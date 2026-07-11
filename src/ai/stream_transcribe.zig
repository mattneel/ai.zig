//! Streaming transcription orchestration over TranscriptionModel V4.
//!
//! The provider stream is the only pipeline driver. Public transcript parts
//! borrow their payloads until the next pull, while final result metadata is
//! cloned into the result arena and exposed through OneShot-backed accessors.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const logger = @import("logger.zig");
const media_data = @import("media_data.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;
const OneShot = provider_utils.OneShot;

pub const StreamTranscribeOptions = struct {
    model: registry.TranscriptionModelRef,
    audio: provider.transcription_model.AudioStream,
    input_audio_format: provider.transcription_model.InputAudioFormat,
    provider_options: ?provider.ProviderOptions = null,
    headers: ?provider.Headers = null,
    include_raw_chunks: bool = false,
    diag: ?*provider.Diagnostics = null,
};

/// Public stream parts omit provider lifecycle records (`stream-start`,
/// `response-metadata`, and `finish`), matching upstream streamTranscribe.
pub const TranscriptionStreamPart = union(enum) {
    transcript_delta: provider.transcription_model.TranscriptDelta,
    transcript_partial: provider.transcription_model.TranscriptPartial,
    transcript_final: provider.transcription_model.TranscriptFinal,
    raw: provider.transcription_model.RawPart,
    err: provider.transcription_model.ErrorPart,
};

pub const FullStream = struct {
    core: *Core,

    /// Returned slices and JSON values remain valid until the next pull or
    /// until the result is deinitialized.
    pub fn next(self: *FullStream, io: std.Io) anyerror!?TranscriptionStreamPart {
        return self.core.next(io);
    }
};

pub const StreamTranscriptionResult = struct {
    core: *Core,

    pub fn fullStream(self: *StreamTranscriptionResult) FullStream {
        return .{ .core = self.core };
    }

    pub fn next(self: *StreamTranscriptionResult, io: std.Io) anyerror!?TranscriptionStreamPart {
        return self.core.next(io);
    }

    pub fn consumeStream(self: *StreamTranscriptionResult, io: std.Io) anyerror!void {
        while (try self.next(io)) |_| {}
    }

    pub fn text(self: *StreamTranscriptionResult, io: std.Io) anyerror![]const u8 {
        try self.consumeStream(io);
        return try (try self.core.text.wait(io));
    }

    pub fn segments(self: *StreamTranscriptionResult, io: std.Io) anyerror![]const provider.TranscriptionSegment {
        try self.consumeStream(io);
        return try (try self.core.segments.wait(io));
    }

    pub fn language(self: *StreamTranscriptionResult, io: std.Io) anyerror!?[]const u8 {
        try self.consumeStream(io);
        return try (try self.core.language.wait(io));
    }

    pub fn durationInSeconds(self: *StreamTranscriptionResult, io: std.Io) anyerror!?f64 {
        try self.consumeStream(io);
        return try (try self.core.duration_in_seconds.wait(io));
    }

    pub fn warnings(self: *StreamTranscriptionResult, io: std.Io) anyerror![]const provider.Warning {
        try self.consumeStream(io);
        return try (try self.core.warnings.wait(io));
    }

    pub fn responses(self: *StreamTranscriptionResult, io: std.Io) anyerror![]const provider.TranscriptionResponseInfo {
        try self.consumeStream(io);
        return try (try self.core.responses.wait(io));
    }

    pub fn providerMetadata(self: *StreamTranscriptionResult, io: std.Io) anyerror!provider.ProviderMetadata {
        try self.consumeStream(io);
        return try (try self.core.provider_metadata.wait(io));
    }

    /// Cancels the provider stream (and therefore its audio/WebSocket pumps)
    /// before releasing result-owned storage.
    pub fn deinit(self: *StreamTranscriptionResult, io: std.Io) void {
        const core = self.core;
        core.model_stream.deinit(io);
        core.arena_state.deinit();
        core.gpa.destroy(core);
        self.* = undefined;
    }
};

pub fn streamTranscribe(
    io: std.Io,
    gpa: Allocator,
    options: StreamTranscribeOptions,
) anyerror!StreamTranscriptionResult {
    const model = try registry.resolveTranscriptionModel(options.model, options.diag);
    if (model.vtable.doStream == null) {
        provider.Diagnostics.set(options.diag, diagnosticAllocator(options.diag, gpa), .{
            .unsupported_functionality = .{
                .message = "The selected model does not support streaming transcription.",
                .functionality = "streaming transcription",
            },
        });
        return error.UnsupportedFunctionalityError;
    }

    const core = try gpa.create(Core);
    errdefer gpa.destroy(core);
    core.* = .{
        .gpa = gpa,
        .arena_state = .init(gpa),
        .model = model,
        .diag = options.diag,
        .started_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    errdefer core.arena_state.deinit();
    core.arena = core.arena_state.allocator();

    const headers = try provider_utils.withUserAgentSuffix(
        core.arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );
    core.model_result = try model.doStream(io, core.arena, &.{
        .audio = options.audio,
        .input_audio_format = options.input_audio_format,
        .provider_options = options.provider_options,
        .headers = headers,
        .include_raw_chunks = options.include_raw_chunks,
    }, options.diag);
    core.model_stream = core.model_result.stream;
    core.response = responseFromModelResult(core, core.model_result.response);
    return .{ .core = core };
}

const Core = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    arena: Allocator = undefined,
    model: provider.TranscriptionModel,
    diag: ?*provider.Diagnostics,
    started_at_ms: i64,
    model_result: provider.TranscriptionStreamResult = undefined,
    model_stream: provider.TranscriptionPartStream = undefined,
    response: provider.TranscriptionResponseInfo = undefined,
    pull_mutex: std.Io.Mutex = .init,
    done: bool = false,
    finalized: bool = false,

    text: OneShot(anyerror![]const u8) = .{},
    segments: OneShot(anyerror![]const provider.TranscriptionSegment) = .{},
    language: OneShot(anyerror!?[]const u8) = .{},
    duration_in_seconds: OneShot(anyerror!?f64) = .{},
    warnings: OneShot(anyerror![]const provider.Warning) = .{},
    responses: OneShot(anyerror![]const provider.TranscriptionResponseInfo) = .{},
    provider_metadata: OneShot(anyerror!provider.ProviderMetadata) = .{},

    fn next(self: *Core, io: std.Io) anyerror!?TranscriptionStreamPart {
        try self.pull_mutex.lock(io);
        defer self.pull_mutex.unlock(io);
        if (self.done) return null;

        while (true) {
            const maybe_part = self.model_stream.next(io) catch |err| {
                self.done = true;
                self.rejectPending(io, err);
                return err;
            };
            const part = maybe_part orelse {
                self.done = true;
                if (!self.finalized) {
                    const err = self.noTranscript();
                    self.rejectPending(io, err);
                    return err;
                }
                return null;
            };

            switch (part) {
                .stream_start => |value| {
                    if (!self.warnings.event.isSet()) {
                        const copy = try cloneWarnings(self.arena, value.warnings);
                        self.warnings.resolve(io, copy);
                        logger.logWarnings(self.arena, .{
                            .warnings = copy,
                            .provider_name = self.model.provider(),
                            .model = self.model.modelId(),
                        });
                    }
                },
                .response_metadata => |value| self.applyResponseMetadata(value),
                .transcript_delta => |value| return .{ .transcript_delta = value },
                .transcript_partial => |value| return .{ .transcript_partial = value },
                .transcript_final => |value| return .{ .transcript_final = value },
                .raw => |value| return .{ .raw = value },
                .err => |value| return .{ .err = value },
                .finish => |value| {
                    if (value.text.len == 0) {
                        self.done = true;
                        const err = self.noTranscript();
                        self.rejectPending(io, err);
                        return err;
                    }
                    try self.finish(io, value);
                    self.done = true;
                    return null;
                },
            }
        }
    }

    fn finish(self: *Core, io: std.Io, value: provider.transcription_model.FinishPart) Allocator.Error!void {
        const text = try self.arena.dupe(u8, value.text);
        const segments = try cloneSegments(self.arena, value.segments);
        const language = if (value.language) |item| try self.arena.dupe(u8, item) else null;
        const metadata = if (value.provider_metadata) |item|
            try provider_utils.cloneJsonValue(self.arena, item)
        else
            provider.ProviderMetadata{ .object = .empty };
        const response_copy = try cloneResponse(self.arena, self.response);
        const response_list = try self.arena.alloc(provider.TranscriptionResponseInfo, 1);
        response_list[0] = response_copy;

        if (!self.warnings.event.isSet()) self.warnings.resolve(io, &.{});
        self.text.resolve(io, text);
        self.segments.resolve(io, segments);
        self.language.resolve(io, language);
        self.duration_in_seconds.resolve(io, value.duration_in_seconds);
        self.responses.resolve(io, response_list);
        self.provider_metadata.resolve(io, metadata);
        self.finalized = true;
    }

    fn applyResponseMetadata(self: *Core, value: provider.transcription_model.StreamResponseMetadata) void {
        if (value.timestamp_ms) |timestamp| self.response.timestamp_ms = timestamp;
        if (value.model_id) |model_id| self.response.model_id = model_id;
        if (value.headers) |headers| self.response.headers = headers;
        if (value.body) |body| self.response.body = body;
    }

    fn noTranscript(self: *Core) provider.Error {
        const responses = [_]provider.TranscriptionResponseInfo{self.response};
        const response_slice: []const provider.TranscriptionResponseInfo = &responses;
        const responses_json = provider.wire.stringifyAlloc(self.arena, response_slice) catch "[]";
        provider.Diagnostics.set(self.diag, diagnosticAllocator(self.diag, self.arena), .{
            .no_transcript_generated = .{
                .message = "No transcript generated.",
                .responses_json = responses_json,
            },
        });
        return error.NoTranscriptGeneratedError;
    }

    fn rejectPending(self: *Core, io: std.Io, err: anyerror) void {
        if (!self.text.event.isSet()) self.text.resolve(io, err);
        if (!self.segments.event.isSet()) self.segments.resolve(io, err);
        if (!self.language.event.isSet()) self.language.resolve(io, err);
        if (!self.duration_in_seconds.event.isSet()) self.duration_in_seconds.resolve(io, err);
        if (!self.warnings.event.isSet()) self.warnings.resolve(io, err);
        if (!self.responses.event.isSet()) self.responses.resolve(io, err);
        if (!self.provider_metadata.event.isSet()) self.provider_metadata.resolve(io, err);
    }
};

fn responseFromModelResult(
    core: *Core,
    maybe_response: ?provider.transcription_model.StreamResponseInfo,
) provider.TranscriptionResponseInfo {
    const response = maybe_response orelse return .{
        .timestamp_ms = core.started_at_ms,
        .model_id = core.model.modelId(),
    };
    return .{
        .timestamp_ms = response.timestamp_ms orelse core.started_at_ms,
        .model_id = response.model_id orelse core.model.modelId(),
        .headers = response.headers,
        .body = response.body,
    };
}

fn cloneWarnings(arena: Allocator, values: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const copy = try arena.alloc(provider.Warning, values.len);
    for (values, copy) |value, *destination| destination.* = try media_data.cloneWarning(arena, value);
    return copy;
}

fn cloneSegments(arena: Allocator, values: []const provider.TranscriptionSegment) Allocator.Error![]const provider.TranscriptionSegment {
    const copy = try arena.alloc(provider.TranscriptionSegment, values.len);
    for (values, copy) |value, *destination| destination.* = .{
        .text = try arena.dupe(u8, value.text),
        .start_second = value.start_second,
        .end_second = value.end_second,
    };
    return copy;
}

fn cloneResponse(arena: Allocator, value: provider.TranscriptionResponseInfo) Allocator.Error!provider.TranscriptionResponseInfo {
    return .{
        .timestamp_ms = value.timestamp_ms,
        .model_id = try arena.dupe(u8, value.model_id),
        .headers = try media_data.cloneHeaders(arena, value.headers),
        .body = if (value.body) |body| try provider_utils.cloneJsonValue(arena, body) else null,
    };
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

const TestAudio = struct {
    fn next(_: *anyopaque, _: std.Io) provider.transcription_model.NextError!?provider.BinaryData {
        return null;
    }
    fn deinit(_: *anyopaque, _: std.Io) void {}
};

const TestModel = struct {
    parts: []const provider.TranscriptionStreamPart,
    index: usize = 0,
    stream_deinitialized: bool = false,

    fn model(self: *TestModel) provider.TranscriptionModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.TranscriptionModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .doGenerate = generate,
        .doStream = stream,
    };

    fn fromRaw(raw: *anyopaque) *TestModel {
        return @ptrCast(@alignCast(raw));
    }
    fn providerName(_: *anyopaque) []const u8 {
        return "mock";
    }
    fn modelId(_: *anyopaque) []const u8 {
        return "stream-transcription";
    }
    fn generate(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.TranscriptionCallOptions,
        _: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionResult {
        return error.UnsupportedFunctionalityError;
    }
    fn stream(
        raw: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.TranscriptionStreamOptions,
        _: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionStreamResult {
        return .{
            .stream = .{ .ctx = raw, .vtable = &.{ .next = nextPart, .deinit = deinitStream } },
            .response = .{ .timestamp_ms = 1, .model_id = "provider-model" },
        };
    }
    fn nextPart(raw: *anyopaque, _: std.Io) provider.transcription_model.NextError!?provider.TranscriptionStreamPart {
        const self = fromRaw(raw);
        if (self.index == self.parts.len) return null;
        defer self.index += 1;
        return self.parts[self.index];
    }
    fn deinitStream(raw: *anyopaque, _: std.Io) void {
        fromRaw(raw).stream_deinitialized = true;
    }
};

test "streamTranscribe forwards public parts and resolves OneShot accessors" {
    logger.setWarningLogger(.disabled);
    defer logger.setWarningLogger(.default);
    const warnings = [_]provider.Warning{.{ .other = .{ .message = "fixture warning" } }};
    const segments = [_]provider.TranscriptionSegment{.{
        .text = "Hello",
        .start_second = 0,
        .end_second = 1,
    }};
    const parts = [_]provider.TranscriptionStreamPart{
        .{ .stream_start = .{ .warnings = &warnings } },
        .{ .transcript_delta = .{ .id = "item-1", .delta = "Hel" } },
        .{ .transcript_final = .{ .id = "item-1", .text = "Hello" } },
        .{ .finish = .{
            .text = "Hello",
            .segments = &segments,
            .language = "en",
            .duration_in_seconds = 1,
        } },
    };
    var model: TestModel = .{ .parts = &parts };
    var audio_marker: u8 = 0;
    var result = try streamTranscribe(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.model() },
        .audio = .{ .ctx = &audio_marker, .vtable = &.{ .next = TestAudio.next, .deinit = TestAudio.deinit } },
        .input_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
    });
    defer result.deinit(std.testing.io);

    var full = result.fullStream();
    const delta = (try full.next(std.testing.io)).?.transcript_delta;
    try std.testing.expectEqualStrings("Hel", delta.delta);
    const final = (try full.next(std.testing.io)).?.transcript_final;
    try std.testing.expectEqualStrings("Hello", final.text);
    try std.testing.expectEqual(null, try full.next(std.testing.io));

    try std.testing.expectEqualStrings("Hello", try result.text(std.testing.io));
    try std.testing.expectEqualStrings("Hello", (try result.segments(std.testing.io))[0].text);
    try std.testing.expectEqualStrings("en", (try result.language(std.testing.io)).?);
    try std.testing.expectEqual(1.0, (try result.durationInSeconds(std.testing.io)).?);
    try std.testing.expectEqualStrings("fixture warning", (try result.warnings(std.testing.io))[0].other.message);
    try std.testing.expectEqualStrings("provider-model", (try result.responses(std.testing.io))[0].model_id);
}

test "streamTranscribe rejects missing doStream before taking audio" {
    const Missing = struct {
        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "generate-only";
        }
        fn generate(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: *const provider.TranscriptionCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.transcription_model.CallError!provider.TranscriptionResult {
            return error.UnsupportedFunctionalityError;
        }
    };
    var marker: u8 = 0;
    const model: provider.TranscriptionModel = .{ .ctx = &marker, .vtable = &.{
        .provider = Missing.providerName,
        .modelId = Missing.modelId,
        .doGenerate = Missing.generate,
        .doStream = null,
    } };
    var audio_marker: u8 = 0;
    try std.testing.expectError(error.UnsupportedFunctionalityError, streamTranscribe(
        std.testing.io,
        std.testing.allocator,
        .{
            .model = .{ .model = model },
            .audio = .{ .ctx = &audio_marker, .vtable = &.{ .next = TestAudio.next, .deinit = TestAudio.deinit } },
            .input_audio_format = .{ .type = "audio/pcm" },
        },
    ));
}

test "streamTranscribe errors when the provider finishes without text" {
    const parts = [_]provider.TranscriptionStreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .finish = .{ .text = "", .segments = &.{} } },
    };
    var model: TestModel = .{ .parts = &parts };
    var audio_marker: u8 = 0;
    var result = try streamTranscribe(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.model() },
        .audio = .{ .ctx = &audio_marker, .vtable = &.{ .next = TestAudio.next, .deinit = TestAudio.deinit } },
        .input_audio_format = .{ .type = "audio/pcm" },
    });
    defer result.deinit(std.testing.io);
    try std.testing.expectError(error.NoTranscriptGeneratedError, result.next(std.testing.io));
    try std.testing.expectError(error.NoTranscriptGeneratedError, result.text(std.testing.io));
}
