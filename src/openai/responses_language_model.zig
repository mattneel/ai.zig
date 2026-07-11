//! OpenAI Responses API LanguageModelV4 implementation.
//!
//! Ported from
//! `packages/openai/src/responses/openai-responses-language-model.ts`.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const capabilities_api = @import("capabilities.zig");
const config_api = @import("config.zig");
const options_api = @import("options.zig");
const responses_api = @import("responses_api.zig");
const responses_input = @import("responses_input.zig");
const responses_tools = @import("responses_tools.zig");

const Allocator = std.mem.Allocator;
const BuildError = provider.Error || Allocator.Error;
const max_provider_id_len = 1024;

const ToolName = struct {
    provider_name: []const u8,
    custom_name: []const u8,
};

pub const PreparedRequest = struct {
    body: std.json.Value,
    warnings: []const provider.Warning,
    metadata_key: []const u8,
    store: bool,
    capture_logprobs: bool,
    web_search_tool_name: ?[]const u8,
    shell_provider_executed: bool,
    tool_names: []const ToolName,
};

pub const ResponsesLanguageModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ResponsesLanguageModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");
        var result: ResponsesLanguageModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.responses", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn languageModel(self: *ResponsesLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn prepareRequest(
        self: *ResponsesLanguageModel,
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

    fn fromRaw(raw: *anyopaque) *ResponsesLanguageModel {
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
        return (std.mem.startsWith(u8, media_type, "image/") or std.mem.eql(u8, media_type, "application/pdf")) and
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
        self: *ResponsesLanguageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const prepared = try buildArgs(self, arena, options, false, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{self.config.base_url});
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
            options.prompt,
            url,
            diag,
        );
    }

    fn doStream(
        self: *ResponsesLanguageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const prepared = try buildArgs(self, arena, options, true, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{self.config.base_url});
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
            .store = prepared.store,
            .capture_logprobs = prepared.capture_logprobs,
            .web_search_tool_name = prepared.web_search_tool_name,
            .shell_provider_executed = prepared.shell_provider_executed,
            .tool_names = prepared.tool_names,
            .diag = diag,
            .id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag),
            .logprobs = std.json.Array.init(arena),
        };
        try state.captureApprovalAliases(options.prompt);
        try state.queue.append(arena, .{ .stream_start = .{ .warnings = prepared.warnings } });
        errdefer state.deinitInternal();
        try state.peekForEarlyFrames(url, body_json, result.response_headers);

        return .{
            .stream = .{ .ctx = state, .vtable = &StreamState.vtable },
            .request = .{ .body = prepared.body },
            .response = .{ .headers = result.response_headers },
        };
    }

    fn resolveHeaders(
        self: *const ResponsesLanguageModel,
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
        if (call_headers) |values| {
            for (values, call_entries) |header, *entry| entry.* = .{ .name = header.name, .value = header.value };
        }
        const lists = [_][]const provider_utils.HeaderEntry{
            configured_storage[0..configured_len],
            self.config.headers.resolve(),
            call_entries,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(arena, combined, &.{"ai-sdk-zig/openai/" ++ provider_utils.version});
    }
};

fn buildArgs(
    self: *ResponsesLanguageModel,
    arena: Allocator,
    call_options: *const provider.CallOptions,
    stream: bool,
    diag: ?*provider.Diagnostics,
) BuildError!PreparedRequest {
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    if (call_options.top_k != null) try warnings.append(arena, .{ .unsupported = .{ .feature = "topK" } });
    if (call_options.seed != null) try warnings.append(arena, .{ .unsupported = .{ .feature = "seed" } });
    if (call_options.presence_penalty != null) try warnings.append(arena, .{ .unsupported = .{ .feature = "presencePenalty" } });
    if (call_options.frequency_penalty != null) try warnings.append(arena, .{ .unsupported = .{ .feature = "frequencyPenalty" } });
    if (call_options.stop_sequences != null) try warnings.append(arena, .{ .unsupported = .{ .feature = "stopSequences" } });

    const openai_options = try options_api.parseResponsesOptions(
        arena,
        call_options.provider_options,
        self.config.provider_options_name,
        diag,
    );
    const model_capabilities = capabilities_api.getLanguageModelCapabilities(self.model_id);
    const resolved_reasoning_effort = openai_options.reasoning_effort orelse reasoningName(call_options.reasoning);
    const resolved_reasoning_summary: ?[]const u8 = if (openai_options.reasoning_summary_set)
        openai_options.reasoning_summary
    else if (resolved_reasoning_effort != null and !std.mem.eql(u8, resolved_reasoning_effort.?, "none"))
        "detailed"
    else
        null;
    const is_reasoning_model = openai_options.force_reasoning orelse model_capabilities.is_reasoning_model;

    if (openai_options.conversation != null and openai_options.previous_response_id != null) {
        try warnings.append(arena, .{ .unsupported = .{
            .feature = "conversation",
            .details = "conversation and previousResponseId cannot be used together",
        } });
    }

    const prepared_tools = try responses_tools.prepareResponsesTools(
        arena,
        call_options.tools,
        call_options.tool_choice,
        openai_options.allowed_tools,
        diag,
    );
    try warnings.appendSlice(arena, prepared_tools.warnings);
    const store = openai_options.store orelse true;
    const converted = try responses_input.convertToOpenAIResponsesInput(arena, call_options.prompt, .{
        .system_message_mode = openai_options.system_message_mode orelse
            if (is_reasoning_model) .developer else model_capabilities.system_message_mode,
        .provider_options_name = self.config.provider_options_name,
        .store = store,
        .has_conversation = openai_options.conversation != null,
        .has_previous_response_id = openai_options.previous_response_id != null,
        .pass_through_unsupported_files = openai_options.pass_through_unsupported_files,
        .tools = call_options.tools,
    }, diag);
    try warnings.appendSlice(arena, converted.warnings);

    var include: std.ArrayList([]const u8) = .empty;
    defer include.deinit(arena);
    if (openai_options.include) |values| try include.appendSlice(arena, values);
    const top_logprobs: ?u64 = if (openai_options.logprobs) |logprobs| switch (logprobs) {
        .boolean => |enabled| if (enabled) 20 else null,
        .count => |count| count,
    } else null;
    if (top_logprobs != null) try addInclude(arena, &include, "message.output_text.logprobs");
    const web_search_tool_name = responses_tools.webSearchToolName(call_options.tools);
    if (web_search_tool_name != null) try addInclude(arena, &include, "web_search_call.action.sources");
    if (responses_tools.hasProviderTool(call_options.tools, "openai.code_interpreter")) try addInclude(arena, &include, "code_interpreter_call.outputs");
    if (!store and is_reasoning_model) try addInclude(arena, &include, "reasoning.encrypted_content");

    var temperature = call_options.temperature;
    var top_p = call_options.top_p;
    if (is_reasoning_model and !(resolved_reasoning_effort != null and
        std.mem.eql(u8, resolved_reasoning_effort.?, "none") and
        model_capabilities.supports_non_reasoning_parameters))
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
    }
    if (!is_reasoning_model) {
        if (openai_options.reasoning_effort != null) try warnings.append(arena, unsupportedWarning("reasoningEffort", "reasoningEffort is not supported for non-reasoning models"));
        if (openai_options.reasoning_summary != null) try warnings.append(arena, unsupportedWarning("reasoningSummary", "reasoningSummary is not supported for non-reasoning models"));
        if (openai_options.reasoning_mode != null) try warnings.append(arena, unsupportedWarning("reasoningMode", "reasoningMode is not supported for non-reasoning models"));
        if (openai_options.reasoning_context != null) try warnings.append(arena, unsupportedWarning("reasoningContext", "reasoningContext is not supported for non-reasoning models"));
    }

    var service_tier = openai_options.service_tier;
    if (service_tier) |tier| {
        if (std.mem.eql(u8, tier, "flex") and !model_capabilities.supports_flex_processing) {
            service_tier = null;
            try warnings.append(arena, unsupportedWarning("serviceTier", "flex processing is only available for o3, o4-mini, and gpt-5 models"));
        } else if (std.mem.eql(u8, tier, "priority") and !model_capabilities.supports_priority_processing) {
            service_tier = null;
            try warnings.append(arena, unsupportedWarning("serviceTier", "priority processing is only available for supported models (gpt-4, gpt-5, gpt-5-mini, o3, o4-mini) and requires Enterprise access. gpt-5-nano is not supported"));
        }
    }

    var body: std.json.ObjectMap = .empty;
    try putString(&body, arena, "model", self.model_id);
    try body.put(arena, "input", converted.value);
    if (temperature) |value| try body.put(arena, "temperature", .{ .float = value });
    if (top_p) |value| try body.put(arena, "top_p", .{ .float = value });
    if (call_options.max_output_tokens) |value| try body.put(arena, "max_output_tokens", try uintValue(arena, value));

    if ((call_options.response_format != null and call_options.response_format.? == .json) or openai_options.text_verbosity != null) {
        var text: std.json.ObjectMap = .empty;
        if (call_options.response_format) |format| switch (format) {
            .text => {},
            .json => |json| {
                var format_object: std.json.ObjectMap = .empty;
                if (json.schema) |schema| {
                    try putString(&format_object, arena, "type", "json_schema");
                    try format_object.put(arena, "strict", .{ .bool = openai_options.strict_json_schema });
                    try putString(&format_object, arena, "name", json.name orelse "response");
                    if (json.description) |description| try putString(&format_object, arena, "description", description);
                    try format_object.put(arena, "schema", try provider_utils.cloneJsonValue(arena, schema));
                } else try putString(&format_object, arena, "type", "json_object");
                try text.put(arena, "format", .{ .object = format_object });
            },
        };
        if (openai_options.text_verbosity) |value| try putString(&text, arena, "verbosity", value);
        try body.put(arena, "text", .{ .object = text });
    }

    if (openai_options.conversation) |value| try putString(&body, arena, "conversation", value);
    if (openai_options.max_tool_calls) |value| try body.put(arena, "max_tool_calls", try uintValue(arena, value));
    if (openai_options.metadata) |value| try body.put(arena, "metadata", try provider_utils.cloneJsonValue(arena, value));
    if (openai_options.parallel_tool_calls) |value| try body.put(arena, "parallel_tool_calls", .{ .bool = value });
    if (openai_options.previous_response_id) |value| try putString(&body, arena, "previous_response_id", value);
    if (openai_options.store) |value| try body.put(arena, "store", .{ .bool = value });
    if (openai_options.user) |value| try putString(&body, arena, "user", value);
    if (openai_options.instructions) |value| try putString(&body, arena, "instructions", value);
    if (service_tier) |value| try putString(&body, arena, "service_tier", value);
    if (include.items.len != 0) try body.put(arena, "include", try stringArray(arena, include.items));
    if (openai_options.prompt_cache_key) |value| try putString(&body, arena, "prompt_cache_key", value);
    if (openai_options.prompt_cache_options) |value| try body.put(arena, "prompt_cache_options", try provider_utils.cloneJsonValue(arena, value));
    if (openai_options.prompt_cache_retention) |value| try putString(&body, arena, "prompt_cache_retention", value);
    if (openai_options.safety_identifier) |value| try putString(&body, arena, "safety_identifier", value);
    if (top_logprobs) |value| try body.put(arena, "top_logprobs", try uintValue(arena, value));
    if (openai_options.truncation) |value| try putString(&body, arena, "truncation", value);
    if (openai_options.context_management) |values| {
        var output = std.json.Array.init(arena);
        for (values) |value| {
            var item: std.json.ObjectMap = .empty;
            try putString(&item, arena, "type", "compaction");
            try item.put(arena, "compact_threshold", try provider_utils.cloneJsonValue(arena, value.compact_threshold));
            try output.append(.{ .object = item });
        }
        try body.put(arena, "context_management", .{ .array = output });
    }
    if (is_reasoning_model and (resolved_reasoning_effort != null or resolved_reasoning_summary != null or
        openai_options.reasoning_mode != null or openai_options.reasoning_context != null))
    {
        var reasoning: std.json.ObjectMap = .empty;
        if (resolved_reasoning_effort) |value| try putString(&reasoning, arena, "effort", value);
        if (resolved_reasoning_summary) |value| try putString(&reasoning, arena, "summary", value);
        if (openai_options.reasoning_mode) |value| try putString(&reasoning, arena, "mode", value);
        if (openai_options.reasoning_context) |value| try putString(&reasoning, arena, "context", value);
        try body.put(arena, "reasoning", .{ .object = reasoning });
    }
    if (prepared_tools.tools) |value| try body.put(arena, "tools", value);
    if (prepared_tools.tool_choice) |value| try body.put(arena, "tool_choice", value);
    if (stream) try body.put(arena, "stream", .{ .bool = true });

    return .{
        .body = .{ .object = body },
        .warnings = try warnings.toOwnedSlice(arena),
        .metadata_key = self.config.provider_options_name,
        .store = store,
        .capture_logprobs = top_logprobs != null,
        .web_search_tool_name = web_search_tool_name,
        .shell_provider_executed = responses_tools.shellIsProviderExecuted(call_options.tools),
        .tool_names = try buildToolNames(arena, call_options.tools),
    };
}

fn mapGenerateResponse(
    io: std.Io,
    arena: Allocator,
    prepared: PreparedRequest,
    response: std.json.Value,
    response_headers: []const provider.Header,
    prompt: provider.Prompt,
    url: []const u8,
    diag: ?*provider.Diagnostics,
) provider.CallError!provider.GenerateResult {
    const root = try requireObject(response, arena, diag, "OpenAI Responses response must be an object");
    if (responses_api.objectField(root, "error")) |error_object| {
        const message = responses_api.optionalString(error_object, "message") orelse "OpenAI Responses API error";
        provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{ .api_call = .{
            .message = message,
            .url = url,
            .status_code = 400,
            .response_headers = response_headers,
            .response_body = try provider_utils.stringifyJsonValueAlloc(arena, response),
            .is_retryable = false,
        } });
        return error.APICallError;
    }

    var content: std.ArrayList(provider.Content) = .empty;
    defer content.deinit(arena);
    var logprobs = std.json.Array.init(arena);
    var generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag);
    var has_function_call = false;
    var hosted_tool_search_ids: std.ArrayList([]const u8) = .empty;
    defer hosted_tool_search_ids.deinit(arena);
    const output = responses_api.arrayField(root, "output") orelse std.json.Array.init(arena);
    for (output.items) |item_value| {
        if (item_value != .object) continue;
        const item = item_value.object;
        const kind = responses_api.optionalString(item, "type") orelse continue;
        if (std.mem.eql(u8, kind, "message")) {
            try appendMessageContent(arena, &content, &logprobs, &generator, item, prepared);
        } else if (std.mem.eql(u8, kind, "reasoning")) {
            try appendReasoningContent(arena, &content, item, prepared.metadata_key);
        } else if (std.mem.eql(u8, kind, "function_call")) {
            has_function_call = true;
            try content.append(arena, .{ .tool_call = .{
                .tool_call_id = try dupeOptional(arena, responses_api.optionalString(item, "call_id"), try generator.nextAlloc(arena)),
                .tool_name = try dupeOptional(arena, responses_api.optionalString(item, "name"), "unknown"),
                .input = try dupeOptional(arena, responses_api.optionalString(item, "arguments"), "{}"),
                .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, true),
            } });
        } else if (std.mem.eql(u8, kind, "custom_tool_call")) {
            has_function_call = true;
            const provider_name = responses_api.optionalString(item, "name") orelse "custom";
            const raw_input = responses_api.optionalString(item, "input") orelse "";
            try content.append(arena, .{ .tool_call = .{
                .tool_call_id = try dupeOptional(arena, responses_api.optionalString(item, "call_id"), try generator.nextAlloc(arena)),
                .tool_name = try arena.dupe(u8, customToolName(prepared.tool_names, provider_name)),
                .input = try provider_utils.stringifyJsonValueAlloc(arena, .{ .string = raw_input }),
                .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, false),
            } });
        } else if (std.mem.eql(u8, kind, "web_search_call")) {
            try appendWebSearch(arena, &content, item, prepared);
        } else if (std.mem.eql(u8, kind, "file_search_call")) {
            try appendFileSearch(arena, &content, item, prepared.tool_names);
        } else if (std.mem.eql(u8, kind, "code_interpreter_call")) {
            try appendCodeInterpreter(arena, &content, item, prepared.tool_names);
        } else if (std.mem.eql(u8, kind, "image_generation_call")) {
            try appendImageGeneration(arena, &content, item, prepared.tool_names, false);
        } else if (std.mem.eql(u8, kind, "computer_call")) {
            try appendComputer(arena, &content, item, prepared.tool_names);
        } else if (std.mem.eql(u8, kind, "local_shell_call")) {
            try appendLocalShell(arena, &content, item, prepared);
        } else if (std.mem.eql(u8, kind, "shell_call")) {
            try appendShellCall(arena, &content, item, prepared);
        } else if (std.mem.eql(u8, kind, "shell_call_output")) {
            try appendShellOutput(arena, &content, item, prepared.tool_names);
        } else if (std.mem.eql(u8, kind, "apply_patch_call")) {
            try appendApplyPatch(arena, &content, item, prepared);
        } else if (std.mem.eql(u8, kind, "tool_search_call")) {
            const call_id = responses_api.optionalString(item, "call_id") orelse responses_api.optionalString(item, "id") orelse try generator.nextAlloc(arena);
            const hosted = std.mem.eql(u8, responses_api.optionalString(item, "execution") orelse "server", "server");
            if (hosted) try hosted_tool_search_ids.append(arena, call_id);
            try appendToolSearchCall(arena, &content, item, call_id, hosted, prepared);
        } else if (std.mem.eql(u8, kind, "tool_search_output")) {
            const call_id = responses_api.optionalString(item, "call_id") orelse
                if (hosted_tool_search_ids.items.len != 0) hosted_tool_search_ids.orderedRemove(0) else responses_api.optionalString(item, "id") orelse try generator.nextAlloc(arena);
            try appendToolSearchOutput(arena, &content, item, call_id, prepared);
        } else if (std.mem.eql(u8, kind, "mcp_call")) {
            try appendMcpCall(arena, &content, item, prompt, prepared.metadata_key);
        } else if (std.mem.eql(u8, kind, "mcp_approval_request")) {
            try appendMcpApproval(arena, &content, item, &generator);
        } else if (std.mem.eql(u8, kind, "compaction")) {
            try content.append(arena, .{ .custom = .{
                .kind = "openai.compaction",
                .provider_metadata = try compactionMetadata(arena, prepared.metadata_key, item),
            } });
        }
    }

    const incomplete = responses_api.objectField(root, "incomplete_details");
    const raw_finish = if (incomplete) |details| responses_api.optionalString(details, "reason") else null;
    const usage_value = root.get("usage");
    return .{
        .content = try content.toOwnedSlice(arena),
        .finish_reason = .{
            .unified = responses_api.mapFinishReason(raw_finish, has_function_call),
            .raw = raw_finish,
        },
        .usage = try responses_api.convertUsage(arena, usage_value),
        .provider_metadata = try responseMetadata(arena, prepared.metadata_key, responses_api.optionalString(root, "id"), logprobs, responses_api.optionalString(root, "service_tier"), reasoningContext(root)),
        .request = .{ .body = prepared.body },
        .response = .{
            .id = responses_api.optionalString(root, "id"),
            .timestamp_ms = responses_api.timestampMillis(root.get("created_at")),
            .model_id = responses_api.optionalString(root, "model"),
            .headers = response_headers,
            .body = response,
        },
        .warnings = prepared.warnings,
    };
}

fn appendMessageContent(
    arena: Allocator,
    content: *std.ArrayList(provider.Content),
    logprobs: *std.json.Array,
    generator: *provider_utils.IdGenerator,
    item: std.json.ObjectMap,
    prepared: PreparedRequest,
) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const phase = responses_api.optionalString(item, "phase");
    const parts = responses_api.arrayField(item, "content") orelse return;
    for (parts.items) |part_value| {
        if (part_value != .object) continue;
        const part = part_value.object;
        if (!std.mem.eql(u8, responses_api.optionalString(part, "type") orelse "", "output_text")) continue;
        if (prepared.capture_logprobs) if (part.get("logprobs")) |value| if (value == .array and value.array.items.len != 0) {
            try logprobs.append(try sanitizeLogprobs(arena, value));
        };
        var details: std.json.ObjectMap = .empty;
        try putString(&details, arena, "itemId", id);
        if (phase) |value| try putString(&details, arena, "phase", value);
        if (part.get("annotations")) |annotations| if (annotations == .array and annotations.array.items.len != 0) {
            try details.put(arena, "annotations", try provider_utils.cloneJsonValue(arena, annotations));
        };
        try content.append(arena, .{ .text = .{
            .text = try dupeOptional(arena, responses_api.optionalString(part, "text"), ""),
            .provider_metadata = try namespacedMetadata(arena, prepared.metadata_key, details),
        } });
        if (responses_api.arrayField(part, "annotations")) |annotations| for (annotations.items) |annotation| {
            try appendAnnotationContent(arena, content, annotation, generator, prepared.metadata_key);
        };
    }
}

fn appendReasoningContent(
    arena: Allocator,
    content: *std.ArrayList(provider.Content),
    item: std.json.ObjectMap,
    metadata_key: []const u8,
) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const encrypted_value = item.get("encrypted_content") orelse std.json.Value.null;
    const summaries = responses_api.arrayField(item, "summary");
    if (summaries == null or summaries.?.items.len == 0) {
        try content.append(arena, .{ .reasoning = .{
            .text = "",
            .provider_metadata = try reasoningMetadata(arena, metadata_key, id, encrypted_value),
        } });
        return;
    }
    for (summaries.?.items) |summary| {
        if (summary != .object) continue;
        try content.append(arena, .{ .reasoning = .{
            .text = try dupeOptional(arena, responses_api.optionalString(summary.object, "text"), ""),
            .provider_metadata = try reasoningMetadata(arena, metadata_key, id, encrypted_value),
        } });
    }
}

fn appendWebSearch(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, prepared: PreparedRequest) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const provider_name = prepared.web_search_tool_name orelse "web_search";
    const name = customToolName(prepared.tool_names, provider_name);
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .input = "{}",
        .provider_executed = true,
    } });
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .result = try mapWebSearchOutput(arena, item.get("action")),
    } });
}

fn appendFileSearch(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, names: []const ToolName) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const name = customToolName(names, "file_search");
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .input = "{}",
        .provider_executed = true,
    } });
    var result: std.json.ObjectMap = .empty;
    if (item.get("queries")) |queries| try result.put(arena, "queries", try provider_utils.cloneJsonValue(arena, queries));
    if (item.get("results")) |results| {
        try result.put(arena, "results", if (results == .null) .null else try mapFileSearchResults(arena, results));
    } else try result.put(arena, "results", .null);
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .result = .{ .object = result },
    } });
}

fn appendCodeInterpreter(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, names: []const ToolName) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const name = customToolName(names, "code_interpreter");
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .input = try codeInterpreterInput(arena, item),
        .provider_executed = true,
    } });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "outputs", try provider_utils.cloneJsonValue(arena, item.get("outputs") orelse .null));
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .result = .{ .object = result },
    } });
}

fn appendImageGeneration(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, names: []const ToolName, preliminary: bool) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const name = customToolName(names, "image_generation");
    if (!preliminary) try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .input = "{}",
        .provider_executed = true,
    } });
    var result: std.json.ObjectMap = .empty;
    try putString(&result, arena, "result", responses_api.optionalString(item, if (preliminary) "partial_image_b64" else "result") orelse "");
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .result = .{ .object = result },
        .preliminary = if (preliminary) true else null,
    } });
}

fn appendComputer(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, names: []const ToolName) Allocator.Error!void {
    const id = responses_api.optionalString(item, "id") orelse "";
    const name = customToolName(names, "computer_use");
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .input = "",
        .provider_executed = true,
    } });
    var result: std.json.ObjectMap = .empty;
    try putString(&result, arena, "type", "computer_use_tool_result");
    try putString(&result, arena, "status", responses_api.optionalString(item, "status") orelse "completed");
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = try arena.dupe(u8, name),
        .result = .{ .object = result },
    } });
}

fn appendLocalShell(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, prepared: PreparedRequest) Allocator.Error!void {
    const call_id = responses_api.optionalString(item, "call_id") orelse "";
    const name = customToolName(prepared.tool_names, "local_shell");
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, call_id),
        .tool_name = try arena.dupe(u8, name),
        .input = try localShellInput(arena, item),
        .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, false),
    } });
}

fn appendShellCall(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, prepared: PreparedRequest) Allocator.Error!void {
    const call_id = responses_api.optionalString(item, "call_id") orelse "";
    const name = customToolName(prepared.tool_names, "shell");
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, call_id),
        .tool_name = try arena.dupe(u8, name),
        .input = try shellInput(arena, item),
        .provider_executed = if (prepared.shell_provider_executed) true else null,
        .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, false),
    } });
}

fn appendShellOutput(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, names: []const ToolName) Allocator.Error!void {
    const call_id = responses_api.optionalString(item, "call_id") orelse "";
    const name = customToolName(names, "shell");
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, call_id),
        .tool_name = try arena.dupe(u8, name),
        .result = try shellResult(arena, item),
    } });
}

fn appendApplyPatch(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, prepared: PreparedRequest) Allocator.Error!void {
    const call_id = responses_api.optionalString(item, "call_id") orelse "";
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, call_id),
        .tool_name = try arena.dupe(u8, customToolName(prepared.tool_names, "apply_patch")),
        .input = try applyPatchInput(arena, item),
        .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, false),
    } });
}

fn appendToolSearchCall(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, call_id: []const u8, hosted: bool, prepared: PreparedRequest) Allocator.Error!void {
    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "arguments", try provider_utils.cloneJsonValue(arena, item.get("arguments") orelse .null));
    if (hosted) try input.put(arena, "call_id", .null) else try putString(&input, arena, "call_id", call_id);
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, call_id),
        .tool_name = try arena.dupe(u8, customToolName(prepared.tool_names, "tool_search")),
        .input = try provider_utils.stringifyJsonValueAlloc(arena, .{ .object = input }),
        .provider_executed = if (hosted) true else null,
        .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, false),
    } });
}

fn appendToolSearchOutput(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, call_id: []const u8, prepared: PreparedRequest) Allocator.Error!void {
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "tools", try provider_utils.cloneJsonValue(arena, item.get("tools") orelse .{ .array = .init(arena) }));
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, call_id),
        .tool_name = try arena.dupe(u8, customToolName(prepared.tool_names, "tool_search")),
        .result = .{ .object = result },
        .provider_metadata = try itemMetadata(arena, prepared.metadata_key, item, false),
    } });
}

fn appendMcpCall(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, prompt: provider.Prompt, metadata_key: []const u8) Allocator.Error!void {
    const approval_id = responses_api.optionalString(item, "approval_request_id");
    const id = if (approval_id) |approval| approvalAliasFromPrompt(prompt, approval) orelse responses_api.optionalString(item, "id") orelse "" else responses_api.optionalString(item, "id") orelse "";
    const raw_name = responses_api.optionalString(item, "name") orelse "unknown";
    const name = try std.fmt.allocPrint(arena, "mcp.{s}", .{raw_name});
    const arguments = responses_api.optionalString(item, "arguments") orelse "{}";
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = name,
        .input = try arena.dupe(u8, arguments),
        .provider_executed = true,
        .dynamic = true,
    } });
    var result: std.json.ObjectMap = .empty;
    try putString(&result, arena, "type", "call");
    try putString(&result, arena, "serverLabel", responses_api.optionalString(item, "server_label") orelse "");
    try putString(&result, arena, "name", raw_name);
    try putString(&result, arena, "arguments", arguments);
    if (item.get("output")) |output| if (output != .null) try result.put(arena, "output", try provider_utils.cloneJsonValue(arena, output));
    if (item.get("error")) |error_value| if (error_value != .null) try result.put(arena, "error", try provider_utils.cloneJsonValue(arena, error_value));
    try content.append(arena, .{ .tool_result = .{
        .tool_call_id = try arena.dupe(u8, id),
        .tool_name = name,
        .result = .{ .object = result },
        .dynamic = true,
        .provider_metadata = try itemMetadata(arena, metadata_key, item, false),
    } });
}

fn appendMcpApproval(arena: Allocator, content: *std.ArrayList(provider.Content), item: std.json.ObjectMap, generator: *provider_utils.IdGenerator) Allocator.Error!void {
    const approval_id = responses_api.optionalString(item, "approval_request_id") orelse responses_api.optionalString(item, "id") orelse "";
    const call_id = try generator.nextAlloc(arena);
    const name = try std.fmt.allocPrint(arena, "mcp.{s}", .{responses_api.optionalString(item, "name") orelse "unknown"});
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = call_id,
        .tool_name = name,
        .input = try dupeOptional(arena, responses_api.optionalString(item, "arguments"), "{}"),
        .provider_executed = true,
        .dynamic = true,
    } });
    try content.append(arena, .{ .tool_approval_request = .{
        .approval_id = try arena.dupe(u8, approval_id),
        .tool_call_id = call_id,
    } });
}

fn appendAnnotationContent(
    arena: Allocator,
    content: *std.ArrayList(provider.Content),
    annotation_value: std.json.Value,
    generator: *provider_utils.IdGenerator,
    metadata_key: []const u8,
) Allocator.Error!void {
    const source = try annotationSource(arena, annotation_value, generator, metadata_key) orelse return;
    try content.append(arena, .{ .source = source });
}

fn annotationSource(
    arena: Allocator,
    annotation_value: std.json.Value,
    generator: *provider_utils.IdGenerator,
    metadata_key: []const u8,
) Allocator.Error!?provider.Source {
    if (annotation_value != .object) return null;
    const annotation = annotation_value.object;
    const kind = responses_api.optionalString(annotation, "type") orelse return null;
    if (std.mem.eql(u8, kind, "url_citation")) return .{ .url = .{
        .id = try generator.nextAlloc(arena),
        .url = try dupeOptional(arena, responses_api.optionalString(annotation, "url"), ""),
        .title = if (responses_api.optionalString(annotation, "title")) |title| try arena.dupe(u8, title) else null,
    } };

    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "type", kind);
    const file_id = responses_api.optionalString(annotation, "file_id") orelse "";
    try putString(&details, arena, "fileId", file_id);
    if (std.mem.eql(u8, kind, "file_citation") or std.mem.eql(u8, kind, "file_path")) {
        if (annotation.get("index")) |index| try details.put(arena, "index", try provider_utils.cloneJsonValue(arena, index));
    } else if (std.mem.eql(u8, kind, "container_file_citation")) {
        try putString(&details, arena, "containerId", responses_api.optionalString(annotation, "container_id") orelse "");
    } else return null;
    const filename = responses_api.optionalString(annotation, "filename") orelse file_id;
    return .{ .document = .{
        .id = try generator.nextAlloc(arena),
        .media_type = if (std.mem.eql(u8, kind, "file_path")) "application/octet-stream" else "text/plain",
        .title = try arena.dupe(u8, filename),
        .filename = try arena.dupe(u8, filename),
        .provider_metadata = try namespacedMetadata(arena, metadata_key, details),
    } };
}

fn mapWebSearchOutput(arena: Allocator, action_value: ?std.json.Value) Allocator.Error!std.json.Value {
    const value = action_value orelse return .{ .object = .empty };
    if (value != .object) return .{ .object = .empty };
    const action = value.object;
    const kind = responses_api.optionalString(action, "type") orelse return .{ .object = .empty };
    var result: std.json.ObjectMap = .empty;
    var mapped: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, kind, "search")) {
        try putString(&mapped, arena, "type", "search");
        if (action.get("query")) |query| if (query != .null) try mapped.put(arena, "query", try provider_utils.cloneJsonValue(arena, query));
        if (action.get("queries")) |queries| if (queries != .null) try mapped.put(arena, "queries", try provider_utils.cloneJsonValue(arena, queries));
        try result.put(arena, "action", .{ .object = mapped });
        if (action.get("sources")) |sources| if (sources != .null) try result.put(arena, "sources", try provider_utils.cloneJsonValue(arena, sources));
    } else if (std.mem.eql(u8, kind, "open_page")) {
        try putString(&mapped, arena, "type", "openPage");
        try mapped.put(arena, "url", try provider_utils.cloneJsonValue(arena, action.get("url") orelse .null));
        try result.put(arena, "action", .{ .object = mapped });
    } else if (std.mem.eql(u8, kind, "find_in_page")) {
        try putString(&mapped, arena, "type", "findInPage");
        try mapped.put(arena, "url", try provider_utils.cloneJsonValue(arena, action.get("url") orelse .null));
        try mapped.put(arena, "pattern", try provider_utils.cloneJsonValue(arena, action.get("pattern") orelse .null));
        try result.put(arena, "action", .{ .object = mapped });
    }
    return .{ .object = result };
}

fn mapFileSearchResults(arena: Allocator, value: std.json.Value) Allocator.Error!std.json.Value {
    if (value != .array) return try provider_utils.cloneJsonValue(arena, value);
    var output = std.json.Array.init(arena);
    for (value.array.items) |entry| {
        if (entry != .object) continue;
        var mapped: std.json.ObjectMap = .empty;
        if (entry.object.get("attributes")) |attributes| try mapped.put(arena, "attributes", try provider_utils.cloneJsonValue(arena, attributes));
        if (responses_api.optionalString(entry.object, "file_id")) |file_id| try putString(&mapped, arena, "fileId", file_id);
        if (responses_api.optionalString(entry.object, "filename")) |filename| try putString(&mapped, arena, "filename", filename);
        if (entry.object.get("score")) |score| try mapped.put(arena, "score", try provider_utils.cloneJsonValue(arena, score));
        if (responses_api.optionalString(entry.object, "text")) |text| try putString(&mapped, arena, "text", text);
        try output.append(.{ .object = mapped });
    }
    return .{ .array = output };
}

fn sanitizeLogprobs(arena: Allocator, value: std.json.Value) Allocator.Error!std.json.Value {
    if (value != .array) return .{ .array = .init(arena) };
    var output = std.json.Array.init(arena);
    for (value.array.items) |entry| {
        if (entry != .object) continue;
        var mapped: std.json.ObjectMap = .empty;
        if (responses_api.optionalString(entry.object, "token")) |token| try putString(&mapped, arena, "token", token);
        if (entry.object.get("logprob")) |logprob| try mapped.put(arena, "logprob", try provider_utils.cloneJsonValue(arena, logprob));
        var top = std.json.Array.init(arena);
        if (responses_api.arrayField(entry.object, "top_logprobs")) |top_values| for (top_values.items) |top_entry| {
            if (top_entry != .object) continue;
            var top_mapped: std.json.ObjectMap = .empty;
            if (responses_api.optionalString(top_entry.object, "token")) |token| try putString(&top_mapped, arena, "token", token);
            if (top_entry.object.get("logprob")) |logprob| try top_mapped.put(arena, "logprob", try provider_utils.cloneJsonValue(arena, logprob));
            try top.append(.{ .object = top_mapped });
        };
        try mapped.put(arena, "top_logprobs", .{ .array = top });
        try output.append(.{ .object = mapped });
    }
    return .{ .array = output };
}

fn codeInterpreterInput(arena: Allocator, item: std.json.ObjectMap) Allocator.Error![]const u8 {
    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "code", try provider_utils.cloneJsonValue(arena, item.get("code") orelse .null));
    try putString(&input, arena, "containerId", responses_api.optionalString(item, "container_id") orelse "");
    return provider_utils.stringifyJsonValueAlloc(arena, .{ .object = input });
}

fn localShellInput(arena: Allocator, item: std.json.ObjectMap) Allocator.Error![]const u8 {
    const action = responses_api.objectField(item, "action") orelse std.json.ObjectMap.empty;
    var mapped_action: std.json.ObjectMap = .empty;
    try putString(&mapped_action, arena, "type", "exec");
    if (action.get("command")) |command| try mapped_action.put(arena, "command", try provider_utils.cloneJsonValue(arena, command));
    try copySnakeToCamel(arena, &mapped_action, action, "timeout_ms", "timeoutMs");
    try copySnakeToCamel(arena, &mapped_action, action, "user", "user");
    try copySnakeToCamel(arena, &mapped_action, action, "working_directory", "workingDirectory");
    try copySnakeToCamel(arena, &mapped_action, action, "env", "env");
    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "action", .{ .object = mapped_action });
    return provider_utils.stringifyJsonValueAlloc(arena, .{ .object = input });
}

fn shellInput(arena: Allocator, item: std.json.ObjectMap) Allocator.Error![]const u8 {
    const action = responses_api.objectField(item, "action") orelse std.json.ObjectMap.empty;
    var mapped_action: std.json.ObjectMap = .empty;
    if (action.get("commands")) |commands| try mapped_action.put(arena, "commands", try provider_utils.cloneJsonValue(arena, commands));
    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "action", .{ .object = mapped_action });
    return provider_utils.stringifyJsonValueAlloc(arena, .{ .object = input });
}

fn shellResult(arena: Allocator, item: std.json.ObjectMap) Allocator.Error!std.json.Value {
    var output = std.json.Array.init(arena);
    if (responses_api.arrayField(item, "output")) |items| for (items.items) |entry| {
        if (entry != .object) continue;
        var mapped: std.json.ObjectMap = .empty;
        try putString(&mapped, arena, "stdout", responses_api.optionalString(entry.object, "stdout") orelse "");
        try putString(&mapped, arena, "stderr", responses_api.optionalString(entry.object, "stderr") orelse "");
        if (responses_api.objectField(entry.object, "outcome")) |outcome| {
            var mapped_outcome: std.json.ObjectMap = .empty;
            const kind = responses_api.optionalString(outcome, "type") orelse "timeout";
            try putString(&mapped_outcome, arena, "type", kind);
            if (std.mem.eql(u8, kind, "exit")) if (outcome.get("exit_code")) |code| try mapped_outcome.put(arena, "exitCode", try provider_utils.cloneJsonValue(arena, code));
            try mapped.put(arena, "outcome", .{ .object = mapped_outcome });
        }
        try output.append(.{ .object = mapped });
    };
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "output", .{ .array = output });
    return .{ .object = result };
}

fn applyPatchInput(arena: Allocator, item: std.json.ObjectMap) Allocator.Error![]const u8 {
    var input: std.json.ObjectMap = .empty;
    try putString(&input, arena, "callId", responses_api.optionalString(item, "call_id") orelse "");
    try input.put(arena, "operation", try provider_utils.cloneJsonValue(arena, item.get("operation") orelse .null));
    return provider_utils.stringifyJsonValueAlloc(arena, .{ .object = input });
}

fn itemMetadata(arena: Allocator, key: []const u8, item: std.json.ObjectMap, include_namespace: bool) Allocator.Error!?provider.ProviderMetadata {
    const id = responses_api.optionalString(item, "id") orelse return null;
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "itemId", id);
    if (include_namespace) if (responses_api.optionalString(item, "namespace")) |namespace| try putString(&details, arena, "namespace", namespace);
    return try namespacedMetadata(arena, key, details);
}

fn reasoningMetadata(arena: Allocator, key: []const u8, item_id: []const u8, encrypted: std.json.Value) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "itemId", item_id);
    try details.put(arena, "reasoningEncryptedContent", try provider_utils.cloneJsonValue(arena, encrypted));
    return namespacedMetadata(arena, key, details);
}

fn textMetadata(arena: Allocator, key: []const u8, item_id: []const u8, phase: ?[]const u8, annotations: []const std.json.Value) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "itemId", item_id);
    if (phase) |value| try putString(&details, arena, "phase", value);
    if (annotations.len != 0) {
        var values = std.json.Array.init(arena);
        for (annotations) |annotation| try values.append(try provider_utils.cloneJsonValue(arena, annotation));
        try details.put(arena, "annotations", .{ .array = values });
    }
    return namespacedMetadata(arena, key, details);
}

fn compactionMetadata(arena: Allocator, key: []const u8, item: std.json.ObjectMap) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "type", "compaction");
    try putString(&details, arena, "itemId", responses_api.optionalString(item, "id") orelse "");
    if (responses_api.optionalString(item, "encrypted_content")) |encrypted| try putString(&details, arena, "encryptedContent", encrypted);
    return namespacedMetadata(arena, key, details);
}

fn responseMetadata(
    arena: Allocator,
    key: []const u8,
    response_id: ?[]const u8,
    logprobs: std.json.Array,
    service_tier: ?[]const u8,
    reasoning_context: ?[]const u8,
) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    if (response_id) |id| try putString(&details, arena, "responseId", id) else try details.put(arena, "responseId", .null);
    if (logprobs.items.len != 0) try details.put(arena, "logprobs", .{ .array = logprobs });
    if (service_tier) |tier| try putString(&details, arena, "serviceTier", tier);
    if (reasoning_context) |context| try putString(&details, arena, "reasoningContext", context);
    return namespacedMetadata(arena, key, details);
}

fn namespacedMetadata(arena: Allocator, key: []const u8, details: std.json.ObjectMap) Allocator.Error!provider.ProviderMetadata {
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, try arena.dupe(u8, key), .{ .object = details });
    return .{ .object = root };
}

fn reasoningContext(root: std.json.ObjectMap) ?[]const u8 {
    const reasoning = responses_api.objectField(root, "reasoning") orelse return null;
    return responses_api.optionalString(reasoning, "context");
}

fn approvalAliasFromPrompt(prompt: provider.Prompt, approval_id: []const u8) ?[]const u8 {
    for (prompt) |message| switch (message) {
        .assistant => |assistant| for (assistant.content) |part| switch (part) {
            .tool_call => |call| {
                const options = options_api.namespaceObject(call.provider_options, "openai") orelse continue;
                const current = responses_api.optionalString(options, "approvalRequestId") orelse continue;
                if (std.mem.eql(u8, current, approval_id)) return call.tool_call_id;
            },
            else => {},
        },
        else => {},
    };
    return null;
}

const ApplyPatchState = struct {
    has_diff: bool,
    end_emitted: bool,
};

const OngoingToolCall = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    code_container_id: ?[]const u8 = null,
    apply_patch: ?ApplyPatchState = null,
    tool_search_execution: ?[]const u8 = null,
};

const SummaryStatus = enum { active, can_conclude, concluded };

const ReasoningState = struct {
    encrypted_content: std.json.Value = .null,
    summary_parts: std.AutoHashMapUnmanaged(usize, SummaryStatus) = .empty,

    fn deinit(self: *ReasoningState, arena: Allocator) void {
        self.summary_parts.deinit(arena);
    }
};

const StreamState = struct {
    arena: Allocator,
    events: provider_utils.JsonEventStream(std.json.Value),
    warnings: []const provider.Warning,
    metadata_key: []const u8,
    include_raw: bool,
    store: bool,
    capture_logprobs: bool,
    web_search_tool_name: ?[]const u8,
    shell_provider_executed: bool,
    tool_names: []const ToolName,
    diag: ?*provider.Diagnostics,
    id_generator: provider_utils.IdGenerator,
    ongoing_tools: std.AutoHashMapUnmanaged(usize, OngoingToolCall) = .empty,
    active_reasoning: std.StringHashMapUnmanaged(ReasoningState) = .empty,
    annotations: std.ArrayList(std.json.Value) = .empty,
    active_message_phase: ?[]const u8 = null,
    approval_aliases_prompt: std.StringHashMapUnmanaged([]const u8) = .empty,
    approval_aliases_stream: std.StringHashMapUnmanaged([]const u8) = .empty,
    hosted_tool_search_ids: std.ArrayList([]const u8) = .empty,
    queue: std.ArrayList(provider.StreamPart) = .empty,
    queue_index: usize = 0,
    finish_reason: provider.FinishReason = .{ .unified = .other },
    usage: ?std.json.Value = null,
    logprobs: std.json.Array,
    response_id: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    reasoning_context: ?[]const u8 = null,
    has_function_call: bool = false,
    encountered_error: bool = false,
    ended: bool = false,
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
        self.ongoing_tools.deinit(self.arena);
        var reasoning_iterator = self.active_reasoning.iterator();
        while (reasoning_iterator.next()) |entry| entry.value_ptr.deinit(self.arena);
        self.active_reasoning.deinit(self.arena);
        self.annotations.deinit(self.arena);
        self.approval_aliases_prompt.deinit(self.arena);
        self.approval_aliases_stream.deinit(self.arena);
        self.hosted_tool_search_ids.deinit(self.arena);
        self.queue.deinit(self.arena);
        self.logprobs.deinit();
        self.deinitialized = true;
    }

    fn captureApprovalAliases(self: *StreamState, prompt: provider.Prompt) Allocator.Error!void {
        for (prompt) |message| switch (message) {
            .assistant => |assistant| for (assistant.content) |part| switch (part) {
                .tool_call => |call| {
                    const options = options_api.namespaceObject(call.provider_options, "openai") orelse continue;
                    const approval_id = responses_api.optionalString(options, "approvalRequestId") orelse continue;
                    try self.approval_aliases_prompt.put(self.arena, approval_id, call.tool_call_id);
                },
                else => {},
            },
            else => {},
        };
    }

    fn peekForEarlyFrames(
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
            if (event == null) {
                try self.flush();
                return;
            }
            switch (event.?) {
                .failure => |failure| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = .{ .string = failure.raw } } });
                    self.finish_reason = .{ .unified = .@"error", .raw = "error" };
                    try self.queue.append(self.arena, .{ .err = .{ .error_value = .{ .string = failure.message } } });
                    return;
                },
                .success => |success| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = success.value } });
                    if (isEarlyErrorEvent(success.value)) {
                        try api.streamError(self.arena, success.value, url, request_body_json, response_headers, self.diag);
                        unreachable;
                    }
                    const output = isOutputEvent(success.value);
                    try self.mapEvent(success.value);
                    if (output or responses_api.isChatCompletionShape(success.value)) return;
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
                    self.finish_reason = .{ .unified = .@"error", .raw = "error" };
                    try self.queue.append(self.arena, .{ .err = .{ .error_value = .{ .string = failure.message } } });
                },
                .success => |success| {
                    if (self.include_raw) try self.queue.append(self.arena, .{ .raw = .{ .raw_value = success.value } });
                    try self.mapEvent(success.value);
                },
            }
        }
    }

    fn mapEvent(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (responses_api.isChatCompletionShape(value)) return self.chatCompletionMismatch(value);
        if (value != .object) return;
        const root = value.object;
        const event_type = responses_api.optionalString(root, "type") orelse return;

        if (std.mem.eql(u8, event_type, "response.created")) return self.responseCreated(root);
        if (std.mem.eql(u8, event_type, "response.output_item.added")) return self.outputItemAdded(root);
        if (std.mem.eql(u8, event_type, "response.output_item.done")) return self.outputItemDone(root);
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta") or
            std.mem.eql(u8, event_type, "response.custom_tool_call_input.delta")) return self.toolInputDelta(root);
        if (std.mem.eql(u8, event_type, "response.code_interpreter_call_code.delta")) return self.codeInterpreterDelta(root);
        if (std.mem.eql(u8, event_type, "response.code_interpreter_call_code.done")) return self.codeInterpreterDone(root);
        if (std.mem.eql(u8, event_type, "response.apply_patch_call_operation_diff.delta")) return self.applyPatchDelta(root);
        if (std.mem.eql(u8, event_type, "response.apply_patch_call_operation_diff.done")) return self.applyPatchDone(root);
        if (std.mem.eql(u8, event_type, "response.image_generation_call.partial_image")) return self.imagePartial(root);
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) return self.outputTextDelta(root);
        if (std.mem.eql(u8, event_type, "response.output_text.annotation.added")) return self.annotationAdded(root);
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) return self.reasoningPartAdded(root);
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) return self.reasoningTextDelta(root);
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) return self.reasoningPartDone(root);
        if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) return self.responseFinished(root);
        if (std.mem.eql(u8, event_type, "response.failed")) return self.responseFailed(root, value);
        if (std.mem.eql(u8, event_type, "error")) {
            self.encountered_error = true;
            self.finish_reason = .{ .unified = .@"error", .raw = "error" };
            try self.queue.append(self.arena, .{ .err = .{ .error_value = try provider_utils.cloneJsonValue(self.arena, value) } });
        }
        // Every other event type is intentionally ignored. This is the
        // upstream `unknown_chunk` coercion, including lifecycle events added
        // by newer APIs such as response.in_progress and *.completed.
    }

    fn chatCompletionMismatch(self: *StreamState, value: std.json.Value) provider.NextError!void {
        const message =
            "Received a Chat Completions stream while using the OpenAI Responses API. " ++
            "The default OpenAI provider model uses the Responses API. If your custom baseURL targets a Chat Completions-compatible endpoint, use openai.chat('model-id') or createOpenAI(...).chat('model-id') instead. " ++
            "You can also use @ai-sdk/openai-compatible for OpenAI-compatible providers.";
        var error_object: std.json.ObjectMap = .empty;
        try putString(&error_object, self.arena, "name", "AI_APICallError");
        try putString(&error_object, self.arena, "message", message);
        try putString(&error_object, self.arena, "responseBody", try provider_utils.stringifyJsonValueAlloc(self.arena, value));
        self.finish_reason = .{ .unified = .@"error", .raw = "error" };
        try self.queue.append(self.arena, .{ .err = .{ .error_value = .{ .object = error_object } } });
    }

    fn responseCreated(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const response = responses_api.objectField(root, "response") orelse return;
        self.response_id = responses_api.optionalString(response, "id");
        try self.queue.append(self.arena, .{ .response_metadata = .{
            .id = self.response_id,
            .timestamp_ms = responses_api.timestampMillis(response.get("created_at")),
            .model_id = responses_api.optionalString(response, "model"),
        } });
    }

    fn outputItemAdded(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const output_index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const item = responses_api.objectField(root, "item") orelse return;
        const kind = responses_api.optionalString(item, "type") orelse return;

        if (std.mem.eql(u8, kind, "function_call")) {
            const id = responses_api.optionalString(item, "call_id") orelse return;
            const name = responses_api.optionalString(item, "name") orelse "unknown";
            try self.ongoing_tools.put(self.arena, output_index, .{ .tool_name = name, .tool_call_id = id });
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = id, .tool_name = name } });
        } else if (std.mem.eql(u8, kind, "custom_tool_call")) {
            const id = responses_api.optionalString(item, "call_id") orelse return;
            const name = customToolName(self.tool_names, responses_api.optionalString(item, "name") orelse "custom");
            try self.ongoing_tools.put(self.arena, output_index, .{ .tool_name = name, .tool_call_id = id });
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = id, .tool_name = name } });
        } else if (std.mem.eql(u8, kind, "web_search_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            const provider_name = self.web_search_tool_name orelse "web_search";
            const name = customToolName(self.tool_names, provider_name);
            try self.ongoing_tools.put(self.arena, output_index, .{ .tool_name = name, .tool_call_id = id });
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = id, .tool_name = name, .provider_executed = true } });
            try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = id } });
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = name,
                .input = "{}",
                .provider_executed = true,
            } });
        } else if (std.mem.eql(u8, kind, "computer_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            const name = customToolName(self.tool_names, "computer_use");
            try self.ongoing_tools.put(self.arena, output_index, .{ .tool_name = name, .tool_call_id = id });
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = id, .tool_name = name, .provider_executed = true } });
        } else if (std.mem.eql(u8, kind, "code_interpreter_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            const container_id = responses_api.optionalString(item, "container_id") orelse "";
            const name = customToolName(self.tool_names, "code_interpreter");
            try self.ongoing_tools.put(self.arena, output_index, .{
                .tool_name = name,
                .tool_call_id = id,
                .code_container_id = container_id,
            });
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = id, .tool_name = name, .provider_executed = true } });
            try self.queue.append(self.arena, .{ .tool_input_delta = .{
                .id = id,
                .delta = try std.fmt.allocPrint(self.arena, "{{\"containerId\":\"{s}\",\"code\":\"", .{container_id}),
            } });
        } else if (std.mem.eql(u8, kind, "file_search_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = customToolName(self.tool_names, "file_search"),
                .input = "{}",
                .provider_executed = true,
            } });
        } else if (std.mem.eql(u8, kind, "image_generation_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = customToolName(self.tool_names, "image_generation"),
                .input = "{}",
                .provider_executed = true,
            } });
        } else if (std.mem.eql(u8, kind, "tool_search_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            const execution = responses_api.optionalString(item, "execution") orelse "server";
            const name = customToolName(self.tool_names, "tool_search");
            try self.ongoing_tools.put(self.arena, output_index, .{
                .tool_name = name,
                .tool_call_id = id,
                .tool_search_execution = execution,
            });
            if (std.mem.eql(u8, execution, "server")) try self.queue.append(self.arena, .{ .tool_input_start = .{
                .id = id,
                .tool_name = name,
                .provider_executed = true,
            } });
        } else if (std.mem.eql(u8, kind, "apply_patch_call")) {
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            const operation = responses_api.objectField(item, "operation") orelse return;
            const operation_type = responses_api.optionalString(operation, "type") orelse return;
            const delete_file = std.mem.eql(u8, operation_type, "delete_file");
            const name = customToolName(self.tool_names, "apply_patch");
            try self.ongoing_tools.put(self.arena, output_index, .{
                .tool_name = name,
                .tool_call_id = call_id,
                .apply_patch = .{ .has_diff = delete_file, .end_emitted = delete_file },
            });
            try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = call_id, .tool_name = name } });
            if (delete_file) {
                try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = call_id, .delta = try applyPatchInput(self.arena, item) } });
                try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = call_id } });
            } else {
                const prefix = try std.fmt.allocPrint(
                    self.arena,
                    "{{\"callId\":\"{s}\",\"operation\":{{\"type\":\"{s}\",\"path\":\"{s}\",\"diff\":\"",
                    .{
                        try responses_api.escapeJsonDelta(self.arena, call_id),
                        try responses_api.escapeJsonDelta(self.arena, operation_type),
                        try responses_api.escapeJsonDelta(self.arena, responses_api.optionalString(operation, "path") orelse ""),
                    },
                );
                try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = call_id, .delta = prefix } });
            }
        } else if (std.mem.eql(u8, kind, "shell_call")) {
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            try self.ongoing_tools.put(self.arena, output_index, .{
                .tool_name = customToolName(self.tool_names, "shell"),
                .tool_call_id = call_id,
            });
        } else if (std.mem.eql(u8, kind, "message")) {
            self.annotations.clearRetainingCapacity();
            self.active_message_phase = responses_api.optionalString(item, "phase");
            const id = responses_api.optionalString(item, "id") orelse return;
            try self.queue.append(self.arena, .{ .text_start = .{
                .id = id,
                .provider_metadata = try textMetadata(self.arena, self.metadata_key, id, self.active_message_phase, &.{}),
            } });
        } else if (std.mem.eql(u8, kind, "reasoning")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            if (self.active_reasoning.fetchRemove(id)) |removed| {
                var old = removed.value;
                old.deinit(self.arena);
            }
            var state: ReasoningState = .{
                .encrypted_content = try provider_utils.cloneJsonValue(self.arena, item.get("encrypted_content") orelse .null),
            };
            try state.summary_parts.put(self.arena, 0, .active);
            try self.active_reasoning.put(self.arena, id, state);
            try self.queue.append(self.arena, .{ .reasoning_start = .{
                .id = try reasoningPartId(self.arena, id, 0),
                .provider_metadata = try reasoningMetadata(self.arena, self.metadata_key, id, state.encrypted_content),
            } });
        }
    }

    fn outputItemDone(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const output_index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const item = responses_api.objectField(root, "item") orelse return;
        const kind = responses_api.optionalString(item, "type") orelse return;

        if (std.mem.eql(u8, kind, "message")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            const phase = responses_api.optionalString(item, "phase") orelse self.active_message_phase;
            self.active_message_phase = null;
            try self.queue.append(self.arena, .{ .text_end = .{
                .id = id,
                .provider_metadata = try textMetadata(self.arena, self.metadata_key, id, phase, self.annotations.items),
            } });
        } else if (std.mem.eql(u8, kind, "function_call")) {
            _ = self.ongoing_tools.remove(output_index);
            self.has_function_call = true;
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            const namespace = responses_api.optionalString(item, "namespace");
            try self.queue.append(self.arena, .{ .tool_input_end = .{
                .id = call_id,
                .provider_metadata = if (namespace) |value| try namespaceOnlyMetadata(self.arena, self.metadata_key, value) else null,
            } });
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = call_id,
                .tool_name = responses_api.optionalString(item, "name") orelse "unknown",
                .input = responses_api.optionalString(item, "arguments") orelse "{}",
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, true),
            } });
        } else if (std.mem.eql(u8, kind, "custom_tool_call")) {
            _ = self.ongoing_tools.remove(output_index);
            self.has_function_call = true;
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            const name = customToolName(self.tool_names, responses_api.optionalString(item, "name") orelse "custom");
            try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = call_id } });
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = call_id,
                .tool_name = name,
                .input = try provider_utils.stringifyJsonValueAlloc(self.arena, .{ .string = responses_api.optionalString(item, "input") orelse "" }),
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
            } });
        } else if (std.mem.eql(u8, kind, "web_search_call")) {
            _ = self.ongoing_tools.remove(output_index);
            const id = responses_api.optionalString(item, "id") orelse return;
            const provider_name = self.web_search_tool_name orelse "web_search";
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = id,
                .tool_name = customToolName(self.tool_names, provider_name),
                .result = try mapWebSearchOutput(self.arena, item.get("action")),
            } });
        } else if (std.mem.eql(u8, kind, "computer_call")) {
            _ = self.ongoing_tools.remove(output_index);
            const id = responses_api.optionalString(item, "id") orelse return;
            const name = customToolName(self.tool_names, "computer_use");
            try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = id } });
            try self.queue.append(self.arena, .{ .tool_call = .{ .tool_call_id = id, .tool_name = name, .input = "", .provider_executed = true } });
            var result: std.json.ObjectMap = .empty;
            try putString(&result, self.arena, "type", "computer_use_tool_result");
            try putString(&result, self.arena, "status", responses_api.optionalString(item, "status") orelse "completed");
            try self.queue.append(self.arena, .{ .tool_result = .{ .tool_call_id = id, .tool_name = name, .result = .{ .object = result } } });
        } else if (std.mem.eql(u8, kind, "file_search_call")) {
            _ = self.ongoing_tools.remove(output_index);
            const id = responses_api.optionalString(item, "id") orelse return;
            var result: std.json.ObjectMap = .empty;
            if (item.get("queries")) |queries| try result.put(self.arena, "queries", try provider_utils.cloneJsonValue(self.arena, queries));
            if (item.get("results")) |results| try result.put(self.arena, "results", if (results == .null) .null else try mapFileSearchResults(self.arena, results)) else try result.put(self.arena, "results", .null);
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = id,
                .tool_name = customToolName(self.tool_names, "file_search"),
                .result = .{ .object = result },
            } });
        } else if (std.mem.eql(u8, kind, "code_interpreter_call")) {
            _ = self.ongoing_tools.remove(output_index);
            const id = responses_api.optionalString(item, "id") orelse return;
            var result: std.json.ObjectMap = .empty;
            try result.put(self.arena, "outputs", try provider_utils.cloneJsonValue(self.arena, item.get("outputs") orelse .null));
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = id,
                .tool_name = customToolName(self.tool_names, "code_interpreter"),
                .result = .{ .object = result },
            } });
        } else if (std.mem.eql(u8, kind, "image_generation_call")) {
            const id = responses_api.optionalString(item, "id") orelse return;
            var result: std.json.ObjectMap = .empty;
            try putString(&result, self.arena, "result", responses_api.optionalString(item, "result") orelse "");
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = id,
                .tool_name = customToolName(self.tool_names, "image_generation"),
                .result = .{ .object = result },
            } });
        } else if (std.mem.eql(u8, kind, "tool_search_call")) {
            const ongoing = self.ongoing_tools.get(output_index) orelse return;
            const hosted = std.mem.eql(u8, responses_api.optionalString(item, "execution") orelse ongoing.tool_search_execution orelse "server", "server");
            const call_id = if (hosted) ongoing.tool_call_id else responses_api.optionalString(item, "call_id") orelse responses_api.optionalString(item, "id") orelse ongoing.tool_call_id;
            if (hosted) try self.hosted_tool_search_ids.append(self.arena, call_id) else try self.queue.append(self.arena, .{ .tool_input_start = .{ .id = call_id, .tool_name = ongoing.tool_name } });
            try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = call_id } });
            var input: std.json.ObjectMap = .empty;
            try input.put(self.arena, "arguments", try provider_utils.cloneJsonValue(self.arena, item.get("arguments") orelse .null));
            if (hosted) try input.put(self.arena, "call_id", .null) else try putString(&input, self.arena, "call_id", call_id);
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = call_id,
                .tool_name = ongoing.tool_name,
                .input = try provider_utils.stringifyJsonValueAlloc(self.arena, .{ .object = input }),
                .provider_executed = if (hosted) true else null,
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
            } });
            _ = self.ongoing_tools.remove(output_index);
        } else if (std.mem.eql(u8, kind, "tool_search_output")) {
            const call_id = responses_api.optionalString(item, "call_id") orelse if (self.hosted_tool_search_ids.items.len != 0) self.hosted_tool_search_ids.orderedRemove(0) else responses_api.optionalString(item, "id") orelse "";
            var result: std.json.ObjectMap = .empty;
            try result.put(self.arena, "tools", try provider_utils.cloneJsonValue(self.arena, item.get("tools") orelse .{ .array = .init(self.arena) }));
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = call_id,
                .tool_name = customToolName(self.tool_names, "tool_search"),
                .result = .{ .object = result },
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
            } });
        } else if (std.mem.eql(u8, kind, "mcp_call")) {
            _ = self.ongoing_tools.remove(output_index);
            try self.emitMcpCall(item);
        } else if (std.mem.eql(u8, kind, "mcp_list_tools")) {
            _ = self.ongoing_tools.remove(output_index);
        } else if (std.mem.eql(u8, kind, "mcp_approval_request")) {
            _ = self.ongoing_tools.remove(output_index);
            try self.emitMcpApproval(item);
        } else if (std.mem.eql(u8, kind, "local_shell_call")) {
            _ = self.ongoing_tools.remove(output_index);
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = call_id,
                .tool_name = customToolName(self.tool_names, "local_shell"),
                .input = try localShellInput(self.arena, item),
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
            } });
        } else if (std.mem.eql(u8, kind, "shell_call")) {
            _ = self.ongoing_tools.remove(output_index);
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = call_id,
                .tool_name = customToolName(self.tool_names, "shell"),
                .input = try shellInput(self.arena, item),
                .provider_executed = if (self.shell_provider_executed) true else null,
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
            } });
        } else if (std.mem.eql(u8, kind, "shell_call_output")) {
            const call_id = responses_api.optionalString(item, "call_id") orelse return;
            try self.queue.append(self.arena, .{ .tool_result = .{
                .tool_call_id = call_id,
                .tool_name = customToolName(self.tool_names, "shell"),
                .result = try shellResult(self.arena, item),
            } });
        } else if (std.mem.eql(u8, kind, "apply_patch_call")) {
            try self.finishApplyPatch(output_index, item);
        } else if (std.mem.eql(u8, kind, "reasoning")) {
            try self.finishReasoning(item);
        } else if (std.mem.eql(u8, kind, "compaction")) {
            try self.queue.append(self.arena, .{ .custom = .{
                .kind = "openai.compaction",
                .provider_metadata = try compactionMetadata(self.arena, self.metadata_key, item),
            } });
        }
    }

    fn emitMcpCall(self: *StreamState, item: std.json.ObjectMap) provider.NextError!void {
        const approval_id = responses_api.optionalString(item, "approval_request_id");
        const id = if (approval_id) |approval|
            self.approval_aliases_stream.get(approval) orelse self.approval_aliases_prompt.get(approval) orelse responses_api.optionalString(item, "id") orelse ""
        else
            responses_api.optionalString(item, "id") orelse "";
        const raw_name = responses_api.optionalString(item, "name") orelse "unknown";
        const name = try std.fmt.allocPrint(self.arena, "mcp.{s}", .{raw_name});
        const arguments = responses_api.optionalString(item, "arguments") orelse "{}";
        try self.queue.append(self.arena, .{ .tool_call = .{
            .tool_call_id = id,
            .tool_name = name,
            .input = arguments,
            .provider_executed = true,
            .dynamic = true,
        } });
        var result: std.json.ObjectMap = .empty;
        try putString(&result, self.arena, "type", "call");
        try putString(&result, self.arena, "serverLabel", responses_api.optionalString(item, "server_label") orelse "");
        try putString(&result, self.arena, "name", raw_name);
        try putString(&result, self.arena, "arguments", arguments);
        if (item.get("output")) |output| if (output != .null) try result.put(self.arena, "output", try provider_utils.cloneJsonValue(self.arena, output));
        if (item.get("error")) |error_value| if (error_value != .null) try result.put(self.arena, "error", try provider_utils.cloneJsonValue(self.arena, error_value));
        try self.queue.append(self.arena, .{ .tool_result = .{
            .tool_call_id = id,
            .tool_name = name,
            .result = .{ .object = result },
            .dynamic = true,
            .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
        } });
    }

    fn emitMcpApproval(self: *StreamState, item: std.json.ObjectMap) provider.NextError!void {
        const call_id = try self.id_generator.nextAlloc(self.arena);
        const approval_id = responses_api.optionalString(item, "approval_request_id") orelse responses_api.optionalString(item, "id") orelse "";
        try self.approval_aliases_stream.put(self.arena, approval_id, call_id);
        const name = try std.fmt.allocPrint(self.arena, "mcp.{s}", .{responses_api.optionalString(item, "name") orelse "unknown"});
        try self.queue.append(self.arena, .{ .tool_call = .{
            .tool_call_id = call_id,
            .tool_name = name,
            .input = responses_api.optionalString(item, "arguments") orelse "{}",
            .provider_executed = true,
            .dynamic = true,
        } });
        try self.queue.append(self.arena, .{ .tool_approval_request = .{
            .approval_id = approval_id,
            .tool_call_id = call_id,
        } });
    }

    fn finishApplyPatch(self: *StreamState, output_index: usize, item: std.json.ObjectMap) provider.NextError!void {
        const ongoing = self.ongoing_tools.getPtr(output_index) orelse return;
        if (ongoing.apply_patch) |*apply| {
            const operation = responses_api.objectField(item, "operation");
            const operation_type = if (operation) |value| responses_api.optionalString(value, "type") else null;
            if (!apply.end_emitted and !std.mem.eql(u8, operation_type orelse "", "delete_file")) {
                if (!apply.has_diff) if (operation) |value| if (responses_api.optionalString(value, "diff")) |diff| {
                    try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = ongoing.tool_call_id, .delta = try responses_api.escapeJsonDelta(self.arena, diff) } });
                };
                try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = ongoing.tool_call_id, .delta = "\"}}" } });
                try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = ongoing.tool_call_id } });
                apply.end_emitted = true;
            }
        }
        if (std.mem.eql(u8, responses_api.optionalString(item, "status") orelse "", "completed")) {
            try self.queue.append(self.arena, .{ .tool_call = .{
                .tool_call_id = ongoing.tool_call_id,
                .tool_name = ongoing.tool_name,
                .input = try applyPatchInput(self.arena, item),
                .provider_metadata = try itemMetadata(self.arena, self.metadata_key, item, false),
            } });
        }
        _ = self.ongoing_tools.remove(output_index);
    }

    fn finishReasoning(self: *StreamState, item: std.json.ObjectMap) provider.NextError!void {
        const id = responses_api.optionalString(item, "id") orelse return;
        const state = self.active_reasoning.getPtr(id) orelse return;
        const encrypted = try provider_utils.cloneJsonValue(self.arena, item.get("encrypted_content") orelse state.encrypted_content);
        var iterator = state.summary_parts.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .active or entry.value_ptr.* == .can_conclude) {
                try self.queue.append(self.arena, .{ .reasoning_end = .{
                    .id = try reasoningPartId(self.arena, id, entry.key_ptr.*),
                    .provider_metadata = try reasoningMetadata(self.arena, self.metadata_key, id, encrypted),
                } });
            }
        }
        if (self.active_reasoning.fetchRemove(id)) |removed| {
            var owned = removed.value;
            owned.deinit(self.arena);
        }
    }

    fn toolInputDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const ongoing = self.ongoing_tools.get(index) orelse return;
        const delta = responses_api.optionalString(root, "delta") orelse return;
        try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = ongoing.tool_call_id, .delta = delta } });
    }

    fn codeInterpreterDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const ongoing = self.ongoing_tools.get(index) orelse return;
        const delta = responses_api.optionalString(root, "delta") orelse return;
        try self.queue.append(self.arena, .{ .tool_input_delta = .{
            .id = ongoing.tool_call_id,
            .delta = try responses_api.escapeJsonDelta(self.arena, delta),
        } });
    }

    fn codeInterpreterDone(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const ongoing = self.ongoing_tools.get(index) orelse return;
        try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = ongoing.tool_call_id, .delta = "\"}" } });
        try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = ongoing.tool_call_id } });
        var input: std.json.ObjectMap = .empty;
        try putString(&input, self.arena, "code", responses_api.optionalString(root, "code") orelse "");
        try putString(&input, self.arena, "containerId", ongoing.code_container_id orelse "");
        try self.queue.append(self.arena, .{ .tool_call = .{
            .tool_call_id = ongoing.tool_call_id,
            .tool_name = ongoing.tool_name,
            .input = try provider_utils.stringifyJsonValueAlloc(self.arena, .{ .object = input }),
            .provider_executed = true,
        } });
    }

    fn applyPatchDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const ongoing = self.ongoing_tools.getPtr(index) orelse return;
        if (ongoing.apply_patch == null) return;
        const delta = responses_api.optionalString(root, "delta") orelse return;
        try self.queue.append(self.arena, .{ .tool_input_delta = .{
            .id = ongoing.tool_call_id,
            .delta = try responses_api.escapeJsonDelta(self.arena, delta),
        } });
        ongoing.apply_patch.?.has_diff = true;
    }

    fn applyPatchDone(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = responses_api.optionalIndex(root.get("output_index")) orelse return;
        const ongoing = self.ongoing_tools.getPtr(index) orelse return;
        if (ongoing.apply_patch == null or ongoing.apply_patch.?.end_emitted) return;
        if (!ongoing.apply_patch.?.has_diff) {
            const diff = responses_api.optionalString(root, "diff") orelse "";
            try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = ongoing.tool_call_id, .delta = try responses_api.escapeJsonDelta(self.arena, diff) } });
            ongoing.apply_patch.?.has_diff = true;
        }
        try self.queue.append(self.arena, .{ .tool_input_delta = .{ .id = ongoing.tool_call_id, .delta = "\"}}" } });
        try self.queue.append(self.arena, .{ .tool_input_end = .{ .id = ongoing.tool_call_id } });
        ongoing.apply_patch.?.end_emitted = true;
    }

    fn imagePartial(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const id = responses_api.optionalString(root, "item_id") orelse return;
        var result: std.json.ObjectMap = .empty;
        try putString(&result, self.arena, "result", responses_api.optionalString(root, "partial_image_b64") orelse "");
        try self.queue.append(self.arena, .{ .tool_result = .{
            .tool_call_id = id,
            .tool_name = customToolName(self.tool_names, "image_generation"),
            .result = .{ .object = result },
            .preliminary = true,
        } });
    }

    fn outputTextDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const id = responses_api.optionalString(root, "item_id") orelse return;
        const delta = responses_api.optionalString(root, "delta") orelse return;
        try self.queue.append(self.arena, .{ .text_delta = .{ .id = id, .delta = delta } });
        if (self.capture_logprobs) if (root.get("logprobs")) |value| if (value == .array and value.array.items.len != 0) {
            try self.logprobs.append(try sanitizeLogprobs(self.arena, value));
        };
    }

    fn annotationAdded(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const annotation = root.get("annotation") orelse return;
        try self.annotations.append(self.arena, try provider_utils.cloneJsonValue(self.arena, annotation));
        const source = try annotationSource(self.arena, annotation, &self.id_generator, self.metadata_key) orelse return;
        try self.queue.append(self.arena, .{ .source = source });
    }

    fn reasoningPartAdded(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const item_id = responses_api.optionalString(root, "item_id") orelse return;
        const summary_index = responses_api.optionalIndex(root.get("summary_index")) orelse return;
        if (summary_index == 0) return;
        const state = self.active_reasoning.getPtr(item_id) orelse return;
        try state.summary_parts.put(self.arena, summary_index, .active);
        var iterator = state.summary_parts.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.* == .can_conclude) {
            try self.queue.append(self.arena, .{ .reasoning_end = .{
                .id = try reasoningPartId(self.arena, item_id, entry.key_ptr.*),
                .provider_metadata = try reasoningItemOnlyMetadata(self.arena, self.metadata_key, item_id),
            } });
            entry.value_ptr.* = .concluded;
        };
        try self.queue.append(self.arena, .{ .reasoning_start = .{
            .id = try reasoningPartId(self.arena, item_id, summary_index),
            .provider_metadata = try reasoningMetadata(self.arena, self.metadata_key, item_id, state.encrypted_content),
        } });
    }

    fn reasoningTextDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const item_id = responses_api.optionalString(root, "item_id") orelse return;
        const summary_index = responses_api.optionalIndex(root.get("summary_index")) orelse return;
        const delta = responses_api.optionalString(root, "delta") orelse return;
        try self.queue.append(self.arena, .{ .reasoning_delta = .{
            .id = try reasoningPartId(self.arena, item_id, summary_index),
            .delta = delta,
            .provider_metadata = try reasoningItemOnlyMetadata(self.arena, self.metadata_key, item_id),
        } });
    }

    fn reasoningPartDone(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const item_id = responses_api.optionalString(root, "item_id") orelse return;
        const summary_index = responses_api.optionalIndex(root.get("summary_index")) orelse return;
        const state = self.active_reasoning.getPtr(item_id) orelse return;
        if (self.store) {
            try self.queue.append(self.arena, .{ .reasoning_end = .{
                .id = try reasoningPartId(self.arena, item_id, summary_index),
                .provider_metadata = try reasoningItemOnlyMetadata(self.arena, self.metadata_key, item_id),
            } });
            try state.summary_parts.put(self.arena, summary_index, .concluded);
        } else try state.summary_parts.put(self.arena, summary_index, .can_conclude);
    }

    fn responseFinished(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const response = responses_api.objectField(root, "response") orelse return;
        const incomplete = responses_api.objectField(response, "incomplete_details");
        const raw = if (incomplete) |details| responses_api.optionalString(details, "reason") else null;
        self.finish_reason = .{ .unified = responses_api.mapFinishReason(raw, self.has_function_call), .raw = raw };
        if (response.get("usage")) |value| self.usage = try provider_utils.cloneJsonValue(self.arena, value);
        self.service_tier = responses_api.optionalString(response, "service_tier");
        self.reasoning_context = reasoningContext(response);
    }

    fn responseFailed(self: *StreamState, root: std.json.ObjectMap, raw_value: std.json.Value) provider.NextError!void {
        const response = responses_api.objectField(root, "response") orelse return;
        const incomplete = responses_api.objectField(response, "incomplete_details");
        const raw = if (incomplete) |details| responses_api.optionalString(details, "reason") else null;
        self.finish_reason = if (raw) |reason| .{
            .unified = responses_api.mapFinishReason(reason, self.has_function_call),
            .raw = reason,
        } else .{ .unified = .@"error", .raw = "error" };
        if (response.get("usage")) |value| {
            if (value != .null) self.usage = try provider_utils.cloneJsonValue(self.arena, value);
        }
        self.service_tier = responses_api.optionalString(response, "service_tier");
        self.reasoning_context = reasoningContext(response);
        if (!self.encountered_error and response.get("error") != null and response.get("error").? != .null) {
            self.encountered_error = true;
            try self.queue.append(self.arena, .{ .err = .{ .error_value = try provider_utils.cloneJsonValue(self.arena, raw_value) } });
        }
    }

    fn flush(self: *StreamState) provider.NextError!void {
        if (self.flushed) return;
        try self.queue.append(self.arena, .{ .finish = .{
            .finish_reason = self.finish_reason,
            .usage = try responses_api.convertUsage(self.arena, self.usage),
            .provider_metadata = try responseMetadata(
                self.arena,
                self.metadata_key,
                self.response_id,
                self.logprobs,
                self.service_tier,
                self.reasoning_context,
            ),
        } });
        self.flushed = true;
        self.ended = true;
    }
};

fn isOutputEvent(value: std.json.Value) bool {
    const event_type = responses_api.eventType(value) orelse return false;
    return !(std.mem.eql(u8, event_type, "response.created") or
        std.mem.eql(u8, event_type, "response.failed") or
        std.mem.eql(u8, event_type, "error") or
        std.mem.eql(u8, event_type, "response.in_progress") or
        isUnknownLifecycleEvent(event_type));
}

fn isEarlyErrorEvent(value: std.json.Value) bool {
    if (value != .object) return false;
    const event_type = responses_api.optionalString(value.object, "type") orelse return false;
    if (std.mem.eql(u8, event_type, "error")) return true;
    if (!std.mem.eql(u8, event_type, "response.failed")) return false;
    const response = responses_api.objectField(value.object, "response") orelse return false;
    const error_value = response.get("error") orelse return false;
    return error_value != .null;
}

fn isUnknownLifecycleEvent(event_type: []const u8) bool {
    if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) return false;
    const known = [_][]const u8{
        "response.output_item.added",
        "response.output_item.done",
        "response.function_call_arguments.delta",
        "response.custom_tool_call_input.delta",
        "response.code_interpreter_call_code.delta",
        "response.code_interpreter_call_code.done",
        "response.apply_patch_call_operation_diff.delta",
        "response.apply_patch_call_operation_diff.done",
        "response.image_generation_call.partial_image",
        "response.output_text.delta",
        "response.output_text.annotation.added",
        "response.reasoning_summary_part.added",
        "response.reasoning_summary_text.delta",
        "response.reasoning_summary_part.done",
    };
    for (known) |candidate| if (std.mem.eql(u8, event_type, candidate)) return false;
    return true;
}

fn namespaceOnlyMetadata(arena: Allocator, key: []const u8, namespace: []const u8) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "namespace", namespace);
    return namespacedMetadata(arena, key, details);
}

fn reasoningItemOnlyMetadata(arena: Allocator, key: []const u8, item_id: []const u8) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "itemId", item_id);
    return namespacedMetadata(arena, key, details);
}

fn reasoningPartId(arena: Allocator, item_id: []const u8, summary_index: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{d}", .{ item_id, summary_index });
}

fn addInclude(arena: Allocator, include: *std.ArrayList([]const u8), value: []const u8) Allocator.Error!void {
    for (include.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try include.append(arena, value);
}

fn buildToolNames(arena: Allocator, tools: ?[]const provider.Tool) Allocator.Error![]const ToolName {
    const input = tools orelse return &.{};
    var output: std.ArrayList(ToolName) = .empty;
    defer output.deinit(arena);
    for (input) |tool| switch (tool) {
        .function => {},
        .provider => |item| try output.append(arena, .{
            .provider_name = try arena.dupe(u8, responses_tools.toProviderToolName(input, item.name)),
            .custom_name = try arena.dupe(u8, item.name),
        }),
    };
    return output.toOwnedSlice(arena);
}

fn customToolName(names: []const ToolName, provider_name: []const u8) []const u8 {
    for (names) |name| if (std.mem.eql(u8, name.provider_name, provider_name)) return name.custom_name;
    return provider_name;
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

fn unsupportedWarning(feature: []const u8, details: []const u8) provider.Warning {
    return .{ .unsupported = .{ .feature = feature, .details = details } };
}

fn copySnakeToCamel(arena: Allocator, destination: *std.json.ObjectMap, source: std.json.ObjectMap, snake: []const u8, camel: []const u8) Allocator.Error!void {
    if (source.get(snake)) |value| if (value != .null) try destination.put(arena, camel, try provider_utils.cloneJsonValue(arena, value));
}

fn dupeOptional(arena: Allocator, value: ?[]const u8, fallback: []const u8) Allocator.Error![]const u8 {
    return arena.dupe(u8, value orelse fallback);
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

fn requireObject(value: std.json.Value, arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error!std.json.ObjectMap {
    return if (value == .object) value.object else invalidResponse(arena, diag, message);
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

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn testConfig(base_url: []const u8, transport: provider_utils.HttpTransport) config_api.Config {
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

test "OpenAI Responses request assembly covers input tools includes structured text and reasoning controls" {
    // Request fixtures are ported from openai-responses-language-model.test.ts
    // doGenerate option/body cases and openai-responses-prepare-tools.test.ts.
    const Dummy = struct {
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
    var marker: u8 = 0;
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var model = try ResponsesLanguageModel.init("gpt-5.1", testConfig("https://example.test/v1", transport), null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"store\":false,\"logprobs\":5,\"parallelToolCalls\":false,\"maxToolCalls\":3,\"reasoningEffort\":\"none\",\"reasoningSummary\":\"auto\",\"textVerbosity\":\"low\",\"previousResponseId\":\"resp_prev\",\"promptCacheKey\":\"cache-key\",\"truncation\":\"auto\",\"contextManagement\":[{\"type\":\"compaction\",\"compactThreshold\":4096}]}}", .{});
    const web_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const tools = [_]provider.Tool{
        .{ .function = .{ .name = "weather", .input_schema = .{ .object = schema }, .strict = true } },
        .{ .provider = .{ .id = "openai.web_search", .name = "webSearch", .args = web_args } },
    };
    const prompt = [_]provider.Message{
        .{ .system = .{ .content = "Be concise." } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } },
    };
    const prepared = try model.prepareRequest(arena, &.{
        .prompt = &prompt,
        .temperature = 0.4,
        .top_p = 0.9,
        .max_output_tokens = 64,
        .tools = &tools,
        .tool_choice = .{ .tool = .{ .tool_name = "webSearch" } },
        .response_format = .{ .json = .{ .schema = .{ .object = schema }, .name = "answer" } },
        .provider_options = provider_options,
    }, false, null);
    const body = prepared.body.object;
    try std.testing.expectEqualStrings("gpt-5.1", body.get("model").?.string);
    try std.testing.expectApproxEqAbs(0.4, body.get("temperature").?.float, 0.0001);
    try std.testing.expectEqualStrings("developer", body.get("input").?.array.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("json_schema", body.get("text").?.object.get("format").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("web_search", body.get("tool_choice").?.object.get("type").?.string);
    try std.testing.expectEqual(3, body.get("include").?.array.items.len);
    try std.testing.expectEqual(5, body.get("top_logprobs").?.integer);
    try std.testing.expectEqualStrings("none", body.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", body.get("reasoning").?.object.get("summary").?.string);
    try std.testing.expectEqual(4096, body.get("context_management").?.array.items[0].object.get("compact_threshold").?.integer);

    const null_summary_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"reasoningEffort\":\"low\",\"reasoningSummary\":null}}", .{});
    const null_summary = try model.prepareRequest(arena, &.{
        .prompt = &prompt,
        .provider_options = null_summary_options,
    }, false, null);
    try std.testing.expect(null_summary.body.object.get("reasoning").?.object.get("summary") == null);
}

test "OpenAI Responses doGenerate maps messages annotations reasoning functions hosted pairs and usage" {
    // Response fixture shape is ported from
    // openai-responses-language-model.test.ts doGenerate cases.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"resp_generate","created_at":1741269019,"model":"gpt-4o-mini","service_tier":"default","reasoning":{"context":"all_turns"},"output":[{"type":"reasoning","id":"rs_1","encrypted_content":"enc_1","summary":[{"type":"summary_text","text":"checking"}]},{"type":"message","role":"assistant","id":"msg_1","phase":"final_answer","content":[{"type":"output_text","text":"Sunny.","logprobs":[{"bytes":[83],"token":"Sunny","logprob":-0.1,"top_logprobs":[]}],"annotations":[{"type":"url_citation","start_index":0,"end_index":6,"url":"https://example.test/weather","title":"Weather"},{"type":"file_citation","file_id":"file_1","filename":"report.txt","index":2}]}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"weather","arguments":"{\"city\":\"Paris\"}"},{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"Paris weather","sources":[{"type":"url","url":"https://example.test/source"}]}}],"incomplete_details":null,"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":40,"cache_write_tokens":10},"output_tokens":20,"output_tokens_details":{"reasoning_tokens":5}}}
        },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-4o-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"logprobs\":true}}", .{});
    const web_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const tools = [_]provider.Tool{.{ .provider = .{ .id = "openai.web_search", .name = "webSearch", .args = web_args } }};
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "weather" } }} } }};
    const result = try model.languageModel().doGenerate(io, arena, &.{ .prompt = &prompt, .tools = &tools, .provider_options = provider_options }, null);
    try std.testing.expectEqual(.tool_calls, result.finish_reason.unified);
    try std.testing.expectEqual(100, result.usage.input_tokens.total.?);
    try std.testing.expectEqual(50, result.usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(15, result.usage.output_tokens.text.?);
    var text_count: usize = 0;
    var source_count: usize = 0;
    var tool_call_count: usize = 0;
    var tool_result_count: usize = 0;
    var reasoning_count: usize = 0;
    for (result.content) |part| switch (part) {
        .text => text_count += 1,
        .source => source_count += 1,
        .tool_call => tool_call_count += 1,
        .tool_result => tool_result_count += 1,
        .reasoning => reasoning_count += 1,
        else => {},
    };
    try std.testing.expectEqual(1, text_count);
    try std.testing.expectEqual(2, source_count);
    try std.testing.expectEqual(2, tool_call_count);
    try std.testing.expectEqual(1, tool_result_count);
    try std.testing.expectEqual(1, reasoning_count);
    const metadata = result.provider_metadata.?.object.get("openai").?.object;
    try std.testing.expectEqualStrings("resp_generate", metadata.get("responseId").?.string);
    try std.testing.expectEqualStrings("all_turns", metadata.get("reasoningContext").?.string);
    try std.testing.expectEqual(1, metadata.get("logprobs").?.array.items.len);
    try std.testing.expect(metadata.get("logprobs").?.array.items[0].array.items[0].object.get("bytes") == null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI Responses stream preserves reasoning lifecycles and byte-exact code interpreter input" {
    // Event sequence is a compact verbatim-shape port of the reasoning and
    // code-interpreter fixtures in openai-responses-language-model.test.ts.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data =
            \\{"type":"response.created","response":{"id":"resp_stream","created_at":1741269019,"model":"gpt-5-mini"}}
            },
            .{ .data =
            \\{"type":"response.future.lifecycle","sequence_number":1}
            },
            .{ .data =
            \\{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"enc_start"}}
            },
            .{ .data =
            \\{"type":"response.reasoning_summary_part.added","item_id":"rs_1","summary_index":0}
            },
            .{ .data =
            \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"first"}
            },
            .{ .data =
            \\{"type":"response.reasoning_summary_part.done","item_id":"rs_1","summary_index":0}
            },
            .{ .data =
            \\{"type":"response.reasoning_summary_part.added","item_id":"rs_1","summary_index":1}
            },
            .{ .data =
            \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,"delta":"second"}
            },
            .{ .data =
            \\{"type":"response.reasoning_summary_part.done","item_id":"rs_1","summary_index":1}
            },
            .{ .data =
            \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"enc_final","summary":[]}}
            },
            .{ .data =
            \\{"type":"response.output_item.added","output_index":1,"item":{"id":"ci_1","type":"code_interpreter_call","container_id":"cntr_1","code":"","outputs":[],"status":"in_progress"}}
            },
            .{ .data =
            \\{"type":"response.code_interpreter_call_code.delta","output_index":1,"item_id":"ci_1","delta":"print(\"x\")\n"}
            },
            .{ .data =
            \\{"type":"response.code_interpreter_call_code.done","output_index":1,"item_id":"ci_1","code":"print(\"x\")\n"}
            },
            .{ .data =
            \\{"type":"response.output_item.done","output_index":1,"item":{"id":"ci_1","type":"code_interpreter_call","container_id":"cntr_1","code":"print(\"x\")\n","outputs":[{"type":"logs","logs":"x"}]}}
            },
            .{ .data =
            \\{"type":"response.output_item.added","output_index":2,"item":{"id":"msg_1","type":"message","phase":"final_answer"}}
            },
            .{ .data =
            \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"done","logprobs":[{"token":"done","logprob":-0.1,"top_logprobs":[]}]}
            },
            .{ .data =
            \\{"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","start_index":0,"end_index":4,"url":"https://example.test","title":"Example"}}
            },
            .{ .data =
            \\{"type":"response.output_item.done","output_index":2,"item":{"id":"msg_1","type":"message","phase":"final_answer"}}
            },
            .{ .data =
            \\{"type":"response.completed","response":{"incomplete_details":null,"service_tier":"default","reasoning":{"context":"current_turn"},"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":2},"output_tokens":6,"output_tokens_details":{"reasoning_tokens":2}}}}
            },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-5-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"store\":false,\"logprobs\":true}}", .{});
    const tool_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const tools = [_]provider.Tool{.{ .provider = .{ .id = "openai.code_interpreter", .name = "codeExecution", .args = tool_args } }};
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "run" } }} } }};
    const stream_result = try model.languageModel().doStream(io, arena, &.{ .prompt = &prompt, .tools = &tools, .provider_options = provider_options }, null);
    defer stream_result.stream.deinit(io);

    var accumulated_input: std.ArrayList(u8) = .empty;
    defer accumulated_input.deinit(allocator);
    var reasoning_starts: usize = 0;
    var reasoning_ends: usize = 0;
    var source_count: usize = 0;
    var error_count: usize = 0;
    var saw_finish = false;
    var finish_metadata: ?provider.ProviderMetadata = null;
    while (try stream_result.stream.next(io)) |part| switch (part) {
        .tool_input_delta => |delta| if (std.mem.eql(u8, delta.id, "ci_1")) try accumulated_input.appendSlice(allocator, delta.delta),
        .reasoning_start => |start| {
            reasoning_starts += 1;
            try std.testing.expect(std.mem.startsWith(u8, start.id, "rs_1:"));
        },
        .reasoning_end => |end| {
            reasoning_ends += 1;
            try std.testing.expect(std.mem.startsWith(u8, end.id, "rs_1:"));
        },
        .source => source_count += 1,
        .err => error_count += 1,
        .finish => |finish| {
            saw_finish = true;
            finish_metadata = finish.provider_metadata;
            try std.testing.expectEqual(.stop, finish.finish_reason.unified);
            try std.testing.expectEqual(10, finish.usage.input_tokens.total.?);
        },
        else => {},
    };
    try std.testing.expectEqualStrings("{\"containerId\":\"cntr_1\",\"code\":\"print(\\\"x\\\")\\n\"}", accumulated_input.items);
    try std.testing.expectEqual(2, reasoning_starts);
    try std.testing.expectEqual(2, reasoning_ends);
    try std.testing.expectEqual(1, source_count);
    try std.testing.expectEqual(0, error_count);
    try std.testing.expect(saw_finish);
    const metadata = finish_metadata.?.object.get("openai").?.object;
    try std.testing.expectEqualStrings("resp_stream", metadata.get("responseId").?.string);
    try std.testing.expectEqualStrings("current_turn", metadata.get("reasoningContext").?.string);
    try std.testing.expectEqual(1, metadata.get("logprobs").?.array.items.len);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI Responses stream maps function deltas web-search immediacy and image partial results" {
    // Compact fixture ported from the upstream function-call, web-search, and
    // image-generation streaming tests.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data =
            \\{"type":"response.created","response":{"id":"resp_tools","created_at":1741269019,"model":"gpt-4o-mini"}}
            },
            .{ .data =
            \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"weather","arguments":""}}
            },
            .{ .data =
            \\{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\"city\":"}
            },
            .{ .data =
            \\{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"\"Paris\"}"}
            },
            .{ .data =
            \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}}
            },
            .{ .data =
            \\{"type":"response.output_item.added","output_index":1,"item":{"id":"ws_1","type":"web_search_call","status":"in_progress"}}
            },
            .{ .data =
            \\{"type":"response.output_item.done","output_index":1,"item":{"id":"ws_1","type":"web_search_call","status":"completed","action":{"type":"search","query":"Paris weather"}}}
            },
            .{ .data =
            \\{"type":"response.output_item.added","output_index":2,"item":{"id":"ig_1","type":"image_generation_call"}}
            },
            .{ .data =
            \\{"type":"response.image_generation_call.partial_image","output_index":2,"item_id":"ig_1","partial_image_b64":"partial-image"}
            },
            .{ .data =
            \\{"type":"response.output_item.done","output_index":2,"item":{"id":"ig_1","type":"image_generation_call","result":"final-image"}}
            },
            .{ .data =
            \\{"type":"response.completed","response":{"incomplete_details":null,"usage":{"input_tokens":4,"output_tokens":3}}}
            },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-4o-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const empty_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const tools = [_]provider.Tool{
        .{ .function = .{ .name = "weather", .input_schema = .{ .object = schema } } },
        .{ .provider = .{ .id = "openai.web_search", .name = "webSearch", .args = empty_args } },
        .{ .provider = .{ .id = "openai.image_generation", .name = "generateImage", .args = empty_args } },
    };
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "use tools" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena, &.{ .prompt = &prompt, .tools = &tools }, null);
    defer streamed.stream.deinit(io);
    var function_delta = std.ArrayList(u8).empty;
    defer function_delta.deinit(allocator);
    var web_calls: usize = 0;
    var web_results: usize = 0;
    var preliminary_images: usize = 0;
    var final_images: usize = 0;
    var saw_function_end = false;
    var finish_reason: ?provider.FinishReasonUnified = null;
    while (try streamed.stream.next(io)) |part| switch (part) {
        .tool_input_delta => |delta| if (std.mem.eql(u8, delta.id, "call_1")) try function_delta.appendSlice(allocator, delta.delta),
        .tool_input_end => |end| if (std.mem.eql(u8, end.id, "call_1")) {
            saw_function_end = true;
        },
        .tool_call => |call| {
            if (std.mem.eql(u8, call.tool_name, "webSearch")) web_calls += 1;
        },
        .tool_result => |result| {
            if (std.mem.eql(u8, result.tool_name, "webSearch")) web_results += 1;
            if (std.mem.eql(u8, result.tool_name, "generateImage")) {
                if (result.preliminary orelse false) preliminary_images += 1 else final_images += 1;
            }
        },
        .finish => |finish| finish_reason = finish.finish_reason.unified,
        else => {},
    };
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", function_delta.items);
    try std.testing.expect(saw_function_end);
    try std.testing.expectEqual(1, web_calls);
    try std.testing.expectEqual(1, web_results);
    try std.testing.expectEqual(1, preliminary_images);
    try std.testing.expectEqual(1, final_images);
    try std.testing.expectEqual(.tool_calls, finish_reason.?);
}

test "OpenAI Responses store-true reasoning concludes each summary at part.done" {
    // Multi-summary store=true sequence ported from the upstream reasoning
    // summary lifecycle test.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_reasoning\",\"created_at\":1,\"model\":\"o3-mini\"}}" },
            .{ .data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_store\",\"type\":\"reasoning\"}}" },
            .{ .data = "{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_store\",\"summary_index\":0}" },
            .{ .data = "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_store\",\"summary_index\":0,\"delta\":\"one\"}" },
            .{ .data = "{\"type\":\"response.reasoning_summary_part.done\",\"item_id\":\"rs_store\",\"summary_index\":0}" },
            .{ .data = "{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_store\",\"summary_index\":1}" },
            .{ .data = "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_store\",\"summary_index\":1,\"delta\":\"two\"}" },
            .{ .data = "{\"type\":\"response.reasoning_summary_part.done\",\"item_id\":\"rs_store\",\"summary_index\":1}" },
            .{ .data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_store\",\"type\":\"reasoning\",\"summary\":[]}}" },
            .{ .data = "{\"type\":\"response.completed\",\"response\":{\"incomplete_details\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"output_tokens_details\":{\"reasoning_tokens\":2}}}}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("o3-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"store\":true}}", .{});
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "think" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena, &.{ .prompt = &prompt, .provider_options = provider_options }, null);
    defer streamed.stream.deinit(io);
    var starts: usize = 0;
    var ends: usize = 0;
    while (try streamed.stream.next(io)) |part| switch (part) {
        .reasoning_start => starts += 1,
        .reasoning_end => |end| {
            ends += 1;
            const details = end.provider_metadata.?.object.get("openai").?.object;
            try std.testing.expect(details.get("reasoningEncryptedContent") == null);
        },
        else => {},
    };
    try std.testing.expectEqual(2, starts);
    try std.testing.expectEqual(2, ends);
}

test "OpenAI Responses late response.failed emits an error part and error finish" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_failed\",\"created_at\":1,\"model\":\"gpt-4o-mini\"}}" },
            .{ .data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_failed\",\"type\":\"message\"}}" },
            .{ .data = "{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_failed\",\"delta\":\"partial\"}" },
            .{ .data = "{\"type\":\"response.failed\",\"sequence_number\":4,\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"failed\"},\"incomplete_details\":null,\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-4o-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "fail" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena_state.allocator(), &.{ .prompt = &prompt }, null);
    defer streamed.stream.deinit(io);
    var errors: usize = 0;
    var finish: ?provider.FinishReasonUnified = null;
    while (try streamed.stream.next(io)) |part| switch (part) {
        .err => errors += 1,
        .finish => |value| finish = value.finish_reason.unified,
        else => {},
    };
    try std.testing.expectEqual(1, errors);
    try std.testing.expectEqual(.@"error", finish.?);
}

test "OpenAI Responses detects Chat Completions stream shape with actionable APICallError" {
    // Verbatim Chat-Completions-shaped fixture from the upstream mismatch test.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{.{ .data = "{\"choices\":[],\"created\":0,\"id\":\"\",\"model\":\"\",\"object\":\"\",\"prompt_filter_results\":[]}" }} },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-4o-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena_state.allocator(), &.{ .prompt = &prompt }, null);
    defer streamed.stream.deinit(io);
    var message: ?[]const u8 = null;
    while (try streamed.stream.next(io)) |part| switch (part) {
        .err => |error_part| if (error_part.error_value == .object) {
            message = responses_api.optionalString(error_part.error_value.object, "message");
        },
        else => {},
    };
    try std.testing.expect(message != null);
    try std.testing.expect(std.mem.indexOf(u8, message.?, "use openai.chat('model-id')") != null);
}

test "OpenAI Responses rejects an API error frame before output starts" {
    // Early insufficient-quota shape captured by openai-responses-api.ts and
    // ported from the upstream early stream error test.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{.{ .data = "{\"type\":\"error\",\"sequence_number\":0,\"error\":{\"type\":\"insufficient_quota\",\"code\":\"insufficient_quota\",\"message\":\"quota exhausted\",\"param\":null}}" }} },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-4o-mini", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.APICallError, model.languageModel().doStream(io, arena_state.allocator(), &.{ .prompt = &prompt }, &diagnostics));
    try std.testing.expectEqual(429, diagnostics.payload.api_call.status_code.?);
    try std.testing.expectEqualStrings("quota exhausted", diagnostics.payload.api_call.message);
}

test "OpenAI Responses apply_patch diff deltas assemble byte-exact JSON" {
    // Synthetic delta fixture mirrors openai-apply-patch-tool.1.chunks.txt and
    // asserts the same JSON.stringify-without-quotes escaping contract.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_support = @import("test_support");
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_patch\",\"created_at\":1,\"model\":\"gpt-5-codex\"}}" },
            .{ .data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"ap_1\",\"type\":\"apply_patch_call\",\"call_id\":\"call_patch\",\"status\":\"in_progress\",\"operation\":{\"type\":\"create_file\",\"path\":\"a\\\"b\",\"diff\":\"\"}}}" },
            .{ .data = "{\"type\":\"response.apply_patch_call_operation_diff.delta\",\"output_index\":0,\"item_id\":\"ap_1\",\"delta\":\"line\\n\\\"x\\\"\"}" },
            .{ .data = "{\"type\":\"response.apply_patch_call_operation_diff.done\",\"output_index\":0,\"item_id\":\"ap_1\",\"diff\":\"line\\n\\\"x\\\"\"}" },
            .{ .data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"ap_1\",\"type\":\"apply_patch_call\",\"call_id\":\"call_patch\",\"status\":\"completed\",\"operation\":{\"type\":\"create_file\",\"path\":\"a\\\"b\",\"diff\":\"line\\n\\\"x\\\"\"}}}" },
            .{ .data = "{\"type\":\"response.completed\",\"response\":{\"incomplete_details\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ResponsesLanguageModel.init("gpt-5-codex", testConfig(server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const tools = [_]provider.Tool{.{ .provider = .{ .id = "openai.apply_patch", .name = "applyPatch", .args = empty } }};
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "patch" } }} } }};
    const streamed = try model.languageModel().doStream(io, arena, &.{ .prompt = &prompt, .tools = &tools }, null);
    defer streamed.stream.deinit(io);
    var assembled = std.ArrayList(u8).empty;
    defer assembled.deinit(allocator);
    while (try streamed.stream.next(io)) |part| switch (part) {
        .tool_input_delta => |delta| if (std.mem.eql(u8, delta.id, "call_patch")) try assembled.appendSlice(allocator, delta.delta),
        else => {},
    };
    try std.testing.expectEqualStrings("{\"callId\":\"call_patch\",\"operation\":{\"type\":\"create_file\",\"path\":\"a\\\"b\",\"diff\":\"line\\n\\\"x\\\"\"}}", assembled.items);
}
