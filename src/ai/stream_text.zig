//! Streaming text generation: step assembly, continuation, transforms, and
//! the public lazy result surface.
//!
//! `StreamTextResult.next` is the single pipeline driver. Every processed part
//! is retained in an append-only `Broadcast`; derived cursors replay that log
//! independently. Derived cursors intentionally wait for the driver, while all
//! promise-like accessors call `consumeStream` first so accessor-only use drives
//! the pipeline to completion.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const generate_text = @import("generate_text.zig");
const logger = @import("logger.zig");
const message = @import("message.zig");
const output_api = @import("output.zig");
const prompt_api = @import("prompt.zig");
const registry = @import("registry.zig");
const response_message_builder = @import("response_messages.zig");
const telemetry = @import("telemetry.zig");
const tool_api = @import("tool.zig");
const tool_common = @import("tool_execution_common.zig");
const types = @import("generate_text_types.zig");
const broadcast_api = @import("stream/broadcast.zig");
const model_call = @import("stream/model_call.zig");
const part_stream = @import("stream/part_stream.zig");
const parts = @import("stream/parts.zig");
const stitchable_api = @import("stream/stitchable.zig");
const tool_callbacks = @import("stream/tool_callbacks.zig");
const tool_execution = @import("stream/tool_execution.zig");
const transform_api = @import("stream/transform.zig");

const Allocator = std.mem.Allocator;
pub const TextStreamPart = parts.TextStreamPart;
const Part = TextStreamPart;
const InternalPart = parts.LanguageModelStreamPart;
const Broadcast = broadcast_api.Broadcast(Part);
const Stitchable = stitchable_api.Stitchable(Part);
const ChildStream = stitchable_api.ChildStream(Part);
const OneShot = provider_utils.OneShot;

fn outputValuesEqual(left: ?types.OutputValue, right: types.OutputValue) bool {
    const value = left orelse return false;
    if (std.meta.activeTag(value) != std.meta.activeTag(right)) return false;
    return switch (value) {
        .text => |text_value| std.mem.eql(u8, text_value, right.text),
        .json => |json_value| provider_utils.isDeepEqualData(json_value, right.json),
    };
}

pub const StreamTransform = transform_api.StreamTransform;
pub const StopStreamFn = transform_api.StopStreamFn;
pub const StepResult = types.StepResult;
pub const ContentPart = types.ContentPart;

pub const ChunkEvent = struct { chunk: *const Part };

pub const StreamErrorEvent = struct {
    call_id: []const u8,
    stream_error: parts.StreamError,
};

pub const StreamTextOptions = struct {
    model: registry.LanguageModelRef,
    instructions: ?prompt_api.Instructions = null,
    prompt: ?prompt_api.PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    allow_system_in_messages: bool = false,
    tools: []const tool_api.NamedTool = &.{},
    tool_choice: ?prompt_api.ToolChoice = null,
    active_tools: ?[]const []const u8 = null,
    tool_order: ?[]const []const u8 = null,
    stop_when: []const generate_text.StopCondition = &.{},
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
    max_retries: u32 = 2,
    timeout: ?generate_text.TimeoutConfiguration = null,
    tools_context: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    output: ?generate_text.Output = null,
    callbacks: generate_text.Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    tool_approval_secret: ?[]const u8 = null,
    diag: ?*provider.Diagnostics = null,

    transforms: []const StreamTransform = &.{},
    on_chunk: ?generate_text.Callback(ChunkEvent) = null,
    on_error: ?generate_text.Callback(StreamErrorEvent) = null,
    on_abort: ?generate_text.Callback(events.AbortEvent) = null,
    include_raw_chunks: bool = false,
};

pub const FullStreamCursor = struct {
    cursor: Broadcast.Cursor,

    pub fn next(self: *FullStreamCursor, io: std.Io) std.Io.Cancelable!?Part {
        return self.cursor.next(io);
    }
};

pub const TextStream = struct {
    cursor: Broadcast.Cursor,

    pub fn next(self: *TextStream, io: std.Io) std.Io.Cancelable!?[]const u8 {
        while (try self.cursor.next(io)) |part| switch (part) {
            .text_delta => |delta| return delta.text,
            else => {},
        };
        return null;
    }
};

pub const PartialOutputStream = struct {
    cursor: Broadcast.Cursor,
    first_id: ?[]const u8 = null,
    text: std.ArrayList(u8) = .empty,
    allocator: Allocator,
    parse_arena: std.heap.ArenaAllocator,
    output_spec: output_api.Output,
    latest: ?types.OutputValue = null,

    pub fn next(self: *PartialOutputStream, io: std.Io) anyerror!?types.OutputValue {
        while (try self.cursor.next(io)) |part| switch (part) {
            .text_start => |value| {
                if (self.first_id == null) self.first_id = value.id;
            },
            .text_delta => |value| {
                if (self.first_id == null) self.first_id = value.id;
                if (std.mem.eql(u8, self.first_id.?, value.id)) {
                    try self.text.appendSlice(self.allocator, value.text);
                    const partial = try self.output_spec.parsePartial(
                        self.parse_arena.allocator(),
                        self.text.items,
                    ) orelse continue;
                    if (outputValuesEqual(self.latest, partial)) continue;
                    self.latest = partial;
                    return partial;
                }
            },
            else => {},
        };
        return null;
    }

    pub fn deinit(self: *PartialOutputStream) void {
        self.text.deinit(self.allocator);
        self.parse_arena.deinit();
        self.* = undefined;
    }
};

pub const ElementOutputStream = struct {
    partial: PartialOutputStream,
    pending: []const std.json.Value = &.{},
    pending_index: usize = 0,
    published: usize = 0,

    pub fn next(self: *ElementOutputStream, io: std.Io) anyerror!?std.json.Value {
        while (true) {
            if (self.pending_index < self.pending.len) {
                const value = self.pending[self.pending_index];
                self.pending_index += 1;
                self.published += 1;
                return value;
            }
            const partial = try self.partial.next(io) orelse return null;
            if (partial != .json or partial.json != .array) continue;
            if (partial.json.array.items.len <= self.published) continue;
            self.pending = partial.json.array.items[self.published..];
            self.pending_index = 0;
        }
    }

    pub fn deinit(self: *ElementOutputStream) void {
        self.partial.deinit();
        self.* = undefined;
    }
};

pub const StreamTextResult = struct {
    core: *Core,

    /// Drives the public full stream. In-stream error parts are returned as
    /// data; only pipeline/memory failures use the Zig error channel.
    pub fn next(self: *StreamTextResult, io: std.Io) anyerror!?Part {
        return self.core.next(io);
    }

    /// Independent replay cursor over the complete public part log.
    pub fn fullStream(self: *StreamTextResult) FullStreamCursor {
        return .{ .cursor = self.core.broadcast.cursor() };
    }

    /// Independent text-delta cursor. It waits until `next` or
    /// `consumeStream` advances the driver.
    pub fn textStream(self: *StreamTextResult) TextStream {
        return .{ .cursor = self.core.broadcast.cursor() };
    }

    /// Output-aware partial adapter. Only the first text part is accumulated,
    /// matching upstream's output transform contract.
    pub fn partialOutputStream(self: *StreamTextResult) PartialOutputStream {
        return .{
            .cursor = self.core.broadcast.cursor(),
            .allocator = self.core.gpa,
            .parse_arena = .init(self.core.gpa),
            .output_spec = self.core.options.output orelse output_api.text(),
        };
    }

    pub fn elementStream(
        self: *StreamTextResult,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ElementOutputStream {
        const output_spec = self.core.options.output orelse {
            return unsupportedElementStream(diag);
        };
        if (!output_spec.hasElementStream()) return unsupportedElementStream(diag);
        return .{ .partial = self.partialOutputStream() };
    }

    pub fn consumeStream(self: *StreamTextResult, io: std.Io) anyerror!void {
        while (try self.next(io)) |_| {}
    }

    pub fn text(self: *StreamTextResult, io: std.Io) anyerror![]const u8 {
        try self.consumeAndCheck(io);
        return self.core.steps.items[self.core.steps.items.len - 1].text();
    }

    pub fn reasoningText(self: *StreamTextResult, io: std.Io) anyerror!?[]const u8 {
        try self.consumeAndCheck(io);
        return self.core.steps.items[self.core.steps.items.len - 1].reasoningText();
    }

    pub fn steps(self: *StreamTextResult, io: std.Io) anyerror![]const StepResult {
        try self.consumeAndCheck(io);
        return self.core.steps.items;
    }

    pub fn finalStep(self: *StreamTextResult, io: std.Io) anyerror!*const StepResult {
        try self.consumeAndCheck(io);
        return &self.core.steps.items[self.core.steps.items.len - 1];
    }

    pub fn finishReason(self: *StreamTextResult, io: std.Io) anyerror!provider.FinishReason {
        try self.consumeAndCheck(io);
        return self.core.finish_reason orelse .{ .unified = .other };
    }

    pub fn rawFinishReason(self: *StreamTextResult, io: std.Io) anyerror!?[]const u8 {
        return (try self.finishReason(io)).raw;
    }

    pub fn totalUsage(self: *StreamTextResult, io: std.Io) anyerror!provider.Usage {
        try self.consumeAndCheck(io);
        return self.core.total_usage orelse types.zero_usage;
    }

    pub fn usage(self: *StreamTextResult, io: std.Io) anyerror!provider.Usage {
        return self.totalUsage(io);
    }

    pub fn responseMessages(self: *StreamTextResult, io: std.Io) anyerror![]const message.ModelMessage {
        try self.consumeAndCheck(io);
        return self.core.response_messages.items;
    }

    pub fn content(self: *StreamTextResult, io: std.Io) anyerror![]const ContentPart {
        try self.consumeAndCheck(io);
        return self.core.all_content;
    }

    pub fn toolCalls(self: *StreamTextResult, io: std.Io) anyerror![]const types.TypedToolCall {
        try self.consumeAndCheck(io);
        return self.core.all_tool_calls;
    }

    pub fn toolResults(self: *StreamTextResult, io: std.Io) anyerror![]const types.TypedToolResult {
        try self.consumeAndCheck(io);
        return self.core.all_tool_results;
    }

    pub fn warnings(self: *StreamTextResult, io: std.Io) anyerror![]const provider.Warning {
        try self.consumeAndCheck(io);
        return self.core.all_warnings;
    }

    pub fn request(self: *StreamTextResult, io: std.Io) anyerror!types.RequestMetadata {
        return (try self.finalStep(io)).request;
    }

    pub fn response(self: *StreamTextResult, io: std.Io) anyerror!types.ResponseMetadata {
        return (try self.finalStep(io)).response;
    }

    pub fn providerMetadata(self: *StreamTextResult, io: std.Io) anyerror!?provider.ProviderMetadata {
        return (try self.finalStep(io)).provider_metadata;
    }

    pub fn output(self: *StreamTextResult, io: std.Io) anyerror!types.OutputValue {
        const final_step = try self.finalStep(io);
        const output_spec = self.core.options.output orelse output_api.text();
        return output_spec.parseComplete(self.core.arena, final_step.text(), &.{
            .response = final_step.response,
            .usage = final_step.usage,
            .finish_reason = final_step.finish_reason,
        }, self.core.options.diag);
    }

    pub fn deinit(self: *StreamTextResult, io: std.Io) void {
        const core = self.core;
        core.deinit(io);
        core.gpa.destroy(core);
        self.* = undefined;
    }

    fn consumeAndCheck(self: *StreamTextResult, io: std.Io) anyerror!void {
        try self.consumeStream(io);
        const outcome = try self.core.completion.wait(io);
        try outcome;
    }
};

fn unsupportedElementStream(diag: ?*provider.Diagnostics) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .unsupported_functionality = .{
            .message = "Element streams are only available for array output.",
            .functionality = "element streams in non-array output mode",
        },
    });
    return error.UnsupportedFunctionalityError;
}

pub fn streamText(io: std.Io, gpa: Allocator, options: StreamTextOptions) !StreamTextResult {
    const core = try gpa.create(Core);
    errdefer gpa.destroy(core);
    core.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .options = options,
        .started_at = std.Io.Timestamp.now(io, .awake),
    };
    errdefer core.arena_state.deinit();
    core.arena = core.arena_state.allocator();

    const standardized = try prompt_api.standardizePrompt(core.arena, .{
        .instructions = options.instructions,
        .prompt = options.prompt,
        .messages = options.messages,
        .allow_system_in_messages = options.allow_system_in_messages,
    }, options.diag);
    core.initial_instructions = standardized.instructions;
    core.current_instructions = standardized.instructions;
    core.initial_messages = standardized.messages;
    core.current_messages = standardized.messages;
    core.current_tools_context = try cloneOptionalJson(core.arena, options.tools_context);
    core.current_runtime_context = try cloneOptionalJson(core.arena, options.runtime_context);
    core.options.transforms = try core.arena.dupe(StreamTransform, options.transforms);
    core.options.stop_when = try core.arena.dupe(generate_text.StopCondition, options.stop_when);
    core.options.tools = try core.arena.dupe(tool_api.NamedTool, options.tools);
    core.dispatcher = try telemetry.createTelemetryDispatcher(io, core.arena, options.telemetry);
    core.id_generator = try provider_utils.IdGenerator.initFromIo(io, .{}, options.diag);
    core.call_id = try core.id_generator.nextAlloc(core.arena);
    core.broadcast = Broadcast.init(core.arena);
    core.stitchable.initInline(&core.stitchable_output_buffer, &core.stitchable_child_buffer);

    var pipeline: part_stream.PartStream(Part) = .{
        .ctx = core,
        .vtable = &Core.base_vtable,
    };
    const transform_options: transform_api.TransformOptions = .{
        .tools = core.options.tools,
        .stop_stream = .{ .ctx = core, .call_fn = Core.stopStream },
    };
    for (core.options.transforms) |transform| {
        pipeline = try transform.wrap(core.arena, pipeline, transform_options);
    }
    core.pipeline = pipeline;
    return .{ .core = core };
}

const Core = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    arena: Allocator = undefined,
    options: StreamTextOptions,
    dispatcher: telemetry.Dispatcher = undefined,
    id_generator: provider_utils.IdGenerator = undefined,
    call_id: []const u8 = "",
    started_at: std.Io.Timestamp,

    initial_instructions: ?prompt_api.Instructions = null,
    current_instructions: ?prompt_api.Instructions = null,
    initial_messages: []const message.ModelMessage = &.{},
    current_messages: []const message.ModelMessage = &.{},
    current_tools_context: ?std.json.Value = null,
    current_runtime_context: ?std.json.Value = null,
    current_model: ?provider.LanguageModel = null,
    current_step_finish: ?*OneShot(void) = null,

    stitchable_output_buffer: [16]Part = undefined,
    stitchable_child_buffer: [2]*ChildStream = undefined,
    stitchable: Stitchable = undefined,
    pipeline: part_stream.PartStream(Part) = undefined,
    broadcast: Broadcast = undefined,
    driver_mutex: std.Io.Mutex = .init,
    base_started: bool = false,
    setup_complete: bool = false,
    running: std.atomic.Value(bool) = .init(true),
    finalized: bool = false,
    aborted: bool = false,
    abort_reason: ?[]const u8 = null,
    timeout_warning_logged: bool = false,
    pending_part: ?Part = null,

    steps: std.ArrayList(StepResult) = .empty,
    response_messages: std.ArrayList(message.ModelMessage) = .empty,
    pending_deferred: std.StringHashMapUnmanaged([]const u8) = .empty,
    finish_reason: ?provider.FinishReason = null,
    total_usage: ?provider.Usage = null,
    accumulated_usage: provider.Usage = types.zero_usage,
    recorded_no_output: bool = false,
    machinery_error: ?anyerror = null,
    completion: OneShot(anyerror!void) = .{},

    recorded_content: std.ArrayList(ContentPart) = .empty,
    active_text: std.StringHashMapUnmanaged(ActiveText) = .empty,
    active_reasoning: std.StringHashMapUnmanaged(ActiveText) = .empty,
    recorded_request: types.RequestMetadata = .{},
    recorded_warnings: []const provider.Warning = &.{},
    all_content: []const ContentPart = &.{},
    all_tool_calls: []const types.TypedToolCall = &.{},
    all_tool_results: []const types.TypedToolResult = &.{},
    all_warnings: []const provider.Warning = &.{},

    const base_vtable: part_stream.PartStream(Part).VTable = .{
        .next = baseNext,
        .deinit = baseDeinit,
    };

    fn next(self: *Core, io: std.Io) anyerror!?Part {
        try self.driver_mutex.lock(io);
        defer self.driver_mutex.unlock(io);
        if (self.pending_part) |pending| {
            self.pending_part = null;
            return try self.process(io, pending);
        }
        if (self.finalized) return null;

        const maybe_part = self.pipeline.next(io) catch |err| switch (err) {
            error.Canceled => return try abort(self, io),
            else => {
                self.machinery_error = err;
                finalize(self, io);
                return err;
            },
        };
        const part = maybe_part orelse {
            finalize(self, io);
            return null;
        };
        return try self.process(io, part);
    }

    fn process(self: *Core, io: std.Io, part: Part) anyerror!?Part {
        return processPart(self, io, part) catch |err| switch (err) {
            error.Canceled => return try abort(self, io),
            else => {
                self.machinery_error = err;
                self.running.store(false, .release);
                self.stitchable.terminate(io);
                if (self.current_step_finish) |cell| {
                    cell.resolve(io, {});
                    self.current_step_finish = null;
                }
                finalize(self, io);
                return err;
            },
        };
    }

    fn baseNext(raw: *anyopaque, io: std.Io) anyerror!?Part {
        const self: *Core = @ptrCast(@alignCast(raw));
        if (!self.base_started) {
            self.base_started = true;
            return .{ .start = {} };
        }
        if (!self.setup_complete) try ensureStarted(self, io);
        if (!self.running.load(.acquire)) return null;
        return self.stitchable.next(io);
    }

    fn baseDeinit(raw: *anyopaque, io: std.Io) void {
        const self: *Core = @ptrCast(@alignCast(raw));
        self.stitchable.deinit(io);
    }

    fn stopStream(raw: *anyopaque, io: std.Io) void {
        const self: *Core = @ptrCast(@alignCast(raw));
        self.running.store(false, .release);
        self.stitchable.terminate(io);
    }

    fn deinit(self: *Core, io: std.Io) void {
        if (!self.finalized) {
            self.running.store(false, .release);
            self.stitchable.terminate(io);
        }
        self.pipeline.deinit(io);
        self.broadcast.deinit();
        self.arena_state.deinit();
    }

    fn nextId(self: *Core) Allocator.Error![]const u8 {
        return self.id_generator.nextAlloc(self.arena);
    }
};

const ActiveText = struct {
    content_index: usize,
    bytes: std.ArrayList(u8) = .empty,
};

fn ensureStarted(self: *Core, io: std.Io) anyerror!void {
    self.setup_complete = true;
    const resolved_model = try registry.resolveLanguageModel(self.options.model, self.options.diag);
    const call_settings = try prompt_api.prepareLanguageModelCallOptions(self.arena, .{
        .max_output_tokens = self.options.max_output_tokens,
        .temperature = self.options.temperature,
        .top_p = self.options.top_p,
        .top_k = self.options.top_k,
        .presence_penalty = self.options.presence_penalty,
        .frequency_penalty = self.options.frequency_penalty,
        .stop_sequences = self.options.stop_sequences,
        .seed = self.options.seed,
        .reasoning = self.options.reasoning,
    }, self.options.diag);
    const start_event: events.GenerateTextStartEvent = .{
        .call_id = self.call_id,
        .operation_id = "ai.streamText",
        .provider_name = resolved_model.provider(),
        .model_id = resolved_model.modelId(),
        .instructions = instructionsText(self.initial_instructions),
        .messages = self.initial_messages,
        .tools = self.options.tools,
        .tool_choice = prompt_api.prepareToolChoice(self.options.tool_choice),
        .max_retries = self.options.max_retries,
        .timeout_ms = if (self.options.timeout) |timeout| timeout.totalMs() else null,
        .max_output_tokens = call_settings.max_output_tokens,
        .temperature = call_settings.temperature,
        .top_p = call_settings.top_p,
        .top_k = call_settings.top_k,
        .presence_penalty = call_settings.presence_penalty,
        .frequency_penalty = call_settings.frequency_penalty,
        .stop_sequences = call_settings.stop_sequences,
        .seed = call_settings.seed,
        .reasoning = call_settings.reasoning,
        .provider_options = self.options.provider_options,
        .runtime_context = self.current_runtime_context,
        .tools_context = self.current_tools_context,
    };
    if (self.options.callbacks.on_start) |callback| callback.callback(callback.ctx, &start_event) catch {};
    try self.dispatcher.onStart(&start_event);

    const approval_replay = generate_text.replayInitialToolApprovals(.{
        .io = io,
        .gpa = self.gpa,
        .arena = self.arena,
        .options = generateOptions(self.options),
        .dispatcher = &self.dispatcher,
        .id_generator = &self.id_generator,
        .call_id = self.call_id,
        .initial_messages = self.initial_messages,
        .initial_instructions = self.initial_instructions,
        .tools_context = self.current_tools_context,
        .runtime_context = self.current_runtime_context,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            try addErrorAndClose(self, io, err);
            return;
        },
    };
    self.current_messages = approval_replay.current_messages;
    try self.response_messages.appendSlice(self.arena, approval_replay.response_messages);

    createAndAddStep(self, io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => try addErrorAndClose(self, io, err),
    };
}

fn generateOptions(options: StreamTextOptions) generate_text.GenerateTextOptions {
    return .{
        .model = options.model,
        .instructions = options.instructions,
        .prompt = options.prompt,
        .messages = options.messages,
        .allow_system_in_messages = options.allow_system_in_messages,
        .tools = options.tools,
        .tool_choice = options.tool_choice,
        .active_tools = options.active_tools,
        .tool_order = options.tool_order,
        .stop_when = options.stop_when,
        .prepare_step = options.prepare_step,
        .repair_tool_call = options.repair_tool_call,
        .refine_tool_input = options.refine_tool_input,
        .max_output_tokens = options.max_output_tokens,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .top_k = options.top_k,
        .presence_penalty = options.presence_penalty,
        .frequency_penalty = options.frequency_penalty,
        .stop_sequences = options.stop_sequences,
        .seed = options.seed,
        .reasoning = options.reasoning,
        .headers = options.headers,
        .provider_options = options.provider_options,
        .max_retries = options.max_retries,
        .timeout = options.timeout,
        .tools_context = options.tools_context,
        .runtime_context = options.runtime_context,
        .output = options.output,
        .callbacks = options.callbacks,
        .telemetry = options.telemetry,
        .tool_approval_secret = options.tool_approval_secret,
        .diag = options.diag,
    };
}

fn createAndAddStep(self: *Core, io: std.Io) anyerror!void {
    const step_number = self.steps.items.len;
    var step_model_ref = self.options.model;
    var step_tool_choice = self.options.tool_choice;
    var active_tools = self.options.active_tools;
    var tool_order = self.options.tool_order;
    var step_instructions = self.current_instructions;
    var step_messages = self.current_messages;
    var step_tools_context = self.current_tools_context;
    var step_runtime_context = self.current_runtime_context;
    var step_provider_options = self.options.provider_options;

    if (self.options.prepare_step) |prepare| {
        const prepared = try prepare.prepare(io, self.arena, &.{
            .steps = self.steps.items,
            .step_number = step_number,
            .model = try registry.resolveLanguageModel(self.options.model, self.options.diag),
            .instructions = self.current_instructions,
            .initial_instructions = self.initial_instructions,
            .messages = self.current_messages,
            .initial_messages = self.initial_messages,
            .response_messages = self.response_messages.items,
            .tools_context = self.current_tools_context,
            .runtime_context = self.current_runtime_context,
        });
        if (prepared) |value| {
            step_model_ref = value.model orelse step_model_ref;
            step_tool_choice = value.tool_choice orelse step_tool_choice;
            active_tools = value.active_tools orelse active_tools;
            tool_order = value.tool_order orelse tool_order;
            step_instructions = value.instructions orelse step_instructions;
            if (value.messages) |items| step_messages = try message.cloneModelMessages(self.arena, items);
            step_tools_context = if (value.tools_context) |context|
                try provider_utils.cloneJsonValue(self.arena, context)
            else
                step_tools_context;
            step_runtime_context = if (value.runtime_context) |context|
                try provider_utils.cloneJsonValue(self.arena, context)
            else
                step_runtime_context;
            step_provider_options = try mergeOptionalJson(
                self.arena,
                step_provider_options,
                value.provider_options,
            );
        }
    }

    const selected_tools = try generate_text.filterActiveTools(self.arena, self.options.tools, active_tools);
    const step_model = try registry.resolveLanguageModel(step_model_ref, self.options.diag);
    self.current_model = step_model;
    self.current_instructions = step_instructions;
    self.current_messages = step_messages;
    self.current_tools_context = step_tools_context;
    self.current_runtime_context = step_runtime_context;

    const step_start_event: events.StepStartEvent = .{
        .call_id = self.call_id,
        .provider_name = step_model.provider(),
        .model_id = step_model.modelId(),
        .step_number = step_number,
        .instructions = instructionsText(step_instructions),
        .messages = step_messages,
        .tools = selected_tools,
        .tool_choice = prompt_api.prepareToolChoice(step_tool_choice),
        .previous_steps = self.steps.items,
        .provider_options = step_provider_options,
        .runtime_context = step_runtime_context,
        .tools_context = step_tools_context,
    };
    if (self.options.callbacks.on_step_start) |callback| callback.callback(callback.ctx, &step_start_event) catch {};
    try self.dispatcher.onStepStart(&step_start_event);

    const owner = try self.gpa.create(StepOwner);
    errdefer self.gpa.destroy(owner);
    owner.* = .{ .arena_state = std.heap.ArenaAllocator.init(self.gpa) };
    errdefer owner.arena_state.deinit();
    const step_arena = owner.arena_state.allocator();
    const step_started = std.Io.Timestamp.now(io, .awake);

    const stage1 = try model_call.streamLanguageModelCall(io, self.gpa, step_arena, .{
        .model = step_model_ref,
        .instructions = step_instructions,
        .messages = step_messages,
        .allow_system_in_messages = self.options.allow_system_in_messages,
        .tools = selected_tools,
        .tool_order = tool_order,
        .tool_choice = step_tool_choice,
        .tools_context = step_tools_context,
        .call_settings = .{
            .max_output_tokens = self.options.max_output_tokens,
            .temperature = self.options.temperature,
            .top_p = self.options.top_p,
            .top_k = self.options.top_k,
            .presence_penalty = self.options.presence_penalty,
            .frequency_penalty = self.options.frequency_penalty,
            .stop_sequences = self.options.stop_sequences,
            .seed = self.options.seed,
            .reasoning = self.options.reasoning,
        },
        .response_format = try (self.options.output orelse output_api.text()).responseFormat(
            io,
            step_arena,
            self.options.diag,
        ),
        .headers = self.options.headers,
        .provider_options = step_provider_options,
        .include_raw_chunks = self.options.include_raw_chunks,
        .max_retries = self.options.max_retries,
        .repair_tool_call = self.options.repair_tool_call,
        .refine_tool_input = self.options.refine_tool_input,
        .telemetry_options = self.options.telemetry,
        .call_id = self.call_id,
        .on_language_model_call_start = callbackAdapter(events.LanguageModelCallStartEvent, self.options.callbacks.on_language_model_call_start),
        .on_language_model_call_end = callbackAdapter(events.LanguageModelCallEndEvent, self.options.callbacks.on_language_model_call_end),
        .diag = self.options.diag,
    });
    errdefer stage1.stage.deinit(io);
    const stage2 = try tool_callbacks.invokeToolCallbacksFromStream(step_arena, .{
        .upstream = stage1.stage,
        .tools = selected_tools,
        .messages = step_messages,
        .runtime_context = step_runtime_context,
    });
    const output_buffer = try step_arena.alloc(InternalPart, 8);
    const stage3 = try tool_execution.executeToolsFromStream(io, self.gpa, step_arena, .{
        .upstream = stage2,
        .output_buffer = output_buffer,
        .tools = selected_tools,
        .call_id = self.call_id,
        .messages = step_messages,
        .tools_context = step_tools_context,
        .timeout = self.options.timeout,
        .telemetry_options = self.options.telemetry,
        .on_tool_execution_start = callbackAdapter(events.ToolExecutionStartEvent, self.options.callbacks.on_tool_execution_start),
        .on_tool_execution_end = callbackAdapter(events.ToolExecutionEndEvent, self.options.callbacks.on_tool_execution_end),
        .diag = self.options.diag,
    });

    const finish_cell = try self.arena.create(OneShot(void));
    finish_cell.* = .{};
    self.current_step_finish = finish_cell;
    const state = try step_arena.create(StepState);
    state.* = .{
        .owner = owner,
        .core = self,
        .upstream = stage3,
        .finish_cell = finish_cell,
        .step_started = step_started,
        .request = try cloneRequestMetadata(self.arena, .{
            .body = stage1.request_info.body,
            .messages = step_messages,
        }),
        .response_headers = try cloneHeaders(self.arena, stage1.response_info.headers),
        .previous_usage = self.accumulated_usage,
    };
    const child = try self.arena.create(ChildStream);
    child.* = .{ .ctx = state, .vtable = &StepState.vtable };
    try self.stitchable.addStream(io, child);
}

fn addErrorAndClose(self: *Core, io: std.Io, err: anyerror) anyerror!void {
    const state = try self.arena.create(ErrorChild);
    state.* = .{ .part = .{ .err = try streamErrorFromError(self.arena, err, self.options.diag) } };
    const child = try self.arena.create(ChildStream);
    child.* = .{ .ctx = state, .vtable = &ErrorChild.vtable };
    try self.stitchable.addStream(io, child);
    self.stitchable.close(io);
}

fn processPart(self: *Core, io: std.Io, input: Part) anyerror!Part {
    const part = try cloneTextStreamPart(self.arena, input);
    try self.broadcast.append(io, part);
    if (self.options.on_chunk) |callback| {
        const event: ChunkEvent = .{ .chunk = &part };
        callback.callback(callback.ctx, &event) catch {};
    }

    switch (part) {
        .start_step => |value| startStep(self, value),
        .text_start => |value| try startText(self, .text, value),
        .text_delta => |value| try appendText(self, .text, value),
        .text_end => |value| try endText(self, .text, value),
        .reasoning_start => |value| try startText(self, .reasoning, value),
        .reasoning_delta => |value| try appendText(self, .reasoning, value),
        .reasoning_end => |value| try endText(self, .reasoning, value),
        .custom => |value| try self.recorded_content.append(self.arena, .{ .custom = .{
            .kind = value.kind,
            .provider_metadata = value.provider_metadata,
        } }),
        .source => |value| try self.recorded_content.append(self.arena, .{ .source = value }),
        .file => |value| try self.recorded_content.append(self.arena, .{ .file = value }),
        .reasoning_file => |value| try self.recorded_content.append(self.arena, .{ .reasoning_file = value }),
        .tool_call => |value| try self.recorded_content.append(self.arena, .{ .tool_call = value }),
        .tool_result => |value| if (!value.preliminary) try self.recorded_content.append(self.arena, .{ .tool_result = value }),
        .tool_error => |value| try self.recorded_content.append(self.arena, .{ .tool_error = value }),
        .tool_approval_request => |value| try self.recorded_content.append(self.arena, .{ .tool_approval_request = value }),
        .tool_approval_response => |value| try self.recorded_content.append(self.arena, .{ .tool_approval_response = value }),
        .finish_step => |value| try finishStep(self, io, value),
        .finish => |value| {
            self.finish_reason = .{ .unified = value.finish_reason.unified, .raw = value.raw_finish_reason };
            self.total_usage = value.total_usage;
        },
        .err => |value| try onError(self, value),
        .abort => {},
        .start, .tool_input_start, .tool_input_delta, .tool_input_end, .tool_output_denied, .raw => {},
    }

    if (part == .abort) finalize(self, io);
    return part;
}

fn startStep(self: *Core, value: parts.StartStep) void {
    self.recorded_content.clearRetainingCapacity();
    self.active_text.clearRetainingCapacity();
    self.active_reasoning.clearRetainingCapacity();
    self.recorded_request = value.request;
    self.recorded_warnings = value.warnings;
}

const TextKind = enum { text, reasoning };

fn startText(self: *Core, kind: TextKind, value: parts.TextBlockBoundary) anyerror!void {
    const index = self.recorded_content.items.len;
    try self.recorded_content.append(self.arena, switch (kind) {
        .text => .{ .text = .{ .text = "", .provider_metadata = value.provider_metadata } },
        .reasoning => .{ .reasoning = .{ .text = "", .provider_metadata = value.provider_metadata } },
    });
    const active: ActiveText = .{ .content_index = index };
    switch (kind) {
        .text => try self.active_text.put(self.arena, value.id, active),
        .reasoning => try self.active_reasoning.put(self.arena, value.id, active),
    }
}

fn appendText(self: *Core, kind: TextKind, value: parts.TextDelta) anyerror!void {
    const active = switch (kind) {
        .text => self.active_text.getPtr(value.id),
        .reasoning => self.active_reasoning.getPtr(value.id),
    } orelse {
        self.pending_part = .{ .err = try missingTextError(self.arena, kind, value.id) };
        return;
    };
    try active.bytes.appendSlice(self.arena, value.text);
    switch (self.recorded_content.items[active.content_index]) {
        .text => |*content| {
            content.text = active.bytes.items;
            content.provider_metadata = value.provider_metadata orelse content.provider_metadata;
        },
        .reasoning => |*content| {
            content.text = active.bytes.items;
            content.provider_metadata = value.provider_metadata orelse content.provider_metadata;
        },
        else => unreachable,
    }
}

fn endText(self: *Core, kind: TextKind, value: parts.TextBlockBoundary) anyerror!void {
    const removed = switch (kind) {
        .text => self.active_text.fetchRemove(value.id),
        .reasoning => self.active_reasoning.fetchRemove(value.id),
    } orelse {
        self.pending_part = .{ .err = try missingTextError(self.arena, kind, value.id) };
        return;
    };
    switch (self.recorded_content.items[removed.value.content_index]) {
        .text => |*content| content.provider_metadata = value.provider_metadata orelse content.provider_metadata,
        .reasoning => |*content| content.provider_metadata = value.provider_metadata orelse content.provider_metadata,
        else => unreachable,
    }
}

fn finishStep(self: *Core, io: std.Io, value: parts.FinishStep) anyerror!void {
    const step_response_messages = try response_message_builder.toResponseMessages(
        self.arena,
        self.options.tools,
        self.recorded_content.items,
    );
    const cloned_messages = try message.cloneModelMessages(self.arena, step_response_messages);
    var response = value.response;
    response.messages = cloned_messages;
    const model = self.current_model.?;
    var step: StepResult = .{
        .call_id = self.call_id,
        .step_number = self.steps.items.len,
        .model = .{
            .provider_name = try self.arena.dupe(u8, model.provider()),
            .model_id = try self.arena.dupe(u8, model.modelId()),
        },
        .tools_context = try cloneOptionalJson(self.arena, self.current_tools_context),
        .runtime_context = try cloneOptionalJson(self.arena, self.current_runtime_context),
        .content = try self.arena.dupe(ContentPart, self.recorded_content.items),
        .finish_reason = .{ .unified = value.finish_reason.unified, .raw = value.raw_finish_reason },
        .usage = value.usage,
        .performance = value.performance,
        .warnings = self.recorded_warnings,
        .request = self.recorded_request,
        .response = response,
        .provider_metadata = value.provider_metadata,
    };
    try step.derive(self.arena);
    try self.steps.append(self.arena, step);
    const stored = &self.steps.items[self.steps.items.len - 1];
    for (cloned_messages) |item| try self.response_messages.append(self.arena, item);

    const event: events.StepEndEvent = .{
        .call_id = self.call_id,
        .step_number = stored.step_number,
        .step_result = stored,
    };
    if (self.options.callbacks.on_step_end) |callback| callback.callback(callback.ctx, &event) catch {};
    try self.dispatcher.onStepEnd(&event);

    self.current_messages = try concatMessages(self.arena, self.current_messages, cloned_messages);
    if (self.current_step_finish) |cell| {
        cell.resolve(io, {});
        self.current_step_finish = null;
    }
}

fn onError(self: *Core, value: parts.StreamError) anyerror!void {
    if (value.error_code) |error_code| {
        if (error_code == error.NoOutputGeneratedError) self.recorded_no_output = true;
    }
    const event: StreamErrorEvent = .{ .call_id = self.call_id, .stream_error = value };
    if (self.options.on_error) |callback| {
        callback.callback(callback.ctx, &event) catch {};
    } else {
        logStreamError(value);
    }
    const generic_event: events.ErrorEvent = .{
        .call_id = self.call_id,
        .err = value.error_code orelse error.InvalidStreamPartError,
        .diag = self.options.diag,
    };
    if (self.options.callbacks.on_error) |callback| callback.callback(callback.ctx, &generic_event) catch {};
    try self.dispatcher.onError(&generic_event);
}

fn abort(self: *Core, io: std.Io) anyerror!?Part {
    if (self.aborted) return null;
    self.aborted = true;
    self.running.store(false, .release);
    self.stitchable.terminate(io);
    const event: events.AbortEvent = .{
        .call_id = self.call_id,
        .steps = self.steps.items,
        .reason = self.abort_reason,
    };
    if (self.options.on_abort) |callback| callback.callback(callback.ctx, &event) catch {};
    if (self.options.callbacks.on_abort) |callback| callback.callback(callback.ctx, &event) catch {};
    self.dispatcher.onAbort(&event) catch {};
    return try processPart(self, io, .{ .abort = .{ .reason = self.abort_reason } });
}

fn finalize(self: *Core, io: std.Io) void {
    if (self.finalized) return;
    self.finalized = true;
    self.running.store(false, .release);

    var failure: ?anyerror = if (self.aborted)
        error.Canceled
    else if (self.machinery_error) |err|
        err
    else if (self.recorded_no_output or self.steps.items.len == 0)
        error.NoOutputGeneratedError
    else
        null;

    if (failure == null) {
        self.finish_reason = self.finish_reason orelse self.steps.items[self.steps.items.len - 1].finish_reason;
        self.total_usage = self.total_usage orelse aggregateUsage(self.steps.items);
        buildAggregates(self) catch |err| {
            self.machinery_error = err;
            failure = err;
        };
        if (failure == null) {
            const final_step = &self.steps.items[self.steps.items.len - 1];
            const event: events.EndEvent = .{
                .call_id = self.call_id,
                .step_number = final_step.step_number,
                .model = self.current_model.?,
                .text = final_step.text(),
                .content = self.all_content,
                .finish_reason = self.finish_reason.?,
                .usage = self.total_usage.?,
                .warnings = self.all_warnings,
                .response_messages = self.response_messages.items,
                .steps = self.steps.items,
                .final_step = final_step,
                .runtime_context = final_step.runtime_context,
                .tools_context = final_step.tools_context,
            };
            if (self.options.callbacks.on_end) |callback| callback.callback(callback.ctx, &event) catch {};
            self.dispatcher.onEnd(&event) catch |err| {
                self.machinery_error = err;
                failure = err;
            };
        }
    }

    self.broadcast.close(io);
    self.completion.resolve(io, if (failure) |err| err else {});
}

fn buildAggregates(self: *Core) Allocator.Error!void {
    var content: std.ArrayList(ContentPart) = .empty;
    var calls: std.ArrayList(types.TypedToolCall) = .empty;
    var results: std.ArrayList(types.TypedToolResult) = .empty;
    var warnings: std.ArrayList(provider.Warning) = .empty;
    for (self.steps.items) |step| {
        try content.appendSlice(self.arena, step.content);
        try calls.appendSlice(self.arena, step.toolCalls());
        try results.appendSlice(self.arena, step.toolResults());
        try warnings.appendSlice(self.arena, step.warnings);
    }
    self.all_content = try content.toOwnedSlice(self.arena);
    self.all_tool_calls = try calls.toOwnedSlice(self.arena);
    self.all_tool_results = try results.toOwnedSlice(self.arena);
    self.all_warnings = try warnings.toOwnedSlice(self.arena);
}

const StepOwner = struct {
    arena_state: std.heap.ArenaAllocator,
};

const ErrorChild = struct {
    part: Part,
    emitted: bool = false,

    const vtable: ChildStream.VTable = .{ .next = next };

    fn next(raw: *anyopaque, _: std.Io) anyerror!?Part {
        const self: *ErrorChild = @ptrCast(@alignCast(raw));
        if (self.emitted) return null;
        self.emitted = true;
        return self.part;
    }
};

const StepState = struct {
    owner: *StepOwner,
    core: *Core,
    upstream: part_stream.PartStream(InternalPart),
    finish_cell: *OneShot(void),
    step_started: std.Io.Timestamp,
    request: types.RequestMetadata,
    response_headers: ?provider.Headers,
    previous_usage: provider.Usage,

    phase: enum { pulling, waiting_for_processor, done } = .pulling,
    pending: ?Part = null,
    emitted_start_step: bool = false,
    has_terminal: bool = false,
    has_output: bool = false,
    warnings: []const provider.Warning = &.{},
    finish_reason: provider.FinishReason = .{ .unified = .other },
    usage: provider.Usage = types.zero_usage,
    provider_metadata: ?provider.ProviderMetadata = null,
    performance: parts.ModelCallPerformance = .{
        .response_time_ms = 0,
        .effective_output_tokens_per_second = 0,
        .effective_total_tokens_per_second = 0,
    },
    response_id: ?[]const u8 = null,
    response_timestamp_ms: ?i64 = null,
    response_model_id: ?[]const u8 = null,
    tool_calls: std.ArrayList(types.TypedToolCall) = .empty,
    tool_outputs: std.ArrayList(ToolOutput) = .empty,
    approval_responses: std.ArrayList(types.ToolApprovalResponse) = .empty,
    tool_timings: std.ArrayList(types.ToolExecutionTiming) = .empty,
    last_upstream_part: ?std.Io.Timestamp = null,
    deinitialized: bool = false,

    const ToolOutput = union(enum) {
        result: types.TypedToolResult,
        tool_error: types.TypedToolError,
    };

    const vtable: ChildStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?Part {
        const self: *StepState = @ptrCast(@alignCast(raw));
        if (self.pending) |part| {
            self.pending = null;
            return part;
        }

        switch (self.phase) {
            .done => return null,
            .waiting_for_processor => return self.afterFinishStep(io),
            .pulling => {},
        }

        while (true) {
            const maybe_internal = try self.pullUpstream(io);
            const internal = maybe_internal orelse return self.endStep(io);
            if (internal == .model_call_start) {
                self.warnings = try cloneWarnings(self.core.arena, internal.model_call_start.warnings);
                const model = self.core.current_model.?;
                logger.logWarnings(self.core.arena, .{
                    .warnings = self.warnings,
                    .provider_name = model.provider(),
                    .model = model.modelId(),
                });
                continue;
            }

            const public_part = try self.consumeInternal(internal);
            if (!self.emitted_start_step) {
                self.emitted_start_step = true;
                self.pending = public_part;
                return .{ .start_step = .{
                    .request = self.request,
                    .warnings = self.warnings,
                } };
            }
            if (public_part) |part| return part;
        }
    }

    fn consumeInternal(self: *StepState, internal: InternalPart) anyerror!?Part {
        if (isOutputInternalPart(internal)) self.has_output = true;
        return switch (internal) {
            .text_start => |value| .{ .text_start = try cloneBoundary(self.core.arena, value) },
            .text_end => |value| .{ .text_end = try cloneBoundary(self.core.arena, value) },
            .text_delta => |value| if (value.text.len == 0)
                null
            else
                .{ .text_delta = try cloneDelta(self.core.arena, value) },
            .reasoning_start => |value| .{ .reasoning_start = try cloneBoundary(self.core.arena, value) },
            .reasoning_end => |value| .{ .reasoning_end = try cloneBoundary(self.core.arena, value) },
            .reasoning_delta => |value| .{ .reasoning_delta = try cloneDelta(self.core.arena, value) },
            .custom => |value| .{ .custom = try cloneCustom(self.core.arena, value) },
            .tool_input_start => |value| .{ .tool_input_start = try cloneToolInputStart(self.core.arena, value) },
            .tool_input_end => |value| .{ .tool_input_end = try cloneToolInputEnd(self.core.arena, value) },
            .tool_input_delta => |value| .{ .tool_input_delta = try cloneToolInputDelta(self.core.arena, value) },
            .source => |value| .{ .source = try cloneSource(self.core.arena, value) },
            .file => |value| .{ .file = try cloneGeneratedFile(self.core.arena, value) },
            .reasoning_file => |value| .{ .reasoning_file = try cloneReasoningFile(self.core.arena, value) },
            .tool_call => |value| blk: {
                const cloned = try cloneToolCall(self.core.arena, value);
                try self.tool_calls.append(self.core.arena, cloned);
                break :blk .{ .tool_call = cloned };
            },
            .tool_result => |value| blk: {
                const cloned = try cloneToolResult(self.core.arena, value);
                if (!cloned.preliminary) try self.tool_outputs.append(self.core.arena, .{ .result = cloned });
                break :blk .{ .tool_result = cloned };
            },
            .tool_error => |value| blk: {
                const cloned = try cloneToolError(self.core.arena, value);
                try self.tool_outputs.append(self.core.arena, .{ .tool_error = cloned });
                break :blk .{ .tool_error = cloned };
            },
            .tool_approval_request => |value| .{ .tool_approval_request = try cloneApprovalRequest(self.core.arena, value) },
            .tool_approval_response => |value| blk: {
                const cloned = try cloneApprovalResponse(self.core.arena, value);
                try self.approval_responses.append(self.core.arena, cloned);
                break :blk .{ .tool_approval_response = cloned };
            },
            .raw => |value| if (self.core.options.include_raw_chunks)
                .{ .raw = try provider_utils.cloneJsonValue(self.core.arena, value) }
            else
                null,
            .err => |value| blk: {
                self.has_terminal = true;
                self.finish_reason = .{ .unified = .@"error" };
                break :blk .{ .err = try cloneStreamError(self.core.arena, value) };
            },
            .model_call_response_metadata => |value| blk: {
                self.response_id = if (value.id) |id| try self.core.arena.dupe(u8, id) else self.response_id;
                self.response_timestamp_ms = value.timestamp_ms orelse self.response_timestamp_ms;
                self.response_model_id = if (value.model_id) |id| try self.core.arena.dupe(u8, id) else self.response_model_id;
                break :blk null;
            },
            .model_call_end => |value| blk: {
                self.has_terminal = true;
                self.finish_reason = .{
                    .unified = value.finish_reason.unified,
                    .raw = if (value.raw_finish_reason) |raw| try self.core.arena.dupe(u8, raw) else null,
                };
                self.usage = try cloneUsage(self.core.arena, value.usage);
                self.provider_metadata = try cloneOptionalJson(self.core.arena, value.provider_metadata);
                self.performance = value.performance;
                break :blk null;
            },
            .tool_execution_end => |value| blk: {
                try self.tool_timings.append(self.core.arena, .{
                    .tool_call_id = try self.core.arena.dupe(u8, value.tool_call_id),
                    .milliseconds = value.tool_execution_ms,
                });
                break :blk null;
            },
            .model_call_start => unreachable,
        };
    }

    fn endStep(self: *StepState, io: std.Io) anyerror!?Part {
        if (!self.has_terminal and !self.has_output) {
            self.phase = .done;
            self.core.recorded_no_output = true;
            self.core.stitchable.close(io);
            return .{ .err = .{
                .error_value = .{ .string = try self.core.arena.dupe(
                    u8,
                    "No output generated. The model stream ended without a finish chunk.",
                ) },
                .error_code = error.NoOutputGeneratedError,
            } };
        }

        self.phase = .waiting_for_processor;
        const model = self.core.current_model.?;
        const response_id = self.response_id orelse try self.core.nextId();
        const response_model_id = self.response_model_id orelse try self.core.arena.dupe(u8, model.modelId());
        return .{ .finish_step = .{
            .response = .{
                .id = response_id,
                .timestamp_ms = self.response_timestamp_ms orelse timestampMilliseconds(io),
                .model_id = response_model_id,
                .headers = self.response_headers,
            },
            .usage = self.usage,
            .performance = .{
                .effective_output_tokens_per_second = self.performance.effective_output_tokens_per_second,
                .output_tokens_per_second = self.performance.output_tokens_per_second,
                .input_tokens_per_second = self.performance.input_tokens_per_second,
                .effective_total_tokens_per_second = self.performance.effective_total_tokens_per_second,
                .step_time_ms = tool_common.elapsedMilliseconds(
                    self.step_started,
                    std.Io.Timestamp.now(io, .awake),
                ),
                .response_time_ms = self.performance.response_time_ms,
                .tool_execution_ms = try self.tool_timings.toOwnedSlice(self.core.arena),
                .time_to_first_output_ms = self.performance.time_to_first_output_ms,
                .time_between_output_chunks_ms = self.performance.time_between_output_chunks_ms,
            },
            .finish_reason = self.finish_reason,
            .raw_finish_reason = self.finish_reason.raw,
            .provider_metadata = self.provider_metadata,
        } };
    }

    fn afterFinishStep(self: *StepState, io: std.Io) anyerror!?Part {
        try self.finish_cell.wait(io);
        self.phase = .done;
        try self.updateDeferredCalls();

        var client_call_count: usize = 0;
        var client_output_count: usize = 0;
        var denied_count: usize = 0;
        for (self.tool_calls.items) |call| if (!call.provider_executed) {
            client_call_count += 1;
        };
        for (self.tool_outputs.items) |output| switch (output) {
            .result => |value| if (!value.provider_executed) {
                client_output_count += 1;
            },
            .tool_error => |value| if (!value.provider_executed) {
                client_output_count += 1;
            },
        };
        for (self.approval_responses.items) |response| if (!response.approved) {
            denied_count += 1;
        };

        const combined_usage = types.addUsage(self.previous_usage, self.usage);
        self.core.accumulated_usage = combined_usage;
        const natural_continue = tool_common.shouldContinue(
            client_call_count,
            client_output_count,
            denied_count,
            self.core.pending_deferred.count(),
        );
        const should_stop = if (natural_continue)
            try generate_text.isStopConditionMet(
                io,
                self.core.arena,
                self.core.options.stop_when,
                self.core.steps.items,
            )
        else
            false;

        if (natural_continue and !should_stop) {
            createAndAddStep(self.core, io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    self.core.stitchable.close(io);
                    return .{ .err = try streamErrorFromError(self.core.arena, err, self.core.options.diag) };
                },
            };
            return null;
        }

        self.core.stitchable.close(io);
        return .{ .finish = .{
            .finish_reason = self.finish_reason,
            .raw_finish_reason = self.finish_reason.raw,
            .total_usage = combined_usage,
        } };
    }

    fn updateDeferredCalls(self: *StepState) Allocator.Error!void {
        for (self.tool_calls.items) |call| {
            if (!call.provider_executed) continue;
            const named = tool_common.findTool(self.core.options.tools, call.tool_name) orelse continue;
            if (!named.tool.supports_deferred_results) continue;
            var has_result = false;
            for (self.tool_outputs.items) |output| switch (output) {
                .result => |value| if (std.mem.eql(u8, value.tool_call_id, call.tool_call_id)) {
                    has_result = true;
                    break;
                },
                .tool_error => |value| if (std.mem.eql(u8, value.tool_call_id, call.tool_call_id)) {
                    has_result = true;
                    break;
                },
            };
            if (!has_result) try self.core.pending_deferred.put(
                self.core.arena,
                call.tool_call_id,
                call.tool_name,
            );
        }
        for (self.tool_outputs.items) |output| switch (output) {
            .result => |value| _ = self.core.pending_deferred.remove(value.tool_call_id),
            .tool_error => |value| _ = self.core.pending_deferred.remove(value.tool_call_id),
        };
    }

    fn pullUpstream(self: *StepState, io: std.Io) anyerror!?InternalPart {
        const deadline = self.nextDeadline(io) orelse {
            const part = try self.upstream.next(io);
            if (part != null) self.last_upstream_part = std.Io.Timestamp.now(io, .awake);
            return part;
        };
        const result = try self.pullWithDeadline(io, deadline);
        if (result != null) self.last_upstream_part = std.Io.Timestamp.now(io, .awake);
        return result;
    }

    const Deadline = struct {
        timestamp: std.Io.Clock.Timestamp,
        label: []const u8,
        milliseconds: u64,
    };

    fn nextDeadline(self: *StepState, _: std.Io) ?Deadline {
        var selected: ?Deadline = null;
        if (self.core.options.timeout) |timeout| {
            if (timeout.totalMs()) |milliseconds| {
                selected = earlierDeadline(selected, self.core.started_at, milliseconds, "Total");
            }
            if (timeout.stepMs()) |milliseconds| {
                selected = earlierDeadline(selected, self.step_started, milliseconds, "Step");
            }
            if (self.last_upstream_part) |last| if (timeout.chunkMs()) |milliseconds| {
                selected = earlierDeadline(selected, last, milliseconds, "Chunk");
            };
        }
        return selected;
    }

    fn pullWithDeadline(self: *StepState, io: std.Io, deadline: Deadline) anyerror!?InternalPart {
        var completed: std.Io.Event = .unset;
        const Runner = struct {
            fn run(state: *StepState, task_io: std.Io, event: *std.Io.Event) anyerror!?InternalPart {
                defer event.set(task_io);
                return state.upstream.next(task_io);
            }
        };
        var future = io.concurrent(Runner.run, .{ self, io, &completed }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                if (!self.core.timeout_warning_logged) {
                    self.core.timeout_warning_logged = true;
                    std.log.warn("stream timeout enforcement unavailable because std.Io concurrency is unavailable", .{});
                }
                return self.upstream.next(io);
            },
        };
        var awaited = false;
        defer {
            if (!awaited) _ = future.cancel(io) catch {};
        }

        while (!completed.isSet()) {
            completed.waitTimeout(io, .{ .deadline = deadline.timestamp }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {
                    const now = std.Io.Timestamp.now(io, .awake);
                    if (now.nanoseconds < deadline.timestamp.raw.nanoseconds) continue;
                    _ = future.cancel(io) catch {};
                    awaited = true;
                    self.core.abort_reason = try std.fmt.allocPrint(
                        self.core.arena,
                        "{s} timeout after {d}ms",
                        .{ deadline.label, deadline.milliseconds },
                    );
                    return error.Canceled;
                },
            };
        }
        awaited = true;
        return try future.await(io);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *StepState = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.upstream.deinit(io);
        const owner = self.owner;
        const gpa = self.core.gpa;
        owner.arena_state.deinit();
        gpa.destroy(owner);
    }
};

fn callbackAdapter(
    comptime Event: type,
    callback: ?generate_text.Callback(Event),
) ?model_call.Callback(Event) {
    const value = callback orelse return null;
    return .{ .ctx = value.ctx, .callback = value.callback };
}

fn instructionsText(instructions: ?prompt_api.Instructions) ?[]const u8 {
    const value = instructions orelse return null;
    return switch (value) {
        .text => |text_value| text_value,
        .message, .messages => null,
    };
}

fn isOutputInternalPart(part: InternalPart) bool {
    return switch (part) {
        .file,
        .custom,
        .source,
        .text_start,
        .text_end,
        .text_delta,
        .reasoning_start,
        .reasoning_end,
        .reasoning_delta,
        .reasoning_file,
        .tool_input_start,
        .tool_input_end,
        .tool_input_delta,
        .tool_approval_request,
        .tool_approval_response,
        .tool_call,
        .tool_result,
        .tool_error,
        => true,
        .model_call_start,
        .model_call_response_metadata,
        .model_call_end,
        .tool_execution_end,
        .err,
        .raw,
        => false,
    };
}

fn earlierDeadline(
    current: ?StepState.Deadline,
    start: std.Io.Timestamp,
    milliseconds: u64,
    label: []const u8,
) StepState.Deadline {
    const value: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
    const candidate: StepState.Deadline = .{
        .timestamp = start.addDuration(.fromMilliseconds(value)).withClock(.awake),
        .label = label,
        .milliseconds = milliseconds,
    };
    const existing = current orelse return candidate;
    return if (candidate.timestamp.raw.nanoseconds < existing.timestamp.raw.nanoseconds)
        candidate
    else
        existing;
}

fn missingTextError(arena: Allocator, kind: TextKind, id: []const u8) Allocator.Error!parts.StreamError {
    return .{
        .error_value = .{ .string = try std.fmt.allocPrint(
            arena,
            "{s} part {s} not found",
            .{ @tagName(kind), id },
        ) },
        .error_code = error.InvalidStreamPartError,
    };
}

fn streamErrorFromError(
    arena: Allocator,
    err: anyerror,
    diag: ?*const provider.Diagnostics,
) Allocator.Error!parts.StreamError {
    const diagnostic_message: ?[]const u8 = if (diag) |diagnostics|
        if (diagnostics.available) switch (diagnostics.payload) {
            .api_call => |value| value.message,
            .invalid_argument => |value| value.message,
            .invalid_prompt => |value| value.message,
            .invalid_response_data => |value| value.message,
            .invalid_tool_input => |value| value.message,
            .no_output_generated => |value| value.message,
            .retry => |value| value.message,
            else => null,
        } else null
    else
        null;
    return .{
        .error_value = .{ .string = try arena.dupe(u8, diagnostic_message orelse @errorName(err)) },
        .error_code = err,
    };
}

fn logStreamError(value: parts.StreamError) void {
    switch (value.error_value) {
        .string => |text| std.log.err("streamText: {s}", .{text}),
        else => std.log.err("streamText error: {s}", .{@errorName(value.error_code orelse error.InvalidStreamPartError)}),
    }
}

fn aggregateUsage(steps: []const StepResult) provider.Usage {
    var usage = types.zero_usage;
    for (steps) |step| usage = types.addUsage(usage, step.usage);
    return usage;
}

fn concatMessages(
    arena: Allocator,
    prefix: []const message.ModelMessage,
    suffix: []const message.ModelMessage,
) Allocator.Error![]const message.ModelMessage {
    const result = try arena.alloc(message.ModelMessage, prefix.len + suffix.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], suffix);
    return result;
}

fn timestampMilliseconds(io: std.Io) i64 {
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divFloor(now, std.time.ns_per_ms));
}

fn cloneTextStreamPart(arena: Allocator, part: Part) anyerror!Part {
    return switch (part) {
        .text_start => |value| .{ .text_start = try cloneBoundary(arena, value) },
        .text_end => |value| .{ .text_end = try cloneBoundary(arena, value) },
        .text_delta => |value| .{ .text_delta = try cloneDelta(arena, value) },
        .reasoning_start => |value| .{ .reasoning_start = try cloneBoundary(arena, value) },
        .reasoning_end => |value| .{ .reasoning_end = try cloneBoundary(arena, value) },
        .reasoning_delta => |value| .{ .reasoning_delta = try cloneDelta(arena, value) },
        .custom => |value| .{ .custom = try cloneCustom(arena, value) },
        .tool_input_start => |value| .{ .tool_input_start = try cloneToolInputStart(arena, value) },
        .tool_input_end => |value| .{ .tool_input_end = try cloneToolInputEnd(arena, value) },
        .tool_input_delta => |value| .{ .tool_input_delta = try cloneToolInputDelta(arena, value) },
        .source => |value| .{ .source = try cloneSource(arena, value) },
        .file => |value| .{ .file = try cloneGeneratedFile(arena, value) },
        .reasoning_file => |value| .{ .reasoning_file = try cloneReasoningFile(arena, value) },
        .tool_call => |value| .{ .tool_call = try cloneToolCall(arena, value) },
        .tool_result => |value| .{ .tool_result = try cloneToolResult(arena, value) },
        .tool_error => |value| .{ .tool_error = try cloneToolError(arena, value) },
        .tool_output_denied => |value| .{ .tool_output_denied = .{
            .tool_call_id = try arena.dupe(u8, value.tool_call_id),
            .tool_name = try arena.dupe(u8, value.tool_name),
            .provider_executed = value.provider_executed,
            .dynamic = value.dynamic,
        } },
        .tool_approval_request => |value| .{ .tool_approval_request = try cloneApprovalRequest(arena, value) },
        .tool_approval_response => |value| .{ .tool_approval_response = try cloneApprovalResponse(arena, value) },
        .start_step => |value| .{ .start_step = .{
            .request = try cloneRequestMetadata(arena, value.request),
            .warnings = try cloneWarnings(arena, value.warnings),
        } },
        .finish_step => |value| .{ .finish_step = .{
            .response = try cloneResponseMetadata(arena, value.response),
            .usage = try cloneUsage(arena, value.usage),
            .performance = try clonePerformance(arena, value.performance),
            .finish_reason = .{
                .unified = value.finish_reason.unified,
                .raw = if (value.finish_reason.raw) |raw| try arena.dupe(u8, raw) else null,
            },
            .raw_finish_reason = if (value.raw_finish_reason) |raw| try arena.dupe(u8, raw) else null,
            .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
        } },
        .start => .{ .start = {} },
        .finish => |value| .{ .finish = .{
            .finish_reason = .{
                .unified = value.finish_reason.unified,
                .raw = if (value.finish_reason.raw) |raw| try arena.dupe(u8, raw) else null,
            },
            .raw_finish_reason = if (value.raw_finish_reason) |raw| try arena.dupe(u8, raw) else null,
            .total_usage = try cloneUsage(arena, value.total_usage),
        } },
        .abort => |value| .{ .abort = .{
            .reason = if (value.reason) |reason| try arena.dupe(u8, reason) else null,
        } },
        .err => |value| .{ .err = try cloneStreamError(arena, value) },
        .raw => |value| .{ .raw = try provider_utils.cloneJsonValue(arena, value) },
    };
}

fn cloneBoundary(arena: Allocator, value: parts.TextBlockBoundary) Allocator.Error!parts.TextBlockBoundary {
    return .{
        .id = try arena.dupe(u8, value.id),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneDelta(arena: Allocator, value: parts.TextDelta) Allocator.Error!parts.TextDelta {
    return .{
        .id = try arena.dupe(u8, value.id),
        .text = try arena.dupe(u8, value.text),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneCustom(arena: Allocator, value: parts.Custom) Allocator.Error!parts.Custom {
    return .{
        .kind = try arena.dupe(u8, value.kind),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneToolInputStart(arena: Allocator, value: parts.ToolInputStart) Allocator.Error!parts.ToolInputStart {
    return .{
        .id = try arena.dupe(u8, value.id),
        .tool_name = try arena.dupe(u8, value.tool_name),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
        .tool_metadata = try cloneOptionalJson(arena, value.tool_metadata),
        .provider_executed = value.provider_executed,
        .dynamic = value.dynamic,
        .title = if (value.title) |title| try arena.dupe(u8, title) else null,
    };
}

fn cloneToolInputEnd(arena: Allocator, value: parts.ToolInputEnd) Allocator.Error!parts.ToolInputEnd {
    return .{
        .id = try arena.dupe(u8, value.id),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneToolInputDelta(arena: Allocator, value: parts.ToolInputDelta) Allocator.Error!parts.ToolInputDelta {
    return .{
        .id = try arena.dupe(u8, value.id),
        .delta = try arena.dupe(u8, value.delta),
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
    };
}

fn cloneToolCall(arena: Allocator, value: types.TypedToolCall) Allocator.Error!types.TypedToolCall {
    return .{
        .tool_call_id = try arena.dupe(u8, value.tool_call_id),
        .tool_name = try arena.dupe(u8, value.tool_name),
        .input = try provider_utils.cloneJsonValue(arena, value.input),
        .provider_executed = value.provider_executed,
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
        .tool_metadata = try cloneOptionalJson(arena, value.tool_metadata),
        .dynamic = value.dynamic,
        .invalid = value.invalid,
        .err = if (value.err) |tool_err| .{
            .kind = tool_err.kind,
            .err = tool_err.err,
            .message = try arena.dupe(u8, tool_err.message),
            .original_kind = tool_err.original_kind,
        } else null,
    };
}

fn cloneToolResult(arena: Allocator, value: types.TypedToolResult) Allocator.Error!types.TypedToolResult {
    return .{
        .tool_call_id = try arena.dupe(u8, value.tool_call_id),
        .tool_name = try arena.dupe(u8, value.tool_name),
        .input = if (value.input) |input| try provider_utils.cloneJsonValue(arena, input) else null,
        .output = try provider_utils.cloneJsonValue(arena, value.output),
        .provider_executed = value.provider_executed,
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
        .tool_metadata = try cloneOptionalJson(arena, value.tool_metadata),
        .dynamic = value.dynamic,
        .preliminary = value.preliminary,
    };
}

fn cloneToolError(arena: Allocator, value: types.TypedToolError) Allocator.Error!types.TypedToolError {
    return .{
        .tool_call_id = try arena.dupe(u8, value.tool_call_id),
        .tool_name = try arena.dupe(u8, value.tool_name),
        .input = if (value.input) |input| try provider_utils.cloneJsonValue(arena, input) else null,
        .error_value = try provider_utils.cloneJsonValue(arena, value.error_value),
        .error_code = value.error_code,
        .provider_executed = value.provider_executed,
        .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
        .tool_metadata = try cloneOptionalJson(arena, value.tool_metadata),
        .dynamic = value.dynamic,
    };
}

fn cloneApprovalRequest(arena: Allocator, value: types.ToolApprovalRequest) Allocator.Error!types.ToolApprovalRequest {
    return .{
        .approval_id = try arena.dupe(u8, value.approval_id),
        .tool_call = try cloneToolCall(arena, value.tool_call),
        .is_automatic = value.is_automatic,
        .signature = if (value.signature) |signature| try arena.dupe(u8, signature) else null,
    };
}

fn cloneApprovalResponse(arena: Allocator, value: types.ToolApprovalResponse) Allocator.Error!types.ToolApprovalResponse {
    return .{
        .approval_id = try arena.dupe(u8, value.approval_id),
        .tool_call = try cloneToolCall(arena, value.tool_call),
        .approved = value.approved,
        .reason = if (value.reason) |reason| try arena.dupe(u8, reason) else null,
        .provider_executed = value.provider_executed,
    };
}

fn cloneStreamError(arena: Allocator, value: parts.StreamError) Allocator.Error!parts.StreamError {
    return .{
        .error_value = try provider_utils.cloneJsonValue(arena, value.error_value),
        .error_code = value.error_code,
    };
}

fn cloneRequestMetadata(arena: Allocator, value: types.RequestMetadata) anyerror!types.RequestMetadata {
    return .{
        .body = try cloneOptionalJson(arena, value.body),
        .messages = if (value.messages) |messages_value| try message.cloneModelMessages(arena, messages_value) else null,
    };
}

fn cloneResponseMetadata(arena: Allocator, value: types.ResponseMetadata) anyerror!types.ResponseMetadata {
    return .{
        .id = if (value.id) |id| try arena.dupe(u8, id) else null,
        .timestamp_ms = value.timestamp_ms,
        .model_id = if (value.model_id) |id| try arena.dupe(u8, id) else null,
        .headers = try cloneHeaders(arena, value.headers),
        .body = try cloneOptionalJson(arena, value.body),
        .messages = try message.cloneModelMessages(arena, value.messages),
    };
}

fn clonePerformance(arena: Allocator, value: types.StepPerformance) Allocator.Error!types.StepPerformance {
    const timings = try arena.alloc(types.ToolExecutionTiming, value.tool_execution_ms.len);
    for (value.tool_execution_ms, timings) |timing, *cloned| cloned.* = .{
        .tool_call_id = try arena.dupe(u8, timing.tool_call_id),
        .milliseconds = timing.milliseconds,
    };
    var result = value;
    result.tool_execution_ms = timings;
    return result;
}

fn cloneUsage(arena: Allocator, usage: provider.Usage) Allocator.Error!provider.Usage {
    var result = usage;
    result.raw = try cloneOptionalJson(arena, usage.raw);
    return result;
}

fn cloneWarnings(arena: Allocator, warnings: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const output = try arena.alloc(provider.Warning, warnings.len);
    for (warnings, output) |warning, *cloned| cloned.* = switch (warning) {
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
    return output;
}

fn cloneHeaders(arena: Allocator, headers: ?provider.Headers) Allocator.Error!?provider.Headers {
    const values = headers orelse return null;
    const output = try arena.alloc(provider.Header, values.len);
    for (values, output) |header, *cloned| cloned.* = .{
        .name = try arena.dupe(u8, header.name),
        .value = try arena.dupe(u8, header.value),
    };
    return output;
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

fn cloneOptionalJson(arena: Allocator, value: ?std.json.Value) Allocator.Error!?std.json.Value {
    return if (value) |json| try provider_utils.cloneJsonValue(arena, json) else null;
}

fn mergeOptionalJson(
    arena: Allocator,
    defaults: ?std.json.Value,
    overrides: ?std.json.Value,
) Allocator.Error!?std.json.Value {
    if (defaults == null and overrides == null) return null;
    if (defaults == null) return try provider_utils.cloneJsonValue(arena, overrides.?);
    if (overrides == null) return try provider_utils.cloneJsonValue(arena, defaults.?);
    return try mergeJson(arena, defaults.?, overrides.?);
}

fn mergeJson(arena: Allocator, base: std.json.Value, overrides: std.json.Value) Allocator.Error!std.json.Value {
    if (base != .object or overrides != .object) return provider_utils.cloneJsonValue(arena, overrides);
    var object: std.json.ObjectMap = .empty;
    var base_iterator = base.object.iterator();
    while (base_iterator.next()) |entry| try object.put(
        arena,
        try arena.dupe(u8, entry.key_ptr.*),
        try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
    );
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
