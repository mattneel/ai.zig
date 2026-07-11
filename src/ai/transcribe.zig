//! `transcribe` orchestration over TranscriptionModel V4.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const logger = @import("logger.zig");
const media_data = @import("media_data.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

/// URLs are explicit in Zig, avoiding the JS `URL`-instance ambiguity while
/// preserving the upstream data-content distinction.
pub const AudioInput = union(enum) {
    data: media_data.DataContent,
    url: []const u8,
};

pub const TranscribeOptions = struct {
    model: registry.TranscriptionModelRef,
    audio: AudioInput,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    download_transport: ?provider_utils.HttpTransport = null,
    download_options: provider_utils.DownloadOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const TranscribeResult = struct {
    arena_state: std.heap.ArenaAllocator,
    text: []const u8,
    segments: []const provider.TranscriptionSegment,
    language: ?[]const u8,
    duration_seconds: ?f64,
    warnings: []const provider.Warning,
    responses: []const provider.TranscriptionResponseInfo,
    provider_metadata: provider.ProviderMetadata,

    pub fn deinit(self: *TranscribeResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn transcribe(
    io: std.Io,
    gpa: Allocator,
    options: TranscribeOptions,
) anyerror!TranscribeResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveTranscriptionModel(options.model, options.diag);
    const headers = try provider_utils.withUserAgentSuffix(
        arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );
    var default_download_client: ?provider_utils.HttpClientTransport = if (options.download_transport == null)
        provider_utils.HttpClientTransport.init(gpa, io)
    else
        null;
    defer if (default_download_client) |*client| client.deinit();
    const download_transport = options.download_transport orelse default_download_client.?.transport();

    const audio_bytes = switch (options.audio) {
        .data => |content| switch (content) {
            .bytes => |bytes| try arena.dupe(u8, bytes),
            .string => |encoded| media_data.binaryBytes(
                arena,
                .{ .base64 = encoded },
                options.diag,
            ) catch |err| return err,
        },
        .url => |url| blk: {
            const downloaded = try provider_utils.download(
                io,
                arena,
                download_transport,
                url,
                options.download_options,
                options.diag,
            );
            break :blk downloaded.data;
        },
    };
    const media_type = (try provider_utils.detectMediaType(
        arena,
        .{ .bytes = audio_bytes },
        "audio",
    )) orelse "audio/wav";

    var attempt: Attempt = .{
        .model = model,
        .arena = arena,
        .options = .{
            .audio = .{ .bytes = audio_bytes },
            .media_type = media_type,
            .provider_options = options.provider_options,
            .headers = headers,
        },
    };
    const model_result = try provider_utils.retry(
        provider.TranscriptionResult,
        io,
        .{ .max_retries = options.max_retries },
        &attempt,
        Attempt.call,
        options.diag,
    );
    const warnings = try cloneWarnings(arena, model_result.warnings);

    logger.logWarnings(arena, .{
        .warnings = warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });

    if (model_result.text.len == 0) {
        const responses = [_]provider.TranscriptionResponseInfo{model_result.response};
        const response_slice: []const provider.TranscriptionResponseInfo = &responses;
        const responses_json = provider.wire.stringifyAlloc(arena, response_slice) catch "[]";
        provider.Diagnostics.set(options.diag, if (options.diag) |diag| diag.allocator else arena, .{
            .no_transcript_generated = .{
                .message = "No transcript generated.",
                .responses_json = responses_json,
            },
        });
        return error.NoTranscriptGeneratedError;
    }

    const segments = try arena.alloc(provider.TranscriptionSegment, model_result.segments.len);
    for (model_result.segments, segments) |segment, *destination| destination.* = .{
        .text = try arena.dupe(u8, segment.text),
        .start_second = segment.start_second,
        .end_second = segment.end_second,
    };
    const responses = try arena.alloc(provider.TranscriptionResponseInfo, 1);
    responses[0] = try cloneResponse(arena, model_result.response);

    return .{
        .arena_state = arena_state,
        .text = try arena.dupe(u8, model_result.text),
        .segments = segments,
        .language = if (model_result.language) |language| try arena.dupe(u8, language) else null,
        .duration_seconds = model_result.duration_in_seconds,
        .warnings = warnings,
        .responses = responses,
        .provider_metadata = if (model_result.provider_metadata) |metadata|
            try provider_utils.cloneJsonValue(arena, metadata)
        else
            .{ .object = .empty },
    };
}

const Attempt = struct {
    model: provider.TranscriptionModel,
    arena: Allocator,
    options: provider.TranscriptionCallOptions,

    fn call(
        self: *Attempt,
        io: std.Io,
        _: u32,
        diag: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionResult {
        return self.model.doGenerate(io, self.arena, &self.options, diag);
    }
};

fn cloneWarnings(arena: Allocator, values: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const copy = try arena.alloc(provider.Warning, values.len);
    for (values, copy) |value, *destination| destination.* = try media_data.cloneWarning(arena, value);
    return copy;
}

fn cloneResponse(
    arena: Allocator,
    value: provider.TranscriptionResponseInfo,
) Allocator.Error!provider.TranscriptionResponseInfo {
    return .{
        .timestamp_ms = value.timestamp_ms,
        .model_id = try arena.dupe(u8, value.model_id),
        .headers = try media_data.cloneHeaders(arena, value.headers),
        .body = if (value.body) |body| try provider_utils.cloneJsonValue(arena, body) else null,
    };
}

test "transcribe downloads URL input and defaults unknown bytes to audio/wav" {
    const test_support = @import("test_support");
    const Capture = struct {
        media_type: ?[]const u8 = null,
        audio_len: usize = 0,

        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "transcription";
        }
        fn generate(
            raw: *anyopaque,
            _: std.Io,
            _: Allocator,
            call_options: *const provider.TranscriptionCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.transcription_model.CallError!provider.TranscriptionResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.media_type = call_options.media_type;
            self.audio_len = call_options.audio.bytes.len;
            return .{
                .text = "downloaded transcript",
                .segments = &.{},
                .warnings = &.{},
                .response = .{ .timestamp_ms = 1, .model_id = "transcription" },
            };
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/octet-stream",
        .body = .{ .text = "not-a-recognized-audio-signature" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var capture: Capture = .{};
    const model: provider.TranscriptionModel = .{ .ctx = &capture, .vtable = &.{
        .provider = Capture.providerName,
        .modelId = Capture.modelId,
        .doGenerate = Capture.generate,
        .doStream = null,
    } };
    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/audio", .{server.baseUrl(&base_buffer)});
    var result = try transcribe(io, allocator, .{
        .model = .{ .model = model },
        .audio = .{ .url = url },
        .download_transport = client.transport(),
        .download_options = .{ .allow_private_networks = true },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("downloaded transcript", result.text);
    try std.testing.expectEqualStrings("audio/wav", capture.media_type.?);
    try std.testing.expectEqual("not-a-recognized-audio-signature".len, capture.audio_len);
    try std.testing.expectEqual(1, server.recordedRequests().len);
    try std.testing.expectEqual(.GET, server.recordedRequests()[0].method);
}
