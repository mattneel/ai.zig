//! Single-step structured object generation.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const logger = @import("logger.zig");
const message = @import("message.zig");
const output_api = @import("output.zig");
const prompt_api = @import("prompt.zig");
const registry = @import("registry.zig");
const telemetry = @import("telemetry.zig");
const types = @import("generate_text_types.zig");

const Allocator = std.mem.Allocator;

pub const OutputMode = enum { object, array, @"enum", no_schema };

pub const RepairErrorInfo = struct {
    kind: enum { json_parse, type_validation },
    message: []const u8,
};

pub const RepairText = struct {
    ctx: ?*anyopaque = null,
    repair_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        text: []const u8,
        error_info: RepairErrorInfo,
    ) anyerror!?[]const u8,

    pub fn repair(
        self: RepairText,
        arena: Allocator,
        text_value: []const u8,
        error_info: RepairErrorInfo,
    ) anyerror!?[]const u8 {
        return self.repair_fn(self.ctx, arena, text_value, error_info);
    }
};

pub const Callbacks = struct {
    on_start: ?provider_utils.Callback(events.GenerateObjectStartEvent) = null,
    on_step_start: ?provider_utils.Callback(events.ObjectStepStartEvent) = null,
    on_step_end: ?provider_utils.Callback(events.ObjectStepEndEvent) = null,
    on_end: ?provider_utils.Callback(events.GenerateObjectEndEvent) = null,
    on_error: ?provider_utils.Callback(events.ErrorEvent) = null,
};

pub const GenerateObjectOptions = struct {
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
    output: OutputMode = .object,
    schema: ?provider_utils.Schema = null,
    schema_name: ?[]const u8 = null,
    schema_description: ?[]const u8 = null,
    enum_values: ?[]const []const u8 = null,
    repair_text: ?RepairText = null,
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const GenerateObjectResult = struct {
    arena_state: std.heap.ArenaAllocator,
    object: std.json.Value,
    reasoning: ?[]const u8,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    warnings: []const provider.Warning,
    request: types.RequestMetadata,
    response: types.ResponseMetadata,
    provider_metadata: ?provider.ProviderMetadata,

    pub fn deinit(self: *GenerateObjectResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn as(
        self: *GenerateObjectResult,
        comptime T: type,
        diag: ?*provider.Diagnostics,
    ) anyerror!T {
        const arena = self.arena_state.allocator();
        const schema = provider_utils.schemaFromType(T);
        if (schema.validator) |validator| try validator.validate(arena, self.object, diag);
        return provider.wire.parse(T, arena, self.object);
    }
};

pub fn GenerateObjectAsResult(comptime T: type) type {
    return struct {
        raw: GenerateObjectResult,
        object: T,

        pub fn deinit(self: *@This()) void {
            self.raw.deinit();
            self.* = undefined;
        }
    };
}

pub fn generateObjectAs(
    comptime T: type,
    io: std.Io,
    gpa: Allocator,
    options: GenerateObjectOptions,
) anyerror!GenerateObjectAsResult(T) {
    var typed_options = options;
    typed_options.output = .object;
    typed_options.schema = provider_utils.schemaFromType(T);
    var raw = try generateObject(io, gpa, typed_options);
    errdefer raw.deinit();
    const typed = try raw.as(T, options.diag);
    return .{ .raw = raw, .object = typed };
}

pub fn generateObject(
    io: std.Io,
    gpa: Allocator,
    options: GenerateObjectOptions,
) anyerror!GenerateObjectResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var local_diagnostics = provider.Diagnostics.init(gpa);
    defer local_diagnostics.deinit();
    const active_diag = options.diag orelse &local_diagnostics;

    try validateInput(arena, options, active_diag);
    const model = try registry.resolveLanguageModel(options.model, active_diag);
    const strategy = strategyFor(options);
    const response_format = try strategy.responseFormat(io, arena, active_diag);
    const schema_value = switch (response_format) {
        .json => |json_format| json_format.schema,
        .text => null,
    };
    const settings = try prompt_api.prepareLanguageModelCallOptions(arena, .{
        .max_output_tokens = options.max_output_tokens,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .top_k = options.top_k,
        .presence_penalty = options.presence_penalty,
        .frequency_penalty = options.frequency_penalty,
        .seed = options.seed,
    }, active_diag);
    const standardized = try prompt_api.standardizePrompt(arena, .{
        .instructions = options.instructions,
        .prompt = options.prompt,
        .messages = options.messages,
        .allow_system_in_messages = options.allow_system_in_messages,
    }, active_diag);
    const prompt_messages = try prompt_api.convertToLanguageModelPrompt(io, gpa, arena, .{
        .prompt = standardized,
        .model = model,
        .provider_name = model.provider(),
    }, active_diag);
    const headers = try provider_utils.withUserAgentSuffix(
        arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );
    var id_generator = try provider_utils.IdGenerator.initFromIo(
        io,
        .{ .prefix = "aiobj", .size = 24 },
        active_diag,
    );
    const call_id = try id_generator.nextAlloc(arena);
    const dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry);

    const start_event: events.GenerateObjectStartEvent = .{
        .call_id = call_id,
        .operation_id = "ai.generateObject",
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .instructions = instructionsText(standardized.instructions),
        .messages = standardized.messages,
        .max_output_tokens = settings.max_output_tokens,
        .temperature = settings.temperature,
        .top_p = settings.top_p,
        .top_k = settings.top_k,
        .presence_penalty = settings.presence_penalty,
        .frequency_penalty = settings.frequency_penalty,
        .seed = settings.seed,
        .max_retries = options.max_retries,
        .headers = headers,
        .provider_options = options.provider_options,
        .output = outputModeName(options.output),
        .schema = schema_value,
        .schema_name = options.schema_name,
        .schema_description = options.schema_description,
    };
    try provider_utils.notify(io, start_event, &.{options.callbacks.on_start});
    try dispatcher.onObjectStart(&start_event);

    const step_start: events.ObjectStepStartEvent = .{
        .call_id = call_id,
        .step_number = 0,
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .provider_options = options.provider_options,
        .headers = headers,
        .prompt_messages = prompt_messages,
    };
    try provider_utils.notify(io, step_start, &.{options.callbacks.on_step_start});
    try dispatcher.onObjectStepStart(&step_start);

    const call_options: provider.CallOptions = .{
        .prompt = prompt_messages,
        .max_output_tokens = settings.max_output_tokens,
        .temperature = settings.temperature,
        .top_p = settings.top_p,
        .top_k = settings.top_k,
        .presence_penalty = settings.presence_penalty,
        .frequency_penalty = settings.frequency_penalty,
        .seed = settings.seed,
        .response_format = response_format,
        .headers = headers,
        .provider_options = options.provider_options,
    };
    var attempt: GenerateAttempt = .{ .model = model, .arena = arena, .options = &call_options };
    const generated = provider_utils.retry(
        provider.GenerateResult,
        io,
        .{ .max_retries = options.max_retries },
        &attempt,
        GenerateAttempt.call,
        active_diag,
    ) catch |err| {
        try notifyError(io, call_id, err, active_diag, options.callbacks.on_error, &dispatcher);
        return err;
    };

    const response: types.ResponseMetadata = .{
        .id = if (generated.response) |value| value.id orelse try id_generator.nextAlloc(arena) else try id_generator.nextAlloc(arena),
        .timestamp_ms = if (generated.response) |value| value.timestamp_ms orelse timestampMilliseconds(io) else timestampMilliseconds(io),
        .model_id = if (generated.response) |value| value.model_id orelse model.modelId() else model.modelId(),
        .headers = if (generated.response) |value| value.headers else null,
        .body = if (generated.response) |value| value.body else null,
    };
    const request: types.RequestMetadata = .{
        .body = if (generated.request) |value| value.body else null,
    };
    const text_value = try extractText(arena, generated.content);
    const reasoning = try extractReasoning(arena, generated.content);
    if (text_value == null) {
        setNoResponse(active_diag, response, generated.usage, generated.finish_reason);
        const err = error.NoObjectGeneratedError;
        try notifyError(io, call_id, err, active_diag, options.callbacks.on_error, &dispatcher);
        return err;
    }

    logger.logWarnings(arena, .{
        .warnings = generated.warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });
    const step_end: events.ObjectStepEndEvent = .{
        .call_id = call_id,
        .step_number = 0,
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .finish_reason = generated.finish_reason,
        .usage = generated.usage,
        .object_text = text_value.?,
        .reasoning = reasoning,
        .warnings = generated.warnings,
        .request = request,
        .response = response,
        .provider_metadata = generated.provider_metadata,
    };
    try provider_utils.notify(io, step_end, &.{options.callbacks.on_step_end});
    try dispatcher.onObjectStepEnd(&step_end);

    const parsed = parseWithRepair(
        arena,
        strategy,
        text_value.?,
        .{
            .response = response,
            .usage = generated.usage,
            .finish_reason = generated.finish_reason,
        },
        options.repair_text,
        active_diag,
    ) catch |err| {
        try notifyError(io, call_id, err, active_diag, options.callbacks.on_error, &dispatcher);
        return err;
    };
    const object_value = outputValueAsJson(parsed);
    const end_event: events.GenerateObjectEndEvent = .{
        .call_id = call_id,
        .object = object_value,
        .reasoning = reasoning,
        .finish_reason = generated.finish_reason,
        .usage = generated.usage,
        .warnings = generated.warnings,
        .request = request,
        .response = response,
        .provider_metadata = generated.provider_metadata,
    };
    try provider_utils.notify(io, end_event, &.{options.callbacks.on_end});
    try dispatcher.onObjectEnd(&end_event);

    return .{
        .arena_state = arena_state,
        .object = object_value,
        .reasoning = reasoning,
        .finish_reason = generated.finish_reason,
        .usage = generated.usage,
        .warnings = generated.warnings,
        .request = request,
        .response = response,
        .provider_metadata = generated.provider_metadata,
    };
}

fn GenerateAttemptCallError(comptime T: type) type {
    return provider.CallError!T;
}

const GenerateAttempt = struct {
    model: provider.LanguageModel,
    arena: Allocator,
    options: *const provider.CallOptions,

    fn call(self: *GenerateAttempt, io: std.Io, _: u32, diag: ?*provider.Diagnostics) GenerateAttemptCallError(provider.GenerateResult) {
        return self.model.doGenerate(io, self.arena, self.options, diag);
    }
};

fn strategyFor(options: GenerateObjectOptions) output_api.Output {
    const strategy_options: output_api.Options = .{
        .name = options.schema_name,
        .description = options.schema_description,
    };
    return switch (options.output) {
        .object => output_api.objectWithOptions(options.schema.?, strategy_options),
        .array => output_api.arrayWithOptions(options.schema.?, strategy_options),
        .@"enum" => output_api.choice(options.enum_values.?),
        .no_schema => output_api.json(),
    };
}

fn validateInput(
    arena: Allocator,
    options: GenerateObjectOptions,
    diag: ?*provider.Diagnostics,
) provider.Error!void {
    switch (options.output) {
        .no_schema => {
            if (options.schema != null) return invalid(arena, diag, "schema", "Schema is not supported for no-schema output.");
            if (options.schema_description != null) return invalid(arena, diag, "schemaDescription", "Schema description is not supported for no-schema output.");
            if (options.schema_name != null) return invalid(arena, diag, "schemaName", "Schema name is not supported for no-schema output.");
            if (options.enum_values != null) return invalid(arena, diag, "enumValues", "Enum values are not supported for no-schema output.");
        },
        .object => {
            if (options.schema == null) return invalid(arena, diag, "schema", "Schema is required for object output.");
            if (options.enum_values != null) return invalid(arena, diag, "enumValues", "Enum values are not supported for object output.");
        },
        .array => {
            if (options.schema == null) return invalid(arena, diag, "schema", "Element schema is required for array output.");
            if (options.enum_values != null) return invalid(arena, diag, "enumValues", "Enum values are not supported for array output.");
        },
        .@"enum" => {
            if (options.schema != null) return invalid(arena, diag, "schema", "Schema is not supported for enum output.");
            if (options.schema_description != null) return invalid(arena, diag, "schemaDescription", "Schema description is not supported for enum output.");
            if (options.schema_name != null) return invalid(arena, diag, "schemaName", "Schema name is not supported for enum output.");
            if (options.enum_values == null) return invalid(arena, diag, "enumValues", "Enum values are required for enum output.");
        },
    }
}

fn invalid(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    parameter: []const u8,
    message_text: []const u8,
) provider.Error {
    _ = arena;
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message_text, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

pub fn parseWithRepair(
    arena: Allocator,
    strategy: output_api.Output,
    text_value: []const u8,
    context: output_api.ParseContext,
    repair_text: ?RepairText,
    diag: ?*provider.Diagnostics,
) anyerror!types.OutputValue {
    return strategy.parseComplete(arena, text_value, &context, diag) catch |err| {
        if (err != error.NoObjectGeneratedError or repair_text == null) return err;
        const parsable = provider_utils.isParsableJson(text_value);
        const cause = if (diag) |diagnostics|
            if (diagnostics.available and diagnostics.payload == .no_object_generated)
                diagnostics.payload.no_object_generated.cause_message orelse @errorName(err)
            else
                @errorName(err)
        else
            @errorName(err);
        const repaired = try repair_text.?.repair(arena, text_value, .{
            .kind = if (parsable) .type_validation else .json_parse,
            .message = cause,
        }) orelse return err;
        return strategy.parseComplete(arena, repaired, &context, diag);
    };
}

pub fn outputValueAsJson(value: types.OutputValue) std.json.Value {
    return switch (value) {
        .text => |text_value| .{ .string = text_value },
        .json => |json_value| json_value,
    };
}

fn extractText(arena: Allocator, content: []const provider.Content) Allocator.Error!?[]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    for (content) |part| switch (part) {
        .text => |text_part| try output.appendSlice(arena, text_part.text),
        else => {},
    };
    if (output.items.len == 0) return null;
    const owned: []const u8 = try output.toOwnedSlice(arena);
    return owned;
}

fn extractReasoning(arena: Allocator, content: []const provider.Content) Allocator.Error!?[]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    for (content) |part| switch (part) {
        .reasoning => |reasoning_part| try output.appendSlice(arena, reasoning_part.text),
        else => {},
    };
    if (output.items.len == 0) return null;
    const owned: []const u8 = try output.toOwnedSlice(arena);
    return owned;
}

fn instructionsText(value: ?prompt_api.Instructions) ?[]const u8 {
    const instructions = value orelse return null;
    return switch (instructions) {
        .text => |text_value| text_value,
        .message => |item| item.content,
        .messages => null,
    };
}

fn outputModeName(mode: OutputMode) []const u8 {
    return switch (mode) {
        .object => "object",
        .array => "array",
        .@"enum" => "enum",
        .no_schema => "no-schema",
    };
}

fn timestampMilliseconds(io: std.Io) i64 {
    const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divFloor(nanoseconds, std.time.ns_per_ms));
}

fn setNoResponse(
    diag: ?*provider.Diagnostics,
    response: types.ResponseMetadata,
    usage: provider.Usage,
    finish_reason: provider.FinishReason,
) void {
    const diagnostics = diag orelse return;
    const response_json = provider.wire.stringifyAlloc(diagnostics.allocator, response) catch null;
    defer if (response_json) |value| diagnostics.allocator.free(value);
    const usage_json = provider.wire.stringifyAlloc(diagnostics.allocator, usage) catch null;
    defer if (usage_json) |value| diagnostics.allocator.free(value);
    provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_object_generated = .{
        .message = "No object generated: the model did not return a response.",
        .response_json = response_json,
        .usage_json = usage_json,
        .finish_reason = finish_reason,
    } });
}

fn notifyError(
    io: std.Io,
    call_id: []const u8,
    err: anyerror,
    diag: ?*provider.Diagnostics,
    callback: ?provider_utils.Callback(events.ErrorEvent),
    dispatcher: *const telemetry.Dispatcher,
) anyerror!void {
    const event: events.ErrorEvent = .{ .call_id = call_id, .err = err, .diag = diag };
    try provider_utils.notify(io, event, &.{callback});
    try dispatcher.onError(&event);
}

test "generateObject validates inputs and parses one object step" {
    const Model = struct {
        seen_format: ?provider.ResponseFormat = null,

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
            return "object-model";
        }
        fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn generate(
            raw: *anyopaque,
            _: std.Io,
            _: Allocator,
            options: *const provider.CallOptions,
            _: ?*provider.Diagnostics,
        ) provider.CallError!provider.GenerateResult {
            fromRaw(raw).seen_format = options.response_format;
            return .{
                .content = &.{.{ .text = .{ .text = "{\"name\":\"Ada\"}" } }},
                .finish_reason = .{ .unified = .stop },
                .usage = .{ .input_tokens = .{ .total = 2 }, .output_tokens = .{ .total = 3 } },
                .warnings = &.{},
            };
        }
        fn stream(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
            return error.UnsupportedFunctionalityError;
        }
    };
    const Shape = struct { name: []const u8 };
    var model: Model = .{};
    var result = try generateObject(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "name" },
        .schema = provider_utils.schemaFromType(Shape),
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Ada", result.object.object.get("name").?.string);
    try std.testing.expect(model.seen_format.? == .json);
    const typed = try result.as(Shape, null);
    try std.testing.expectEqualStrings("Ada", typed.name);

    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.InvalidArgumentError, generateObject(
        std.testing.io,
        std.testing.allocator,
        .{
            .model = .{ .model = model.languageModel() },
            .prompt = .{ .text = "name" },
            .output = .object,
            .diag = &diagnostics,
        },
    ));
    try std.testing.expectEqualStrings("Schema is required for object output.", diagnostics.payload.invalid_argument.message);
}

const TestObjectModel = struct {
    content: []const provider.Content,
    calls: usize = 0,

    fn languageModel(self: *TestObjectModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: provider.LanguageModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .urlIsSupported = supported,
        .doGenerate = generate,
        .doStream = stream,
    };
    fn fromRaw(raw: *anyopaque) *TestObjectModel {
        return @ptrCast(@alignCast(raw));
    }
    fn vProvider(_: *anyopaque) []const u8 {
        return "mock";
    }
    fn vModelId(_: *anyopaque) []const u8 {
        return "object-model";
    }
    fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }
    fn generate(
        raw: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const self = fromRaw(raw);
        self.calls += 1;
        return .{
            .content = self.content,
            .finish_reason = .{ .unified = .stop, .raw = "stop" },
            .usage = .{ .input_tokens = .{ .total = 2 }, .output_tokens = .{ .total = 3 } },
            .response = .{ .id = "response-1", .timestamp_ms = 123, .model_id = "object-model" },
            .warnings = &.{},
        };
    }
    fn stream(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
        return error.UnsupportedFunctionalityError;
    }
};

test "generateObject input validation matrix preserves upstream messages" {
    var model: TestObjectModel = .{ .content = &.{} };
    const schema = provider_utils.schemaFromType(struct { value: []const u8 });
    const choices = [_][]const u8{ "a", "b" };
    const Case = struct {
        options: GenerateObjectOptions,
        parameter: []const u8,
        message: []const u8,
    };
    const base_model: registry.LanguageModelRef = .{ .model = model.languageModel() };
    const cases = [_]Case{
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .no_schema, .schema = schema }, .parameter = "schema", .message = "Schema is not supported for no-schema output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .no_schema, .schema_description = "x" }, .parameter = "schemaDescription", .message = "Schema description is not supported for no-schema output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .no_schema, .schema_name = "x" }, .parameter = "schemaName", .message = "Schema name is not supported for no-schema output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .no_schema, .enum_values = &choices }, .parameter = "enumValues", .message = "Enum values are not supported for no-schema output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .object }, .parameter = "schema", .message = "Schema is required for object output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .object, .schema = schema, .enum_values = &choices }, .parameter = "enumValues", .message = "Enum values are not supported for object output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .array }, .parameter = "schema", .message = "Element schema is required for array output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .array, .schema = schema, .enum_values = &choices }, .parameter = "enumValues", .message = "Enum values are not supported for array output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .@"enum", .schema = schema, .enum_values = &choices }, .parameter = "schema", .message = "Schema is not supported for enum output." },
        .{ .options = .{ .model = base_model, .prompt = .{ .text = "x" }, .output = .@"enum" }, .parameter = "enumValues", .message = "Enum values are required for enum output." },
    };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    for (cases) |case| {
        var options = case.options;
        options.diag = &diagnostics;
        try std.testing.expectError(error.InvalidArgumentError, generateObject(
            std.testing.io,
            std.testing.allocator,
            options,
        ));
        try std.testing.expectEqualStrings(case.parameter, diagnostics.payload.invalid_argument.parameter);
        try std.testing.expectEqualStrings(case.message, diagnostics.payload.invalid_argument.message);
    }
    try std.testing.expectEqual(0, model.calls);
}

test "generateObject repair runs exactly once and diagnostics retain payload" {
    const Shape = struct { name: []const u8 };
    const broken = [_]provider.Content{.{ .text = .{ .text = "{\"name\":1}" } }};
    var model: TestObjectModel = .{ .content = &broken };
    const Repair = struct {
        calls: usize = 0,
        replacement: []const u8,

        fn run(
            raw: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            info: RepairErrorInfo,
        ) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try std.testing.expectEqual(.type_validation, info.kind);
            return self.replacement;
        }
    };
    var repair: Repair = .{ .replacement = "{\"name\":\"Ada\"}" };
    var result = try generateObject(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "name" },
        .schema = provider_utils.schemaFromType(Shape),
        .repair_text = .{ .ctx = &repair, .repair_fn = Repair.run },
    });
    defer result.deinit();
    try std.testing.expectEqual(1, repair.calls);
    try std.testing.expectEqualStrings("Ada", result.object.object.get("name").?.string);

    repair.calls = 0;
    repair.replacement = "{\"name\":2}";
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.NoObjectGeneratedError, generateObject(
        std.testing.io,
        std.testing.allocator,
        .{
            .model = .{ .model = model.languageModel() },
            .prompt = .{ .text = "name" },
            .schema = provider_utils.schemaFromType(Shape),
            .repair_text = .{ .ctx = &repair, .repair_fn = Repair.run },
            .diag = &diagnostics,
        },
    ));
    try std.testing.expectEqual(1, repair.calls);
    const payload = diagnostics.payload.no_object_generated;
    try std.testing.expectEqualStrings("{\"name\":2}", payload.text.?);
    try std.testing.expect(payload.response_json != null);
    try std.testing.expect(payload.usage_json != null);
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, payload.finish_reason.?.unified);
}

test "generateObject reports missing model text as NoObjectGeneratedError" {
    var model: TestObjectModel = .{ .content = &.{} };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.NoObjectGeneratedError, generateObject(
        std.testing.io,
        std.testing.allocator,
        .{
            .model = .{ .model = model.languageModel() },
            .prompt = .{ .text = "name" },
            .schema = provider_utils.schemaFromType(struct { name: []const u8 }),
            .diag = &diagnostics,
        },
    ));
    try std.testing.expectEqualStrings(
        "No object generated: the model did not return a response.",
        diagnostics.payload.no_object_generated.message,
    );
}
