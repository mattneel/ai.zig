const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");
const options_api = @import("options.zig");
const prompt_api = @import("prompt.zig");
const schema_api = @import("schema.zig");
const tools_api = @import("tools.zig");

const Allocator = std.mem.Allocator;
const BuildError = provider.Error || Allocator.Error;

pub const PreparedRequest = struct {
    body: std.json.Value,
    warnings: []const provider.Warning,
};

pub const GoogleLanguageModel = struct {
    model_id: []const u8,
    config: config_api.Config,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!GoogleLanguageModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "Google language model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "Google provider name is required");
        return .{ .model_id = model_id, .config = config };
    }

    pub fn languageModel(self: *GoogleLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn model(self: *GoogleLanguageModel) provider.LanguageModel {
        return self.languageModel();
    }

    pub fn prepareRequest(
        self: *GoogleLanguageModel,
        arena: Allocator,
        call_options: *const provider.CallOptions,
        stream: bool,
        diag: ?*provider.Diagnostics,
    ) BuildError!PreparedRequest {
        return self.buildArgs(arena, call_options, stream, diag);
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .urlIsSupported = vUrlIsSupported,
        .doGenerate = vDoGenerate,
        .doStream = vDoStream,
    };

    fn fromRaw(raw: *anyopaque) *GoogleLanguageModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        return fromRaw(raw).config.provider_name;
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vUrlIsSupported(raw: *anyopaque, media_type: []const u8, url: []const u8) bool {
        const self = fromRaw(raw);
        if (std.mem.startsWith(u8, url, self.config.base_url) and
            url.len > self.config.base_url.len and
            std.mem.startsWith(u8, url[self.config.base_url.len..], "/files/")) return true;
        if (isYouTubeUrl(url)) return true;
        return supportsExternalFileUrls(self.model_id) and
            std.mem.startsWith(u8, url, "https://") and
            supportedExternalMediaType(media_type);
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return fromRaw(raw).doGenerate(io, arena, call_options, diag);
    }

    fn vDoStream(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return fromRaw(raw).doStream(io, arena, call_options, diag);
    }

    fn doGenerate(
        self: *GoogleLanguageModel,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const prepared = try self.buildArgs(arena, call_options, false, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const model_path = try getModelPath(arena, self.model_id);
        const url = try std.fmt.allocPrint(arena, "{s}/{s}:generateContent", .{ self.config.base_url, model_path });
        const headers = try config_api.resolveHeaders(self.config, arena, call_options.headers, diag);
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
        return mapGenerateResponse(io, arena, prepared, result.value, result.response_headers, diag);
    }

    fn doStream(
        self: *GoogleLanguageModel,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const prepared = try self.buildArgs(arena, call_options, true, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const model_path = try getModelPath(arena, self.model_id);
        const url = try std.fmt.allocPrint(arena, "{s}/{s}:streamGenerateContent?alt=sse", .{ self.config.base_url, model_path });
        const headers = try config_api.resolveHeaders(self.config, arena, call_options.headers, diag);
        const EventStream = provider_utils.JsonEventStream(std.json.Value);
        const result = try provider_utils.postJsonToApi(
            EventStream,
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
            .include_raw = call_options.include_raw_chunks orelse false,
            .diag = diag,
            .id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag),
        };
        try state.queue.append(arena, .{ .stream_start = .{ .warnings = prepared.warnings } });
        return .{
            .stream = .{ .ctx = state, .vtable = &StreamState.vtable },
            .request = .{ .body = prepared.body },
            .response = .{ .headers = result.response_headers },
        };
    }

    fn buildArgs(
        self: *GoogleLanguageModel,
        arena: Allocator,
        call_options: *const provider.CallOptions,
        stream: bool,
        diag: ?*provider.Diagnostics,
    ) BuildError!PreparedRequest {
        var warnings: std.ArrayList(provider.Warning) = .empty;
        defer warnings.deinit(arena);
        const google_options = try options_api.parseLanguage(arena, call_options.provider_options, diag);
        if (google_options.stream_function_call_arguments == true) try warnings.append(arena, .{ .other = .{
            .message = "'streamFunctionCallArguments' is only supported on the Vertex AI API and is ignored by the native Google Generative AI provider.",
        } });
        if (google_options.shared_request_type != null or google_options.request_type != null) try warnings.append(arena, .{ .other = .{
            .message = "'sharedRequestType' and 'requestType' are Vertex AI options and are ignored by the native Google Generative AI provider.",
        } });

        const converted_prompt = try prompt_api.convert(arena, call_options.prompt, self.model_id, diag);
        try warnings.appendSlice(arena, converted_prompt.warnings);
        const prepared_tools = try tools_api.prepare(arena, call_options.tools, call_options.tool_choice, self.model_id);
        try warnings.appendSlice(arena, prepared_tools.warnings);

        var generation_config: std.json.ObjectMap = .empty;
        if (call_options.max_output_tokens) |value| try putU64(&generation_config, arena, "maxOutputTokens", value, diag);
        if (call_options.temperature) |value| try generation_config.put(arena, "temperature", .{ .float = value });
        if (call_options.top_k) |value| try generation_config.put(arena, "topK", .{ .float = value });
        if (call_options.top_p) |value| try generation_config.put(arena, "topP", .{ .float = value });
        if (call_options.frequency_penalty) |value| try generation_config.put(arena, "frequencyPenalty", .{ .float = value });
        if (call_options.presence_penalty) |value| try generation_config.put(arena, "presencePenalty", .{ .float = value });
        if (call_options.stop_sequences) |values| try generation_config.put(arena, "stopSequences", try stringArray(arena, values));
        if (call_options.seed) |value| try generation_config.put(arena, "seed", .{ .integer = value });

        if (call_options.response_format) |format| switch (format) {
            .text => {},
            .json => |json| {
                try putString(&generation_config, arena, "responseMimeType", "application/json");
                if ((google_options.structured_outputs orelse true) and json.schema != null) {
                    if (try schema_api.convert(arena, json.schema.?)) |converted| {
                        try generation_config.put(arena, "responseSchema", converted);
                    }
                }
            },
        };
        if (google_options.audio_timestamp) |value| try generation_config.put(arena, "audioTimestamp", .{ .bool = value });
        if (google_options.response_modalities) |value| try generation_config.put(arena, "responseModalities", try provider_utils.cloneJsonValue(arena, value));
        if (try resolvedThinkingConfig(arena, self.model_id, call_options.reasoning, google_options.thinking_config, &warnings)) |thinking| {
            try generation_config.put(arena, "thinkingConfig", thinking);
        }
        if (google_options.media_resolution) |value| try putString(&generation_config, arena, "mediaResolution", value);
        if (google_options.image_config) |value| try generation_config.put(arena, "imageConfig", try provider_utils.cloneJsonValue(arena, value));

        var body: std.json.ObjectMap = .empty;
        try body.put(arena, "generationConfig", .{ .object = generation_config });
        try body.put(arena, "contents", converted_prompt.contents);
        if (converted_prompt.system_instruction) |value| try body.put(arena, "systemInstruction", value);
        if (google_options.safety_settings) |value| {
            try body.put(arena, "safetySettings", try provider_utils.cloneJsonValue(arena, value));
        } else if (google_options.threshold) |threshold| {
            try body.put(arena, "safetySettings", try expandedSafetySettings(arena, threshold));
        }
        if (prepared_tools.tools) |value| try body.put(arena, "tools", value);

        var tool_config: ?std.json.Value = if (prepared_tools.tool_config) |value|
            try provider_utils.cloneJsonValue(arena, value)
        else
            null;
        if (google_options.retrieval_config) |retrieval| {
            if (tool_config == null) tool_config = .{ .object = .empty };
            try tool_config.?.object.put(arena, "retrievalConfig", try provider_utils.cloneJsonValue(arena, retrieval));
        }
        if (tool_config) |value| try body.put(arena, "toolConfig", value);
        if (google_options.cached_content) |value| try putString(&body, arena, "cachedContent", value);
        if (google_options.labels) |value| try body.put(arena, "labels", try provider_utils.cloneJsonValue(arena, value));
        if (google_options.service_tier) |value| try putString(&body, arena, "serviceTier", value);
        _ = stream;
        return .{ .body = .{ .object = body }, .warnings = try warnings.toOwnedSlice(arena) };
    }
};

fn resolvedThinkingConfig(
    arena: Allocator,
    model_id: []const u8,
    reasoning: ?provider.ReasoningEffort,
    explicit: ?std.json.Value,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!?std.json.Value {
    var output: ?std.json.Value = null;
    if (reasoning) |effort| if (effort != .provider_default) {
        var object: std.json.ObjectMap = .empty;
        if (isGemini3(model_id) and !contains(model_id, "gemini-3-pro-image")) {
            const level = switch (effort) {
                .none, .minimal => "minimal",
                .low => "low",
                .medium => "medium",
                .high, .xhigh => "high",
                .provider_default => unreachable,
            };
            if (effort == .xhigh) try warnings.append(arena, .{ .compatibility = .{
                .feature = "reasoning",
                .details = "reasoning \"xhigh\" is not directly supported by this model. mapped to effort \"high\".",
            } });
            try putString(&object, arena, "thinkingLevel", level);
        } else {
            const budget: u64 = switch (effort) {
                .none => 0,
                .minimal => 1311,
                .low => 6554,
                .medium => 19661,
                .high => @min(39322, maxThinkingTokens(model_id)),
                .xhigh => @min(58982, maxThinkingTokens(model_id)),
                .provider_default => unreachable,
            };
            try object.put(arena, "thinkingBudget", .{ .integer = @intCast(budget) });
        }
        output = .{ .object = object };
    };
    if (explicit) |value| {
        if (output == null) output = .{ .object = .empty };
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            try output.?.object.put(
                arena,
                try arena.dupe(u8, entry.key_ptr.*),
                try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
            );
        }
    }
    return output;
}

fn expandedSafetySettings(arena: Allocator, threshold: []const u8) Allocator.Error!std.json.Value {
    const categories = [_][]const u8{
        "HARM_CATEGORY_HATE_SPEECH",
        "HARM_CATEGORY_DANGEROUS_CONTENT",
        "HARM_CATEGORY_HARASSMENT",
        "HARM_CATEGORY_SEXUALLY_EXPLICIT",
    };
    var output = std.json.Array.init(arena);
    for (categories) |category| {
        var entry: std.json.ObjectMap = .empty;
        try putString(&entry, arena, "category", category);
        try putString(&entry, arena, "threshold", threshold);
        try output.append(.{ .object = entry });
    }
    return .{ .array = output };
}

fn getModelPath(arena: Allocator, model_id: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, model_id, '/') != null) return arena.dupe(u8, model_id);
    return std.fmt.allocPrint(arena, "models/{s}", .{model_id});
}

fn mapGenerateResponse(
    io: std.Io,
    arena: Allocator,
    prepared: PreparedRequest,
    response: std.json.Value,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.CallError!provider.GenerateResult {
    const root = try requireObject(response, arena, diag, "Google response must be an object");
    const candidates = try requireArrayField(root, "candidates", arena, diag);
    if (candidates.items.len == 0) return invalidResponse(arena, diag, "Google response has no candidates");
    const candidate = try requireObject(candidates.items[0], arena, diag, "Google candidate must be an object");
    var generated_ids = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag);
    var content_items: std.ArrayList(provider.Content) = .empty;
    defer content_items.deinit(arena);
    var has_client_tool_calls = false;
    var last_code_execution_id: ?[]const u8 = null;
    var last_server_tool_call_id: ?[]const u8 = null;

    if (candidate.get("content")) |content_value| if (content_value == .object) {
        if (content_value.object.get("parts")) |parts| if (parts == .array) for (parts.array.items) |part_value| {
            if (part_value != .object) continue;
            const part = part_value.object;
            if (part.get("executableCode")) |executable| if (executable == .object and optionalStringField(executable.object, "code") != null) {
                const id = try generated_ids.nextAlloc(arena);
                last_code_execution_id = id;
                try content_items.append(arena, .{ .tool_call = .{
                    .tool_call_id = id,
                    .tool_name = "code_execution",
                    .input = try provider_utils.stringifyJsonValueAlloc(arena, executable),
                    .provider_executed = true,
                } });
                continue;
            };
            if (part.get("codeExecutionResult")) |execution_result| if (execution_result == .object) {
                var result_value: std.json.ObjectMap = .empty;
                if (optionalStringField(execution_result.object, "outcome")) |outcome| try putString(&result_value, arena, "outcome", outcome);
                try putString(&result_value, arena, "output", optionalStringField(execution_result.object, "output") orelse "");
                try content_items.append(arena, .{ .tool_result = .{
                    .tool_call_id = last_code_execution_id orelse try generated_ids.nextAlloc(arena),
                    .tool_name = "code_execution",
                    .result = .{ .object = result_value },
                } });
                last_code_execution_id = null;
                continue;
            };
            if (optionalStringField(part, "text")) |text| {
                if (text.len != 0) {
                    const metadata = try thoughtMetadata(arena, optionalStringField(part, "thoughtSignature"));
                    if (optionalBoolField(part, "thought") == true) {
                        try content_items.append(arena, .{ .reasoning = .{ .text = try arena.dupe(u8, text), .provider_metadata = metadata } });
                    } else {
                        try content_items.append(arena, .{ .text = .{ .text = try arena.dupe(u8, text), .provider_metadata = metadata } });
                    }
                }
                continue;
            }
            if (part.get("functionCall")) |function_call| if (function_call == .object) {
                const name = optionalStringField(function_call.object, "name") orelse continue;
                const id = optionalStringField(function_call.object, "id") orelse try generated_ids.nextAlloc(arena);
                const arguments = function_call.object.get("args") orelse std.json.Value{ .object = .empty };
                const input = if (arguments == .string)
                    try arena.dupe(u8, arguments.string)
                else
                    try provider_utils.stringifyJsonValueAlloc(arena, arguments);
                try content_items.append(arena, .{ .tool_call = .{
                    .tool_call_id = try arena.dupe(u8, id),
                    .tool_name = try arena.dupe(u8, name),
                    .input = input,
                    .provider_metadata = try thoughtMetadata(arena, optionalStringField(part, "thoughtSignature")),
                } });
                has_client_tool_calls = true;
                continue;
            };
            if (part.get("toolCall")) |tool_call| if (tool_call == .object) {
                const tool_type = optionalStringField(tool_call.object, "toolType") orelse continue;
                const id = optionalStringField(tool_call.object, "id") orelse try generated_ids.nextAlloc(arena);
                last_server_tool_call_id = id;
                const arguments = tool_call.object.get("args") orelse std.json.Value{ .object = .empty };
                try content_items.append(arena, .{ .tool_call = .{
                    .tool_call_id = try arena.dupe(u8, id),
                    .tool_name = try std.fmt.allocPrint(arena, "server:{s}", .{tool_type}),
                    .input = try provider_utils.stringifyJsonValueAlloc(arena, arguments),
                    .provider_executed = true,
                    .dynamic = true,
                    .provider_metadata = try serverToolMetadata(
                        arena,
                        id,
                        tool_type,
                        optionalStringField(part, "thoughtSignature"),
                    ),
                } });
                continue;
            };
            if (part.get("toolResponse")) |tool_response| if (tool_response == .object) {
                const tool_type = optionalStringField(tool_response.object, "toolType") orelse continue;
                const id = last_server_tool_call_id orelse optionalStringField(tool_response.object, "id") orelse try generated_ids.nextAlloc(arena);
                const response_value = tool_response.object.get("response") orelse std.json.Value{ .object = .empty };
                try content_items.append(arena, .{ .tool_result = .{
                    .tool_call_id = try arena.dupe(u8, id),
                    .tool_name = try std.fmt.allocPrint(arena, "server:{s}", .{tool_type}),
                    .result = try provider_utils.cloneJsonValue(arena, response_value),
                    .provider_metadata = try serverToolMetadata(
                        arena,
                        id,
                        tool_type,
                        optionalStringField(part, "thoughtSignature"),
                    ),
                } });
                last_server_tool_call_id = null;
                continue;
            };
            if (part.get("inlineData")) |inline_data| if (inline_data == .object) {
                const media_type = optionalStringField(inline_data.object, "mimeType") orelse continue;
                const data = optionalStringField(inline_data.object, "data") orelse continue;
                const metadata = try thoughtMetadata(arena, optionalStringField(part, "thoughtSignature"));
                if (optionalBoolField(part, "thought") == true) {
                    try content_items.append(arena, .{ .reasoning_file = .{
                        .media_type = try arena.dupe(u8, media_type),
                        .data = .{ .data = .{ .data = .{ .base64 = try arena.dupe(u8, data) } } },
                        .provider_metadata = metadata,
                    } });
                } else {
                    try content_items.append(arena, .{ .file = .{
                        .media_type = try arena.dupe(u8, media_type),
                        .data = .{ .data = .{ .data = .{ .base64 = try arena.dupe(u8, data) } } },
                        .provider_metadata = metadata,
                    } });
                }
            };
        };
    };
    try appendSources(arena, &generated_ids, candidate.get("groundingMetadata"), &content_items, null);

    const finish_raw = optionalStringField(candidate, "finishReason");
    const usage_value = root.get("usageMetadata");
    return .{
        .content = try content_items.toOwnedSlice(arena),
        .finish_reason = .{ .unified = mapFinishReason(finish_raw, has_client_tool_calls), .raw = finish_raw },
        .usage = try convertUsage(arena, usage_value),
        .provider_metadata = try responseProviderMetadata(arena, root, candidate, usage_value),
        .request = .{ .body = prepared.body },
        .response = .{ .headers = response_headers, .body = response },
        .warnings = prepared.warnings,
    };
}

const StreamState = struct {
    arena: Allocator,
    events: provider_utils.JsonEventStream(std.json.Value),
    warnings: []const provider.Warning,
    include_raw: bool,
    diag: ?*provider.Diagnostics,
    id_generator: provider_utils.IdGenerator,
    queue: std.ArrayList(provider.StreamPart) = .empty,
    queue_index: usize = 0,
    current_text_id: ?[]const u8 = null,
    current_reasoning_id: ?[]const u8 = null,
    block_counter: usize = 0,
    has_tool_calls: bool = false,
    finish_reason: provider.FinishReason = .{ .unified = .other },
    usage: ?std.json.Value = null,
    provider_metadata: ?std.json.Value = null,
    last_grounding_metadata: ?std.json.Value = null,
    last_url_context_metadata: ?std.json.Value = null,
    last_code_execution_id: ?[]const u8 = null,
    last_server_tool_call_id: ?[]const u8 = null,
    emitted_source_urls: std.ArrayList([]const u8) = .empty,
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
        if (self.deinitialized) return;
        self.events.deinit();
        self.queue.deinit(self.arena);
        self.emitted_source_urls.deinit(self.arena);
        self.deinitialized = true;
    }

    fn fillQueue(self: *StreamState) provider.NextError!void {
        while (self.queue.items.len == 0 and !self.flushed) {
            const next_event = self.events.next(self.arena) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidStream(self.arena, self.diag, @errorName(err)),
            };
            const event = next_event orelse {
                try self.flush();
                return;
            };
            switch (event) {
                .failure => |failure| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = .{ .string = failure.raw } } });
                    try self.queue.append(self.arena, .{ .err = .{ .error_value = .{ .string = failure.message } } });
                    self.finish_reason = .{ .unified = .@"error" };
                },
                .success => |success| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = success.value } });
                    try self.mapChunk(success.value);
                },
            }
        }
    }

    fn mapChunk(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (value != .object) return;
        const root = value.object;
        if (root.get("usageMetadata")) |usage| {
            if (usage != .null) self.usage = usage;
        }
        const candidates = root.get("candidates") orelse return;
        if (candidates != .array or candidates.array.items.len == 0 or candidates.array.items[0] != .object) return;
        const candidate = candidates.array.items[0].object;
        if (candidate.get("groundingMetadata")) |metadata| {
            if (metadata != .null) self.last_grounding_metadata = metadata;
        }
        if (candidate.get("urlContextMetadata")) |metadata| {
            if (metadata != .null) self.last_url_context_metadata = metadata;
        }
        try appendStreamSources(self, candidate.get("groundingMetadata"));

        if (candidate.get("content")) |content_value| if (content_value == .object) {
            if (content_value.object.get("parts")) |parts| if (parts == .array) for (parts.array.items) |part_value| {
                if (part_value != .object) continue;
                try self.mapPart(part_value.object);
            };
        };

        if (optionalStringField(candidate, "finishReason")) |raw| {
            self.finish_reason = .{ .unified = mapFinishReason(raw, self.has_tool_calls), .raw = raw };
            self.provider_metadata = try streamProviderMetadata(
                self.arena,
                root,
                candidate,
                self.usage,
                self.last_grounding_metadata,
                self.last_url_context_metadata,
            );
        }
    }

    fn mapPart(self: *StreamState, part: std.json.ObjectMap) provider.NextError!void {
        if (part.get("executableCode")) |executable| if (executable == .object and optionalStringField(executable.object, "code") != null) {
            const id = try self.id_generator.nextAlloc(self.arena);
            self.last_code_execution_id = id;
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = "code_execution",
                .input = try provider_utils.stringifyJsonValueAlloc(self.arena, executable),
                .provider_executed = true,
            } });
            return;
        };
        if (part.get("codeExecutionResult")) |execution_result| if (execution_result == .object) {
            var result: std.json.ObjectMap = .empty;
            if (optionalStringField(execution_result.object, "outcome")) |outcome| try putString(&result, self.arena, "outcome", outcome);
            try putString(&result, self.arena, "output", optionalStringField(execution_result.object, "output") orelse "");
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = self.last_code_execution_id orelse try self.id_generator.nextAlloc(self.arena),
                .tool_name = "code_execution",
                .result = .{ .object = result },
            } });
            self.last_code_execution_id = null;
            return;
        };
        if (part.get("text")) |text_value| if (text_value == .string) {
            const signature = optionalStringField(part, "thoughtSignature");
            const metadata = try thoughtMetadata(self.arena, signature);
            const reasoning = optionalBoolField(part, "thought") == true;
            if (reasoning) {
                if (self.current_text_id) |id| {
                    try self.queue.append(self.arena, .{ .text_end = .{ .id = id } });
                    self.current_text_id = null;
                }
                if (self.current_reasoning_id == null) {
                    self.current_reasoning_id = try self.nextBlockId();
                    try self.queue.append(self.arena, .{ .reasoning_start = .{
                        .id = self.current_reasoning_id.?,
                        .provider_metadata = metadata,
                    } });
                }
                if (text_value.string.len != 0 or metadata != null) try self.queue.append(self.arena, .{ .reasoning_delta = .{
                    .id = self.current_reasoning_id.?,
                    .delta = text_value.string,
                    .provider_metadata = metadata,
                } });
            } else {
                if (self.current_reasoning_id) |id| {
                    try self.queue.append(self.arena, .{ .reasoning_end = .{ .id = id } });
                    self.current_reasoning_id = null;
                }
                if (self.current_text_id == null and text_value.string.len != 0) {
                    self.current_text_id = try self.nextBlockId();
                    try self.queue.append(self.arena, .{ .text_start = .{
                        .id = self.current_text_id.?,
                        .provider_metadata = metadata,
                    } });
                }
                if ((text_value.string.len != 0 or metadata != null) and self.current_text_id != null) try self.queue.append(self.arena, .{ .text_delta = .{
                    .id = self.current_text_id.?,
                    .delta = text_value.string,
                    .provider_metadata = metadata,
                } });
            }
            return;
        };
        if (part.get("inlineData")) |inline_data| if (inline_data == .object) {
            try self.endBlocks();
            const media_type = optionalStringField(inline_data.object, "mimeType") orelse return;
            const data = optionalStringField(inline_data.object, "data") orelse return;
            const metadata = try thoughtMetadata(self.arena, optionalStringField(part, "thoughtSignature"));
            if (optionalBoolField(part, "thought") == true) {
                try self.queue.append(self.arena, .{ .reasoning_file = .{
                    .media_type = media_type,
                    .data = .{ .data = .{ .data = .{ .base64 = data } } },
                    .provider_metadata = metadata,
                } });
            } else {
                try self.queue.append(self.arena, .{ .file = .{
                    .media_type = media_type,
                    .data = .{ .data = .{ .data = .{ .base64 = data } } },
                    .provider_metadata = metadata,
                } });
            }
            return;
        };
        if (part.get("toolCall")) |tool_call| if (tool_call == .object) {
            const tool_type = optionalStringField(tool_call.object, "toolType") orelse return;
            const id = optionalStringField(tool_call.object, "id") orelse try self.id_generator.nextAlloc(self.arena);
            self.last_server_tool_call_id = id;
            const arguments = tool_call.object.get("args") orelse std.json.Value{ .object = .empty };
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = try std.fmt.allocPrint(self.arena, "server:{s}", .{tool_type}),
                .input = try provider_utils.stringifyJsonValueAlloc(self.arena, arguments),
                .provider_executed = true,
                .dynamic = true,
                .provider_metadata = try serverToolMetadata(
                    self.arena,
                    id,
                    tool_type,
                    optionalStringField(part, "thoughtSignature"),
                ),
            } });
            return;
        };
        if (part.get("toolResponse")) |tool_response| if (tool_response == .object) {
            const tool_type = optionalStringField(tool_response.object, "toolType") orelse return;
            const id = self.last_server_tool_call_id orelse optionalStringField(tool_response.object, "id") orelse try self.id_generator.nextAlloc(self.arena);
            const response_value = tool_response.object.get("response") orelse std.json.Value{ .object = .empty };
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = id,
                .tool_name = try std.fmt.allocPrint(self.arena, "server:{s}", .{tool_type}),
                .result = try provider_utils.cloneJsonValue(self.arena, response_value),
                .provider_metadata = try serverToolMetadata(
                    self.arena,
                    id,
                    tool_type,
                    optionalStringField(part, "thoughtSignature"),
                ),
            } });
            self.last_server_tool_call_id = null;
            return;
        };
        if (part.get("functionCall")) |function_call| if (function_call == .object) {
            const name = optionalStringField(function_call.object, "name") orelse return;
            const id = optionalStringField(function_call.object, "id") orelse try self.id_generator.nextAlloc(self.arena);
            const args_value = function_call.object.get("args");
            const args = args_value orelse std.json.Value{ .object = .empty };
            const input = if (args == .string) args.string else try provider_utils.stringifyJsonValueAlloc(self.arena, args);
            const metadata = try thoughtMetadata(self.arena, optionalStringField(part, "thoughtSignature"));
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = id, .tool_name = name, .provider_metadata = metadata } });
            if (args_value != null and input.len != 0) try self.queue.append(self.arena, .{ .tool_input_delta = .{
                .id = id,
                .delta = input,
                .provider_metadata = metadata,
            } });
            try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = id, .provider_metadata = metadata } });
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = name,
                .input = if (input.len == 0) "{}" else input,
                .provider_metadata = metadata,
            } });
            self.has_tool_calls = true;
        };
    }

    fn nextBlockId(self: *StreamState) Allocator.Error![]const u8 {
        const id = try std.fmt.allocPrint(self.arena, "{d}", .{self.block_counter});
        self.block_counter += 1;
        return id;
    }

    fn endBlocks(self: *StreamState) Allocator.Error!void {
        if (self.current_text_id) |id| {
            try self.queue.append(self.arena, .{ .text_end = .{ .id = id } });
            self.current_text_id = null;
        }
        if (self.current_reasoning_id) |id| {
            try self.queue.append(self.arena, .{ .reasoning_end = .{ .id = id } });
            self.current_reasoning_id = null;
        }
    }

    fn flush(self: *StreamState) provider.NextError!void {
        if (self.flushed) return;
        try self.endBlocks();
        try self.queue.append(self.arena, .{ .finish = .{
            .finish_reason = self.finish_reason,
            .usage = try convertUsage(self.arena, self.usage),
            .provider_metadata = self.provider_metadata,
        } });
        self.flushed = true;
    }
};

fn appendStreamSources(self: *StreamState, grounding: ?std.json.Value) provider.NextError!void {
    var content_items: std.ArrayList(provider.Content) = .empty;
    defer content_items.deinit(self.arena);
    try appendSources(self.arena, &self.id_generator, grounding, &content_items, &self.emitted_source_urls);
    for (content_items.items) |item| switch (item) {
        .source => |source| try self.queue.append(self.arena, .{ .source = source }),
        else => {},
    };
}

fn appendSources(
    arena: Allocator,
    ids: *provider_utils.IdGenerator,
    grounding: ?std.json.Value,
    content: *std.ArrayList(provider.Content),
    emitted_urls: ?*std.ArrayList([]const u8),
) provider.CallError!void {
    const metadata = grounding orelse return;
    if (metadata != .object) return;
    const chunks = metadata.object.get("groundingChunks") orelse return;
    if (chunks != .array) return;
    for (chunks.array.items) |chunk_value| {
        if (chunk_value != .object) continue;
        const chunk = chunk_value.object;
        if (chunk.get("web")) |web| if (web == .object) {
            const url = optionalStringField(web.object, "uri") orelse continue;
            if (alreadyEmitted(emitted_urls, url)) continue;
            try rememberUrl(arena, emitted_urls, url);
            try content.append(arena, .{ .source = .{ .url = .{
                .id = try ids.nextAlloc(arena),
                .url = try arena.dupe(u8, url),
                .title = if (optionalStringField(web.object, "title")) |title| try arena.dupe(u8, title) else null,
            } } });
            continue;
        };
        if (chunk.get("image")) |image| if (image == .object) {
            const url = optionalStringField(image.object, "sourceUri") orelse continue;
            if (alreadyEmitted(emitted_urls, url)) continue;
            try rememberUrl(arena, emitted_urls, url);
            try content.append(arena, .{ .source = .{ .url = .{
                .id = try ids.nextAlloc(arena),
                .url = try arena.dupe(u8, url),
                .title = if (optionalStringField(image.object, "title")) |title| try arena.dupe(u8, title) else null,
            } } });
            continue;
        };
        if (chunk.get("maps")) |maps| if (maps == .object) {
            const url = optionalStringField(maps.object, "uri") orelse continue;
            if (alreadyEmitted(emitted_urls, url)) continue;
            try rememberUrl(arena, emitted_urls, url);
            try content.append(arena, .{ .source = .{ .url = .{
                .id = try ids.nextAlloc(arena),
                .url = try arena.dupe(u8, url),
                .title = if (optionalStringField(maps.object, "title")) |title| try arena.dupe(u8, title) else null,
            } } });
            continue;
        };
        if (chunk.get("retrievedContext")) |retrieved| if (retrieved == .object) {
            if (optionalStringField(retrieved.object, "uri")) |uri| {
                if (std.mem.startsWith(u8, uri, "http://") or std.mem.startsWith(u8, uri, "https://")) {
                    if (alreadyEmitted(emitted_urls, uri)) continue;
                    try rememberUrl(arena, emitted_urls, uri);
                    try content.append(arena, .{ .source = .{ .url = .{
                        .id = try ids.nextAlloc(arena),
                        .url = try arena.dupe(u8, uri),
                        .title = if (optionalStringField(retrieved.object, "title")) |title| try arena.dupe(u8, title) else null,
                    } } });
                } else {
                    try appendDocumentSource(arena, ids, content, retrieved.object, uri);
                }
            } else if (optionalStringField(retrieved.object, "fileSearchStore")) |store| {
                try content.append(arena, .{ .source = .{ .document = .{
                    .id = try ids.nextAlloc(arena),
                    .media_type = "application/octet-stream",
                    .title = try arena.dupe(u8, optionalStringField(retrieved.object, "title") orelse "Unknown Document"),
                    .filename = try lastPathSegment(arena, store),
                } } });
            }
        };
    }
}

fn appendDocumentSource(
    arena: Allocator,
    ids: *provider_utils.IdGenerator,
    content: *std.ArrayList(provider.Content),
    retrieved: std.json.ObjectMap,
    uri: []const u8,
) provider.CallError!void {
    const media_type = if (std.mem.endsWith(u8, uri, ".pdf"))
        "application/pdf"
    else if (std.mem.endsWith(u8, uri, ".txt"))
        "text/plain"
    else if (std.mem.endsWith(u8, uri, ".docx"))
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    else if (std.mem.endsWith(u8, uri, ".doc"))
        "application/msword"
    else if (std.mem.endsWith(u8, uri, ".md") or std.mem.endsWith(u8, uri, ".markdown"))
        "text/markdown"
    else
        "application/octet-stream";
    try content.append(arena, .{ .source = .{ .document = .{
        .id = try ids.nextAlloc(arena),
        .media_type = media_type,
        .title = try arena.dupe(u8, optionalStringField(retrieved, "title") orelse "Unknown Document"),
        .filename = try lastPathSegment(arena, uri),
    } } });
}

fn responseProviderMetadata(
    arena: Allocator,
    root: std.json.ObjectMap,
    candidate: std.json.ObjectMap,
    usage: ?std.json.Value,
) Allocator.Error!std.json.Value {
    return metadataValue(
        arena,
        root.get("promptFeedback"),
        candidate.get("groundingMetadata"),
        candidate.get("urlContextMetadata"),
        candidate.get("safetyRatings"),
        usage,
        candidate.get("finishMessage"),
    );
}

fn streamProviderMetadata(
    arena: Allocator,
    root: std.json.ObjectMap,
    candidate: std.json.ObjectMap,
    usage: ?std.json.Value,
    grounding: ?std.json.Value,
    url_context: ?std.json.Value,
) Allocator.Error!std.json.Value {
    return metadataValue(
        arena,
        root.get("promptFeedback"),
        grounding,
        url_context,
        candidate.get("safetyRatings"),
        usage,
        candidate.get("finishMessage"),
    );
}

fn metadataValue(
    arena: Allocator,
    prompt_feedback: ?std.json.Value,
    grounding: ?std.json.Value,
    url_context: ?std.json.Value,
    safety: ?std.json.Value,
    usage: ?std.json.Value,
    finish_message: ?std.json.Value,
) Allocator.Error!std.json.Value {
    var payload: std.json.ObjectMap = .empty;
    try payload.put(arena, "promptFeedback", try cloneOrNull(arena, prompt_feedback));
    try payload.put(arena, "groundingMetadata", try cloneOrNull(arena, grounding));
    try payload.put(arena, "urlContextMetadata", try cloneOrNull(arena, url_context));
    try payload.put(arena, "safetyRatings", try cloneOrNull(arena, safety));
    try payload.put(arena, "usageMetadata", try cloneOrNull(arena, usage));
    try payload.put(arena, "finishMessage", try cloneOrNull(arena, finish_message));
    const service_tier = if (usage) |value|
        if (value == .object) value.object.get("serviceTier") else null
    else
        null;
    try payload.put(arena, "serviceTier", try cloneOrNull(arena, service_tier));
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "google", .{ .object = payload });
    return .{ .object = root };
}

fn thoughtMetadata(arena: Allocator, signature: ?[]const u8) Allocator.Error!?std.json.Value {
    const value = signature orelse return null;
    var payload: std.json.ObjectMap = .empty;
    try putString(&payload, arena, "thoughtSignature", value);
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "google", .{ .object = payload });
    return .{ .object = root };
}

fn serverToolMetadata(
    arena: Allocator,
    id: []const u8,
    tool_type: []const u8,
    signature: ?[]const u8,
) Allocator.Error!std.json.Value {
    var payload: std.json.ObjectMap = .empty;
    try putString(&payload, arena, "serverToolCallId", id);
    try putString(&payload, arena, "serverToolType", tool_type);
    if (signature) |value| try putString(&payload, arena, "thoughtSignature", value);
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "google", .{ .object = payload });
    return .{ .object = root };
}

fn convertUsage(arena: Allocator, usage: ?std.json.Value) Allocator.Error!provider.Usage {
    const value = usage orelse return .{
        .input_tokens = .{},
        .output_tokens = .{},
    };
    if (value == .null or value != .object) return .{
        .input_tokens = .{},
        .output_tokens = .{},
    };
    const prompt_tokens = optionalU64(value.object.get("promptTokenCount")) orelse 0;
    const candidates_tokens = optionalU64(value.object.get("candidatesTokenCount")) orelse 0;
    const cached_tokens = optionalU64(value.object.get("cachedContentTokenCount")) orelse 0;
    const thoughts_tokens = optionalU64(value.object.get("thoughtsTokenCount")) orelse 0;
    return .{
        .input_tokens = .{
            .total = prompt_tokens,
            .no_cache = prompt_tokens -| cached_tokens,
            .cache_read = cached_tokens,
        },
        .output_tokens = .{
            .total = candidates_tokens +| thoughts_tokens,
            .text = candidates_tokens,
            .reasoning = thoughts_tokens,
        },
        .raw = try provider_utils.cloneJsonValue(arena, value),
    };
}

fn mapFinishReason(raw: ?[]const u8, has_tool_calls: bool) provider.FinishReasonUnified {
    const value = raw orelse return .other;
    if (std.mem.eql(u8, value, "STOP")) return if (has_tool_calls) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, value, "IMAGE_SAFETY") or
        std.mem.eql(u8, value, "RECITATION") or
        std.mem.eql(u8, value, "SAFETY") or
        std.mem.eql(u8, value, "BLOCKLIST") or
        std.mem.eql(u8, value, "PROHIBITED_CONTENT") or
        std.mem.eql(u8, value, "SPII")) return .content_filter;
    if (std.mem.eql(u8, value, "MALFORMED_FUNCTION_CALL")) return .@"error";
    return .other;
}

fn maxThinkingTokens(model_id: []const u8) u64 {
    if (contains(model_id, "2.5-pro") or contains(model_id, "gemini-3-pro-image")) return 32768;
    return 24576;
}

fn isGemini3(model_id: []const u8) bool {
    return std.mem.eql(u8, model_id, "gemini-3") or
        std.mem.startsWith(u8, model_id, "gemini-3.") or
        std.mem.startsWith(u8, model_id, "gemini-3-");
}

fn supportsExternalFileUrls(model_id: []const u8) bool {
    return (std.mem.startsWith(u8, model_id, "gemini-") or contains(model_id, "/gemini-")) and
        !(std.mem.startsWith(u8, model_id, "gemini-2.0") or contains(model_id, "/gemini-2.0"));
}

fn supportedExternalMediaType(media_type: []const u8) bool {
    const values = [_][]const u8{
        "text/html",        "text/css",        "text/plain", "text/xml",    "text/csv",  "text/rtf",   "text/javascript",
        "application/json", "application/pdf", "image/bmp",  "image/jpeg",  "image/png", "image/webp", "video/mp4",
        "video/mpeg",       "video/quicktime", "video/avi",  "video/x-flv", "video/mpg", "video/webm", "video/wmv",
        "video/3gpp",
    };
    for (values) |value| if (std.mem.eql(u8, value, media_type)) return true;
    return false;
}

fn isYouTubeUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://youtube.com/watch?v=") or
        std.mem.startsWith(u8, url, "https://www.youtube.com/watch?v=") or
        std.mem.startsWith(u8, url, "https://youtu.be/");
}

fn alreadyEmitted(emitted: ?*std.ArrayList([]const u8), url: []const u8) bool {
    const list = emitted orelse return false;
    for (list.items) |value| if (std.mem.eql(u8, value, url)) return true;
    return false;
}

fn rememberUrl(arena: Allocator, emitted: ?*std.ArrayList([]const u8), url: []const u8) Allocator.Error!void {
    const list = emitted orelse return;
    try list.append(arena, try arena.dupe(u8, url));
}

fn lastPathSegment(arena: Allocator, value: []const u8) Allocator.Error!?[]const u8 {
    const index = std.mem.lastIndexOfScalar(u8, value, '/') orelse {
        const result: []const u8 = try arena.dupe(u8, value);
        return result;
    };
    if (index + 1 >= value.len) return null;
    const result: []const u8 = try arena.dupe(u8, value[index + 1 ..]);
    return result;
}

fn cloneOrNull(arena: Allocator, value: ?std.json.Value) Allocator.Error!std.json.Value {
    const item = value orelse return .null;
    return provider_utils.cloneJsonValue(arena, item);
}

fn requireObject(value: std.json.Value, arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error!std.json.ObjectMap {
    if (value != .object) return invalidResponse(arena, diag, message);
    return value.object;
}

fn requireArrayField(object: std.json.ObjectMap, field: []const u8, arena: Allocator, diag: ?*provider.Diagnostics) provider.Error!std.json.Array {
    const value = object.get(field) orelse return invalidResponse(arena, diag, "Google response array field is missing");
    if (value != .array) return invalidResponse(arena, diag, "Google response field must be an array");
    return value.array;
}

fn optionalStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalBoolField(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        else => null,
    };
}

fn stringArray(arena: Allocator, values: []const []const u8) Allocator.Error!std.json.Value {
    var output = std.json.Array.init(arena);
    for (values) |value| try output.append(.{ .string = try arena.dupe(u8, value) });
    return .{ .array = output };
}

fn putU64(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: u64, diag: ?*provider.Diagnostics) BuildError!void {
    if (value > std.math.maxInt(i64)) return invalidArgument(diag, key, "Google numeric option is too large");
    try object.put(arena, key, .{ .integer = @intCast(value) });
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn invalidResponse(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
}

fn invalidStream(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .invalid_stream_part = .{ .message = message, .chunk_json = "" },
    });
    return error.InvalidStreamPartError;
}

fn invalidArgument(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

fn testConfig(allocator: Allocator, base_url: []const u8, transport: provider_utils.HttpTransport) config_api.Config {
    return .{
        .allocator = allocator,
        .base_url = base_url,
        .api_key = "test-api-key",
        .env = .empty,
        .headers = .{ .static = &.{.{ .name = "x-provider", .value = "provider-value" }} },
        .transport = transport,
        .provider_name = "google.generative-ai",
        .provider_options_name = "google",
    };
}

test "Google generateContent sends native prompt, options, tools, safety, and structured output" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":1,\"totalTokenCount\":2}}" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleLanguageModel.init("gemini-3-pro-preview", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}
    , .{});
    const provider_options = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"google":{"threshold":"BLOCK_NONE","responseModalities":["TEXT"],"thinkingConfig":{"includeThoughts":true},"serviceTier":"flex"}}
    , .{});
    const messages = [_]provider.Message{
        .{ .system = .{ .content = "test system instruction" } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "Hello" } }} } },
    };
    const functions = [_]provider.Tool{.{ .function = .{ .name = "test-tool", .input_schema = schema } }};
    const call_headers = [_]provider.Header{.{ .name = "x-request", .value = "request-value" }};
    _ = try model.languageModel().doGenerate(io, arena, &.{
        .prompt = &messages,
        .seed = 123,
        .temperature = 0.5,
        .response_format = .{ .json = .{ .schema = schema } },
        .tools = &functions,
        .tool_choice = .{ .tool = .{ .tool_name = "test-tool" } },
        .reasoning = .high,
        .provider_options = provider_options,
        .headers = &call_headers,
    }, null);
    const request = server.recordedRequests()[0];
    try std.testing.expectEqualStrings("/models/gemini-3-pro-preview:generateContent", request.target);
    try std.testing.expectEqualStrings("test-api-key", recordedHeader(request.headers, "x-goog-api-key").?);
    try std.testing.expectEqualStrings("provider-value", recordedHeader(request.headers, "x-provider").?);
    try std.testing.expectEqualStrings("request-value", recordedHeader(request.headers, "x-request").?);
    try std.testing.expect(std.mem.indexOf(u8, recordedHeader(request.headers, "user-agent").?, "ai-sdk-zig/google/") != null);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, request.body, .{});
    try std.testing.expectEqualStrings("Hello", body.object.get("contents").?.array.items[0].object.get("parts").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("test system instruction", body.object.get("systemInstruction").?.object.get("parts").?.array.items[0].object.get("text").?.string);
    const generation = body.object.get("generationConfig").?.object;
    try std.testing.expectEqualStrings("application/json", generation.get("responseMimeType").?.string);
    try std.testing.expect(generation.get("responseSchema").?.object.get("additionalProperties") == null);
    try std.testing.expectEqualStrings("high", generation.get("thinkingConfig").?.object.get("thinkingLevel").?.string);
    try std.testing.expectEqual(true, generation.get("thinkingConfig").?.object.get("includeThoughts").?.bool);
    try std.testing.expectEqual(4, body.object.get("safetySettings").?.array.items.len);
    try std.testing.expectEqualStrings("ANY", body.object.get("toolConfig").?.object.get("functionCallingConfig").?.object.get("mode").?.string);
    try std.testing.expectEqualStrings("flex", body.object.get("serviceTier").?.string);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google doGenerate maps text, reasoning, tool calls, sources, usage, and metadata" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "google-1" }},
        .body = .{ .text =
        \\{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true,"thoughtSignature":"sig-r"},{"text":"answer","thoughtSignature":"sig-t"},{"functionCall":{"id":"call-1","name":"weather","args":{"city":"Paris"}},"thoughtSignature":"sig-c"}]},"finishReason":"STOP","finishMessage":"Model generated function call(s).","safetyRatings":[],"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com","title":"Example"}}]}}],"promptFeedback":{},"usageMetadata":{"promptTokenCount":10,"cachedContentTokenCount":2,"candidatesTokenCount":4,"thoughtsTokenCount":6,"totalTokenCount":20,"serviceTier":"flex"}}
        },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleLanguageModel.init("gemini-2.5-flash", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    const result = try model.languageModel().doGenerate(io, arena_state.allocator(), &.{ .prompt = &prompt }, null);
    try std.testing.expectEqual(4, result.content.len);
    try std.testing.expectEqualStrings("thinking", result.content[0].reasoning.text);
    try std.testing.expectEqualStrings("answer", result.content[1].text.text);
    try std.testing.expectEqualStrings("weather", result.content[2].tool_call.tool_name);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", result.content[2].tool_call.input);
    try std.testing.expectEqualStrings("https://example.com", result.content[3].source.url.url);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, result.finish_reason.unified);
    try std.testing.expectEqual(10, result.usage.input_tokens.total.?);
    try std.testing.expectEqual(8, result.usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(2, result.usage.input_tokens.cache_read.?);
    try std.testing.expectEqual(10, result.usage.output_tokens.total.?);
    try std.testing.expectEqualStrings("sig-c", result.content[2].tool_call.provider_metadata.?.object.get("google").?.object.get("thoughtSignature").?.string);
    try std.testing.expectEqualStrings("flex", result.provider_metadata.?.object.get("google").?.object.get("serviceTier").?.string);
    try std.testing.expectEqualStrings("google-1", recordedHeader(result.response.?.headers.?, "x-request-id").?);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google doGenerate maps provider-executed server tool calls and responses" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"candidates":[{"content":{"parts":[{"toolCall":{"toolType":"google_search","args":{"query":"zig"},"id":"server-1"},"thoughtSignature":"server-sig"},{"toolResponse":{"toolType":"google_search","response":{"result":"found"},"id":"server-1"}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}
        },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleLanguageModel.init("gemini-3-pro-preview", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "search" } }} } }};
    const result = try model.languageModel().doGenerate(io, arena_state.allocator(), &.{ .prompt = &prompt }, null);
    try std.testing.expectEqual(2, result.content.len);
    try std.testing.expectEqualStrings("server:google_search", result.content[0].tool_call.tool_name);
    try std.testing.expectEqual(true, result.content[0].tool_call.provider_executed.?);
    try std.testing.expectEqual(true, result.content[0].tool_call.dynamic.?);
    try std.testing.expectEqualStrings("server:google_search", result.content[1].tool_result.tool_name);
    try std.testing.expectEqualStrings("found", result.content[1].tool_result.result.object.get("result").?.string);
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, result.finish_reason.unified);
    const metadata = result.content[0].tool_call.provider_metadata.?.object.get("google").?.object;
    try std.testing.expectEqualStrings("server-1", metadata.get("serverToolCallId").?.string);
    try std.testing.expectEqualStrings("server-sig", metadata.get("thoughtSignature").?.string);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google structuredOutputs false keeps JSON MIME type and omits responseSchema" {
    var marker: u8 = 0;
    const Dummy = struct {
        fn request(_: *anyopaque, _: std.Io, _: Allocator, _: provider_utils.RequestSpec, _: ?*provider.Diagnostics) provider_utils.RequestError!provider_utils.Response {
            return error.APICallError;
        }
    };
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var model = try GoogleLanguageModel.init("gemini-pro", testConfig(std.testing.allocator, "https://example.test", transport), null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}}}", .{});
    const options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"google\":{\"structuredOutputs\":false}}", .{});
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    const prepared = try model.prepareRequest(arena, &.{
        .prompt = &prompt,
        .response_format = .{ .json = .{ .schema = schema } },
        .provider_options = options,
    }, false, null);
    const generation = prepared.body.object.get("generationConfig").?.object;
    try std.testing.expectEqualStrings("application/json", generation.get("responseMimeType").?.string);
    try std.testing.expect(generation.get("responseSchema") == null);
}

test "Google streamGenerateContent emits text, tool input lifecycle, raw chunks, usage, and tool finish" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello \"}]}}]}" },
            .{ .data = "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"id\":\"call-1\",\"name\":\"weather\",\"args\":{\"city\":\"Paris\"}}}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":2,\"thoughtsTokenCount\":1,\"totalTokenCount\":6}}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleLanguageModel.init("gemini-2.5-flash", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena_state.allocator(), &.{ .prompt = &prompt, .include_raw_chunks = true }, null);
    defer streamed.stream.deinit(io);
    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(allocator);
    var finish: ?provider.language_model.FinishPart = null;
    while (try streamed.stream.next(io)) |part| {
        try tags.append(allocator, part);
        if (part == .finish) finish = part.finish;
    }
    try std.testing.expectEqualStrings("/models/gemini-2.5-flash:streamGenerateContent?alt=sse", server.recordedRequests()[0].target);
    try std.testing.expect(tags.items.len >= 10);
    try std.testing.expectEqual(std.meta.Tag(provider.StreamPart).stream_start, tags.items[0]);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, finish.?.finish_reason.unified);
    try std.testing.expectEqual(3, finish.?.usage.output_tokens.total.?);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google streaming separates reasoning and text blocks" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"think\",\"thought\":true,\"thoughtSignature\":\"sig\"}]}}]}" },
            .{ .data = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"answer\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":1,\"thoughtsTokenCount\":1}}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleLanguageModel.init("gemini-2.5-flash", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena_state.allocator(), &.{ .prompt = &prompt }, null);
    defer streamed.stream.deinit(io);
    var saw_reasoning_start = false;
    var saw_reasoning_delta = false;
    var saw_reasoning_end = false;
    var saw_text = false;
    while (try streamed.stream.next(io)) |part| switch (part) {
        .reasoning_start => saw_reasoning_start = true,
        .reasoning_delta => |delta| {
            saw_reasoning_delta = true;
            try std.testing.expectEqualStrings("sig", delta.provider_metadata.?.object.get("google").?.object.get("thoughtSignature").?.string);
        },
        .reasoning_end => saw_reasoning_end = true,
        .text_delta => saw_text = true,
        else => {},
    };
    try std.testing.expect(saw_reasoning_start and saw_reasoning_delta and saw_reasoning_end and saw_text);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google API error shape maps message, body, status, and retryability" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .status = .too_many_requests,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"code\":429,\"message\":\"quota exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleLanguageModel.init("gemini-2.5-flash", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    try std.testing.expectError(error.APICallError, model.languageModel().doGenerate(io, arena_state.allocator(), &.{ .prompt = &prompt }, &diagnostics));
    try std.testing.expectEqualStrings("quota exhausted", diagnostics.payload.api_call.message);
    try std.testing.expectEqual(429, diagnostics.payload.api_call.status_code.?);
    try std.testing.expect(diagnostics.payload.api_call.is_retryable);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.payload.api_call.response_body.?, "RESOURCE_EXHAUSTED") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google finish reasons and usage match upstream mappings" {
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, mapFinishReason("STOP", false));
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, mapFinishReason("STOP", true));
    try std.testing.expectEqual(provider.FinishReasonUnified.length, mapFinishReason("MAX_TOKENS", false));
    try std.testing.expectEqual(provider.FinishReasonUnified.content_filter, mapFinishReason("SAFETY", false));
    try std.testing.expectEqual(provider.FinishReasonUnified.@"error", mapFinishReason("MALFORMED_FUNCTION_CALL", false));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"promptTokenCount\":9,\"cachedContentTokenCount\":2,\"candidatesTokenCount\":4,\"thoughtsTokenCount\":3}", .{});
    const usage = try convertUsage(arena, value);
    try std.testing.expectEqual(7, usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(7, usage.output_tokens.total.?);
}

test "Google model paths and URL support match native provider contracts" {
    var marker: u8 = 0;
    const Dummy = struct {
        fn request(_: *anyopaque, _: std.Io, _: Allocator, _: provider_utils.RequestSpec, _: ?*provider.Diagnostics) provider_utils.RequestError!provider_utils.Response {
            return error.APICallError;
        }
    };
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var model = try GoogleLanguageModel.init("gemini-3.5-flash", testConfig(std.testing.allocator, "https://generativelanguage.googleapis.com/v1beta", transport), null);
    const erased = model.languageModel();
    try std.testing.expect(erased.urlIsSupported("video/mp4", "https://youtube.com/watch?v=abc"));
    try std.testing.expect(erased.urlIsSupported("application/pdf", "https://example.com/file.pdf"));
    try std.testing.expect(erased.urlIsSupported("application/octet-stream", "https://generativelanguage.googleapis.com/v1beta/files/abc"));
    try std.testing.expect(!erased.urlIsSupported("text/markdown", "https://example.com/file.md"));
    var old = try GoogleLanguageModel.init("gemini-2.0-flash", testConfig(std.testing.allocator, "https://generativelanguage.googleapis.com/v1beta", transport), null);
    try std.testing.expect(!old.languageModel().urlIsSupported("text/plain", "https://example.com/file.txt"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("models/gemini-pro", try getModelPath(arena_state.allocator(), "gemini-pro"));
    try std.testing.expectEqualStrings("tunedModels/custom", try getModelPath(arena_state.allocator(), "tunedModels/custom"));
}
