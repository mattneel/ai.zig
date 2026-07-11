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
        .doStream = vDoStream,
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

    fn vDoStream(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.TranscriptionStreamOptions,
        diag: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionStreamResult {
        return fromRaw(raw).doStream(io, arena, options, diag);
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

    fn doStream(
        self: *TranscriptionModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.TranscriptionStreamOptions,
        diag: ?*provider.Diagnostics,
    ) provider.transcription_model.CallError!provider.TranscriptionStreamResult {
        if (!isRealtimeTranscriptionModelId(self.model_id)) {
            const functionality = try std.fmt.allocPrint(
                arena,
                "streaming transcription with {s}",
                .{self.model_id},
            );
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .unsupported_functionality = .{
                .message = functionality,
                .functionality = functionality,
            } });
            return error.UnsupportedFunctionalityError;
        }

        const openai_options = try parseTranscriptionOptions(
            arena,
            options.provider_options,
            self.config.provider_options_name,
            diag,
        );
        const warnings = try streamingWarnings(
            arena,
            options.provider_options,
            self.config.provider_options_name,
        );
        const headers = try self.resolveHeaders(arena, options.headers, diag);
        const protocols = try realtimeProtocols(arena, headers);
        const websocket_headers = try stripAuthorizationHeader(arena, headers);
        const http_url = try std.fmt.allocPrint(
            arena,
            "{s}/realtime?intent=transcription",
            .{self.config.base_url},
        );
        const websocket_url = provider_utils.websocket.toWebSocketUrl(arena, http_url) catch |err|
            return streamSetupFailure(arena, diag, http_url, err);
        const session_update = try buildRealtimeTranscriptionSession(
            arena,
            self.model_id,
            options.input_audio_format,
            openai_options,
        );
        const session_json = try provider_utils.stringifyJsonValueAlloc(arena, session_update);

        var socket = self.config.websocket_factory.connect(
            self.config.allocator,
            io,
            websocket_url,
            .{ .protocols = protocols, .headers = websocket_headers },
            diag,
        ) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.ConcurrencyUnavailable => {
                provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .unsupported_functionality = .{
                    .message = "OpenAI streaming transcription requires real std.Io concurrency",
                    .functionality = "streaming transcription WebSocket tasks",
                } });
                return error.UnsupportedFunctionalityError;
            },
            else => return streamSetupFailure(arena, diag, websocket_url, err),
        };
        errdefer socket.deinit();
        socket.sendText(session_json) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return streamSetupFailure(arena, diag, websocket_url, err),
        };

        const state = try arena.create(RealtimeTranscriptionStream);
        state.* = .{
            .gpa = self.config.allocator,
            .io = io,
            .socket = socket,
            .audio = options.audio,
            .url = websocket_url,
            .model_id = self.model_id,
            .language = if (openai_options) |settings| settings.language else null,
            .warnings = warnings,
            .include_raw_chunks = options.include_raw_chunks orelse false,
            .diag = diag,
            .scratch = .init(self.config.allocator),
        };
        state.audio_future = io.concurrent(RealtimeTranscriptionStream.pumpAudioEntry, .{state}) catch {
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .unsupported_functionality = .{
                .message = "OpenAI streaming transcription requires a concurrent audio pump",
                .functionality = "streaming transcription audio pump",
            } });
            return error.UnsupportedFunctionalityError;
        };

        return .{
            .request = .{ .body = session_update },
            .response = .{
                .timestamp_ms = currentTimeMillis(io),
                .model_id = self.model_id,
            },
            .stream = state.partStream(),
        };
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

const RealtimeTranscriptionStream = struct {
    const PumpResult = anyerror!void;

    gpa: Allocator,
    io: std.Io,
    socket: provider_utils.WebSocketLike,
    audio: provider.transcription_model.AudioStream,
    url: []const u8,
    model_id: []const u8,
    language: ?[]const u8,
    warnings: []const provider.Warning,
    include_raw_chunks: bool,
    diag: ?*provider.Diagnostics,
    scratch: std.heap.ArenaAllocator,
    audio_future: std.Io.Future(PumpResult) = undefined,
    pump_error_mutex: std.Io.Mutex = .init,
    pump_error: ?anyerror = null,
    audio_stopped: bool = false,
    started: bool = false,
    finished: bool = false,
    terminal_error_pending: bool = false,
    deinitialized: bool = false,
    pending: [2]provider.TranscriptionStreamPart = undefined,
    pending_index: u2 = 0,
    pending_len: u2 = 0,

    fn partStream(self: *RealtimeTranscriptionStream) provider.TranscriptionPartStream {
        return .{ .ctx = self, .vtable = &part_stream_vtable };
    }

    const part_stream_vtable: provider.transcription_model.PartStream.VTable = .{
        .next = vNext,
        .deinit = vDeinit,
    };

    fn fromRaw(raw: *anyopaque) *RealtimeTranscriptionStream {
        return @ptrCast(@alignCast(raw));
    }

    fn vNext(
        raw: *anyopaque,
        io: std.Io,
    ) provider.transcription_model.NextError!?provider.TranscriptionStreamPart {
        return fromRaw(raw).next(io);
    }

    fn vDeinit(raw: *anyopaque, io: std.Io) void {
        fromRaw(raw).deinit(io);
    }

    fn next(
        self: *RealtimeTranscriptionStream,
        io: std.Io,
    ) provider.transcription_model.NextError!?provider.TranscriptionStreamPart {
        if (self.terminal_error_pending) {
            self.terminal_error_pending = false;
            return error.APICallError;
        }
        if (self.deinitialized or self.finished and self.pending_index == self.pending_len) return null;
        if (!self.started) {
            self.started = true;
            return .{ .stream_start = .{ .warnings = self.warnings } };
        }
        if (self.pending_index < self.pending_len) {
            const part = self.pending[self.pending_index];
            self.pending_index += 1;
            return part;
        }

        self.pending_index = 0;
        self.pending_len = 0;
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();

        while (true) {
            if (self.takePumpError()) |err| return self.mapStreamFailure(scratch, err);
            const message = self.socket.receive(io) catch |err| return self.mapStreamFailure(scratch, err);
            const received = message orelse {
                if (self.takePumpError()) |err| return self.mapStreamFailure(scratch, err);
                self.finished = true;
                return null;
            };
            const raw = std.json.parseFromSliceLeaky(std.json.Value, scratch, received.payload, .{
                .allocate = .alloc_always,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (raw != .object) {
                if (self.include_raw_chunks) return .{ .raw = .{ .raw_value = raw } };
                continue;
            }
            const event_type = jsonString(raw.object, "type") orelse {
                if (self.include_raw_chunks) return .{ .raw = .{ .raw_value = raw } };
                continue;
            };

            if (std.mem.eql(u8, event_type, "conversation.item.input_audio_transcription.delta")) {
                const normalized: provider.TranscriptionStreamPart = .{ .transcript_delta = .{
                    .id = jsonString(raw.object, "item_id"),
                    .delta = jsonString(raw.object, "delta") orelse "",
                } };
                if (self.include_raw_chunks) {
                    self.pushPending(normalized);
                    return .{ .raw = .{ .raw_value = raw } };
                }
                return normalized;
            }

            if (std.mem.eql(u8, event_type, "conversation.item.input_audio_transcription.completed")) {
                const item_id = jsonString(raw.object, "item_id");
                const text = jsonString(raw.object, "transcript") orelse "";
                const final_part: provider.TranscriptionStreamPart = .{ .transcript_final = .{
                    .id = item_id,
                    .text = text,
                } };
                const finish_part: provider.TranscriptionStreamPart = .{ .finish = .{
                    .text = text,
                    .segments = &.{},
                    .language = self.language,
                } };
                self.finished = true;
                self.stopAudioPump();
                self.socket.close(1000, "") catch {};
                if (self.include_raw_chunks) {
                    self.pushPending(final_part);
                    self.pushPending(finish_part);
                    return .{ .raw = .{ .raw_value = raw } };
                }
                self.pushPending(finish_part);
                return final_part;
            }

            if (std.mem.eql(u8, event_type, "error")) {
                const message_text = if (raw.object.get("error")) |error_value|
                    if (error_value == .object) jsonString(error_value.object, "message") orelse "OpenAI realtime error" else "OpenAI realtime error"
                else
                    "OpenAI realtime error";
                provider.Diagnostics.set(self.diag, diagnosticAllocator(self.diag, scratch), .{ .api_call = .{
                    .message = message_text,
                    .url = self.url,
                    .is_retryable = false,
                    .data_json = received.payload,
                } });
                self.finished = true;
                self.stopAudioPump();
                self.socket.close(1011, "server transcription error") catch {};
                if (self.include_raw_chunks) {
                    self.terminal_error_pending = true;
                    return .{ .raw = .{ .raw_value = raw } };
                }
                return error.APICallError;
            }

            if (self.include_raw_chunks) return .{ .raw = .{ .raw_value = raw } };
        }
    }

    fn pushPending(self: *RealtimeTranscriptionStream, part: provider.TranscriptionStreamPart) void {
        std.debug.assert(self.pending_len < self.pending.len);
        self.pending[self.pending_len] = part;
        self.pending_len += 1;
    }

    fn mapStreamFailure(
        self: *RealtimeTranscriptionStream,
        arena: Allocator,
        err: anyerror,
    ) provider.transcription_model.NextError {
        return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => {
                self.finished = true;
                self.stopAudioPump();
                self.socket.close(1011, "transcription stream failed") catch {};
                return error.OutOfMemory;
            },
            else => {
                self.finished = true;
                self.stopAudioPump();
                self.socket.close(1011, "transcription stream failed") catch {};
                const message = std.fmt.allocPrint(
                    arena,
                    "OpenAI realtime transcription failed: {s}",
                    .{@errorName(err)},
                ) catch return error.OutOfMemory;
                provider.Diagnostics.set(self.diag, diagnosticAllocator(self.diag, arena), .{ .api_call = .{
                    .message = message,
                    .url = self.url,
                    .is_retryable = false,
                    .cause_message = @errorName(err),
                } });
                return error.APICallError;
            },
        };
    }

    fn takePumpError(self: *RealtimeTranscriptionStream) ?anyerror {
        self.pump_error_mutex.lockUncancelable(self.io);
        defer self.pump_error_mutex.unlock(self.io);
        const result = self.pump_error;
        self.pump_error = null;
        return result;
    }

    fn setPumpError(self: *RealtimeTranscriptionStream, err: anyerror) void {
        self.pump_error_mutex.lockUncancelable(self.io);
        defer self.pump_error_mutex.unlock(self.io);
        if (self.pump_error == null) self.pump_error = err;
    }

    fn pumpAudioEntry(self: *RealtimeTranscriptionStream) PumpResult {
        self.pumpAudio() catch |err| {
            if (err != error.Canceled) {
                self.setPumpError(err);
                self.socket.close(1011, "audio input failed") catch {};
            }
            return err;
        };
    }

    fn pumpAudio(self: *RealtimeTranscriptionStream) anyerror!void {
        var chunk_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer chunk_arena.deinit();
        while (try self.audio.next(self.io)) |chunk| {
            _ = chunk_arena.reset(.retain_capacity);
            const arena = chunk_arena.allocator();
            const encoded = switch (chunk) {
                .bytes => |bytes| try provider_utils.encodeBase64(arena, bytes),
                .base64 => |base64| base64,
            };
            var object: std.json.ObjectMap = .empty;
            try object.put(arena, "type", .{ .string = "input_audio_buffer.append" });
            try object.put(arena, "audio", .{ .string = encoded });
            const json = try provider_utils.stringifyJsonValueAlloc(arena, .{ .object = object });
            try self.socket.sendText(json);
        }
        try self.socket.sendText("{\"type\":\"input_audio_buffer.commit\"}");
    }

    fn deinit(self: *RealtimeTranscriptionStream, io: std.Io) void {
        _ = io;
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.stopAudioPump();
        self.socket.close(1000, "") catch {};
        self.socket.deinit();
        self.scratch.deinit();
    }

    fn stopAudioPump(self: *RealtimeTranscriptionStream) void {
        if (self.audio_stopped) return;
        self.audio_stopped = true;
        _ = self.audio_future.cancel(self.io) catch {};
        self.audio.deinit(self.io);
    }
};

const TranscriptionOptions = struct {
    include: ?[]const []const u8 = null,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    temperature: ?f64 = 0,
    timestamp_granularities: ?[]const []const u8 = &.{"segment"},
    streaming: ?StreamingOptions = null,
};

const StreamingOptions = struct {
    delay: ?[]const u8 = null,
    include: ?[]const []const u8 = null,
};

fn buildRealtimeTranscriptionSession(
    arena: Allocator,
    model_id: []const u8,
    format: provider.transcription_model.InputAudioFormat,
    maybe_options: ?TranscriptionOptions,
) Allocator.Error!std.json.Value {
    var format_object: std.json.ObjectMap = .empty;
    try format_object.put(arena, "type", .{ .string = format.type });
    if (format.rate) |rate| try format_object.put(arena, "rate", .{ .integer = rate });

    var transcription: std.json.ObjectMap = .empty;
    try transcription.put(arena, "model", .{ .string = model_id });
    if (maybe_options) |options| {
        if (options.language) |language| try transcription.put(arena, "language", .{ .string = language });
        if (options.streaming) |streaming| {
            if (streaming.delay) |delay| try transcription.put(arena, "delay", .{ .string = delay });
        }
    }

    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "format", .{ .object = format_object });
    try input.put(arena, "transcription", .{ .object = transcription });
    try input.put(arena, "turn_detection", .null);
    var audio: std.json.ObjectMap = .empty;
    try audio.put(arena, "input", .{ .object = input });
    var session: std.json.ObjectMap = .empty;
    try session.put(arena, "type", .{ .string = "transcription" });
    try session.put(arena, "audio", .{ .object = audio });
    if (maybe_options) |options| {
        if (options.streaming) |streaming| {
            if (streaming.include) |include| {
                var array = std.json.Array.init(arena);
                for (include) |item| try array.append(.{ .string = item });
                try session.put(arena, "include", .{ .array = array });
            }
        }
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "type", .{ .string = "session.update" });
    try root.put(arena, "session", .{ .object = session });
    return .{ .object = root };
}

fn realtimeProtocols(arena: Allocator, headers: []const provider.Header) Allocator.Error![]const []const u8 {
    const authorization = recordedHeader(headers, "authorization");
    const token = if (authorization) |value|
        if (std.mem.startsWith(u8, value, "Bearer ")) value["Bearer ".len..] else null
    else
        null;
    const protocols = try arena.alloc([]const u8, if (token == null) 1 else 2);
    protocols[0] = "realtime";
    if (token) |value| protocols[1] = try std.fmt.allocPrint(arena, "openai-insecure-api-key.{s}", .{value});
    return protocols;
}

fn stripAuthorizationHeader(arena: Allocator, headers: []const provider.Header) Allocator.Error![]const provider.Header {
    const result = try arena.alloc(provider.Header, headers.len);
    var count: usize = 0;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        result[count] = header;
        count += 1;
    }
    return result[0..count];
}

fn streamingWarnings(
    arena: Allocator,
    provider_options: ?provider.ProviderOptions,
    namespace: []const u8,
) Allocator.Error![]const provider.Warning {
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    const root = provider_options orelse return &.{};
    if (root != .object) return &.{};

    for ([_][]const u8{ "include", "prompt", "temperature", "timestampGranularities" }) |field| {
        var present_namespace: ?[]const u8 = null;
        const names = [_][]const u8{ "openai", namespace };
        for (names) |name| {
            if (present_namespace != null and std.mem.eql(u8, name, "openai")) continue;
            const maybe_value = root.object.get(name);
            const value = maybe_value orelse continue;
            if (value == .object and value.object.get(field) != null and value.object.get(field).? != .null) {
                present_namespace = name;
            }
        }
        const selected_namespace = present_namespace orelse continue;
        try warnings.append(arena, .{ .unsupported = .{
            .feature = try std.fmt.allocPrint(
                arena,
                "providerOptions.{s}.{s}",
                .{ selected_namespace, field },
            ),
            .details = try std.fmt.allocPrint(
                arena,
                "OpenAI streaming transcription does not support {s}.",
                .{field},
            ),
        } });
    }
    return warnings.toOwnedSlice(arena);
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn streamSetupFailure(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    url: []const u8,
    cause: anyerror,
) provider.Error {
    const message = std.fmt.allocPrint(
        arena,
        "OpenAI realtime transcription setup failed: {s}",
        .{@errorName(cause)},
    ) catch "OpenAI realtime transcription setup failed";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .is_retryable = false,
        .cause_message = @errorName(cause),
    } });
    return error.APICallError;
}

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
    if (value.object.get("streaming")) |item| {
        settings.streaming = try optionalStreamingOptions(arena, item, diag);
    }
}

fn optionalStreamingOptions(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.transcription_model.CallError!?StreamingOptions {
    if (value == .null) return null;
    if (value != .object) return invalidOptionField(arena, diag, "streaming", "must be an object");
    var result: StreamingOptions = .{};
    if (value.object.get("delay")) |item| {
        const delay = try optionalString(arena, item, "streaming.delay", diag);
        if (delay) |selected| {
            const allowed = [_][]const u8{ "minimal", "low", "medium", "high", "xhigh" };
            var supported = false;
            for (allowed) |candidate| if (std.mem.eql(u8, selected, candidate)) {
                supported = true;
                break;
            };
            if (!supported) return invalidOptionField(arena, diag, "streaming.delay", "contains an unsupported value");
        }
        result.delay = delay;
    }
    if (value.object.get("include")) |item| {
        result.include = try optionalStringArray(arena, item, "streaming.include", null, diag);
    }
    return result;
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

const FakeRealtimeSocket = struct {
    allocator: Allocator,
    io: std.Io,
    messages: []const []const u8,
    message_index: usize = 0,
    sent: std.ArrayList([]u8) = .empty,
    mutex: std.Io.Mutex = .init,
    commit_sent: std.Io.Event = .unset,
    connected_url: ?[]const u8 = null,
    connected_protocols: []const []const u8 = &.{},
    connected_headers: []const provider.Header = &.{},
    closed: bool = false,

    fn factory(self: *FakeRealtimeSocket) provider_utils.WebSocketFactory {
        return .{ .ctx = self, .vtable = &factory_vtable };
    }

    fn deinit(self: *FakeRealtimeSocket) void {
        for (self.sent.items) |message| self.allocator.free(message);
        self.sent.deinit(self.allocator);
    }

    const factory_vtable: provider_utils.websocket.WebSocketFactoryVTable = .{ .connect = connect };
    const socket_vtable: provider_utils.websocket.WebSocketLikeVTable = .{
        .send = send,
        .receive = receive,
        .close = close,
        .negotiated_protocol = negotiatedProtocol,
        .close_info = closeInfo,
        .deinit = deinitSocket,
    };

    fn connect(
        raw: ?*anyopaque,
        _: Allocator,
        _: std.Io,
        url: []const u8,
        options: provider_utils.WebSocketConnectOptions,
        _: ?*provider.Diagnostics,
    ) anyerror!provider_utils.WebSocketLike {
        const self: *FakeRealtimeSocket = @ptrCast(@alignCast(raw.?));
        self.connected_url = url;
        self.connected_protocols = options.protocols;
        self.connected_headers = options.headers;
        return .{ .ctx = self, .vtable = &socket_vtable };
    }

    fn fromRaw(raw: *anyopaque) *FakeRealtimeSocket {
        return @ptrCast(@alignCast(raw));
    }

    fn send(raw: *anyopaque, _: provider_utils.WebSocketMessageKind, payload: []const u8) anyerror!void {
        const self = fromRaw(raw);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.sent.append(self.allocator, try self.allocator.dupe(u8, payload));
        if (std.mem.indexOf(u8, payload, "input_audio_buffer.commit") != null) {
            self.commit_sent.set(self.io);
        }
    }

    fn receive(raw: *anyopaque, _: std.Io) anyerror!?provider_utils.WebSocketMessage {
        const self = fromRaw(raw);
        if (self.message_index == self.messages.len) return null;
        defer self.message_index += 1;
        return .{ .kind = .text, .payload = self.messages[self.message_index] };
    }

    fn close(raw: *anyopaque, _: u16, _: []const u8) anyerror!void {
        fromRaw(raw).closed = true;
    }

    fn negotiatedProtocol(_: *const anyopaque) ?[]const u8 {
        return "realtime";
    }

    fn closeInfo(_: *const anyopaque) ?provider_utils.websocket.CloseInfo {
        return null;
    }

    fn deinitSocket(_: *anyopaque) void {}
};

const FiniteAudioStream = struct {
    chunks: []const provider.BinaryData,
    index: usize = 0,
    deinitialized: bool = false,

    fn stream(self: *FiniteAudioStream) provider.transcription_model.AudioStream {
        return .{ .ctx = self, .vtable = &.{ .next = next, .deinit = deinit } };
    }

    fn next(raw: *anyopaque, _: std.Io) provider.transcription_model.NextError!?provider.BinaryData {
        const self: *FiniteAudioStream = @ptrCast(@alignCast(raw));
        if (self.index == self.chunks.len) return null;
        defer self.index += 1;
        return self.chunks[self.index];
    }

    fn deinit(raw: *anyopaque, _: std.Io) void {
        const self: *FiniteAudioStream = @ptrCast(@alignCast(raw));
        self.deinitialized = true;
    }
};

const DummyRealtimeHttpTransport = struct {
    var marker: u8 = 0;

    fn request(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: provider_utils.RequestSpec,
        _: ?*provider.Diagnostics,
    ) provider_utils.RequestError!provider_utils.Response {
        return error.APICallError;
    }
};

fn testRealtimeTranscriptionModel(
    allocator: Allocator,
    socket: *FakeRealtimeSocket,
) !TranscriptionModel {
    return TranscriptionModel.init("gpt-realtime-whisper", .{
        .allocator = allocator,
        .base_url = "https://api.openai.com/v1",
        .api_key = "test-api-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = .{ .ctx = &DummyRealtimeHttpTransport.marker, .vtable = &.{
            .request = DummyRealtimeHttpTransport.request,
        } },
        .websocket_factory = socket.factory(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
}

test "OpenAI realtime whisper streams audio and maps transcript events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const messages = [_][]const u8{
        "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"item_id\":\"item-1\",\"delta\":\"Hel\"}",
        "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-1\",\"transcript\":\"Hello\"}",
    };
    var socket: FakeRealtimeSocket = .{ .allocator = allocator, .io = io, .messages = &messages };
    defer socket.deinit();

    var concrete = try testRealtimeTranscriptionModel(allocator, &socket);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"openai\":{\"language\":\"en\",\"prompt\":\"ignored\",\"temperature\":0.5,\"streaming\":{\"delay\":\"low\",\"include\":[\"item.input_audio_transcription.logprobs\"]}}}",
        .{},
    );
    const chunks = [_]provider.BinaryData{.{ .bytes = &.{ 1, 2, 3 } }};
    var audio: FiniteAudioStream = .{ .chunks = &chunks };

    var result = try concrete.transcriptionModel().doStream(io, arena, &.{
        .audio = audio.stream(),
        .input_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
        .provider_options = provider_options,
        .include_raw_chunks = true,
    }, null);
    defer result.stream.deinit(io);

    try std.testing.expectEqualStrings(
        "wss://api.openai.com/v1/realtime?intent=transcription",
        socket.connected_url.?,
    );
    try std.testing.expectEqualStrings("realtime", socket.connected_protocols[0]);
    try std.testing.expectEqualStrings("openai-insecure-api-key.test-api-key", socket.connected_protocols[1]);
    try std.testing.expect(recordedHeader(socket.connected_headers, "authorization") == null);
    try std.testing.expectEqualStrings(
        "gpt-realtime-whisper",
        result.request.?.body.?.object.get("session").?.object.get("audio").?.object.get("input").?.object.get("transcription").?.object.get("model").?.string,
    );

    const start = (try result.stream.next(io)).?.stream_start;
    try std.testing.expectEqual(2, start.warnings.len);
    try std.testing.expect((try result.stream.next(io)).? == .raw);
    try std.testing.expectEqualStrings("Hel", (try result.stream.next(io)).?.transcript_delta.delta);
    try std.testing.expect((try result.stream.next(io)).? == .raw);
    try std.testing.expectEqualStrings("Hello", (try result.stream.next(io)).?.transcript_final.text);
    const finish = (try result.stream.next(io)).?.finish;
    try std.testing.expectEqualStrings("Hello", finish.text);
    try std.testing.expectEqualStrings("en", finish.language.?);
    try std.testing.expectEqual(null, try result.stream.next(io));

    try socket.commit_sent.wait(io);
    socket.mutex.lockUncancelable(io);
    defer socket.mutex.unlock(io);
    try std.testing.expectEqual(3, socket.sent.items.len);
    try std.testing.expect(std.mem.indexOf(u8, socket.sent.items[0], "\"type\":\"session.update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, socket.sent.items[1], "\"audio\":\"AQID\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, socket.sent.items[2], "input_audio_buffer.commit") != null);
}

test "OpenAI realtime whisper error is terminal and preserves raw-before-error ordering" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const messages = [_][]const u8{
        "{\"type\":\"error\",\"error\":{\"message\":\"bad audio\"}}",
    };
    var socket: FakeRealtimeSocket = .{ .allocator = allocator, .io = io, .messages = &messages };
    defer socket.deinit();
    var concrete = try testRealtimeTranscriptionModel(allocator, &socket);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var audio: FiniteAudioStream = .{ .chunks = &.{} };
    var result = try concrete.transcriptionModel().doStream(io, arena_state.allocator(), &.{
        .audio = audio.stream(),
        .input_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
        .include_raw_chunks = true,
    }, null);
    defer result.stream.deinit(io);

    try std.testing.expect((try result.stream.next(io)).? == .stream_start);
    try std.testing.expect((try result.stream.next(io)).? == .raw);
    try std.testing.expectError(error.APICallError, result.stream.next(io));
    try std.testing.expectEqual(null, try result.stream.next(io));
    try std.testing.expect(socket.closed);
    try std.testing.expect(audio.deinitialized);
}

test "OpenAI realtime whisper deinit cancels a pending audio pump" {
    const BlockingAudio = struct {
        io: std.Io,
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        deinitialized: bool = false,

        fn stream(self: *@This()) provider.transcription_model.AudioStream {
            return .{ .ctx = self, .vtable = &.{ .next = next, .deinit = deinit } };
        }
        fn next(raw: *anyopaque, io: std.Io) provider.transcription_model.NextError!?provider.BinaryData {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.set(self.io);
            try self.release.wait(io);
            return null;
        }
        fn deinit(raw: *anyopaque, _: std.Io) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.deinitialized = true;
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var socket: FakeRealtimeSocket = .{ .allocator = allocator, .io = io, .messages = &.{} };
    defer socket.deinit();
    var concrete = try testRealtimeTranscriptionModel(allocator, &socket);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var audio: BlockingAudio = .{ .io = io };
    var result = try concrete.transcriptionModel().doStream(io, arena_state.allocator(), &.{
        .audio = audio.stream(),
        .input_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
    }, null);
    audio.started.waitUncancelable(io);
    result.stream.deinit(io);

    try std.testing.expect(audio.deinitialized);
    try std.testing.expect(socket.closed);
}
