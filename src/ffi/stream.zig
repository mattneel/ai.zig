const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const options_api = @import("options.zig");
const providers = @import("providers.zig");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");
const wire_json = @import("wire_json.zig");

const Allocator = std.mem.Allocator;

pub const OwnerReleaseFn = *const fn (ctx: *anyopaque) void;

const Item = union(enum) {
    text: ai.TextStreamPart,
    object: ai.ObjectStreamPart,
    ui: ai.UIMessageChunk,
};

const Source = union(enum) {
    text: ai.StreamTextResult,
    object: ai.StreamObjectResult,
    ui: ai.ui.UIMessageChunkStream,

    fn next(self: *Source, io: std.Io) anyerror!?Item {
        return switch (self.*) {
            .text => |*value| if (try value.next(io)) |part| .{ .text = part } else null,
            .object => |*value| if (try value.next(io)) |part| .{ .object = part } else null,
            .ui => |*value| if (try value.next(io)) |part| .{ .ui = part } else null,
        };
    }

    fn deinit(self: *Source, io: std.Io) void {
        switch (self.*) {
            .text => |*value| value.deinit(io),
            .object => |*value| value.deinit(io),
            .ui => |*value| value.deinit(io),
        }
    }
};

pub const Stream = struct {
    runtime: *runtime_api.Runtime,
    owner_ctx: *anyopaque,
    owner_release: OwnerReleaseFn,
    request_arena_state: std.heap.ArenaAllocator,
    scratch_arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    last_error: runtime_api.ErrorStore,
    source: Source,
    queue_buffer: [16]Item,
    queue: std.Io.Queue(Item),
    future: std.Io.Future(void),
    next_mutex: std.atomic.Mutex,
    future_mutex: std.atomic.Mutex,
    terminal_status: std.atomic.Value(c_int),
    timed_out: std.atomic.Value(bool),

    fn producer(self: *Stream) void {
        const io = self.runtime.io();
        while (self.source.next(io)) |maybe_part| {
            const part = maybe_part orelse break;
            if (part == .text and part.text == .abort) {
                if (part.text.abort.reason) |reason| {
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
        self.future.cancel(self.runtime.io());
    }

    fn deinit(self: *Stream) void {
        const runtime = self.runtime;
        const allocator = runtime.allocator();
        self.cancelAndJoin();
        self.source.deinit(runtime.io());
        self.last_error.deinit(allocator);
        self.diagnostics.deinit();
        self.scratch_arena_state.deinit();
        self.request_arena_state.deinit();
        const owner_ctx = self.owner_ctx;
        const owner_release = self.owner_release;
        allocator.destroy(self);
        owner_release(owner_ctx);
        runtime.release();
    }

    fn cleanupBeforeStart(self: *Stream, has_source: bool) void {
        const runtime = self.runtime;
        const allocator = runtime.allocator();
        if (has_source) self.source.deinit(runtime.io());
        self.last_error.deinit(allocator);
        self.diagnostics.deinit();
        self.scratch_arena_state.deinit();
        self.request_arena_state.deinit();
        const owner_ctx = self.owner_ctx;
        const owner_release = self.owner_release;
        allocator.destroy(self);
        owner_release(owner_ctx);
        runtime.release();
    }
};

pub fn fromHandle(handle: *types.ai_stream) *Stream {
    return @ptrCast(@alignCast(handle));
}

fn modelRelease(raw: *anyopaque) void {
    const model: *providers.Model = @ptrCast(@alignCast(raw));
    model.release();
}

fn allocate(
    runtime: *runtime_api.Runtime,
    owner_ctx: *anyopaque,
    owner_release: OwnerReleaseFn,
) Allocator.Error!*Stream {
    const allocator = runtime.allocator();
    const self = try allocator.create(Stream);
    runtime.retain();
    self.runtime = runtime;
    self.owner_ctx = owner_ctx;
    self.owner_release = owner_release;
    self.request_arena_state = .init(allocator);
    self.scratch_arena_state = .init(allocator);
    self.diagnostics = .init(allocator);
    self.last_error = .{};
    self.queue = .init(&self.queue_buffer);
    self.next_mutex = .unlocked;
    self.future_mutex = .unlocked;
    self.terminal_status = .init(@intFromEnum(types.Status.ok));
    self.timed_out = .init(false);
    return self;
}

pub fn startPrepared(
    self: *Stream,
    source: Source,
    out: [*c]?*types.ai_stream,
) types.Status {
    self.source = source;
    self.future = self.runtime.io().concurrent(Stream.producer, .{self}) catch |err| {
        const status = self.runtime.fail(err, null);
        self.cleanupBeforeStart(true);
        return status;
    };
    out.* = @ptrCast(self);
    return .ok;
}

pub fn allocateForOwner(
    runtime: *runtime_api.Runtime,
    owner_ctx: *anyopaque,
    owner_release: OwnerReleaseFn,
) Allocator.Error!*Stream {
    return allocate(runtime, owner_ctx, owner_release);
}

pub fn discardBeforeStart(self: *Stream) void {
    self.cleanupBeforeStart(false);
}

pub fn startTextPrepared(
    self: *Stream,
    result: ai.StreamTextResult,
    out: [*c]?*types.ai_stream,
) types.Status {
    return startPrepared(self, .{ .text = result }, out);
}

pub fn startObjectPrepared(
    self: *Stream,
    result: ai.StreamObjectResult,
    out: [*c]?*types.ai_stream,
) types.Status {
    return startPrepared(self, .{ .object = result }, out);
}

pub fn startUiPrepared(
    self: *Stream,
    result: ai.ui.UIMessageChunkStream,
    out: [*c]?*types.ai_stream,
) types.Status {
    return startPrepared(self, .{ .ui = result }, out);
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
    return startTextCall(
        runtime_handle,
        model_handle,
        options_json,
        options_json_len,
        tools,
        tools_len,
        false,
        out,
    );
}

pub export fn ai_stream_text_ui(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    tools: [*c]const types.ai_tool,
    tools_len: usize,
    out: [*c]?*types.ai_stream,
) types.Status {
    return startTextCall(
        runtime_handle,
        model_handle,
        options_json,
        options_json_len,
        tools,
        tools_len,
        true,
        out,
    );
}

fn startTextCall(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    tools: [*c]const types.ai_tool,
    tools_len: usize,
    as_ui: bool,
    out: [*c]?*types.ai_stream,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.modelFromHandle(value) else return runtime.invalid("model is required", "model");
    if (model.owner.runtime != runtime) {
        return runtime.invalid("model belongs to a different runtime", "model");
    }

    model.retain();
    const self = allocate(runtime, model, modelRelease) catch |err| {
        model.release();
        return runtime.fail(err, null);
    };
    const request_arena = self.request_arena_state.allocator();
    const parsed = options_api.parse(
        request_arena,
        options_json,
        options_json_len,
        &self.diagnostics,
    ) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        self.cleanupBeforeStart(false);
        return status;
    };
    const named_tools = options_api.parseTools(
        request_arena,
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
    const result = ai.streamText(
        runtime.io(),
        runtime.allocator(),
        parsed.stream(model.interface, named_tools, stop_when, &self.diagnostics),
    ) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        self.cleanupBeforeStart(false);
        return status;
    };
    if (as_ui) {
        const ui_stream = ai.ui.to_ui_chunks.fromStreamTextResult(
            runtime.allocator(),
            runtime.io(),
            result,
            .{},
        ) catch |err| {
            var owned_result = result;
            owned_result.deinit(runtime.io());
            const status = runtime.fail(err, &self.diagnostics);
            self.cleanupBeforeStart(false);
            return status;
        };
        return startUiPrepared(self, ui_stream, out);
    }
    return startTextPrepared(self, result, out);
}

pub export fn ai_stream_next(handle: ?*types.ai_stream, out: [*c]types.ai_part) types.Status {
    types.validateOutputStruct(types.ai_part, out) catch return .invalid_argument;
    const requested_size = out[0].struct_size;
    types.writeOutputStruct(types.ai_part, out, emptyPart(requested_size));
    const self = if (handle) |value| fromHandle(value) else return .invalid_argument;
    lockAtomic(&self.next_mutex);
    defer self.next_mutex.unlock();

    self.scratch_arena_state.deinit();
    self.scratch_arena_state = .init(self.runtime.allocator());
    const item = self.queue.getOne(self.runtime.io()) catch |err| switch (err) {
        error.Closed => {
            const status: types.Status = @enumFromInt(self.terminal_status.load(.acquire));
            return if (status == .ok) .stream_done else status;
        },
        error.Canceled => return .canceled,
    };
    const scratch = self.scratch_arena_state.allocator();
    const encoded = encodeItem(scratch, item) catch |err| {
        const status = types.statusFromError(err);
        self.last_error.set(self.runtime.allocator(), status, err, null);
        return status;
    };
    types.writeOutputStruct(types.ai_part, out, .{
        .struct_size = requested_size,
        .type = encoded.type,
        .json_ptr = encoded.json.ptr,
        .json_len = encoded.json.len,
        .text_ptr = if (encoded.text.len == 0) null else encoded.text.ptr,
        .text_len = encoded.text.len,
    });
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
    const value = types.readStruct(types.ai_part, part) catch return .invalid_argument;
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

const EncodedItem = struct {
    type: types.PartType,
    json: []const u8,
    text: []const u8,
};

const ObjectErrorDocument = struct {
    type: []const u8,
    error_value: std.json.Value,
    error_code: ?[]const u8,

    pub const wire_field_names = .{
        .{ "error_value", "error" },
    };
};

const ObjectFinishDocument = struct {
    type: []const u8,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    response: ai.generate_text_types.ResponseMetadata,
    provider_metadata: ?provider.ProviderMetadata,
};

fn encodeItem(arena: Allocator, item: Item) !EncodedItem {
    return switch (item) {
        .text => |part| .{
            .type = wire_json.partType(part),
            .json = try wire_json.stringifyPart(arena, part),
            .text = if (wire_json.partText(part)) |value| try arena.dupe(u8, value) else "",
        },
        .object => |part| encodeObjectPart(arena, part),
        .ui => |part| .{
            .type = .ui_message,
            .json = try provider.wire.stringifyAlloc(arena, part),
            .text = switch (part) {
                .text_delta => |value| try arena.dupe(u8, value.delta),
                else => "",
            },
        },
    };
}

fn encodeObjectPart(arena: Allocator, part: ai.ObjectStreamPart) !EncodedItem {
    return switch (part) {
        .object => |value| .{
            .type = .object,
            .json = try provider.wire.stringifyAlloc(arena, .{ .type = @as([]const u8, "object"), .object = value }),
            .text = "",
        },
        .text_delta => |value| .{
            .type = .text_delta,
            .json = try provider.wire.stringifyAlloc(arena, .{ .type = @as([]const u8, "text-delta"), .text_delta = value }),
            .text = try arena.dupe(u8, value),
        },
        .err => |value| .{
            .type = .err,
            .json = try provider.wire.stringifyAlloc(arena, ObjectErrorDocument{
                .type = @as([]const u8, "error"),
                .error_value = value.error_value,
                .error_code = if (value.err) |err| @errorName(err) else null,
            }),
            .text = "",
        },
        .finish => |value| .{
            .type = .finish,
            .json = try provider.wire.stringifyAlloc(arena, ObjectFinishDocument{
                .type = "finish",
                .finish_reason = value.finish_reason,
                .usage = value.usage,
                .response = value.response,
                .provider_metadata = value.provider_metadata,
            }),
            .text = "",
        },
    };
}

fn emptyPart(struct_size: usize) types.ai_part {
    return .{
        .struct_size = struct_size,
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
