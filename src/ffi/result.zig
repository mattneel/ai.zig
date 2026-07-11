const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const options_api = @import("options.zig");
const providers = @import("providers.zig");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");
const wire_json = @import("wire_json.zig");

const Allocator = std.mem.Allocator;

pub const StepDocument = struct {
    step_number: usize,
    model: ai.generate_text_types.ModelInfo,
    text: []const u8,
    content: []const std.json.Value,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    warnings: []const provider.Warning,
    response_messages: []const ai.ModelMessage,
};

pub const ResultDocument = struct {
    text: []const u8,
    content: []const std.json.Value,
    steps: []const StepDocument,
    usage: provider.Usage,
    finish_reason: provider.FinishReason,
    response_messages: []const ai.ModelMessage,
};

pub const Result = struct {
    runtime: *runtime_api.Runtime,
    value: ai.GenerateTextResult,
    json: []u8,

    fn deinit(self: *Result) void {
        const runtime = self.runtime;
        const allocator = runtime.allocator();
        std.heap.c_allocator.free(self.json);
        self.value.deinit();
        allocator.destroy(self);
        runtime.release();
    }
};

const TimeoutTracker = struct {
    timed_out: std.atomic.Value(bool) = .init(false),

    fn onAbort(raw: ?*anyopaque, event: *const ai.events.AbortEvent) anyerror!void {
        const self: *TimeoutTracker = @ptrCast(@alignCast(raw.?));
        if (event.reason) |reason| {
            if (std.mem.eql(u8, reason, "timeout")) self.timed_out.store(true, .release);
        }
    }
};

pub fn fromHandle(handle: *types.ai_result) *Result {
    return @ptrCast(@alignCast(handle));
}

pub export fn ai_generate_text(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    tools: [*c]const types.ai_tool,
    tools_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.modelFromHandle(value) else return runtime.invalid("model is required", "model");
    if (model.owner.runtime != runtime) {
        return runtime.invalid("model belongs to a different runtime", "model");
    }

    model.retain();
    defer model.release();
    const allocator = runtime.allocator();
    var call_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer call_arena_state.deinit();
    const call_arena = call_arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();

    const parsed = options_api.parse(
        call_arena,
        options_json,
        options_json_len,
        &diagnostics,
    ) catch |err| return runtime.fail(err, &diagnostics);
    const named_tools = options_api.parseTools(call_arena, tools, tools_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    var stop_storage: [1]ai.StopCondition = undefined;
    const stop_when = options_api.stopConditions(parsed, &stop_storage);
    var timeout_tracker: TimeoutTracker = .{};
    var generate_options = parsed.generate(model.interface, named_tools, stop_when, &diagnostics);
    generate_options.callbacks.on_abort = .{
        .ctx = &timeout_tracker,
        .callback = TimeoutTracker.onAbort,
    };
    var generated = ai.generateText(
        runtime.io(),
        allocator,
        generate_options,
    ) catch |err| {
        if (err == error.Canceled and timeout_tracker.timed_out.load(.acquire)) {
            return runtime.fail(error.Timeout, &diagnostics);
        }
        return runtime.fail(err, &diagnostics);
    };

    const json = encodeResult(&generated) catch |err| {
        const status = runtime.fail(err, null);
        generated.deinit();
        return status;
    };
    const result = allocator.create(Result) catch |err| {
        const status = runtime.fail(err, null);
        std.heap.c_allocator.free(json);
        generated.deinit();
        return status;
    };
    runtime.retain();
    result.* = .{ .runtime = runtime, .value = generated, .json = json };
    out.* = @ptrCast(result);
    return .ok;
}

pub export fn ai_result_json(handle: ?*const types.ai_result) types.ai_string {
    const value = handle orelse return types.empty_string;
    const result: *const Result = @ptrCast(@alignCast(value));
    return types.string(result.json);
}

pub export fn ai_result_text(handle: ?*const types.ai_result) types.ai_string {
    const value = handle orelse return types.empty_string;
    const result: *const Result = @ptrCast(@alignCast(value));
    return types.string(result.value.text());
}

pub export fn ai_result_finish_reason(handle: ?*const types.ai_result) types.ai_string {
    const value = handle orelse return types.empty_string;
    const result: *const Result = @ptrCast(@alignCast(value));
    return types.string(wire_json.finishReasonName(result.value.finishReason()));
}

pub export fn ai_result_total_tokens(handle: ?*const types.ai_result) u64 {
    const value = handle orelse return 0;
    const result: *const Result = @ptrCast(@alignCast(value));
    const usage = result.value.usage();
    return (usage.input_tokens.total orelse 0) +| (usage.output_tokens.total orelse 0);
}

pub export fn ai_result_destroy(handle: ?*types.ai_result) void {
    const value = handle orelse return;
    fromHandle(value).deinit();
}

fn encodeResult(result: *ai.GenerateTextResult) ![]u8 {
    const arena = result.arena_state.allocator();
    const steps = try arena.alloc(StepDocument, result.steps.len);
    for (result.steps, steps) |step, *destination| {
        destination.* = .{
            .step_number = step.step_number,
            .model = step.model,
            .text = step.text(),
            .content = try wire_json.contentValues(arena, step.content),
            .finish_reason = step.finish_reason,
            .usage = step.usage,
            .warnings = step.warnings,
            .response_messages = step.response.messages,
        };
    }
    const document: ResultDocument = .{
        .text = result.text(),
        .content = try wire_json.contentValues(arena, result.content()),
        .steps = steps,
        .usage = result.usage(),
        .finish_reason = result.finishReason(),
        .response_messages = result.responseMessages(),
    };
    return provider.wire.stringifyAlloc(std.heap.c_allocator, document);
}

test "result document round-trips response messages through provider wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]ai.ModelMessage{.{ .assistant = .{ .content = .{ .text = "done" } } }};
    const document: ResultDocument = .{
        .text = "done",
        .content = &.{},
        .steps = &.{},
        .usage = .{ .input_tokens = .{}, .output_tokens = .{} },
        .finish_reason = .{ .unified = .stop },
        .response_messages = &messages,
    };
    const json = try provider.wire.stringifyAlloc(arena, document);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const parsed_messages = try provider.wire.parse(
        []const ai.ModelMessage,
        arena,
        value.object.get("responseMessages").?,
    );
    try std.testing.expectEqualStrings("done", parsed_messages[0].assistant.content.text);
}
