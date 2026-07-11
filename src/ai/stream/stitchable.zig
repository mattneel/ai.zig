//! FIFO stream splicing with one concurrent pump.
//!
//! Normal mode owns one `std.Io.Group` task that drains child streams into the
//! bounded outer queue, preserving end-to-end backpressure. When
//! `Io.concurrent` reports `error.ConcurrencyUnavailable`, the stitchable
//! enters a documented degraded mode: `next` pumps children inline. In that
//! mode the inner queue still bounds pending child handles, but the outer queue
//! is bypassed so construction cannot deadlock by running a pump inline.

const std = @import("std");
const stream_api = @import("part_stream.zig");

pub fn ChildStream(comptime T: type) type {
    return stream_api.PartStream(T);
}

pub fn Stitchable(comptime T: type) type {
    return struct {
        const Self = @This();
        const Child = ChildStream(T);
        const Mode = enum { concurrent, inline_mode };

        outer: std.Io.Queue(T),
        inner: std.Io.Queue(*Child),
        driver_group: std.Io.Group = .init,
        mode: Mode = .concurrent,
        current_inline: ?*Child = null,
        error_mutex: std.Io.Mutex = .init,
        first_child_error: ?anyerror = null,
        child_error_returned: bool = false,
        terminated: std.atomic.Value(bool) = .init(false),

        /// Initializes in-place so the driver always receives a stable self
        /// pointer. The caller owns both queue buffers for the full lifetime.
        pub fn init(self: *Self, io: std.Io, outer_buffer: []T, inner_buffer: []*Child) void {
            self.* = .{
                .outer = .init(outer_buffer),
                .inner = .init(inner_buffer),
            };
            self.driver_group.concurrent(io, drive, .{ self, io }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => self.mode = .inline_mode,
            };
        }

        /// Initializes the explicit pull-only mode. No producer task is
        /// spawned, so downstream awaited callbacks apply backpressure all the
        /// way to the active child. `streamText` uses this mode.
        pub fn initInline(self: *Self, outer_buffer: []T, inner_buffer: []*Child) void {
            self.* = .{
                .outer = .init(outer_buffer),
                .inner = .init(inner_buffer),
                .mode = .inline_mode,
            };
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            self.terminate(io);
            self.* = undefined;
        }

        pub fn addStream(self: *Self, io: std.Io, child: *Child) (std.Io.QueueClosedError || std.Io.Cancelable)!void {
            return self.inner.putOne(io, child);
        }

        /// Graceful drain-then-close: no more children can be added, while the
        /// active and already queued children remain readable in FIFO order.
        pub fn close(self: *Self, io: std.Io) void {
            self.inner.close(io);
        }

        /// Immediately closes consumer output and cancels the driver/current
        /// child. Pending child handles are deinitialized after the driver has
        /// stopped. Idempotent.
        pub fn terminate(self: *Self, io: std.Io) void {
            if (self.terminated.swap(true, .acq_rel)) return;
            self.outer.close(io);
            self.inner.close(io);
            switch (self.mode) {
                .concurrent => self.driver_group.cancel(io),
                .inline_mode => {
                    if (self.current_inline) |child| {
                        child.deinit(io);
                        self.current_inline = null;
                    }
                    self.drainPending(io);
                },
            }
        }

        pub fn next(self: *Self, io: std.Io) anyerror!?T {
            return switch (self.mode) {
                .concurrent => self.nextConcurrent(io),
                .inline_mode => self.nextInline(io),
            };
        }

        fn nextConcurrent(self: *Self, io: std.Io) anyerror!?T {
            return self.outer.getOne(io) catch |err| switch (err) {
                error.Canceled => |canceled| return canceled,
                error.Closed => if (self.takeChildError(io)) |child_error|
                    return child_error
                else
                    null,
            };
        }

        fn nextInline(self: *Self, io: std.Io) anyerror!?T {
            while (true) {
                if (self.current_inline) |child| {
                    const item = child.next(io) catch |err| {
                        child.deinit(io);
                        self.current_inline = null;
                        self.storeChildError(io, err);
                        self.inner.close(io);
                        self.drainPending(io);
                        self.outer.close(io);
                        return self.takeChildError(io).?;
                    };
                    if (item) |value| return value;
                    child.deinit(io);
                    self.current_inline = null;
                    continue;
                }

                self.current_inline = self.inner.getOne(io) catch |err| switch (err) {
                    error.Canceled => |canceled| return canceled,
                    error.Closed => {
                        self.outer.close(io);
                        if (self.takeChildError(io)) |child_error| return child_error;
                        return null;
                    },
                };
            }
        }

        fn drive(self: *Self, io: std.Io) std.Io.Cancelable!void {
            defer self.outer.close(io);
            defer self.drainPending(io);

            while (true) {
                const child = self.inner.getOne(io) catch |err| switch (err) {
                    error.Closed => return,
                    error.Canceled => |canceled| return canceled,
                };
                defer child.deinit(io);

                while (true) {
                    const item = child.next(io) catch |err| {
                        if (err != error.Canceled or !self.terminated.load(.acquire)) {
                            self.storeChildError(io, err);
                            self.inner.close(io);
                        }
                        if (err == error.Canceled) return error.Canceled;
                        return;
                    };
                    const value = item orelse break;
                    self.outer.putOne(io, value) catch |err| switch (err) {
                        error.Closed => return,
                        error.Canceled => |canceled| return canceled,
                    };
                }
            }
        }

        fn storeChildError(self: *Self, io: std.Io, err: anyerror) void {
            self.error_mutex.lockUncancelable(io);
            defer self.error_mutex.unlock(io);
            if (self.first_child_error == null) self.first_child_error = err;
        }

        fn takeChildError(self: *Self, io: std.Io) ?anyerror {
            self.error_mutex.lockUncancelable(io);
            defer self.error_mutex.unlock(io);
            if (self.child_error_returned) return null;
            const err = self.first_child_error orelse return null;
            self.child_error_returned = true;
            return err;
        }

        fn drainPending(self: *Self, io: std.Io) void {
            while (self.inner.getOneUncancelable(io)) |child| {
                child.deinit(io);
            } else |err| switch (err) {
                error.Closed => {},
            }
        }
    };
}

fn SliceChild(comptime T: type) type {
    return struct {
        values: []const T,
        index: usize = 0,

        fn stream(self: *@This()) ChildStream(T) {
            return .{ .ctx = self, .vtable = &.{ .next = next } };
        }

        fn next(raw: *anyopaque, _: std.Io) anyerror!?T {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == self.values.len) return null;
            defer self.index += 1;
            return self.values[self.index];
        }
    };
}

test "Stitchable splices children in order and close drains" {
    const io = std.testing.io;
    var outer_buffer: [2]u8 = undefined;
    var inner_buffer: [2]*ChildStream(u8) = undefined;
    var stitchable: Stitchable(u8) = undefined;
    stitchable.init(io, &outer_buffer, &inner_buffer);
    defer stitchable.deinit(io);

    var first_state: SliceChild(u8) = .{ .values = &.{ 1, 2, 3 } };
    var second_state: SliceChild(u8) = .{ .values = &.{ 4, 5 } };
    var first = first_state.stream();
    var second = second_state.stream();
    try stitchable.addStream(io, &first);
    // The first child can already be pumping/backpressured while the second is
    // appended to the bounded child queue.
    try stitchable.addStream(io, &second);
    stitchable.close(io);

    var received: [5]u8 = undefined;
    for (&received) |*slot| slot.* = (try stitchable.next(io)).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, &received);
    try std.testing.expectEqual(null, try stitchable.next(io));
}

test "Stitchable terminate cuts a blocked child immediately" {
    const io = std.testing.io;
    const Blocking = struct {
        index: usize = 0,
        entered: std.Io.Event = .unset,
        blocker: std.Io.Event = .unset,

        fn next(raw: *anyopaque, task_io: std.Io) anyerror!?u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == 0) {
                self.index = 1;
                return 7;
            }
            self.entered.set(task_io);
            try self.blocker.wait(task_io);
            return null;
        }
    };

    var outer_buffer: [1]u8 = undefined;
    var inner_buffer: [1]*ChildStream(u8) = undefined;
    var stitchable: Stitchable(u8) = undefined;
    stitchable.init(io, &outer_buffer, &inner_buffer);
    defer stitchable.deinit(io);
    var state: Blocking = .{};
    var child: ChildStream(u8) = .{ .ctx = &state, .vtable = &.{ .next = Blocking.next } };
    try stitchable.addStream(io, &child);
    try std.testing.expectEqual(7, (try stitchable.next(io)).?);

    // Give the driver a cancellation point by blocking it in the next pull.
    try state.entered.wait(io);
    stitchable.terminate(io);
    try std.testing.expectEqual(null, try stitchable.next(io));
}

test "Stitchable child error surfaces after buffered output" {
    const io = std.testing.io;
    const Failing = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => 42,
                else => error.ChildFailed,
            };
        }
    };

    var outer_buffer: [2]u8 = undefined;
    var inner_buffer: [1]*ChildStream(u8) = undefined;
    var stitchable: Stitchable(u8) = undefined;
    stitchable.init(io, &outer_buffer, &inner_buffer);
    defer stitchable.deinit(io);
    var state: Failing = .{};
    var child: ChildStream(u8) = .{ .ctx = &state, .vtable = &.{ .next = Failing.next } };
    try stitchable.addStream(io, &child);
    stitchable.close(io);

    try std.testing.expectEqual(42, (try stitchable.next(io)).?);
    try std.testing.expectError(error.ChildFailed, stitchable.next(io));
    try std.testing.expectEqual(null, try stitchable.next(io));
}

test "Stitchable blocked consumer propagates cancellation" {
    const io = std.testing.io;
    var outer_buffer: [1]u8 = undefined;
    var inner_buffer: [1]*ChildStream(u8) = undefined;
    var stitchable: Stitchable(u8) = undefined;
    stitchable.init(io, &outer_buffer, &inner_buffer);
    defer stitchable.deinit(io);
    var entered: std.Io.Event = .unset;

    const Waiter = struct {
        fn run(target: *Stitchable(u8), task_io: std.Io, ready: *std.Io.Event) anyerror!?u8 {
            ready.set(task_io);
            return target.next(task_io);
        }
    };
    var future = try io.concurrent(Waiter.run, .{ &stitchable, io, &entered });
    try entered.wait(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
}

test "Stitchable inline degradation preserves ordering" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var outer_buffer: [1]u8 = undefined;
    var inner_buffer: [2]*ChildStream(u8) = undefined;
    var stitchable: Stitchable(u8) = undefined;
    stitchable.init(io, &outer_buffer, &inner_buffer);
    defer stitchable.deinit(io);

    var first_state: SliceChild(u8) = .{ .values = &.{ 1, 2 } };
    var second_state: SliceChild(u8) = .{ .values = &.{3} };
    var first = first_state.stream();
    var second = second_state.stream();
    try stitchable.addStream(io, &first);
    try stitchable.addStream(io, &second);
    stitchable.close(io);
    try std.testing.expectEqual(1, (try stitchable.next(io)).?);
    try std.testing.expectEqual(2, (try stitchable.next(io)).?);
    try std.testing.expectEqual(3, (try stitchable.next(io)).?);
    try std.testing.expectEqual(null, try stitchable.next(io));
}

test "Stitchable stress pumps 1000 parts across three children" {
    const io = std.testing.io;
    var values: [1000]u16 = undefined;
    for (&values, 0..) |*value, index| value.* = @intCast(index);
    var outer_buffer: [17]u16 = undefined;
    var inner_buffer: [3]*ChildStream(u16) = undefined;
    var stitchable: Stitchable(u16) = undefined;
    stitchable.init(io, &outer_buffer, &inner_buffer);
    defer stitchable.deinit(io);

    var first_state: SliceChild(u16) = .{ .values = values[0..333] };
    var second_state: SliceChild(u16) = .{ .values = values[333..777] };
    var third_state: SliceChild(u16) = .{ .values = values[777..] };
    var first = first_state.stream();
    var second = second_state.stream();
    var third = third_state.stream();
    try stitchable.addStream(io, &first);
    try stitchable.addStream(io, &second);
    try stitchable.addStream(io, &third);
    stitchable.close(io);

    for (0..1000) |expected| try std.testing.expectEqual(expected, (try stitchable.next(io)).?);
    try std.testing.expectEqual(null, try stitchable.next(io));
}
