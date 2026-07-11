//! Stage 1: provider stream standardization for one language-model call.
//!
//! Provider parts are cloned immediately into the caller's step arena because
//! `provider.PartStream` values borrow only until the next pull. The returned
//! stage owns the provider stream and must be deinitialized before that arena.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("../events.zig");
const generate_text = @import("../generate_text.zig");
const message = @import("../message.zig");
const prompt_api = @import("../prompt.zig");
const registry = @import("../registry.zig");
const telemetry = @import("../telemetry.zig");
const tool_api = @import("../tool.zig");
const tool_common = @import("../tool_execution_common.zig");
const types = @import("../generate_text_types.zig");
const part_stream = @import("part_stream.zig");
const parts = @import("parts.zig");

const Allocator = std.mem.Allocator;

pub fn Callback(comptime Event: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        callback: *const fn (ctx: ?*anyopaque, event: *const Event) anyerror!void,
    };
}

pub const Options = struct {
    model: registry.LanguageModelRef,
    instructions: ?prompt_api.Instructions = null,
    prompt: ?prompt_api.PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    allow_system_in_messages: bool = false,
    tools: tool_api.ToolSet = &.{},
    tool_order: ?[]const []const u8 = null,
    tool_choice: ?prompt_api.ToolChoice = null,
    tools_context: ?std.json.Value = null,
    call_settings: prompt_api.LanguageModelCallOptions = .{},
    response_format: ?provider.ResponseFormat = null,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    include_raw_chunks: bool = false,
    max_retries: u32 = 2,
    repair_tool_call: ?tool_common.RepairToolCall = null,
    refine_tool_input: ?[]const tool_common.RefineToolInput = null,
    transport: ?provider_utils.HttpTransport = null,
    download_options: provider_utils.DownloadOptions = .{},
    telemetry_options: telemetry.TelemetryOptions = .{},
    call_id: ?[]const u8 = null,
    on_language_model_call_start: ?Callback(events.LanguageModelCallStartEvent) = null,
    on_language_model_call_end: ?Callback(events.LanguageModelCallEndEvent) = null,
    diag: ?*provider.Diagnostics = null,
};

pub const Result = struct {
    stage: part_stream.PartStream(parts.LanguageModelStreamPart),
    request_info: provider.RequestInfo,
    response_info: provider.StreamResponseInfo,
};

const ModelAttempt = struct {
    model: provider.LanguageModel,
    arena: Allocator,
    options: *const provider.CallOptions,
    dispatcher: *telemetry.Dispatcher,
    call_id: []const u8,

    fn call(
        self: *ModelAttempt,
        io: std.Io,
        _: u32,
        diag: ?*provider.Diagnostics,
    ) anyerror!provider.StreamResult {
        const scope = try self.dispatcher.enterModelCall(self.call_id);
        defer scope.exit();
        return self.model.doStream(io, self.arena, self.options, diag);
    }
};

pub fn streamLanguageModelCall(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    options: Options,
) anyerror!Result {
    const model = try registry.resolveLanguageModel(options.model, options.diag);
    const standardized = try prompt_api.standardizePrompt(arena, .{
        .instructions = options.instructions,
        .prompt = options.prompt,
        .messages = options.messages,
        .allow_system_in_messages = options.allow_system_in_messages,
    }, options.diag);
    const prompt_messages = try prompt_api.convertToLanguageModelPrompt(io, gpa, arena, .{
        .prompt = standardized,
        .model = model,
        .transport = options.transport,
        .provider_name = model.provider(),
        .download_options = options.download_options,
    }, options.diag);
    const prepared_tools = try prompt_api.prepareTools(
        arena,
        if (options.tools.len == 0) null else options.tools,
        options.tool_order,
        options.tools_context,
        options.diag,
    );
    const call_settings = try prompt_api.prepareLanguageModelCallOptions(arena, options.call_settings, options.diag);
    const model_options = try arena.create(provider.CallOptions);
    model_options.* = .{
        .prompt = prompt_messages,
        .max_output_tokens = call_settings.max_output_tokens,
        .temperature = call_settings.temperature,
        .stop_sequences = call_settings.stop_sequences,
        .top_p = call_settings.top_p,
        .top_k = call_settings.top_k,
        .presence_penalty = call_settings.presence_penalty,
        .frequency_penalty = call_settings.frequency_penalty,
        .response_format = options.response_format,
        .seed = call_settings.seed,
        .tools = prepared_tools,
        .tool_choice = prompt_api.prepareToolChoice(options.tool_choice),
        .include_raw_chunks = options.include_raw_chunks,
        .headers = options.headers,
        .reasoning = call_settings.reasoning,
        .provider_options = options.provider_options,
    };

    var id_generator = try provider_utils.IdGenerator.initFromIo(io, .{}, options.diag);
    const call_id = if (options.call_id) |value| try arena.dupe(u8, value) else try id_generator.nextAlloc(arena);
    var dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry_options);
    const start_event: events.LanguageModelCallStartEvent = .{
        .call_id = call_id,
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .instructions = instructionsText(standardized.instructions),
        .messages = standardized.messages,
        .tools = prepared_tools,
        .options = model_options,
    };
    if (options.on_language_model_call_start) |callback| callback.callback(callback.ctx, &start_event) catch {};
    try dispatcher.onLanguageModelCallStart(&start_event);

    const call_started = std.Io.Timestamp.now(io, .awake);
    var attempt: ModelAttempt = .{
        .model = model,
        .arena = arena,
        .options = model_options,
        .dispatcher = &dispatcher,
        .call_id = call_id,
    };
    const stream_result = try provider_utils.retryWithOptions(
        provider.StreamResult,
        io,
        .{
            .policy = .{ .max_retries = options.max_retries },
            .get_delay_ms = generate_text.retryDelayInMs,
        },
        &attempt,
        ModelAttempt.call,
        options.diag,
    );
    errdefer stream_result.stream.deinit(io);

    const request_info = try cloneRequestInfo(arena, stream_result.request);
    const response_info = try cloneStreamResponseInfo(arena, stream_result.response);
    const state = try arena.create(State);
    state.* = .{
        .arena = arena,
        .provider_stream = stream_result.stream,
        .tools = options.tools,
        .instructions = standardized.instructions,
        .messages = standardized.messages,
        .repair_tool_call = options.repair_tool_call,
        .refine_tool_input = options.refine_tool_input,
        .dispatcher = dispatcher,
        .on_end = options.on_language_model_call_end,
        .call_id = call_id,
        .provider_name = try arena.dupe(u8, model.provider()),
        .model_id = try arena.dupe(u8, model.modelId()),
        .response_id = try id_generator.nextAlloc(arena),
        .call_started = call_started,
    };
    return .{
        .stage = .{ .ctx = state, .vtable = &State.vtable },
        .request_info = request_info,
        .response_info = response_info,
    };
}

const State = struct {
    arena: Allocator,
    provider_stream: provider.PartStream,
    tools: tool_api.ToolSet,
    instructions: ?prompt_api.Instructions,
    messages: []const message.ModelMessage,
    repair_tool_call: ?tool_common.RepairToolCall,
    refine_tool_input: ?[]const tool_common.RefineToolInput,
    dispatcher: telemetry.Dispatcher,
    on_end: ?Callback(events.LanguageModelCallEndEvent),
    call_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    response_id: []const u8,
    call_started: std.Io.Timestamp,
    previous_output_timestamp: ?std.Io.Timestamp = null,
    time_to_first_output_ms: ?f64 = null,
    output_gaps_ms: std.ArrayList(f64) = .empty,
    calls_by_id: std.StringHashMapUnmanaged(types.TypedToolCall) = .empty,
    text_indexes: std.StringHashMapUnmanaged(usize) = .empty,
    reasoning_indexes: std.StringHashMapUnmanaged(usize) = .empty,
    content: std.ArrayList(types.ContentPart) = .empty,
    pending: ?parts.LanguageModelStreamPart = null,
    deinitialized: bool = false,

    const vtable: part_stream.PartStream(parts.LanguageModelStreamPart).VTable = .{
        .next = next,
        .deinit = deinit,
    };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?parts.LanguageModelStreamPart {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.pending) |part| {
            self.pending = null;
            return part;
        }

        while (true) {
            const raw_part = (try self.provider_stream.next(io)) orelse return null;
            if (isOutputPart(raw_part)) try self.recordOutputTimestamp(io);

            switch (raw_part) {
                .text_start => |value| {
                    const cloned = try cloneBoundary(self.arena, value);
                    try self.upsertText(.text, cloned.id, null, cloned.provider_metadata);
                    return .{ .text_start = cloned };
                },
                .text_delta => |value| {
                    if (value.delta.len == 0) continue;
                    const cloned = try cloneDelta(self.arena, value);
                    try self.upsertText(.text, cloned.id, cloned.text, cloned.provider_metadata);
                    return .{ .text_delta = cloned };
                },
                .text_end => |value| {
                    const cloned = try cloneBoundary(self.arena, value);
                    try self.upsertText(.text, cloned.id, null, cloned.provider_metadata);
                    _ = self.text_indexes.remove(cloned.id);
                    return .{ .text_end = cloned };
                },
                .reasoning_start => |value| {
                    const cloned = try cloneBoundary(self.arena, value);
                    try self.upsertText(.reasoning, cloned.id, null, cloned.provider_metadata);
                    return .{ .reasoning_start = cloned };
                },
                .reasoning_delta => |value| {
                    const cloned = try cloneDelta(self.arena, value);
                    try self.upsertText(.reasoning, cloned.id, cloned.text, cloned.provider_metadata);
                    return .{ .reasoning_delta = cloned };
                },
                .reasoning_end => |value| {
                    const cloned = try cloneBoundary(self.arena, value);
                    try self.upsertText(.reasoning, cloned.id, null, cloned.provider_metadata);
                    _ = self.reasoning_indexes.remove(cloned.id);
                    return .{ .reasoning_end = cloned };
                },
                .tool_input_start => |value| {
                    const named = tool_common.findTool(self.tools, value.tool_name);
                    return .{ .tool_input_start = .{
                        .id = try self.arena.dupe(u8, value.id),
                        .tool_name = try self.arena.dupe(u8, value.tool_name),
                        .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
                        .tool_metadata = if (named) |tool| try cloneOptionalJson(self.arena, tool.tool.metadata) else null,
                        .provider_executed = value.provider_executed,
                        .dynamic = value.dynamic orelse if (named) |tool| tool.tool.kind == .dynamic else null,
                        .title = if (value.title) |title| try self.arena.dupe(u8, title) else null,
                    } };
                },
                .tool_input_delta => |value| return .{ .tool_input_delta = .{
                    .id = try self.arena.dupe(u8, value.id),
                    .delta = try self.arena.dupe(u8, value.delta),
                    .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
                } },
                .tool_input_end => |value| return .{ .tool_input_end = .{
                    .id = try self.arena.dupe(u8, value.id),
                    .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
                } },
                .tool_call => |value| {
                    const call = try tool_common.parseToolCall(.{
                        .io = io,
                        .arena = self.arena,
                        .tools = self.tools,
                        .repair_tool_call = self.repair_tool_call,
                        .refine_tool_input = self.refine_tool_input,
                        .instructions = self.instructions,
                        .messages = self.messages,
                    }, value);
                    try self.calls_by_id.put(self.arena, call.tool_call_id, call);
                    try self.content.append(self.arena, .{ .tool_call = call });
                    if (call.invalid) self.pending = .{ .tool_error = .{
                        .tool_call_id = call.tool_call_id,
                        .tool_name = call.tool_name,
                        .input = call.input,
                        .error_value = .{ .string = call.err.?.message },
                        .error_code = call.err.?.err,
                        .provider_metadata = call.provider_metadata,
                        .tool_metadata = call.tool_metadata,
                        .dynamic = true,
                    } };
                    return .{ .tool_call = call };
                },
                .tool_result => |value| {
                    const call = self.calls_by_id.get(value.tool_call_id);
                    if (value.is_error == true) {
                        const tool_error: types.TypedToolError = .{
                            .tool_call_id = try self.arena.dupe(u8, value.tool_call_id),
                            .tool_name = try self.arena.dupe(u8, value.tool_name),
                            .input = if (call) |known| known.input else null,
                            .error_value = try provider_utils.cloneJsonValue(self.arena, value.result),
                            .provider_executed = true,
                            .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
                            .tool_metadata = if (call) |known| known.tool_metadata else null,
                            .dynamic = value.dynamic == true,
                        };
                        try self.content.append(self.arena, .{ .tool_error = tool_error });
                        return .{ .tool_error = tool_error };
                    }
                    const result: types.TypedToolResult = .{
                        .tool_call_id = try self.arena.dupe(u8, value.tool_call_id),
                        .tool_name = try self.arena.dupe(u8, value.tool_name),
                        .input = if (call) |known| known.input else null,
                        .output = try provider_utils.cloneJsonValue(self.arena, value.result),
                        .provider_executed = true,
                        .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
                        .tool_metadata = if (call) |known| known.tool_metadata else null,
                        .dynamic = value.dynamic == true,
                        .preliminary = value.preliminary == true,
                    };
                    try self.content.append(self.arena, .{ .tool_result = result });
                    return .{ .tool_result = result };
                },
                .tool_approval_request => |value| {
                    const call = self.calls_by_id.get(value.tool_call_id) orelse return .{ .err = .{
                        .error_value = .{ .string = try std.fmt.allocPrint(
                            self.arena,
                            "Tool call {s} not found for approval {s}",
                            .{ value.tool_call_id, value.approval_id },
                        ) },
                        .error_code = error.ToolCallNotFoundForApprovalError,
                    } };
                    const request: types.ToolApprovalRequest = .{
                        .approval_id = try self.arena.dupe(u8, value.approval_id),
                        .tool_call = call,
                    };
                    try self.content.append(self.arena, .{ .tool_approval_request = request });
                    return .{ .tool_approval_request = request };
                },
                .custom => |value| {
                    const custom: parts.Custom = .{
                        .kind = try self.arena.dupe(u8, value.kind),
                        .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
                    };
                    try self.content.append(self.arena, .{ .custom = .{
                        .kind = custom.kind,
                        .provider_metadata = custom.provider_metadata,
                    } });
                    return .{ .custom = custom };
                },
                .file => |value| {
                    const file = try cloneGeneratedFile(self.arena, value);
                    try self.content.append(self.arena, .{ .file = file });
                    return .{ .file = file };
                },
                .reasoning_file => |value| {
                    const file = try cloneReasoningFile(self.arena, value);
                    try self.content.append(self.arena, .{ .reasoning_file = file });
                    return .{ .reasoning_file = file };
                },
                .source => |value| {
                    const source = try cloneSource(self.arena, value);
                    try self.content.append(self.arena, .{ .source = source });
                    return .{ .source = source };
                },
                .stream_start => |value| return .{ .model_call_start = .{
                    .warnings = try cloneWarnings(self.arena, value.warnings),
                } },
                .response_metadata => |value| {
                    if (value.id) |id| self.response_id = try self.arena.dupe(u8, id);
                    return .{ .model_call_response_metadata = .{
                        .id = if (value.id) |id| try self.arena.dupe(u8, id) else null,
                        .timestamp_ms = value.timestamp_ms,
                        .model_id = if (value.model_id) |id| try self.arena.dupe(u8, id) else null,
                    } };
                },
                .finish => |value| return try self.finish(io, value),
                .raw => |value| return .{ .raw = try provider_utils.cloneJsonValue(self.arena, value.raw_value) },
                .err => |value| return .{ .err = .{
                    .error_value = try provider_utils.cloneJsonValue(self.arena, value.error_value),
                } },
            }
        }
    }

    fn finish(self: *State, io: std.Io, value: provider.language_model.FinishPart) anyerror!parts.LanguageModelStreamPart {
        const finished = std.Io.Timestamp.now(io, .awake);
        const response_time_ms = tool_common.elapsedMilliseconds(self.call_started, finished);
        const usage = try cloneUsage(self.arena, value.usage);
        const performance: parts.ModelCallPerformance = .{
            .response_time_ms = response_time_ms,
            .effective_output_tokens_per_second = tokensPerSecond(usage.output_tokens.total, response_time_ms),
            .output_tokens_per_second = if (self.time_to_first_output_ms) |ttft|
                tokensPerSecond(usage.output_tokens.total, response_time_ms - ttft)
            else
                null,
            .input_tokens_per_second = if (self.time_to_first_output_ms) |ttft|
                tokensPerSecond(usage.input_tokens.total, ttft)
            else
                null,
            .effective_total_tokens_per_second = tokensPerSecond(
                types.addTokenCounts(usage.input_tokens.total, usage.output_tokens.total),
                response_time_ms,
            ),
            .time_to_first_output_ms = self.time_to_first_output_ms,
            .time_between_output_chunks_ms = if (self.output_gaps_ms.items.len == 0)
                null
            else
                try parts.calculateChunkTimingStats(self.arena, self.output_gaps_ms.items),
        };
        const finish_reason: provider.FinishReason = .{
            .unified = value.finish_reason.unified,
            .raw = if (value.finish_reason.raw) |raw| try self.arena.dupe(u8, raw) else null,
        };
        const end_event: events.LanguageModelCallEndEvent = .{
            .call_id = self.call_id,
            .provider_name = self.provider_name,
            .model_id = self.model_id,
            .finish_reason = finish_reason,
            .usage = usage,
            .content = self.content.items,
            .response_id = self.response_id,
            .performance = .{
                .response_time_ms = performance.response_time_ms,
                .effective_output_tokens_per_second = performance.effective_output_tokens_per_second,
                .output_tokens_per_second = performance.output_tokens_per_second,
                .input_tokens_per_second = performance.input_tokens_per_second,
                .effective_total_tokens_per_second = performance.effective_total_tokens_per_second,
                .time_to_first_output_ms = performance.time_to_first_output_ms,
                .time_between_output_chunks_ms = performance.time_between_output_chunks_ms,
            },
        };
        if (self.on_end) |callback| callback.callback(callback.ctx, &end_event) catch {};
        try self.dispatcher.onLanguageModelCallEnd(&end_event);
        return .{ .model_call_end = .{
            .finish_reason = finish_reason,
            .raw_finish_reason = finish_reason.raw,
            .usage = usage,
            .provider_metadata = try cloneOptionalJson(self.arena, value.provider_metadata),
            .performance = performance,
        } };
    }

    fn recordOutputTimestamp(self: *State, io: std.Io) Allocator.Error!void {
        const now = std.Io.Timestamp.now(io, .awake);
        if (self.previous_output_timestamp) |previous| {
            try self.output_gaps_ms.append(self.arena, tool_common.elapsedMilliseconds(previous, now));
        } else {
            self.time_to_first_output_ms = tool_common.elapsedMilliseconds(self.call_started, now);
        }
        self.previous_output_timestamp = now;
    }

    const TextKind = enum { text, reasoning };

    fn upsertText(
        self: *State,
        kind: TextKind,
        id: []const u8,
        delta: ?[]const u8,
        metadata: ?provider.ProviderMetadata,
    ) Allocator.Error!void {
        const indexes = if (kind == .text) &self.text_indexes else &self.reasoning_indexes;
        const index = indexes.get(id) orelse blk: {
            const retained_id = try self.arena.dupe(u8, id);
            const new_index = self.content.items.len;
            switch (kind) {
                .text => try self.content.append(self.arena, .{ .text = .{
                    .text = "",
                    .provider_metadata = try cloneOptionalJson(self.arena, metadata),
                } }),
                .reasoning => try self.content.append(self.arena, .{ .reasoning = .{
                    .text = "",
                    .provider_metadata = try cloneOptionalJson(self.arena, metadata),
                } }),
            }
            try indexes.put(self.arena, retained_id, new_index);
            break :blk new_index;
        };

        switch (self.content.items[index]) {
            .text => |*value| {
                if (delta) |text| value.text = try std.mem.concat(self.arena, u8, &.{ value.text, text });
                if (metadata) |meta| value.provider_metadata = try provider_utils.cloneJsonValue(self.arena, meta);
            },
            .reasoning => |*value| {
                if (delta) |text| value.text = try std.mem.concat(self.arena, u8, &.{ value.text, text });
                if (metadata) |meta| value.provider_metadata = try provider_utils.cloneJsonValue(self.arena, meta);
            },
            else => unreachable,
        }
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.provider_stream.deinit(io);
    }
};

fn isOutputPart(part: provider.StreamPart) bool {
    return switch (part) {
        .text_delta => |value| value.delta.len != 0,
        .reasoning_delta => |value| value.delta.len != 0,
        .tool_input_delta => |value| value.delta.len != 0,
        .file, .reasoning_file, .tool_call => true,
        else => false,
    };
}

fn cloneBoundary(arena: Allocator, value: provider.language_model.BlockBoundary) Allocator.Error!parts.TextBlockBoundary {
    return .{
        .id = try arena.dupe(u8, value.id),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneDelta(arena: Allocator, value: provider.language_model.BlockDelta) Allocator.Error!parts.TextDelta {
    return .{
        .id = try arena.dupe(u8, value.id),
        .text = try arena.dupe(u8, value.delta),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneRequestInfo(arena: Allocator, value: provider.RequestInfo) Allocator.Error!provider.RequestInfo {
    return .{ .body = try cloneOptionalJson(arena, value.body) };
}

fn cloneStreamResponseInfo(arena: Allocator, value: provider.StreamResponseInfo) Allocator.Error!provider.StreamResponseInfo {
    return .{ .headers = try cloneHeaders(arena, value.headers) };
}

fn cloneHeaders(arena: Allocator, input: ?provider.Headers) Allocator.Error!?provider.Headers {
    const headers = input orelse return null;
    const result = try arena.alloc(provider.Header, headers.len);
    for (headers, result) |header, *destination| destination.* = .{
        .name = try arena.dupe(u8, header.name),
        .value = try arena.dupe(u8, header.value),
    };
    return result;
}

fn cloneWarnings(arena: Allocator, input: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const result = try arena.alloc(provider.Warning, input.len);
    for (input, result) |warning, *destination| destination.* = switch (warning) {
        .unsupported => |value| .{ .unsupported = .{
            .feature = try arena.dupe(u8, value.feature),
            .details = if (value.details) |details| try arena.dupe(u8, details) else null,
        } },
        .compatibility => |value| .{ .compatibility = .{
            .feature = try arena.dupe(u8, value.feature),
            .details = if (value.details) |details| try arena.dupe(u8, details) else null,
        } },
        .deprecated => |value| .{ .deprecated = .{
            .setting = try arena.dupe(u8, value.setting),
            .message = try arena.dupe(u8, value.message),
        } },
        .other => |value| .{ .other = .{ .message = try arena.dupe(u8, value.message) } },
    };
    return result;
}

fn cloneUsage(arena: Allocator, usage: provider.Usage) Allocator.Error!provider.Usage {
    return .{
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .raw = try cloneOptionalJson(arena, usage.raw),
    };
}

fn cloneGeneratedFile(arena: Allocator, value: provider.GeneratedFile) Allocator.Error!provider.GeneratedFile {
    return .{
        .media_type = try arena.dupe(u8, value.media_type),
        .data = try cloneGeneratedFileData(arena, value.data),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneReasoningFile(arena: Allocator, value: provider.GeneratedReasoningFile) Allocator.Error!provider.GeneratedReasoningFile {
    return .{
        .media_type = try arena.dupe(u8, value.media_type),
        .data = try cloneGeneratedFileData(arena, value.data),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneGeneratedFileData(arena: Allocator, value: provider.GeneratedFileData) Allocator.Error!provider.GeneratedFileData {
    return switch (value) {
        .data => |data| .{ .data = .{ .data = switch (data.data) {
            .bytes => |bytes| .{ .bytes = try arena.dupe(u8, bytes) },
            .base64 => |base64| .{ .base64 = try arena.dupe(u8, base64) },
        } } },
        .url => |url| .{ .url = .{ .url = try arena.dupe(u8, url.url) } },
    };
}

fn cloneSource(arena: Allocator, value: provider.Source) Allocator.Error!provider.Source {
    return switch (value) {
        .url => |source| .{ .url = .{
            .id = try arena.dupe(u8, source.id),
            .url = try arena.dupe(u8, source.url),
            .title = if (source.title) |title| try arena.dupe(u8, title) else null,
            .provider_metadata = try cloneOptionalJson(arena, source.provider_metadata),
        } },
        .document => |source| .{ .document = .{
            .id = try arena.dupe(u8, source.id),
            .media_type = try arena.dupe(u8, source.media_type),
            .title = try arena.dupe(u8, source.title),
            .filename = if (source.filename) |name| try arena.dupe(u8, name) else null,
            .provider_metadata = try cloneOptionalJson(arena, source.provider_metadata),
        } },
    };
}

fn cloneOptionalJson(arena: Allocator, value: ?std.json.Value) Allocator.Error!?std.json.Value {
    return if (value) |json| try provider_utils.cloneJsonValue(arena, json) else null;
}

fn instructionsText(input: ?prompt_api.Instructions) ?[]const u8 {
    return if (input) |instructions| switch (instructions) {
        .text => |text| text,
        .message => |system| system.content,
        .messages => null,
    } else null;
}

fn tokensPerSecond(tokens: ?u64, milliseconds: f64) f64 {
    const count = tokens orelse return 0;
    if (milliseconds <= 0) return 0;
    return @as(f64, @floatFromInt(count)) * 1000 / milliseconds;
}

const ScriptedModel = struct {
    stream_parts: []const provider.StreamPart,
    index: usize = 0,
    deinit_calls: usize = 0,
    stream_calls: usize = 0,
    fail_first: bool = false,

    fn model(self: *ScriptedModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &model_vtable };
    }

    const model_vtable: provider.LanguageModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .urlIsSupported = supported,
        .doGenerate = generate,
        .doStream = stream,
    };
    const stream_vtable: provider.PartStream.VTable = .{ .next = streamNext, .deinit = streamDeinit };

    fn fromRaw(raw: *anyopaque) *ScriptedModel {
        return @ptrCast(@alignCast(raw));
    }
    fn providerName(_: *anyopaque) []const u8 {
        return "scripted";
    }
    fn modelId(_: *anyopaque) []const u8 {
        return "stream-test";
    }
    fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }
    fn generate(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return error.UnsupportedFunctionalityError;
    }
    fn stream(
        raw: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const self = fromRaw(raw);
        self.stream_calls += 1;
        if (self.fail_first and self.stream_calls == 1) {
            const diagnostics = diag orelse return error.APICallError;
            provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .api_call = .{
                .message = "retry me",
                .url = "https://example.invalid",
                .response_headers = &.{.{ .name = "retry-after-ms", .value = "0" }},
                .is_retryable = true,
            } });
            return error.APICallError;
        }
        self.index = 0;
        return .{
            .stream = .{ .ctx = self, .vtable = &stream_vtable },
            .request = .{ .body = .{ .string = "request-body" } },
            .response = .{ .headers = &.{.{ .name = "x-model", .value = "scripted" }} },
        };
    }
    fn streamNext(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
        const self = fromRaw(raw);
        if (self.index == self.stream_parts.len) return null;
        defer self.index += 1;
        return self.stream_parts[self.index];
    }
    fn streamDeinit(raw: *anyopaque, _: std.Io) void {
        fromRaw(raw).deinit_calls += 1;
    }
};

test "model-call stage maps provider vocabulary and attaches parsed tool input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw_parts = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .response_metadata = .{ .id = "response-1", .timestamp_ms = 12, .model_id = "actual-model" } },
        .{ .text_start = .{ .id = "text-1" } },
        .{ .text_delta = .{ .id = "text-1", .delta = "" } },
        .{ .text_delta = .{ .id = "text-1", .delta = "hello" } },
        .{ .text_end = .{ .id = "text-1" } },
        .{ .tool_call = .{
            .tool_call_id = "provider-call",
            .tool_name = "provider.dynamic",
            .input = "{\"value\":7}",
            .provider_executed = true,
            .dynamic = true,
        } },
        .{ .tool_result = .{
            .tool_call_id = "provider-call",
            .tool_name = "provider.dynamic",
            .result = .{ .string = "done" },
            .dynamic = true,
        } },
        .{ .tool_call = .{
            .tool_call_id = "invalid-call",
            .tool_name = "missing",
            .input = "{bad",
        } },
        .{ .finish = .{
            .usage = .{ .input_tokens = .{ .total = 3 }, .output_tokens = .{ .total = 5 } },
            .finish_reason = .{ .unified = .tool_calls, .raw = "tool_use" },
        } },
    };
    var scripted: ScriptedModel = .{ .stream_parts = &raw_parts };
    const result = try streamLanguageModelCall(std.testing.io, std.testing.allocator, arena, .{
        .model = .{ .model = scripted.model() },
        .prompt = .{ .text = "test" },
    });
    defer result.stage.deinit(std.testing.io);
    try std.testing.expectEqualStrings("scripted", result.response_info.headers.?[0].value);
    try std.testing.expectEqualStrings("request-body", result.request_info.body.?.string);

    const expected_tags = [_]std.meta.Tag(parts.LanguageModelStreamPart){
        .model_call_start,
        .model_call_response_metadata,
        .text_start,
        .text_delta,
        .text_end,
        .tool_call,
        .tool_result,
        .tool_call,
        .tool_error,
        .model_call_end,
    };
    var tags: std.ArrayList(std.meta.Tag(parts.LanguageModelStreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    var saw_provider_input = false;
    var saw_invalid_pair = false;
    var saw_performance = false;
    while (try result.stage.next(std.testing.io)) |part| {
        try tags.append(std.testing.allocator, std.meta.activeTag(part));
        switch (part) {
            .text_delta => |value| try std.testing.expectEqualStrings("hello", value.text),
            .tool_result => |value| {
                saw_provider_input = value.input.?.object.get("value").?.integer == 7;
            },
            .tool_error => |value| {
                saw_invalid_pair = std.mem.eql(u8, value.tool_call_id, "invalid-call") and
                    value.error_code.? == error.NoSuchToolError;
            },
            .model_call_end => |value| {
                try std.testing.expectEqual(.tool_calls, value.finish_reason.unified);
                try std.testing.expectEqualStrings("tool_use", value.raw_finish_reason.?);
                saw_performance = value.performance.response_time_ms >= 0 and
                    value.performance.time_to_first_output_ms != null and
                    value.performance.time_between_output_chunks_ms != null;
            },
            else => {},
        }
    }
    try std.testing.expectEqualSlices(std.meta.Tag(parts.LanguageModelStreamPart), &expected_tags, tags.items);
    try std.testing.expect(saw_provider_input);
    try std.testing.expect(saw_invalid_pair);
    try std.testing.expect(saw_performance);
}

test "model-call retries bracket every provider attempt with telemetry hooks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw_parts = [_]provider.StreamPart{.{ .finish = .{
        .usage = .{ .input_tokens = .{}, .output_tokens = .{} },
        .finish_reason = .{ .unified = .stop },
    } }};
    var scripted: ScriptedModel = .{ .stream_parts = &raw_parts, .fail_first = true };
    const Hook = struct {
        enters: usize = 0,
        exits: usize = 0,
        fn enter(raw: ?*anyopaque, _: []const u8) ?*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.enters += 1;
            return self;
        }
        fn exit(raw: ?*anyopaque, _: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.exits += 1;
        }
    };
    var hook: Hook = .{};
    const integrations = [_]telemetry.Telemetry{.{ .ctx = &hook, .vtable = &.{
        .enterModelCall = Hook.enter,
        .exitModelCall = Hook.exit,
    } }};
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const result = try streamLanguageModelCall(std.testing.io, std.testing.allocator, arena, .{
        .model = .{ .model = scripted.model() },
        .prompt = .{ .text = "retry" },
        .max_retries = 1,
        .telemetry_options = .{ .integrations = &integrations },
        .diag = &diagnostics,
    });
    defer result.stage.deinit(std.testing.io);
    while (try result.stage.next(std.testing.io)) |_| {}
    try std.testing.expectEqual(2, scripted.stream_calls);
    try std.testing.expectEqual(2, hook.enters);
    try std.testing.expectEqual(2, hook.exits);
}
