const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");

const Allocator = std.mem.Allocator;
const max_provider_id_len = 1024;

pub const SpeechModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!SpeechModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI speech model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");

        var result: SpeechModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.speech", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn speechModel(self: *SpeechModel) provider.SpeechModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.SpeechModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .doGenerate = vDoGenerate,
    };

    fn fromRaw(raw: *anyopaque) *SpeechModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        return self.provider_id_buffer[0..self.provider_id_len];
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.SpeechCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.speech_model.CallError!provider.SpeechResult {
        return fromRaw(raw).doGenerate(io, arena, options, diag);
    }

    fn doGenerate(
        self: *SpeechModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.SpeechCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.speech_model.CallError!provider.SpeechResult {
        const timestamp_ms = currentTimeMillis(io);
        const output_format = options.output_format orelse "mp3";
        const supported_format = isSupportedOutputFormat(output_format);
        const warning_count = @as(usize, @intFromBool(!supported_format)) +
            @as(usize, @intFromBool(options.language != null));
        const warnings = try arena.alloc(provider.Warning, warning_count);
        var warning_index: usize = 0;
        if (!supported_format) {
            warnings[warning_index] = .{ .unsupported = .{
                .feature = "outputFormat",
                .details = try std.fmt.allocPrint(
                    arena,
                    "Unsupported output format: {s}. Using mp3 instead.",
                    .{output_format},
                ),
            } };
            warning_index += 1;
        }
        if (options.language) |language| {
            warnings[warning_index] = .{ .unsupported = .{
                .feature = "language",
                .details = try std.fmt.allocPrint(
                    arena,
                    "OpenAI speech models do not support language selection. Language parameter \"{s}\" was ignored.",
                    .{language},
                ),
            } };
        }

        var body: std.json.ObjectMap = .empty;
        try putString(&body, arena, "model", self.model_id);
        try putString(&body, arena, "input", options.text);
        try putString(&body, arena, "voice", options.voice orelse "alloy");
        try putString(&body, arena, "response_format", if (supported_format) output_format else "mp3");
        if (options.speed) |speed| try body.put(arena, "speed", .{ .float = speed });
        if (options.instructions) |instructions| try putString(&body, arena, "instructions", instructions);

        const body_value: std.json.Value = .{ .object = body };
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, body_value);
        const url = try std.fmt.allocPrint(arena, "{s}/audio/speech", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, options.headers, diag);
        const result = try provider_utils.postJsonToApi(
            []const u8,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.binaryResponseHandler(),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );

        return .{
            .audio = .{ .bytes = result.value },
            .warnings = warnings,
            .request = .{ .body = body_value },
            .response = .{
                .timestamp_ms = timestamp_ms,
                .model_id = self.model_id,
                .headers = result.response_headers,
            },
        };
    }

    fn resolveHeaders(
        self: *const SpeechModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
        diag: ?*provider.Diagnostics,
    ) provider.speech_model.CallError![]const provider.Header {
        const api_key = try provider_utils.loadApiKey(.{
            .explicit = self.config.api_key,
            .env_var = "OPENAI_API_KEY",
            .description = "OpenAI",
            .env = self.config.env,
        }, arena, diag);
        var configured_storage: [3]provider_utils.HeaderEntry = undefined;
        var configured_len: usize = 0;
        configured_storage[configured_len] = .{
            .name = "authorization",
            .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}),
        };
        configured_len += 1;
        if (self.config.organization) |organization| {
            configured_storage[configured_len] = .{ .name = "OpenAI-Organization", .value = organization };
            configured_len += 1;
        }
        if (self.config.project) |project| {
            configured_storage[configured_len] = .{ .name = "OpenAI-Project", .value = project };
            configured_len += 1;
        }
        const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |value| value.len else 0);
        if (call_headers) |values| for (values, call_entries) |header, *entry| {
            entry.* = .{ .name = header.name, .value = header.value };
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            configured_storage[0..configured_len],
            self.config.headers.resolve(),
            call_entries,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(
            arena,
            combined,
            &.{"ai-sdk-zig/openai/" ++ provider_utils.version},
        );
    }
};

fn isSupportedOutputFormat(value: []const u8) bool {
    return std.mem.eql(u8, value, "mp3") or
        std.mem.eql(u8, value, "opus") or
        std.mem.eql(u8, value, "aac") or
        std.mem.eql(u8, value, "flac") or
        std.mem.eql(u8, value, "wav") or
        std.mem.eql(u8, value, "pcm");
}

fn currentTimeMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn invalidArgument(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "OpenAI speech posts options and returns binary audio with exact warnings" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "audio/mpeg",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "speech-request" }},
        .body = .{ .text = "\x49\x44\x33\x04\x00\x00" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try SpeechModel.init("tts-1", .{
        .allocator = allocator,
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = client.transport(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try model.speechModel().doGenerate(io, arena_state.allocator(), &.{
        .text = "Hello from ai.zig",
        .voice = "nova",
        .output_format = "not-audio",
        .speed = 1.5,
        .instructions = "Speak clearly",
        .language = "en",
    }, null);

    try std.testing.expectEqualStrings("\x49\x44\x33\x04\x00\x00", result.audio.bytes);
    try std.testing.expectEqual(2, result.warnings.len);
    try std.testing.expectEqualStrings("outputFormat", result.warnings[0].unsupported.feature);
    try std.testing.expectEqualStrings(
        "Unsupported output format: not-audio. Using mp3 instead.",
        result.warnings[0].unsupported.details.?,
    );
    try std.testing.expectEqualStrings("language", result.warnings[1].unsupported.feature);
    try std.testing.expectEqualStrings(
        "OpenAI speech models do not support language selection. Language parameter \"en\" was ignored.",
        result.warnings[1].unsupported.details.?,
    );
    try std.testing.expectEqualStrings("speech-request", recordedHeader(result.response.headers.?, "x-request-id").?);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqualStrings("/audio/speech", requests[0].target);
    try std.testing.expectEqualStrings("application/json", recordedHeader(requests[0].headers, "content-type").?);
    const request_body = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), requests[0].body, .{});
    try std.testing.expectEqualStrings("tts-1", request_body.object.get("model").?.string);
    try std.testing.expectEqualStrings("Hello from ai.zig", request_body.object.get("input").?.string);
    try std.testing.expectEqualStrings("nova", request_body.object.get("voice").?.string);
    try std.testing.expectEqualStrings("mp3", request_body.object.get("response_format").?.string);
    try std.testing.expectEqual(1.5, request_body.object.get("speed").?.float);
    try std.testing.expectEqualStrings("Speak clearly", request_body.object.get("instructions").?.string);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI speech accepts each native output format" {
    const formats = [_][]const u8{ "mp3", "opus", "aac", "flac", "wav", "pcm" };
    for (formats) |format| try std.testing.expect(isSupportedOutputFormat(format));
    try std.testing.expect(!isSupportedOutputFormat("ogg"));
}
