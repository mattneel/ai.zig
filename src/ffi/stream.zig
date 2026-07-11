const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const options_api = @import("options.zig");
const providers = @import("providers.zig");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");
const wire_json = @import("wire_json.zig");

const Allocator = std.mem.Allocator;

pub const Stream = struct {
    runtime: *runtime_api.Runtime,
    model: *providers.Model,
    options_arena_state: std.heap.ArenaAllocator,
    scratch_arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    last_error: runtime_api.ErrorStore,
    result: ai.StreamTextResult,
    queue_buffer: [16]ai.TextStreamPart,
    queue: std.Io.Queue(ai.TextStreamPart),
    future: std.Io.Future(void),
    next_mutex: std.atomic.Mutex,
    future_mutex: std.atomic.Mutex,
    terminal_status: std.atomic.Value(c_int),
    cancel_requested: std.atomic.Value(bool),
    timed_out: std.atomic.Value(bool),

    fn producer(self: *Stream) void {
        const io = self.runtime.io();
        while (self.result.next(io)) |maybe_part| {
            const part = maybe_part orelse break;
            if (part == .abort) {
                if (part.abort.reason) |reason| {
                    if (std.mem.indexOf(u8, reason, "timeout") != null) {
                        self.timed_out.store(true, .release);
                    }
                }
            }
            self.queue.putOne(io, part) catch |err| {
                self.finishWithError(err);
                self.queue.close(io);
                return;
            };
        } else |err| {
            self.finishWithError(err);
            self.queue.close(io);
            return;
        }
        self.terminal_status.store(@intFromEnum(types.Status.ok), .release);
        self.queue.close(io);
    }

    fn finishWithError(self: *Stream, err: anyerror) void {
        const reported_error = if (err == error.Canceled and self.timed_out.load(.acquire))
            error.Timeout
        else
            err;
        const status = types.statusFromError(reported_error);
        self.last_error.set(
            self.runtime.allocator(),
            status,
            reported_error,
            if (self.diagnostics.available) &self.diagnostics else null,
        );
        self.terminal_status.store(@intFromEnum(status), .release);
    }

    fn cancelAndJoin(self: *Stream) void {
        lockAtomic(&self.future_mutex);
        defer self.future_mutex.unlock();
        self.cancel_requested.store(true, .release);
        self.future.cancel(self.runtime.io());
    }

    fn deinit(self: *Stream) void {
        const runtime = self.runtime;
        const model = self.model;
        const allocator = runtime.allocator();
        self.cancelAndJoin();
        self.result.deinit(runtime.io());
        self.last_error.deinit(allocator);
        self.diagnostics.deinit();
        self.scratch_arena_state.deinit();
        self.options_arena_state.deinit();
        allocator.destroy(self);
        model.release();
        runtime.release();
    }

    fn cleanupBeforeStart(self: *Stream, has_result: bool) void {
        const runtime = self.runtime;
        const model = self.model;
        const allocator = runtime.allocator();
        if (has_result) self.result.deinit(runtime.io());
        self.last_error.deinit(allocator);
        self.diagnostics.deinit();
        self.scratch_arena_state.deinit();
        self.options_arena_state.deinit();
        allocator.destroy(self);
        model.release();
        runtime.release();
    }
};

pub fn fromHandle(handle: *types.ai_stream) *Stream {
    return @ptrCast(@alignCast(handle));
}

pub export fn ai_stream_text(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    tools: [*c]const types.ai_tool,
    tools_len: usize,
    out: [*c]?*types.ai_stream,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.modelFromHandle(value) else return runtime.invalid("model is required", "model");
    if (model.owner.runtime != runtime) {
        return runtime.invalid("model belongs to a different runtime", "model");
    }

    const allocator = runtime.allocator();
    const self = allocator.create(Stream) catch |err| return runtime.fail(err, null);
    runtime.retain();
    model.retain();
    self.runtime = runtime;
    self.model = model;
    self.options_arena_state = .init(allocator);
    self.scratch_arena_state = .init(allocator);
    self.diagnostics = .init(allocator);
    self.last_error = .{};
    self.queue = .init(&self.queue_buffer);
    self.next_mutex = .unlocked;
    self.future_mutex = .unlocked;
    self.terminal_status = .init(@intFromEnum(types.Status.ok));
    self.cancel_requested = .init(false);
    self.timed_out = .init(false);

    const options_arena = self.options_arena_state.allocator();
    const parsed = options_api.parse(
        options_arena,
        options_json,
        options_json_len,
        &self.diagnostics,
    ) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        self.cleanupBeforeStart(false);
        return status;
    };
    const named_tools = options_api.parseTools(
        options_arena,
        tools,
        tools_len,
        &self.diagnostics,
    ) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        self.cleanupBeforeStart(false);
        return status;
    };
    var stop_storage: [1]ai.StopCondition = undefined;
    const stop_when = options_api.stopConditions(parsed, &stop_storage);
    self.result = ai.streamText(
        runtime.io(),
        allocator,
        parsed.stream(model.interface, named_tools, stop_when, &self.diagnostics),
    ) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        self.cleanupBeforeStart(false);
        return status;
    };
    self.future = runtime.io().concurrent(Stream.producer, .{self}) catch |err| {
        const status = runtime.fail(err, null);
        self.cleanupBeforeStart(true);
        return status;
    };
    out.* = @ptrCast(self);
    return .ok;
}

pub export fn ai_stream_next(handle: ?*types.ai_stream, out: [*c]types.ai_part) types.Status {
    if (out == null) return .invalid_argument;
    out.* = emptyPart();
    const self = if (handle) |value| fromHandle(value) else return .invalid_argument;
    lockAtomic(&self.next_mutex);
    defer self.next_mutex.unlock();

    self.scratch_arena_state.deinit();
    self.scratch_arena_state = .init(self.runtime.allocator());
    const part = self.queue.getOne(self.runtime.io()) catch |err| switch (err) {
        error.Closed => {
            const status: types.Status = @enumFromInt(self.terminal_status.load(.acquire));
            return if (status == .ok) .stream_done else status;
        },
        error.Canceled => return .canceled,
    };
    const scratch = self.scratch_arena_state.allocator();
    const json = wire_json.stringifyPart(scratch, part) catch |err| {
        const status = types.statusFromError(err);
        self.last_error.set(self.runtime.allocator(), status, err, null);
        return status;
    };
    const text = if (wire_json.partText(part)) |value|
        scratch.dupe(u8, value) catch |err| {
            const status = types.statusFromError(err);
            self.last_error.set(self.runtime.allocator(), status, err, null);
            return status;
        }
    else
        "";
    out.* = .{
        .type = wire_json.partType(part),
        .json_ptr = json.ptr,
        .json_len = json.len,
        .text_ptr = if (text.len == 0) null else text.ptr,
        .text_len = text.len,
    };
    return .ok;
}

pub export fn ai_stream_cancel(handle: ?*types.ai_stream) types.Status {
    const self = if (handle) |value| fromHandle(value) else return .invalid_argument;
    self.cancelAndJoin();
    return .ok;
}

pub export fn ai_stream_last_error(handle: ?*const types.ai_stream) types.ai_string {
    const value = handle orelse return types.empty_string;
    const self: *Stream = @ptrCast(@alignCast(@constCast(value)));
    return self.last_error.get();
}

pub export fn ai_part_clone(part: [*c]const types.ai_part, out_json: [*c]types.ai_string) types.Status {
    if (out_json == null) return .invalid_argument;
    out_json.* = types.empty_string;
    if (part == null) return .invalid_argument;
    const value = part[0];
    if (value.json_len == 0) return .ok;
    if (value.json_ptr == null) return .invalid_argument;
    const copy = std.heap.c_allocator.alloc(u8, value.json_len) catch return .out_of_memory;
    @memcpy(copy, value.json_ptr[0..value.json_len]);
    out_json.* = types.string(copy);
    return .ok;
}

pub export fn ai_stream_destroy(handle: ?*types.ai_stream) void {
    const value = handle orelse return;
    fromHandle(value).deinit();
}

fn emptyPart() types.ai_part {
    return .{
        .type = .raw,
        .json_ptr = null,
        .json_len = 0,
        .text_ptr = null,
        .text_len = 0,
    };
}

fn lockAtomic(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
