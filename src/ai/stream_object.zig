//! Pull-based structured object streaming with partial JSON repair and dedup.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const generate_object = @import("generate_object.zig");
const logger = @import("logger.zig");
const message = @import("message.zig");
const output_api = @import("output.zig");
const prompt_api = @import("prompt.zig");
const registry = @import("registry.zig");
const telemetry = @import("telemetry.zig");
const types = @import("generate_text_types.zig");
const broadcast_api = @import("stream/broadcast.zig");

const Allocator = std.mem.Allocator;
const OutputValue = types.OutputValue;

pub const ObjectStreamError = struct {
    err: ?anyerror = null,
    error_value: std.json.Value = .null,
};

pub const Finish = struct {
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    response: types.ResponseMetadata,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ObjectStreamPart = union(enum) {
    object: std.json.Value,
    text_delta: []const u8,
    err: ObjectStreamError,
    finish: Finish,
};

const Broadcast = broadcast_api.Broadcast(ObjectStreamPart);

pub const Callbacks = struct {
    on_start: ?provider_utils.Callback(events.GenerateObjectStartEvent) = null,
    on_step_start: ?provider_utils.Callback(events.ObjectStepStartEvent) = null,
    on_step_end: ?provider_utils.Callback(events.ObjectStepEndEvent) = null,
    on_end: ?provider_utils.Callback(events.GenerateObjectEndEvent) = null,
    on_error: ?provider_utils.Callback(events.ErrorEvent) = null,
};

pub const StreamObjectOptions = struct {
    model: registry.LanguageModelRef,
    instructions: ?prompt_api.Instructions = null,
    prompt: ?prompt_api.PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    allow_system_in_messages: bool = false,
    max_output_tokens: ?f64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    seed: ?f64 = null,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    output: generate_object.OutputMode = .object,
    schema: ?provider_utils.Schema = null,
    schema_name: ?[]const u8 = null,
    schema_description: ?[]const u8 = null,
    enum_values: ?[]const []const u8 = null,
    repair_text: ?generate_object.RepairText = null,
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const FullStreamCursor = struct {
    core: *Core,
    cursor: Broadcast.Cursor,

    pub fn next(self: *FullStreamCursor, io: std.Io) anyerror!?ObjectStreamPart {
        try self.core.ensureProducer(io);
        return self.cursor.next(io);
    }
};

pub const PartialObjectStream = struct {
    core: *Core,
    cursor: Broadcast.Cursor,

    pub fn next(self: *PartialObjectStream, io: std.Io) anyerror!?std.json.Value {
        try self.core.ensureProducer(io);
        while (try self.cursor.next(io)) |part| switch (part) {
            .object => |value| return value,
            else => {},
        };
        return null;
    }
};

pub const TextStream = struct {
    core: *Core,
    cursor: Broadcast.Cursor,

    pub fn next(self: *TextStream, io: std.Io) anyerror!?[]const u8 {
        try self.core.ensureProducer(io);
        while (try self.cursor.next(io)) |part| switch (part) {
            .text_delta => |value| return value,
            else => {},
        };
        return null;
    }
};

pub const ElementStream = struct {
    core: *Core,
    cursor: Broadcast.Cursor,
    pending: []const std.json.Value = &.{},
    pending_index: usize = 0,
    published: usize = 0,

    pub fn next(self: *ElementStream, io: std.Io) anyerror!?std.json.Value {
        try self.core.ensureProducer(io);
        while (true) {
            if (self.pending_index < self.pending.len) {
                const value = self.pending[self.pending_index];
                self.pending_index += 1;
                self.published += 1;
                return value;
            }
            const part = try self.cursor.next(io) orelse return null;
            switch (part) {
                .object => |value| if (value == .array and value.array.items.len > self.published) {
                    self.pending = value.array.items[self.published..];
                    self.pending_index = 0;
                },
                else => {},
            }
        }
    }
};

pub const StreamObjectResult = struct {
    core: *Core,
    cursor: Broadcast.Cursor,

    /// Drives the inline-degradation path and returns the full object stream.
    pub fn next(self: *StreamObjectResult, io: std.Io) anyerror!?ObjectStreamPart {
        try self.core.ensureProducer(io);
        return self.cursor.next(io);
    }

    pub fn fullStream(self: *StreamObjectResult) FullStreamCursor {
        return .{ .core = self.core, .cursor = self.core.broadcast.cursor() };
    }

    pub fn partialObjectStream(self: *StreamObjectResult) PartialObjectStream {
        return .{ .core = self.core, .cursor = self.core.broadcast.cursor() };
    }

    pub fn textStream(self: *StreamObjectResult) TextStream {
        return .{ .core = self.core, .cursor = self.core.broadcast.cursor() };
    }

    pub fn elementStream(
        self: *StreamObjectResult,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ElementStream {
        if (!self.core.strategy.hasElementStream()) {
            if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
                .unsupported_functionality = .{
                    .message = "Element streams are only available for array output.",
                    .functionality = "element streams in non-array mode",
                },
            });
            return error.UnsupportedFunctionalityError;
        }
        return .{ .core = self.core, .cursor = self.core.broadcast.cursor() };
    }

    pub fn object(self: *StreamObjectResult, io: std.Io) anyerror!std.json.Value {
        try self.core.wait(io);
        if (self.core.object_error) |err| return err;
        return self.core.final_object orelse error.NoObjectGeneratedError;
    }

    pub fn usage(self: *StreamObjectResult, io: std.Io) anyerror!provider.Usage {
        try self.core.wait(io);
        return self.core.usage;
    }

    pub fn finishReason(self: *StreamObjectResult, io: std.Io) anyerror!provider.FinishReason {
        try self.core.wait(io);
        return self.core.finish_reason;
    }

    pub fn warnings(self: *StreamObjectResult, io: std.Io) anyerror![]const provider.Warning {
        try self.core.wait(io);
        return self.core.warnings;
    }

    pub fn request(self: *StreamObjectResult, io: std.Io) anyerror!types.RequestMetadata {
        try self.core.wait(io);
        return self.core.request;
    }

    pub fn response(self: *StreamObjectResult, io: std.Io) anyerror!types.ResponseMetadata {
        try self.core.wait(io);
        return self.core.response;
    }

    pub fn providerMetadata(self: *StreamObjectResult, io: std.Io) anyerror!?provider.ProviderMetadata {
        try self.core.wait(io);
        return self.core.provider_metadata;
    }

    pub fn deinit(self: *StreamObjectResult, io: std.Io) void {
        const core = self.core;
        if (core.mode == .concurrent) core.future.cancel(io);
        core.broadcast.close(io);
        core.local_diagnostics.deinit();
        core.broadcast.deinit();
        core.arena_state.deinit();
        core.gpa.destroy(core);
        self.* = undefined;
    }
};

/// Starts the producer concurrently when the active `std.Io` supports it.
/// With an inline-only `Io`, the first cursor pull or result accessor runs the
/// same producer synchronously; ordering and result semantics stay identical.
pub fn streamObject(
    io: std.Io,
    gpa: Allocator,
    options: StreamObjectOptions,
) anyerror!StreamObjectResult {
    const core = try gpa.create(Core);
    errdefer gpa.destroy(core);
    core.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .options = options,
        .local_diagnostics = provider.Diagnostics.init(gpa),
    };
    errdefer core.local_diagnostics.deinit();
    errdefer core.arena_state.deinit();
    core.arena = core.arena_state.allocator();
    core.broadcast = Broadcast.init(core.arena);
    errdefer core.broadcast.deinit();

    const diag = core.diag();
    try validateInput(options, diag);
    core.model = try registry.resolveLanguageModel(options.model, diag);
    core.strategy = strategyFor(options);
    core.settings = try prompt_api.prepareLanguageModelCallOptions(core.arena, .{
        .max_output_tokens = options.max_output_tokens,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .top_k = options.top_k,
        .presence_penalty = options.presence_penalty,
        .frequency_penalty = options.frequency_penalty,
        .seed = options.seed,
    }, diag);
    const standardized = try prompt_api.standardizePrompt(core.arena, .{
        .instructions = options.instructions,
        .prompt = options.prompt,
        .messages = options.messages,
        .allow_system_in_messages = options.allow_system_in_messages,
    }, diag);
    core.instructions = standardized.instructions;
    core.messages = standardized.messages;
    core.prompt_messages = try prompt_api.convertToLanguageModelPrompt(io, gpa, core.arena, .{
        .prompt = standardized,
        .model = core.model,
        .provider_name = core.model.provider(),
    }, diag);
    core.headers = try provider_utils.withUserAgentSuffix(
        core.arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );
    core.provider_options = if (options.provider_options) |value|
        try provider_utils.cloneJsonValue(core.arena, value)
    else
        null;
    core.response_format = try core.strategy.responseFormat(io, core.arena, diag);
    core.id_generator = try provider_utils.IdGenerator.initFromIo(
        io,
        .{ .prefix = "aiobj", .size = 24 },
        diag,
    );
    core.call_id = try core.id_generator.nextAlloc(core.arena);
    core.dispatcher = try telemetry.createTelemetryDispatcher(io, core.arena, options.telemetry);
    core.started_at = std.Io.Timestamp.now(io, .awake);

    core.future = io.concurrent(Core.producer, .{ core, io }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            core.mode = .inline_mode;
            return .{ .core = core, .cursor = core.broadcast.cursor() };
        },
    };
    core.producer_started = true;
    return .{ .core = core, .cursor = core.broadcast.cursor() };
}

const Core = struct {
    const Mode = enum { concurrent, inline_mode };

    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    arena: Allocator = undefined,
    options: StreamObjectOptions,
    local_diagnostics: provider.Diagnostics,
    broadcast: Broadcast = undefined,
    mode: Mode = .concurrent,
    future: std.Io.Future(void) = undefined,
    producer_mutex: std.atomic.Mutex = .unlocked,
    producer_started: bool = false,
    completion: provider_utils.OneShot(anyerror!void) = .{},

    model: provider.LanguageModel = undefined,
    strategy: output_api.Output = undefined,
    settings: prompt_api.PreparedLanguageModelCallOptions = .{},
    instructions: ?prompt_api.Instructions = null,
    messages: []const message.ModelMessage = &.{},
    prompt_messages: provider.Prompt = &.{},
    headers: provider.Headers = &.{},
    provider_options: ?provider.ProviderOptions = null,
    response_format: provider.ResponseFormat = .{ .text = .{} },
    dispatcher: telemetry.Dispatcher = undefined,
    id_generator: provider_utils.IdGenerator = undefined,
    call_id: []const u8 = "",
    started_at: std.Io.Timestamp = undefined,

    final_object: ?std.json.Value = null,
    object_error: ?anyerror = null,
    usage: provider.Usage = .{ .input_tokens = .{}, .output_tokens = .{} },
    finish_reason: provider.FinishReason = .{ .unified = .other },
    warnings: []const provider.Warning = &.{},
    request: types.RequestMetadata = .{},
    response: types.ResponseMetadata = .{},
    provider_metadata: ?provider.ProviderMetadata = null,

    fn diag(self: *Core) *provider.Diagnostics {
        return self.options.diag orelse &self.local_diagnostics;
    }

    fn ensureProducer(self: *Core, io: std.Io) anyerror!void {
        if (self.mode == .concurrent) return;
        lockAtomic(&self.producer_mutex);
        defer self.producer_mutex.unlock();
        if (self.producer_started) return;
        self.producer_started = true;
        producer(self, io);
    }

    fn wait(self: *Core, io: std.Io) anyerror!void {
        try self.ensureProducer(io);
        const outcome = try self.completion.wait(io);
        try outcome;
    }

    fn producer(self: *Core, io: std.Io) void {
        const outcome = self.run(io);
        if (outcome) |_| {
            self.completion.resolve(io, {});
        } else |err| {
            self.emitError(io, err, .null);
            self.completion.resolve(io, err);
        }
        self.broadcast.close(io);
    }

    fn run(self: *Core, io: std.Io) anyerror!void {
        const schema_value = switch (self.response_format) {
            .json => |value| value.schema,
            .text => null,
        };
        const start_event: events.GenerateObjectStartEvent = .{
            .call_id = self.call_id,
            .operation_id = "ai.streamObject",
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .instructions = instructionsText(self.instructions),
            .messages = self.messages,
            .max_output_tokens = self.settings.max_output_tokens,
            .temperature = self.settings.temperature,
            .top_p = self.settings.top_p,
            .top_k = self.settings.top_k,
            .presence_penalty = self.settings.presence_penalty,
            .frequency_penalty = self.settings.frequency_penalty,
            .seed = self.settings.seed,
            .max_retries = self.options.max_retries,
            .headers = self.headers,
            .provider_options = self.provider_options,
            .output = outputModeName(self.options.output),
            .schema = schema_value,
            .schema_name = self.options.schema_name,
            .schema_description = self.options.schema_description,
        };
        try provider_utils.notify(io, start_event, &.{self.options.callbacks.on_start});
        try self.dispatcher.onObjectStart(&start_event);

        const step_start: events.ObjectStepStartEvent = .{
            .call_id = self.call_id,
            .step_number = 0,
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .provider_options = self.provider_options,
            .headers = self.headers,
            .prompt_messages = self.prompt_messages,
        };
        try provider_utils.notify(io, step_start, &.{self.options.callbacks.on_step_start});
        try self.dispatcher.onObjectStepStart(&step_start);

        const call_options: provider.CallOptions = .{
            .prompt = self.prompt_messages,
            .max_output_tokens = self.settings.max_output_tokens,
            .temperature = self.settings.temperature,
            .top_p = self.settings.top_p,
            .top_k = self.settings.top_k,
            .presence_penalty = self.settings.presence_penalty,
            .frequency_penalty = self.settings.frequency_penalty,
            .seed = self.settings.seed,
            .response_format = self.response_format,
            .headers = self.headers,
            .provider_options = self.provider_options,
            .include_raw_chunks = false,
        };
        var attempt: StreamAttempt = .{ .model = self.model, .arena = self.arena, .options = &call_options };
        var model_result = try provider_utils.retry(
            provider.StreamResult,
            io,
            .{ .max_retries = self.options.max_retries },
            &attempt,
            StreamAttempt.call,
            self.diag(),
        );
        defer model_result.stream.deinit(io);
        self.request = .{ .body = model_result.request.body };
        self.response = .{
            .id = try self.id_generator.nextAlloc(self.arena),
            .timestamp_ms = timestampMilliseconds(io),
            .model_id = self.model.modelId(),
            .headers = model_result.response.headers,
        };

        var accumulated: std.ArrayList(u8) = .empty;
        defer accumulated.deinit(self.arena);
        var pending_text: std.ArrayList(u8) = .empty;
        defer pending_text.deinit(self.arena);
        var latest_raw: ?std.json.Value = null;
        var latest_partial: ?OutputValue = null;
        var latest_state: ?provider_utils.parse_partial_json.State = null;
        var first_delta = true;
        var first_chunk = true;
        var ms_to_first_chunk: ?f64 = null;
        var saw_finish = false;

        while (try model_result.stream.next(io)) |part| switch (part) {
            .stream_start => |value| {
                self.warnings = try cloneWarnings(self.arena, value.warnings);
            },
            .text_delta => |value| {
                if (first_chunk) {
                    ms_to_first_chunk = elapsedMilliseconds(self.started_at, std.Io.Timestamp.now(io, .awake));
                    first_chunk = false;
                }
                try accumulated.appendSlice(self.arena, value.delta);
                try pending_text.appendSlice(self.arena, value.delta);
                const parsed = try provider_utils.parsePartialJson(self.arena, accumulated.items);
                const current = parsed.value orelse continue;
                const raw_changed = !provider_utils.isDeepEqualOptionalData(latest_raw, current);
                const final_transition = parsed.state == .successful_parse and latest_state != .successful_parse;
                if (!raw_changed and !final_transition) continue;

                const validated = try self.strategy.validatePartial(self.arena, .{
                    .value = current,
                    .text_delta = pending_text.items,
                    .latest = latest_partial,
                    .is_first_delta = first_delta,
                    .is_final_delta = parsed.state == .successful_parse,
                }) orelse continue;
                const partial_changed = !outputValuesEqual(latest_partial, validated.partial);
                const array_closure = self.strategy.kind == .array and final_transition and validated.text_delta.len != 0;
                if (!partial_changed and !array_closure) continue;

                latest_raw = current;
                latest_state = parsed.state;
                if (partial_changed) {
                    latest_partial = validated.partial;
                    try self.broadcast.append(io, .{ .object = generate_object.outputValueAsJson(validated.partial) });
                }
                if (validated.text_delta.len != 0) {
                    try self.broadcast.append(io, .{ .text_delta = validated.text_delta });
                }
                pending_text.clearRetainingCapacity();
                first_delta = false;
            },
            .response_metadata => |value| {
                self.response.id = if (value.id) |id| try self.arena.dupe(u8, id) else self.response.id;
                self.response.timestamp_ms = value.timestamp_ms orelse self.response.timestamp_ms;
                self.response.model_id = if (value.model_id) |model_id|
                    try self.arena.dupe(u8, model_id)
                else
                    self.response.model_id;
            },
            .finish => |value| {
                saw_finish = true;
                self.finish_reason = value.finish_reason;
                self.usage = value.usage;
                self.provider_metadata = if (value.provider_metadata) |metadata|
                    try provider_utils.cloneJsonValue(self.arena, metadata)
                else
                    null;
                if (pending_text.items.len != 0 and self.strategy.kind != .array) {
                    try self.broadcast.append(io, .{ .text_delta = try self.arena.dupe(u8, pending_text.items) });
                    pending_text.clearRetainingCapacity();
                }
                try self.broadcast.append(io, .{ .finish = .{
                    .finish_reason = self.finish_reason,
                    .usage = self.usage,
                    .response = self.response,
                    .provider_metadata = self.provider_metadata,
                } });
                logger.logWarnings(self.arena, .{
                    .warnings = self.warnings,
                    .provider_name = self.model.provider(),
                    .model = self.model.modelId(),
                });
                const parsed_final = generate_object.parseWithRepair(
                    self.arena,
                    self.strategy,
                    accumulated.items,
                    .{
                        .response = self.response,
                        .usage = self.usage,
                        .finish_reason = self.finish_reason,
                    },
                    self.options.repair_text,
                    self.diag(),
                ) catch |err| {
                    self.object_error = err;
                    continue;
                };
                self.final_object = generate_object.outputValueAsJson(parsed_final);
            },
            .err => |value| {
                const cloned = try provider_utils.cloneJsonValue(self.arena, value.error_value);
                self.emitError(io, null, cloned);
            },
            else => {},
        };

        if (!saw_finish) {
            setNoObject(self.diag(), accumulated.items, self.response, self.usage, self.finish_reason, "model stream ended without a finish part");
            self.object_error = error.NoObjectGeneratedError;
        }

        const step_end: events.ObjectStepEndEvent = .{
            .call_id = self.call_id,
            .step_number = 0,
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .finish_reason = self.finish_reason,
            .usage = self.usage,
            .object_text = accumulated.items,
            .warnings = self.warnings,
            .request = self.request,
            .response = self.response,
            .provider_metadata = self.provider_metadata,
            .ms_to_first_chunk = ms_to_first_chunk,
        };
        try provider_utils.notify(io, step_end, &.{self.options.callbacks.on_step_end});
        try self.dispatcher.onObjectStepEnd(&step_end);

        const end_event: events.GenerateObjectEndEvent = .{
            .call_id = self.call_id,
            .object = self.final_object,
            .err = self.object_error,
            .finish_reason = self.finish_reason,
            .usage = self.usage,
            .warnings = self.warnings,
            .request = self.request,
            .response = self.response,
            .provider_metadata = self.provider_metadata,
        };
        try provider_utils.notify(io, end_event, &.{self.options.callbacks.on_end});
        try self.dispatcher.onObjectEnd(&end_event);
    }

    fn emitError(self: *Core, io: std.Io, err: ?anyerror, value: std.json.Value) void {
        const cloned = provider_utils.cloneJsonValue(self.arena, value) catch .null;
        self.broadcast.append(io, .{ .err = .{ .err = err, .error_value = cloned } }) catch {};
        const event_error = err orelse error.InvalidResponseDataError;
        const event: events.ErrorEvent = .{
            .call_id = self.call_id,
            .err = event_error,
            .diag = self.diag(),
        };
        if (self.options.callbacks.on_error) |callback| {
            provider_utils.notify(io, event, &.{callback}) catch {};
        } else {
            std.log.err("streamObject error: {s}", .{@errorName(event_error)});
        }
        self.dispatcher.onError(&event) catch {};
    }
};

const StreamAttempt = struct {
    model: provider.LanguageModel,
    arena: Allocator,
    options: *const provider.CallOptions,

    fn call(self: *StreamAttempt, io: std.Io, _: u32, diag: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
        return self.model.doStream(io, self.arena, self.options, diag);
    }
};

fn validateInput(options: StreamObjectOptions, diag: ?*provider.Diagnostics) provider.Error!void {
    switch (options.output) {
        .no_schema => {
            if (options.schema != null) return invalid(diag, "schema", "Schema is not supported for no-schema output.");
            if (options.schema_description != null) return invalid(diag, "schemaDescription", "Schema description is not supported for no-schema output.");
            if (options.schema_name != null) return invalid(diag, "schemaName", "Schema name is not supported for no-schema output.");
            if (options.enum_values != null) return invalid(diag, "enumValues", "Enum values are not supported for no-schema output.");
        },
        .object => {
            if (options.schema == null) return invalid(diag, "schema", "Schema is required for object output.");
            if (options.enum_values != null) return invalid(diag, "enumValues", "Enum values are not supported for object output.");
        },
        .array => {
            if (options.schema == null) return invalid(diag, "schema", "Element schema is required for array output.");
            if (options.enum_values != null) return invalid(diag, "enumValues", "Enum values are not supported for array output.");
        },
        .@"enum" => {
            if (options.schema != null) return invalid(diag, "schema", "Schema is not supported for enum output.");
            if (options.schema_description != null) return invalid(diag, "schemaDescription", "Schema description is not supported for enum output.");
            if (options.schema_name != null) return invalid(diag, "schemaName", "Schema name is not supported for enum output.");
            if (options.enum_values == null) return invalid(diag, "enumValues", "Enum values are required for enum output.");
        },
    }
}

fn invalid(diag: ?*provider.Diagnostics, parameter: []const u8, message_text: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message_text, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn strategyFor(options: StreamObjectOptions) output_api.Output {
    const strategy_options: output_api.Options = .{ .name = options.schema_name, .description = options.schema_description };
    return switch (options.output) {
        .object => output_api.objectWithOptions(options.schema.?, strategy_options),
        .array => output_api.arrayWithOptions(options.schema.?, strategy_options),
        .@"enum" => output_api.choice(options.enum_values.?),
        .no_schema => output_api.json(),
    };
}

fn outputValuesEqual(left: ?OutputValue, right: OutputValue) bool {
    const value = left orelse return false;
    if (std.meta.activeTag(value) != std.meta.activeTag(right)) return false;
    return switch (value) {
        .text => |text_value| std.mem.eql(u8, text_value, right.text),
        .json => |json_value| provider_utils.isDeepEqualData(json_value, right.json),
    };
}

fn cloneWarnings(arena: Allocator, source: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const result = try arena.alloc(provider.Warning, source.len);
    for (source, result) |warning, *destination| destination.* = switch (warning) {
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

fn instructionsText(value: ?prompt_api.Instructions) ?[]const u8 {
    const instructions = value orelse return null;
    return switch (instructions) {
        .text => |text_value| text_value,
        .message => |item| item.content,
        .messages => null,
    };
}

fn outputModeName(mode: generate_object.OutputMode) []const u8 {
    return switch (mode) {
        .object => "object",
        .array => "array",
        .@"enum" => "enum",
        .no_schema => "no-schema",
    };
}

fn timestampMilliseconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

fn elapsedMilliseconds(start: std.Io.Timestamp, finish: std.Io.Timestamp) f64 {
    const elapsed: f64 = @floatFromInt(@max(finish.nanoseconds - start.nanoseconds, 0));
    return elapsed / @as(f64, std.time.ns_per_ms);
}

fn lockAtomic(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn setNoObject(
    diag: ?*provider.Diagnostics,
    text_value: []const u8,
    response: types.ResponseMetadata,
    usage: provider.Usage,
    finish_reason: provider.FinishReason,
    cause: []const u8,
) void {
    const diagnostics = diag orelse return;
    const response_json = provider.wire.stringifyAlloc(diagnostics.allocator, response) catch null;
    defer if (response_json) |value| diagnostics.allocator.free(value);
    const usage_json = provider.wire.stringifyAlloc(diagnostics.allocator, usage) catch null;
    defer if (usage_json) |value| diagnostics.allocator.free(value);
    provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_object_generated = .{
        .message = "No object generated: the model did not return a response.",
        .text = text_value,
        .response_json = response_json,
        .usage_json = usage_json,
        .finish_reason = finish_reason,
        .cause_message = cause,
    } });
}

test "streamObject deduplicates object partials and synthesizes array JSON text" {
    const ErrorRecorder = struct {
        calls: std.atomic.Value(usize) = .init(0),

        fn record(raw: ?*anyopaque, _: events.ErrorEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.calls.fetchAdd(1, .monotonic);
        }
    };
    const ScriptStream = struct {
        parts: []const provider.StreamPart,
        index: usize = 0,

        fn partStream(self: *@This()) provider.PartStream {
            return .{ .ctx = self, .vtable = &vtable };
        }
        const vtable: provider.PartStream.VTable = .{ .next = nextPart, .deinit = deinitPart };
        fn nextPart(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == self.parts.len) return null;
            defer self.index += 1;
            return self.parts[self.index];
        }
        fn deinitPart(_: *anyopaque, _: std.Io) void {}
    };
    const Model = struct {
        stream_state: ScriptStream,

        fn languageModel(self: *@This()) provider.LanguageModel {
            return .{ .ctx = self, .vtable = &vtable };
        }
        const vtable: provider.LanguageModel.VTable = .{
            .provider = vProvider,
            .modelId = vModelId,
            .urlIsSupported = supported,
            .doGenerate = generate,
            .doStream = stream,
        };
        fn fromRaw(raw: *anyopaque) *@This() {
            return @ptrCast(@alignCast(raw));
        }
        fn vProvider(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn vModelId(_: *anyopaque) []const u8 {
            return "stream-object";
        }
        fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn generate(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
            return error.UnsupportedFunctionalityError;
        }
        fn stream(raw: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
            return .{ .stream = fromRaw(raw).stream_state.partStream() };
        }
    };

    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_delta = .{ .id = "1", .delta = "{\"elements\":[" } },
        .{ .text_delta = .{ .id = "1", .delta = "{\"value\":\"a\"}," } },
        .{ .text_delta = .{ .id = "1", .delta = "{\"value\":\"b\"}" } },
        .{ .text_delta = .{ .id = "1", .delta = "]}" } },
        .{ .err = .{ .error_value = .{ .string = "provider warning" } } },
        .{ .finish = .{
            .finish_reason = .{ .unified = .stop },
            .usage = .{ .input_tokens = .{ .total = 1 }, .output_tokens = .{ .total = 2 } },
        } },
    };
    const Element = struct { value: []const u8 };
    var model: Model = .{ .stream_state = .{ .parts = &script } };
    var errors: ErrorRecorder = .{};
    var result = try streamObject(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .output = .array,
        .schema = provider_utils.schemaFromType(Element),
        .callbacks = .{ .on_error = .{ .ctx = &errors, .func = ErrorRecorder.record } },
    });
    defer result.deinit(std.testing.io);

    var text_stream = result.textStream();
    var text_bytes: std.ArrayList(u8) = .empty;
    defer text_bytes.deinit(std.testing.allocator);
    while (try text_stream.next(std.testing.io)) |delta| try text_bytes.appendSlice(std.testing.allocator, delta);
    try std.testing.expectEqualStrings("[{\"value\":\"a\"},{\"value\":\"b\"}]", text_bytes.items);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text_bytes.items, .{});
    defer parsed.deinit();

    const object_value = try result.object(std.testing.io);
    try std.testing.expectEqual(2, object_value.array.items.len);
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, (try result.finishReason(std.testing.io)).unified);
    try std.testing.expectEqual(@as(?u64, 1), (try result.usage(std.testing.io)).input_tokens.total);
    try std.testing.expectEqual(1, errors.calls.load(.monotonic));

    var full = result.fullStream();
    var error_parts: usize = 0;
    while (try full.next(std.testing.io)) |part| if (part == .err) {
        error_parts += 1;
        try std.testing.expectEqualStrings("provider warning", part.err.error_value.string);
    };
    try std.testing.expectEqual(1, error_parts);

    var partials = result.partialObjectStream();
    var partial_lengths: [4]usize = undefined;
    var partial_count: usize = 0;
    while (try partials.next(std.testing.io)) |partial| {
        partial_lengths[partial_count] = partial.array.items.len;
        partial_count += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, partial_lengths[0..partial_count]);
    var elements = try result.elementStream(null);
    try std.testing.expectEqualStrings("a", (try elements.next(std.testing.io)).?.object.get("value").?.string);
    try std.testing.expectEqualStrings("b", (try elements.next(std.testing.io)).?.object.get("value").?.string);
    try std.testing.expectEqual(null, try elements.next(std.testing.io));
}
