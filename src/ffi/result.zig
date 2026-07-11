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

pub const BlobSource = struct {
    bytes: []const u8,
    media_type: []const u8,
};

const Blob = struct {
    bytes: []const u8,
    media_type: []const u8,
};

/// Common immutable result representation used by text, object, embedding,
/// agent, and media calls. Core results are copied into this arena before
/// their Zig-side arenas are released.
pub const Result = struct {
    runtime: *runtime_api.Runtime,
    arena_state: std.heap.ArenaAllocator,
    json: []const u8,
    text: []const u8,
    finish_reason: []const u8,
    total_tokens: u64,
    blobs: []const Blob,

    fn deinit(self: *Result) void {
        const runtime = self.runtime;
        const allocator = runtime.allocator();
        self.arena_state.deinit();
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

pub fn create(
    runtime: *runtime_api.Runtime,
    document: anytype,
    text: []const u8,
    finish_reason: []const u8,
    total_tokens: u64,
    blob_sources: []const BlobSource,
) !*Result {
    const allocator = runtime.allocator();
    const self = try allocator.create(Result);
    errdefer allocator.destroy(self);
    self.runtime = runtime;
    self.arena_state = .init(allocator);
    errdefer self.arena_state.deinit();
    const arena = self.arena_state.allocator();
    self.json = try provider.wire.stringifyAlloc(arena, document);
    self.text = try arena.dupe(u8, text);
    self.finish_reason = try arena.dupe(u8, finish_reason);
    self.total_tokens = total_tokens;
    const blobs = try arena.alloc(Blob, blob_sources.len);
    for (blob_sources, blobs) |source, *destination| destination.* = .{
        .bytes = try arena.dupe(u8, source.bytes),
        .media_type = try arena.dupe(u8, source.media_type),
    };
    self.blobs = blobs;
    runtime.retain();
    return self;
}

pub fn createFromGenerateText(
    runtime: *runtime_api.Runtime,
    generated: *ai.GenerateTextResult,
) !*Result {
    const document = try encodeResultDocument(generated);
    const usage = generated.usage();
    return create(
        runtime,
        document,
        generated.text(),
        wire_json.finishReasonName(generated.finishReason()),
        (usage.input_tokens.total orelse 0) +| (usage.output_tokens.total orelse 0),
        &.{},
    );
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
    defer generated.deinit();

    const result = createFromGenerateText(runtime, &generated) catch |err| return runtime.fail(err, null);
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
    return types.string(result.text);
}

pub export fn ai_result_finish_reason(handle: ?*const types.ai_result) types.ai_string {
    const value = handle orelse return types.empty_string;
    const result: *const Result = @ptrCast(@alignCast(value));
    return types.string(result.finish_reason);
}

pub export fn ai_result_total_tokens(handle: ?*const types.ai_result) u64 {
    const value = handle orelse return 0;
    const result: *const Result = @ptrCast(@alignCast(value));
    return result.total_tokens;
}

pub export fn ai_result_blob_count(handle: ?*const types.ai_result) usize {
    const value = handle orelse return 0;
    const result: *const Result = @ptrCast(@alignCast(value));
    return result.blobs.len;
}

pub export fn ai_result_blob_media_type(
    handle: ?*const types.ai_result,
    index: usize,
) types.ai_string {
    const value = handle orelse return types.empty_string;
    const result: *const Result = @ptrCast(@alignCast(value));
    if (index >= result.blobs.len) return types.empty_string;
    return types.string(result.blobs[index].media_type);
}

pub export fn ai_result_blob(
    handle: ?*const types.ai_result,
    index: usize,
    out: [*c]types.ai_buffer,
) types.Status {
    types.validateOutputStruct(types.ai_buffer, out) catch return .invalid_argument;
    const requested_size = out[0].struct_size;
    var output: types.ai_buffer = .{ .struct_size = requested_size, .ptr = null, .len = 0 };
    types.writeOutputStruct(types.ai_buffer, out, output);
    const value = handle orelse return .invalid_argument;
    const result: *const Result = @ptrCast(@alignCast(value));
    if (index >= result.blobs.len) return .invalid_argument;
    const source = result.blobs[index].bytes;
    if (source.len == 0) return .ok;
    const copy = std.heap.c_allocator.alloc(u8, source.len) catch return .out_of_memory;
    @memcpy(copy, source);
    output.ptr = copy.ptr;
    output.len = copy.len;
    types.writeOutputStruct(types.ai_buffer, out, output);
    return .ok;
}

pub export fn ai_result_destroy(handle: ?*types.ai_result) void {
    const value = handle orelse return;
    fromHandle(value).deinit();
}

fn encodeResultDocument(result: *ai.GenerateTextResult) !ResultDocument {
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
    return .{
        .text = result.text(),
        .content = try wire_json.contentValues(arena, result.content()),
        .steps = steps,
        .usage = result.usage(),
        .finish_reason = result.finishReason(),
        .response_messages = result.responseMessages(),
    };
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
