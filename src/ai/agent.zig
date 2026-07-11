//! Agent V1 interface and the settings-merging ToolLoopAgent.
//!
//! ToolLoopAgent intentionally owns no generation loop. It validates and
//! prepares one call, merges lifecycle callbacks, tags request headers, and
//! delegates to the live-validated `generateText` / `streamText` paths.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const generate_text = @import("generate_text.zig");
const message = @import("message.zig");
const output_api = @import("output.zig");
const prompt_api = @import("prompt.zig");
const registry = @import("registry.zig");
const stream_text = @import("stream_text.zig");
const telemetry = @import("telemetry.zig");
const tool_api = @import("tool.zig");

const Allocator = std.mem.Allocator;

pub const version = "agent-v1";
pub const user_agent_suffix = "ai-sdk-zig-agent/tool-loop";

/// Type-erased Agent V1 surface used by harnesses and later UI-stream APIs.
pub const Agent = struct {
    ctx: *anyopaque,
    version: []const u8 = version,
    id: ?[]const u8 = null,
    tools: tool_api.ToolSet = &.{},
    generate_fn: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) provider.CallError!generate_text.GenerateTextResult,
    stream_fn: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) anyerror!stream_text.StreamTextResult,

    pub fn generate(
        self: Agent,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) provider.CallError!generate_text.GenerateTextResult {
        return self.generate_fn(self.ctx, io, gpa, params);
    }

    pub fn stream(
        self: Agent,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) anyerror!stream_text.StreamTextResult {
        return self.stream_fn(self.ctx, io, gpa, params);
    }
};

/// Canonical lifecycle callbacks only. Deprecated upstream aliases are not
/// part of the Zig surface (fidelity-ledger item 16).
pub const LifecycleCallbacks = struct {
    on_start: ?generate_text.Callback(events.GenerateTextStartEvent) = null,
    on_step_start: ?generate_text.Callback(events.StepStartEvent) = null,
    on_tool_execution_start: ?generate_text.Callback(events.ToolExecutionStartEvent) = null,
    on_tool_execution_end: ?generate_text.Callback(events.ToolExecutionEndEvent) = null,
    on_step_end: ?generate_text.Callback(events.StepEndEvent) = null,
    on_end: ?generate_text.Callback(events.EndEvent) = null,
};

pub const ToolApprovalConfiguration = struct {
    secret: ?[]const u8 = null,
};

pub const AgentCallParameters = struct {
    options: ?std.json.Value = null,
    prompt: ?prompt_api.PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    timeout: ?generate_text.TimeoutConfiguration = null,
    callbacks: LifecycleCallbacks = .{},
    transforms: []const stream_text.StreamTransform = &.{},
};

/// Fully resolved input passed to `prepare_call`. Lifecycle callbacks are
/// deliberately absent, matching upstream's settings-without-callbacks step.
pub const PrepareCallOptions = struct {
    options: ?std.json.Value,
    model: registry.LanguageModelRef,
    instructions: ?prompt_api.Instructions,
    allow_system_in_messages: bool,
    prompt: ?prompt_api.PromptValue,
    messages: ?[]const message.ModelMessage,
    tools: []const tool_api.NamedTool,
    tool_choice: ?prompt_api.ToolChoice,
    active_tools: ?[]const []const u8,
    tool_order: ?[]const []const u8,
    stop_when: []const generate_text.StopCondition,
    prepare_step: ?generate_text.PrepareStep,
    repair_tool_call: ?generate_text.RepairToolCall,
    refine_tool_input: ?[]const generate_text.RefineToolInput,
    max_output_tokens: ?f64,
    temperature: ?f64,
    top_p: ?f64,
    top_k: ?f64,
    presence_penalty: ?f64,
    frequency_penalty: ?f64,
    stop_sequences: ?[]const []const u8,
    seed: ?f64,
    reasoning: ?provider.ReasoningEffort,
    headers: ?provider.Headers,
    provider_options: ?provider.ProviderOptions,
    max_retries: u32,
    timeout: ?generate_text.TimeoutConfiguration,
    tools_context: ?std.json.Value,
    runtime_context: ?std.json.Value,
    output: ?output_api.Output,
    telemetry: telemetry.TelemetryOptions,
    tool_approval: ?ToolApprovalConfiguration,
};

/// Sparse replacement returned by `prepare_call`. Every absent field inherits
/// its base value. Supplying `prompt` replaces inherited `messages`, and vice
/// versa, so hooks can safely change the prompt representation.
pub const PrepareCallResult = struct {
    model: ?registry.LanguageModelRef = null,
    instructions: ?prompt_api.Instructions = null,
    allow_system_in_messages: ?bool = null,
    prompt: ?prompt_api.PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    tools: ?[]const tool_api.NamedTool = null,
    tool_choice: ?prompt_api.ToolChoice = null,
    active_tools: ?[]const []const u8 = null,
    tool_order: ?[]const []const u8 = null,
    stop_when: ?[]const generate_text.StopCondition = null,
    prepare_step: ?generate_text.PrepareStep = null,
    repair_tool_call: ?generate_text.RepairToolCall = null,
    refine_tool_input: ?[]const generate_text.RefineToolInput = null,
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
    max_retries: ?u32 = null,
    timeout: ?generate_text.TimeoutConfiguration = null,
    tools_context: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    output: ?output_api.Output = null,
    telemetry: ?telemetry.TelemetryOptions = null,
    tool_approval: ?ToolApprovalConfiguration = null,
};

pub const PrepareCall = struct {
    ctx: ?*anyopaque = null,
    prepare_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const PrepareCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!?PrepareCallResult,

    pub fn prepare(
        self: PrepareCall,
        io: std.Io,
        arena: Allocator,
        options: *const PrepareCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!?PrepareCallResult {
        return self.prepare_fn(self.ctx, io, arena, options, diag);
    }
};

pub const ToolLoopAgentSettings = struct {
    model: registry.LanguageModelRef,
    id: ?[]const u8 = null,
    instructions: ?prompt_api.Instructions = null,
    allow_system_in_messages: bool = false,
    tools: []const tool_api.NamedTool = &.{},
    tool_choice: ?prompt_api.ToolChoice = null,
    active_tools: ?[]const []const u8 = null,
    tool_order: ?[]const []const u8 = null,
    /// Null selects the agent default `stepCount(20)`; an explicit empty slice
    /// preserves bare generateText's one-step default when deliberately asked.
    stop_when: ?[]const generate_text.StopCondition = null,
    prepare_step: ?generate_text.PrepareStep = null,
    repair_tool_call: ?generate_text.RepairToolCall = null,
    refine_tool_input: ?[]const generate_text.RefineToolInput = null,
    max_output_tokens: ?f64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?f64 = null,
    reasoning: ?provider.ReasoningEffort = null,
    provider_options: ?provider.ProviderOptions = null,
    headers: ?provider.Headers = null,
    max_retries: u32 = 2,
    timeout: ?generate_text.TimeoutConfiguration = null,
    tools_context: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    output: ?output_api.Output = null,
    tool_approval: ?ToolApprovalConfiguration = null,
    telemetry: telemetry.TelemetryOptions = .{},
    callbacks: LifecycleCallbacks = .{},
    call_options_schema: ?provider_utils.Schema = null,
    prepare_call: ?PrepareCall = null,
    diag: ?*provider.Diagnostics = null,
};

pub const ToolLoopAgent = struct {
    settings: ToolLoopAgentSettings,

    pub fn init(settings: ToolLoopAgentSettings) ToolLoopAgent {
        return .{ .settings = settings };
    }

    pub fn asAgent(self: *ToolLoopAgent) Agent {
        return .{
            .ctx = self,
            .id = self.settings.id,
            .tools = self.settings.tools,
            .generate_fn = erasedGenerate,
            .stream_fn = erasedStream,
        };
    }

    pub fn generate(
        self: *ToolLoopAgent,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) provider.CallError!generate_text.GenerateTextResult {
        var call_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer call_arena_state.deinit();
        const arena = call_arena_state.allocator();
        const prepared = try self.prepareCall(io, arena, params);
        var callbacks: CallbackBundle = .{
            .io = io,
            .settings = self.settings.callbacks,
            .call = params.callbacks,
        };
        return generate_text.generateText(io, gpa, generateOptions(prepared, callbacks.callbacks()));
    }

    pub fn stream(
        self: *ToolLoopAgent,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) anyerror!stream_text.StreamTextResult {
        const resources = try gpa.create(StreamResources);
        resources.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .callbacks = .{
                .io = io,
                .settings = self.settings.callbacks,
                .call = params.callbacks,
            },
        };
        errdefer resources.destroy();

        const prepared = try self.prepareCall(io, resources.arena_state.allocator(), params);
        var result = try stream_text.streamText(
            io,
            gpa,
            streamOptions(prepared, resources.callbacks.callbacks(), params.transforms),
        );
        result.attachCleanup(.{ .ctx = resources, .deinit_fn = StreamResources.cleanup });
        return result;
    }

    fn erasedGenerate(
        raw: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) provider.CallError!generate_text.GenerateTextResult {
        const self: *ToolLoopAgent = @ptrCast(@alignCast(raw));
        return self.generate(io, gpa, params);
    }

    fn erasedStream(
        raw: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        params: AgentCallParameters,
    ) anyerror!stream_text.StreamTextResult {
        const self: *ToolLoopAgent = @ptrCast(@alignCast(raw));
        return self.stream(io, gpa, params);
    }

    fn prepareCall(
        self: *ToolLoopAgent,
        io: std.Io,
        arena: Allocator,
        params: AgentCallParameters,
    ) provider.CallError!PrepareCallOptions {
        try self.validateCallOptions(arena, params.options);
        try validatePromptChoice(arena, params.prompt, params.messages, self.settings.diag);

        const default_stop = if (self.settings.stop_when == null) blk: {
            const conditions = try arena.alloc(generate_text.StopCondition, 1);
            conditions[0] = generate_text.stepCount(20);
            break :blk conditions;
        } else self.settings.stop_when.?;

        var prepared: PrepareCallOptions = .{
            .options = params.options,
            .model = self.settings.model,
            .instructions = self.settings.instructions,
            .allow_system_in_messages = self.settings.allow_system_in_messages,
            .prompt = params.prompt,
            .messages = params.messages,
            .tools = self.settings.tools,
            .tool_choice = self.settings.tool_choice,
            .active_tools = self.settings.active_tools,
            .tool_order = self.settings.tool_order,
            .stop_when = default_stop,
            .prepare_step = self.settings.prepare_step,
            .repair_tool_call = self.settings.repair_tool_call,
            .refine_tool_input = self.settings.refine_tool_input,
            .max_output_tokens = self.settings.max_output_tokens,
            .temperature = self.settings.temperature,
            .top_p = self.settings.top_p,
            .top_k = self.settings.top_k,
            .presence_penalty = self.settings.presence_penalty,
            .frequency_penalty = self.settings.frequency_penalty,
            .stop_sequences = self.settings.stop_sequences,
            .seed = self.settings.seed,
            .reasoning = self.settings.reasoning,
            .headers = self.settings.headers,
            .provider_options = self.settings.provider_options,
            .max_retries = self.settings.max_retries,
            .timeout = params.timeout orelse self.settings.timeout,
            .tools_context = self.settings.tools_context,
            .runtime_context = self.settings.runtime_context,
            .output = self.settings.output,
            .telemetry = self.settings.telemetry,
            .tool_approval = self.settings.tool_approval,
        };

        if (self.settings.prepare_call) |hook| {
            if (try hook.prepare(io, arena, &prepared, self.settings.diag)) |replacement| {
                try applyReplacement(arena, &prepared, replacement, self.settings.diag);
            }
        }
        try validatePromptChoice(arena, prepared.prompt, prepared.messages, self.settings.diag);
        prepared.headers = try provider_utils.withUserAgentSuffix(
            arena,
            prepared.headers orelse &.{},
            &.{user_agent_suffix},
        );
        return prepared;
    }

    fn validateCallOptions(
        self: *ToolLoopAgent,
        arena: Allocator,
        options: ?std.json.Value,
    ) provider.CallError!void {
        const schema = self.settings.call_options_schema orelse return;
        const value = options orelse return;
        const validator = schema.validator orelse {
            const value_json = try provider_utils.stringifyJsonValueAlloc(arena, value);
            provider.Diagnostics.set(self.settings.diag, diagnosticAllocator(self.settings.diag, arena), .{
                .type_validation = .{
                    .message = "Type validation failed for options",
                    .value_json = value_json,
                    .context = .{ .field = "options" },
                    .cause_message = "SchemaValidatorMissing",
                },
            });
            return error.TypeValidationError;
        };
        validator.validate(arena, value, self.settings.diag) catch {
            const value_json = try provider_utils.stringifyJsonValueAlloc(arena, value);
            const cause = if (self.settings.diag) |diag|
                if (diag.available and diag.payload == .type_validation)
                    if (diag.payload.type_validation.cause_message) |cause_message|
                        try arena.dupe(u8, cause_message)
                    else
                        null
                else
                    null
            else
                null;
            provider.Diagnostics.set(self.settings.diag, diagnosticAllocator(self.settings.diag, arena), .{
                .type_validation = .{
                    .message = "Type validation failed for options",
                    .value_json = value_json,
                    .context = .{ .field = "options" },
                    .cause_message = cause,
                },
            });
            return error.TypeValidationError;
        };
    }
};

fn applyReplacement(
    arena: Allocator,
    prepared: *PrepareCallOptions,
    replacement: PrepareCallResult,
    diag: ?*provider.Diagnostics,
) provider.CallError!void {
    if (replacement.prompt != null and replacement.messages != null) {
        return invalidPrompt(arena, diag, "prepareCall cannot return both prompt and messages");
    }
    if (replacement.model) |value| prepared.model = value;
    if (replacement.instructions) |value| prepared.instructions = value;
    if (replacement.allow_system_in_messages) |value| prepared.allow_system_in_messages = value;
    if (replacement.prompt) |value| {
        prepared.prompt = value;
        prepared.messages = null;
    }
    if (replacement.messages) |value| {
        prepared.messages = value;
        prepared.prompt = null;
    }
    if (replacement.tools) |value| prepared.tools = value;
    if (replacement.tool_choice) |value| prepared.tool_choice = value;
    if (replacement.active_tools) |value| prepared.active_tools = value;
    if (replacement.tool_order) |value| prepared.tool_order = value;
    if (replacement.stop_when) |value| prepared.stop_when = value;
    if (replacement.prepare_step) |value| prepared.prepare_step = value;
    if (replacement.repair_tool_call) |value| prepared.repair_tool_call = value;
    if (replacement.refine_tool_input) |value| prepared.refine_tool_input = value;
    if (replacement.max_output_tokens) |value| prepared.max_output_tokens = value;
    if (replacement.temperature) |value| prepared.temperature = value;
    if (replacement.top_p) |value| prepared.top_p = value;
    if (replacement.top_k) |value| prepared.top_k = value;
    if (replacement.presence_penalty) |value| prepared.presence_penalty = value;
    if (replacement.frequency_penalty) |value| prepared.frequency_penalty = value;
    if (replacement.stop_sequences) |value| prepared.stop_sequences = value;
    if (replacement.seed) |value| prepared.seed = value;
    if (replacement.reasoning) |value| prepared.reasoning = value;
    if (replacement.headers) |value| prepared.headers = value;
    if (replacement.provider_options) |value| prepared.provider_options = value;
    if (replacement.max_retries) |value| prepared.max_retries = value;
    if (replacement.timeout) |value| prepared.timeout = value;
    if (replacement.tools_context) |value| prepared.tools_context = value;
    if (replacement.runtime_context) |value| prepared.runtime_context = value;
    if (replacement.output) |value| prepared.output = value;
    if (replacement.telemetry) |value| prepared.telemetry = value;
    if (replacement.tool_approval) |value| prepared.tool_approval = value;
}

fn validatePromptChoice(
    arena: Allocator,
    prompt: ?prompt_api.PromptValue,
    messages: ?[]const message.ModelMessage,
    diag: ?*provider.Diagnostics,
) provider.CallError!void {
    if (prompt == null and messages == null) return invalidPrompt(
        arena,
        diag,
        "prompt or messages must be defined",
    );
    if (prompt != null and messages != null) return invalidPrompt(
        arena,
        diag,
        "prompt and messages cannot be defined at the same time",
    );
}

fn invalidPrompt(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    text: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .invalid_prompt = .{ .message = text },
    });
    return error.InvalidPromptError;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

fn generateOptions(
    prepared: PrepareCallOptions,
    callbacks: generate_text.Callbacks,
) generate_text.GenerateTextOptions {
    return .{
        .model = prepared.model,
        .instructions = prepared.instructions,
        .prompt = prepared.prompt,
        .messages = prepared.messages,
        .allow_system_in_messages = prepared.allow_system_in_messages,
        .tools = prepared.tools,
        .tool_choice = prepared.tool_choice,
        .active_tools = prepared.active_tools,
        .tool_order = prepared.tool_order,
        .stop_when = prepared.stop_when,
        .prepare_step = prepared.prepare_step,
        .repair_tool_call = prepared.repair_tool_call,
        .refine_tool_input = prepared.refine_tool_input,
        .max_output_tokens = prepared.max_output_tokens,
        .temperature = prepared.temperature,
        .top_p = prepared.top_p,
        .top_k = prepared.top_k,
        .presence_penalty = prepared.presence_penalty,
        .frequency_penalty = prepared.frequency_penalty,
        .stop_sequences = prepared.stop_sequences,
        .seed = prepared.seed,
        .reasoning = prepared.reasoning,
        .headers = prepared.headers,
        .provider_options = prepared.provider_options,
        .max_retries = prepared.max_retries,
        .timeout = prepared.timeout,
        .tools_context = prepared.tools_context,
        .runtime_context = prepared.runtime_context,
        .output = prepared.output,
        .callbacks = callbacks,
        .telemetry = prepared.telemetry,
        .tool_approval_secret = if (prepared.tool_approval) |approval| approval.secret else null,
    };
}

fn streamOptions(
    prepared: PrepareCallOptions,
    callbacks: generate_text.Callbacks,
    transforms: []const stream_text.StreamTransform,
) stream_text.StreamTextOptions {
    return .{
        .model = prepared.model,
        .instructions = prepared.instructions,
        .prompt = prepared.prompt,
        .messages = prepared.messages,
        .allow_system_in_messages = prepared.allow_system_in_messages,
        .tools = prepared.tools,
        .tool_choice = prepared.tool_choice,
        .active_tools = prepared.active_tools,
        .tool_order = prepared.tool_order,
        .stop_when = prepared.stop_when,
        .prepare_step = prepared.prepare_step,
        .repair_tool_call = prepared.repair_tool_call,
        .refine_tool_input = prepared.refine_tool_input,
        .max_output_tokens = prepared.max_output_tokens,
        .temperature = prepared.temperature,
        .top_p = prepared.top_p,
        .top_k = prepared.top_k,
        .presence_penalty = prepared.presence_penalty,
        .frequency_penalty = prepared.frequency_penalty,
        .stop_sequences = prepared.stop_sequences,
        .seed = prepared.seed,
        .reasoning = prepared.reasoning,
        .headers = prepared.headers,
        .provider_options = prepared.provider_options,
        .max_retries = prepared.max_retries,
        .timeout = prepared.timeout,
        .tools_context = prepared.tools_context,
        .runtime_context = prepared.runtime_context,
        .output = prepared.output,
        .callbacks = callbacks,
        .telemetry = prepared.telemetry,
        .tool_approval_secret = if (prepared.tool_approval) |approval| approval.secret else null,
        .transforms = transforms,
    };
}

const CallbackBundle = struct {
    io: std.Io,
    settings: LifecycleCallbacks,
    call: LifecycleCallbacks,

    fn callbacks(self: *CallbackBundle) generate_text.Callbacks {
        return .{
            .on_start = self.merged(events.GenerateTextStartEvent, "on_start"),
            .on_step_start = self.merged(events.StepStartEvent, "on_step_start"),
            .on_tool_execution_start = self.merged(events.ToolExecutionStartEvent, "on_tool_execution_start"),
            .on_tool_execution_end = self.merged(events.ToolExecutionEndEvent, "on_tool_execution_end"),
            .on_step_end = self.merged(events.StepEndEvent, "on_step_end"),
            .on_end = self.merged(events.EndEvent, "on_end"),
        };
    }

    fn merged(
        self: *CallbackBundle,
        comptime Event: type,
        comptime field_name: []const u8,
    ) ?generate_text.Callback(Event) {
        if (@field(self.settings, field_name) == null and @field(self.call, field_name) == null) return null;
        return .{ .ctx = self, .callback = MergeRunner(Event, field_name).run };
    }
};

fn MergeRunner(comptime Event: type, comptime field_name: []const u8) type {
    return struct {
        fn run(raw: ?*anyopaque, event: *const Event) anyerror!void {
            const self: *CallbackBundle = @ptrCast(@alignCast(raw.?));
            var settings_callback = @field(self.settings, field_name);
            var call_callback = @field(self.call, field_name);
            const Forward = struct {
                fn invoke(callback_raw: ?*anyopaque, value: Event) anyerror!void {
                    const callback: *const generate_text.Callback(Event) = @ptrCast(@alignCast(callback_raw.?));
                    return callback.callback(callback.ctx, &value);
                }
            };
            const callbacks = [_]?provider_utils.Callback(Event){
                if (settings_callback != null) .{ .ctx = &settings_callback.?, .func = Forward.invoke } else null,
                if (call_callback != null) .{ .ctx = &call_callback.?, .func = Forward.invoke } else null,
            };
            try provider_utils.notify(self.io, event.*, &callbacks);
        }
    };
}

const StreamResources = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    callbacks: CallbackBundle,

    fn cleanup(raw: *anyopaque) void {
        const self: *StreamResources = @ptrCast(@alignCast(raw));
        self.destroy();
    }

    fn destroy(self: *StreamResources) void {
        const gpa = self.gpa;
        self.arena_state.deinit();
        gpa.destroy(self);
    }
};

const TestModel = struct {
    calls: usize = 0,
    always_tool_call: bool = false,
    saw_agent_user_agent: bool = false,
    saw_custom_user_agent: bool = false,
    captured_temperature: ?f64 = null,
    captured_max_output_tokens: ?u64 = null,
    captured_option_value: ?[]const u8 = null,

    fn languageModel(self: *TestModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .urlIsSupported = urlIsSupported,
        .doGenerate = doGenerate,
        .doStream = doStream,
    };

    fn fromRaw(raw: *anyopaque) *TestModel {
        return @ptrCast(@alignCast(raw));
    }

    fn providerName(_: *anyopaque) []const u8 {
        return "agent-test";
    }

    fn modelId(_: *anyopaque) []const u8 {
        return "agent-test-model";
    }

    fn urlIsSupported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }

    fn capture(self: *TestModel, options: *const provider.CallOptions) void {
        self.calls += 1;
        self.captured_temperature = options.temperature;
        self.captured_max_output_tokens = options.max_output_tokens;
        if (options.headers) |headers| {
            const user_agent = provider_utils.getHeader(headers, "user-agent") orelse "";
            self.saw_agent_user_agent = std.mem.indexOf(u8, user_agent, user_agent_suffix) != null;
            self.saw_custom_user_agent = std.mem.indexOf(u8, user_agent, "test-client/1") != null;
        }
        if (options.provider_options) |provider_options| {
            if (provider_options == .object) {
                if (provider_options.object.get("test")) |namespace| {
                    if (namespace == .object) {
                        if (namespace.object.get("value")) |value| {
                            if (value == .string) self.captured_option_value = value.string;
                        }
                    }
                }
            }
        }
    }

    fn doGenerate(
        raw: *anyopaque,
        _: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const self = fromRaw(raw);
        self.capture(options);
        const content = try arena.alloc(provider.Content, 1);
        if (self.always_tool_call) {
            content[0] = .{ .tool_call = .{
                .tool_call_id = try std.fmt.allocPrint(arena, "call-{d}", .{self.calls}),
                .tool_name = "weather",
                .input = "{}",
            } };
        } else {
            content[0] = .{ .text = .{ .text = "reply" } };
        }
        return .{
            .content = content,
            .finish_reason = .{
                .unified = if (self.always_tool_call) .tool_calls else .stop,
                .raw = if (self.always_tool_call) "tool_calls" else "stop",
            },
            .usage = test_usage,
            .warnings = &.{},
        };
    }

    fn doStream(
        raw: *anyopaque,
        _: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const self = fromRaw(raw);
        self.capture(options);
        const state = try arena.create(TestPartStream);
        state.* = .{};
        return .{ .stream = .{ .ctx = state, .vtable = &TestPartStream.vtable } };
    }
};

const test_usage: provider.Usage = .{
    .input_tokens = .{ .total = 1, .no_cache = 1 },
    .output_tokens = .{ .total = 1, .text = 1 },
};

const TestPartStream = struct {
    index: usize = 0,

    const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
        const self: *TestPartStream = @ptrCast(@alignCast(raw));
        defer self.index += 1;
        return switch (self.index) {
            0 => .{ .stream_start = .{ .warnings = &.{} } },
            1 => .{ .response_metadata = .{
                .id = "stream-1",
                .timestamp_ms = 0,
                .model_id = "agent-test-model",
            } },
            2 => .{ .text_start = .{ .id = "0" } },
            3 => .{ .text_delta = .{ .id = "0", .delta = "reply" } },
            4 => .{ .text_end = .{ .id = "0" } },
            5 => .{ .finish = .{
                .finish_reason = .{ .unified = .stop, .raw = "stop" },
                .usage = test_usage,
            } },
            else => null,
        };
    }

    fn deinit(_: *anyopaque, _: std.Io) void {}
};

fn executeTestTool(
    _: ?*anyopaque,
    _: std.Io,
    _: Allocator,
    _: std.json.Value,
    _: tool_api.ToolExecutionOptions,
) anyerror!tool_api.ToolOutput {
    return .{ .value = .{ .string = "sunny" } };
}

fn testTools() [1]tool_api.NamedTool {
    return .{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct {}),
            .execute = .{ .execute_fn = executeTestTool },
        },
    }};
}

test "ToolLoopAgent defaults stop_when to stepCount(20) and accepts hasToolCall override" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tools = testTools();

    var default_model: TestModel = .{ .always_tool_call = true };
    var default_agent = ToolLoopAgent.init(.{
        .model = .{ .model = default_model.languageModel() },
        .tools = &tools,
    });
    var default_result = try default_agent.generate(io, allocator, .{ .prompt = .{ .text = "weather" } });
    defer default_result.deinit();
    try std.testing.expectEqual(20, default_model.calls);
    try std.testing.expectEqual(20, default_result.steps.len);

    var custom_model: TestModel = .{ .always_tool_call = true };
    const custom_stop = [_]generate_text.StopCondition{generate_text.hasToolCall(&.{"weather"})};
    var custom_agent = ToolLoopAgent.init(.{
        .model = .{ .model = custom_model.languageModel() },
        .tools = &tools,
        .stop_when = &custom_stop,
    });
    var custom_result = try custom_agent.generate(io, allocator, .{ .prompt = .{ .text = "weather" } });
    defer custom_result.deinit();
    try std.testing.expectEqual(1, custom_model.calls);
    try std.testing.expectEqual(1, custom_result.steps.len);
}

test "ToolLoopAgent call_options_schema validation matrix reports options diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const CallOptions = struct { topic: enum { legal, medical } };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const valid = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"topic\":\"legal\"}", .{});
    const invalid = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"topic\":\"evil\"}", .{});

    var no_schema_model: TestModel = .{};
    var no_schema_agent = ToolLoopAgent.init(.{ .model = .{ .model = no_schema_model.languageModel() } });
    var no_options = try no_schema_agent.generate(io, allocator, .{ .prompt = .{ .text = "hi" } });
    no_options.deinit();
    var unvalidated_options = try no_schema_agent.generate(io, allocator, .{
        .prompt = .{ .text = "hi" },
        .options = invalid,
    });
    unvalidated_options.deinit();

    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    var schema_model: TestModel = .{};
    var schema_agent = ToolLoopAgent.init(.{
        .model = .{ .model = schema_model.languageModel() },
        .call_options_schema = provider_utils.schemaFromType(CallOptions),
        .diag = &diagnostics,
    });
    var absent_options = try schema_agent.generate(io, allocator, .{ .prompt = .{ .text = "hi" } });
    absent_options.deinit();
    var valid_options = try schema_agent.generate(io, allocator, .{
        .prompt = .{ .text = "hi" },
        .options = valid,
    });
    valid_options.deinit();
    const calls_before_invalid = schema_model.calls;
    try std.testing.expectError(error.TypeValidationError, schema_agent.generate(io, allocator, .{
        .prompt = .{ .text = "hi" },
        .options = invalid,
    }));
    try std.testing.expectEqual(calls_before_invalid, schema_model.calls);
    try std.testing.expect(diagnostics.available);
    try std.testing.expect(diagnostics.payload == .type_validation);
    try std.testing.expectEqualStrings("options", diagnostics.payload.type_validation.context.?.field.?);
}

test "ToolLoopAgent prepare_call rewrites selected fields and inherits the rest" {
    const Context = struct {
        saw_inherited_limit: bool = false,

        fn prepare(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            options: *const PrepareCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.CallError!?PrepareCallResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.saw_inherited_limit = options.max_output_tokens == 64;
            const value = options.options.?.object.get("value").?.string;
            var namespace: std.json.ObjectMap = .empty;
            try namespace.put(arena, "value", .{ .string = try arena.dupe(u8, value) });
            var root: std.json.ObjectMap = .empty;
            try root.put(arena, "test", .{ .object = namespace });
            return .{
                .temperature = 0.75,
                .provider_options = .{ .object = root },
            };
        }
    };

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const options = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"value\":\"rewritten\"}", .{});
    var context: Context = .{};
    var model: TestModel = .{};
    var agent = ToolLoopAgent.init(.{
        .model = .{ .model = model.languageModel() },
        .max_output_tokens = 64,
        .temperature = 0.2,
        .prepare_call = .{ .ctx = &context, .prepare_fn = Context.prepare },
    });
    var result = try agent.generate(std.testing.io, allocator, .{
        .prompt = .{ .text = "hi" },
        .options = options,
    });
    defer result.deinit();
    try std.testing.expect(context.saw_inherited_limit);
    try std.testing.expectEqual(@as(?u64, 64), model.captured_max_output_tokens);
    try std.testing.expectEqual(@as(?f64, 0.75), model.captured_temperature);
    try std.testing.expectEqualStrings("rewritten", model.captured_option_value.?);
}

test "ToolLoopAgent merges settings and call callbacks for generate and stream and swallows errors" {
    const Context = struct {
        settings_calls: std.atomic.Value(usize) = .init(0),
        call_calls: std.atomic.Value(usize) = .init(0),

        fn settingsCallback(raw: ?*anyopaque, _: *const events.StepStartEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.settings_calls.fetchAdd(1, .monotonic);
            return error.ExpectedCallbackFailure;
        }

        fn callCallback(raw: ?*anyopaque, _: *const events.StepStartEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.call_calls.fetchAdd(1, .monotonic);
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var context: Context = .{};
    var model: TestModel = .{};
    var agent = ToolLoopAgent.init(.{
        .model = .{ .model = model.languageModel() },
        .callbacks = .{ .on_step_start = .{ .ctx = &context, .callback = Context.settingsCallback } },
    });
    const call_callbacks: LifecycleCallbacks = .{
        .on_step_start = .{ .ctx = &context, .callback = Context.callCallback },
    };

    var generated = try agent.generate(io, allocator, .{
        .prompt = .{ .text = "hi" },
        .callbacks = call_callbacks,
    });
    generated.deinit();

    var streamed = try agent.stream(io, allocator, .{
        .prompt = .{ .text = "hi" },
        .callbacks = call_callbacks,
    });
    defer streamed.deinit(io);
    try streamed.consumeStream(io);

    try std.testing.expectEqual(2, context.settings_calls.load(.monotonic));
    try std.testing.expectEqual(2, context.call_calls.load(.monotonic));
}

test "ToolLoopAgent appends its user-agent suffix and preserves an existing value" {
    var model: TestModel = .{};
    var agent = ToolLoopAgent.init(.{
        .model = .{ .model = model.languageModel() },
        .headers = &.{.{ .name = "user-agent", .value = "test-client/1" }},
    });
    var result = try agent.generate(std.testing.io, std.testing.allocator, .{ .prompt = .{ .text = "hi" } });
    defer result.deinit();
    try std.testing.expect(model.saw_agent_user_agent);
    try std.testing.expect(model.saw_custom_user_agent);
}

test "ToolLoopAgent enforces prompt XOR messages before model invocation" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var model: TestModel = .{};
    var agent = ToolLoopAgent.init(.{
        .model = .{ .model = model.languageModel() },
        .diag = &diagnostics,
    });
    try std.testing.expectError(
        error.InvalidPromptError,
        agent.generate(std.testing.io, std.testing.allocator, .{}),
    );
    const messages = [_]message.ModelMessage{.{ .user = .{ .content = .{ .text = "hi" } } }};
    try std.testing.expectError(error.InvalidPromptError, agent.generate(
        std.testing.io,
        std.testing.allocator,
        .{ .prompt = .{ .text = "hi" }, .messages = &messages },
    ));
    try std.testing.expectEqual(0, model.calls);
}

test "ToolLoopAgent exposes the Agent V1 fat-pointer surface" {
    var model: TestModel = .{};
    var concrete = ToolLoopAgent.init(.{
        .id = "weather-agent",
        .model = .{ .model = model.languageModel() },
    });
    const agent = concrete.asAgent();
    try std.testing.expectEqualStrings("agent-v1", agent.version);
    try std.testing.expectEqualStrings("weather-agent", agent.id.?);
    var result = try agent.generate(std.testing.io, std.testing.allocator, .{ .prompt = .{ .text = "hi" } });
    defer result.deinit();
    try std.testing.expectEqualStrings("reply", result.text());
}
