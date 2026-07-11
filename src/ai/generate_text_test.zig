const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const approval_signature = @import("tool_approval_signature.zig");
const events = @import("events.zig");
const generate = @import("generate_text.zig");
const message = @import("message.zig");
const telemetry = @import("telemetry.zig");
const tool_api = @import("tool.zig");

const FakeLanguageModel = struct {
    actions: []const Action,
    call_count: usize = 0,
    prompts: [16]?provider.Prompt = .{null} ** 16,
    sleep_ms: u64 = 0,

    const Action = union(enum) {
        result: provider.GenerateResult,
        failure: Failure,
    };

    const Failure = struct {
        err: provider.CallError,
        diagnostic: ?provider.Payload = null,
    };

    fn languageModel(self: *FakeLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn fromRaw(raw: *anyopaque) *FakeLanguageModel {
        return @ptrCast(@alignCast(raw));
    }

    fn providerName(_: *anyopaque) []const u8 {
        return "fake";
    }

    fn modelId(_: *anyopaque) []const u8 {
        return "scripted-model";
    }

    fn urlSupported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn doGenerate(
        raw: *anyopaque,
        io: std.Io,
        _: std.mem.Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const self = fromRaw(raw);
        const index = self.call_count;
        self.call_count += 1;
        if (index < self.prompts.len) self.prompts[index] = options.prompt;
        if (self.sleep_ms != 0) {
            const duration: i64 = @intCast(self.sleep_ms);
            try io.sleep(.fromMilliseconds(duration), .awake);
        }
        const action = self.actions[@min(index, self.actions.len - 1)];
        return switch (action) {
            .result => |result| result,
            .failure => |failure| {
                if (failure.diagnostic) |payload| provider.Diagnostics.set(diag, diag.?.allocator, payload);
                return failure.err;
            },
        };
    }

    fn doStream(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return error.UnsupportedFunctionalityError;
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .urlIsSupported = urlSupported,
        .doGenerate = doGenerate,
        .doStream = doStream,
    };
};

fn generated(
    content: []const provider.Content,
    finish_reason: provider.FinishReasonUnified,
    input_tokens: ?u64,
    output_tokens: ?u64,
) provider.GenerateResult {
    return .{
        .content = content,
        .finish_reason = .{ .unified = finish_reason, .raw = @tagName(finish_reason) },
        .usage = .{
            .input_tokens = .{ .total = input_tokens },
            .output_tokens = .{ .total = output_tokens },
        },
        .warnings = &.{},
    };
}

test "generateText defaults to one step and owns text output" {
    const content = [_]provider.Content{.{ .text = .{ .text = "hello" } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&content, .stop, 3, 2) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };

    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "say hello" },
    });
    defer result.deinit();

    try std.testing.expectEqual(1, fake.call_count);
    try std.testing.expectEqual(1, result.steps.len);
    try std.testing.expectEqualStrings("hello", result.text());
    try std.testing.expectEqual(3, result.usage().input_tokens.total.?);
    try std.testing.expectError(error.NoOutputGeneratedError, result.output());
}

const WeatherTool = struct {
    calls: usize = 0,
    saw_city: bool = false,

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        _: tool_api.ToolExecutionOptions,
    ) anyerror!tool_api.ToolOutput {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.saw_city = std.mem.eql(u8, input.object.get("city").?.string, "Paris");
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "temperature", .{ .integer = 21 });
        return .{ .value = .{ .object = object } };
    }
};

test "generateText feeds an executed tool result into the second model prompt" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "call-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const second_content = [_]provider.Content{.{ .text = .{ .text = "It is 21 C." } }};
    const actions = [_]FakeLanguageModel.Action{
        .{ .result = generated(&first_content, .tool_calls, 5, 3) },
        .{ .result = generated(&second_content, .stop, 8, 4) },
    };
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
        },
    }};

    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "weather?" },
        .tools = &tools,
        .stop_when = &.{generate.loopFinished()},
    });
    defer result.deinit();

    try std.testing.expectEqual(2, fake.call_count);
    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("It is 21 C.", result.text());
    try std.testing.expectEqual(13, result.usage().input_tokens.total.?);
    try std.testing.expectEqual(7, result.usage().output_tokens.total.?);

    const second_prompt = fake.prompts[1].?;
    try std.testing.expectEqual(3, second_prompt.len);
    try std.testing.expect(second_prompt[1] == .assistant);
    try std.testing.expectEqualStrings("call-1", second_prompt[1].assistant.content[0].tool_call.tool_call_id);
    try std.testing.expect(second_prompt[2] == .tool);
    try std.testing.expectEqualStrings("call-1", second_prompt[2].tool.content[0].tool_result.tool_call_id);
}

test "tool without execute is a natural loop stop" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "call-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&first_content, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{ .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }) },
    }};

    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .messages = &.{.{ .user = .{ .content = .{ .text = "weather?" } } }},
        .tools = &tools,
        .stop_when = &.{generate.loopFinished()},
        .output = generate.text(),
    });
    defer result.deinit();
    try std.testing.expectEqual(1, fake.call_count);
    try std.testing.expectEqual(1, result.steps.len);
    try std.testing.expectEqual(0, result.toolResults().len);
    try std.testing.expectError(error.NoOutputGeneratedError, result.output());
}

test "text output parses only a final stop response" {
    const content = [_]provider.Content{.{ .text = .{ .text = "complete" } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&content, .stop, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "go" },
        .output = generate.text(),
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("complete", (try result.output()).text);
}

test "retry-after numeric headers respect priority and cap rules" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    provider.Diagnostics.set(&diagnostics, diagnostics.allocator, .{ .api_call = .{
        .message = "limited",
        .url = "https://example.test",
        .is_retryable = true,
        .response_headers = &.{
            .{ .name = "retry-after", .value = "3" },
            .{ .name = "retry-after-ms", .value = "125.9" },
        },
    } });
    try std.testing.expectEqual(125, generate.retryDelayInMs(error.APICallError, &diagnostics, 2000));

    provider.Diagnostics.set(&diagnostics, diagnostics.allocator, .{ .api_call = .{
        .message = "limited",
        .url = "https://example.test",
        .is_retryable = true,
        .response_headers = &.{.{ .name = "retry-after", .value = "2.5" }},
    } });
    try std.testing.expectEqual(2500, generate.retryDelayInMs(error.APICallError, &diagnostics, 4000));

    provider.Diagnostics.set(&diagnostics, diagnostics.allocator, .{ .api_call = .{
        .message = "limited",
        .url = "https://example.test",
        .is_retryable = true,
        .response_headers = &.{.{ .name = "retry-after-ms", .value = "60000" }},
    } });
    try std.testing.expectEqual(2000, generate.retryDelayInMs(error.APICallError, &diagnostics, 2000));
    try std.testing.expectEqual(60_000, generate.retryDelayInMs(error.APICallError, &diagnostics, 120_000));
}

test "stepCount and hasToolCall stop conditions OR-compose" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "call-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&first_content, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "weather?" },
        .tools = &tools,
        .stop_when = &.{ generate.stepCount(99), generate.hasToolCall(&.{"weather"}) },
    });
    defer result.deinit();
    try std.testing.expectEqual(1, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
}

test "deferred provider tool result drives a continuation and resolves later" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "provider-1",
        .tool_name = "code_execution",
        .input = "{\"code\":\"1+1\"}",
        .provider_executed = true,
    } }};
    const second_content = [_]provider.Content{
        .{ .tool_result = .{
            .tool_call_id = "provider-1",
            .tool_name = "code_execution",
            .result = .{ .integer = 2 },
            .provider_metadata = null,
        } },
        .{ .text = .{ .text = "two" } },
    };
    const actions = [_]FakeLanguageModel.Action{
        .{ .result = generated(&first_content, .tool_calls, 2, 1) },
        .{ .result = generated(&second_content, .stop, 3, 1) },
    };
    var fake: FakeLanguageModel = .{ .actions = &actions };
    const tools = [_]tool_api.NamedTool{.{
        .name = "code_execution",
        .tool = .{
            .kind = .provider_executed,
            .input_schema = provider_utils.schemaFromType(struct { code: []const u8 }),
            .provider_id = "fake.code_execution",
            .provider_args = .{ .object = .empty },
            .supports_deferred_results = true,
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "compute" },
        .tools = &tools,
        .stop_when = &.{generate.loopFinished()},
    });
    defer result.deinit();
    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqualStrings("two", result.text());
    try std.testing.expectEqual(1, result.toolResults().len);
    try std.testing.expect(result.toolResults()[0].provider_executed);
    try std.testing.expectEqual(null, result.toolResults()[0].input);
}

test "invalid tool input becomes data and the loop continues" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "bad-1",
        .tool_name = "weather",
        .input = "not-json",
    } }};
    const second_content = [_]provider.Content{.{ .text = .{ .text = "recovered" } }};
    const actions = [_]FakeLanguageModel.Action{
        .{ .result = generated(&first_content, .tool_calls, 1, 1) },
        .{ .result = generated(&second_content, .stop, 1, 1) },
    };
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "weather" },
        .tools = &tools,
        .stop_when = &.{generate.loopFinished()},
    });
    defer result.deinit();
    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(.tool_calls, result.steps[0].finish_reason.unified);
    try std.testing.expectEqual(1, result.steps[0].toolErrors().len);
    try std.testing.expectEqual(0, weather.calls);
    try std.testing.expectEqualStrings("recovered", result.text());
    const second_prompt = fake.prompts[1].?;
    try std.testing.expect(second_prompt[1] == .assistant);
    try std.testing.expect(second_prompt[2] == .tool);
    try std.testing.expect(second_prompt[2].tool.content[0].tool_result.output == .error_text);
}

const RepairBehavior = enum { success, null_result, throws };

const RepairState = struct {
    behavior: RepairBehavior,

    fn repair(
        raw: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        options: *const generate.RepairToolCallOptions,
    ) anyerror!?provider.GeneratedToolCall {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try std.testing.expectEqualStrings("weather", options.tool_call.tool_name);
        return switch (self.behavior) {
            .success => .{
                .tool_call_id = options.tool_call.tool_call_id,
                .tool_name = "weather",
                .input = "{\"city\":\"Paris\"}",
            },
            .null_result => null,
            .throws => error.RepairExploded,
        };
    }
};

test "tool call repair success null and throw all flow through result data" {
    inline for (.{ RepairBehavior.success, .null_result, .throws }) |behavior| {
        const first_content = [_]provider.Content{.{ .tool_call = .{
            .tool_call_id = "repair-1",
            .tool_name = "weather",
            .input = "bad",
        } }};
        const second_content = [_]provider.Content{.{ .text = .{ .text = "done" } }};
        const actions = [_]FakeLanguageModel.Action{
            .{ .result = generated(&first_content, .tool_calls, 1, 1) },
            .{ .result = generated(&second_content, .stop, 1, 1) },
        };
        var fake: FakeLanguageModel = .{ .actions = &actions };
        var weather: WeatherTool = .{};
        var repair_state: RepairState = .{ .behavior = behavior };
        const tools = [_]tool_api.NamedTool{.{
            .name = "weather",
            .tool = .{
                .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
                .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
            },
        }};
        var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
            .model = .{ .model = fake.languageModel() },
            .prompt = .{ .text = "weather" },
            .tools = &tools,
            .repair_tool_call = .{ .ctx = &repair_state, .repair_fn = RepairState.repair },
            .stop_when = &.{generate.loopFinished()},
        });
        defer result.deinit();
        if (behavior == .success) {
            try std.testing.expectEqual(1, weather.calls);
            try std.testing.expect(!result.toolCalls()[0].invalid);
        } else {
            try std.testing.expectEqual(0, weather.calls);
            try std.testing.expect(result.toolCalls()[0].invalid);
            if (behavior == .throws) {
                try std.testing.expectEqual(error.ToolCallRepairError, result.toolCalls()[0].err.?.err);
            }
        }
    }
}

const RefineState = struct {
    fn refine(
        _: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        _: std.json.Value,
    ) anyerror!std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "city", .{ .string = "Paris" });
        return .{ .object = object };
    }
};

test "refine hook changes execution and retained tool input" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "refine-1",
        .tool_name = "weather",
        .input = "{\"city\":\"paris\"}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&first_content, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
        },
    }};
    const refinements = [_]generate.RefineToolInput{.{
        .tool_name = "weather",
        .refine_fn = RefineState.refine,
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "weather" },
        .tools = &tools,
        .refine_tool_input = &refinements,
    });
    defer result.deinit();
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("Paris", result.toolCalls()[0].input.object.get("city").?.string);
}

const PrepareState = struct {
    calls: usize = 0,
    override_messages: []const message.ModelMessage,

    fn prepare(
        raw: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        options: *const generate.PrepareStepOptions,
    ) provider.CallError!?generate.PrepareStepResult {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        defer self.calls += 1;
        if (options.step_number == 0) {
            std.debug.assert(options.steps.len == 0);
            return .{
                .instructions = .{ .text = "carried instruction" },
                .messages = self.override_messages,
                .runtime_context = .{ .string = "runtime-2" },
                .tools_context = .{ .string = "tools-2" },
                .provider_options = .{ .object = .empty },
            };
        }
        std.debug.assert(options.steps.len == 1);
        std.debug.assert(std.mem.eql(u8, "carried instruction", options.instructions.?.text));
        std.debug.assert(std.mem.eql(u8, "runtime-2", options.runtime_context.?.string));
        std.debug.assert(std.mem.eql(u8, "tools-2", options.tools_context.?.string));
        std.debug.assert(options.messages.len >= 3);
        return null;
    }
};

test "prepareStep overrides carry instructions messages and contexts forward" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "prepare-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const second_content = [_]provider.Content{.{ .text = .{ .text = "prepared" } }};
    const actions = [_]FakeLanguageModel.Action{
        .{ .result = generated(&first_content, .tool_calls, 1, 1) },
        .{ .result = generated(&second_content, .stop, 1, 1) },
    };
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
        },
    }};
    const override_messages = [_]message.ModelMessage{.{ .user = .{ .content = .{ .text = "override" } } }};
    var prepare_state: PrepareState = .{ .override_messages = &override_messages };
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "original" },
        .tools = &tools,
        .prepare_step = .{ .ctx = &prepare_state, .prepare_fn = PrepareState.prepare },
        .stop_when = &.{generate.loopFinished()},
    });
    defer result.deinit();
    try std.testing.expectEqual(2, prepare_state.calls);
    const second_prompt = fake.prompts[1].?;
    try std.testing.expect(second_prompt[0] == .system);
    try std.testing.expectEqualStrings("carried instruction", second_prompt[0].system.content);
    try std.testing.expect(second_prompt[1] == .user);
    try std.testing.expectEqualStrings("override", second_prompt[1].user.content[0].text.text);
}

test "approved and denied incoming approvals produce pre-step tool outputs" {
    inline for (.{ true, false }) |approved| {
        const final_content = [_]provider.Content{.{ .text = .{ .text = "continued" } }};
        const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&final_content, .stop, 1, 1) }};
        var fake: FakeLanguageModel = .{ .actions = &actions };
        var weather: WeatherTool = .{};
        const tools = [_]tool_api.NamedTool{.{
            .name = "weather",
            .tool = .{
                .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
                .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
                .needs_approval = .yes,
            },
        }};
        const parsed_input = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            "{\"city\":\"Paris\"}",
            .{},
        );
        defer parsed_input.deinit();
        var signature_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer signature_arena_state.deinit();
        const assistant_parts = [_]message.AssistantContentPart{
            .{ .tool_call = .{
                .tool_call_id = "approval-call",
                .tool_name = "weather",
                .input = parsed_input.value,
            } },
            .{ .tool_approval_request = .{
                .approval_id = "approval-1",
                .tool_call_id = "approval-call",
                .signature = if (approved) try approval_signature.sign(
                    signature_arena_state.allocator(),
                    "approval-secret",
                    "approval-1",
                    "approval-call",
                    "weather",
                    parsed_input.value,
                ) else null,
            } },
        };
        const tool_parts = [_]message.ToolContentPart{.{ .tool_approval_response = .{
            .approval_id = "approval-1",
            .approved = approved,
            .reason = if (approved) null else "not allowed",
        } }};
        const messages = [_]message.ModelMessage{
            .{ .user = .{ .content = .{ .text = "weather" } } },
            .{ .assistant = .{ .content = .{ .parts = &assistant_parts } } },
            .{ .tool = .{ .content = &tool_parts } },
        };
        var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
            .model = .{ .model = fake.languageModel() },
            .messages = &messages,
            .tools = &tools,
            .tool_approval_secret = if (approved) "approval-secret" else null,
        });
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, if (approved) 1 else 0), weather.calls);
        try std.testing.expectEqual(2, result.responseMessages().len);
        try std.testing.expect(result.responseMessages()[0] == .tool);
        const initial_output = result.responseMessages()[0].tool.content[0].tool_result.output;
        if (approved) {
            try std.testing.expect(initial_output == .json);
        } else {
            try std.testing.expect(initial_output == .execution_denied);
        }
        const provider_prompt = fake.prompts[0].?;
        try std.testing.expect(provider_prompt[provider_prompt.len - 1] == .tool);
        var saw_result = false;
        for (provider_prompt[provider_prompt.len - 1].tool.content) |part| switch (part) {
            .tool_result => saw_result = true,
            else => {},
        };
        try std.testing.expect(saw_result);
    }
}

test "tool needing approval blocks execution and halts the loop" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "blocked-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&first_content, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
            .needs_approval = .yes,
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "weather" },
        .tools = &tools,
        .stop_when = &.{generate.loopFinished()},
    });
    defer result.deinit();
    try std.testing.expectEqual(1, result.steps.len);
    try std.testing.expectEqual(0, weather.calls);
    try std.testing.expect(result.steps[0].content[result.steps[0].content.len - 1] == .tool_approval_request);
    try std.testing.expect(result.responseMessages()[0] == .assistant);
}

test "approved replay with a configured secret rejects a missing signature" {
    const unused_content = [_]provider.Content{.{ .text = .{ .text = "unused" } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&unused_content, .stop, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
            .needs_approval = .yes,
        },
    }};
    const parsed_input = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"city\":\"Paris\"}",
        .{},
    );
    defer parsed_input.deinit();
    const assistant_parts = [_]message.AssistantContentPart{
        .{ .tool_call = .{
            .tool_call_id = "approval-call",
            .tool_name = "weather",
            .input = parsed_input.value,
        } },
        .{ .tool_approval_request = .{
            .approval_id = "approval-1",
            .tool_call_id = "approval-call",
        } },
    };
    const tool_parts = [_]message.ToolContentPart{.{ .tool_approval_response = .{
        .approval_id = "approval-1",
        .approved = true,
    } }};
    const messages = [_]message.ModelMessage{
        .{ .user = .{ .content = .{ .text = "weather" } } },
        .{ .assistant = .{ .content = .{ .parts = &assistant_parts } } },
        .{ .tool = .{ .content = &tool_parts } },
    };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.InvalidToolApprovalSignatureError, generate.generateText(
        std.testing.io,
        std.testing.allocator,
        .{
            .model = .{ .model = fake.languageModel() },
            .messages = &messages,
            .tools = &tools,
            .tool_approval_secret = "approval-secret",
            .diag = &diagnostics,
        },
    ));
    try std.testing.expectEqual(0, fake.call_count);
    try std.testing.expect(diagnostics.payload == .invalid_tool_approval_signature);
    try std.testing.expectEqualStrings("missing signature", diagnostics.payload.invalid_tool_approval_signature.reason);
}

const OrderRecorder = struct {
    values: [16]u8 = undefined,
    index: std.atomic.Value(usize) = .init(0),

    fn add(self: *@This(), value: u8) void {
        const index = self.index.fetchAdd(1, .monotonic);
        self.values[index] = value;
    }
    fn start(raw: ?*anyopaque, _: *const events.GenerateTextStartEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(1);
    }
    fn stepStart(raw: ?*anyopaque, _: *const events.StepStartEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(2);
    }
    fn modelStart(raw: ?*anyopaque, _: *const events.LanguageModelCallStartEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(3);
    }
    fn modelEnd(raw: ?*anyopaque, _: *const events.LanguageModelCallEndEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(4);
    }
    fn toolStart(raw: ?*anyopaque, _: *const events.ToolExecutionStartEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(5);
    }
    fn toolEnd(raw: ?*anyopaque, _: *const events.ToolExecutionEndEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(6);
    }
    fn stepEnd(raw: ?*anyopaque, event: *const events.StepEndEvent) anyerror!void {
        try std.testing.expectEqual(event.step_number, event.step_result.step_number);
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(7);
    }
    fn end(raw: ?*anyopaque, _: *const events.EndEvent) anyerror!void {
        (@as(*@This(), @ptrCast(@alignCast(raw.?)))).add(8);
    }
};

test "callbacks observe canonical lifecycle order" {
    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "order-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&first_content, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    var recorder: OrderRecorder = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = &weather, .execute_fn = WeatherTool.execute },
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "weather" },
        .tools = &tools,
        .callbacks = .{
            .on_start = .{ .ctx = &recorder, .callback = OrderRecorder.start },
            .on_step_start = .{ .ctx = &recorder, .callback = OrderRecorder.stepStart },
            .on_language_model_call_start = .{ .ctx = &recorder, .callback = OrderRecorder.modelStart },
            .on_language_model_call_end = .{ .ctx = &recorder, .callback = OrderRecorder.modelEnd },
            .on_tool_execution_start = .{ .ctx = &recorder, .callback = OrderRecorder.toolStart },
            .on_tool_execution_end = .{ .ctx = &recorder, .callback = OrderRecorder.toolEnd },
            .on_step_end = .{ .ctx = &recorder, .callback = OrderRecorder.stepEnd },
            .on_end = .{ .ctx = &recorder, .callback = OrderRecorder.end },
        },
    });
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, recorder.values[0..8]);
}

const TelemetryCounter = struct {
    enters: std.atomic.Value(usize) = .init(0),
    exits: std.atomic.Value(usize) = .init(0),

    fn enter(raw: ?*anyopaque, _: []const u8) ?*anyopaque {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.enters.fetchAdd(1, .monotonic);
        return raw;
    }

    fn exit(raw: ?*anyopaque, token: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        std.debug.assert(token == raw);
        _ = self.exits.fetchAdd(1, .monotonic);
    }
};

test "telemetry model-call enter and exit wrap every retry attempt" {
    const final_content = [_]provider.Content{.{ .text = .{ .text = "retried" } }};
    const actions = [_]FakeLanguageModel.Action{
        .{ .failure = .{
            .err = error.APICallError,
            .diagnostic = .{ .api_call = .{
                .message = "limited",
                .url = "https://example.test",
                .is_retryable = true,
                .response_headers = &.{.{ .name = "retry-after-ms", .value = "0" }},
            } },
        } },
        .{ .result = generated(&final_content, .stop, 1, 1) },
    };
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var counter: TelemetryCounter = .{};
    const integrations = [_]telemetry.Telemetry{.{
        .ctx = &counter,
        .vtable = &.{
            .enterModelCall = TelemetryCounter.enter,
            .exitModelCall = TelemetryCounter.exit,
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "retry" },
        .max_retries = 1,
        .diag = &diagnostics,
        .telemetry = .{ .integrations = &integrations },
    });
    defer result.deinit();
    try std.testing.expectEqual(2, fake.call_count);
    try std.testing.expectEqual(2, counter.enters.load(.monotonic));
    try std.testing.expectEqual(2, counter.exits.load(.monotonic));
}

const TerminalCallbacks = struct {
    aborts: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
    ends: std.atomic.Value(usize) = .init(0),
    saw_timeout: std.atomic.Value(bool) = .init(false),
    saw_diagnostics: std.atomic.Value(bool) = .init(false),

    fn abort(raw: ?*anyopaque, event: *const events.AbortEvent) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.aborts.fetchAdd(1, .monotonic);
        if (event.reason != null and std.mem.eql(u8, event.reason.?, "timeout")) self.saw_timeout.store(true, .release);
    }
    fn err(raw: ?*anyopaque, event: *const events.ErrorEvent) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.errors.fetchAdd(1, .monotonic);
        if (event.diag != null and event.diag.?.available) self.saw_diagnostics.store(true, .release);
    }
    fn end(raw: ?*anyopaque, _: *const events.EndEvent) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.ends.fetchAdd(1, .monotonic);
    }
};

test "step timeout fires onAbort timeout without onError or onEnd" {
    const content = [_]provider.Content{.{ .text = .{ .text = "late" } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&content, .stop, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions, .sleep_ms = 100 };
    var terminal: TerminalCallbacks = .{};
    try std.testing.expectError(error.Canceled, generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "slow" },
        .timeout = .{ .granular = .{ .step_ms = 10 } },
        .callbacks = .{
            .on_abort = .{ .ctx = &terminal, .callback = TerminalCallbacks.abort },
            .on_error = .{ .ctx = &terminal, .callback = TerminalCallbacks.err },
            .on_end = .{ .ctx = &terminal, .callback = TerminalCallbacks.end },
        },
    }));
    try std.testing.expectEqual(1, terminal.aborts.load(.monotonic));
    try std.testing.expect(terminal.saw_timeout.load(.acquire));
    try std.testing.expectEqual(0, terminal.errors.load(.monotonic));
    try std.testing.expectEqual(0, terminal.ends.load(.monotonic));
}

const SlowTool = struct {
    fn execute(
        _: ?*anyopaque,
        io: std.Io,
        _: std.mem.Allocator,
        _: std.json.Value,
        _: tool_api.ToolExecutionOptions,
    ) anyerror!tool_api.ToolOutput {
        try io.sleep(.fromMilliseconds(100), .awake);
        return .{ .value = .{ .string = "late" } };
    }
};

test "tool timeout aborts the call instead of becoming tool-error data" {
    const calls = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "slow-tool",
        .tool_name = "slow",
        .input = "{}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&calls, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    const tools = [_]tool_api.NamedTool{.{
        .name = "slow",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct {}),
            .execute = .{ .execute_fn = SlowTool.execute },
        },
    }};
    var terminal: TerminalCallbacks = .{};
    try std.testing.expectError(error.Canceled, generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "slow" },
        .tools = &tools,
        .timeout = .{ .granular = .{ .tool_ms = 10 } },
        .callbacks = .{
            .on_abort = .{ .ctx = &terminal, .callback = TerminalCallbacks.abort },
            .on_error = .{ .ctx = &terminal, .callback = TerminalCallbacks.err },
            .on_end = .{ .ctx = &terminal, .callback = TerminalCallbacks.end },
        },
    }));
    try std.testing.expectEqual(1, terminal.aborts.load(.monotonic));
    try std.testing.expect(terminal.saw_timeout.load(.acquire));
    try std.testing.expectEqual(0, terminal.errors.load(.monotonic));
    try std.testing.expectEqual(0, terminal.ends.load(.monotonic));
}

test "failure fires onError exactly once with diagnostics" {
    const actions = [_]FakeLanguageModel.Action{.{ .failure = .{
        .err = error.APICallError,
        .diagnostic = .{ .api_call = .{
            .message = "bad request",
            .url = "https://example.test",
            .status_code = 400,
            .is_retryable = false,
        } },
    } }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var terminal: TerminalCallbacks = .{};
    try std.testing.expectError(error.APICallError, generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "fail" },
        .max_retries = 0,
        .diag = &diagnostics,
        .callbacks = .{
            .on_abort = .{ .ctx = &terminal, .callback = TerminalCallbacks.abort },
            .on_error = .{ .ctx = &terminal, .callback = TerminalCallbacks.err },
            .on_end = .{ .ctx = &terminal, .callback = TerminalCallbacks.end },
        },
    }));
    try std.testing.expectEqual(0, terminal.aborts.load(.monotonic));
    try std.testing.expectEqual(1, terminal.errors.load(.monotonic));
    try std.testing.expect(terminal.saw_diagnostics.load(.acquire));
    try std.testing.expectEqual(0, terminal.ends.load(.monotonic));
}

const EchoTool = struct {
    fn execute(
        _: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        input: std.json.Value,
        _: tool_api.ToolExecutionOptions,
    ) anyerror!tool_api.ToolOutput {
        return .{ .value = input };
    }
};

test "parallel tool results remain in provider tool-call order" {
    const calls = [_]provider.Content{
        .{ .tool_call = .{ .tool_call_id = "second", .tool_name = "echo", .input = "{\"value\":2}" } },
        .{ .tool_call = .{ .tool_call_id = "first", .tool_name = "echo", .input = "{\"value\":1}" } },
    };
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&calls, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    const tools = [_]tool_api.NamedTool{.{
        .name = "echo",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { value: u64 }),
            .execute = .{ .execute_fn = EchoTool.execute },
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "echo" },
        .tools = &tools,
    });
    defer result.deinit();
    const response_messages = result.steps[0].response.messages;
    try std.testing.expectEqual(2, response_messages.len);
    const tool_message = response_messages[1].tool;
    try std.testing.expectEqualStrings("second", tool_message.content[0].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("first", tool_message.content[1].tool_result.tool_call_id);
}

const PreliminaryTool = struct {
    stream_state: StreamState = .{},

    const StreamState = struct {
        index: usize = 0,

        fn next(raw: *anyopaque, _: std.Io) anyerror!?std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .integer = 1 },
                1 => .{ .integer = 2 },
                else => null,
            };
        }
    };

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: std.json.Value,
        _: tool_api.ToolExecutionOptions,
    ) anyerror!tool_api.ToolOutput {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.stream_state.index = 0;
        return .{ .stream = .{
            .ctx = &self.stream_state,
            .vtable = &.{ .next = StreamState.next },
        } };
    }
};

test "generateText drops preliminary stream values and retains only the last" {
    const calls = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "stream-result",
        .tool_name = "progress",
        .input = "{}",
    } }};
    const actions = [_]FakeLanguageModel.Action{.{ .result = generated(&calls, .tool_calls, 1, 1) }};
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var progress: PreliminaryTool = .{};
    const tools = [_]tool_api.NamedTool{.{
        .name = "progress",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct {}),
            .execute = .{ .ctx = &progress, .execute_fn = PreliminaryTool.execute },
        },
    }};
    var result = try generate.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "progress" },
        .tools = &tools,
    });
    defer result.deinit();
    try std.testing.expectEqual(1, result.toolResults().len);
    try std.testing.expectEqual(2, result.toolResults()[0].output.integer);
}
