//! OpenAI Realtime API model V4 codec and ephemeral client-secret flow.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");

const Allocator = std.mem.Allocator;
const max_provider_id_len = 1024;

pub const RealtimeModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!RealtimeModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI realtime model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");

        var result: RealtimeModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.realtime", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn realtimeModel(self: *RealtimeModel) provider.RealtimeModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.RealtimeModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .doCreateClientSecret = vDoCreateClientSecret,
        .getWebSocketConfig = vGetWebSocketConfig,
        .parseServerEvent = vParseServerEvent,
        .serializeClientEvent = vSerializeClientEvent,
        .buildSessionConfig = vBuildSessionConfig,
        .getHealthCheckResponse = null,
    };

    fn fromRaw(raw: *anyopaque) *RealtimeModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        return self.provider_id_buffer[0..self.provider_id_len];
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vDoCreateClientSecret(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.ClientSecretOptions,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.ClientSecretResult {
        return fromRaw(raw).doCreateClientSecret(io, arena, options, diag);
    }

    fn vGetWebSocketConfig(
        raw: *anyopaque,
        arena: Allocator,
        options: *const provider.WebSocketOptions,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.WebSocketConfig {
        return fromRaw(raw).getWebSocketConfig(arena, options, diag);
    }

    fn vParseServerEvent(
        raw: *anyopaque,
        arena: Allocator,
        event: *const provider.JsonValue,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError![]const provider.ServerEvent {
        return fromRaw(raw).parseServerEvent(arena, event, diag);
    }

    fn vSerializeClientEvent(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        event: *const provider.ClientEvent,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.JsonValue {
        return fromRaw(raw).serializeClientEvent(io, arena, event, diag);
    }

    fn vBuildSessionConfig(
        raw: *anyopaque,
        arena: Allocator,
        session_config: *const provider.SessionConfig,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.JsonValue {
        return fromRaw(raw).buildSessionConfig(arena, session_config, diag);
    }

    fn doCreateClientSecret(
        self: *const RealtimeModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.ClientSecretOptions,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.ClientSecretResult {
        const session = if (options.session_config) |session_config|
            try self.buildSessionConfig(arena, &session_config, diag)
        else blk: {
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "type", "realtime");
            try putString(&object, arena, "model", self.model_id);
            break :blk provider.JsonValue{ .object = object };
        };

        var body: std.json.ObjectMap = .empty;
        try body.put(arena, "session", session);
        if (options.expires_after_seconds) |seconds| {
            var expires_after: std.json.ObjectMap = .empty;
            try putString(&expires_after, arena, "anchor", "created_at");
            try expires_after.put(
                arena,
                "seconds",
                try unsignedJsonInteger(arena, diag, "expiresAfterSeconds", seconds),
            );
            try body.put(arena, "expires_after", .{ .object = expires_after });
        }

        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, .{ .object = body });
        const url = try std.fmt.allocPrint(arena, "{s}/realtime/client_secrets", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, diag);
        const result = try provider_utils.postJsonToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );

        if (result.value != .object) {
            return invalidResponse(arena, diag, "OpenAI realtime client-secret response must be an object");
        }
        const token_value = result.value.object.get("value") orelse
            return invalidResponse(arena, diag, "OpenAI realtime client-secret response value is missing");
        if (token_value != .string) {
            return invalidResponse(arena, diag, "OpenAI realtime client-secret response value must be a string");
        }

        const expires_at = if (result.value.object.get("expires_at")) |value|
            try optionalResponseU64(arena, diag, "expires_at", value)
        else
            null;
        return .{
            .token = token_value.string,
            .url = try self.realtimeWebSocketUrl(arena, diag),
            .expires_at = expires_at,
        };
    }

    fn getWebSocketConfig(
        _: *const RealtimeModel,
        arena: Allocator,
        options: *const provider.WebSocketOptions,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.WebSocketConfig {
        const protocols = try arena.alloc([]const u8, 2);
        protocols[0] = try arena.dupe(u8, "realtime");
        protocols[1] = try std.fmt.allocPrint(arena, "openai-insecure-api-key.{s}", .{options.token});
        return .{
            .url = try arena.dupe(u8, options.url),
            .protocols = protocols,
        };
    }

    fn parseServerEvent(
        _: *const RealtimeModel,
        arena: Allocator,
        event: *const provider.JsonValue,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError![]const provider.ServerEvent {
        const raw = try provider_utils.cloneJsonValue(arena, event.*);
        const object = if (raw == .object) raw.object else std.json.ObjectMap.empty;
        const event_type = optionalString(object, "type") orelse "";
        const parsed: provider.ServerEvent = if (std.mem.eql(u8, event_type, "session.created"))
            .{ .session_created = .{
                .session_id = optionalNestedString(object, "session", "id"),
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "session.updated"))
            .{ .session_updated = .{ .raw = raw } }
        else if (std.mem.eql(u8, event_type, "input_audio_buffer.speech_started"))
            .{ .speech_started = .{ .item_id = optionalString(object, "item_id"), .raw = raw } }
        else if (std.mem.eql(u8, event_type, "input_audio_buffer.speech_stopped"))
            .{ .speech_stopped = .{ .item_id = optionalString(object, "item_id"), .raw = raw } }
        else if (std.mem.eql(u8, event_type, "input_audio_buffer.committed"))
            .{ .audio_committed = .{
                .item_id = optionalString(object, "item_id"),
                .previous_item_id = optionalString(object, "previous_item_id"),
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "conversation.item.added"))
            .{ .conversation_item_added = .{
                .item_id = optionalNestedString(object, "item", "id") orelse optionalString(object, "item_id") orelse "",
                .item = object.get("item") orelse .null,
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "conversation.item.input_audio_transcription.completed"))
            .{ .input_transcription_completed = .{
                .item_id = optionalString(object, "item_id") orelse "",
                .transcript = optionalString(object, "transcript") orelse "",
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "response.created"))
            .{ .response_created = .{
                .response_id = optionalNestedString(object, "response", "id") orelse optionalString(object, "response_id") orelse "",
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "response.done"))
            .{ .response_done = .{
                .response_id = optionalNestedString(object, "response", "id") orelse optionalString(object, "response_id") orelse "",
                .status = optionalNestedString(object, "response", "status") orelse "completed",
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "response.output_item.added"))
            itemEvent(.output_item_added, object, raw)
        else if (std.mem.eql(u8, event_type, "response.output_item.done"))
            itemEvent(.output_item_done, object, raw)
        else if (std.mem.eql(u8, event_type, "response.content_part.added"))
            itemEvent(.content_part_added, object, raw)
        else if (std.mem.eql(u8, event_type, "response.content_part.done"))
            itemEvent(.content_part_done, object, raw)
        else if (std.mem.eql(u8, event_type, "response.output_audio.delta"))
            deltaEvent(.audio_delta, object, raw)
        else if (std.mem.eql(u8, event_type, "response.output_audio.done"))
            itemEvent(.audio_done, object, raw)
        else if (std.mem.eql(u8, event_type, "response.output_audio_transcript.delta"))
            deltaEvent(.audio_transcript_delta, object, raw)
        else if (std.mem.eql(u8, event_type, "response.output_audio_transcript.done"))
            .{ .audio_transcript_done = .{
                .response_id = optionalString(object, "response_id") orelse "",
                .item_id = optionalString(object, "item_id") orelse "",
                .transcript = optionalString(object, "transcript"),
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "response.output_text.delta"))
            deltaEvent(.text_delta, object, raw)
        else if (std.mem.eql(u8, event_type, "response.output_text.done"))
            .{ .text_done = .{
                .response_id = optionalString(object, "response_id") orelse "",
                .item_id = optionalString(object, "item_id") orelse "",
                .text = optionalString(object, "text"),
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta"))
            .{ .function_call_arguments_delta = .{
                .response_id = optionalString(object, "response_id") orelse "",
                .item_id = optionalString(object, "item_id") orelse "",
                .call_id = optionalString(object, "call_id") orelse "",
                .delta = optionalString(object, "delta") orelse "",
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done"))
            .{ .function_call_arguments_done = .{
                .response_id = optionalString(object, "response_id") orelse "",
                .item_id = optionalString(object, "item_id") orelse "",
                .call_id = optionalString(object, "call_id") orelse "",
                .name = optionalString(object, "name") orelse "",
                .arguments = optionalString(object, "arguments") orelse "",
                .raw = raw,
            } }
        else if (std.mem.eql(u8, event_type, "error"))
            .{ .err = .{
                .message = optionalNestedString(object, "error", "message") orelse optionalString(object, "message") orelse "Unknown error",
                .code = optionalNestedString(object, "error", "code") orelse optionalString(object, "code"),
                .raw = raw,
            } }
        else
            .{ .custom = .{ .raw_type = event_type, .raw = raw } };

        const events = try arena.alloc(provider.ServerEvent, 1);
        events[0] = parsed;
        return events;
    }

    fn serializeClientEvent(
        self: *const RealtimeModel,
        _: std.Io,
        arena: Allocator,
        event: *const provider.ClientEvent,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.JsonValue {
        var root: std.json.ObjectMap = .empty;
        switch (event.*) {
            .session_update => |payload| {
                try putString(&root, arena, "type", "session.update");
                try root.put(arena, "session", try self.buildSessionConfig(arena, &payload.config, diag));
            },
            .input_audio_append => |payload| {
                try putString(&root, arena, "type", "input_audio_buffer.append");
                try putString(&root, arena, "audio", payload.audio);
            },
            .input_audio_commit => {
                try putString(&root, arena, "type", "input_audio_buffer.commit");
            },
            .input_audio_clear => {
                try putString(&root, arena, "type", "input_audio_buffer.clear");
            },
            .conversation_item_create => |payload| {
                try putString(&root, arena, "type", "conversation.item.create");
                var item: std.json.ObjectMap = .empty;
                switch (payload.item) {
                    .text_message => |message| {
                        try putString(&item, arena, "type", "message");
                        try putString(&item, arena, "role", @tagName(message.role));
                        var content = std.json.Array.init(arena);
                        var part: std.json.ObjectMap = .empty;
                        try putString(&part, arena, "type", "input_text");
                        try putString(&part, arena, "text", message.text);
                        try content.append(.{ .object = part });
                        try item.put(arena, "content", .{ .array = content });
                    },
                    .audio_message => |message| {
                        try putString(&item, arena, "type", "message");
                        try putString(&item, arena, "role", @tagName(message.role));
                        var content = std.json.Array.init(arena);
                        var part: std.json.ObjectMap = .empty;
                        try putString(&part, arena, "type", "input_audio");
                        try putString(&part, arena, "audio", message.audio);
                        try content.append(.{ .object = part });
                        try item.put(arena, "content", .{ .array = content });
                    },
                    .function_call_output => |output| {
                        try putString(&item, arena, "type", "function_call_output");
                        try putString(&item, arena, "call_id", output.call_id);
                        try putString(&item, arena, "output", output.output);
                    },
                }
                try root.put(arena, "item", .{ .object = item });
            },
            .conversation_item_truncate => |payload| {
                try putString(&root, arena, "type", "conversation.item.truncate");
                try putString(&root, arena, "item_id", payload.item_id);
                try root.put(arena, "content_index", .{ .integer = payload.content_index });
                try root.put(
                    arena,
                    "audio_end_ms",
                    try unsignedJsonInteger(arena, diag, "audioEndMs", payload.audio_end_ms),
                );
            },
            .response_create => |payload| {
                try putString(&root, arena, "type", "response.create");
                if (payload.options) |options| {
                    var response: std.json.ObjectMap = .empty;
                    if (options.modalities) |modalities| {
                        try response.put(arena, "output_modalities", try stringArray(arena, modalities));
                    }
                    if (options.instructions) |instructions| try putString(&response, arena, "instructions", instructions);
                    if (options.metadata) |metadata| {
                        try response.put(arena, "metadata", try provider_utils.cloneJsonValue(arena, metadata));
                    }
                    try root.put(arena, "response", .{ .object = response });
                }
            },
            .response_cancel => {
                try putString(&root, arena, "type", "response.cancel");
            },
        }
        return .{ .object = root };
    }

    fn buildSessionConfig(
        self: *const RealtimeModel,
        arena: Allocator,
        session_config: *const provider.SessionConfig,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.JsonValue {
        var session: std.json.ObjectMap = .empty;
        try putString(&session, arena, "type", "realtime");
        try putString(&session, arena, "model", self.model_id);

        if (session_config.instructions) |instructions| try putString(&session, arena, "instructions", instructions);
        if (session_config.output_modalities) |modalities| {
            var array = std.json.Array.init(arena);
            for (modalities) |modality| try array.append(.{ .string = try arena.dupe(u8, @tagName(modality)) });
            try session.put(arena, "output_modalities", .{ .array = array });
        }

        var audio: std.json.ObjectMap = .empty;
        if (session_config.input_audio_format != null or
            session_config.input_audio_transcription != null or
            session_config.turn_detection != null)
        {
            var input: std.json.ObjectMap = .empty;
            if (session_config.input_audio_format) |format| {
                try input.put(arena, "format", try audioFormat(arena, format));
            }
            if (session_config.turn_detection) |turn_detection| {
                if (turn_detection.type == .disabled) {
                    try input.put(arena, "turn_detection", .null);
                } else {
                    var mapped: std.json.ObjectMap = .empty;
                    try putString(
                        &mapped,
                        arena,
                        "type",
                        if (turn_detection.type == .server_vad) "server_vad" else "semantic_vad",
                    );
                    if (turn_detection.threshold) |threshold| try mapped.put(arena, "threshold", .{ .float = threshold });
                    if (turn_detection.silence_duration_ms) |duration| {
                        try mapped.put(
                            arena,
                            "silence_duration_ms",
                            try unsignedJsonInteger(arena, diag, "silenceDurationMs", duration),
                        );
                    }
                    if (turn_detection.prefix_padding_ms) |duration| {
                        try mapped.put(
                            arena,
                            "prefix_padding_ms",
                            try unsignedJsonInteger(arena, diag, "prefixPaddingMs", duration),
                        );
                    }
                    try input.put(arena, "turn_detection", .{ .object = mapped });
                }
            }
            if (session_config.input_audio_transcription) |transcription| {
                var mapped: std.json.ObjectMap = .empty;
                try putString(&mapped, arena, "model", transcription.model orelse "gpt-realtime-whisper");
                if (transcription.language) |language| try putString(&mapped, arena, "language", language);
                if (transcription.prompt) |prompt| try putString(&mapped, arena, "prompt", prompt);
                try input.put(arena, "transcription", .{ .object = mapped });
            }
            try audio.put(arena, "input", .{ .object = input });
        }

        if (session_config.output_audio_format != null or session_config.voice != null) {
            var output: std.json.ObjectMap = .empty;
            if (session_config.output_audio_format) |format| {
                try output.put(arena, "format", try audioFormat(arena, format));
            }
            if (session_config.voice) |voice| try putString(&output, arena, "voice", voice);
            try audio.put(arena, "output", .{ .object = output });
        }
        if (audio.count() != 0) try session.put(arena, "audio", .{ .object = audio });

        if (session_config.tools) |tools| if (tools.len != 0) {
            var mapped_tools = std.json.Array.init(arena);
            for (tools) |tool| switch (tool) {
                .function => |definition| {
                    var mapped: std.json.ObjectMap = .empty;
                    try putString(&mapped, arena, "type", "function");
                    try putString(&mapped, arena, "name", definition.name);
                    if (definition.description) |description| try putString(&mapped, arena, "description", description);
                    try mapped.put(arena, "parameters", try provider_utils.cloneJsonValue(arena, definition.parameters));
                    try mapped_tools.append(.{ .object = mapped });
                },
            };
            try session.put(arena, "tools", .{ .array = mapped_tools });
            try putString(&session, arena, "tool_choice", "auto");
        };

        if (session_config.provider_options) |provider_options| switch (provider_options) {
            .null => {},
            .object => |options| {
                var iterator = options.iterator();
                while (iterator.next()) |entry| {
                    try session.put(
                        arena,
                        try arena.dupe(u8, entry.key_ptr.*),
                        try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
                    );
                }
            },
            else => return invalidArgument(
                diag,
                "providerOptions",
                "OpenAI realtime providerOptions must be a JSON object",
            ),
        };

        return .{ .object = session };
    }

    fn resolveHeaders(
        self: *const RealtimeModel,
        arena: Allocator,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError![]const provider.Header {
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
        const required_headers = [_]provider_utils.HeaderEntry{
            .{ .name = "content-type", .value = "application/json" },
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            configured_storage[0..configured_len],
            self.config.headers.resolve(),
            &required_headers,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(
            arena,
            combined,
            &.{"ai-sdk-zig/openai/" ++ provider_utils.version},
        );
    }

    fn realtimeWebSocketUrl(
        self: *const RealtimeModel,
        arena: Allocator,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError![]const u8 {
        const uri = std.Uri.parse(self.config.base_url) catch
            return invalidArgument(diag, "baseURL", "OpenAI base URL must be an absolute URL");
        const host_component = uri.host orelse
            return invalidArgument(diag, "baseURL", "OpenAI base URL must include a host");
        const host = switch (host_component) {
            .raw, .percent_encoded => |value| value,
        };
        const encoded_model_id = try encodeURIComponent(arena, self.model_id);
        if (uri.port) |port| if (!isDefaultPort(uri.scheme, port)) {
            return std.fmt.allocPrint(
                arena,
                "wss://{s}:{d}/v1/realtime?model={s}",
                .{ host, port, encoded_model_id },
            );
        };
        return std.fmt.allocPrint(
            arena,
            "wss://{s}/v1/realtime?model={s}",
            .{ host, encoded_model_id },
        );
    }
};

const ItemEventTag = enum {
    output_item_added,
    output_item_done,
    content_part_added,
    content_part_done,
    audio_done,
};

fn itemEvent(tag: ItemEventTag, object: std.json.ObjectMap, raw: provider.JsonValue) provider.ServerEvent {
    const payload: provider.realtime_model.ServerEvent.ItemEvent = .{
        .response_id = optionalString(object, "response_id") orelse "",
        .item_id = switch (tag) {
            .output_item_added, .output_item_done => optionalNestedString(object, "item", "id") orelse
                optionalString(object, "item_id") orelse "",
            .content_part_added, .content_part_done, .audio_done => optionalString(object, "item_id") orelse "",
        },
        .raw = raw,
    };
    return switch (tag) {
        .output_item_added => .{ .output_item_added = payload },
        .output_item_done => .{ .output_item_done = payload },
        .content_part_added => .{ .content_part_added = payload },
        .content_part_done => .{ .content_part_done = payload },
        .audio_done => .{ .audio_done = payload },
    };
}

const DeltaEventTag = enum { audio_delta, audio_transcript_delta, text_delta };

fn deltaEvent(tag: DeltaEventTag, object: std.json.ObjectMap, raw: provider.JsonValue) provider.ServerEvent {
    const payload: provider.realtime_model.ServerEvent.DeltaEvent = .{
        .response_id = optionalString(object, "response_id") orelse "",
        .item_id = optionalString(object, "item_id") orelse "",
        .delta = optionalString(object, "delta") orelse "",
        .raw = raw,
    };
    return switch (tag) {
        .audio_delta => .{ .audio_delta = payload },
        .audio_transcript_delta => .{ .audio_transcript_delta = payload },
        .text_delta => .{ .text_delta = payload },
    };
}

fn audioFormat(arena: Allocator, format: provider.realtime_model.AudioFormat) Allocator.Error!provider.JsonValue {
    var mapped: std.json.ObjectMap = .empty;
    try putString(&mapped, arena, "type", format.type);
    if (format.rate) |rate| try mapped.put(arena, "rate", .{ .integer = rate });
    return .{ .object = mapped };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalNestedString(object: std.json.ObjectMap, parent: []const u8, key: []const u8) ?[]const u8 {
    const value = object.get(parent) orelse return null;
    if (value != .object) return null;
    return optionalString(value.object, key);
}

fn optionalResponseU64(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    field: []const u8,
    value: provider.JsonValue,
) provider.realtime_model.CallError!?u64 {
    if (value == .null) return null;
    const parsed: ?u64 = switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (std.math.isFinite(float) and float >= 0 and @floor(float) == float and float < 18_446_744_073_709_551_616.0)
            @intFromFloat(float)
        else
            null,
        else => null,
    };
    return parsed orelse {
        const message = try std.fmt.allocPrint(arena, "OpenAI realtime client-secret response {s} must be a non-negative integer", .{field});
        return invalidResponse(arena, diag, message);
    };
}

fn unsignedJsonInteger(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    field: []const u8,
    value: u64,
) provider.realtime_model.CallError!provider.JsonValue {
    if (value > std.math.maxInt(i64)) {
        const message = try std.fmt.allocPrint(arena, "OpenAI realtime {s} exceeds the JSON integer range", .{field});
        return invalidArgument(diag, field, message);
    }
    return .{ .integer = @intCast(value) };
}

fn stringArray(arena: Allocator, values: []const []const u8) Allocator.Error!provider.JsonValue {
    var array = std.json.Array.init(arena);
    for (values) |value| try array.append(.{ .string = try arena.dupe(u8, value) });
    return .{ .array = array };
}

fn encodeURIComponent(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var encoded_len: usize = 0;
    for (value) |byte| encoded_len += if (isEncodeURIComponentByte(byte)) 1 else 3;
    const encoded = try arena.alloc(u8, encoded_len);
    const hex = "0123456789ABCDEF";
    var index: usize = 0;
    for (value) |byte| {
        if (isEncodeURIComponentByte(byte)) {
            encoded[index] = byte;
            index += 1;
        } else {
            encoded[index] = '%';
            encoded[index + 1] = hex[byte >> 4];
            encoded[index + 2] = hex[byte & 0x0f];
            index += 3;
        }
    }
    return encoded;
}

fn isEncodeURIComponentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

fn isDefaultPort(scheme: []const u8, port: u16) bool {
    return (std.ascii.eqlIgnoreCase(scheme, "http") and port == 80) or
        (std.ascii.eqlIgnoreCase(scheme, "https") and port == 443);
}

fn putString(
    object: *std.json.ObjectMap,
    arena: Allocator,
    key: []const u8,
    value: []const u8,
) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn invalidResponse(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
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

const TestTransport = struct {
    var marker: u8 = 0;

    fn transport() provider_utils.HttpTransport {
        return .{ .ctx = &marker, .vtable = &.{ .request = request } };
    }

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

fn testModel(model_id: []const u8) !RealtimeModel {
    return RealtimeModel.init(model_id, .{
        .allocator = std.testing.allocator,
        .base_url = "https://api.openai.com/v1",
        .api_key = "test-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = TestTransport.transport(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
}

fn expectJson(
    arena: Allocator,
    actual: provider.JsonValue,
    expected_json: []const u8,
) !void {
    const expected = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, expected_json, .{});
    if (provider_utils.isDeepEqualData(actual, expected)) return;

    const actual_json = try provider_utils.stringifyJsonValueAlloc(arena, actual);
    std.debug.print("\nexpected JSON: {s}\n  actual JSON: {s}\n", .{ expected_json, actual_json });
    return error.TestExpectedEqual;
}

fn expectSerialized(
    model: provider.RealtimeModel,
    arena: Allocator,
    event: provider.ClientEvent,
    expected_json: []const u8,
) !void {
    const actual = try model.serializeClientEvent(std.testing.io, arena, &event, null);
    try expectJson(arena, actual, expected_json);
}

test "OpenAI realtime model identity and WebSocket subprotocol auth" {
    var concrete = try testModel("gpt-realtime");
    const model = concrete.realtimeModel();
    try std.testing.expectEqualStrings("openai.realtime", model.provider());
    try std.testing.expectEqualStrings("gpt-realtime", model.modelId());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const config = try model.getWebSocketConfig(arena_state.allocator(), &.{
        .token = "ek_test_secret",
        .url = "wss://example.test/v1/realtime?model=gpt-realtime",
    }, null);
    try std.testing.expectEqualStrings("wss://example.test/v1/realtime?model=gpt-realtime", config.url);
    try std.testing.expectEqual(2, config.protocols.?.len);
    try std.testing.expectEqualStrings("realtime", config.protocols.?[0]);
    try std.testing.expectEqualStrings("openai-insecure-api-key.ek_test_secret", config.protocols.?[1]);
}

test "OpenAI realtime session config maps audio VAD tools and provider option overrides" {
    var concrete = try testModel("gpt-realtime");
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parameters = try std.json.parseFromSliceLeaky(
        provider.JsonValue,
        arena,
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
        .{},
    );
    const provider_options = try std.json.parseFromSliceLeaky(
        provider.JsonValue,
        arena,
        "{\"model\":\"provider-override\",\"tracing\":{\"enabled\":true}}",
        .{},
    );
    const tools = [_]provider.RealtimeToolDefinition{.{ .function = .{
        .name = "weather",
        .description = "Look up weather",
        .parameters = parameters,
    } }};
    const modalities = [_]provider.realtime_model.OutputModality{ .text, .audio };
    const actual = try model.buildSessionConfig(arena, &.{
        .instructions = "Be concise.",
        .voice = "marin",
        .output_modalities = &modalities,
        .input_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
        .input_audio_transcription = .{
            .model = "gpt-4o-mini-transcribe",
            .language = "en",
            .prompt = "Short voice messages.",
        },
        .output_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
        .turn_detection = .{
            .type = .server_vad,
            .threshold = 0.45,
            .silence_duration_ms = 700,
            .prefix_padding_ms = 250,
        },
        .tools = &tools,
        .provider_options = provider_options,
    }, null);
    try expectJson(arena, actual,
        \\{"type":"realtime","model":"provider-override","instructions":"Be concise.","output_modalities":["text","audio"],"audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"turn_detection":{"type":"server_vad","threshold":0.45,"silence_duration_ms":700,"prefix_padding_ms":250},"transcription":{"model":"gpt-4o-mini-transcribe","language":"en","prompt":"Short voice messages."}},"output":{"format":{"type":"audio/pcm","rate":24000},"voice":"marin"}},"tools":[{"type":"function","name":"weather","description":"Look up weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}],"tool_choice":"auto","tracing":{"enabled":true}}
    );
}

// Ported from openai-realtime-event-mapper.test.ts: the default model is a
// wire contract, not a provider-local convenience default.
test "OpenAI realtime session config enables input transcription with upstream default" {
    var concrete = try testModel("gpt-realtime");
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const actual = try model.buildSessionConfig(arena, &.{
        .input_audio_transcription = .{},
    }, null);
    try expectJson(arena, actual,
        \\{"type":"realtime","model":"gpt-realtime","audio":{"input":{"transcription":{"model":"gpt-realtime-whisper"}}}}
    );
}

// Ported from openai-realtime-event-mapper.test.ts.
test "OpenAI realtime session config maps input transcription options and disabled VAD" {
    var concrete = try testModel("gpt-realtime");
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const actual = try model.buildSessionConfig(arena, &.{
        .input_audio_transcription = .{
            .model = "gpt-4o-mini-transcribe",
            .language = "en",
            .prompt = "Transcribe short voice chat messages.",
        },
        .turn_detection = .{ .type = .disabled },
    }, null);
    try expectJson(arena, actual,
        \\{"type":"realtime","model":"gpt-realtime","audio":{"input":{"turn_detection":null,"transcription":{"model":"gpt-4o-mini-transcribe","language":"en","prompt":"Transcribe short voice chat messages."}}}}
    );

    const semantic_vad = try model.buildSessionConfig(arena, &.{
        .turn_detection = .{ .type = .semantic_vad, .threshold = 0.8 },
    }, null);
    try expectJson(arena, semantic_vad,
        \\{"type":"realtime","model":"gpt-realtime","audio":{"input":{"turn_detection":{"type":"semantic_vad","threshold":0.8}}}}
    );
}

test "OpenAI realtime client serializer covers all normalized event variants" {
    var concrete = try testModel("gpt-realtime");
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectSerialized(model, arena, .{ .session_update = .{ .config = .{ .instructions = "hello" } } },
        \\{"type":"session.update","session":{"type":"realtime","model":"gpt-realtime","instructions":"hello"}}
    );
    try expectSerialized(model, arena, .{ .input_audio_append = .{ .audio = "AQID" } },
        \\{"type":"input_audio_buffer.append","audio":"AQID"}
    );
    try expectSerialized(model, arena, .{ .input_audio_commit = .{} },
        \\{"type":"input_audio_buffer.commit"}
    );
    try expectSerialized(model, arena, .{ .input_audio_clear = .{} },
        \\{"type":"input_audio_buffer.clear"}
    );
    try expectSerialized(model, arena, .{ .conversation_item_create = .{ .item = .{ .text_message = .{
        .role = .user,
        .text = "hello",
    } } } },
        \\{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
    );
    try expectSerialized(model, arena, .{ .conversation_item_create = .{ .item = .{ .audio_message = .{
        .role = .user,
        .audio = "BAUG",
    } } } },
        \\{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_audio","audio":"BAUG"}]}}
    );
    try expectSerialized(model, arena, .{ .conversation_item_create = .{ .item = .{ .function_call_output = .{
        .call_id = "call_1",
        .name = "ignored-on-openai-wire",
        .output = "{\"ok\":true}",
    } } } },
        \\{"type":"conversation.item.create","item":{"type":"function_call_output","call_id":"call_1","output":"{\"ok\":true}"}}
    );
    try expectSerialized(model, arena, .{ .conversation_item_truncate = .{
        .item_id = "item_1",
        .content_index = 0,
        .audio_end_ms = 1_234,
    } },
        \\{"type":"conversation.item.truncate","item_id":"item_1","content_index":0,"audio_end_ms":1234}
    );
    try expectSerialized(model, arena, .{ .response_create = .{} },
        \\{"type":"response.create"}
    );
    try expectSerialized(model, arena, .{ .response_create = .{ .options = .{} } },
        \\{"type":"response.create","response":{}}
    );
    const metadata = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, "{\"request_id\":\"req_1\"}", .{});
    const modalities = [_][]const u8{ "text", "audio" };
    try expectSerialized(model, arena, .{ .response_create = .{ .options = .{
        .modalities = &modalities,
        .instructions = "Answer now.",
        .metadata = metadata,
    } } },
        \\{"type":"response.create","response":{"output_modalities":["text","audio"],"instructions":"Answer now.","metadata":{"request_id":"req_1"}}}
    );
    try expectSerialized(model, arena, .{ .response_cancel = .{} },
        \\{"type":"response.cancel"}
    );
}

test "OpenAI realtime server parser covers every upstream mapper branch" {
    var concrete = try testModel("gpt-realtime");
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Tag = std.meta.Tag(provider.ServerEvent);
    const Fixture = struct { json: []const u8, tag: Tag };

    // Event names and representative shapes are ported from
    // openai-realtime-event-mapper.ts (SDK v7 territory).
    const fixtures = [_]Fixture{
        .{ .json = "{\"type\":\"session.created\",\"session\":{\"id\":\"sess_1\"}}", .tag = .session_created },
        .{ .json = "{\"type\":\"session.updated\"}", .tag = .session_updated },
        .{ .json = "{\"type\":\"input_audio_buffer.speech_started\",\"item_id\":\"item_1\"}", .tag = .speech_started },
        .{ .json = "{\"type\":\"input_audio_buffer.speech_stopped\",\"item_id\":\"item_1\"}", .tag = .speech_stopped },
        .{ .json = "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"item_2\",\"previous_item_id\":\"item_1\"}", .tag = .audio_committed },
        .{ .json = "{\"type\":\"conversation.item.added\",\"item_id\":\"fallback\",\"item\":{\"id\":\"item_3\",\"type\":\"message\"}}", .tag = .conversation_item_added },
        .{ .json = "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item_2\",\"transcript\":\"hello\"}", .tag = .input_transcription_completed },
        .{ .json = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}", .tag = .response_created },
        .{ .json = "{\"type\":\"response.done\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}", .tag = .response_done },
        .{ .json = "{\"type\":\"response.output_item.added\",\"response_id\":\"resp_1\",\"item\":{\"id\":\"item_4\"}}", .tag = .output_item_added },
        .{ .json = "{\"type\":\"response.output_item.done\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\"}", .tag = .output_item_done },
        .{ .json = "{\"type\":\"response.content_part.added\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\"}", .tag = .content_part_added },
        .{ .json = "{\"type\":\"response.content_part.done\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\"}", .tag = .content_part_done },
        .{ .json = "{\"type\":\"response.output_audio.delta\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\",\"delta\":\"AQID\"}", .tag = .audio_delta },
        .{ .json = "{\"type\":\"response.output_audio.done\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\"}", .tag = .audio_done },
        .{ .json = "{\"type\":\"response.output_audio_transcript.delta\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\",\"delta\":\"hel\"}", .tag = .audio_transcript_delta },
        .{ .json = "{\"type\":\"response.output_audio_transcript.done\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\",\"transcript\":\"hello\"}", .tag = .audio_transcript_done },
        .{ .json = "{\"type\":\"response.output_text.delta\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\",\"delta\":\"hel\"}", .tag = .text_delta },
        .{ .json = "{\"type\":\"response.output_text.done\",\"response_id\":\"resp_1\",\"item_id\":\"item_4\",\"text\":\"hello\"}", .tag = .text_done },
        .{ .json = "{\"type\":\"response.function_call_arguments.delta\",\"response_id\":\"resp_1\",\"item_id\":\"item_5\",\"call_id\":\"call_1\",\"delta\":\"{\\\"city\\\":\"}", .tag = .function_call_arguments_delta },
        .{ .json = "{\"type\":\"response.function_call_arguments.done\",\"response_id\":\"resp_1\",\"item_id\":\"item_5\",\"call_id\":\"call_1\",\"name\":\"weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}", .tag = .function_call_arguments_done },
        .{ .json = "{\"type\":\"error\",\"error\":{\"message\":\"bad request\",\"code\":\"invalid_event\"}}", .tag = .err },
        .{ .json = "{\"type\":\"rate_limits.updated\",\"rate_limits\":[]}", .tag = .custom },
    };

    for (fixtures) |fixture| {
        const raw = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, fixture.json, .{});
        const events = try model.parseServerEvent(arena, &raw, null);
        try std.testing.expectEqual(1, events.len);
        try std.testing.expectEqual(fixture.tag, std.meta.activeTag(events[0]));
    }

    const raw_created = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, fixtures[0].json, .{});
    const created = (try model.parseServerEvent(arena, &raw_created, null))[0].session_created;
    try std.testing.expectEqualStrings("sess_1", created.session_id.?);

    const raw_item = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, fixtures[5].json, .{});
    const item = (try model.parseServerEvent(arena, &raw_item, null))[0].conversation_item_added;
    try std.testing.expectEqualStrings("item_3", item.item_id);
    try std.testing.expectEqualStrings("message", optionalString(item.item.object, "type").?);

    const raw_error = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, fixtures[21].json, .{});
    const mapped_error = (try model.parseServerEvent(arena, &raw_error, null))[0].err;
    try std.testing.expectEqualStrings("bad request", mapped_error.message);
    try std.testing.expectEqualStrings("invalid_event", mapped_error.code.?);

    const missing_fields = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, "{\"type\":\"response.done\"}", .{});
    const defaulted = (try model.parseServerEvent(arena, &missing_fields, null))[0].response_done;
    try std.testing.expectEqualStrings("", defaulted.response_id);
    try std.testing.expectEqualStrings("completed", defaulted.status);

    const non_object: provider.JsonValue = .null;
    const custom = (try model.parseServerEvent(arena, &non_object, null))[0].custom;
    try std.testing.expectEqualStrings("", custom.raw_type);
    try std.testing.expectEqual(provider.JsonValue.null, std.meta.activeTag(custom.raw));
}

// The first two request cases are ported from openai-realtime-model.test.ts.
test "OpenAI realtime client-secret POST omits or anchors expires_after and builds encoded WS URL" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"value\":\"secret-one\",\"expires_at\":123}" },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"value\":\"secret-two\"}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    const base_url = server.baseUrl(&base_buffer);
    var concrete = try RealtimeModel.init("gpt-realtime/preview x", .{
        .allocator = allocator,
        .base_url = base_url,
        .api_key = "test-key",
        .organization = "org-test",
        .project = "project-test",
        .env = .empty,
        .headers = .{ .static = &.{
            .{ .name = "x-openai-test", .value = "codec" },
            .{ .name = "content-type", .value = "text/plain" },
        } },
        .transport = client.transport(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try model.doCreateClientSecret(io, arena, &.{}, null);
    try std.testing.expectEqualStrings("secret-one", first.token);
    try std.testing.expectEqual(123, first.expires_at.?);
    const expected_url = try std.fmt.allocPrint(
        arena,
        "wss://127.0.0.1:{d}/v1/realtime?model=gpt-realtime%2Fpreview%20x",
        .{server.port()},
    );
    try std.testing.expectEqualStrings(expected_url, first.url);

    const second = try model.doCreateClientSecret(io, arena, &.{
        .expires_after_seconds = 60,
        .session_config = .{ .input_audio_transcription = .{} },
    }, null);
    try std.testing.expectEqualStrings("secret-two", second.token);
    try std.testing.expect(second.expires_at == null);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expectEqual(.POST, requests[0].method);
    try std.testing.expectEqualStrings("/realtime/client_secrets", requests[0].target);
    try std.testing.expectEqualStrings("application/json", recordedHeader(requests[0].headers, "content-type").?);
    try std.testing.expectEqualStrings("Bearer test-key", recordedHeader(requests[0].headers, "authorization").?);
    try std.testing.expectEqualStrings("org-test", recordedHeader(requests[0].headers, "openai-organization").?);
    try std.testing.expectEqualStrings("project-test", recordedHeader(requests[0].headers, "openai-project").?);
    try std.testing.expectEqualStrings("codec", recordedHeader(requests[0].headers, "x-openai-test").?);

    const first_body = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, requests[0].body, .{});
    try expectJson(arena, first_body,
        \\{"session":{"type":"realtime","model":"gpt-realtime/preview x"}}
    );
    const second_body = try std.json.parseFromSliceLeaky(provider.JsonValue, arena, requests[1].body, .{});
    try expectJson(arena, second_body,
        \\{"session":{"type":"realtime","model":"gpt-realtime/preview x","audio":{"input":{"transcription":{"model":"gpt-realtime-whisper"}}}},"expires_after":{"anchor":"created_at","seconds":60}}
    );
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI realtime rejects malformed secret responses and non-object provider options" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"expires_at\":123}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var concrete = try RealtimeModel.init("gpt-realtime", .{
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
    const model = concrete.realtimeModel();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(
        error.InvalidResponseDataError,
        model.doCreateClientSecret(io, arena, &.{}, null),
    );
    try std.testing.expectError(
        error.InvalidArgumentError,
        model.buildSessionConfig(arena, &.{ .provider_options = .{ .string = "invalid" } }, null),
    );
}

fn recordedHeader(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}
