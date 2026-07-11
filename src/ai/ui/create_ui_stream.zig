//! Concurrent writer-composition primitive for UI message streams.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const chunks = @import("ui_chunks.zig");
const messages = @import("ui_messages.zig");
const process = @import("process_ui_stream.zig");
const finish = @import("handle_ui_stream_finish.zig");
const stream_api = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;

pub const ErrorMapper = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, arena: Allocator, err: anyerror) anyerror![]const u8,

    pub fn call(self: ErrorMapper, arena: Allocator, err: anyerror) anyerror![]const u8 {
        return self.call_fn(self.ctx, arena, err);
    }

    pub const masked: ErrorMapper = .{ .call_fn = maskedError };
};

pub const Writer = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, io: std.Io, chunk: chunks.UIMessageChunk) anyerror!void,
    merge_fn: *const fn (ctx: *anyopaque, io: std.Io, stream: stream_api.ChunkStream) anyerror!void,
    on_error: ErrorMapper,

    pub fn write(self: Writer, io: std.Io, chunk: chunks.UIMessageChunk) anyerror!void {
        return self.write_fn(self.ctx, io, chunk);
    }

    pub fn merge(self: Writer, io: std.Io, stream: stream_api.ChunkStream) anyerror!void {
        return self.merge_fn(self.ctx, io, stream);
    }
};

pub const Execute = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, io: std.Io, writer: Writer) anyerror!void,

    pub fn call(self: Execute, io: std.Io, writer: Writer) anyerror!void {
        return self.call_fn(self.ctx, io, writer);
    }
};

pub const Options = struct {
    execute: Execute,
    on_error: ErrorMapper = .masked,
    queue_capacity: usize = 32,
    message_id: ?[]const u8 = null,
    original_messages: ?[]const messages.UIMessage = null,
    on_step_end: ?finish.OnStepEnd = null,
    on_end: ?finish.OnEnd = null,
    on_callback_error: ?process.OnError = null,
    diag: ?*provider.Diagnostics = null,
};

pub fn createUIMessageStream(
    io: std.Io,
    gpa: Allocator,
    options: Options,
) !stream_api.ChunkStream {
    if (options.queue_capacity == 0) return error.InvalidArgumentError;
    const state = try gpa.create(State);
    const queue_buffer = try gpa.alloc(chunks.UIMessageChunk, options.queue_capacity);
    errdefer gpa.free(queue_buffer);
    state.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .queue_buffer = queue_buffer,
        .queue = .init(queue_buffer),
        .execute = options.execute,
        .error_mapper = options.on_error,
    };
    errdefer {
        state.arena_state.deinit();
        gpa.destroy(state);
    }
    state.writer = .{
        .ctx = state,
        .write_fn = State.write,
        .merge_fn = State.merge,
        .on_error = options.on_error,
    };

    try state.group.concurrent(io, State.runExecute, .{ state, io });
    const raw_stream: stream_api.ChunkStream = .{ .ctx = state, .vtable = &State.vtable };
    errdefer raw_stream.deinit(io);

    var generated_buffer: [64]u8 = undefined;
    const generated_id = if (options.message_id) |id| id else blk: {
        var generator = try provider_utils.IdGenerator.initFromIo(io, .{}, options.diag);
        break :blk generator.next(&generated_buffer);
    };
    return finish.handleUIMessageStreamFinish(gpa, raw_stream, .{
        .message_id = generated_id,
        .original_messages = options.original_messages,
        .on_step_end = options.on_step_end,
        .on_end = options.on_end,
        .on_error = options.on_callback_error,
        .diag = options.diag,
    });
}

const State = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    queue_buffer: []chunks.UIMessageChunk,
    queue: std.Io.Queue(chunks.UIMessageChunk),
    group: std.Io.Group = .init,
    execute: Execute,
    error_mapper: ErrorMapper,
    writer: Writer = undefined,
    producers: std.atomic.Value(usize) = .init(1),
    canceled: std.atomic.Value(bool) = .init(false),
    deinitialized: bool = false,

    const vtable: stream_api.ChunkStream.VTable = .{
        .next = next,
        .deinit = deinit,
        .cancel = cancel,
    };

    fn runExecute(self: *State, io: std.Io) std.Io.Cancelable!void {
        defer self.producerDone(io);
        self.execute.call(io, self.writer) catch |err| {
            self.emitError(io, err) catch |emit_err| switch (emit_err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        };
    }

    fn write(raw: *anyopaque, io: std.Io, chunk: chunks.UIMessageChunk) anyerror!void {
        const self: *State = @ptrCast(@alignCast(raw));
        const owned = try chunks.cloneChunk(self.arena_state.allocator(), chunk);
        self.queue.putOne(io, owned) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => |canceled| return canceled,
        };
    }

    fn merge(raw: *anyopaque, io: std.Io, stream: stream_api.ChunkStream) anyerror!void {
        const self: *State = @ptrCast(@alignCast(raw));
        _ = self.producers.fetchAdd(1, .acq_rel);
        self.group.concurrent(io, pump, .{ self, io, stream }) catch |err| {
            stream.deinit(io);
            self.emitError(io, err) catch {};
            self.producerDone(io);
            return err;
        };
    }

    fn pump(self: *State, io: std.Io, stream: stream_api.ChunkStream) std.Io.Cancelable!void {
        defer stream.deinit(io);
        defer self.producerDone(io);
        while (true) {
            const chunk = stream.next(io) catch |err| {
                if (!(err == error.Canceled and self.canceled.load(.acquire))) {
                    self.emitError(io, err) catch |emit_err| switch (emit_err) {
                        error.Canceled => return error.Canceled,
                        else => {},
                    };
                }
                if (err == error.Canceled) return error.Canceled;
                return;
            };
            const value = chunk orelse return;
            self.writer.write(io, value) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    self.emitError(io, err) catch |emit_err| switch (emit_err) {
                        error.Canceled => return error.Canceled,
                        else => {},
                    };
                    return;
                },
            };
        }
    }

    fn emitError(self: *State, io: std.Io, err: anyerror) anyerror!void {
        const error_text = self.error_mapper.call(self.arena_state.allocator(), err) catch "An error occurred.";
        try self.writer.write(io, .{ .err = .{ .error_text = error_text } });
    }

    fn producerDone(self: *State, io: std.Io) void {
        const previous = self.producers.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous == 1) self.queue.close(io);
    }

    fn next(raw: *anyopaque, io: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *State = @ptrCast(@alignCast(raw));
        return self.queue.getOne(io) catch |err| switch (err) {
            error.Closed => null,
            error.Canceled => |canceled| return canceled,
        };
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.canceled.swap(true, .acq_rel)) return;
        self.queue.close(io);
        self.group.cancel(io);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.canceled.store(true, .release);
        self.queue.close(io);
        self.group.cancel(io);
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.free(self.queue_buffer);
        gpa.destroy(self);
    }
};

fn maskedError(_: ?*anyopaque, _: Allocator, _: anyerror) anyerror![]const u8 {
    return "An error occurred.";
}

test "createUIMessageStream interleaves merges, drains a late merge, and masks errors" {
    const io = std.testing.io;

    const Delayed = struct {
        values: []const chunks.UIMessageChunk,
        index: usize = 0,
        delay_ms: i64,

        fn stream(self: *@This()) stream_api.ChunkStream {
            return .{ .ctx = self, .vtable = &.{ .next = next } };
        }

        fn next(raw: *anyopaque, task_io: std.Io) anyerror!?chunks.UIMessageChunk {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == self.values.len) return null;
            if (self.delay_ms != 0) try task_io.sleep(.fromMilliseconds(self.delay_ms), .awake);
            defer self.index += 1;
            return self.values[self.index];
        }
    };
    const Failing = struct {
        fn stream(self: *@This()) stream_api.ChunkStream {
            return .{ .ctx = self, .vtable = &.{ .next = next } };
        }
        fn next(_: *anyopaque, _: std.Io) anyerror!?chunks.UIMessageChunk {
            return error.PrivateFailure;
        }
    };
    const Late = struct {
        writer: *Writer,
        late: stream_api.ChunkStream,
        emitted: bool = false,

        fn stream(self: *@This()) stream_api.ChunkStream {
            return .{ .ctx = self, .vtable = &.{ .next = next } };
        }
        fn next(raw: *anyopaque, task_io: std.Io) anyerror!?chunks.UIMessageChunk {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.emitted) return null;
            self.emitted = true;
            try self.writer.merge(task_io, self.late);
            return .{ .text_delta = .{ .id = "late", .delta = "parent" } };
        }
    };
    const Fixture = struct {
        first: Delayed,
        second: Delayed,
        late_child: stream_api.SliceStream,
        late: Late = undefined,
        failing: Failing = .{},
        writer_storage: Writer = undefined,

        fn execute(raw: ?*anyopaque, task_io: std.Io, writer: Writer) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.writer_storage = writer;
            self.late = .{ .writer = &self.writer_storage, .late = self.late_child.stream() };
            try writer.merge(task_io, self.first.stream());
            try writer.merge(task_io, self.second.stream());
            try writer.merge(task_io, self.late.stream());
            try writer.merge(task_io, self.failing.stream());
        }
    };

    var fixture: Fixture = .{
        .first = .{ .values = &.{
            .{ .text_delta = .{ .id = "a", .delta = "a1" } },
            .{ .text_delta = .{ .id = "a", .delta = "a2" } },
        }, .delay_ms = 1 },
        .second = .{ .values = &.{
            .{ .text_delta = .{ .id = "b", .delta = "b1" } },
            .{ .text_delta = .{ .id = "b", .delta = "b2" } },
        }, .delay_ms = 1 },
        .late_child = .{ .values = &.{.{ .text_delta = .{ .id = "late", .delta = "child" } }} },
    };
    const stream = try createUIMessageStream(io, std.testing.allocator, .{
        .execute = .{ .ctx = &fixture, .call_fn = Fixture.execute },
        .message_id = "m",
        .queue_capacity = 4,
    });
    defer stream.deinit(io);

    var seen_a: usize = 0;
    var seen_b: usize = 0;
    var seen_late: usize = 0;
    var seen_error: usize = 0;
    while (try stream.next(io)) |chunk| switch (chunk) {
        .text_delta => |delta| {
            if (std.mem.eql(u8, delta.id, "a")) seen_a += 1;
            if (std.mem.eql(u8, delta.id, "b")) seen_b += 1;
            if (std.mem.eql(u8, delta.id, "late")) seen_late += 1;
        },
        .err => |value| {
            seen_error += 1;
            try std.testing.expectEqualStrings("An error occurred.", value.error_text);
        },
        else => {},
    };
    try std.testing.expectEqual(2, seen_a);
    try std.testing.expectEqual(2, seen_b);
    try std.testing.expectEqual(2, seen_late);
    try std.testing.expectEqual(1, seen_error);
}
