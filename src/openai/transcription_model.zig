const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");

const Allocator = std.mem.Allocator;
const max_provider_id_len = 1024;

pub const TranscriptionModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!TranscriptionModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI transcription model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");

        var result: TranscriptionModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.transcription", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn transcriptionModel(self: *TranscriptionModel) provider.TranscriptionModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.TranscriptionModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .doGenerate = vDoGenerate,
        .doStream = null,
    };

    fn fromRaw(raw: *anyopaque) *TranscriptionModel {
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
        options: *const provider.TranscriptionCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionResult {
        return fromRaw(raw).doGenerate(io, arena, options, diag);
    }

    fn doGenerate(
        self: *TranscriptionModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.TranscriptionCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionResult {
        if (isRealtimeTranscriptionModelId(self.model_id)) {
            const functionality = try std.fmt.allocPrint(
                arena,
                "non-streaming transcription with {s}",
                .{self.model_id},
            );
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .unsupported_functionality = .{
                .message = functionality,
                .functionality = functionality,
            } });
            return error.UnsupportedFunctionalityError;
        }

        const timestamp_ms = currentTimeMillis(io);
        const openai_options = try parseTranscriptionOptions(
            arena,
            options.provider_options,
            self.config.provider_options_name,
            diag,
        );
        const audio = switch (options.audio) {
            .bytes => |bytes| bytes,
            .base64 => |encoded| provider_utils.decodeBase64(arena, encoded) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidAudio(arena, diag, "OpenAI transcription audio contains invalid base64"),
            },
        };
        const extension = try mediaTypeToExtension(arena, options.media_type);
        const filename = try std.fmt.allocPrint(arena, "audio.{s}", .{extension});

        var form_data = try provider_utils.FormData.initFromIo(arena, io);
        defer form_data.deinit();
        try form_data.appendText("model", self.model_id);
        try form_data.appendFile("file", filename, options.media_type, audio);
        try form_data.appendText("response_format", transcriptionResponseFormat(self.model_id));
        if (openai_options) |settings| {
            if (settings.include) |values| try appendArrayWithBrackets(arena, &form_data, "include", values);
            if (settings.language) |language| try form_data.appendText("language", language);
            if (settings.prompt) |prompt| try form_data.appendText("prompt", prompt);
            if (settings.temperature) |temperature| {
                try form_data.appendText("temperature", try std.fmt.allocPrint(arena, "{d}", .{temperature}));
            }
            if (settings.timestamp_granularities) |values| {
                try appendArrayWithBrackets(arena, &form_data, "timestamp_granularities", values);
            }
        }

        const url = try std.fmt.allocPrint(arena, "{s}/audio/transcriptions", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, options.headers, diag);
        const result = try provider_utils.postFormDataToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .form_data = &form_data },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );
        return mapResponse(
            arena,
            result.value,
            timestamp_ms,
            self.model_id,
            result.response_headers,
            diag,
        );
    }

    fn resolveHeaders(
        self: *const TranscriptionModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
        diag: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError![]const provider.Header {
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

const TranscriptionOptions = struct {
    include: ?[]const []const u8 = null,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    temperature: ?f64 = 0,
    timestamp_granularities: ?[]const []const u8 = &.{"segment"},
};

fn parseTranscriptionOptions(
    arena: Allocator,
    value: ?provider.ProviderOptions,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!?TranscriptionOptions {
    const root = value orelse return null;
    if (root == .null) return null;
    if (root != .object) return invalidOptions(arena, diag, "providerOptions must be a JSON object");

    var result: ?TranscriptionOptions = null;
    if (root.object.get("openai")) |canonical| try applyTranscriptionOptions(arena, &result, canonical, diag);
    if (!std.mem.eql(u8, namespace, "openai")) {
        if (root.object.get(namespace)) |custom| try applyTranscriptionOptions(arena, &result, custom, diag);
    }
    return result;
}

fn applyTranscriptionOptions(
    arena: Allocator,
    result: *?TranscriptionOptions,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!void {
    if (value == .null) return;
    if (value != .object) return invalidOptions(arena, diag, "OpenAI transcription options must be an object");
    if (result.* == null) result.* = .{};
    const settings = &result.*.?;
    if (value.object.get("include")) |item| settings.include = try optionalStringArray(arena, item, "include", null, diag);
    if (value.object.get("language")) |item| settings.language = try optionalString(arena, item, "language", diag);
    if (value.object.get("prompt")) |item| settings.prompt = try optionalString(arena, item, "prompt", diag);
    if (value.object.get("temperature")) |item| settings.temperature = try optionalTemperature(arena, item, diag);
    if (value.object.get("timestampGranularities")) |item| {
        settings.timestamp_granularities = try optionalStringArray(
            arena,
            item,
            "timestampGranularities",
            &.{ "word", "segment" },
            diag,
        );
    }
}

fn optionalString(
    arena: Allocator,
    value: std.json.Value,
    field: []const u8,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => invalidOptionField(arena, diag, field, "must be a string"),
    };
}

fn optionalStringArray(
    arena: Allocator,
    value: std.json.Value,
    field: []const u8,
    allowed: ?[]const []const u8,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!?[]const []const u8 {
    if (value == .null) return null;
    if (value != .array) return invalidOptionField(arena, diag, field, "must be an array of strings");
    const result = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, result) |item, *destination| {
        if (item != .string) return invalidOptionField(arena, diag, field, "must be an array of strings");
        if (allowed) |candidates| {
            var supported = false;
            for (candidates) |candidate| if (std.mem.eql(u8, item.string, candidate)) {
                supported = true;
                break;
            };
            if (!supported) return invalidOptionField(arena, diag, field, "contains an unsupported value");
        }
        destination.* = item.string;
    }
    return result;
}

fn optionalTemperature(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!?f64 {
    if (value == .null) return null;
    const number = switch (value) {
        .float => |float| float,
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        else => return invalidOptionField(arena, diag, "temperature", "must be between 0 and 1"),
    };
    if (!std.math.isFinite(number) or number < 0 or number > 1) {
        return invalidOptionField(arena, diag, "temperature", "must be between 0 and 1");
    }
    return number;
}

fn appendArrayWithBrackets(
    arena: Allocator,
    form_data: *provider_utils.FormData,
    name: []const u8,
    values: []const []const u8,
) Allocator.Error!void {
    const array_name = try std.fmt.allocPrint(arena, "{s}[]", .{name});
    for (values) |value| try form_data.appendText(array_name, value);
}

fn isRealtimeTranscriptionModelId(model_id: []const u8) bool {
    return std.mem.eql(u8, model_id, "gpt-realtime-whisper") or
        std.mem.startsWith(u8, model_id, "gpt-realtime-whisper-");
}

fn transcriptionResponseFormat(model_id: []const u8) []const u8 {
    if (std.mem.eql(u8, model_id, "gpt-4o-transcribe") or
        std.mem.eql(u8, model_id, "gpt-4o-mini-transcribe")) return "json";
    return "verbose_json";
}

fn mediaTypeToExtension(arena: Allocator, media_type: []const u8) Allocator.Error![]const u8 {
    const slash = std.mem.findScalar(u8, media_type, '/') orelse media_type.len;
    const subtype = if (slash == media_type.len) "" else media_type[slash + 1 ..];
    const lowercase = try arena.alloc(u8, subtype.len);
    for (subtype, lowercase) |source, *destination| destination.* = std.ascii.toLower(source);
    if (std.mem.eql(u8, lowercase, "mpeg")) return "mp3";
    if (std.mem.eql(u8, lowercase, "x-wav")) return "wav";
    if (std.mem.eql(u8, lowercase, "opus")) return "ogg";
    if (std.mem.eql(u8, lowercase, "mp4") or std.mem.eql(u8, lowercase, "x-m4a")) return "m4a";
    return lowercase;
}

fn mapResponse(
    arena: Allocator,
    response: std.json.Value,
    timestamp_ms: i64,
    model_id: []const u8,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!provider.TranscriptionResult {
    if (response != .object) return invalidResponse(arena, diag, "OpenAI transcription response must be an object");
    const text = optionalResponseString(response.object, "text") orelse
        return invalidResponse(arena, diag, "OpenAI transcription response text is missing");
    const segments = if (response.object.get("segments")) |value|
        if (value == .null) try mapWords(arena, response.object.get("words"), diag) else try mapSegments(arena, value, diag)
    else
        try mapWords(arena, response.object.get("words"), diag);
    const language = if (optionalResponseString(response.object, "language")) |value| languageToIso6391(value) else null;

    return .{
        .text = text,
        .segments = segments,
        .language = language,
        .duration_in_seconds = optionalF64(response.object.get("duration")),
        .warnings = &.{},
        .response = .{
            .timestamp_ms = timestamp_ms,
            .model_id = model_id,
            .headers = response_headers,
            .body = response,
        },
    };
}

fn mapSegments(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError![]const provider.TranscriptionSegment {
    if (value != .array) return invalidResponse(arena, diag, "OpenAI transcription segments must be an array");
    const result = try arena.alloc(provider.TranscriptionSegment, value.array.items.len);
    for (value.array.items, result) |item, *destination| {
        if (item != .object) return invalidResponse(arena, diag, "OpenAI transcription segment must be an object");
        destination.* = .{
            .text = optionalResponseString(item.object, "text") orelse
                return invalidResponse(arena, diag, "OpenAI transcription segment text is missing"),
            .start_second = optionalF64(item.object.get("start")) orelse
                return invalidResponse(arena, diag, "OpenAI transcription segment start is missing"),
            .end_second = optionalF64(item.object.get("end")) orelse
                return invalidResponse(arena, diag, "OpenAI transcription segment end is missing"),
        };
    }
    return result;
}

fn mapWords(
    arena: Allocator,
    maybe_value: ?std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError![]const provider.TranscriptionSegment {
    const value = maybe_value orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return invalidResponse(arena, diag, "OpenAI transcription words must be an array");
    const result = try arena.alloc(provider.TranscriptionSegment, value.array.items.len);
    for (value.array.items, result) |item, *destination| {
        if (item != .object) return invalidResponse(arena, diag, "OpenAI transcription word must be an object");
        destination.* = .{
            .text = optionalResponseString(item.object, "word") orelse
                return invalidResponse(arena, diag, "OpenAI transcription word text is missing"),
            .start_second = optionalF64(item.object.get("start")) orelse
                return invalidResponse(arena, diag, "OpenAI transcription word start is missing"),
            .end_second = optionalF64(item.object.get("end")) orelse
                return invalidResponse(arena, diag, "OpenAI transcription word end is missing"),
        };
    }
    return result;
}

const Language = struct { name: []const u8, code: []const u8 };
const languages = [_]Language{
    .{ .name = "afrikaans", .code = "af" },
    .{ .name = "arabic", .code = "ar" },
    .{ .name = "armenian", .code = "hy" },
    .{ .name = "azerbaijani", .code = "az" },
    .{ .name = "belarusian", .code = "be" },
    .{ .name = "bosnian", .code = "bs" },
    .{ .name = "bulgarian", .code = "bg" },
    .{ .name = "catalan", .code = "ca" },
    .{ .name = "chinese", .code = "zh" },
    .{ .name = "croatian", .code = "hr" },
    .{ .name = "czech", .code = "cs" },
    .{ .name = "danish", .code = "da" },
    .{ .name = "dutch", .code = "nl" },
    .{ .name = "english", .code = "en" },
    .{ .name = "estonian", .code = "et" },
    .{ .name = "finnish", .code = "fi" },
    .{ .name = "french", .code = "fr" },
    .{ .name = "galician", .code = "gl" },
    .{ .name = "german", .code = "de" },
    .{ .name = "greek", .code = "el" },
    .{ .name = "hebrew", .code = "he" },
    .{ .name = "hindi", .code = "hi" },
    .{ .name = "hungarian", .code = "hu" },
    .{ .name = "icelandic", .code = "is" },
    .{ .name = "indonesian", .code = "id" },
    .{ .name = "italian", .code = "it" },
    .{ .name = "japanese", .code = "ja" },
    .{ .name = "kannada", .code = "kn" },
    .{ .name = "kazakh", .code = "kk" },
    .{ .name = "korean", .code = "ko" },
    .{ .name = "latvian", .code = "lv" },
    .{ .name = "lithuanian", .code = "lt" },
    .{ .name = "macedonian", .code = "mk" },
    .{ .name = "malay", .code = "ms" },
    .{ .name = "marathi", .code = "mr" },
    .{ .name = "maori", .code = "mi" },
    .{ .name = "nepali", .code = "ne" },
    .{ .name = "norwegian", .code = "no" },
    .{ .name = "persian", .code = "fa" },
    .{ .name = "polish", .code = "pl" },
    .{ .name = "portuguese", .code = "pt" },
    .{ .name = "romanian", .code = "ro" },
    .{ .name = "russian", .code = "ru" },
    .{ .name = "serbian", .code = "sr" },
    .{ .name = "slovak", .code = "sk" },
    .{ .name = "slovenian", .code = "sl" },
    .{ .name = "spanish", .code = "es" },
    .{ .name = "swahili", .code = "sw" },
    .{ .name = "swedish", .code = "sv" },
    .{ .name = "tagalog", .code = "tl" },
    .{ .name = "tamil", .code = "ta" },
    .{ .name = "thai", .code = "th" },
    .{ .name = "turkish", .code = "tr" },
    .{ .name = "ukrainian", .code = "uk" },
    .{ .name = "urdu", .code = "ur" },
    .{ .name = "vietnamese", .code = "vi" },
    .{ .name = "welsh", .code = "cy" },
};

fn languageToIso6391(language: []const u8) ?[]const u8 {
    for (languages) |entry| if (std.mem.eql(u8, language, entry.name)) return entry.code;
    return null;
}

fn optionalResponseString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalF64(value: ?std.json.Value) ?f64 {
    const item = value orelse return null;
    return switch (item) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

fn currentTimeMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn invalidResponse(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
}

fn invalidAudio(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .invalid_data_content = .{ .message = message },
    });
    return error.InvalidDataContentError;
}

fn invalidOptions(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .type_validation = .{ .message = message },
    });
    return error.TypeValidationError;
}

fn invalidOptionField(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    field: []const u8,
    details: []const u8,
) provider.transcription_model.CallError {
    const message = std.fmt.allocPrint(arena, "OpenAI transcription option {s} {s}", .{ field, details }) catch
        return error.OutOfMemory;
    return invalidOptions(arena, diag, message);
}

fn invalidArgument(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "OpenAI transcription multipart maps verbose response and prefers segments" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "transcription-request" }},
        .body = .{ .text =
        \\{"text":"Hello world","language":"english","duration":2.5,"segments":[{"id":0,"seek":0,"start":0,"end":2.5,"text":"Hello world","tokens":[],"temperature":0,"avg_logprob":-0.1,"compression_ratio":1,"no_speech_prob":0}],"words":[{"word":"ignored","start":0,"end":1}]}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try TranscriptionModel.init("whisper-1", .{
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
    const openai_options = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"openai":{"include":["logprobs"],"language":"en","prompt":"context","temperature":0.5,"timestampGranularities":["word","segment"]}}
    , .{});
    const result = try model.transcriptionModel().doGenerate(io, arena_state.allocator(), &.{
        .audio = .{ .bytes = "RIFFaudio" },
        .media_type = "audio/x-wav",
        .provider_options = openai_options,
    }, null);

    try std.testing.expectEqualStrings("Hello world", result.text);
    try std.testing.expectEqualStrings("en", result.language.?);
    try std.testing.expectEqual(2.5, result.duration_in_seconds.?);
    try std.testing.expectEqual(1, result.segments.len);
    try std.testing.expectEqualStrings("Hello world", result.segments[0].text);
    try std.testing.expectEqualStrings("transcription-request", recordedHeader(result.response.headers.?, "x-request-id").?);

    const requests = server.recordedRequests();
    try std.testing.expectEqualStrings("/audio/transcriptions", requests[0].target);
    const content_type = recordedHeader(requests[0].headers, "content-type").?;
    try std.testing.expect(std.mem.startsWith(u8, content_type, "multipart/form-data; boundary=ai-zig-boundary-"));
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"model\"\r\n\r\nwhisper-1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"file\"; filename=\"audio.wav\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "Content-Type: audio/x-wav\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"response_format\"\r\n\r\nverbose_json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"include[]\"\r\n\r\nlogprobs\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"timestamp_granularities[]\"\r\n\r\nword\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI transcription response formats extensions and language map match upstream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("verbose_json", transcriptionResponseFormat("whisper-1"));
    try std.testing.expectEqualStrings("json", transcriptionResponseFormat("gpt-4o-transcribe"));
    try std.testing.expectEqualStrings("json", transcriptionResponseFormat("gpt-4o-mini-transcribe"));
    try std.testing.expectEqualStrings("verbose_json", transcriptionResponseFormat("custom-model"));
    try std.testing.expectEqualStrings("mp3", try mediaTypeToExtension(arena, "audio/mpeg"));
    try std.testing.expectEqualStrings("wav", try mediaTypeToExtension(arena, "audio/x-wav"));
    try std.testing.expectEqualStrings("ogg", try mediaTypeToExtension(arena, "audio/opus"));
    try std.testing.expectEqualStrings("m4a", try mediaTypeToExtension(arena, "audio/mp4"));
    try std.testing.expectEqualStrings("en", languageToIso6391("english").?);
    try std.testing.expectEqualStrings("cy", languageToIso6391("welsh").?);
    try std.testing.expectEqual(57, languages.len);
    try std.testing.expect(languageToIso6391("en") == null);
}

test "OpenAI transcription falls back to words but an empty segments array wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const words_response = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"text":"Hello world","words":[{"word":"Hello","start":0,"end":1},{"word":"world","start":1,"end":2}]}
    , .{});
    const words_result = try mapResponse(arena, words_response, 0, "whisper-1", &.{}, null);
    try std.testing.expectEqual(2, words_result.segments.len);
    try std.testing.expectEqualStrings("Hello", words_result.segments[0].text);
    try std.testing.expectEqual(1.0, words_result.segments[0].end_second);

    const empty_segments_response = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"text":"Hello world","segments":[],"words":[{"word":"ignored","start":0,"end":2}]}
    , .{});
    const empty_segments_result = try mapResponse(arena, empty_segments_response, 0, "whisper-1", &.{}, null);
    try std.testing.expectEqual(0, empty_segments_result.segments.len);
}
