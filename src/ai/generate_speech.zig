//! `generateSpeech` orchestration over SpeechModel V4.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const generated_file = @import("generated_file.zig");
const logger = @import("logger.zig");
const media_data = @import("media_data.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

pub const GenerateSpeechOptions = struct {
    model: registry.SpeechModelRef,
    text: []const u8,
    voice: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    speed: ?f64 = null,
    language: ?[]const u8 = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    diag: ?*provider.Diagnostics = null,
};

pub const GenerateSpeechResult = struct {
    arena_state: std.heap.ArenaAllocator,
    audio: generated_file.GeneratedAudioFile,
    warnings: []const provider.Warning,
    responses: []const provider.SpeechResponseInfo,
    provider_metadata: provider.ProviderMetadata,

    pub fn deinit(self: *GenerateSpeechResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn generateSpeech(
    io: std.Io,
    gpa: Allocator,
    options: GenerateSpeechOptions,
) anyerror!GenerateSpeechResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveSpeechModel(options.model, options.diag);
    const headers = try provider_utils.withUserAgentSuffix(
        arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );

    var attempt: Attempt = .{
        .model = model,
        .arena = arena,
        .options = .{
            .text = options.text,
            .voice = options.voice,
            .output_format = options.output_format,
            .instructions = options.instructions,
            .speed = options.speed,
            .language = options.language,
            .provider_options = options.provider_options,
            .headers = headers,
        },
    };
    const model_result = try provider_utils.retry(
        provider.SpeechResult,
        io,
        .{ .max_retries = options.max_retries },
        &attempt,
        Attempt.call,
        options.diag,
    );

    const audio_len = switch (model_result.audio) {
        .bytes => |bytes| bytes.len,
        .base64 => |encoded| encoded.len,
    };
    // Preserve upstream's observable order: empty audio fails before warning
    // logging, even when the provider returned warnings.
    if (audio_len == 0) {
        const responses = [_]provider.SpeechResponseInfo{model_result.response};
        const response_slice: []const provider.SpeechResponseInfo = &responses;
        const responses_json = provider.wire.stringifyAlloc(arena, response_slice) catch "[]";
        provider.Diagnostics.set(options.diag, if (options.diag) |diag| diag.allocator else arena, .{
            .no_speech_generated = .{
                .message = "No speech generated.",
                .responses_json = responses_json,
            },
        });
        return error.NoSpeechGeneratedError;
    }

    const owned_audio = switch (model_result.audio) {
        .bytes => |bytes| provider.BinaryData{ .bytes = try arena.dupe(u8, bytes) },
        .base64 => |encoded| provider.BinaryData{ .base64 = try arena.dupe(u8, encoded) },
    };
    const media_type = (try provider_utils.detectMediaType(
        arena,
        switch (owned_audio) {
            .bytes => |bytes| .{ .bytes = bytes },
            .base64 => |encoded| .{ .base64 = encoded },
        },
        "audio",
    )) orelse "audio/mp3";
    const warnings = try cloneWarnings(arena, model_result.warnings);
    const responses = try arena.alloc(provider.SpeechResponseInfo, 1);
    responses[0] = try cloneResponse(arena, model_result.response);
    const metadata = if (model_result.provider_metadata) |value|
        try provider_utils.cloneJsonValue(arena, value)
    else
        std.json.Value{ .object = .empty };

    logger.logWarnings(arena, .{
        .warnings = warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });

    return .{
        .arena_state = arena_state,
        .audio = generated_file.GeneratedAudioFile.init(owned_audio, media_type),
        .warnings = warnings,
        .responses = responses,
        .provider_metadata = metadata,
    };
}

const Attempt = struct {
    model: provider.SpeechModel,
    arena: Allocator,
    options: provider.SpeechCallOptions,

    fn call(
        self: *Attempt,
        io: std.Io,
        _: u32,
        diag: ?*provider.Diagnostics,
    ) provider.speech_model.CallError!provider.SpeechResult {
        return self.model.doGenerate(io, self.arena, &self.options, diag);
    }
};

fn cloneWarnings(arena: Allocator, values: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const copy = try arena.alloc(provider.Warning, values.len);
    for (values, copy) |value, *destination| destination.* = try media_data.cloneWarning(arena, value);
    return copy;
}

fn cloneResponse(arena: Allocator, value: provider.SpeechResponseInfo) Allocator.Error!provider.SpeechResponseInfo {
    return .{
        .timestamp_ms = value.timestamp_ms,
        .model_id = try arena.dupe(u8, value.model_id),
        .headers = try media_data.cloneHeaders(arena, value.headers),
        .body = if (value.body) |body| try provider_utils.cloneJsonValue(arena, body) else null,
    };
}

test "generateSpeech rejects empty audio before logging warnings" {
    const Mock = struct {
        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "speech";
        }
        fn generate(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: *const provider.SpeechCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.speech_model.CallError!provider.SpeechResult {
            return .{
                .audio = .{ .bytes = &.{} },
                .warnings = &.{.{ .other = .{ .message = "must not log" } }},
                .response = .{ .timestamp_ms = 1, .model_id = "speech" },
            };
        }
    };
    const Capture = struct {
        calls: usize = 0,
        fn log(raw: ?*anyopaque, _: *const logger.Options) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
        }
    };
    var marker: u8 = 0;
    var capture: Capture = .{};
    logger.setWarningLogger(.{ .custom = .{ .ctx = &capture, .log_fn = Capture.log } });
    defer logger.setWarningLogger(.default);
    const model: provider.SpeechModel = .{ .ctx = &marker, .vtable = &.{
        .provider = Mock.providerName,
        .modelId = Mock.modelId,
        .doGenerate = Mock.generate,
    } };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.NoSpeechGeneratedError, generateSpeech(
        std.testing.io,
        std.testing.allocator,
        .{ .model = .{ .model = model }, .text = "hello", .diag = &diagnostics },
    ));
    try std.testing.expectEqual(0, capture.calls);
    try std.testing.expect(diagnostics.payload == .no_speech_generated);
}
