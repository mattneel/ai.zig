const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const capabilities_api = @import("capabilities.zig");
const chat_messages = @import("chat_messages.zig");
const chat_tools = @import("chat_tools.zig");
const config_api = @import("config.zig");
const options_api = @import("options.zig");

const Allocator = std.mem.Allocator;
const BuildError = provider.Error || Allocator.Error;
const max_provider_id_len = 1024;

pub const PreparedRequest = struct {
    body: std.json.Value,
    warnings: []const provider.Warning,
    metadata_key: []const u8,
};

pub const ChatLanguageModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ChatLanguageModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");
        var result: ChatLanguageModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.chat", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn languageModel(self: *ChatLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn prepareRequest(
        self: *ChatLanguageModel,
        arena: Allocator,
        options: *const provider.CallOptions,
        stream: bool,
        diag: ?*provider.Diagnostics,
    ) BuildError!PreparedRequest {
        return buildArgs(self, arena, options, stream, diag);
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .urlIsSupported = vUrlIsSupported,
        .doGenerate = vDoGenerate,
        .doStream = vDoStream,
    };

    fn fromRaw(raw: *anyopaque) *ChatLanguageModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        return self.provider_id_buffer[0..self.provider_id_len];
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vUrlIsSupported(_: *anyopaque, media_type: []const u8, url: []const u8) bool {
        return std.mem.startsWith(u8, media_type, "image/") and
            (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"));
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return fromRaw(raw).doGenerate(io, arena, options, diag);
    }

    fn vDoStream(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return fromRaw(raw).doStream(io, arena, options, diag);
    }

    fn doGenerate(
        self: *ChatLanguageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const prepared = try buildArgs(self, arena, options, false, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, options.headers, diag);
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
        return mapGenerateResponse(
            io,
            arena,
            prepared,
            result.value,
            result.response_headers,
            diag,
        );
    }

    fn doStream(
        self: *ChatLanguageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const prepared = try buildArgs(self, arena, options, true, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, options.headers, diag);
        const Stream = provider_utils.JsonEventStream(std.json.Value);
        const result = try provider_utils.postJsonToApi(
            Stream,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.eventSourceResponseHandler(std.json.Value),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );

        const state = try arena.create(StreamState);
        state.* = .{
            .arena = arena,
            .events = result.value,
            .warnings = prepared.warnings,
            .metadata_key = prepared.metadata_key,
            .include_raw = options.include_raw_chunks orelse false,
            .diag = diag,
            .id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag),
            .tracker = undefined,
        };
        state.tracker = provider_utils.StreamingToolCallTracker.initWithOptions(
            arena,
            &state.id_generator,
            .if_present,
        );
        try state.queue.append(arena, .{ .stream_start = .{ .warnings = prepared.warnings } });
        errdefer state.deinitInternal();
        try state.peekForEarlyError(url, body_json, result.response_headers);

        return .{
            .stream = .{ .ctx = state, .vtable = &StreamState.vtable },
            .request = .{ .body = prepared.body },
            .response = .{ .headers = result.response_headers },
        };
    }

    fn resolveHeaders(
        self: *const ChatLanguageModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
        diag: ?*provider.Diagnostics,
    ) provider.CallError![]const provider.Header {
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

fn buildArgs(
    self: *ChatLanguageModel,
    arena: Allocator,
    call_options: *const provider.CallOptions,
    stream: bool,
    diag: ?*provider.Diagnostics,
) BuildError!PreparedRequest {
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    if (call_options.top_k != null) try warnings.append(arena, .{ .unsupported = .{ .feature = "topK" } });

    const openai_options = try options_api.parseChatOptions(
        arena,
        call_options.provider_options,
        self.config.provider_options_name,
        diag,
    );
    const capabilities = capabilities_api.getLanguageModelCapabilities(self.model_id);
    const resolved_reasoning_effort = openai_options.reasoning_effort orelse reasoningName(call_options.reasoning);
    const is_reasoning_model = openai_options.force_reasoning orelse capabilities.is_reasoning_model;
    const mode = openai_options.system_message_mode orelse
        if (is_reasoning_model) capabilities_api.SystemMessageMode.developer else capabilities.system_message_mode;
    const converted = try chat_messages.convertMessages(
        arena,
        call_options.prompt,
        mode,
        self.config.provider_options_name,
        diag,
    );
    try warnings.appendSlice(arena, converted.warnings);

    var temperature = call_options.temperature;
    var top_p = call_options.top_p;
    var frequency_penalty = call_options.frequency_penalty;
    var presence_penalty = call_options.presence_penalty;
    var logit_bias = openai_options.logit_bias;
    var logprobs_enabled: ?bool = if (openai_options.logprobs) |value| switch (value) {
        .boolean => |enabled| if (enabled) true else null,
        .count => true,
    } else null;
    var top_logprobs: ?u64 = if (openai_options.logprobs) |value| switch (value) {
        .boolean => |enabled| if (enabled) 0 else null,
        .count => |count| count,
    } else null;
    var max_tokens = call_options.max_output_tokens;
    var max_completion_tokens = openai_options.max_completion_tokens;

    if (is_reasoning_model) {
        if (resolved_reasoning_effort == null or
            !std.mem.eql(u8, resolved_reasoning_effort.?, "none") or
            !capabilities.supports_non_reasoning_parameters)
        {
            if (temperature != null) {
                temperature = null;
                try warnings.append(arena, .{ .unsupported = .{
                    .feature = "temperature",
                    .details = "temperature is not supported for reasoning models",
                } });
            }
            if (top_p != null) {
                top_p = null;
                try warnings.append(arena, .{ .unsupported = .{
                    .feature = "topP",
                    .details = "topP is not supported for reasoning models",
                } });
            }
            if (logprobs_enabled != null) {
                logprobs_enabled = null;
                try warnings.append(arena, .{ .other = .{ .message = "logprobs is not supported for reasoning models" } });
            }
        }
        if (frequency_penalty != null) {
            frequency_penalty = null;
            try warnings.append(arena, .{ .unsupported = .{
                .feature = "frequencyPenalty",
                .details = "frequencyPenalty is not supported for reasoning models",
            } });
        }
        if (presence_penalty != null) {
            presence_penalty = null;
            try warnings.append(arena, .{ .unsupported = .{
                .feature = "presencePenalty",
                .details = "presencePenalty is not supported for reasoning models",
            } });
        }
        if (logit_bias != null) {
            logit_bias = null;
            try warnings.append(arena, .{ .other = .{ .message = "logitBias is not supported for reasoning models" } });
        }
        if (top_logprobs != null) {
            top_logprobs = null;
            try warnings.append(arena, .{ .other = .{ .message = "topLogprobs is not supported for reasoning models" } });
        }
        if (max_tokens) |value| {
            if (max_completion_tokens == null) max_completion_tokens = value;
            max_tokens = null;
        }
    } else if ((std.mem.startsWith(u8, self.model_id, "gpt-4o-search-preview") or
        std.mem.startsWith(u8, self.model_id, "gpt-4o-mini-search-preview")) and temperature != null)
    {
        temperature = null;
        try warnings.append(arena, .{ .unsupported = .{
            .feature = "temperature",
            .details = "temperature is not supported for the search preview models and has been removed.",
        } });
    }

    var service_tier = openai_options.service_tier;
    if (service_tier) |tier| {
        if (std.mem.eql(u8, tier, "flex") and !capabilities.supports_flex_processing) {
            service_tier = null;
            try warnings.append(arena, .{ .unsupported = .{
                .feature = "serviceTier",
                .details = "flex processing is only available for o3, o4-mini, and gpt-5 models",
            } });
        } else if (std.mem.eql(u8, tier, "priority") and !capabilities.supports_priority_processing) {
            service_tier = null;
            try warnings.append(arena, .{ .unsupported = .{
                .feature = "serviceTier",
                .details = "priority processing is only available for supported models (gpt-4, gpt-5, gpt-5-mini, o3, o4-mini) and requires Enterprise access. gpt-5-nano is not supported",
            } });
        }
    }

    const prepared_tools = try chat_tools.prepareChatTools(arena, call_options.tools, call_options.tool_choice);
    try warnings.appendSlice(arena, prepared_tools.warnings);

    var body: std.json.ObjectMap = .empty;
    try putString(&body, arena, "model", self.model_id);
    if (logit_bias) |value| try body.put(arena, "logit_bias", try provider_utils.cloneJsonValue(arena, value));
    if (logprobs_enabled) |enabled| try body.put(arena, "logprobs", .{ .bool = enabled });
    if (top_logprobs) |count| try body.put(arena, "top_logprobs", try uintValue(arena, count));
    if (openai_options.user) |value| try putString(&body, arena, "user", value);
    if (openai_options.parallel_tool_calls) |value| try body.put(arena, "parallel_tool_calls", .{ .bool = value });
    if (max_tokens) |value| try body.put(arena, "max_tokens", try uintValue(arena, value));
    if (temperature) |value| try body.put(arena, "temperature", .{ .float = value });
    if (top_p) |value| try body.put(arena, "top_p", .{ .float = value });
    if (frequency_penalty) |value| try body.put(arena, "frequency_penalty", .{ .float = value });
    if (presence_penalty) |value| try body.put(arena, "presence_penalty", .{ .float = value });
    if (call_options.response_format) |format| switch (format) {
        .text => {},
        .json => |json| {
            var response_format: std.json.ObjectMap = .empty;
            if (json.schema) |schema| {
                try putString(&response_format, arena, "type", "json_schema");
                var json_schema: std.json.ObjectMap = .empty;
                try json_schema.put(arena, "schema", try provider_utils.cloneJsonValue(arena, schema));
                try json_schema.put(arena, "strict", .{ .bool = openai_options.strict_json_schema });
                try putString(&json_schema, arena, "name", json.name orelse "response");
                if (json.description) |description| try putString(&json_schema, arena, "description", description);
                try response_format.put(arena, "json_schema", .{ .object = json_schema });
            } else {
                try putString(&response_format, arena, "type", "json_object");
            }
            try body.put(arena, "response_format", .{ .object = response_format });
        },
    };
    if (call_options.stop_sequences) |values| try body.put(arena, "stop", try stringArray(arena, values));
    if (call_options.seed) |value| try body.put(arena, "seed", .{ .integer = value });
    if (openai_options.text_verbosity) |value| try putString(&body, arena, "verbosity", value);
    if (max_completion_tokens) |value| try body.put(arena, "max_completion_tokens", try uintValue(arena, value));
    if (openai_options.store) |value| try body.put(arena, "store", .{ .bool = value });
    if (openai_options.metadata) |value| try body.put(arena, "metadata", try provider_utils.cloneJsonValue(arena, value));
    if (openai_options.prediction) |value| try body.put(arena, "prediction", try provider_utils.cloneJsonValue(arena, value));
    if (resolved_reasoning_effort) |value| try putString(&body, arena, "reasoning_effort", value);
    if (service_tier) |value| try putString(&body, arena, "service_tier", value);
    if (openai_options.prompt_cache_key) |value| try putString(&body, arena, "prompt_cache_key", value);
    if (openai_options.prompt_cache_options) |value| try body.put(arena, "prompt_cache_options", try provider_utils.cloneJsonValue(arena, value));
    if (openai_options.prompt_cache_retention) |value| try putString(&body, arena, "prompt_cache_retention", value);
    if (openai_options.safety_identifier) |value| try putString(&body, arena, "safety_identifier", value);
    try body.put(arena, "messages", converted.value);
    if (prepared_tools.tools) |value| try body.put(arena, "tools", value);
    if (prepared_tools.tool_choice) |value| try body.put(arena, "tool_choice", value);
    if (stream) {
        try body.put(arena, "stream", .{ .bool = true });
        var stream_options: std.json.ObjectMap = .empty;
        try stream_options.put(arena, "include_usage", .{ .bool = true });
        try body.put(arena, "stream_options", .{ .object = stream_options });
    }
    return .{
        .body = .{ .object = body },
        .warnings = try warnings.toOwnedSlice(arena),
        .metadata_key = self.config.provider_options_name,
    };
}

fn mapGenerateResponse(
    io: std.Io,
    arena: Allocator,
    prepared: PreparedRequest,
    response: std.json.Value,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.CallError!provider.GenerateResult {
    const root = try requireObject(response, arena, diag, "OpenAI response must be an object");
    const choices = try requireArrayField(root, "choices", arena, diag);
    if (choices.items.len == 0) return invalidResponse(arena, diag, "OpenAI response has no choices");
    const choice = try requireObject(choices.items[0], arena, diag, "OpenAI choice must be an object");
    const message = try requireObjectField(choice, "message", arena, diag);
    var content: std.ArrayList(provider.Content) = .empty;
    defer content.deinit(arena);
    if (optionalStringField(message, "content")) |text| if (text.len != 0) {
        try content.append(arena, .{ .text = .{ .text = try arena.dupe(u8, text) } });
    };

    var generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag);
    if (message.get("tool_calls")) |tool_calls| if (tool_calls == .array) {
        for (tool_calls.array.items) |item| {
            if (item != .object) continue;
            const function = objectField(item.object, "function") orelse continue;
            const name = optionalStringField(function, "name") orelse continue;
            const arguments = optionalStringField(function, "arguments") orelse "";
            const id = optionalStringField(item.object, "id") orelse try generator.nextAlloc(arena);
            try content.append(arena, .{ .tool_call = .{
                .tool_call_id = try arena.dupe(u8, id),
                .tool_name = try arena.dupe(u8, name),
                .input = try arena.dupe(u8, arguments),
            } });
        }
    };
    if (message.get("annotations")) |annotations| if (annotations == .array) {
        for (annotations.array.items) |annotation| {
            const annotation_object = if (annotation == .object) annotation.object else continue;
            const citation = objectField(annotation_object, "url_citation") orelse continue;
            const url = optionalStringField(citation, "url") orelse continue;
            try content.append(arena, .{ .source = .{ .url = .{
                .id = try generator.nextAlloc(arena),
                .url = try arena.dupe(u8, url),
                .title = if (optionalStringField(citation, "title")) |title| try arena.dupe(u8, title) else null,
            } } });
        }
    };

    const usage_value = root.get("usage") orelse std.json.Value.null;
    const finish_raw = optionalStringField(choice, "finish_reason");
    return .{
        .content = try content.toOwnedSlice(arena),
        .finish_reason = .{ .unified = mapFinishReason(finish_raw), .raw = finish_raw },
        .usage = try convertUsage(arena, usage_value),
        .provider_metadata = try makeProviderMetadata(arena, prepared.metadata_key, usage_value, choice.get("logprobs")),
        .request = .{ .body = prepared.body },
        .response = .{
            .id = optionalStringField(root, "id"),
            .timestamp_ms = timestampMillis(root.get("created")),
            .model_id = optionalStringField(root, "model"),
            .headers = response_headers,
            .body = response,
        },
        .warnings = prepared.warnings,
    };
}

const StreamState = struct {
    arena: Allocator,
    events: provider_utils.JsonEventStream(std.json.Value),
    warnings: []const provider.Warning,
    metadata_key: []const u8,
    include_raw: bool,
    diag: ?*provider.Diagnostics,
    id_generator: provider_utils.IdGenerator,
    tracker: provider_utils.StreamingToolCallTracker,
    queue: std.ArrayList(provider.StreamPart) = .empty,
    queue_index: usize = 0,
    metadata_extracted: bool = false,
    active_text: bool = false,
    finish_reason: provider.FinishReason = .{ .unified = .other },
    usage: ?std.json.Value = null,
    logprobs: ?std.json.Value = null,
    flushed: bool = false,
    deinitialized: bool = false,

    const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return null;
        while (self.queue_index >= self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.queue_index = 0;
            if (self.flushed) return null;
            try self.fillQueue();
        }
        defer self.queue_index += 1;
        return self.queue.items[self.queue_index];
    }

    fn deinit(raw: *anyopaque, _: std.Io) void {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        self.deinitInternal();
    }

    fn deinitInternal(self: *StreamState) void {
        if (self.deinitialized) return;
        self.events.deinit();
        self.tracker.deinit();
        self.queue.deinit(self.arena);
        self.deinitialized = true;
    }

    fn peekForEarlyError(
        self: *StreamState,
        url: []const u8,
        request_body_json: []const u8,
        response_headers: []const provider.Header,
    ) provider.CallError!void {
        while (true) {
            const event = self.events.next(self.arena) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidResponse(self.arena, self.diag, @errorName(err)),
            };
            const value = event orelse {
                try self.flush();
                return;
            };
            switch (value) {
                .failure => |failure| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = .{ .string = failure.raw } } });
                    self.finish_reason = .{ .unified = .@"error" };
                    try self.queue.append(self.arena, .{ .err = .{ .error_value = .{ .string = failure.message } } });
                    return;
                },
                .success => |success| {
                    if (success.value == .object and success.value.object.get("error") != null) {
                        try api.streamError(self.arena, success.value, url, request_body_json, response_headers, self.diag);
                        unreachable;
                    }
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = success.value } });
                    const is_output = isOutputChunk(success.value);
                    try self.mapChunk(success.value);
                    if (is_output) return;
                },
            }
        }
    }

    fn fillQueue(self: *StreamState) provider.NextError!void {
        while (self.queue.items.len == 0) {
            const event = self.events.next(self.arena) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidResponse(self.arena, self.diag, @errorName(err)),
            };
            if (event == null) {
                try self.flush();
                return;
            }
            switch (event.?) {
                .failure => |failure| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = .{ .string = failure.raw } } });
                    self.finish_reason = .{ .unified = .@"error" };
                    try self.queue.append(self.arena, .{ .err = .{ .error_value = .{ .string = failure.message } } });
                },
                .success => |success| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = success.value } });
                    try self.mapChunk(success.value);
                },
            }
        }
    }

    fn mapChunk(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (value != .object) {
            self.finish_reason = .{ .unified = .@"error" };
            try self.queue.append(self.arena, .{ .err = .{ .error_value = value } });
            return;
        }
        const root = value.object;
        if (root.get("error")) |error_value| {
            self.finish_reason = .{ .unified = .@"error" };
            try self.queue.append(self.arena, .{ .err = .{ .error_value = error_value } });
            return;
        }
        if (!self.metadata_extracted) {
            const id = optionalStringField(root, "id");
            const model_id = optionalStringField(root, "model");
            const timestamp = timestampMillis(root.get("created"));
            if ((id != null and id.?.len != 0) or (model_id != null and model_id.?.len != 0) or timestamp != null) {
                self.metadata_extracted = true;
                try self.queue.append(self.arena, .{ .response_metadata = .{
                    .id = id,
                    .timestamp_ms = timestamp,
                    .model_id = model_id,
                } });
            }
        }
        if (root.get("usage")) |usage| {
            if (usage != .null) self.usage = usage;
        }
        const choices = root.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice_value = choices.array.items[0];
        if (choice_value != .object) return;
        const choice = choice_value.object;
        if (optionalStringField(choice, "finish_reason")) |raw| self.finish_reason = .{
            .unified = mapFinishReason(raw),
            .raw = raw,
        };
        if (choice.get("logprobs")) |value_logprobs| {
            if (value_logprobs != .null) self.logprobs = value_logprobs;
        }
        const delta = objectField(choice, "delta") orelse return;
        if (delta.get("content")) |content| if (content == .string) {
            if (!self.active_text) {
                try self.queue.append(self.arena, .{ .text_start = .{ .id = "0" } });
                self.active_text = true;
            }
            try self.queue.append(self.arena, .{ .text_delta = .{ .id = "0", .delta = content.string } });
        };
        if (delta.get("tool_calls")) |tool_calls| if (tool_calls == .array) {
            for (tool_calls.array.items) |tool_delta| try self.processToolDelta(tool_delta);
        };
        if (delta.get("annotations")) |annotations| if (annotations == .array) {
            for (annotations.array.items) |annotation| {
                const annotation_object = if (annotation == .object) annotation.object else continue;
                const citation = objectField(annotation_object, "url_citation") orelse continue;
                const url = optionalStringField(citation, "url") orelse continue;
                try self.queue.append(self.arena, .{ .source = .{ .url = .{
                    .id = try self.id_generator.nextAlloc(self.arena),
                    .url = url,
                    .title = optionalStringField(citation, "title"),
                } } });
            }
        };
    }

    fn processToolDelta(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (value != .object) return;
        const function = objectField(value.object, "function");
        const parts = try self.tracker.handleDelta(.{
            .index = optionalIndex(value.object.get("index")),
            .id = optionalStringField(value.object, "id"),
            .type = optionalStringField(value.object, "type"),
            .function = if (function) |item| .{
                .name = optionalStringField(item, "name"),
                .arguments = optionalStringField(item, "arguments"),
            } else null,
        }, self.diag);
        try self.appendTrackerParts(parts);
    }

    fn appendTrackerParts(self: *StreamState, input: []const provider.StreamPart) Allocator.Error!void {
        for (input) |part| {
            const owned = switch (part) {
                .tool_input_delta => |delta| provider.StreamPart{ .tool_input_delta = .{
                    .id = delta.id,
                    .delta = try self.arena.dupe(u8, delta.delta),
                    .provider_metadata = delta.provider_metadata,
                } },
                else => part,
            };
            try self.queue.append(self.arena, owned);
        }
    }

    fn flush(self: *StreamState) provider.NextError!void {
        if (self.flushed) return;
        if (self.active_text) {
            try self.queue.append(self.arena, .{ .text_end = .{ .id = "0" } });
            self.active_text = false;
        }
        try self.appendTrackerParts(try self.tracker.flush());
        const usage_value = self.usage orelse std.json.Value.null;
        try self.queue.append(self.arena, .{ .finish = .{
            .finish_reason = self.finish_reason,
            .usage = try convertUsage(self.arena, usage_value),
            .provider_metadata = try makeProviderMetadata(self.arena, self.metadata_key, usage_value, self.logprobs),
        } });
        self.flushed = true;
    }
};

fn isOutputChunk(value: std.json.Value) bool {
    if (value != .object) return false;
    const choices = value.object.get("choices") orelse return false;
    if (choices != .array) return false;
    for (choices.array.items) |choice_value| {
        if (choice_value != .object) continue;
        const delta = objectField(choice_value.object, "delta") orelse continue;
        if (optionalStringField(delta, "content")) |content| if (content.len != 0) return true;
        if (delta.get("tool_calls")) |tools| if (tools == .array and tools.array.items.len != 0) return true;
        if (delta.get("annotations")) |annotations| if (annotations == .array and annotations.array.items.len != 0) return true;
    }
    return false;
}

fn convertUsage(arena: Allocator, value: std.json.Value) Allocator.Error!provider.Usage {
    if (value != .object) return .{ .input_tokens = .{}, .output_tokens = .{} };
    const prompt_tokens = optionalU64(value.object.get("prompt_tokens")) orelse 0;
    const completion_tokens = optionalU64(value.object.get("completion_tokens")) orelse 0;
    const cached_tokens = nestedU64(value.object, "prompt_tokens_details", "cached_tokens") orelse 0;
    const cache_write_tokens = nestedU64(value.object, "prompt_tokens_details", "cache_write_tokens");
    const reasoning_tokens = nestedU64(value.object, "completion_tokens_details", "reasoning_tokens") orelse 0;
    return .{
        .input_tokens = .{
            .total = prompt_tokens,
            .no_cache = prompt_tokens -| cached_tokens -| (cache_write_tokens orelse 0),
            .cache_read = cached_tokens,
            .cache_write = cache_write_tokens,
        },
        .output_tokens = .{
            .total = completion_tokens,
            .text = completion_tokens -| reasoning_tokens,
            .reasoning = reasoning_tokens,
        },
        .raw = try provider_utils.cloneJsonValue(arena, value),
    };
}

fn makeProviderMetadata(
    arena: Allocator,
    key: []const u8,
    usage: std.json.Value,
    logprobs_value: ?std.json.Value,
) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    if (usage == .object) {
        if (nestedU64(usage.object, "completion_tokens_details", "accepted_prediction_tokens")) |value| {
            try details.put(arena, "acceptedPredictionTokens", try uintValue(arena, value));
        }
        if (nestedU64(usage.object, "completion_tokens_details", "rejected_prediction_tokens")) |value| {
            try details.put(arena, "rejectedPredictionTokens", try uintValue(arena, value));
        }
    }
    if (logprobs_value) |logprobs| if (logprobs == .object) {
        if (logprobs.object.get("content")) |content| if (content != .null) {
            try details.put(arena, "logprobs", try provider_utils.cloneJsonValue(arena, content));
        };
    };
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, try arena.dupe(u8, key), .{ .object = details });
    return .{ .object = root };
}

fn mapFinishReason(value: ?[]const u8) provider.FinishReasonUnified {
    const reason = value orelse return .other;
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, reason, "function_call") or std.mem.eql(u8, reason, "tool_calls")) return .tool_calls;
    return .other;
}

fn reasoningName(value: ?provider.ReasoningEffort) ?[]const u8 {
    return switch (value orelse return null) {
        .provider_default => null,
        .none => "none",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn timestampMillis(value: ?std.json.Value) ?i64 {
    const seconds = value orelse return null;
    const number: i64 = switch (seconds) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => return null,
    };
    if (number == 0) return null;
    return std.math.mul(i64, number, 1000) catch null;
}

fn optionalIndex(value: ?std.json.Value) ?usize {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        else => null,
    };
}

fn nestedU64(object: std.json.ObjectMap, outer: []const u8, inner: []const u8) ?u64 {
    const nested = objectField(object, outer) orelse return null;
    return optionalU64(nested.get(inner));
}

fn optionalStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(object: std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    const value = object.get(field) orelse return null;
    return if (value == .object) value.object else null;
}

fn requireObject(value: std.json.Value, arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error!std.json.ObjectMap {
    return if (value == .object) value.object else invalidResponse(arena, diag, message);
}

fn requireObjectField(object: std.json.ObjectMap, field: []const u8, arena: Allocator, diag: ?*provider.Diagnostics) provider.Error!std.json.ObjectMap {
    const value = object.get(field) orelse return invalidResponse(arena, diag, "Required OpenAI response object is missing");
    return requireObject(value, arena, diag, "Required OpenAI response field must be an object");
}

fn requireArrayField(object: std.json.ObjectMap, field: []const u8, arena: Allocator, diag: ?*provider.Diagnostics) provider.Error!std.json.Array {
    const value = object.get(field) orelse return invalidResponse(arena, diag, "Required OpenAI response array is missing");
    return if (value == .array) value.array else invalidResponse(arena, diag, "Required OpenAI response field must be an array");
}

fn invalidResponse(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
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

fn stringArray(arena: Allocator, values: []const []const u8) Allocator.Error!std.json.Value {
    var array = std.json.Array.init(arena);
    for (values) |value| try array.append(.{ .string = try arena.dupe(u8, value) });
    return .{ .array = array };
}

fn uintValue(arena: Allocator, value: u64) Allocator.Error!std.json.Value {
    if (value <= std.math.maxInt(i64)) return .{ .integer = @intCast(value) };
    return .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{value}) };
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn testConfig(
    base_url: []const u8,
    transport: provider_utils.HttpTransport,
) config_api.Config {
    return .{
        .base_url = base_url,
        .api_key = "test-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = transport,
        .provider_name = "openai",
        .provider_options_name = "openai",
    };
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "OpenAI Chat getArgs strips reasoning parameters and maps structured messages and options" {
    const allocator = std.testing.allocator;
    var client = provider_utils.HttpClientTransport.init(allocator, std.testing.io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"openai\":{\"imageDetail\":\"high\"}}",
        .{},
    );
    const tool_input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"city\":\"Paris\"}",
        .{},
    );
    const tool_output = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"condition\":\"sunny\"}",
        .{},
    );
    const user_content = [_]provider.UserContentPart{
        .{ .text = .{ .text = "What is shown?" } },
        .{ .file = .{
            .filename = "pixel.png",
            .data = .{ .data = .{ .data = .{ .bytes = &.{ 0x89, 0x50, 0x4e, 0x47 } } } },
            .media_type = "image/png",
            .provider_options = image_options,
        } },
    };
    const assistant_content = [_]provider.AssistantContentPart{
        .{ .text = .{ .text = "Checking" } },
        .{ .tool_call = .{
            .tool_call_id = "call-weather",
            .tool_name = "weather",
            .input = tool_input,
        } },
    };
    const tool_content = [_]provider.ToolContentPart{.{ .tool_result = .{
        .tool_call_id = "call-weather",
        .tool_name = "weather",
        .output = .{ .json = .{ .value = tool_output } },
    } }};
    const prompt = [_]provider.Message{
        .{ .system = .{ .content = "You are concise." } },
        .{ .user = .{ .content = &user_content } },
        .{ .assistant = .{ .content = &assistant_content } },
        .{ .tool = .{ .content = &tool_content } },
    };
    const reasoning_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"openai\":{\"logitBias\":{\"42\":-1},\"logprobs\":3}}",
        .{},
    );
    var reasoning_model = try ChatLanguageModel.init(
        "o1-mini",
        testConfig("https://example.invalid/v1", client.transport()),
        null,
    );
    const stripped = try reasoning_model.prepareRequest(arena, &.{
        .prompt = &prompt,
        .max_output_tokens = 120,
        .temperature = 0.7,
        .top_p = 0.8,
        .top_k = 4,
        .frequency_penalty = 0.1,
        .presence_penalty = 0.2,
        .provider_options = reasoning_options,
    }, false, null);
    const stripped_body = stripped.body.object;
    try std.testing.expect(stripped_body.get("temperature") == null);
    try std.testing.expect(stripped_body.get("top_p") == null);
    try std.testing.expect(stripped_body.get("frequency_penalty") == null);
    try std.testing.expect(stripped_body.get("presence_penalty") == null);
    try std.testing.expect(stripped_body.get("logit_bias") == null);
    try std.testing.expect(stripped_body.get("logprobs") == null);
    try std.testing.expect(stripped_body.get("max_tokens") == null);
    try std.testing.expectEqual(120, stripped_body.get("max_completion_tokens").?.integer);
    try std.testing.expectEqual(8, stripped.warnings.len);

    const messages = stripped_body.get("messages").?.array.items;
    try std.testing.expectEqualStrings("developer", messages[0].object.get("role").?.string);
    const user_parts = messages[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", user_parts[0].object.get("type").?.string);
    const image = user_parts[1].object.get("image_url").?.object;
    try std.testing.expect(std.mem.startsWith(u8, image.get("url").?.string, "data:image/png;base64,"));
    try std.testing.expectEqualStrings("high", image.get("detail").?.string);
    const assistant = messages[2].object;
    try std.testing.expectEqualStrings("Checking", assistant.get("content").?.string);
    try std.testing.expectEqualStrings(
        "{\"city\":\"Paris\"}",
        assistant.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string,
    );
    try std.testing.expectEqualStrings("tool", messages[3].object.get("role").?.string);
    try std.testing.expectEqualStrings("{\"condition\":\"sunny\"}", messages[3].object.get("content").?.string);

    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}}}",
        .{},
    );
    const advanced_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        \\{"openai":{"parallelToolCalls":false,"user":"user-1","reasoningEffort":"none","maxCompletionTokens":77,"store":true,"metadata":{"trace":"abc"},"prediction":{"type":"content","content":"expected"},"serviceTier":"flex","strictJsonSchema":false,"textVerbosity":"low","promptCacheKey":"cache-1","promptCacheOptions":{"retention":"24h"},"promptCacheRetention":"24h","safetyIdentifier":"safe-1","logprobs":2}}
    ,
        .{},
    );
    const simple_prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "Hello" } }} } }};
    var advanced_model = try ChatLanguageModel.init(
        "gpt-5.1",
        testConfig("https://example.invalid/v1", client.transport()),
        null,
    );
    const advanced = try advanced_model.prepareRequest(arena, &.{
        .prompt = &simple_prompt,
        .max_output_tokens = 120,
        .temperature = 0.4,
        .top_p = 0.9,
        .stop_sequences = &.{ "END", "STOP" },
        .seed = 17,
        .response_format = .{ .json = .{
            .schema = schema,
            .name = "answer",
            .description = "Structured answer",
        } },
        .provider_options = advanced_options,
    }, true, null);
    const body = advanced.body.object;
    try std.testing.expectEqual(0.4, body.get("temperature").?.float);
    try std.testing.expectEqual(0.9, body.get("top_p").?.float);
    try std.testing.expectEqual(77, body.get("max_completion_tokens").?.integer);
    try std.testing.expectEqualStrings("none", body.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("flex", body.get("service_tier").?.string);
    try std.testing.expectEqualStrings("low", body.get("verbosity").?.string);
    try std.testing.expectEqualStrings("cache-1", body.get("prompt_cache_key").?.string);
    try std.testing.expectEqualStrings("24h", body.get("prompt_cache_retention").?.string);
    try std.testing.expectEqualStrings("safe-1", body.get("safety_identifier").?.string);
    try std.testing.expect(!body.get("parallel_tool_calls").?.bool);
    try std.testing.expect(body.get("store").?.bool);
    try std.testing.expect(body.get("logprobs").?.bool);
    try std.testing.expect(body.get("top_logprobs") == null);
    try std.testing.expect(body.get("stream").?.bool);
    try std.testing.expect(body.get("stream_options").?.object.get("include_usage").?.bool);
    const response_schema = body.get("response_format").?.object.get("json_schema").?.object;
    try std.testing.expect(!response_schema.get("strict").?.bool);
    try std.testing.expectEqualStrings("answer", response_schema.get("name").?.string);
    try std.testing.expectEqualStrings("Structured answer", response_schema.get("description").?.string);
}

test "OpenAI Chat doGenerate maps text tools citations usage metadata and headers" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "request-1" }},
        .body = .{ .text =
        \\{"id":"chatcmpl-1","created":1711115037,"model":"gpt-4o-mini","choices":[{"message":{"role":"assistant","content":"Hello","tool_calls":[{"type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}],"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/source","title":"Example"}}]},"finish_reason":"tool_calls","logprobs":{"content":[{"token":"Hello","logprob":-0.1,"top_logprobs":[]}]}}],"usage":{"prompt_tokens":12,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":2},"completion_tokens_details":{"reasoning_tokens":3,"accepted_prediction_tokens":2,"rejected_prediction_tokens":1}}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    var config = testConfig(server.baseUrl(&base_buffer), client.transport());
    config.organization = "org-1";
    config.project = "project-1";
    config.headers = .{ .static = &.{.{ .name = "x-static", .value = "static" }} };
    var model = try ChatLanguageModel.init("gpt-4o-mini", config, null);
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "Hello" } }} } }};
    const call_headers = [_]provider.Header{.{ .name = "x-call", .value = "call" }};
    const result = try model.languageModel().doGenerate(io, arena, &.{
        .prompt = &prompt,
        .headers = &call_headers,
    }, null);

    try std.testing.expectEqual(3, result.content.len);
    try std.testing.expectEqualStrings("Hello", result.content[0].text.text);
    try std.testing.expect(std.mem.startsWith(u8, result.content[1].tool_call.tool_call_id, "call-"));
    try std.testing.expectEqualStrings("weather", result.content[1].tool_call.tool_name);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", result.content[1].tool_call.input);
    try std.testing.expectEqualStrings("https://example.com/source", result.content[2].source.url.url);
    try std.testing.expectEqualStrings("Example", result.content[2].source.url.title.?);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, result.finish_reason.unified);
    try std.testing.expectEqualStrings("tool_calls", result.finish_reason.raw.?);
    try std.testing.expectEqual(12, result.usage.input_tokens.total.?);
    try std.testing.expectEqual(10, result.usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(2, result.usage.input_tokens.cache_read.?);
    try std.testing.expectEqual(7, result.usage.output_tokens.total.?);
    try std.testing.expectEqual(4, result.usage.output_tokens.text.?);
    try std.testing.expectEqual(3, result.usage.output_tokens.reasoning.?);
    const metadata = result.provider_metadata.?.object.get("openai").?.object;
    try std.testing.expectEqual(2, metadata.get("acceptedPredictionTokens").?.integer);
    try std.testing.expectEqual(1, metadata.get("rejectedPredictionTokens").?.integer);
    try std.testing.expectEqualStrings("Hello", metadata.get("logprobs").?.array.items[0].object.get("token").?.string);
    try std.testing.expectEqual(1711115037000, result.response.?.timestamp_ms.?);
    try std.testing.expectEqualStrings("request-1", recordedHeader(result.response.?.headers.?, "x-request-id").?);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqualStrings("/chat/completions", requests[0].target);
    try std.testing.expectEqualStrings("Bearer test-key", recordedHeader(requests[0].headers, "authorization").?);
    try std.testing.expectEqualStrings("org-1", recordedHeader(requests[0].headers, "OpenAI-Organization").?);
    try std.testing.expectEqualStrings("project-1", recordedHeader(requests[0].headers, "OpenAI-Project").?);
    try std.testing.expectEqualStrings("static", recordedHeader(requests[0].headers, "x-static").?);
    try std.testing.expectEqualStrings("call", recordedHeader(requests[0].headers, "x-call").?);
    try std.testing.expect(std.mem.indexOf(
        u8,
        recordedHeader(requests[0].headers, "user-agent").?,
        "ai-sdk-zig/openai/",
    ) != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI Chat doStream tracks tool deltas citations and flush usage" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"chatcmpl-stream\",\"created\":1711115037,\"model\":\"gpt-4o-mini\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}" },
            .{ .data = "{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}" },
            .{ .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-weather\",\"type\":\"function\",\"function\":{\"name\":\"weather\",\"arguments\":\"{\\\"city\\\"\"}}]}}]}" },
            .{ .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"Paris\\\"}\"}}]}}]}" },
            .{ .data = "{\"choices\":[{\"delta\":{\"annotations\":[{\"type\":\"url_citation\",\"url_citation\":{\"url\":\"https://example.com/stream\",\"title\":\"Stream\"}}]}}]}" },
            .{ .data = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}" },
            .{ .data = "{\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":3,\"completion_tokens_details\":{\"reasoning_tokens\":1,\"accepted_prediction_tokens\":1}}}" },
            .{ .data = "[DONE]" },
        } },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    var model = try ChatLanguageModel.init(
        "gpt-4o-mini",
        testConfig(server.baseUrl(&base_buffer), client.transport()),
        null,
    );
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "Hello" } }} } }};
    const result = try model.languageModel().doStream(io, arena, &.{ .prompt = &prompt }, null);
    defer result.stream.deinit(io);

    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(allocator);
    var text_bytes: std.ArrayList(u8) = .empty;
    defer text_bytes.deinit(allocator);
    var tool_input: ?[]u8 = null;
    defer if (tool_input) |value| allocator.free(value);
    var saw_source = false;
    var finish_reason: ?provider.FinishReason = null;
    var finish_usage: ?provider.Usage = null;
    var finish_metadata: ?provider.ProviderMetadata = null;
    while (try result.stream.next(io)) |part| {
        try tags.append(allocator, std.meta.activeTag(part));
        switch (part) {
            .text_delta => |delta| try text_bytes.appendSlice(allocator, delta.delta),
            .tool_call => |call| tool_input = try allocator.dupe(u8, call.input),
            .source => |source| {
                saw_source = true;
                try std.testing.expectEqualStrings("https://example.com/stream", source.url.url);
            },
            .finish => |value| {
                finish_reason = value.finish_reason;
                finish_usage = value.usage;
                finish_metadata = value.provider_metadata;
            },
            else => {},
        }
    }
    try std.testing.expectEqualStrings("Hello", text_bytes.items);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", tool_input.?);
    try std.testing.expect(saw_source);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(provider.StreamPart), tags.items, .text_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(provider.StreamPart), tags.items, .text_end) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(provider.StreamPart), tags.items, .tool_input_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(provider.StreamPart), tags.items, .tool_input_end) != null);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, finish_reason.?.unified);
    try std.testing.expectEqual(4, finish_usage.?.input_tokens.total.?);
    try std.testing.expectEqual(3, finish_usage.?.output_tokens.total.?);
    try std.testing.expectEqual(2, finish_usage.?.output_tokens.text.?);
    try std.testing.expectEqual(1, finish_usage.?.output_tokens.reasoning.?);
    try std.testing.expectEqual(
        1,
        finish_metadata.?.object.get("openai").?.object.get("acceptedPredictionTokens").?.integer,
    );
    const request_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        server.recordedRequests()[0].body,
        .{},
    );
    try std.testing.expect(request_json.object.get("stream").?.bool);
    try std.testing.expect(request_json.object.get("stream_options").?.object.get("include_usage").?.bool);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI Chat rejects an authentication error frame before output" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"error\":{\"message\":\"Incorrect API key\",\"type\":\"authentication_error\"}}" },
            .{ .data = "[DONE]" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ChatLanguageModel.init(
        "gpt-4o-mini",
        testConfig(server.baseUrl(&base_buffer), client.transport()),
        null,
    );
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "Hello" } }} } }};
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.APICallError,
        model.languageModel().doStream(io, arena_state.allocator(), &.{ .prompt = &prompt }, &diagnostics),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqual(401, diagnostics.payload.api_call.status_code.?);
    try std.testing.expect(!diagnostics.payload.api_call.is_retryable);
    try std.testing.expectEqualStrings("Incorrect API key", diagnostics.payload.api_call.message);
    try std.testing.expectEqual(0, server.serveErrorCount());
}
