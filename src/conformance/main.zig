const std = @import("std");
const ai = @import("ai");
const anthropic = @import("anthropic");
const openai = @import("openai");
const openai_compatible = @import("openai_compatible");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

const Scenario = struct {
    name: []const u8,
    surface: []const u8,
    provider: []const u8,
    model: []const u8,
    input: Input,
};

const Input = struct {
    messages: []const InputMessage = &.{},
    tools: []const ToolDefinition = &.{},
    settings: Settings = .{},
    schema: ?JsonValue = null,
    schema_name: ?[]const u8 = null,
    schema_description: ?[]const u8 = null,
    value: ?[]const u8 = null,
    values: []const []const u8 = &.{},
};

const InputMessage = struct {
    role: []const u8,
    content: []const u8,
};

const ToolDefinition = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema: JsonValue,
    output: JsonValue,
};

const Settings = struct {
    maxRetries: u32 = 0,
};

const TokenDetails = struct {
    no_cache_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
};

const OutputTokenDetails = struct {
    text_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
};

const CommonUsage = struct {
    input_tokens: ?u64 = null,
    input_token_details: TokenDetails = .{},
    output_tokens: ?u64 = null,
    output_token_details: OutputTokenDetails = .{},
    total_tokens: ?u64 = null,
    tokens: ?u64 = null,
};

const CommonError = struct {
    category: []const u8,
};

const CommonToolCall = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: JsonValue,
};

const CommonToolResult = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: ?JsonValue = null,
    output: JsonValue,
};

const CommonStep = struct {
    text: []const u8,
    finish_reason: []const u8,
    usage: CommonUsage,
    tool_calls: []const CommonToolCall,
    tool_results: []const CommonToolResult,
};

const CommonPart = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    input: ?JsonValue = null,
    output: ?JsonValue = null,
    object: ?JsonValue = null,
    finish_reason: ?[]const u8 = null,
    usage: ?CommonUsage = null,
    @"error": ?CommonError = null,
};

const CommonResult = struct {
    text: ?[]const u8 = null,
    object: ?JsonValue = null,
    embedding: ?[]const f64 = null,
    embeddings: ?[]const []const f64 = null,
    value: ?[]const u8 = null,
    values: ?[]const []const u8 = null,
};

const CommonEnvelope = struct {
    surface: []const u8,
    result: CommonResult = .{},
    stream_parts: []const CommonPart = &.{},
    usage: ?CommonUsage = null,
    finish_reason: ?[]const u8 = null,
    steps: []const CommonStep = &.{},
    messages: JsonValue,
    @"error": ?CommonError = null,
};

const ToolRuntime = struct {
    output: JsonValue,

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        arena: Allocator,
        _: JsonValue,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        const self: *ToolRuntime = @ptrCast(@alignCast(raw.?));
        return .{ .value = try provider_utils.cloneJsonValue(arena, self.output) };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: {s} <scenario-file> <base-url>", .{args[0]});
        return error.InvalidArguments;
    }

    const scenario_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[1],
        arena,
        .limited(16 * 1024 * 1024),
    );
    const scenario = try std.json.parseFromSliceLeaky(Scenario, arena, scenario_bytes, .{
        .ignore_unknown_fields = true,
    });
    const result = try runScenario(io, init.gpa, arena, scenario, args[2]);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try std.json.Stringify.value(result, .{ .emit_null_optional_fields = true }, &stdout_file.interface);
    try stdout_file.interface.writeByte('\n');
    try stdout_file.interface.flush();
}

fn runScenario(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    server_base_url: []const u8,
) !CommonEnvelope {
    var transport = provider_utils.HttpClientTransport.init(gpa, io);
    defer transport.deinit();
    const base_url = try std.fmt.allocPrint(arena, "{s}/v1", .{server_base_url});

    if (std.mem.eql(u8, scenario.surface, "embed+embedMany")) {
        if (!std.mem.eql(u8, scenario.provider, "openai")) {
            return error.UnsupportedProvider;
        }
        var factory = openai.createOpenAi(.{
            .allocator = gpa,
            .base_url = base_url,
            .api_key = "test-key",
            .transport = transport.transport(),
        });
        var model = try factory.embeddingModel(scenario.model, null);
        return runEmbeddings(io, gpa, arena, scenario, model.embeddingModel());
    }

    if (std.mem.eql(u8, scenario.provider, "openai")) {
        var factory = openai.createOpenAi(.{
            .allocator = gpa,
            .base_url = base_url,
            .api_key = "test-key",
            .transport = transport.transport(),
        });
        var model = try factory.chat(scenario.model, null);
        return runLanguage(io, gpa, arena, scenario, model.languageModel());
    }
    if (std.mem.eql(u8, scenario.provider, "anthropic")) {
        var factory = try anthropic.createAnthropic(.{
            .base_url = base_url,
            .api_key = "test-key",
            .transport = transport.transport(),
        });
        var model = try factory.messages(scenario.model, null);
        return runLanguage(io, gpa, arena, scenario, model.languageModel());
    }
    if (std.mem.eql(u8, scenario.provider, "openai-compatible")) {
        var factory = openai_compatible.createOpenAiCompatible(.{
            .provider_name = "conformance",
            .base_url = base_url,
            .api_key = "test-key",
            .transport = transport.transport(),
            .include_usage = true,
            .supports_structured_outputs = true,
        });
        var model = try factory.chatModel(scenario.model, null);
        return runLanguage(io, gpa, arena, scenario, model.languageModel());
    }
    return error.UnsupportedProvider;
}

fn runLanguage(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    model: provider.LanguageModel,
) !CommonEnvelope {
    const messages = try buildMessages(arena, scenario.input.messages);
    const tool_bundle = try buildTools(arena, scenario.input.tools);
    if (std.mem.eql(u8, scenario.surface, "generateText")) {
        return runGenerateText(io, gpa, arena, scenario, model, messages, tool_bundle.tools);
    }
    if (std.mem.eql(u8, scenario.surface, "streamText")) {
        return runStreamText(io, gpa, arena, scenario, model, messages, tool_bundle.tools);
    }
    if (std.mem.eql(u8, scenario.surface, "generateObject")) {
        return runGenerateObject(io, gpa, arena, scenario, model, messages);
    }
    if (std.mem.eql(u8, scenario.surface, "streamObject")) {
        return runStreamObject(io, gpa, arena, scenario, model, messages);
    }
    return error.UnsupportedSurface;
}

const ToolBundle = struct {
    states: []ToolRuntime,
    tools: []ai.NamedTool,
};

fn buildTools(arena: Allocator, definitions: []const ToolDefinition) !ToolBundle {
    const states = try arena.alloc(ToolRuntime, definitions.len);
    const tools = try arena.alloc(ai.NamedTool, definitions.len);
    for (definitions, states, tools) |definition, *state, *named| {
        state.* = .{ .output = definition.output };
        const schema_text = try provider_utils.stringifyJsonValueAlloc(arena, definition.input_schema);
        named.* = .{
            .name = definition.name,
            .tool = .{
                .description = if (definition.description) |description|
                    .{ .text = description }
                else
                    null,
                .input_schema = provider_utils.rawSchema(schema_text, null),
                .execute = .{ .ctx = state, .execute_fn = ToolRuntime.execute },
            },
        };
    }
    return .{ .states = states, .tools = tools };
}

fn buildMessages(arena: Allocator, input: []const InputMessage) ![]const ai.ModelMessage {
    const messages = try arena.alloc(ai.ModelMessage, input.len);
    for (input, messages) |source, *destination| {
        if (std.mem.eql(u8, source.role, "user")) {
            destination.* = .{ .user = .{ .content = .{ .text = source.content } } };
        } else if (std.mem.eql(u8, source.role, "system")) {
            destination.* = .{ .system = .{ .content = source.content } };
        } else if (std.mem.eql(u8, source.role, "assistant")) {
            destination.* = .{ .assistant = .{ .content = .{ .text = source.content } } };
        } else {
            return error.UnsupportedMessageRole;
        }
    }
    return messages;
}

fn runGenerateText(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    model: provider.LanguageModel,
    messages: []const ai.ModelMessage,
    tools: []const ai.NamedTool,
) !CommonEnvelope {
    var diagnostics = provider.Diagnostics.init(gpa);
    defer diagnostics.deinit();
    const stop_conditions = [_]ai.StopCondition{ai.loopFinished()};
    var native = ai.generateText(io, gpa, .{
        .model = .{ .model = model },
        .messages = messages,
        .tools = tools,
        .stop_when = if (tools.len == 0) &.{} else &stop_conditions,
        .max_retries = scenario.input.settings.maxRetries,
        .diag = &diagnostics,
    }) catch |err| return errorEnvelope(arena, scenario.surface, err);
    defer native.deinit();

    return .{
        .surface = try arena.dupe(u8, scenario.surface),
        .result = .{ .text = try arena.dupe(u8, native.text()) },
        .usage = mapUsage(native.usage()),
        .finish_reason = finishReasonName(native.finishReason().unified),
        .steps = try mapSteps(arena, native.steps),
        .messages = try mapMessages(arena, native.responseMessages()),
    };
}

fn runStreamText(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    model: provider.LanguageModel,
    messages: []const ai.ModelMessage,
    tools: []const ai.NamedTool,
) !CommonEnvelope {
    var diagnostics = provider.Diagnostics.init(gpa);
    defer diagnostics.deinit();
    const stop_conditions = [_]ai.StopCondition{ai.loopFinished()};
    var native = ai.streamText(io, gpa, .{
        .model = .{ .model = model },
        .messages = messages,
        .tools = tools,
        .stop_when = if (tools.len == 0) &.{} else &stop_conditions,
        .max_retries = scenario.input.settings.maxRetries,
        .diag = &diagnostics,
    }) catch |err| return errorEnvelope(arena, scenario.surface, err);
    defer native.deinit(io);

    var parts: std.ArrayList(CommonPart) = .empty;
    while (native.next(io) catch |err| return errorEnvelope(arena, scenario.surface, err)) |part| {
        try parts.append(arena, try mapTextPart(arena, part));
    }
    const text = native.text(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    const usage = native.totalUsage(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    const finish_reason = native.finishReason(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    const steps = native.steps(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    const response_messages = native.responseMessages(io) catch |err| return errorEnvelope(arena, scenario.surface, err);

    return .{
        .surface = try arena.dupe(u8, scenario.surface),
        .result = .{ .text = try arena.dupe(u8, text) },
        .stream_parts = try parts.toOwnedSlice(arena),
        .usage = mapUsage(usage),
        .finish_reason = finishReasonName(finish_reason.unified),
        .steps = try mapSteps(arena, steps),
        .messages = try mapMessages(arena, response_messages),
    };
}

fn schemaForInput(arena: Allocator, input: Input) !provider_utils.Schema {
    const schema = input.schema orelse return error.MissingSchema;
    const text = try provider_utils.stringifyJsonValueAlloc(arena, schema);
    return provider_utils.rawSchema(text, null);
}

fn runGenerateObject(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    model: provider.LanguageModel,
    messages: []const ai.ModelMessage,
) !CommonEnvelope {
    var diagnostics = provider.Diagnostics.init(gpa);
    defer diagnostics.deinit();
    var native = ai.generateObject(io, gpa, .{
        .model = .{ .model = model },
        .messages = messages,
        .schema = try schemaForInput(arena, scenario.input),
        .schema_name = scenario.input.schema_name,
        .schema_description = scenario.input.schema_description,
        .max_retries = scenario.input.settings.maxRetries,
        .diag = &diagnostics,
    }) catch |err| return errorEnvelope(arena, scenario.surface, err);
    defer native.deinit();
    return .{
        .surface = try arena.dupe(u8, scenario.surface),
        .result = .{ .object = try provider_utils.cloneJsonValue(arena, native.object) },
        .usage = mapUsage(native.usage),
        .finish_reason = finishReasonName(native.finish_reason.unified),
        .messages = emptyMessages(arena),
    };
}

fn runStreamObject(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    model: provider.LanguageModel,
    messages: []const ai.ModelMessage,
) !CommonEnvelope {
    var diagnostics = provider.Diagnostics.init(gpa);
    defer diagnostics.deinit();
    var native = ai.streamObject(io, gpa, .{
        .model = .{ .model = model },
        .messages = messages,
        .schema = try schemaForInput(arena, scenario.input),
        .schema_name = scenario.input.schema_name,
        .schema_description = scenario.input.schema_description,
        .max_retries = scenario.input.settings.maxRetries,
        .diag = &diagnostics,
    }) catch |err| return errorEnvelope(arena, scenario.surface, err);
    defer native.deinit(io);

    var parts: std.ArrayList(CommonPart) = .empty;
    while (native.next(io) catch |err| return errorEnvelope(arena, scenario.surface, err)) |part| {
        try parts.append(arena, try mapObjectPart(arena, part));
    }
    const object = native.object(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    const usage = native.usage(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    const finish_reason = native.finishReason(io) catch |err| return errorEnvelope(arena, scenario.surface, err);
    return .{
        .surface = try arena.dupe(u8, scenario.surface),
        .result = .{ .object = try provider_utils.cloneJsonValue(arena, object) },
        .stream_parts = try parts.toOwnedSlice(arena),
        .usage = mapUsage(usage),
        .finish_reason = finishReasonName(finish_reason.unified),
        .messages = emptyMessages(arena),
    };
}

fn runEmbeddings(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    scenario: Scenario,
    model: provider.EmbeddingModel,
) !CommonEnvelope {
    const value = scenario.input.value orelse return error.MissingEmbeddingValue;
    var diagnostics = provider.Diagnostics.init(gpa);
    defer diagnostics.deinit();
    var single = ai.embed(io, gpa, .{
        .model = .{ .model = model },
        .value = value,
        .max_retries = scenario.input.settings.maxRetries,
        .diag = &diagnostics,
    }) catch |err| return errorEnvelope(arena, scenario.surface, err);
    defer single.deinit();
    var many = ai.embedMany(io, gpa, .{
        .model = .{ .model = model },
        .values = scenario.input.values,
        .max_retries = scenario.input.settings.maxRetries,
        .diag = &diagnostics,
    }) catch |err| return errorEnvelope(arena, scenario.surface, err);
    defer many.deinit();

    const embeddings = try arena.alloc([]const f64, many.embeddings.len);
    for (many.embeddings, embeddings) |source, *destination| {
        destination.* = try arena.dupe(f64, source);
    }
    const values = try cloneStrings(arena, many.values);
    return .{
        .surface = try arena.dupe(u8, scenario.surface),
        .result = .{
            .embedding = try arena.dupe(f64, single.embedding),
            .embeddings = embeddings,
            .value = try arena.dupe(u8, single.value),
            .values = values,
        },
        .usage = .{
            .tokens = addOptional(single.usage.tokens, many.usage.tokens),
        },
        .messages = emptyMessages(arena),
    };
}

fn mapUsage(usage: provider.Usage) CommonUsage {
    return .{
        .input_tokens = usage.input_tokens.total,
        .input_token_details = .{
            .no_cache_tokens = usage.input_tokens.no_cache,
            .cache_read_tokens = usage.input_tokens.cache_read,
            .cache_write_tokens = usage.input_tokens.cache_write,
        },
        .output_tokens = usage.output_tokens.total,
        .output_token_details = .{
            .text_tokens = usage.output_tokens.text,
            .reasoning_tokens = usage.output_tokens.reasoning,
        },
        .total_tokens = addOptional(usage.input_tokens.total, usage.output_tokens.total),
    };
}

fn addOptional(left: ?u64, right: ?u64) ?u64 {
    if (left == null and right == null) return null;
    return (left orelse 0) +| (right orelse 0);
}

fn finishReasonName(reason: provider.FinishReasonUnified) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .content_filter => "content-filter",
        .tool_calls => "tool-calls",
        .@"error" => "error",
        .other => "other",
    };
}

fn mapToolCall(arena: Allocator, call: ai.TypedToolCall) !CommonToolCall {
    return .{
        .tool_call_id = try arena.dupe(u8, call.tool_call_id),
        .tool_name = try arena.dupe(u8, call.tool_name),
        .input = try provider_utils.cloneJsonValue(arena, call.input),
    };
}

fn mapToolResult(arena: Allocator, result: ai.TypedToolResult) !CommonToolResult {
    return .{
        .tool_call_id = try arena.dupe(u8, result.tool_call_id),
        .tool_name = try arena.dupe(u8, result.tool_name),
        .input = if (result.input) |input|
            try provider_utils.cloneJsonValue(arena, input)
        else
            null,
        .output = try provider_utils.cloneJsonValue(arena, result.output),
    };
}

fn mapSteps(arena: Allocator, steps: []const ai.StepResult) ![]const CommonStep {
    const mapped = try arena.alloc(CommonStep, steps.len);
    for (steps, mapped) |step, *destination| {
        const calls = try arena.alloc(CommonToolCall, step.toolCalls().len);
        for (step.toolCalls(), calls) |call, *mapped_call| {
            mapped_call.* = try mapToolCall(arena, call);
        }
        const results = try arena.alloc(CommonToolResult, step.toolResults().len);
        for (step.toolResults(), results) |result, *mapped_result| {
            mapped_result.* = try mapToolResult(arena, result);
        }
        destination.* = .{
            .text = try arena.dupe(u8, step.text()),
            .finish_reason = finishReasonName(step.finish_reason.unified),
            .usage = mapUsage(step.usage),
            .tool_calls = calls,
            .tool_results = results,
        };
    }
    return mapped;
}

fn mapMessages(arena: Allocator, messages: []const ai.ModelMessage) !JsonValue {
    const encoded = try provider.wire.stringifyAlloc(arena, messages);
    var value = try std.json.parseFromSliceLeaky(JsonValue, arena, encoded, .{});
    normalizeMessageDefaults(&value);
    return value;
}

fn normalizeMessageDefaults(value: *JsonValue) void {
    switch (value.*) {
        .array => |*array| for (array.items) |*item| normalizeMessageDefaults(item),
        .object => |*object| {
            if (object.get("providerExecuted")) |provider_executed| {
                if (provider_executed == .bool and !provider_executed.bool) {
                    _ = object.orderedRemove("providerExecuted");
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| normalizeMessageDefaults(entry.value_ptr);
        },
        else => {},
    }
}

fn emptyMessages(arena: Allocator) JsonValue {
    return .{ .array = std.json.Array.init(arena) };
}

fn emptyPart(part_type: []const u8) CommonPart {
    return .{ .type = part_type };
}

fn mapTextPart(arena: Allocator, part: ai.TextStreamPart) !CommonPart {
    return switch (part) {
        .start => emptyPart("start"),
        .start_step => emptyPart("start-step"),
        .text_start => |value| .{
            .type = "text-start",
            .id = try arena.dupe(u8, value.id),
        },
        .text_delta => |value| .{
            .type = "text-delta",
            .id = try arena.dupe(u8, value.id),
            .text = try arena.dupe(u8, value.text),
        },
        .text_end => |value| .{
            .type = "text-end",
            .id = try arena.dupe(u8, value.id),
        },
        .reasoning_start => |value| .{
            .type = "reasoning-start",
            .id = try arena.dupe(u8, value.id),
        },
        .reasoning_delta => |value| .{
            .type = "reasoning-delta",
            .id = try arena.dupe(u8, value.id),
            .text = try arena.dupe(u8, value.text),
        },
        .reasoning_end => |value| .{
            .type = "reasoning-end",
            .id = try arena.dupe(u8, value.id),
        },
        .tool_input_start => |value| .{
            .type = "tool-input-start",
            .id = try arena.dupe(u8, value.id),
            .tool_name = try arena.dupe(u8, value.tool_name),
        },
        .tool_input_delta => |value| .{
            .type = "tool-input-delta",
            .id = try arena.dupe(u8, value.id),
            .text = try arena.dupe(u8, value.delta),
        },
        .tool_input_end => |value| .{
            .type = "tool-input-end",
            .id = try arena.dupe(u8, value.id),
        },
        .tool_call => |value| .{
            .type = "tool-call",
            .tool_call_id = try arena.dupe(u8, value.tool_call_id),
            .tool_name = try arena.dupe(u8, value.tool_name),
            .input = try provider_utils.cloneJsonValue(arena, value.input),
        },
        .tool_result => |value| .{
            .type = "tool-result",
            .tool_call_id = try arena.dupe(u8, value.tool_call_id),
            .tool_name = try arena.dupe(u8, value.tool_name),
            .input = if (value.input) |input|
                try provider_utils.cloneJsonValue(arena, input)
            else
                null,
            .output = try provider_utils.cloneJsonValue(arena, value.output),
        },
        .finish_step => |value| .{
            .type = "finish-step",
            .finish_reason = finishReasonName(value.finish_reason.unified),
            .usage = mapUsage(value.usage),
        },
        .finish => |value| .{
            .type = "finish",
            .finish_reason = finishReasonName(value.finish_reason.unified),
            .usage = mapUsage(value.total_usage),
        },
        .err => .{
            .type = "error",
            .@"error" = .{ .category = "stream_error" },
        },
        .custom => emptyPart("custom"),
        .source => emptyPart("source"),
        .file => emptyPart("file"),
        .reasoning_file => emptyPart("reasoning-file"),
        .tool_error => emptyPart("tool-error"),
        .tool_output_denied => emptyPart("tool-output-denied"),
        .tool_approval_request => emptyPart("tool-approval-request"),
        .tool_approval_response => emptyPart("tool-approval-response"),
        .abort => emptyPart("abort"),
        .raw => emptyPart("raw"),
    };
}

fn mapObjectPart(arena: Allocator, part: ai.ObjectStreamPart) !CommonPart {
    return switch (part) {
        .object => |value| .{
            .type = "object",
            .object = try provider_utils.cloneJsonValue(arena, value),
        },
        .text_delta => |value| .{
            .type = "text-delta",
            .text = try arena.dupe(u8, value),
        },
        .finish => |value| .{
            .type = "finish",
            .finish_reason = finishReasonName(value.finish_reason.unified),
            .usage = mapUsage(value.usage),
        },
        .err => .{
            .type = "error",
            .@"error" = .{ .category = "stream_error" },
        },
    };
}

fn errorEnvelope(arena: Allocator, surface: []const u8, err: anyerror) !CommonEnvelope {
    return .{
        .surface = try arena.dupe(u8, surface),
        .messages = emptyMessages(arena),
        .@"error" = .{ .category = errorCategory(err) },
    };
}

fn errorCategory(err: anyerror) []const u8 {
    return switch (err) {
        error.APICallError => "api_call_error",
        error.InvalidArgumentError => "invalid_argument_error",
        error.TypeValidationError => "type_validation_error",
        error.NoObjectGeneratedError => "no_object_generated_error",
        else => @errorName(err),
    };
}

fn cloneStrings(arena: Allocator, values: []const []const u8) ![]const []const u8 {
    const output = try arena.alloc([]const u8, values.len);
    for (values, output) |value, *destination| {
        destination.* = try arena.dupe(u8, value);
    }
    return output;
}
