const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const capabilities_api = @import("capabilities.zig");
const config_api = @import("config.zig");
const options_api = @import("options.zig");
const prompt_api = @import("prompt.zig");
const tools_api = @import("tools.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const BuildError = provider.Error || Allocator.Error;

const ToolName = struct {
    wire: []const u8,
    custom: []const u8,
};

pub const PreparedRequest = struct {
    body: std.json.Value,
    warnings: []const provider.Warning,
    betas: utils.BetaSet,
    uses_json_response_tool: bool,
    provider_options_name: []const u8,
    used_custom_provider_key: bool,
    tool_names: []const ToolName,
};

pub const AnthropicLanguageModel = struct {
    model_id: []const u8,
    config: config_api.Config,

    pub fn languageModel(self: *AnthropicLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn model(self: *AnthropicLanguageModel) provider.LanguageModel {
        return self.languageModel();
    }

    pub fn prepareRequest(
        self: *AnthropicLanguageModel,
        allocator: Allocator,
        call_options: *const provider.CallOptions,
        stream: bool,
        diag: ?*provider.Diagnostics,
    ) BuildError!PreparedRequest {
        return self.buildArgs(
            allocator,
            call_options,
            stream,
            self.config.headers.resolve(),
            diag,
        );
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .urlIsSupported = vUrlIsSupported,
        .doGenerate = vDoGenerate,
        .doStream = vDoStream,
    };

    fn fromRaw(raw: *anyopaque) *AnthropicLanguageModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        return fromRaw(raw).config.provider;
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vUrlIsSupported(_: *anyopaque, media_type: []const u8, url: []const u8) bool {
        return std.mem.startsWith(u8, url, "https://") and
            (std.mem.startsWith(u8, media_type, "image/") or
                std.mem.eql(u8, media_type, "application/pdf"));
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        allocator: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return fromRaw(raw).doGenerate(io, allocator, call_options, diag);
    }

    fn vDoStream(
        raw: *anyopaque,
        io: std.Io,
        allocator: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return fromRaw(raw).doStream(io, allocator, call_options, diag);
    }

    fn doGenerate(
        self: *AnthropicLanguageModel,
        io: std.Io,
        allocator: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const configured_headers = self.config.headers.resolve();
        const prepared = try self.buildArgs(allocator, call_options, false, configured_headers, diag);
        const headers = try self.resolveHeaders(
            allocator,
            configured_headers,
            call_options.headers,
            &prepared.betas,
            diag,
        );
        const body_json = try provider_utils.stringifyJsonValueAlloc(allocator, prepared.body);
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.config.base_url});
        const ErrorShape = struct {
            type: ?[]const u8 = null,
            @"error": struct { type: []const u8, message: []const u8 },
        };
        const Callbacks = struct {
            fn message(value: ErrorShape) []const u8 {
                return value.@"error".message;
            }
        };
        const result = try provider_utils.postJsonToApi(
            std.json.Value,
            io,
            allocator,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = provider_utils.jsonErrorResponseHandler(ErrorShape, Callbacks.message),
            },
            diag,
        );
        return mapGenerateResponse(
            io,
            allocator,
            prepared,
            result.value,
            result.response_headers,
            diag,
        );
    }

    fn doStream(
        self: *AnthropicLanguageModel,
        io: std.Io,
        allocator: Allocator,
        call_options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const configured_headers = self.config.headers.resolve();
        const prepared = try self.buildArgs(allocator, call_options, true, configured_headers, diag);
        const headers = try self.resolveHeaders(
            allocator,
            configured_headers,
            call_options.headers,
            &prepared.betas,
            diag,
        );
        const body_json = try provider_utils.stringifyJsonValueAlloc(allocator, prepared.body);
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.config.base_url});
        const ErrorShape = struct {
            type: ?[]const u8 = null,
            @"error": struct { type: []const u8, message: []const u8 },
        };
        const Callbacks = struct {
            fn message(value: ErrorShape) []const u8 {
                return value.@"error".message;
            }
        };
        const Stream = provider_utils.JsonEventStream(std.json.Value);
        const result = try provider_utils.postJsonToApi(
            Stream,
            io,
            allocator,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.eventSourceResponseHandler(std.json.Value),
                .failure = provider_utils.jsonErrorResponseHandler(ErrorShape, Callbacks.message),
            },
            diag,
        );

        // The caller-supplied doStream arena owns the event stream, mapper,
        // block registry, replay queue, and every returned slice. The
        // PartStream must be deinitialized before that arena is released.
        const state = try allocator.create(StreamState);
        state.* = .{
            .allocator = allocator,
            .events = result.value,
            .warnings = prepared.warnings,
            .include_raw = call_options.include_raw_chunks orelse false,
            .uses_json_response_tool = prepared.uses_json_response_tool,
            .provider_options_name = prepared.provider_options_name,
            .used_custom_provider_key = prepared.used_custom_provider_key,
            .tool_names = prepared.tool_names,
            .diag = diag,
            .id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "src" }, diag),
        };
        try state.queue.append(allocator, .{ .stream_start = .{ .warnings = prepared.warnings } });

        // Anthropic can return HTTP 200 with an overload error. Pull through
        // stream-start/raw framing and replay the buffered non-error prelude.
        var first_substantive: ?provider.StreamPart = null;
        while (first_substantive == null) {
            const part = (try state.nextBase()) orelse break;
            try state.replay.append(allocator, part);
            switch (part) {
                .stream_start, .raw => {},
                else => first_substantive = part,
            }
        }
        if (first_substantive) |part| switch (part) {
            .err => |error_part| {
                const error_type = errorType(error_part.error_value);
                const overloaded = error_type != null and std.mem.eql(u8, error_type.?, "overloaded_error");
                const message = errorMessage(error_part.error_value) orelse "Anthropic stream error";
                const response_body = try provider_utils.stringifyJsonValueAlloc(allocator, error_part.error_value);
                provider.Diagnostics.set(diag, if (diag) |value| value.allocator else allocator, .{ .api_call = .{
                    .message = message,
                    .url = url,
                    .status_code = if (overloaded) 529 else 500,
                    .response_headers = result.response_headers,
                    .response_body = response_body,
                    .is_retryable = overloaded,
                    .request_body_json = body_json,
                } });
                state.deinitResources();
                return error.APICallError;
            },
            else => {},
        };

        return .{
            .stream = .{ .ctx = state, .vtable = &StreamState.vtable },
            .request = .{ .body = prepared.body },
            .response = .{ .headers = result.response_headers },
        };
    }

    fn buildArgs(
        self: *AnthropicLanguageModel,
        allocator: Allocator,
        call_options: *const provider.CallOptions,
        stream: bool,
        configured_headers: []const provider_utils.HeaderEntry,
        diag: ?*provider.Diagnostics,
    ) BuildError!PreparedRequest {
        var warnings: std.ArrayList(provider.Warning) = .empty;
        defer warnings.deinit(allocator);
        var cache_validator: prompt_api.CacheControlValidator = .{};
        const parsed_options = try options_api.parse(
            allocator,
            call_options.provider_options,
            self.config.provider_options_name,
            diag,
        );
        var anthropic_options = parsed_options.value;
        const capabilities = capabilities_api.getModelCapabilities(self.model_id);

        if (call_options.frequency_penalty != null) try unsupportedWarning(allocator, &warnings, "frequencyPenalty", null);
        if (call_options.presence_penalty != null) try unsupportedWarning(allocator, &warnings, "presencePenalty", null);
        if (call_options.seed != null) try unsupportedWarning(allocator, &warnings, "seed", null);

        var temperature = call_options.temperature;
        var top_p = call_options.top_p;
        var top_k = call_options.top_k;
        if (temperature) |value| {
            if (value > 1) {
                temperature = 1;
                try unsupportedWarning(allocator, &warnings, "temperature", "temperature exceeds anthropic maximum of 1.0. clamped to 1.0");
            } else if (value < 0) {
                temperature = 0;
                try unsupportedWarning(allocator, &warnings, "temperature", "temperature is below anthropic minimum of 0. clamped to 0");
            }
        }
        if (capabilities.rejects_sampling_parameters) {
            if (temperature != null) {
                temperature = null;
                try unsupportedWarning(allocator, &warnings, "temperature", "sampling parameters are not supported by this model");
            }
            if (top_p != null) {
                top_p = null;
                try unsupportedWarning(allocator, &warnings, "topP", "sampling parameters are not supported by this model");
            }
            if (top_k != null) {
                top_k = null;
                try unsupportedWarning(allocator, &warnings, "topK", "sampling parameters are not supported by this model");
            }
        }

        if (call_options.reasoning) |reasoning| {
            if (reasoning != .provider_default and anthropic_options.thinking == null) {
                if (reasoning == .none) {
                    anthropic_options.thinking = .{ .type = .disabled };
                } else if (capabilities.supports_adaptive_thinking) {
                    anthropic_options.thinking = .{ .type = .adaptive };
                    if (anthropic_options.effort == null) anthropic_options.effort = switch (reasoning) {
                        .minimal, .low => .low,
                        .medium => .medium,
                        .high => .high,
                        .xhigh => if (capabilities.supports_xhigh_effort) .xhigh else .max,
                        else => null,
                    };
                } else {
                    anthropic_options.thinking = .{
                        .type = .enabled,
                        .budgetTokens = reasoningBudget(reasoning, capabilities.max_output_tokens),
                    };
                }
            }
        }

        const prompt_result = try prompt_api.convert(
            allocator,
            call_options.prompt,
            anthropic_options.sendReasoning orelse true,
            call_options.tools,
            &warnings,
            &cache_validator,
            diag,
        );
        var betas = prompt_result.betas;

        const structured_mode = anthropic_options.structuredOutputMode orelse .auto;
        const use_native_structured = structured_mode == .outputFormat or
            (structured_mode == .auto and capabilities.supports_structured_output);
        var uses_json_tool = false;
        var prepared_tools = call_options.tools;
        var tool_choice = call_options.tool_choice;
        var disable_parallel = anthropic_options.disableParallelToolUse;
        if (call_options.response_format) |format| switch (format) {
            .text => {},
            .json => |json| if (json.schema == null) {
                try unsupportedWarning(allocator, &warnings, "responseFormat", "JSON response format requires a schema. The response format is ignored.");
            } else if (!use_native_structured) {
                uses_json_tool = true;
                const original = call_options.tools orelse &.{};
                const combined = try allocator.alloc(provider.Tool, original.len + 1);
                @memcpy(combined[0..original.len], original);
                combined[original.len] = .{ .function = .{
                    .name = "json",
                    .description = "Respond with a JSON object.",
                    .input_schema = json.schema.?,
                } };
                prepared_tools = combined;
                tool_choice = .{ .required = .{} };
                disable_parallel = true;
            },
        };

        const tool_result = try tools_api.prepare(
            allocator,
            prepared_tools,
            tool_choice,
            disable_parallel,
            &cache_validator,
            if (uses_json_tool) false else capabilities.supports_structured_output,
            capabilities.supports_structured_output,
            stream and (anthropic_options.toolStreaming orelse true),
            &warnings,
        );
        try betas.merge(allocator, &tool_result.betas);
        for (configured_headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "anthropic-beta")) {
            if (header.value) |value| try betas.addCsv(allocator, value);
        };
        if (call_options.headers) |headers| for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "anthropic-beta")) try betas.addCsv(allocator, header.value);
        };
        if (anthropic_options.anthropicBeta) |values| for (values) |beta| try betas.add(allocator, beta);

        const thinking = anthropic_options.thinking;
        const thinking_enabled = if (thinking) |value| value.type != .disabled else false;
        var thinking_budget: u64 = 0;
        if (thinking) |value| if (value.type == .enabled) {
            thinking_budget = value.budgetTokens orelse 1024;
            if (value.budgetTokens == null) try warnings.append(allocator, .{ .compatibility = .{
                .feature = "extended thinking",
                .details = "thinking budget is required when thinking is enabled. using default budget of 1024 tokens.",
            } });
        };
        if (thinking_enabled) {
            if (temperature != null) {
                temperature = null;
                try unsupportedWarning(allocator, &warnings, "temperature", "temperature is not supported when thinking is enabled");
            }
            if (top_p != null) {
                top_p = null;
                try unsupportedWarning(allocator, &warnings, "topP", "topP is not supported when thinking is enabled");
            }
            if (top_k != null) {
                top_k = null;
                try unsupportedWarning(allocator, &warnings, "topK", "topK is not supported when thinking is enabled");
            }
        } else if ((capabilities.is_known_model or std.mem.startsWith(u8, self.model_id, "claude-")) and
            temperature != null and top_p != null)
        {
            top_p = null;
            try unsupportedWarning(allocator, &warnings, "topP", "topP is not supported when temperature is set. topP is ignored.");
        }

        const requested_max = call_options.max_output_tokens orelse capabilities.max_output_tokens;
        var max_tokens = requested_max +| thinking_budget;
        if (capabilities.is_known_model and max_tokens > capabilities.max_output_tokens) {
            if (call_options.max_output_tokens != null) try unsupportedWarning(
                allocator,
                &warnings,
                "maxOutputTokens",
                "maxOutputTokens plus thinking budget exceeds the model maximum and was clamped",
            );
            max_tokens = capabilities.max_output_tokens;
        }

        var body: std.json.ObjectMap = .empty;
        try utils.putString(&body, allocator, "model", self.model_id);
        try body.put(allocator, "max_tokens", try utils.uintValue(allocator, max_tokens));
        if (temperature) |value| try body.put(allocator, "temperature", .{ .float = value });
        if (top_k) |value| try body.put(allocator, "top_k", .{ .float = value });
        if (top_p) |value| try body.put(allocator, "top_p", .{ .float = value });
        if (call_options.stop_sequences) |values| try body.put(allocator, "stop_sequences", try stringArray(allocator, values));

        if (thinking) |value| {
            var object: std.json.ObjectMap = .empty;
            try utils.putString(&object, allocator, "type", @tagName(value.type));
            if (value.type == .enabled) try object.put(
                allocator,
                "budget_tokens",
                try utils.uintValue(allocator, thinking_budget),
            );
            if (value.display) |display| try utils.putString(&object, allocator, "display", @tagName(display));
            try body.put(allocator, "thinking", .{ .object = object });
        }

        var output_config: std.json.ObjectMap = .empty;
        if (anthropic_options.effort) |effort| try utils.putString(&output_config, allocator, "effort", @tagName(effort));
        if (anthropic_options.taskBudget) |task_budget| {
            if (try taskBudgetValue(allocator, task_budget)) |value| {
                try output_config.put(allocator, "task_budget", value);
                try betas.add(allocator, "task-budgets-2026-03-13");
            }
        }
        if (use_native_structured) if (call_options.response_format) |format| switch (format) {
            .json => |json| if (json.schema) |schema| {
                var format_object: std.json.ObjectMap = .empty;
                try utils.putString(&format_object, allocator, "type", "json_schema");
                try format_object.put(allocator, "schema", try provider_utils.cloneJsonValue(allocator, schema));
                try output_config.put(allocator, "format", .{ .object = format_object });
            },
            else => {},
        };
        if (output_config.count() != 0) try body.put(allocator, "output_config", .{ .object = output_config });
        if (anthropic_options.speed) |speed| {
            try utils.putString(&body, allocator, "speed", @tagName(speed));
            if (speed == .fast) try betas.add(allocator, "fast-mode-2026-02-01");
        }
        if (anthropic_options.inferenceGeo) |geo| try utils.putString(&body, allocator, "inference_geo", @tagName(geo));
        if (anthropic_options.fallbacks) |fallbacks| if (fallbacks == .array and fallbacks.array.items.len != 0) {
            try body.put(allocator, "fallbacks", try provider_utils.cloneJsonValue(allocator, fallbacks));
            try betas.add(allocator, "server-side-fallback-2026-06-01");
        };
        if (anthropic_options.cacheControl) |cache| {
            var object: std.json.ObjectMap = .empty;
            try utils.putString(&object, allocator, "type", @tagName(cache.type));
            if (cache.ttl) |ttl| try utils.putString(&object, allocator, "ttl", @tagName(ttl));
            try body.put(allocator, "cache_control", .{ .object = object });
        }
        if (anthropic_options.metadata) |metadata| if (metadata.userId) |user_id| {
            var object: std.json.ObjectMap = .empty;
            try utils.putString(&object, allocator, "user_id", user_id);
            try body.put(allocator, "metadata", .{ .object = object });
        };
        if (anthropic_options.mcpServers) |servers| {
            if (try mcpServersValue(allocator, servers)) |value| {
                try body.put(allocator, "mcp_servers", value);
                try betas.add(allocator, "mcp-client-2025-04-04");
            }
        }
        if (anthropic_options.container) |container| {
            if (try containerValue(allocator, container)) |value| {
                try body.put(allocator, "container", value);
                if (containerHasSkills(container)) {
                    try betas.add(allocator, "code-execution-2025-08-25");
                    try betas.add(allocator, "skills-2025-10-02");
                    try betas.add(allocator, "files-api-2025-04-14");
                    if (!hasSkillsCodeExecutionTool(call_options.tools)) {
                        try warnings.append(allocator, .{ .other = .{
                            .message = "code execution tool is required when using skills",
                        } });
                    }
                }
            }
        }
        if (prompt_result.system) |system| try body.put(allocator, "system", system);
        try body.put(allocator, "messages", prompt_result.messages);
        if (anthropic_options.contextManagement) |context_management| {
            if (try contextManagementValue(allocator, context_management, &warnings)) |value| {
                try body.put(allocator, "context_management", value.value);
                try betas.add(allocator, "context-management-2025-06-27");
                if (value.has_compaction) try betas.add(allocator, "compact-2026-01-12");
            }
        }
        if (tool_result.tools) |value| try body.put(allocator, "tools", value);
        if (tool_result.tool_choice) |value| try body.put(allocator, "tool_choice", value);
        if (stream) try body.put(allocator, "stream", .{ .bool = true });

        return .{
            .body = .{ .object = body },
            .warnings = try warnings.toOwnedSlice(allocator),
            .betas = betas,
            .uses_json_response_tool = uses_json_tool,
            .provider_options_name = self.config.provider_options_name,
            .used_custom_provider_key = parsed_options.used_custom_key,
            .tool_names = try buildToolNames(allocator, call_options.tools),
        };
    }

    fn resolveHeaders(
        self: *AnthropicLanguageModel,
        allocator: Allocator,
        configured_headers: []const provider_utils.HeaderEntry,
        call_headers: ?provider.Headers,
        betas: *const utils.BetaSet,
        diag: ?*provider.Diagnostics,
    ) BuildError![]const provider.Header {
        const api_key = try provider_utils.loadOptionalSetting(.{
            .explicit = self.config.api_key,
            .env_var = "ANTHROPIC_API_KEY",
            .description = "Anthropic",
            .setting_name = "apiKey",
            .env = self.config.env,
        }, allocator);
        const auth_token = try provider_utils.loadOptionalSetting(.{
            .explicit = self.config.auth_token,
            .env_var = "ANTHROPIC_AUTH_TOKEN",
            .description = "Anthropic",
            .setting_name = "authToken",
            .env = self.config.env,
        }, allocator);
        if (api_key != null and auth_token != null) return invalidArgument(
            diag,
            allocator,
            "apiKey/authToken",
            "Both apiKey and authToken were provided. Please use only one authentication method.",
        );
        var defaults: [2]provider_utils.HeaderEntry = undefined;
        var defaults_len: usize = 1;
        defaults[0] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        if (auth_token) |token| {
            defaults[defaults_len] = .{
                .name = "authorization",
                .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
            };
            defaults_len += 1;
        } else {
            const key = api_key orelse try provider_utils.loadApiKey(.{
                .explicit = null,
                .env_var = "ANTHROPIC_API_KEY",
                .description = "Anthropic",
                .env = self.config.env,
            }, allocator, diag);
            defaults[defaults_len] = .{ .name = "x-api-key", .value = key };
            defaults_len += 1;
        }
        var beta_entries: [1]provider_utils.HeaderEntry = undefined;
        const beta_headers: []const provider_utils.HeaderEntry = if (try betas.join(allocator)) |value| blk: {
            beta_entries[0] = .{ .name = "anthropic-beta", .value = value };
            break :blk &beta_entries;
        } else &.{};
        const call_entries = try allocator.alloc(provider_utils.HeaderEntry, if (call_headers) |headers| headers.len else 0);
        if (call_headers) |headers| for (headers, call_entries) |header, *entry| {
            entry.* = .{ .name = header.name, .value = header.value };
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            defaults[0..defaults_len],
            configured_headers,
            call_entries,
            beta_headers,
        };
        const combined = try provider_utils.combineHeaders(allocator, &lists);
        return provider_utils.withUserAgentSuffix(allocator, combined, &.{"ai-sdk-zig/anthropic/0.0.0"});
    }
};

fn mapGenerateResponse(
    io: std.Io,
    allocator: Allocator,
    prepared: PreparedRequest,
    response: std.json.Value,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.CallError!provider.GenerateResult {
    if (response != .object) return invalidResponse(diag, allocator, "Anthropic response must be an object");
    const root = response.object;
    const content_value = root.get("content") orelse return invalidResponse(
        diag,
        allocator,
        "Anthropic response content is missing",
    );
    if (content_value != .array) return invalidResponse(diag, allocator, "Anthropic response content must be an array");
    var content: std.ArrayList(provider.Content) = .empty;
    defer content.deinit(allocator);
    var generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "src" }, diag);
    var json_response_from_tool = false;
    var mcp_calls: std.StringHashMapUnmanaged(McpCall) = .empty;
    defer mcp_calls.deinit(allocator);

    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const kind = utils.optionalString(part.object, "type") orelse continue;
        if (std.mem.eql(u8, kind, "text")) {
            if (!prepared.uses_json_response_tool) {
                if (utils.optionalString(part.object, "text")) |text| if (text.len != 0) {
                    try content.append(allocator, .{ .text = .{ .text = text } });
                };
                if (part.object.get("citations")) |citations| if (citations == .array) {
                    for (citations.array.items) |citation| {
                        if (try citationSource(allocator, citation, &generator)) |source| {
                            try content.append(allocator, .{ .source = source });
                        }
                    }
                };
            }
        } else if (std.mem.eql(u8, kind, "thinking")) {
            const text = utils.optionalString(part.object, "thinking") orelse "";
            const metadata = if (utils.optionalString(part.object, "signature")) |signature|
                try anthropicMetadataValue(allocator, &.{.{ "signature", .{ .string = signature } }})
            else
                null;
            try content.append(allocator, .{ .reasoning = .{
                .text = text,
                .provider_metadata = metadata,
            } });
        } else if (std.mem.eql(u8, kind, "redacted_thinking")) {
            const metadata = if (utils.optionalString(part.object, "data")) |data|
                try anthropicMetadataValue(allocator, &.{.{ "redactedData", .{ .string = data } }})
            else
                null;
            try content.append(allocator, .{ .reasoning = .{
                .text = "",
                .provider_metadata = metadata,
            } });
        } else if (std.mem.eql(u8, kind, "mcp_tool_use")) {
            const id = utils.optionalString(part.object, "id") orelse try generator.nextAlloc(allocator);
            const name = utils.optionalString(part.object, "name") orelse "unknown";
            const input = part.object.get("input") orelse std.json.Value{ .object = .empty };
            const metadata = try mcpMetadata(
                allocator,
                utils.optionalString(part.object, "server_name"),
            );
            try mcp_calls.put(allocator, id, .{ .tool_name = name, .provider_metadata = metadata });
            try content.append(allocator, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = name,
                .input = try provider_utils.stringifyJsonValueAlloc(allocator, input),
                .provider_executed = true,
                .dynamic = true,
                .provider_metadata = metadata,
            } });
        } else if (std.mem.eql(u8, kind, "mcp_tool_result")) {
            const tool_call_id = utils.optionalString(part.object, "tool_use_id") orelse "";
            const call = mcp_calls.get(tool_call_id);
            try content.append(allocator, .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .tool_name = if (call) |value| value.tool_name else "mcp",
                .result = try provider_utils.cloneJsonValue(
                    allocator,
                    part.object.get("content") orelse .null,
                ),
                .is_error = utils.optionalBool(part.object, "is_error"),
                .dynamic = true,
                .provider_metadata = if (call) |value| value.provider_metadata else null,
            } });
        } else if (std.mem.eql(u8, kind, "tool_use") or std.mem.eql(u8, kind, "server_tool_use")) {
            const id = utils.optionalString(part.object, "id") orelse try generator.nextAlloc(allocator);
            const wire_name = utils.optionalString(part.object, "name") orelse "unknown";
            const input = part.object.get("input") orelse std.json.Value{ .object = .empty };
            if (prepared.uses_json_response_tool and std.mem.eql(u8, wire_name, "json")) {
                json_response_from_tool = true;
                try content.append(allocator, .{ .text = .{
                    .text = try provider_utils.stringifyJsonValueAlloc(allocator, input),
                } });
            } else {
                try content.append(allocator, .{ .tool_call = .{
                    .tool_call_id = id,
                    .tool_name = customToolName(prepared.tool_names, wire_name),
                    .input = try provider_utils.stringifyJsonValueAlloc(allocator, input),
                    .provider_executed = std.mem.eql(u8, kind, "server_tool_use"),
                    .provider_metadata = try callerMetadata(allocator, part.object.get("caller")),
                } });
            }
        } else if (std.mem.endsWith(u8, kind, "_tool_result") or std.mem.eql(u8, kind, "tool_search_tool_result")) {
            const tool_call_id = utils.optionalString(part.object, "tool_use_id") orelse "";
            const wire_name = resultToolName(kind);
            const result_value = part.object.get("content") orelse std.json.Value.null;
            try content.append(allocator, .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .tool_name = customToolName(prepared.tool_names, wire_name),
                .result = try provider_utils.cloneJsonValue(allocator, result_value),
                .is_error = toolResultIsError(result_value),
            } });
            if (std.mem.eql(u8, kind, "web_search_tool_result") and result_value == .array) {
                for (result_value.array.items) |item| if (item == .object) {
                    const url = utils.optionalString(item.object, "url") orelse continue;
                    const id = try generator.nextAlloc(allocator);
                    try content.append(allocator, .{ .source = .{ .url = .{
                        .id = id,
                        .url = url,
                        .title = utils.optionalString(item.object, "title"),
                    } } });
                };
            }
        }
    }

    const raw_stop = utils.optionalString(root, "stop_reason");
    const usage_value = root.get("usage") orelse std.json.Value.null;
    return .{
        .content = try content.toOwnedSlice(allocator),
        .finish_reason = .{
            .unified = mapStopReason(raw_stop, json_response_from_tool),
            .raw = raw_stop,
        },
        .usage = try convertUsage(allocator, usage_value),
        .provider_metadata = try responseProviderMetadata(
            allocator,
            usage_value,
            root.get("stop_sequence") orelse .null,
            root.get("stop_details") orelse .null,
            root.get("container"),
            root.get("context_management"),
            prepared.provider_options_name,
            prepared.used_custom_provider_key,
        ),
        .request = .{ .body = prepared.body },
        .response = .{
            .id = utils.optionalString(root, "id"),
            .model_id = utils.optionalString(root, "model"),
            .headers = response_headers,
            .body = response,
        },
        .warnings = prepared.warnings,
    };
}

const MetadataEntry = struct { []const u8, std.json.Value };

const McpCall = struct {
    tool_name: []const u8,
    provider_metadata: provider.ProviderMetadata,
};

fn anthropicMetadataValue(
    allocator: Allocator,
    entries: []const MetadataEntry,
) Allocator.Error!provider.ProviderMetadata {
    var anthropic: std.json.ObjectMap = .empty;
    for (entries) |entry| try anthropic.put(
        allocator,
        entry[0],
        try provider_utils.cloneJsonValue(allocator, entry[1]),
    );
    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "anthropic", .{ .object = anthropic });
    return .{ .object = root };
}

fn callerMetadata(
    allocator: Allocator,
    caller_value: ?std.json.Value,
) Allocator.Error!?provider.ProviderMetadata {
    const caller = caller_value orelse return null;
    if (caller != .object) return null;
    var normalized: std.json.ObjectMap = .empty;
    if (utils.optionalString(caller.object, "type")) |value| try utils.putString(&normalized, allocator, "type", value);
    if (utils.optionalString(caller.object, "tool_id")) |value| try utils.putString(&normalized, allocator, "toolId", value);
    var anthropic: std.json.ObjectMap = .empty;
    try anthropic.put(allocator, "caller", .{ .object = normalized });
    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "anthropic", .{ .object = anthropic });
    return .{ .object = root };
}

fn mcpMetadata(
    allocator: Allocator,
    server_name: ?[]const u8,
) Allocator.Error!provider.ProviderMetadata {
    var entries: [2]MetadataEntry = undefined;
    var len: usize = 1;
    entries[0] = .{ "type", .{ .string = "mcp-tool-use" } };
    if (server_name) |value| {
        entries[len] = .{ "serverName", .{ .string = value } };
        len += 1;
    }
    return anthropicMetadataValue(allocator, entries[0..len]);
}

fn citationSource(
    allocator: Allocator,
    citation: std.json.Value,
    generator: *provider_utils.IdGenerator,
) Allocator.Error!?provider.Source {
    if (citation != .object) return null;
    const kind = utils.optionalString(citation.object, "type") orelse return null;
    if (!std.mem.eql(u8, kind, "web_search_result_location")) return null;
    const url = utils.optionalString(citation.object, "url") orelse return null;
    return .{ .url = .{
        .id = try generator.nextAlloc(allocator),
        .url = url,
        .title = utils.optionalString(citation.object, "title"),
    } };
}

fn convertUsage(allocator: Allocator, usage: std.json.Value) Allocator.Error!provider.Usage {
    if (usage != .object) return .{ .input_tokens = .{}, .output_tokens = .{} };
    const input = utils.optionalU64(usage.object.get("input_tokens"));
    const output = utils.optionalU64(usage.object.get("output_tokens"));
    const cache_write = utils.optionalU64(usage.object.get("cache_creation_input_tokens")) orelse 0;
    const cache_read = utils.optionalU64(usage.object.get("cache_read_input_tokens")) orelse 0;
    // TODO(phase-3): Sum executor iterations when an exercised fixture needs
    // compaction/advisor accounting; preserve raw iterations meanwhile.
    return .{
        .input_tokens = .{
            .total = if (input) |value| value +| cache_write +| cache_read else null,
            .no_cache = input,
            .cache_read = if (input != null) cache_read else null,
            .cache_write = if (input != null) cache_write else null,
        },
        .output_tokens = .{ .total = output },
        .raw = try provider_utils.cloneJsonValue(allocator, usage),
    };
}

fn responseProviderMetadata(
    allocator: Allocator,
    usage: std.json.Value,
    stop_sequence: std.json.Value,
    stop_details: std.json.Value,
    container: ?std.json.Value,
    context_management: ?std.json.Value,
    custom_name: []const u8,
    used_custom: bool,
) Allocator.Error!provider.ProviderMetadata {
    var metadata: std.json.ObjectMap = .empty;
    try metadata.put(allocator, "usage", try provider_utils.cloneJsonValue(allocator, usage));
    try metadata.put(allocator, "stopSequence", try provider_utils.cloneJsonValue(allocator, stop_sequence));
    try metadata.put(allocator, "stopDetails", try provider_utils.cloneJsonValue(allocator, stop_details));
    if (usage == .object) {
        try metadata.put(
            allocator,
            "iterations",
            try provider_utils.cloneJsonValue(allocator, usage.object.get("iterations") orelse .null),
        );
    } else try metadata.put(allocator, "iterations", .null);
    try metadata.put(
        allocator,
        "container",
        if (container) |value| try provider_utils.cloneJsonValue(allocator, value) else .null,
    );
    try metadata.put(
        allocator,
        "contextManagement",
        if (context_management) |value| try provider_utils.cloneJsonValue(allocator, value) else .null,
    );
    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "anthropic", .{ .object = metadata });
    if (used_custom and !std.mem.eql(u8, custom_name, "anthropic")) {
        try root.put(allocator, try allocator.dupe(u8, custom_name), .{ .object = metadata });
    }
    return .{ .object = root };
}

const BlockKind = enum { text, reasoning, tool };

const BlockState = struct {
    kind: BlockKind,
    id: []const u8,
    tool_name: []const u8 = "",
    input: std.ArrayList(u8) = .empty,
    provider_executed: bool = false,
    is_thinking: bool = false,
    json_response_tool: bool = false,

    fn deinit(self: *BlockState, allocator: Allocator) void {
        self.input.deinit(allocator);
        self.* = undefined;
    }
};

const StreamState = struct {
    allocator: Allocator,
    events: provider_utils.JsonEventStream(std.json.Value),
    warnings: []const provider.Warning,
    include_raw: bool,
    uses_json_response_tool: bool,
    provider_options_name: []const u8,
    used_custom_provider_key: bool,
    tool_names: []const ToolName,
    diag: ?*provider.Diagnostics,
    id_generator: provider_utils.IdGenerator,
    blocks: std.AutoHashMapUnmanaged(usize, BlockState) = .empty,
    mcp_calls: std.StringHashMapUnmanaged(McpCall) = .empty,
    queue: std.ArrayList(provider.StreamPart) = .empty,
    queue_index: usize = 0,
    replay: std.ArrayList(provider.StreamPart) = .empty,
    replay_index: usize = 0,
    usage: std.json.ObjectMap = .empty,
    finish_reason: provider.FinishReason = .{ .unified = .other },
    stop_sequence: std.json.Value = .null,
    stop_details: std.json.Value = .null,
    container: ?std.json.Value = null,
    context_management: ?std.json.Value = null,
    json_response_from_tool: bool = false,
    ended: bool = false,
    deinitialized: bool = false,

    const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return null;
        if (self.replay_index < self.replay.items.len) {
            defer self.replay_index += 1;
            return self.replay.items[self.replay_index];
        }
        return self.nextBase();
    }

    fn nextBase(self: *StreamState) provider.NextError!?provider.StreamPart {
        while (self.queue_index >= self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.queue_index = 0;
            if (self.ended) return null;
            try self.fillQueue();
        }
        defer self.queue_index += 1;
        return self.queue.items[self.queue_index];
    }

    fn deinit(raw: *anyopaque, _: std.Io) void {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        self.deinitResources();
    }

    fn deinitResources(self: *StreamState) void {
        if (self.deinitialized) return;
        self.events.deinit();
        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.mcp_calls.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.replay.deinit(self.allocator);
        self.usage.deinit(self.allocator);
        self.deinitialized = true;
    }

    fn fillQueue(self: *StreamState) provider.NextError!void {
        while (self.queue.items.len == 0) {
            const event = self.events.next(self.allocator) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponseDataError => return error.InvalidResponseDataError,
                else => return invalidStream(self.diag, self.allocator, @errorName(err)),
            };
            if (event == null) {
                self.ended = true;
                return;
            }
            switch (event.?) {
                .failure => |failure| {
                    if (self.include_raw) try self.queue.append(self.allocator, .{ .raw = .{
                        .raw_value = .{ .string = failure.raw },
                    } });
                    try self.queue.append(self.allocator, .{ .err = .{
                        .error_value = .{ .string = failure.message },
                    } });
                },
                .success => |success| {
                    if (self.include_raw) try self.queue.append(self.allocator, .{ .raw = .{
                        .raw_value = success.value,
                    } });
                    try self.mapEvent(success.value);
                },
            }
        }
    }

    fn mapEvent(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (value != .object) {
            try self.queue.append(self.allocator, .{ .err = .{ .error_value = value } });
            return;
        }
        const root = value.object;
        const event_type = utils.optionalString(root, "type") orelse return;
        if (std.mem.eql(u8, event_type, "ping")) return;
        if (std.mem.eql(u8, event_type, "error")) {
            try self.queue.append(self.allocator, .{ .err = .{
                .error_value = root.get("error") orelse value,
            } });
            return;
        }
        if (std.mem.eql(u8, event_type, "message_start")) return self.messageStart(root);
        if (std.mem.eql(u8, event_type, "content_block_start")) return self.contentBlockStart(root);
        if (std.mem.eql(u8, event_type, "content_block_delta")) return self.contentBlockDelta(root);
        if (std.mem.eql(u8, event_type, "content_block_stop")) return self.contentBlockStop(root);
        if (std.mem.eql(u8, event_type, "message_delta")) return self.messageDelta(root);
        if (std.mem.eql(u8, event_type, "message_stop")) return self.messageStop();
    }

    fn messageStart(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const message_value = root.get("message") orelse return;
        if (message_value != .object) return;
        const message = message_value.object;
        if (message.get("usage")) |usage| if (usage == .object) try self.mergeUsage(usage.object);
        if (message.get("container")) |container| if (container != .null) {
            self.container = try provider_utils.cloneJsonValue(self.allocator, container);
        };
        if (utils.optionalString(message, "stop_reason")) |raw| {
            self.finish_reason = .{ .unified = mapStopReason(raw, self.json_response_from_tool), .raw = raw };
        }
        try self.queue.append(self.allocator, .{ .response_metadata = .{
            .id = utils.optionalString(message, "id"),
            .model_id = utils.optionalString(message, "model"),
        } });
        if (message.get("content")) |content| if (content == .array) {
            for (content.array.items) |part| {
                if (part != .object) continue;
                const kind = utils.optionalString(part.object, "type") orelse continue;
                if (!std.mem.eql(u8, kind, "tool_use")) continue;
                const id = utils.optionalString(part.object, "id") orelse try self.id_generator.nextAlloc(self.allocator);
                const name = utils.optionalString(part.object, "name") orelse "unknown";
                const input = part.object.get("input") orelse std.json.Value{ .object = .empty };
                const input_json = try provider_utils.stringifyJsonValueAlloc(self.allocator, input);
                try self.queue.append(self.allocator, .{ .tool_input_start = .{ .id = id, .tool_name = name } });
                try self.queue.append(self.allocator, .{ .tool_input_delta = .{ .id = id, .delta = input_json } });
                try self.queue.append(self.allocator, .{ .tool_input_end = .{ .id = id } });
                try self.queue.append(self.allocator, .{ .tool_call = .{
                    .tool_call_id = id,
                    .tool_name = name,
                    .input = input_json,
                    .provider_metadata = try callerMetadata(self.allocator, part.object.get("caller")),
                } });
            }
        };
    }

    fn contentBlockStart(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = eventIndex(root) orelse return;
        const block_value = root.get("content_block") orelse return;
        if (block_value != .object) return;
        const block = block_value.object;
        const kind = utils.optionalString(block, "type") orelse return;
        const index_id = try std.fmt.allocPrint(self.allocator, "{d}", .{index});

        if (std.mem.eql(u8, kind, "fallback")) return;
        if (std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "compaction")) {
            if (self.uses_json_response_tool and std.mem.eql(u8, kind, "text")) return;
            try self.blocks.put(self.allocator, index, .{ .kind = .text, .id = index_id });
            const metadata = if (std.mem.eql(u8, kind, "compaction"))
                try anthropicMetadataValue(self.allocator, &.{.{ "type", .{ .string = "compaction" } }})
            else
                null;
            try self.queue.append(self.allocator, .{ .text_start = .{
                .id = index_id,
                .provider_metadata = metadata,
            } });
            return;
        }
        if (std.mem.eql(u8, kind, "thinking") or std.mem.eql(u8, kind, "redacted_thinking")) {
            try self.blocks.put(self.allocator, index, .{
                .kind = .reasoning,
                .id = index_id,
                .is_thinking = std.mem.eql(u8, kind, "thinking"),
            });
            const metadata = if (std.mem.eql(u8, kind, "redacted_thinking"))
                if (utils.optionalString(block, "data")) |data|
                    try anthropicMetadataValue(self.allocator, &.{.{ "redactedData", .{ .string = data } }})
                else
                    null
            else
                null;
            try self.queue.append(self.allocator, .{ .reasoning_start = .{
                .id = index_id,
                .provider_metadata = metadata,
            } });
            return;
        }
        if (std.mem.eql(u8, kind, "mcp_tool_use")) {
            const id = utils.optionalString(block, "id") orelse try self.id_generator.nextAlloc(self.allocator);
            const name = utils.optionalString(block, "name") orelse "unknown";
            const input = block.get("input") orelse std.json.Value{ .object = .empty };
            const metadata = try mcpMetadata(
                self.allocator,
                utils.optionalString(block, "server_name"),
            );
            try self.mcp_calls.put(self.allocator, id, .{
                .tool_name = name,
                .provider_metadata = metadata,
            });
            try self.queue.append(self.allocator, .{ .tool_call = .{
                .tool_call_id = id,
                .tool_name = name,
                .input = try provider_utils.stringifyJsonValueAlloc(self.allocator, input),
                .provider_executed = true,
                .dynamic = true,
                .provider_metadata = metadata,
            } });
            return;
        }
        if (std.mem.eql(u8, kind, "mcp_tool_result")) {
            const tool_call_id = utils.optionalString(block, "tool_use_id") orelse "";
            const call = self.mcp_calls.get(tool_call_id);
            try self.queue.append(self.allocator, .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .tool_name = if (call) |value| value.tool_name else "mcp",
                .result = try provider_utils.cloneJsonValue(
                    self.allocator,
                    block.get("content") orelse .null,
                ),
                .is_error = utils.optionalBool(block, "is_error"),
                .dynamic = true,
                .provider_metadata = if (call) |value| value.provider_metadata else null,
            } });
            return;
        }
        if (std.mem.eql(u8, kind, "tool_use") or std.mem.eql(u8, kind, "server_tool_use")) {
            const id = utils.optionalString(block, "id") orelse try self.id_generator.nextAlloc(self.allocator);
            const wire_name = utils.optionalString(block, "name") orelse "unknown";
            const json_tool = self.uses_json_response_tool and std.mem.eql(u8, wire_name, "json");
            if (json_tool) {
                self.json_response_from_tool = true;
                try self.blocks.put(self.allocator, index, .{
                    .kind = .text,
                    .id = index_id,
                    .json_response_tool = true,
                });
                try self.queue.append(self.allocator, .{ .text_start = .{ .id = index_id } });
                return;
            }
            var state: BlockState = .{
                .kind = .tool,
                .id = id,
                .tool_name = customToolName(self.tool_names, wire_name),
                .provider_executed = std.mem.eql(u8, kind, "server_tool_use"),
            };
            if (block.get("input")) |input| if (input == .object and input.object.count() != 0) {
                try state.input.appendSlice(
                    self.allocator,
                    try provider_utils.stringifyJsonValueAlloc(self.allocator, input),
                );
            };
            try self.blocks.put(self.allocator, index, state);
            try self.queue.append(self.allocator, .{ .tool_input_start = .{
                .id = id,
                .tool_name = state.tool_name,
                .provider_executed = state.provider_executed,
            } });
            return;
        }
        if (std.mem.endsWith(u8, kind, "_tool_result") or std.mem.eql(u8, kind, "tool_search_tool_result")) {
            const tool_call_id = utils.optionalString(block, "tool_use_id") orelse "";
            const result_value = block.get("content") orelse std.json.Value.null;
            const wire_name = resultToolName(kind);
            try self.queue.append(self.allocator, .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .tool_name = customToolName(self.tool_names, wire_name),
                .result = try provider_utils.cloneJsonValue(self.allocator, result_value),
                .is_error = toolResultIsError(result_value),
            } });
            if (std.mem.eql(u8, kind, "web_search_tool_result") and result_value == .array) {
                for (result_value.array.items) |item| if (item == .object) {
                    const url = utils.optionalString(item.object, "url") orelse continue;
                    try self.queue.append(self.allocator, .{ .source = .{ .url = .{
                        .id = try self.id_generator.nextAlloc(self.allocator),
                        .url = url,
                        .title = utils.optionalString(item.object, "title"),
                    } } });
                };
            }
        }
    }

    fn contentBlockDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = eventIndex(root) orelse return;
        const delta_value = root.get("delta") orelse return;
        if (delta_value != .object) return;
        const delta = delta_value.object;
        const kind = utils.optionalString(delta, "type") orelse return;
        const block = self.blocks.getPtr(index);
        if (std.mem.eql(u8, kind, "text_delta")) {
            const text = utils.optionalString(delta, "text") orelse "";
            if (text.len != 0) try self.queue.append(self.allocator, .{ .text_delta = .{
                .id = if (block) |state| state.id else try std.fmt.allocPrint(self.allocator, "{d}", .{index}),
                .delta = text,
            } });
        } else if (std.mem.eql(u8, kind, "thinking_delta")) {
            const text = utils.optionalString(delta, "thinking") orelse "";
            try self.queue.append(self.allocator, .{ .reasoning_delta = .{
                .id = if (block) |state| state.id else try std.fmt.allocPrint(self.allocator, "{d}", .{index}),
                .delta = text,
            } });
        } else if (std.mem.eql(u8, kind, "signature_delta")) {
            if (block) |state| if (state.kind == .reasoning and state.is_thinking) {
                const signature = utils.optionalString(delta, "signature") orelse "";
                try self.queue.append(self.allocator, .{ .reasoning_delta = .{
                    .id = state.id,
                    .delta = "",
                    .provider_metadata = try anthropicMetadataValue(
                        self.allocator,
                        &.{.{ "signature", .{ .string = signature } }},
                    ),
                } });
            };
        } else if (std.mem.eql(u8, kind, "compaction_delta")) {
            if (utils.optionalString(delta, "content")) |text| try self.queue.append(
                self.allocator,
                .{ .text_delta = .{
                    .id = if (block) |state| state.id else try std.fmt.allocPrint(self.allocator, "{d}", .{index}),
                    .delta = text,
                } },
            );
        } else if (std.mem.eql(u8, kind, "input_json_delta")) {
            const fragment = utils.optionalString(delta, "partial_json") orelse "";
            if (fragment.len == 0) return;
            const state = block orelse return;
            if (state.kind == .text and state.json_response_tool) {
                try self.queue.append(self.allocator, .{ .text_delta = .{ .id = state.id, .delta = fragment } });
            } else if (state.kind == .tool) {
                try state.input.appendSlice(self.allocator, fragment);
                try self.queue.append(self.allocator, .{ .tool_input_delta = .{
                    .id = state.id,
                    .delta = fragment,
                } });
            }
        } else if (std.mem.eql(u8, kind, "citations_delta")) {
            if (delta.get("citation")) |citation| {
                if (try citationSource(self.allocator, citation, &self.id_generator)) |source| {
                    try self.queue.append(self.allocator, .{ .source = source });
                }
            }
        }
    }

    fn contentBlockStop(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        const index = eventIndex(root) orelse return;
        var state = self.blocks.fetchRemove(index) orelse return;
        defer state.value.deinit(self.allocator);
        switch (state.value.kind) {
            .text => try self.queue.append(self.allocator, .{ .text_end = .{ .id = state.value.id } }),
            .reasoning => try self.queue.append(self.allocator, .{ .reasoning_end = .{ .id = state.value.id } }),
            .tool => {
                try self.queue.append(self.allocator, .{ .tool_input_end = .{ .id = state.value.id } });
                try self.queue.append(self.allocator, .{ .tool_call = .{
                    .tool_call_id = state.value.id,
                    .tool_name = state.value.tool_name,
                    .input = if (state.value.input.items.len == 0) "{}" else try self.allocator.dupe(u8, state.value.input.items),
                    .provider_executed = state.value.provider_executed,
                } });
            },
        }
    }

    fn messageDelta(self: *StreamState, root: std.json.ObjectMap) provider.NextError!void {
        if (root.get("usage")) |usage| if (usage == .object) try self.mergeUsage(usage.object);
        if (root.get("delta")) |delta| if (delta == .object) {
            if (utils.optionalString(delta.object, "stop_reason")) |raw| {
                self.finish_reason = .{ .unified = mapStopReason(raw, self.json_response_from_tool), .raw = raw };
            }
            if (delta.object.get("stop_sequence")) |value| self.stop_sequence = try provider_utils.cloneJsonValue(self.allocator, value);
            if (delta.object.get("stop_details")) |value| self.stop_details = try provider_utils.cloneJsonValue(self.allocator, value);
            if (delta.object.get("container")) |value| self.container = try provider_utils.cloneJsonValue(self.allocator, value);
        };
        if (root.get("context_management")) |value| {
            self.context_management = try provider_utils.cloneJsonValue(self.allocator, value);
        }
    }

    fn messageStop(self: *StreamState) provider.NextError!void {
        const usage_value: std.json.Value = .{ .object = self.usage };
        try self.queue.append(self.allocator, .{ .finish = .{
            .finish_reason = self.finish_reason,
            .usage = try convertUsage(self.allocator, usage_value),
            .provider_metadata = try responseProviderMetadata(
                self.allocator,
                usage_value,
                self.stop_sequence,
                self.stop_details,
                self.container,
                self.context_management,
                self.provider_options_name,
                self.used_custom_provider_key,
            ),
        } });
    }

    fn mergeUsage(self: *StreamState, source: std.json.ObjectMap) Allocator.Error!void {
        var iterator = source.iterator();
        while (iterator.next()) |entry| try self.usage.put(
            self.allocator,
            try self.allocator.dupe(u8, entry.key_ptr.*),
            try provider_utils.cloneJsonValue(self.allocator, entry.value_ptr.*),
        );
    }
};

fn taskBudgetValue(
    allocator: Allocator,
    value: std.json.Value,
) Allocator.Error!?std.json.Value {
    if (value != .object) return null;
    var output: std.json.ObjectMap = .empty;
    try copyObjectField(allocator, &output, value.object, "type", "type");
    try copyObjectField(allocator, &output, value.object, "total", "total");
    try copyObjectField(allocator, &output, value.object, "remaining", "remaining");
    return .{ .object = output };
}

fn mcpServersValue(
    allocator: Allocator,
    value: std.json.Value,
) Allocator.Error!?std.json.Value {
    if (value != .array or value.array.items.len == 0) return null;
    var servers = std.json.Array.init(allocator);
    for (value.array.items) |server_value| {
        if (server_value != .object) continue;
        var server: std.json.ObjectMap = .empty;
        try copyObjectField(allocator, &server, server_value.object, "type", "type");
        try copyObjectField(allocator, &server, server_value.object, "name", "name");
        try copyObjectField(allocator, &server, server_value.object, "url", "url");
        try copyObjectField(
            allocator,
            &server,
            server_value.object,
            "authorizationToken",
            "authorization_token",
        );
        if (server_value.object.get("toolConfiguration")) |configuration| {
            if (configuration == .object) {
                var wire_configuration: std.json.ObjectMap = .empty;
                try copyObjectField(
                    allocator,
                    &wire_configuration,
                    configuration.object,
                    "allowedTools",
                    "allowed_tools",
                );
                try copyObjectField(
                    allocator,
                    &wire_configuration,
                    configuration.object,
                    "enabled",
                    "enabled",
                );
                if (wire_configuration.count() != 0) try server.put(
                    allocator,
                    "tool_configuration",
                    .{ .object = wire_configuration },
                );
            }
        }
        try servers.append(.{ .object = server });
    }
    return if (servers.items.len == 0) null else .{ .array = servers };
}

fn containerValue(
    allocator: Allocator,
    value: std.json.Value,
) Allocator.Error!?std.json.Value {
    if (value != .object) return null;
    const skills_value = value.object.get("skills");
    const has_skills = if (skills_value) |skills| skills == .array and skills.array.items.len != 0 else false;
    if (!has_skills) {
        const id = utils.optionalString(value.object, "id") orelse return null;
        return .{ .string = try allocator.dupe(u8, id) };
    }

    var container: std.json.ObjectMap = .empty;
    try copyObjectField(allocator, &container, value.object, "id", "id");
    var skills = std.json.Array.init(allocator);
    for (skills_value.?.array.items) |skill_value| {
        if (skill_value != .object) continue;
        var skill: std.json.ObjectMap = .empty;
        const kind = utils.optionalString(skill_value.object, "type") orelse continue;
        try utils.putString(&skill, allocator, "type", kind);
        if (std.mem.eql(u8, kind, "custom")) {
            if (skill_value.object.get("providerReference")) |reference| {
                if (anthropicReference(reference)) |id| try utils.putString(
                    &skill,
                    allocator,
                    "skill_id",
                    id,
                );
            }
        } else if (utils.optionalString(skill_value.object, "skillId")) |id| {
            try utils.putString(&skill, allocator, "skill_id", id);
        }
        try copyObjectField(allocator, &skill, skill_value.object, "version", "version");
        try skills.append(.{ .object = skill });
    }
    try container.put(allocator, "skills", .{ .array = skills });
    return .{ .object = container };
}

fn anthropicReference(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    return utils.optionalString(value.object, "anthropic");
}

fn containerHasSkills(value: std.json.Value) bool {
    if (value != .object) return false;
    const skills = value.object.get("skills") orelse return false;
    return skills == .array and skills.array.items.len != 0;
}

fn hasSkillsCodeExecutionTool(input_tools: ?[]const provider.Tool) bool {
    const tools = input_tools orelse return false;
    for (tools) |tool| switch (tool) {
        .provider => |value| if (std.mem.eql(u8, value.id, "anthropic.code_execution_20250825") or
            std.mem.eql(u8, value.id, "anthropic.code_execution_20260120")) return true,
        else => {},
    };
    return false;
}

const ContextManagementResult = struct {
    value: std.json.Value,
    has_compaction: bool,
};

fn contextManagementValue(
    allocator: Allocator,
    value: std.json.Value,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!?ContextManagementResult {
    if (value != .object) return null;
    const edits_value = value.object.get("edits") orelse return null;
    if (edits_value != .array) return null;
    var edits = std.json.Array.init(allocator);
    var has_compaction = false;
    for (edits_value.array.items) |edit_value| {
        if (edit_value != .object) continue;
        const kind = utils.optionalString(edit_value.object, "type") orelse continue;
        var edit: std.json.ObjectMap = .empty;
        try utils.putString(&edit, allocator, "type", kind);
        if (std.mem.eql(u8, kind, "clear_tool_uses_20250919")) {
            try copyObjectField(allocator, &edit, edit_value.object, "trigger", "trigger");
            try copyObjectField(allocator, &edit, edit_value.object, "keep", "keep");
            try copyObjectField(allocator, &edit, edit_value.object, "clearAtLeast", "clear_at_least");
            try copyObjectField(allocator, &edit, edit_value.object, "clearToolInputs", "clear_tool_inputs");
            try copyObjectField(allocator, &edit, edit_value.object, "excludeTools", "exclude_tools");
        } else if (std.mem.eql(u8, kind, "clear_thinking_20251015")) {
            try copyObjectField(allocator, &edit, edit_value.object, "keep", "keep");
        } else if (std.mem.eql(u8, kind, "compact_20260112")) {
            has_compaction = true;
            try copyObjectField(allocator, &edit, edit_value.object, "trigger", "trigger");
            try copyObjectField(allocator, &edit, edit_value.object, "pauseAfterCompaction", "pause_after_compaction");
            try copyObjectField(allocator, &edit, edit_value.object, "instructions", "instructions");
        } else {
            try warnings.append(allocator, .{ .other = .{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "Unknown context management strategy: {s}",
                    .{kind},
                ),
            } });
            continue;
        }
        try edits.append(.{ .object = edit });
    }
    var context: std.json.ObjectMap = .empty;
    try context.put(allocator, "edits", .{ .array = edits });
    return .{ .value = .{ .object = context }, .has_compaction = has_compaction };
}

fn copyObjectField(
    allocator: Allocator,
    destination: *std.json.ObjectMap,
    source: std.json.ObjectMap,
    source_name: []const u8,
    destination_name: []const u8,
) Allocator.Error!void {
    const value = source.get(source_name) orelse return;
    if (value == .null) return;
    try destination.put(
        allocator,
        destination_name,
        try provider_utils.cloneJsonValue(allocator, value),
    );
}

fn reasoningBudget(effort: provider.ReasoningEffort, maximum: u64) ?u64 {
    const percent: ?u64 = switch (effort) {
        .minimal => 2,
        .low => 10,
        .medium => 30,
        .high => 60,
        .xhigh => 90,
        else => null,
    };
    const value = percent orelse return null;
    return @min(maximum, @max(1024, maximum *| value / 100));
}

fn unsupportedWarning(
    allocator: Allocator,
    warnings: *std.ArrayList(provider.Warning),
    feature: []const u8,
    details: ?[]const u8,
) Allocator.Error!void {
    try warnings.append(allocator, .{ .unsupported = .{ .feature = feature, .details = details } });
}

fn stringArray(allocator: Allocator, values: []const []const u8) Allocator.Error!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = try allocator.dupe(u8, value) });
    return .{ .array = array };
}

fn buildToolNames(allocator: Allocator, input: ?[]const provider.Tool) Allocator.Error![]const ToolName {
    const tools = input orelse return &.{};
    var names: std.ArrayList(ToolName) = .empty;
    defer names.deinit(allocator);
    for (tools) |tool| switch (tool) {
        .provider => |value| try names.append(allocator, .{
            .wire = prompt_api.toProviderToolName(tools, value.name),
            .custom = value.name,
        }),
        else => {},
    };
    return names.toOwnedSlice(allocator);
}

fn customToolName(names: []const ToolName, wire: []const u8) []const u8 {
    for (names) |name| if (std.mem.eql(u8, name.wire, wire)) return name.custom;
    return wire;
}

fn mapStopReason(raw: ?[]const u8, json_from_tool: bool) provider.FinishReasonUnified {
    const reason = raw orelse return .other;
    if (std.mem.eql(u8, reason, "pause_turn") or
        std.mem.eql(u8, reason, "end_turn") or
        std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "refusal")) return .content_filter;
    if (std.mem.eql(u8, reason, "tool_use")) return if (json_from_tool) .stop else .tool_calls;
    if (std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "model_context_window_exceeded")) return .length;
    return .other;
}

fn resultToolName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "web_search_tool_result")) return "web_search";
    if (std.mem.eql(u8, kind, "web_fetch_tool_result")) return "web_fetch";
    if (std.mem.eql(u8, kind, "code_execution_tool_result") or
        std.mem.eql(u8, kind, "bash_code_execution_tool_result") or
        std.mem.eql(u8, kind, "text_editor_code_execution_tool_result")) return "code_execution";
    if (std.mem.eql(u8, kind, "tool_search_tool_result")) return "tool_search_tool_regex";
    if (std.mem.eql(u8, kind, "advisor_tool_result")) return "advisor";
    if (std.mem.eql(u8, kind, "mcp_tool_result")) return "mcp";
    return kind;
}

fn toolResultIsError(value: std.json.Value) ?bool {
    if (value != .object) return null;
    const kind = utils.optionalString(value.object, "type") orelse return null;
    return std.mem.endsWith(u8, kind, "_error");
}

fn eventIndex(object: std.json.ObjectMap) ?usize {
    return switch (object.get("index") orelse return null) {
        .integer => |value| if (value >= 0) @intCast(value) else null,
        .float => |value| if (value >= 0 and @floor(value) == value) @intFromFloat(value) else null,
        else => null,
    };
}

fn errorType(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    return utils.optionalString(value.object, "type");
}

fn errorMessage(value: std.json.Value) ?[]const u8 {
    if (value == .string) return value.string;
    if (value != .object) return null;
    return utils.optionalString(value.object, "message");
}

fn invalidResponse(
    diag: ?*provider.Diagnostics,
    allocator: Allocator,
    message: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else allocator, .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
}

fn invalidStream(
    diag: ?*provider.Diagnostics,
    allocator: Allocator,
    message: []const u8,
) provider.NextError {
    return invalidResponse(diag, allocator, message);
}

fn invalidArgument(
    diag: ?*provider.Diagnostics,
    allocator: Allocator,
    parameter: []const u8,
    message: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

test "Anthropic stop reasons and usage conversion preserve cache accounting" {
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, mapStopReason("pause_turn", false));
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, mapStopReason("tool_use", false));
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, mapStopReason("tool_use", true));
    try std.testing.expectEqual(provider.FinishReasonUnified.content_filter, mapStopReason("refusal", false));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"input_tokens\":10,\"output_tokens\":4,\"cache_creation_input_tokens\":3,\"cache_read_input_tokens\":2}",
        .{},
    );
    const usage = try convertUsage(allocator, value);
    try std.testing.expectEqual(15, usage.input_tokens.total.?);
    try std.testing.expectEqual(10, usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(2, usage.input_tokens.cache_read.?);
    try std.testing.expectEqual(3, usage.input_tokens.cache_write.?);
    try std.testing.expectEqual(4, usage.output_tokens.total.?);
}
