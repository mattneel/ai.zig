//! Non-streaming text generation with the multi-step client tool loop.
//!
//! The returned result owns one call-lifetime arena. Provider responses,
//! prompts, step content, and response messages are retained there. Concurrent
//! tool executions use independent worker arenas and are copied into the call
//! arena in tool-call order after the group joins.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const logger = @import("logger.zig");
const message = @import("message.zig");
const prompt_api = @import("prompt.zig");
const response_message_builder = @import("response_messages.zig");
const registry = @import("registry.zig");
const telemetry = @import("telemetry.zig");
const tool_api = @import("tool.zig");
const approval_signature = @import("tool_approval_signature.zig");
const tool_common = @import("tool_execution_common.zig");
const types = @import("generate_text_types.zig");

const Allocator = std.mem.Allocator;

pub const GenerateTextResult = types.GenerateTextResult;
pub const StepResult = types.StepResult;
pub const ContentPart = types.ContentPart;
pub const TypedToolCall = types.TypedToolCall;
pub const TypedToolResult = types.TypedToolResult;
pub const TypedToolError = types.TypedToolError;
pub const OutputValue = types.OutputValue;

pub const ToolTimeout = struct {
    name: []const u8,
    ms: u64,
};

pub const TimeoutConfiguration = union(enum) {
    total_ms: u64,
    granular: Granular,

    pub const Granular = struct {
        total_ms: ?u64 = null,
        step_ms: ?u64 = null,
        /// Maximum gap between provider stream parts. Used by `streamText`.
        chunk_ms: ?u64 = null,
        tool_ms: ?u64 = null,
        tools: []const ToolTimeout = &.{},
    };

    pub fn totalMs(self: TimeoutConfiguration) ?u64 {
        return switch (self) {
            .total_ms => |value| value,
            .granular => |value| value.total_ms,
        };
    }

    pub fn stepMs(self: TimeoutConfiguration) ?u64 {
        return switch (self) {
            .total_ms => null,
            .granular => |value| value.step_ms,
        };
    }

    pub fn chunkMs(self: TimeoutConfiguration) ?u64 {
        return switch (self) {
            .total_ms => null,
            .granular => |value| value.chunk_ms,
        };
    }

    pub fn toolMs(self: TimeoutConfiguration, tool_name: []const u8) ?u64 {
        return switch (self) {
            .total_ms => null,
            .granular => |value| blk: {
                for (value.tools) |entry| {
                    if (std.mem.eql(u8, entry.name, tool_name)) break :blk entry.ms;
                }
                break :blk value.tool_ms;
            },
        };
    }
};

pub const StopCondition = struct {
    ctx: ?*const anyopaque = null,
    check_fn: *const fn (
        ctx: ?*const anyopaque,
        io: std.Io,
        steps: []const StepResult,
    ) provider.CallError!bool,

    pub fn check(self: StopCondition, io: std.Io, steps: []const StepResult) provider.CallError!bool {
        return self.check_fn(self.ctx, io, steps);
    }
};

/// The count is encoded in the opaque context value, keeping the public stop
/// condition representation a two-word fat pointer without heap allocation.
pub fn stepCount(count: usize) StopCondition {
    std.debug.assert(count < std.math.maxInt(usize));
    return .{
        .ctx = @ptrFromInt(count + 1),
        .check_fn = struct {
            fn check(raw: ?*const anyopaque, _: std.Io, steps: []const StepResult) provider.CallError!bool {
                const expected = @intFromPtr(raw.?) - 1;
                return steps.len == expected;
            }
        }.check,
    };
}

pub fn loopFinished() StopCondition {
    return .{
        .check_fn = struct {
            fn check(_: ?*const anyopaque, _: std.Io, _: []const StepResult) provider.CallError!bool {
                return false;
            }
        }.check,
    };
}

/// Comptime names specialize the predicate while preserving the two-word
/// fat-pointer representation without allocating a context object.
pub fn hasToolCall(comptime names: []const []const u8) StopCondition {
    const Storage = struct {
        const value = names;
        fn check(_: ?*const anyopaque, _: std.Io, steps: []const StepResult) provider.CallError!bool {
            if (steps.len == 0) return false;
            for (steps[steps.len - 1].toolCalls()) |call| {
                inline for (value) |name| {
                    if (std.mem.eql(u8, call.tool_name, name)) return true;
                }
            }
            return false;
        }
    };
    return .{ .check_fn = Storage.check };
}

pub const PrepareStepOptions = struct {
    steps: []const StepResult,
    step_number: usize,
    model: provider.LanguageModel,
    instructions: ?prompt_api.Instructions,
    initial_instructions: ?prompt_api.Instructions,
    messages: []const message.ModelMessage,
    initial_messages: []const message.ModelMessage,
    response_messages: []const message.ModelMessage,
    tools_context: ?std.json.Value,
    runtime_context: ?std.json.Value,
};

pub const PrepareStepResult = struct {
    model: ?registry.LanguageModelRef = null,
    tool_choice: ?prompt_api.ToolChoice = null,
    active_tools: ?[]const []const u8 = null,
    tool_order: ?[]const []const u8 = null,
    instructions: ?prompt_api.Instructions = null,
    messages: ?[]const message.ModelMessage = null,
    tools_context: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    provider_options: ?provider.ProviderOptions = null,
};

pub const PrepareStep = struct {
    ctx: ?*anyopaque = null,
    prepare_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const PrepareStepOptions,
    ) provider.CallError!?PrepareStepResult,

    pub fn prepare(
        self: PrepareStep,
        io: std.Io,
        arena: Allocator,
        options: *const PrepareStepOptions,
    ) provider.CallError!?PrepareStepResult {
        return self.prepare_fn(self.ctx, io, arena, options);
    }
};

pub const RepairToolCallOptions = tool_common.RepairToolCallOptions;
pub const RepairToolCall = tool_common.RepairToolCall;
pub const RefineToolInput = tool_common.RefineToolInput;

pub const OutputParseContext = struct {
    response: types.ResponseMetadata,
    usage: provider.Usage,
    finish_reason: provider.FinishReason,
};

pub const Output = struct {
    name: []const u8,
    response_format: provider.ResponseFormat,
    ctx: ?*anyopaque = null,
    parse_complete_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        text_value: []const u8,
        context: *const OutputParseContext,
    ) provider.CallError!OutputValue,

    pub fn parseComplete(
        self: Output,
        arena: Allocator,
        text_value: []const u8,
        context: *const OutputParseContext,
    ) provider.CallError!OutputValue {
        return self.parse_complete_fn(self.ctx, arena, text_value, context);
    }
};

pub fn text() Output {
    return .{
        .name = "text",
        .response_format = .{ .text = .{} },
        .parse_complete_fn = struct {
            fn parse(
                _: ?*anyopaque,
                _: Allocator,
                text_value: []const u8,
                _: *const OutputParseContext,
            ) provider.CallError!OutputValue {
                return .{ .text = text_value };
            }
        }.parse,
    };
}

pub fn Callback(comptime Event: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        callback: *const fn (ctx: ?*anyopaque, event: *const Event) anyerror!void,
    };
}

pub const Callbacks = struct {
    on_start: ?Callback(events.GenerateTextStartEvent) = null,
    on_step_start: ?Callback(events.StepStartEvent) = null,
    on_language_model_call_start: ?Callback(events.LanguageModelCallStartEvent) = null,
    on_language_model_call_end: ?Callback(events.LanguageModelCallEndEvent) = null,
    on_tool_execution_start: ?Callback(events.ToolExecutionStartEvent) = null,
    on_tool_execution_end: ?Callback(events.ToolExecutionEndEvent) = null,
    on_step_end: ?Callback(events.StepEndEvent) = null,
    on_end: ?Callback(events.EndEvent) = null,
    on_error: ?Callback(events.ErrorEvent) = null,
    on_abort: ?Callback(events.AbortEvent) = null,
};

pub const GenerateTextOptions = struct {
    model: registry.LanguageModelRef,
    instructions: ?prompt_api.Instructions = null,
    prompt: ?prompt_api.PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    allow_system_in_messages: bool = false,
    tools: []const tool_api.NamedTool = &.{},
    tool_choice: ?prompt_api.ToolChoice = null,
    active_tools: ?[]const []const u8 = null,
    tool_order: ?[]const []const u8 = null,
    stop_when: []const StopCondition = &.{},
    prepare_step: ?PrepareStep = null,
    repair_tool_call: ?RepairToolCall = null,
    refine_tool_input: ?[]const RefineToolInput = null,
    max_output_tokens: ?f64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?f64 = null,
    reasoning: ?provider.ReasoningEffort = null,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    timeout: ?TimeoutConfiguration = null,
    tools_context: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    output: ?Output = null,
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    /// Matches upstream's optional `experimental_toolApprovalSecret` source.
    tool_approval_secret: ?[]const u8 = null,
    diag: ?*provider.Diagnostics = null,
};

const CallData = struct {
    steps: []const StepResult,
    total_usage: provider.Usage,
    response_messages: []const message.ModelMessage,
    initial_response_messages: []const message.ModelMessage,
    all_content: []const ContentPart,
    all_files: []const provider.GeneratedFile,
    all_sources: []const provider.Source,
    all_tool_calls: []const TypedToolCall,
    all_static_tool_calls: []const TypedToolCall,
    all_dynamic_tool_calls: []const TypedToolCall,
    all_tool_results: []const TypedToolResult,
    all_static_tool_results: []const TypedToolResult,
    all_dynamic_tool_results: []const TypedToolResult,
    all_warnings: []const provider.Warning,
    parsed_output: ?OutputValue,
};

const CallState = struct {
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    options: GenerateTextOptions,
    dispatcher: telemetry.Dispatcher,
    id_generator: provider_utils.IdGenerator,
    call_id: []const u8,
    initial_messages: []const message.ModelMessage,
    initial_instructions: ?prompt_api.Instructions,
    current_messages: []const message.ModelMessage,
    current_instructions: ?prompt_api.Instructions,
    current_tools_context: ?std.json.Value,
    current_runtime_context: ?std.json.Value,
    initial_response_messages: std.ArrayList(message.ModelMessage) = .empty,
    accumulated_response_messages: std.ArrayList(message.ModelMessage) = .empty,
    steps: std.ArrayList(StepResult) = .empty,
    pending_deferred: std.StringHashMapUnmanaged([]const u8) = .empty,
    timed_out: std.atomic.Value(bool) = .init(false),
    last_model: ?provider.LanguageModel = null,

    fn nextId(self: *CallState) Allocator.Error![]const u8 {
        return self.id_generator.nextAlloc(self.arena);
    }
};

/// Shared pre-step approval replay used by blocking and streaming generation.
/// Returned messages borrow `context.arena`.
pub const InitialApprovalReplayContext = struct {
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    options: GenerateTextOptions,
    dispatcher: *telemetry.Dispatcher,
    id_generator: *provider_utils.IdGenerator,
    call_id: []const u8,
    initial_messages: []const message.ModelMessage,
    initial_instructions: ?prompt_api.Instructions,
    tools_context: ?std.json.Value,
    runtime_context: ?std.json.Value,
};

pub const InitialApprovalReplayResult = struct {
    current_messages: []const message.ModelMessage,
    response_messages: []const message.ModelMessage,
};

pub fn replayInitialToolApprovals(
    context: InitialApprovalReplayContext,
) provider.CallError!InitialApprovalReplayResult {
    var state: CallState = .{
        .io = context.io,
        .gpa = context.gpa,
        .arena = context.arena,
        .options = context.options,
        .dispatcher = context.dispatcher.*,
        .id_generator = context.id_generator.*,
        .call_id = context.call_id,
        .initial_messages = context.initial_messages,
        .initial_instructions = context.initial_instructions,
        .current_messages = context.initial_messages,
        .current_instructions = context.initial_instructions,
        .current_tools_context = context.tools_context,
        .current_runtime_context = context.runtime_context,
    };
    try replayToolApprovals(&state);
    context.id_generator.* = state.id_generator;
    return .{
        .current_messages = state.current_messages,
        .response_messages = try state.initial_response_messages.toOwnedSlice(context.arena),
    };
}

pub fn generateText(
    io: std.Io,
    gpa: Allocator,
    options: GenerateTextOptions,
) provider.CallError!GenerateTextResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var id_generator = try provider_utils.IdGenerator.initFromIo(io, .{}, options.diag);
    const call_id = try id_generator.nextAlloc(arena);
    const dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry);

    var state: CallState = .{
        .io = io,
        .gpa = gpa,
        .arena = arena,
        .options = options,
        .dispatcher = dispatcher,
        .id_generator = id_generator,
        .call_id = call_id,
        .initial_messages = &.{},
        .initial_instructions = null,
        .current_messages = &.{},
        .current_instructions = null,
        .current_tools_context = null,
        .current_runtime_context = null,
    };

    const total_timeout = if (options.timeout) |timeout| timeout.totalMs() else null;
    const data = runWithTimeout(
        CallData,
        io,
        total_timeout,
        &state,
        runCall,
        &state.timed_out,
    ) catch |err| {
        if (err == error.Canceled) {
            const abort_event: events.AbortEvent = .{
                .call_id = call_id,
                .reason = if (state.timed_out.load(.acquire)) "timeout" else "canceled",
            };
            dispatchEvent(
                events.AbortEvent,
                io,
                &state.dispatcher,
                options.callbacks.on_abort,
                abort_event,
                "onAbort",
            ) catch {};
            return error.Canceled;
        }

        const error_event: events.ErrorEvent = .{
            .call_id = call_id,
            .err = err,
            .diag = if (options.diag) |diag| diag else null,
        };
        dispatchEvent(
            events.ErrorEvent,
            io,
            &state.dispatcher,
            options.callbacks.on_error,
            error_event,
            "onError",
        ) catch {};
        return err;
    };

    return .{
        .arena_state = arena_state,
        .steps = data.steps,
        .total_usage = data.total_usage,
        .response_messages = data.response_messages,
        .initial_response_messages = data.initial_response_messages,
        .all_content = data.all_content,
        .all_files = data.all_files,
        .all_sources = data.all_sources,
        .all_tool_calls = data.all_tool_calls,
        .all_static_tool_calls = data.all_static_tool_calls,
        .all_dynamic_tool_calls = data.all_dynamic_tool_calls,
        .all_tool_results = data.all_tool_results,
        .all_static_tool_results = data.all_static_tool_results,
        .all_dynamic_tool_results = data.all_dynamic_tool_results,
        .all_warnings = data.all_warnings,
        .parsed_output = data.parsed_output,
    };
}

fn runCall(state: *CallState) provider.CallError!CallData {
    const options = state.options;
    const initial_model = try registry.resolveLanguageModel(options.model, options.diag);
    const standardized = try prompt_api.standardizePrompt(state.arena, .{
        .instructions = options.instructions,
        .prompt = options.prompt,
        .messages = options.messages,
        .allow_system_in_messages = options.allow_system_in_messages,
    }, options.diag);

    state.initial_messages = message.cloneModelMessages(state.arena, standardized.messages) catch |err|
        return mapAnyError(state, err, "failed to clone initial messages");
    state.initial_instructions = try cloneInstructions(state.arena, standardized.instructions);
    state.current_messages = state.initial_messages;
    state.current_instructions = state.initial_instructions;
    state.current_tools_context = try cloneOptionalJson(state.arena, options.tools_context);
    state.current_runtime_context = try cloneOptionalJson(state.arena, options.runtime_context);

    const call_settings = try prompt_api.prepareLanguageModelCallOptions(state.arena, .{
        .max_output_tokens = options.max_output_tokens,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .top_k = options.top_k,
        .presence_penalty = options.presence_penalty,
        .frequency_penalty = options.frequency_penalty,
        .stop_sequences = options.stop_sequences,
        .seed = options.seed,
        .reasoning = options.reasoning,
    }, options.diag);

    const start_event: events.GenerateTextStartEvent = .{
        .call_id = state.call_id,
        .provider_name = initial_model.provider(),
        .model_id = initial_model.modelId(),
        .instructions = instructionsText(state.initial_instructions),
        .messages = state.initial_messages,
        .tools = options.tools,
        .tool_choice = prompt_api.prepareToolChoice(options.tool_choice),
        .max_retries = options.max_retries,
        .timeout_ms = if (options.timeout) |timeout| timeout.totalMs() else null,
        .max_output_tokens = call_settings.max_output_tokens,
        .temperature = call_settings.temperature,
        .top_p = call_settings.top_p,
        .top_k = call_settings.top_k,
        .presence_penalty = call_settings.presence_penalty,
        .frequency_penalty = call_settings.frequency_penalty,
        .stop_sequences = call_settings.stop_sequences,
        .seed = call_settings.seed,
        .reasoning = call_settings.reasoning,
        .provider_options = options.provider_options,
        .runtime_context = state.current_runtime_context,
        .tools_context = state.current_tools_context,
    };
    try dispatchEvent(
        events.GenerateTextStartEvent,
        state.io,
        &state.dispatcher,
        options.callbacks.on_start,
        start_event,
        "onStart",
    );

    const approval_replay = try replayInitialToolApprovals(.{
        .io = state.io,
        .gpa = state.gpa,
        .arena = state.arena,
        .options = state.options,
        .dispatcher = &state.dispatcher,
        .id_generator = &state.id_generator,
        .call_id = state.call_id,
        .initial_messages = state.initial_messages,
        .initial_instructions = state.initial_instructions,
        .tools_context = state.current_tools_context,
        .runtime_context = state.current_runtime_context,
    });
    state.current_messages = approval_replay.current_messages;
    for (approval_replay.response_messages) |response_message| {
        try state.initial_response_messages.append(state.arena, response_message);
        try state.accumulated_response_messages.append(state.arena, response_message);
    }

    var natural_continue = true;
    while (natural_continue) {
        const step_timeout = if (options.timeout) |timeout| timeout.stepMs() else null;
        const outcome = try runWithTimeout(
            StepOutcome,
            state.io,
            step_timeout,
            StepContext{ .state = state, .call_settings = call_settings },
            runStep,
            &state.timed_out,
        );

        try state.steps.append(state.arena, outcome.step);
        const stored_step = &state.steps.items[state.steps.items.len - 1];
        for (stored_step.response.messages) |response_message| {
            try state.accumulated_response_messages.append(state.arena, response_message);
        }

        state.current_instructions = outcome.next_instructions;
        state.current_messages = outcome.next_messages;
        state.current_runtime_context = outcome.next_runtime_context;
        state.current_tools_context = outcome.next_tools_context;
        state.last_model = outcome.model;

        const step_end_event: events.StepEndEvent = .{
            .call_id = state.call_id,
            .step_number = stored_step.step_number,
            .step_result = stored_step,
        };
        try dispatchEvent(
            events.StepEndEvent,
            state.io,
            &state.dispatcher,
            options.callbacks.on_step_end,
            step_end_event,
            "onStepEnd",
        );

        natural_continue = outcome.should_continue;
        if (natural_continue and try stopConditionMet(state)) natural_continue = false;
    }

    const steps = try state.steps.toOwnedSlice(state.arena);
    var total_usage = types.zero_usage;
    for (steps) |step| total_usage = types.addUsage(total_usage, step.usage);

    const aggregates = try aggregateResults(state.arena, steps);
    var parsed_output: ?OutputValue = null;
    const final_step = &steps[steps.len - 1];
    if (options.output) |output| {
        if (final_step.finish_reason.unified == .stop) {
            parsed_output = try output.parseComplete(state.arena, final_step.text(), &.{
                .response = final_step.response,
                .usage = total_usage,
                .finish_reason = final_step.finish_reason,
            });
        }
    }

    const response_messages = try accumulatedResultMessages(state, steps);
    const end_event: events.EndEvent = .{
        .call_id = state.call_id,
        .step_number = final_step.step_number,
        .model = state.last_model orelse initial_model,
        .text = final_step.text(),
        .content = aggregates.content,
        .finish_reason = final_step.finish_reason,
        .usage = total_usage,
        .warnings = aggregates.warnings,
        .response_messages = response_messages,
        .steps = steps,
        .final_step = final_step,
        .runtime_context = final_step.runtime_context,
        .tools_context = final_step.tools_context,
    };
    try dispatchEvent(
        events.EndEvent,
        state.io,
        &state.dispatcher,
        options.callbacks.on_end,
        end_event,
        "onEnd",
    );

    return .{
        .steps = steps,
        .total_usage = total_usage,
        .response_messages = response_messages,
        .initial_response_messages = try state.initial_response_messages.toOwnedSlice(state.arena),
        .all_content = aggregates.content,
        .all_files = aggregates.files,
        .all_sources = aggregates.sources,
        .all_tool_calls = aggregates.tool_calls,
        .all_static_tool_calls = aggregates.static_tool_calls,
        .all_dynamic_tool_calls = aggregates.dynamic_tool_calls,
        .all_tool_results = aggregates.tool_results,
        .all_static_tool_results = aggregates.static_tool_results,
        .all_dynamic_tool_results = aggregates.dynamic_tool_results,
        .all_warnings = aggregates.warnings,
        .parsed_output = parsed_output,
    };
}

const StepContext = struct {
    state: *CallState,
    call_settings: prompt_api.PreparedLanguageModelCallOptions,
};

const StepOutcome = struct {
    step: StepResult,
    model: provider.LanguageModel,
    next_messages: []const message.ModelMessage,
    next_instructions: ?prompt_api.Instructions,
    next_runtime_context: ?std.json.Value,
    next_tools_context: ?std.json.Value,
    should_continue: bool,
};

fn runStep(context: StepContext) provider.CallError!StepOutcome {
    return executeStep(context.state, context.call_settings);
}

const ModelAttempt = struct {
    state: *CallState,
    model: provider.LanguageModel,
    options: *const provider.CallOptions,

    fn call(
        self: *ModelAttempt,
        io: std.Io,
        _: u32,
        diag: ?*provider.Diagnostics,
    ) anyerror!provider.GenerateResult {
        const scope = try self.state.dispatcher.enterModelCall(self.state.call_id);
        defer scope.exit();
        return self.model.doGenerate(io, self.state.arena, self.options, diag);
    }
};

const ApprovalResolution = struct {
    requests: []const types.ToolApprovalRequest,
    responses: []const types.ToolApprovalResponse,
    blocked: std.StringHashMapUnmanaged(void),
    denied_count: usize,
};

const ClientToolOutput = tool_common.ClientToolOutput;

fn executeStep(
    state: *CallState,
    call_settings: prompt_api.PreparedLanguageModelCallOptions,
) provider.CallError!StepOutcome {
    const options = state.options;
    const step_number = state.steps.items.len;
    const base_model = try registry.resolveLanguageModel(options.model, options.diag);
    const prepare_options: PrepareStepOptions = .{
        .steps = state.steps.items,
        .step_number = step_number,
        .model = base_model,
        .instructions = state.current_instructions,
        .initial_instructions = state.initial_instructions,
        .messages = state.current_messages,
        .initial_messages = state.initial_messages,
        .response_messages = state.accumulated_response_messages.items,
        .tools_context = state.current_tools_context,
        .runtime_context = state.current_runtime_context,
    };
    const prepared = if (options.prepare_step) |prepare|
        try prepare.prepare(state.io, state.arena, &prepare_options)
    else
        null;

    const step_model_ref = if (prepared) |value| value.model orelse options.model else options.model;
    const step_model = try registry.resolveLanguageModel(step_model_ref, options.diag);
    const step_instructions = try cloneInstructions(
        state.arena,
        if (prepared) |value| value.instructions orelse state.current_instructions else state.current_instructions,
    );
    const step_messages = if (prepared) |value|
        if (value.messages) |messages_value|
            message.cloneModelMessages(state.arena, messages_value) catch |err|
                return mapAnyError(state, err, "failed to clone prepareStep messages")
        else
            state.current_messages
    else
        state.current_messages;
    const step_runtime_context = if (prepared) |value|
        if (value.runtime_context) |runtime| try provider_utils.cloneJsonValue(state.arena, runtime) else state.current_runtime_context
    else
        state.current_runtime_context;
    const step_tools_context = if (prepared) |value|
        if (value.tools_context) |tools_context| try provider_utils.cloneJsonValue(state.arena, tools_context) else state.current_tools_context
    else
        state.current_tools_context;
    const active_names = if (prepared) |value| value.active_tools orelse options.active_tools else options.active_tools;
    const tool_order = if (prepared) |value| value.tool_order orelse options.tool_order else options.tool_order;
    const selected_tools = try filterActiveTools(state.arena, options.tools, active_names);
    const provider_tools = prompt_api.prepareTools(
        state.arena,
        selected_tools,
        tool_order,
        step_tools_context,
        options.diag,
    ) catch |err| return mapAnyError(state, err, "failed to prepare tools");
    const selected_choice = if (prepared) |value| value.tool_choice orelse options.tool_choice else options.tool_choice;
    const provider_choice = prompt_api.prepareToolChoice(selected_choice);
    const step_provider_options = try mergeOptionalJson(
        state.arena,
        options.provider_options,
        if (prepared) |value| value.provider_options else null,
    );

    const provider_prompt = prompt_api.convertToLanguageModelPrompt(
        state.io,
        state.gpa,
        state.arena,
        .{
            .prompt = .{ .instructions = step_instructions, .messages = step_messages },
            .model = step_model,
            .provider_name = step_model.provider(),
        },
        options.diag,
    ) catch |err| return mapAnyError(state, err, "failed to convert prompt");

    const response_format = if (options.output) |output| output.response_format else null;
    const model_options: provider.CallOptions = .{
        .prompt = provider_prompt,
        .max_output_tokens = call_settings.max_output_tokens,
        .temperature = call_settings.temperature,
        .stop_sequences = call_settings.stop_sequences,
        .top_p = call_settings.top_p,
        .top_k = call_settings.top_k,
        .presence_penalty = call_settings.presence_penalty,
        .frequency_penalty = call_settings.frequency_penalty,
        .response_format = response_format,
        .seed = call_settings.seed,
        .tools = provider_tools,
        .tool_choice = provider_choice,
        .headers = options.headers,
        .reasoning = call_settings.reasoning,
        .provider_options = step_provider_options,
    };

    const step_start_event: events.StepStartEvent = .{
        .call_id = state.call_id,
        .provider_name = step_model.provider(),
        .model_id = step_model.modelId(),
        .step_number = step_number,
        .instructions = instructionsText(step_instructions),
        .messages = step_messages,
        .prompt_messages = provider_prompt,
        .tools = options.tools,
        .step_tools = provider_tools,
        .tool_choice = provider_choice,
        .previous_steps = state.steps.items,
        .provider_options = step_provider_options,
        .runtime_context = step_runtime_context,
        .tools_context = step_tools_context,
    };
    try dispatchEvent(
        events.StepStartEvent,
        state.io,
        &state.dispatcher,
        options.callbacks.on_step_start,
        step_start_event,
        "onStepStart",
    );

    const model_start_event: events.LanguageModelCallStartEvent = .{
        .call_id = state.call_id,
        .provider_name = step_model.provider(),
        .model_id = step_model.modelId(),
        .instructions = instructionsText(step_instructions),
        .messages = step_messages,
        .tools = provider_tools,
        .options = &model_options,
    };
    try dispatchEvent(
        events.LanguageModelCallStartEvent,
        state.io,
        &state.dispatcher,
        options.callbacks.on_language_model_call_start,
        model_start_event,
        "onLanguageModelCallStart",
    );

    const step_started = std.Io.Timestamp.now(state.io, .awake);
    var attempt: ModelAttempt = .{ .state = state, .model = step_model, .options = &model_options };
    const generated = provider_utils.retryWithOptions(
        provider.GenerateResult,
        state.io,
        .{
            .policy = .{ .max_retries = options.max_retries },
            .get_delay_ms = retryDelayInMs,
        },
        &attempt,
        ModelAttempt.call,
        options.diag,
    ) catch |err| return mapAnyError(state, err, "language model call failed");
    const model_finished = std.Io.Timestamp.now(state.io, .awake);
    const response_time_ms = elapsedMilliseconds(step_started, model_finished);

    const parsed_calls = try parseToolCalls(
        state,
        generated.content,
        step_instructions,
        step_messages,
    );
    const model_call_content = try assembleContent(
        state,
        generated.content,
        parsed_calls,
        &.{},
        &.{},
        &.{},
    );
    const model_end_event: events.LanguageModelCallEndEvent = .{
        .call_id = state.call_id,
        .provider_name = step_model.provider(),
        .model_id = step_model.modelId(),
        .finish_reason = generated.finish_reason,
        .usage = generated.usage,
        .content = model_call_content,
        .response_id = if (generated.response) |response| response.id else null,
        .performance = .{
            .response_time_ms = response_time_ms,
            .effective_output_tokens_per_second = tokensPerSecond(generated.usage.output_tokens.total, response_time_ms),
            .effective_total_tokens_per_second = tokensPerSecond(
                types.addTokenCounts(generated.usage.input_tokens.total, generated.usage.output_tokens.total),
                response_time_ms,
            ),
        },
    };
    try dispatchEvent(
        events.LanguageModelCallEndEvent,
        state.io,
        &state.dispatcher,
        options.callbacks.on_language_model_call_end,
        model_end_event,
        "onLanguageModelCallEnd",
    );

    logger.logWarnings(state.arena, .{
        .warnings = generated.warnings,
        .provider_name = step_model.provider(),
        .model = step_model.modelId(),
    });

    for (parsed_calls) |call| try notifyInputAvailable(state, call, step_messages, step_tools_context);
    const approvals = try resolveStepApprovals(state, parsed_calls, step_messages, step_tools_context);

    var client_calls: std.ArrayList(TypedToolCall) = .empty;
    defer client_calls.deinit(state.arena);
    var outputs: std.ArrayList(ClientToolOutput) = .empty;
    defer outputs.deinit(state.arena);
    for (parsed_calls) |call| {
        if (call.provider_executed) continue;
        try client_calls.append(state.arena, call);
        if (call.invalid and call.dynamic) {
            const retained_error = call.err.?;
            try outputs.append(state.arena, .{ .tool_error = .{
                .tool_call_id = call.tool_call_id,
                .tool_name = call.tool_name,
                .input = call.input,
                .error_value = .{ .string = retained_error.message },
                .error_code = retained_error.err,
                .provider_executed = false,
                .provider_metadata = call.provider_metadata,
                .tool_metadata = call.tool_metadata,
                .dynamic = true,
            } });
        }
    }

    var executable: std.ArrayList(TypedToolCall) = .empty;
    defer executable.deinit(state.arena);
    for (client_calls.items) |call| {
        if (call.invalid or approvals.blocked.contains(call.tool_call_id)) continue;
        try executable.append(state.arena, call);
    }
    const execution = try executeToolCalls(
        state,
        executable.items,
        step_messages,
        step_tools_context,
    );
    try outputs.appendSlice(state.arena, execution.outputs);

    try updateDeferredCalls(state, parsed_calls, generated.content);
    const step_content = try assembleContent(
        state,
        generated.content,
        parsed_calls,
        outputs.items,
        approvals.requests,
        approvals.responses,
    );
    const response_messages_uncloned = try toResponseMessages(state, step_content);
    const response_messages = message.cloneModelMessages(state.arena, response_messages_uncloned) catch |err|
        return mapAnyError(state, err, "failed to clone response messages");
    const request_body = if (generated.request) |request| try cloneOptionalJson(state.arena, request.body) else null;
    const generated_response = generated.response orelse provider.ResponseInfo{};
    const response_id = if (generated_response.id) |value| try state.arena.dupe(u8, value) else try state.nextId();
    const response_model_id = if (generated_response.model_id) |value| try state.arena.dupe(u8, value) else try state.arena.dupe(u8, step_model.modelId());
    const response_timestamp = generated_response.timestamp_ms orelse timestampMilliseconds(state.io);
    const response_headers = try cloneHeaders(state.arena, generated_response.headers);
    const response_body = try cloneOptionalJson(state.arena, generated_response.body);

    const step_finished = std.Io.Timestamp.now(state.io, .awake);
    var step = StepResult{
        .call_id = state.call_id,
        .step_number = step_number,
        .model = .{
            .provider_name = try state.arena.dupe(u8, step_model.provider()),
            .model_id = try state.arena.dupe(u8, step_model.modelId()),
        },
        .tools_context = try cloneOptionalJson(state.arena, step_tools_context),
        .runtime_context = try cloneOptionalJson(state.arena, step_runtime_context),
        .content = step_content,
        .finish_reason = .{
            .unified = generated.finish_reason.unified,
            .raw = if (generated.finish_reason.raw) |raw| try state.arena.dupe(u8, raw) else null,
        },
        .usage = try cloneUsage(state.arena, generated.usage),
        .performance = .{
            .effective_output_tokens_per_second = tokensPerSecond(generated.usage.output_tokens.total, response_time_ms),
            .effective_total_tokens_per_second = tokensPerSecond(
                types.addTokenCounts(generated.usage.input_tokens.total, generated.usage.output_tokens.total),
                response_time_ms,
            ),
            .step_time_ms = elapsedMilliseconds(step_started, step_finished),
            .response_time_ms = response_time_ms,
            .tool_execution_ms = execution.timings,
        },
        .warnings = try cloneWarnings(state.arena, generated.warnings),
        .request = .{
            .body = request_body,
            .messages = message.cloneModelMessages(state.arena, step_messages) catch |err|
                return mapAnyError(state, err, "failed to clone request messages"),
        },
        .response = .{
            .id = response_id,
            .timestamp_ms = response_timestamp,
            .model_id = response_model_id,
            .headers = response_headers,
            .body = response_body,
            .messages = response_messages,
        },
        .provider_metadata = try cloneOptionalJson(state.arena, generated.provider_metadata),
    };
    try step.derive(state.arena);

    const next_messages = try concatMessages(state.arena, step_messages, response_messages);
    const should_continue = tool_common.shouldContinue(
        client_calls.items.len,
        outputs.items.len,
        approvals.denied_count,
        state.pending_deferred.count(),
    );

    return .{
        .step = step,
        .model = step_model,
        .next_messages = next_messages,
        .next_instructions = step_instructions,
        .next_runtime_context = step_runtime_context,
        .next_tools_context = step_tools_context,
        .should_continue = should_continue,
    };
}

fn parseToolCalls(
    state: *CallState,
    content: []const provider.Content,
    instructions: ?prompt_api.Instructions,
    messages: []const message.ModelMessage,
) provider.CallError![]const TypedToolCall {
    var parsed: std.ArrayList(TypedToolCall) = .empty;
    defer parsed.deinit(state.arena);
    for (content) |part| switch (part) {
        .tool_call => |call| try parsed.append(
            state.arena,
            try parseToolCall(state, call, instructions, messages),
        ),
        else => {},
    };
    return parsed.toOwnedSlice(state.arena);
}

fn parseToolCall(
    state: *CallState,
    original: provider.GeneratedToolCall,
    instructions: ?prompt_api.Instructions,
    messages: []const message.ModelMessage,
) provider.CallError!TypedToolCall {
    return tool_common.parseToolCall(.{
        .io = state.io,
        .arena = state.arena,
        .tools = state.options.tools,
        .repair_tool_call = state.options.repair_tool_call,
        .refine_tool_input = state.options.refine_tool_input,
        .instructions = instructions,
        .messages = messages,
    }, original);
}

fn notifyInputAvailable(
    state: *CallState,
    call: TypedToolCall,
    messages: []const message.ModelMessage,
    tools_context: ?std.json.Value,
) provider.CallError!void {
    const named = findTool(state.options.tools, call.tool_name) orelse return;
    const callback = named.tool.on_input_available orelse return;
    const context = try validatedToolContext(state, named, tools_context);
    callback.callback(callback.ctx, call.input, .{
        .tool_call_id = call.tool_call_id,
        .messages = messages,
        .context = context,
    }) catch {};
}

fn resolveStepApprovals(
    state: *CallState,
    calls: []const TypedToolCall,
    messages: []const message.ModelMessage,
    tools_context: ?std.json.Value,
) provider.CallError!ApprovalResolution {
    var requests: std.ArrayList(types.ToolApprovalRequest) = .empty;
    defer requests.deinit(state.arena);
    var responses: std.ArrayList(types.ToolApprovalResponse) = .empty;
    defer responses.deinit(state.arena);
    var blocked: std.StringHashMapUnmanaged(void) = .empty;
    var denied_count: usize = 0;

    for (calls) |call| {
        if (call.invalid) continue;
        const named = findTool(state.options.tools, call.tool_name) orelse continue;
        const decision = tool_common.resolveToolApproval(.{
            .arena = state.arena,
            .named = named,
            .tool_call = call,
            .messages = messages,
            .tools_context = tools_context,
            .diag = state.options.diag,
        }) catch |err| {
            setInvalidApproval(state, call.tool_call_id);
            return mapAnyError(state, err, "tool approval resolver failed");
        };
        if (decision == .not_applicable or decision == .approved) continue;

        const approval_id = try state.nextId();
        const signature = if (state.options.tool_approval_secret) |secret|
            try approval_signature.sign(
                state.arena,
                secret,
                approval_id,
                call.tool_call_id,
                call.tool_name,
                call.input,
            )
        else
            null;
        try requests.append(state.arena, .{
            .approval_id = approval_id,
            .tool_call = call,
            .is_automatic = decision == .denied,
            .signature = signature,
        });
        try blocked.put(state.arena, call.tool_call_id, {});
        if (decision == .denied) {
            try responses.append(state.arena, .{
                .approval_id = approval_id,
                .tool_call = call,
                .approved = false,
                .reason = decision.denied,
                .provider_executed = call.provider_executed,
            });
            denied_count += 1;
        }
    }

    return .{
        .requests = try requests.toOwnedSlice(state.arena),
        .responses = try responses.toOwnedSlice(state.arena),
        .blocked = blocked,
        .denied_count = denied_count,
    };
}

fn validatedToolContext(
    state: *CallState,
    named: *const tool_api.NamedTool,
    tools_context: ?std.json.Value,
) provider.CallError!?std.json.Value {
    return tool_common.validatedToolContext(state.arena, named, tools_context, state.options.diag);
}

fn updateDeferredCalls(
    state: *CallState,
    calls: []const TypedToolCall,
    content: []const provider.Content,
) Allocator.Error!void {
    for (calls) |call| {
        if (!call.provider_executed) continue;
        const named = findTool(state.options.tools, call.tool_name) orelse continue;
        if (!named.tool.supports_deferred_results) continue;
        var has_result = false;
        for (content) |part| switch (part) {
            .tool_result => |result| if (std.mem.eql(u8, result.tool_call_id, call.tool_call_id)) {
                has_result = true;
                break;
            },
            else => {},
        };
        if (!has_result) try state.pending_deferred.put(state.arena, call.tool_call_id, call.tool_name);
    }
    for (content) |part| switch (part) {
        .tool_result => |result| _ = state.pending_deferred.remove(result.tool_call_id),
        else => {},
    };
}

fn findTool(tools: tool_api.ToolSet, name: []const u8) ?*const tool_api.NamedTool {
    return tool_common.findTool(tools, name);
}

fn assembleContent(
    state: *CallState,
    provider_content: []const provider.Content,
    calls: []const TypedToolCall,
    outputs: []const ClientToolOutput,
    approval_requests: []const types.ToolApprovalRequest,
    approval_responses: []const types.ToolApprovalResponse,
) provider.CallError![]const ContentPart {
    var content: std.ArrayList(ContentPart) = .empty;
    defer content.deinit(state.arena);
    var outputs_before: std.ArrayList(ClientToolOutput) = .empty;
    defer outputs_before.deinit(state.arena);
    var outputs_after: std.ArrayList(ClientToolOutput) = .empty;
    defer outputs_after.deinit(state.arena);

    for (provider_content) |part| switch (part) {
        .text => |value| try content.append(state.arena, .{ .text = .{
            .text = try state.arena.dupe(u8, value.text),
            .provider_metadata = try cloneOptionalJson(state.arena, value.provider_metadata),
        } }),
        .reasoning => |value| try content.append(state.arena, .{ .reasoning = .{
            .text = try state.arena.dupe(u8, value.text),
            .provider_metadata = try cloneOptionalJson(state.arena, value.provider_metadata),
        } }),
        .custom => |value| try content.append(state.arena, .{ .custom = .{
            .kind = try state.arena.dupe(u8, value.kind),
            .provider_metadata = try cloneOptionalJson(state.arena, value.provider_metadata),
        } }),
        .file => |value| try content.append(state.arena, .{ .file = try cloneGeneratedFile(state.arena, value) }),
        .reasoning_file => |value| try content.append(state.arena, .{ .reasoning_file = try cloneReasoningFile(state.arena, value) }),
        .source => |value| try content.append(state.arena, .{ .source = try cloneSource(state.arena, value) }),
        .tool_call => |value| {
            const call = findCall(calls, value.tool_call_id) orelse {
                setInvalidResponse(state, "Parsed tool call not found");
                return error.InvalidResponseDataError;
            };
            try content.append(state.arena, .{ .tool_call = call.* });
        },
        .tool_result => |value| {
            const matching_call = findCall(calls, value.tool_call_id);
            const named = findTool(state.options.tools, value.tool_name);
            if (matching_call == null and (named == null or !named.?.tool.supports_deferred_results)) {
                const error_message = try std.fmt.allocPrint(
                    state.arena,
                    "Tool call {s} not found.",
                    .{value.tool_call_id},
                );
                setInvalidResponse(state, error_message);
                return error.InvalidResponseDataError;
            }
            const input = if (matching_call) |call| try provider_utils.cloneJsonValue(state.arena, call.input) else null;
            const dynamic = value.dynamic == true or if (matching_call) |call| call.dynamic else false;
            const metadata = if (matching_call) |call| call.tool_metadata else if (named) |tool_value| tool_value.tool.metadata else null;
            if (value.is_error == true) {
                try content.append(state.arena, .{ .tool_error = .{
                    .tool_call_id = try state.arena.dupe(u8, value.tool_call_id),
                    .tool_name = try state.arena.dupe(u8, value.tool_name),
                    .input = input,
                    .error_value = try provider_utils.cloneJsonValue(state.arena, value.result),
                    .provider_executed = true,
                    .provider_metadata = try cloneOptionalJson(state.arena, value.provider_metadata),
                    .tool_metadata = try cloneOptionalJson(state.arena, metadata),
                    .dynamic = dynamic,
                } });
            } else {
                try content.append(state.arena, .{ .tool_result = .{
                    .tool_call_id = try state.arena.dupe(u8, value.tool_call_id),
                    .tool_name = try state.arena.dupe(u8, value.tool_name),
                    .input = input,
                    .output = try provider_utils.cloneJsonValue(state.arena, value.result),
                    .provider_executed = true,
                    .provider_metadata = try cloneOptionalJson(state.arena, value.provider_metadata),
                    .tool_metadata = try cloneOptionalJson(state.arena, metadata),
                    .dynamic = dynamic,
                    .preliminary = value.preliminary == true,
                } });
            }
        },
        .tool_approval_request => |value| {
            const call = findCall(calls, value.tool_call_id) orelse {
                setToolApprovalNotFound(state, value.tool_call_id, value.approval_id);
                return error.ToolCallNotFoundForApprovalError;
            };
            try content.append(state.arena, .{ .tool_approval_request = .{
                .approval_id = try state.arena.dupe(u8, value.approval_id),
                .tool_call = call.*,
            } });
        },
    };

    for (outputs) |output| {
        var has_approval_response = false;
        for (approval_responses) |response| {
            if (std.mem.eql(u8, response.tool_call.tool_call_id, output.toolCallId())) {
                has_approval_response = true;
                break;
            }
        }
        if (has_approval_response) {
            try outputs_after.append(state.arena, output);
        } else {
            try outputs_before.append(state.arena, output);
        }
    }
    for (outputs_before.items) |output| try appendClientOutput(&content, state.arena, output);
    for (approval_requests) |request| try content.append(state.arena, .{ .tool_approval_request = request });
    for (approval_responses) |response| try content.append(state.arena, .{ .tool_approval_response = response });
    for (outputs_after.items) |output| try appendClientOutput(&content, state.arena, output);
    return content.toOwnedSlice(state.arena);
}

fn appendClientOutput(
    content: *std.ArrayList(ContentPart),
    arena: Allocator,
    output: ClientToolOutput,
) Allocator.Error!void {
    switch (output) {
        .result => |value| try content.append(arena, .{ .tool_result = value }),
        .tool_error => |value| try content.append(arena, .{ .tool_error = value }),
    }
}

fn findCall(calls: []const TypedToolCall, id: []const u8) ?*const TypedToolCall {
    for (calls) |*call| if (std.mem.eql(u8, call.tool_call_id, id)) return call;
    return null;
}

fn toResponseMessages(
    state: *CallState,
    input_content: []const ContentPart,
) provider.CallError![]const message.ModelMessage {
    return response_message_builder.toResponseMessages(
        state.arena,
        state.options.tools,
        input_content,
    ) catch |err| return mapAnyError(state, err, "failed to convert response messages");
}

const ToolExecutionBatch = struct {
    outputs: []const ClientToolOutput,
    timings: []const types.ToolExecutionTiming,
};

const ToolOperationContext = struct {
    job: *ToolJob,

    fn run(self: ToolOperationContext) provider.CallError!?tool_common.ExecutionResult {
        return tool_common.executeToolCall(.{
            .io = self.job.state.io,
            .arena = self.job.arena_state.allocator(),
            .call = self.job.call,
            .named = self.job.named,
            .messages = self.job.messages,
            .tool_context = self.job.tool_context,
        }) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.Closed => error.InvalidStreamPartError,
        };
    }
};

const ToolJob = struct {
    state: *CallState,
    call: TypedToolCall,
    named: *const tool_api.NamedTool,
    messages: []const message.ModelMessage,
    tool_context: ?std.json.Value,
    timeout_ms: ?u64,
    arena_state: std.heap.ArenaAllocator,
    hook_scope: ?telemetry.HookScope = null,
    scope_exited: std.atomic.Value(bool) = .init(false),
    output: ?ClientToolOutput = null,
    duration_ms: f64 = 0,
    fatal_error: ?provider.CallError = null,

    fn run(self: *ToolJob) void {
        defer self.exitScope();
        const start_event: events.ToolExecutionStartEvent = .{
            .call_id = self.state.call_id,
            .tool_call = eventToolCall(self.call),
            .messages = self.messages,
            .tool_context = self.tool_context,
        };
        dispatchEvent(
            events.ToolExecutionStartEvent,
            self.state.io,
            &self.state.dispatcher,
            self.state.options.callbacks.on_tool_execution_start,
            start_event,
            "onToolExecutionStart",
        ) catch |err| {
            self.fatal_error = err;
            return;
        };

        const started = std.Io.Timestamp.now(self.state.io, .awake);
        const operation = runWithTimeout(
            ?tool_common.ExecutionResult,
            self.state.io,
            self.timeout_ms,
            ToolOperationContext{ .job = self },
            ToolOperationContext.run,
            &self.state.timed_out,
        ) catch |err| {
            self.duration_ms = elapsedMilliseconds(started, std.Io.Timestamp.now(self.state.io, .awake));
            self.fatal_error = err;
            return;
        };
        const result = operation orelse return;
        self.duration_ms = result.tool_execution_ms;
        self.output = result.output;
        const event_output: events.ToolExecutionOutput = switch (result.output) {
            .result => |value| .{ .result = value.output },
            .tool_error => |value| .{ .err = value.error_code orelse error.InvalidToolInputError },
        };

        const end_event: events.ToolExecutionEndEvent = .{
            .call_id = self.state.call_id,
            .tool_call = eventToolCall(self.call),
            .messages = self.messages,
            .tool_context = self.tool_context,
            .tool_output = event_output,
            .tool_execution_ms = self.duration_ms,
        };
        dispatchEvent(
            events.ToolExecutionEndEvent,
            self.state.io,
            &self.state.dispatcher,
            self.state.options.callbacks.on_tool_execution_end,
            end_event,
            "onToolExecutionEnd",
        ) catch |err| {
            self.fatal_error = err;
        };
    }

    fn exitScope(self: *ToolJob) void {
        const scope = self.hook_scope orelse return;
        if (self.scope_exited.swap(true, .acq_rel)) return;
        scope.exit();
    }
};

fn executeToolCalls(
    state: *CallState,
    calls: []const TypedToolCall,
    messages: []const message.ModelMessage,
    tools_context: ?std.json.Value,
) provider.CallError!ToolExecutionBatch {
    const jobs = try state.arena.alloc(ToolJob, calls.len);
    var job_count: usize = 0;
    defer for (jobs[0..job_count]) |*job| job.arena_state.deinit();
    for (calls) |call| {
        const named = findTool(state.options.tools, call.tool_name) orelse continue;
        if (named.tool.execute == null) continue;
        jobs[job_count] = .{
            .state = state,
            .call = call,
            .named = named,
            .messages = messages,
            .tool_context = try validatedToolContext(state, named, tools_context),
            .timeout_ms = if (state.options.timeout) |timeout| timeout.toolMs(call.tool_name) else null,
            .arena_state = .init(state.gpa),
        };
        job_count += 1;
    }
    const active_jobs = jobs[0..job_count];
    errdefer for (active_jobs) |*job| job.exitScope();
    for (active_jobs) |*job| {
        job.hook_scope = try state.dispatcher.enterToolExecution(state.call_id);
    }

    var group: std.Io.Group = .init;
    defer group.cancel(state.io);
    var warned = false;
    for (active_jobs) |*job| {
        group.concurrent(state.io, ToolJob.run, .{job}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                if (!warned) {
                    std.log.warn("tool execution concurrency unavailable; falling back to async scheduling", .{});
                    warned = true;
                }
                group.async(state.io, ToolJob.run, .{job});
            },
        };
    }
    try group.await(state.io);

    var outputs: std.ArrayList(ClientToolOutput) = .empty;
    defer outputs.deinit(state.arena);
    var timings: std.ArrayList(types.ToolExecutionTiming) = .empty;
    defer timings.deinit(state.arena);
    for (active_jobs) |*job| {
        if (job.fatal_error) |err| return err;
        const output = job.output orelse continue;
        const cloned = try tool_common.cloneClientOutput(state.arena, output);
        try outputs.append(state.arena, cloned);
        try timings.append(state.arena, .{
            .tool_call_id = cloned.toolCallId(),
            .milliseconds = job.duration_ms,
        });
    }
    return .{
        .outputs = try outputs.toOwnedSlice(state.arena),
        .timings = try timings.toOwnedSlice(state.arena),
    };
}

fn eventToolCall(call: TypedToolCall) events.ToolCall {
    return .{
        .tool_call_id = call.tool_call_id,
        .tool_name = call.tool_name,
        .input = call.input,
        .provider_executed = call.provider_executed,
        .dynamic = call.dynamic,
    };
}

const CollectedApproval = struct {
    request: message.ToolApprovalRequest,
    response: message.ToolApprovalResponse,
    call: TypedToolCall,
};

const CollectedApprovals = struct {
    approved: []const CollectedApproval,
    denied: []const CollectedApproval,
};

fn replayToolApprovals(state: *CallState) provider.CallError!void {
    const collected = try collectToolApprovals(state);
    var approved_calls: std.ArrayList(TypedToolCall) = .empty;
    defer approved_calls.deinit(state.arena);

    for (collected.approved) |approval| {
        if (state.options.tool_approval_secret) |secret| {
            const signature = approval.request.signature orelse {
                setInvalidApprovalSignature(
                    state,
                    approval.request.approval_id,
                    approval.call.tool_call_id,
                    "missing signature",
                );
                return error.InvalidToolApprovalSignatureError;
            };
            if (!try approval_signature.verify(
                state.arena,
                secret,
                signature,
                approval.request.approval_id,
                approval.call.tool_call_id,
                approval.call.tool_name,
                approval.call.input,
            )) {
                setInvalidApprovalSignature(
                    state,
                    approval.request.approval_id,
                    approval.call.tool_call_id,
                    "invalid signature",
                );
                return error.InvalidToolApprovalSignatureError;
            }
        }

        const named = findTool(state.options.tools, approval.call.tool_name);
        if (named) |selected| {
            if (selected.tool.execute != null) {
                if (selected.tool.input_schema.validator) |validator| {
                    validator.validate(state.arena, approval.call.input, state.options.diag) catch {
                        setInvalidToolInput(state, approval.call.tool_name, approval.call.input, "approved input failed schema validation");
                        return error.InvalidToolInputError;
                    };
                }
            }
            _ = try approvalStillAllowed(state, selected, approval.call);
        }
        if (!approval.call.provider_executed) try approved_calls.append(state.arena, approval.call);
    }

    const executed = try executeToolCalls(
        state,
        approved_calls.items,
        state.initial_messages,
        state.current_tools_context,
    );
    var tool_parts: std.ArrayList(message.ToolContentPart) = .empty;
    defer tool_parts.deinit(state.arena);
    for (executed.outputs) |output| switch (output) {
        .result => |value| {
            const model_output = prompt_api.createToolModelOutput(
                state.arena,
                value.tool_call_id,
                value.input orelse std.json.Value.null,
                value.output,
                if (findTool(state.options.tools, value.tool_name)) |named| &named.tool else null,
                .none,
            ) catch |err| return mapAnyError(state, err, "failed to convert approved tool result");
            try tool_parts.append(state.arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .output = model_output,
            } });
        },
        .tool_error => |value| {
            const model_output = prompt_api.createToolModelOutput(
                state.arena,
                value.tool_call_id,
                value.input orelse std.json.Value.null,
                value.error_value,
                if (findTool(state.options.tools, value.tool_name)) |named| &named.tool else null,
                .text,
            ) catch |err| return mapAnyError(state, err, "failed to convert approved tool error");
            try tool_parts.append(state.arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .output = model_output,
            } });
        },
    };
    for (collected.denied) |approval| {
        try tool_parts.append(state.arena, .{ .tool_result = .{
            .tool_call_id = approval.call.tool_call_id,
            .tool_name = approval.call.tool_name,
            .output = .{ .execution_denied = .{ .reason = approval.response.reason } },
        } });
    }

    if (tool_parts.items.len == 0) return;
    const initial_message: message.ModelMessage = .{ .tool = .{
        .content = try tool_parts.toOwnedSlice(state.arena),
    } };
    try state.initial_response_messages.append(state.arena, initial_message);
    try state.accumulated_response_messages.append(state.arena, initial_message);
    state.current_messages = try concatMessages(state.arena, state.initial_messages, &.{initial_message});
}

fn approvalStillAllowed(
    state: *CallState,
    named: *const tool_api.NamedTool,
    call: TypedToolCall,
) provider.CallError!bool {
    return switch (named.tool.needs_approval) {
        .no => true,
        .yes => true,
        .resolver => |resolver| resolver.resolve(call.input, .{
            .tool_call_id = call.tool_call_id,
            .messages = state.initial_messages,
            .context = try validatedToolContext(state, named, state.current_tools_context),
        }) catch |err| return mapAnyError(state, err, "tool approval revalidation failed"),
    };
}

fn collectToolApprovals(state: *CallState) provider.CallError!CollectedApprovals {
    if (state.initial_messages.len == 0) {
        return .{ .approved = &.{}, .denied = &.{} };
    }
    const last_tool = switch (state.initial_messages[state.initial_messages.len - 1]) {
        .tool => |value| value,
        else => return .{ .approved = &.{}, .denied = &.{} },
    };

    var calls: std.StringHashMapUnmanaged(TypedToolCall) = .empty;
    var requests: std.StringHashMapUnmanaged(message.ToolApprovalRequest) = .empty;
    for (state.initial_messages) |item| switch (item) {
        .assistant => |assistant| switch (assistant.content) {
            .text => {},
            .parts => |parts| for (parts) |part| switch (part) {
                .tool_call => |call| {
                    const named = findTool(state.options.tools, call.tool_name);
                    try calls.put(state.arena, call.tool_call_id, .{
                        .tool_call_id = try state.arena.dupe(u8, call.tool_call_id),
                        .tool_name = try state.arena.dupe(u8, call.tool_name),
                        .input = try provider_utils.cloneJsonValue(state.arena, call.input),
                        .provider_executed = call.provider_executed == true,
                        .provider_metadata = try cloneOptionalJson(state.arena, call.provider_options),
                        .tool_metadata = if (named) |value| try cloneOptionalJson(state.arena, value.tool.metadata) else null,
                        .dynamic = if (named) |value| value.tool.kind == .dynamic else true,
                    });
                },
                .tool_approval_request => |request| try requests.put(state.arena, request.approval_id, request),
                else => {},
            },
        },
        else => {},
    };

    var existing_results: std.StringHashMapUnmanaged(void) = .empty;
    for (last_tool.content) |part| switch (part) {
        .tool_result => |result| try existing_results.put(state.arena, result.tool_call_id, {}),
        else => {},
    };
    var approved: std.ArrayList(CollectedApproval) = .empty;
    defer approved.deinit(state.arena);
    var denied: std.ArrayList(CollectedApproval) = .empty;
    defer denied.deinit(state.arena);
    for (last_tool.content) |part| switch (part) {
        .tool_approval_response => |response| {
            const request = requests.get(response.approval_id) orelse {
                setInvalidApproval(state, response.approval_id);
                return error.InvalidToolApprovalError;
            };
            if (existing_results.contains(request.tool_call_id)) continue;
            const call = calls.get(request.tool_call_id) orelse {
                setToolApprovalNotFound(state, request.tool_call_id, request.approval_id);
                return error.ToolCallNotFoundForApprovalError;
            };
            const collected: CollectedApproval = .{
                .request = request,
                .response = response,
                .call = call,
            };
            if (response.approved) {
                try approved.append(state.arena, collected);
            } else {
                try denied.append(state.arena, collected);
            }
        },
        else => {},
    };
    return .{
        .approved = try approved.toOwnedSlice(state.arena),
        .denied = try denied.toOwnedSlice(state.arena),
    };
}

const StopConditionJob = struct {
    io: std.Io,
    condition: StopCondition,
    steps: []const StepResult,
    matched: bool = false,
    err: ?provider.CallError = null,

    fn run(self: *StopConditionJob) void {
        self.matched = self.condition.check(self.io, self.steps) catch |err| {
            self.err = err;
            return;
        };
    }
};

pub fn isStopConditionMet(
    io: std.Io,
    arena: Allocator,
    stop_when: []const StopCondition,
    steps: []const StepResult,
) provider.CallError!bool {
    if (stop_when.len == 0) return steps.len == 1;
    const jobs = try arena.alloc(StopConditionJob, stop_when.len);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var warned = false;
    for (stop_when, jobs) |condition, *job| {
        job.* = .{ .io = io, .condition = condition, .steps = steps };
        group.concurrent(io, StopConditionJob.run, .{job}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                if (!warned) {
                    std.log.warn("stop-condition concurrency unavailable; falling back to async scheduling", .{});
                    warned = true;
                }
                group.async(io, StopConditionJob.run, .{job});
            },
        };
    }
    try group.await(io);
    var matched = false;
    for (jobs) |job| {
        if (job.err) |err| return err;
        if (job.matched) matched = true;
    }
    return matched;
}

fn stopConditionMet(state: *CallState) provider.CallError!bool {
    return isStopConditionMet(
        state.io,
        state.arena,
        state.options.stop_when,
        state.steps.items,
    );
}

const Aggregates = struct {
    content: []const ContentPart,
    files: []const provider.GeneratedFile,
    sources: []const provider.Source,
    tool_calls: []const TypedToolCall,
    static_tool_calls: []const TypedToolCall,
    dynamic_tool_calls: []const TypedToolCall,
    tool_results: []const TypedToolResult,
    static_tool_results: []const TypedToolResult,
    dynamic_tool_results: []const TypedToolResult,
    warnings: []const provider.Warning,
};

fn aggregateResults(arena: Allocator, steps: []const StepResult) Allocator.Error!Aggregates {
    var content: std.ArrayList(ContentPart) = .empty;
    defer content.deinit(arena);
    var files: std.ArrayList(provider.GeneratedFile) = .empty;
    defer files.deinit(arena);
    var sources: std.ArrayList(provider.Source) = .empty;
    defer sources.deinit(arena);
    var calls: std.ArrayList(TypedToolCall) = .empty;
    defer calls.deinit(arena);
    var static_calls: std.ArrayList(TypedToolCall) = .empty;
    defer static_calls.deinit(arena);
    var dynamic_calls: std.ArrayList(TypedToolCall) = .empty;
    defer dynamic_calls.deinit(arena);
    var results: std.ArrayList(TypedToolResult) = .empty;
    defer results.deinit(arena);
    var static_results: std.ArrayList(TypedToolResult) = .empty;
    defer static_results.deinit(arena);
    var dynamic_results: std.ArrayList(TypedToolResult) = .empty;
    defer dynamic_results.deinit(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    for (steps) |step| {
        try content.appendSlice(arena, step.content);
        try files.appendSlice(arena, step.files());
        try sources.appendSlice(arena, step.sources());
        try calls.appendSlice(arena, step.toolCalls());
        try static_calls.appendSlice(arena, step.staticToolCalls());
        try dynamic_calls.appendSlice(arena, step.dynamicToolCalls());
        try results.appendSlice(arena, step.toolResults());
        try static_results.appendSlice(arena, step.staticToolResults());
        try dynamic_results.appendSlice(arena, step.dynamicToolResults());
        try warnings.appendSlice(arena, step.warnings);
    }
    return .{
        .content = try content.toOwnedSlice(arena),
        .files = try files.toOwnedSlice(arena),
        .sources = try sources.toOwnedSlice(arena),
        .tool_calls = try calls.toOwnedSlice(arena),
        .static_tool_calls = try static_calls.toOwnedSlice(arena),
        .dynamic_tool_calls = try dynamic_calls.toOwnedSlice(arena),
        .tool_results = try results.toOwnedSlice(arena),
        .static_tool_results = try static_results.toOwnedSlice(arena),
        .dynamic_tool_results = try dynamic_results.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn accumulatedResultMessages(state: *CallState, steps: []const StepResult) Allocator.Error![]const message.ModelMessage {
    var result: std.ArrayList(message.ModelMessage) = .empty;
    defer result.deinit(state.arena);
    try result.appendSlice(state.arena, state.initial_response_messages.items);
    for (steps) |step| try result.appendSlice(state.arena, step.response.messages);
    return result.toOwnedSlice(state.arena);
}

pub fn filterActiveTools(
    arena: Allocator,
    tools: tool_api.ToolSet,
    active: ?[]const []const u8,
) Allocator.Error!tool_api.ToolSet {
    const names = active orelse return tools;
    var filtered: std.ArrayList(tool_api.NamedTool) = .empty;
    defer filtered.deinit(arena);
    for (tools) |named| {
        for (names) |name| if (std.mem.eql(u8, named.name, name)) {
            try filtered.append(arena, named);
            break;
        };
    }
    return filtered.toOwnedSlice(arena);
}

pub fn retryDelayInMs(
    _: anyerror,
    diag: ?*const provider.Diagnostics,
    exponential_delay_ms: u64,
) u64 {
    const diagnostics = diag orelse return exponential_delay_ms;
    if (!diagnostics.available or diagnostics.payload != .api_call) return exponential_delay_ms;
    const headers = diagnostics.payload.api_call.response_headers;
    var delay_ms: ?f64 = null;
    if (provider_utils.getHeader(headers, "retry-after-ms")) |value| {
        delay_ms = std.fmt.parseFloat(f64, value) catch null;
    }
    if (delay_ms == null) if (provider_utils.getHeader(headers, "retry-after")) |value| {
        if (std.fmt.parseFloat(f64, value)) |seconds| {
            delay_ms = seconds * 1000;
        } else |_| {
            // TODO(phase-4b): parse the RFC1123 HTTP-date form once a reusable
            // stdlib HTTP-date parser exists; numeric seconds remain supported.
        }
    };
    const candidate = delay_ms orelse return exponential_delay_ms;
    if (!std.math.isFinite(candidate) or candidate < 0) return exponential_delay_ms;
    const exponential: f64 = @floatFromInt(exponential_delay_ms);
    if (!(candidate < 60_000 or candidate < exponential)) return exponential_delay_ms;
    const max_float: f64 = @floatFromInt(std.math.maxInt(u64));
    if (candidate >= max_float) return std.math.maxInt(u64);
    return @intFromFloat(@floor(candidate));
}

fn runWithTimeout(
    comptime T: type,
    io: std.Io,
    timeout_ms: ?u64,
    context: anytype,
    comptime operation: anytype,
    timed_out: *std.atomic.Value(bool),
) provider.CallError!T {
    const milliseconds = timeout_ms orelse return operation(context);
    const Context = @TypeOf(context);
    const Runner = struct {
        fn run(inner: Context) provider.CallError!T {
            return operation(inner);
        }
    };
    const Race = union(enum) {
        operation: provider.CallError!T,
        deadline: std.Io.Cancelable!void,
    };
    var buffer: [2]Race = undefined;
    var select: std.Io.Select(Race) = .init(io, &buffer);
    select.concurrent(.deadline, sleepMilliseconds, .{ io, milliseconds }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            std.log.warn("timeout enforcement unavailable because std.Io concurrency is unavailable", .{});
            return operation(context);
        },
    };
    defer select.cancelDiscard();
    select.async(.operation, Runner.run, .{context});
    return switch (try select.await()) {
        .operation => |result| try result,
        .deadline => |result| {
            try result;
            timed_out.store(true, .release);
            return error.Canceled;
        },
    };
}

fn sleepMilliseconds(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    const value: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
    return io.sleep(.fromMilliseconds(value), .awake);
}

fn dispatchEvent(
    comptime Event: type,
    io: std.Io,
    dispatcher: *telemetry.Dispatcher,
    user_callback: ?Callback(Event),
    event: Event,
    comptime method_name: []const u8,
) provider.CallError!void {
    const UserRunner = struct {
        fn run(raw: ?*anyopaque, value: Event) anyerror!void {
            const callback: *const Callback(Event) = @ptrCast(@alignCast(raw.?));
            return callback.callback(callback.ctx, &value);
        }
    };
    const TelemetryRunner = struct {
        fn run(raw: ?*anyopaque, value: Event) anyerror!void {
            const selected: *telemetry.Dispatcher = @ptrCast(@alignCast(raw.?));
            if (comptime std.mem.eql(u8, method_name, "onStart")) return selected.onStart(&value);
            if (comptime std.mem.eql(u8, method_name, "onStepStart")) return selected.onStepStart(&value);
            if (comptime std.mem.eql(u8, method_name, "onLanguageModelCallStart")) return selected.onLanguageModelCallStart(&value);
            if (comptime std.mem.eql(u8, method_name, "onLanguageModelCallEnd")) return selected.onLanguageModelCallEnd(&value);
            if (comptime std.mem.eql(u8, method_name, "onToolExecutionStart")) return selected.onToolExecutionStart(&value);
            if (comptime std.mem.eql(u8, method_name, "onToolExecutionEnd")) return selected.onToolExecutionEnd(&value);
            if (comptime std.mem.eql(u8, method_name, "onStepEnd")) return selected.onStepEnd(&value);
            if (comptime std.mem.eql(u8, method_name, "onEnd")) return selected.onEnd(&value);
            if (comptime std.mem.eql(u8, method_name, "onAbort")) return selected.onAbort(&value);
            if (comptime std.mem.eql(u8, method_name, "onError")) return selected.onError(&value);
            @compileError("unsupported telemetry event method");
        }
    };
    var user_storage = user_callback;
    const callbacks = [_]?provider_utils.Callback(Event){
        if (user_storage != null) .{ .ctx = &user_storage.?, .func = UserRunner.run } else null,
        .{ .ctx = dispatcher, .func = TelemetryRunner.run },
    };
    try provider_utils.notify(io, event, &callbacks);
}

fn cloneInstructions(arena: Allocator, input: ?prompt_api.Instructions) Allocator.Error!?prompt_api.Instructions {
    const value = input orelse return null;
    return switch (value) {
        .text => |text_value| .{ .text = try arena.dupe(u8, text_value) },
        .message => |system| .{ .message = .{
            .content = try arena.dupe(u8, system.content),
            .provider_options = try cloneOptionalJson(arena, system.provider_options),
        } },
        .messages => |systems| blk: {
            const result = try arena.alloc(message.SystemModelMessage, systems.len);
            for (systems, result) |system, *destination| destination.* = .{
                .content = try arena.dupe(u8, system.content),
                .provider_options = try cloneOptionalJson(arena, system.provider_options),
            };
            break :blk .{ .messages = result };
        },
    };
}

fn instructionsText(input: ?prompt_api.Instructions) ?[]const u8 {
    const value = input orelse return null;
    return switch (value) {
        .text => |text_value| text_value,
        .message => |system| system.content,
        .messages => |systems| if (systems.len == 0) null else systems[0].content,
    };
}

fn cloneOptionalJson(arena: Allocator, input: ?std.json.Value) Allocator.Error!?std.json.Value {
    return if (input) |value| try provider_utils.cloneJsonValue(arena, value) else null;
}

fn mergeOptionalJson(
    arena: Allocator,
    base: ?std.json.Value,
    overrides: ?std.json.Value,
) Allocator.Error!?std.json.Value {
    if (base == null and overrides == null) return null;
    if (base == null) return cloneOptionalJson(arena, overrides);
    if (overrides == null) return cloneOptionalJson(arena, base);
    return try mergeJson(arena, base.?, overrides.?);
}

fn mergeJson(arena: Allocator, base: std.json.Value, overrides: std.json.Value) Allocator.Error!std.json.Value {
    if (base != .object or overrides != .object) return provider_utils.cloneJsonValue(arena, overrides);
    var object: std.json.ObjectMap = .empty;
    var base_iterator = base.object.iterator();
    while (base_iterator.next()) |entry| {
        try object.put(
            arena,
            try arena.dupe(u8, entry.key_ptr.*),
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
        );
    }
    var override_iterator = overrides.object.iterator();
    while (override_iterator.next()) |entry| {
        const merged = if (object.get(entry.key_ptr.*)) |existing|
            try mergeJson(arena, existing, entry.value_ptr.*)
        else
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*);
        try object.put(arena, try arena.dupe(u8, entry.key_ptr.*), merged);
    }
    return .{ .object = object };
}

fn concatMessages(
    arena: Allocator,
    first: []const message.ModelMessage,
    second: []const message.ModelMessage,
) Allocator.Error![]const message.ModelMessage {
    const result = try arena.alloc(message.ModelMessage, first.len + second.len);
    @memcpy(result[0..first.len], first);
    @memcpy(result[first.len..], second);
    return result;
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

fn cloneUsage(arena: Allocator, usage: provider.Usage) Allocator.Error!provider.Usage {
    var result = usage;
    result.raw = try cloneOptionalJson(arena, usage.raw);
    return result;
}

fn cloneWarnings(arena: Allocator, warnings: []const provider.Warning) Allocator.Error![]const provider.Warning {
    if (warnings.len == 0) return &.{};
    const json_text = provider.wire.stringifyAlloc(arena, warnings) catch return error.OutOfMemory;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch return error.OutOfMemory;
    return provider.wire.parse([]const provider.Warning, arena, value) catch return error.OutOfMemory;
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
            .filename = if (source.filename) |filename| try arena.dupe(u8, filename) else null,
            .provider_metadata = try cloneOptionalJson(arena, source.provider_metadata),
        } },
    };
}

fn elapsedMilliseconds(start: std.Io.Timestamp, finish: std.Io.Timestamp) f64 {
    const nanoseconds = finish.nanoseconds -| start.nanoseconds;
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn timestampMilliseconds(io: std.Io) i64 {
    const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
    const milliseconds = @divTrunc(nanoseconds, std.time.ns_per_ms);
    return @intCast(std.math.clamp(milliseconds, std.math.minInt(i64), std.math.maxInt(i64)));
}

fn tokensPerSecond(tokens: ?u64, milliseconds: f64) f64 {
    const count = tokens orelse return 0;
    if (milliseconds <= 0) return 0;
    return @as(f64, @floatFromInt(count)) * 1000 / milliseconds;
}

fn setInvalidResponse(state: *CallState, text_value: []const u8) void {
    provider.Diagnostics.set(state.options.diag, diagnosticAllocator(state), .{ .invalid_response_data = .{
        .message = text_value,
    } });
}

fn setInvalidApproval(state: *CallState, approval_id: []const u8) void {
    provider.Diagnostics.set(state.options.diag, diagnosticAllocator(state), .{ .invalid_tool_approval = .{
        .message = "Invalid tool approval response",
        .approval_id = approval_id,
    } });
}

fn setInvalidApprovalSignature(
    state: *CallState,
    approval_id: []const u8,
    tool_call_id: []const u8,
    reason: []const u8,
) void {
    provider.Diagnostics.set(state.options.diag, diagnosticAllocator(state), .{ .invalid_tool_approval_signature = .{
        .message = "Invalid tool approval signature",
        .approval_id = approval_id,
        .tool_call_id = tool_call_id,
        .reason = reason,
    } });
}

fn setToolApprovalNotFound(
    state: *CallState,
    tool_call_id: []const u8,
    approval_id: []const u8,
) void {
    provider.Diagnostics.set(state.options.diag, diagnosticAllocator(state), .{ .tool_call_not_found_for_approval = .{
        .message = "Tool call for approval was not found",
        .tool_call_id = tool_call_id,
        .approval_id = approval_id,
    } });
}

fn setInvalidToolInput(
    state: *CallState,
    tool_name: []const u8,
    input: std.json.Value,
    cause: []const u8,
) void {
    const text_value = provider_utils.stringifyJsonValueAlloc(state.arena, input) catch "<unavailable>";
    provider.Diagnostics.set(state.options.diag, diagnosticAllocator(state), .{ .invalid_tool_input = .{
        .message = "Invalid tool input",
        .tool_name = tool_name,
        .tool_input = text_value,
        .cause_message = cause,
    } });
}

fn diagnosticAllocator(state: *CallState) Allocator {
    return if (state.options.diag) |diag| diag.allocator else state.arena;
}

fn mapAnyError(state: *CallState, err: anyerror, context: []const u8) provider.CallError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.APICallError => error.APICallError,
        error.EmptyResponseBodyError => error.EmptyResponseBodyError,
        error.InvalidArgumentError => error.InvalidArgumentError,
        error.InvalidPromptError => error.InvalidPromptError,
        error.InvalidResponseDataError => error.InvalidResponseDataError,
        error.JSONParseError => error.JSONParseError,
        error.LoadAPIKeyError => error.LoadAPIKeyError,
        error.LoadSettingError => error.LoadSettingError,
        error.NoContentGeneratedError => error.NoContentGeneratedError,
        error.NoSuchModelError => error.NoSuchModelError,
        error.NoSuchProviderReferenceError => error.NoSuchProviderReferenceError,
        error.TooManyEmbeddingValuesForCallError => error.TooManyEmbeddingValuesForCallError,
        error.TypeValidationError => error.TypeValidationError,
        error.UnsupportedFunctionalityError => error.UnsupportedFunctionalityError,
        error.DownloadError => error.DownloadError,
        error.InvalidStreamPartError => error.InvalidStreamPartError,
        error.InvalidToolApprovalError => error.InvalidToolApprovalError,
        error.InvalidToolApprovalSignatureError => error.InvalidToolApprovalSignatureError,
        error.InvalidToolInputError => error.InvalidToolInputError,
        error.MissingToolResultsError => error.MissingToolResultsError,
        error.NoImageGeneratedError => error.NoImageGeneratedError,
        error.NoObjectGeneratedError => error.NoObjectGeneratedError,
        error.NoOutputGeneratedError => error.NoOutputGeneratedError,
        error.NoSpeechGeneratedError => error.NoSpeechGeneratedError,
        error.NoSuchToolError => error.NoSuchToolError,
        error.NoTranscriptGeneratedError => error.NoTranscriptGeneratedError,
        error.NoVideoGeneratedError => error.NoVideoGeneratedError,
        error.ToolCallNotFoundForApprovalError => error.ToolCallNotFoundForApprovalError,
        error.ToolCallRepairError => error.ToolCallRepairError,
        error.UIMessageStreamError => error.UIMessageStreamError,
        error.UnsupportedModelVersionError => error.UnsupportedModelVersionError,
        error.InvalidDataContentError => error.InvalidDataContentError,
        error.InvalidMessageRoleError => error.InvalidMessageRoleError,
        error.MessageConversionError => error.MessageConversionError,
        error.NoSuchProviderError => error.NoSuchProviderError,
        error.RetryError => error.RetryError,
        else => {
            provider.Diagnostics.set(state.options.diag, diagnosticAllocator(state), .{ .invalid_argument = .{
                .message = context,
                .parameter = "callback",
                .value_json = @errorName(err),
            } });
            return error.InvalidArgumentError;
        },
    };
}
