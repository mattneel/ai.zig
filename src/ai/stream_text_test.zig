const std = @import("std");
const provider = @import("provider");
const stream_text = @import("stream_text.zig");
const generate_text = @import("generate_text.zig");
const events = @import("events.zig");
const message = @import("message.zig");
const telemetry = @import("telemetry.zig");
const smooth_stream = @import("stream/smooth_stream.zig");

const ScriptedModel = struct {
    scripts: []const []const provider.StreamPart,
    call_count: usize = 0,
    saw_tool_result_prompt: bool = false,
    states: [8]State = .{State{}} ** 8,

    const State = struct {
        parts: []const provider.StreamPart = &.{},
        index: usize = 0,

        fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
            const self: *State = @ptrCast(@alignCast(raw));
            if (self.index == self.parts.len) return null;
            defer self.index += 1;
            return self.parts[self.index];
        }

        fn deinit(_: *anyopaque, _: std.Io) void {}

        const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };
    };

    fn languageModel(self: *ScriptedModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn providerName(_: *anyopaque) []const u8 {
        return "scripted";
    }

    fn modelId(_: *anyopaque) []const u8 {
        return "stream-model";
    }

    fn urlSupported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn doGenerate(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return error.UnsupportedFunctionalityError;
    }

    fn doStream(
        raw: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        options: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const self: *ScriptedModel = @ptrCast(@alignCast(raw));
        const index = self.call_count;
        self.call_count += 1;
        for (options.prompt) |prompt_message| switch (prompt_message) {
            .tool => |tool_message| for (tool_message.content) |content| switch (content) {
                .tool_result => self.saw_tool_result_prompt = true,
                else => {},
            },
            else => {},
        };
        self.states[index] = .{ .parts = self.scripts[@min(index, self.scripts.len - 1)] };
        return .{ .stream = .{ .ctx = &self.states[index], .vtable = &State.vtable } };
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .urlIsSupported = urlSupported,
        .doGenerate = doGenerate,
        .doStream = doStream,
    };
};

fn usage(input: u64, output: u64) provider.Usage {
    return .{
        .input_tokens = .{ .total = input },
        .output_tokens = .{ .total = output, .text = output },
    };
}

const FailingModel = struct {
    fn languageModel(self: *FailingModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn p(_: *anyopaque) []const u8 {
        return "failing";
    }
    fn m(_: *anyopaque) []const u8 {
        return "failing-model";
    }
    fn u(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }
    fn g(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
        return error.UnsupportedFunctionalityError;
    }
    fn s(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
        return error.APICallError;
    }
    const vtable: provider.LanguageModel.VTable = .{
        .provider = p,
        .modelId = m,
        .urlIsSupported = u,
        .doGenerate = g,
        .doStream = s,
    };
};

const InterruptingModel = struct {
    const Behavior = enum { cancel, delay };

    behavior: Behavior,
    delay_ms: u64 = 0,
    state: State = .{},

    const State = struct {
        behavior: Behavior = .cancel,
        delay_ms: u64 = 0,
        index: usize = 0,

        fn next(raw: *anyopaque, io: std.Io) provider.NextError!?provider.StreamPart {
            const self: *State = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .stream_start = .{ .warnings = &.{} } },
                1 => .{ .response_metadata = .{ .id = "interrupt-response", .model_id = "interrupt-model" } },
                2 => switch (self.behavior) {
                    .cancel => error.Canceled,
                    .delay => blk: {
                        const milliseconds: i64 = @intCast(self.delay_ms);
                        try io.sleep(.fromMilliseconds(milliseconds), .awake);
                        break :blk .{ .text_start = .{ .id = "late" } };
                    },
                },
                3 => .{ .text_delta = .{ .id = "late", .delta = "late" } },
                4 => .{ .text_end = .{ .id = "late" } },
                5 => .{ .finish = .{
                    .finish_reason = .{ .unified = .stop },
                    .usage = usage(1, 1),
                } },
                else => null,
            };
        }

        fn deinit(_: *anyopaque, _: std.Io) void {}
        const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };
    };

    fn languageModel(self: *InterruptingModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn p(_: *anyopaque) []const u8 {
        return "interrupt";
    }
    fn m(_: *anyopaque) []const u8 {
        return "interrupt-model";
    }
    fn u(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }
    fn g(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
        return error.UnsupportedFunctionalityError;
    }
    fn s(raw: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
        const self: *InterruptingModel = @ptrCast(@alignCast(raw));
        self.state = .{ .behavior = self.behavior, .delay_ms = self.delay_ms };
        return .{ .stream = .{ .ctx = &self.state, .vtable = &State.vtable } };
    }
    const vtable: provider.LanguageModel.VTable = .{
        .provider = p,
        .modelId = m,
        .urlIsSupported = u,
        .doGenerate = g,
        .doStream = s,
    };
};

const LifecycleRecorder = struct {
    abort_count: usize = 0,
    error_count: usize = 0,
    end_count: usize = 0,
    abort_steps: usize = 999,
    abort_reason: ?[]const u8 = null,
    telemetry_abort_count: usize = 0,
    telemetry_error_count: usize = 0,
    telemetry_end_count: usize = 0,

    fn onAbort(raw: ?*anyopaque, event: *const events.AbortEvent) anyerror!void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(raw.?));
        self.abort_count += 1;
        self.abort_steps = event.steps.len;
        self.abort_reason = event.reason;
    }

    fn onError(raw: ?*anyopaque, _: *const events.ErrorEvent) anyerror!void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(raw.?));
        self.error_count += 1;
    }

    fn onEnd(raw: ?*anyopaque, _: *const events.EndEvent) anyerror!void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(raw.?));
        self.end_count += 1;
    }

    fn telemetryAbort(raw: ?*anyopaque, _: *const events.AbortEvent, _: *const telemetry.Meta) anyerror!void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(raw.?));
        self.telemetry_abort_count += 1;
    }

    fn telemetryError(raw: ?*anyopaque, _: *const events.ErrorEvent, _: *const telemetry.Meta) anyerror!void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(raw.?));
        self.telemetry_error_count += 1;
    }

    fn telemetryEnd(raw: ?*anyopaque, _: *const events.EndEvent, _: *const telemetry.Meta) anyerror!void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(raw.?));
        self.telemetry_end_count += 1;
    }
};

test "streamText canonical text stream and lazy text accessor" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .response_metadata = .{ .id = "response-1", .timestamp_ms = 10, .model_id = "stream-model" } },
        .{ .text_start = .{ .id = "text-1" } },
        .{ .text_delta = .{ .id = "text-1", .delta = "Hello" } },
        .{ .text_delta = .{ .id = "text-1", .delta = ", world" } },
        .{ .text_end = .{ .id = "text-1" } },
        .{ .finish = .{
            .finish_reason = .{ .unified = .stop, .raw = "stop" },
            .usage = usage(3, 2),
        } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "hello" },
    });
    defer result.deinit(std.testing.io);

    try std.testing.expectEqualStrings("Hello, world", try result.text(std.testing.io));
    try std.testing.expectEqual(1, (try result.steps(std.testing.io)).len);
    try std.testing.expectEqual(3, (try result.totalUsage(std.testing.io)).input_tokens.total.?);
    try std.testing.expectEqual(null, try result.reasoningText(std.testing.io));
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, (try result.finishReason(std.testing.io)).unified);
    try std.testing.expectEqualStrings("stop", (try result.rawFinishReason(std.testing.io)).?);
    try std.testing.expectEqual(1, (try result.content(std.testing.io)).len);
    try std.testing.expectEqual(0, (try result.toolCalls(std.testing.io)).len);
    try std.testing.expectEqual(0, (try result.toolResults(std.testing.io)).len);
    try std.testing.expectEqual(0, (try result.warnings(std.testing.io)).len);
    try std.testing.expect((try result.request(std.testing.io)).messages != null);
    try std.testing.expectEqualStrings("response-1", (try result.response(std.testing.io)).id.?);
    try std.testing.expectEqual(null, try result.providerMetadata(std.testing.io));
    try std.testing.expectEqualStrings("Hello, world", (try result.output(std.testing.io)).text);
    try std.testing.expectEqual(1, (try result.responseMessages(std.testing.io)).len);
    try std.testing.expectEqualStrings("Hello, world", (try result.finalStep(std.testing.io)).text());

    var cursor = result.fullStream();
    var tags: std.ArrayList(std.meta.Tag(stream_text.TextStreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    while (try cursor.next(std.testing.io)) |part| try tags.append(std.testing.allocator, std.meta.activeTag(part));
    try std.testing.expectEqualSlices(
        std.meta.Tag(stream_text.TextStreamPart),
        &.{ .start, .start_step, .text_start, .text_delta, .text_delta, .text_end, .finish_step, .finish },
        tags.items,
    );
}

test "streamText converts doStream failure to an error part" {
    var model: FailingModel = .{};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "hello" },
        .on_error = .{ .callback = struct {
            fn ignore(_: ?*anyopaque, _: *const stream_text.StreamErrorEvent) anyerror!void {}
        }.ignore },
    });
    defer result.deinit(std.testing.io);
    try std.testing.expect((try result.next(std.testing.io)).? == .start);
    const error_part = (try result.next(std.testing.io)).?;
    try std.testing.expect(error_part == .err);
    try std.testing.expectEqual(error.APICallError, error_part.err.error_code.?);
    try std.testing.expectEqual(null, try result.next(std.testing.io));
    try std.testing.expectError(error.NoOutputGeneratedError, result.text(std.testing.io));

    var text_cursor = result.textStream();
    try std.testing.expectEqual(null, try text_cursor.next(std.testing.io));
}

test "streamText emits exact missing text id error and still completes the step" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_delta = .{ .id = "missing", .delta = "orphan" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 1) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .on_error = .{ .callback = struct {
            fn ignore(_: ?*anyopaque, _: *const stream_text.StreamErrorEvent) anyerror!void {}
        }.ignore },
    });
    defer result.deinit(std.testing.io);
    var found = false;
    while (try result.next(std.testing.io)) |part| if (part == .err) {
        found = true;
        try std.testing.expectEqualStrings("text part missing not found", part.err.error_value.string);
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(1, (try result.steps(std.testing.io)).len);
}

const PreliminaryTool = struct {
    calls: usize = 0,

    const OutputState = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?std.json.Value {
            const self: *OutputState = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .string = "preliminary" },
                1 => .{ .string = "final" },
                else => null,
            };
        }
    };

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        _: std.json.Value,
        _: @import("tool.zig").ToolExecutionOptions,
    ) anyerror!@import("tool.zig").ToolOutput {
        const self: *PreliminaryTool = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        const state = try arena.create(OutputState);
        state.* = .{};
        return .{ .stream = .{ .ctx = state, .vtable = &.{ .next = OutputState.next } } };
    }
};

test "streamText splices a second tool-loop step and excludes preliminary result from content" {
    const first = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .tool_call = .{ .tool_call_id = "call-1", .tool_name = "weather", .input = "{\"city\":\"Paris\"}" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .tool_calls }, .usage = usage(2, 1) } },
    };
    const second = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "text-2" } },
        .{ .text_delta = .{ .id = "text-2", .delta = "Sunny" } },
        .{ .text_end = .{ .id = "text-2" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(4, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{ &first, &second };
    var model: ScriptedModel = .{ .scripts = &scripts };
    var tool_state: PreliminaryTool = .{};
    const tool_api = @import("tool.zig");
    const provider_utils = @import("provider_utils");
    const tools = [_]tool_api.NamedTool{.{ .name = "weather", .tool = .{
        .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
        .execute = .{ .ctx = &tool_state, .execute_fn = PreliminaryTool.execute },
    } }};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "weather" },
        .tools = &tools,
        .stop_when = &.{@import("generate_text.zig").loopFinished()},
    });
    defer result.deinit(std.testing.io);

    var preliminary_index: ?usize = null;
    var final_index: ?usize = null;
    var second_step_index: ?usize = null;
    var index: usize = 0;
    while (try result.next(std.testing.io)) |part| : (index += 1) switch (part) {
        .tool_result => |value| if (value.preliminary) {
            preliminary_index = index;
        } else {
            final_index = index;
        },
        .start_step => if (second_step_index == null and index != 1) {
            second_step_index = index;
        },
        else => {},
    };
    try std.testing.expect(preliminary_index.? < final_index.?);
    try std.testing.expect(final_index.? < second_step_index.?);
    try std.testing.expectEqual(2, (try result.steps(std.testing.io)).len);
    try std.testing.expectEqualStrings("Sunny", try result.text(std.testing.io));
    try std.testing.expectEqual(1, (try result.toolResults(std.testing.io)).len);
    try std.testing.expectEqual(6, (try result.totalUsage(std.testing.io)).input_tokens.total.?);
    try std.testing.expectEqual(1, tool_state.calls);
    try std.testing.expect(model.saw_tool_result_prompt);
}

test "streamText replays an approved incoming tool call before step zero" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "continued" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 1) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var tool_state: PreliminaryTool = .{};
    const tool_api = @import("tool.zig");
    const provider_utils = @import("provider_utils");
    const tools = [_]tool_api.NamedTool{.{ .name = "weather", .tool = .{
        .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
        .execute = .{ .ctx = &tool_state, .execute_fn = PreliminaryTool.execute },
        .needs_approval = .yes,
    } }};
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
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .messages = &messages,
        .tools = &tools,
    });
    defer result.deinit(std.testing.io);

    try std.testing.expectEqualStrings("continued", try result.text(std.testing.io));
    try std.testing.expectEqual(1, tool_state.calls);
    try std.testing.expect(model.saw_tool_result_prompt);
    try std.testing.expectEqual(2, (try result.responseMessages(std.testing.io)).len);
    try std.testing.expect((try result.responseMessages(std.testing.io))[0] == .tool);
}

test "streamText keeps tool failures as data and continues the loop" {
    const first = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .tool_call = .{ .tool_call_id = "fail-1", .tool_name = "fail", .input = "{}" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .tool_calls }, .usage = usage(1, 1) } },
    };
    const second = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "recovered" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(2, 1) } },
    };
    const scripts = [_][]const provider.StreamPart{ &first, &second };
    var model: ScriptedModel = .{ .scripts = &scripts };
    const Executor = struct {
        fn run(
            _: ?*anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: std.json.Value,
            _: @import("tool.zig").ToolExecutionOptions,
        ) anyerror!@import("tool.zig").ToolOutput {
            return error.ExpectedToolFailure;
        }
    };
    const tools = [_]@import("tool.zig").NamedTool{.{ .name = "fail", .tool = .{
        .input_schema = @import("provider_utils").schemaFromType(struct {}),
        .execute = .{ .execute_fn = Executor.run },
    } }};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .tools = &tools,
        .stop_when = &.{generate_text.loopFinished()},
    });
    defer result.deinit(std.testing.io);

    var saw_error = false;
    while (try result.next(std.testing.io)) |part| switch (part) {
        .tool_error => |value| {
            saw_error = true;
            try std.testing.expectEqual(error.ExpectedToolFailure, value.error_code.?);
        },
        else => {},
    };
    const steps = try result.steps(std.testing.io);
    try std.testing.expect(saw_error);
    try std.testing.expectEqual(2, steps.len);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, steps[0].finish_reason.unified);
    try std.testing.expectEqualStrings("recovered", try result.text(std.testing.io));
    try std.testing.expect(model.saw_tool_result_prompt);
}

test "streamText Broadcast supports independent full and text cursors" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "A" } },
        .{ .text_delta = .{ .id = "t", .delta = "B" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
    });
    defer result.deinit(std.testing.io);
    var first = result.fullStream();
    var second = result.fullStream();
    var text = result.textStream();
    try result.consumeStream(std.testing.io);
    var first_count: usize = 0;
    var second_count: usize = 0;
    while (try first.next(std.testing.io)) |_| first_count += 1;
    while (try second.next(std.testing.io)) |_| second_count += 1;
    try std.testing.expectEqual(first_count, second_count);
    try std.testing.expectEqualStrings("A", (try text.next(std.testing.io)).?);
    try std.testing.expectEqualStrings("B", (try text.next(std.testing.io)).?);
    try std.testing.expectEqual(null, try text.next(std.testing.io));
}

test "streamText turns cancellation into abort without onError or onEnd" {
    var model: InterruptingModel = .{ .behavior = .cancel };
    var lifecycle: LifecycleRecorder = .{};
    const integrations = [_]telemetry.Telemetry{.{
        .ctx = &lifecycle,
        .vtable = &.{
            .onAbort = LifecycleRecorder.telemetryAbort,
            .onError = LifecycleRecorder.telemetryError,
            .onEnd = LifecycleRecorder.telemetryEnd,
        },
    }};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "cancel" },
        .callbacks = .{
            .on_abort = .{ .ctx = &lifecycle, .callback = LifecycleRecorder.onAbort },
            .on_error = .{ .ctx = &lifecycle, .callback = LifecycleRecorder.onError },
            .on_end = .{ .ctx = &lifecycle, .callback = LifecycleRecorder.onEnd },
        },
        .telemetry = .{ .integrations = &integrations },
    });
    defer result.deinit(std.testing.io);

    var tags: std.ArrayList(std.meta.Tag(stream_text.TextStreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    while (try result.next(std.testing.io)) |part| try tags.append(
        std.testing.allocator,
        std.meta.activeTag(part),
    );
    try std.testing.expectEqualSlices(
        std.meta.Tag(stream_text.TextStreamPart),
        &.{ .start, .start_step, .abort },
        tags.items,
    );
    try std.testing.expectEqual(1, lifecycle.abort_count);
    try std.testing.expectEqual(0, lifecycle.abort_steps);
    try std.testing.expectEqual(0, lifecycle.error_count);
    try std.testing.expectEqual(0, lifecycle.end_count);
    try std.testing.expectEqual(1, lifecycle.telemetry_abort_count);
    try std.testing.expectEqual(0, lifecycle.telemetry_error_count);
    try std.testing.expectEqual(0, lifecycle.telemetry_end_count);
    try std.testing.expectError(error.Canceled, result.text(std.testing.io));
}

test "streamText chunk timeout aborts the delayed provider pull" {
    var model: InterruptingModel = .{ .behavior = .delay, .delay_ms = 40 };
    var lifecycle: LifecycleRecorder = .{};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "timeout" },
        .timeout = .{ .granular = .{ .chunk_ms = 5 } },
        .on_abort = .{ .ctx = &lifecycle, .callback = LifecycleRecorder.onAbort },
    });
    defer result.deinit(std.testing.io);

    var saw_abort = false;
    while (try result.next(std.testing.io)) |part| switch (part) {
        .abort => |value| {
            saw_abort = true;
            try std.testing.expect(std.mem.startsWith(u8, value.reason.?, "Chunk timeout after 5ms"));
        },
        else => {},
    };
    try std.testing.expect(saw_abort);
    try std.testing.expectEqual(1, lifecycle.abort_count);
    try std.testing.expectEqualStrings("Chunk timeout after 5ms", lifecycle.abort_reason.?);
}

test "streamText onEnd still fires after a mid-stream error part" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "before error" } },
        .{ .err = .{ .error_value = .{ .string = "provider warning" } } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var lifecycle: LifecycleRecorder = .{};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .on_error = .{ .callback = struct {
            fn ignore(_: ?*anyopaque, _: *const stream_text.StreamErrorEvent) anyerror!void {}
        }.ignore },
        .callbacks = .{
            .on_error = .{ .ctx = &lifecycle, .callback = LifecycleRecorder.onError },
            .on_end = .{ .ctx = &lifecycle, .callback = LifecycleRecorder.onEnd },
        },
    });
    defer result.deinit(std.testing.io);

    try result.consumeStream(std.testing.io);
    try std.testing.expectEqualStrings("before error", try result.text(std.testing.io));
    try std.testing.expectEqual(1, lifecycle.error_count);
    try std.testing.expectEqual(1, lifecycle.end_count);
}

test "streamText zero-output stream records NoOutputGeneratedError" {
    const script = [_]provider.StreamPart{.{ .stream_start = .{ .warnings = &.{} } }};
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .on_error = .{ .callback = struct {
            fn ignore(_: ?*anyopaque, _: *const stream_text.StreamErrorEvent) anyerror!void {}
        }.ignore },
    });
    defer result.deinit(std.testing.io);

    try std.testing.expect((try result.next(std.testing.io)).? == .start);
    const failure = (try result.next(std.testing.io)).?;
    try std.testing.expect(failure == .err);
    try std.testing.expectEqual(error.NoOutputGeneratedError, failure.err.error_code.?);
    try std.testing.expectEqual(null, try result.next(std.testing.io));
    try std.testing.expectError(error.NoOutputGeneratedError, result.steps(std.testing.io));
}

const ChunkGate = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    count: usize = 0,
    tags: [32]std.meta.Tag(stream_text.TextStreamPart) = undefined,

    fn onChunk(raw: ?*anyopaque, event: *const stream_text.ChunkEvent) anyerror!void {
        const self: *ChunkGate = @ptrCast(@alignCast(raw.?));
        const index = self.count;
        self.tags[index] = std.meta.activeTag(event.chunk.*);
        self.count += 1;
        if (index == 0) {
            self.entered.set(self.io);
            try self.release.wait(self.io);
        }
    }
};

const PrefixTransform = struct {
    prefix: []const u8,

    fn transform(self: *const PrefixTransform) stream_text.StreamTransform {
        return .{ .ctx = @ptrCast(@constCast(self)), .wrap_fn = wrap };
    }

    fn wrap(
        raw: ?*anyopaque,
        arena: std.mem.Allocator,
        upstream: @import("stream/part_stream.zig").PartStream(stream_text.TextStreamPart),
        _: @import("stream/transform.zig").TransformOptions,
    ) anyerror!@import("stream/part_stream.zig").PartStream(stream_text.TextStreamPart) {
        const options: *const PrefixTransform = @ptrCast(@alignCast(raw.?));
        const state = try arena.create(State);
        state.* = .{
            .arena = arena,
            .upstream = upstream,
            .prefix = try arena.dupe(u8, options.prefix),
        };
        return .{ .ctx = state, .vtable = &State.vtable };
    }

    const State = struct {
        arena: std.mem.Allocator,
        upstream: @import("stream/part_stream.zig").PartStream(stream_text.TextStreamPart),
        prefix: []const u8,
        deinitialized: bool = false,

        const vtable: @import("stream/part_stream.zig").PartStream(stream_text.TextStreamPart).VTable = .{
            .next = next,
            .deinit = deinit,
        };

        fn next(raw: *anyopaque, io: std.Io) anyerror!?stream_text.TextStreamPart {
            const self: *State = @ptrCast(@alignCast(raw));
            const part = (try self.upstream.next(io)) orelse return null;
            return switch (part) {
                .text_delta => |value| .{ .text_delta = .{
                    .id = value.id,
                    .text = try std.mem.concat(self.arena, u8, &.{ self.prefix, value.text }),
                    .provider_metadata = value.provider_metadata,
                } },
                else => part,
            };
        }

        fn deinit(raw: *anyopaque, io: std.Io) void {
            const self: *State = @ptrCast(@alignCast(raw));
            if (self.deinitialized) return;
            self.deinitialized = true;
            self.upstream.deinit(io);
        }
    };
};

test "streamText awaits onChunk and reports every public part in order" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "A" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 1) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var gate: ChunkGate = .{ .io = std.testing.io };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .on_chunk = .{ .ctx = &gate, .callback = ChunkGate.onChunk },
    });
    defer result.deinit(std.testing.io);

    const Driver = struct {
        fn run(value: *stream_text.StreamTextResult, io: std.Io) anyerror!?stream_text.TextStreamPart {
            return value.next(io);
        }
    };
    var future = try std.testing.io.concurrent(Driver.run, .{ &result, std.testing.io });
    var awaited = false;
    defer {
        if (!awaited) _ = future.cancel(std.testing.io) catch {};
    }
    try gate.entered.wait(std.testing.io);
    try std.testing.expectEqual(0, model.call_count);
    gate.release.set(std.testing.io);
    const first = try future.await(std.testing.io);
    awaited = true;
    try std.testing.expect(first.? == .start);
    try result.consumeStream(std.testing.io);
    try std.testing.expectEqualSlices(
        std.meta.Tag(stream_text.TextStreamPart),
        &.{ .start, .start_step, .text_start, .text_delta, .text_end, .finish_step, .finish },
        gate.tags[0..gate.count],
    );
}

test "streamText finishStep exposes first-output and inter-chunk timing" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "A" } },
        .{ .text_delta = .{ .id = "t", .delta = "B" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
    });
    defer result.deinit(std.testing.io);

    var captured: ?@import("stream/parts.zig").FinishStep = null;
    while (try result.next(std.testing.io)) |part| switch (part) {
        .finish_step => |value| captured = value,
        else => {},
    };
    try std.testing.expect(captured.?.performance.time_to_first_output_ms != null);
    try std.testing.expect(captured.?.performance.time_between_output_chunks_ms != null);
    try std.testing.expect(captured.?.performance.step_time_ms >= 0);
}

test "streamText applies user transforms in declaration order" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "x" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 1) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    const first: PrefixTransform = .{ .prefix = "A" };
    const second: PrefixTransform = .{ .prefix = "B" };
    const transforms = [_]stream_text.StreamTransform{ first.transform(), second.transform() };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .transforms = &transforms,
    });
    defer result.deinit(std.testing.io);
    try std.testing.expectEqualStrings("BAx", try result.text(std.testing.io));
}

test "streamText filters raw and empty deltas and partial output follows first text id" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .raw = .{ .raw_value = .{ .string = "wire" } } },
        .{ .text_start = .{ .id = "first" } },
        .{ .text_delta = .{ .id = "first", .delta = "" } },
        .{ .text_delta = .{ .id = "first", .delta = "A" } },
        .{ .text_end = .{ .id = "first" } },
        .{ .text_start = .{ .id = "second" } },
        .{ .text_delta = .{ .id = "second", .delta = "B" } },
        .{ .text_end = .{ .id = "second" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .include_raw_chunks = true,
    });
    defer result.deinit(std.testing.io);

    try result.consumeStream(std.testing.io);
    var cursor = result.fullStream();
    var raw_count: usize = 0;
    var delta_count: usize = 0;
    while (try cursor.next(std.testing.io)) |part| switch (part) {
        .raw => raw_count += 1,
        .text_delta => delta_count += 1,
        else => {},
    };
    try std.testing.expectEqual(1, raw_count);
    try std.testing.expectEqual(2, delta_count);
    try std.testing.expectEqualStrings("AB", try result.text(std.testing.io));
    var partial = result.partialOutputStream();
    defer partial.deinit();
    try std.testing.expectEqualStrings("A", (try partial.next(std.testing.io)).?);
    try std.testing.expectEqual(null, try partial.next(std.testing.io));
}

test "smoothStream word chunks preserve metadata and flush trailing text" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "Hello,", .provider_metadata = .{ .string = "first" } } },
        .{ .text_delta = .{ .id = "t", .delta = " world!", .provider_metadata = .{ .string = "second" } } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    const transforms = [_]stream_text.StreamTransform{smooth_stream.smoothStream(.{ .delay_ms = null })};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .transforms = &transforms,
    });
    defer result.deinit(std.testing.io);

    var deltas: std.ArrayList([]const u8) = .empty;
    defer deltas.deinit(std.testing.allocator);
    var saw_metadata = false;
    while (try result.next(std.testing.io)) |part| switch (part) {
        .text_delta => |value| {
            try deltas.append(std.testing.allocator, value.text);
            if (value.provider_metadata) |metadata| saw_metadata = metadata == .string;
        },
        else => {},
    };
    try std.testing.expectEqual(2, deltas.items.len);
    try std.testing.expectEqualStrings("Hello, ", deltas.items[0]);
    try std.testing.expectEqualStrings("world!", deltas.items[1]);
    try std.testing.expect(saw_metadata);
}

test "smoothStream line chunks flush on a non-delta part and honor delay" {
    const script = [_]provider.StreamPart{
        .{ .stream_start = .{ .warnings = &.{} } },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "one\ntwo" } },
        .{ .reasoning_start = .{ .id = "r" } },
        .{ .reasoning_delta = .{ .id = "r", .delta = "why\nrest" } },
        .{ .reasoning_end = .{ .id = "r" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish = .{ .finish_reason = .{ .unified = .stop }, .usage = usage(1, 2) } },
    };
    const scripts = [_][]const provider.StreamPart{&script};
    var model: ScriptedModel = .{ .scripts = &scripts };
    const transforms = [_]stream_text.StreamTransform{smooth_stream.smoothStream(.{
        .delay_ms = 2,
        .chunking = .line,
    })};
    var result = try stream_text.streamText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "go" },
        .transforms = &transforms,
    });
    defer result.deinit(std.testing.io);

    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(std.testing.allocator);
    while (try result.next(std.testing.io)) |part| switch (part) {
        .text_delta => |value| try text.appendSlice(std.testing.allocator, value.text),
        .reasoning_delta => |value| try reasoning.appendSlice(std.testing.allocator, value.text),
        else => {},
    };
    const elapsed_ns = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started.nanoseconds;
    try std.testing.expectEqualStrings("one\ntwo", text.items);
    try std.testing.expectEqualStrings("why\nrest", reasoning.items);
    try std.testing.expect(elapsed_ns >= std.time.ns_per_ms);
}
