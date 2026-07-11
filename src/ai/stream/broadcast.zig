//! Append-only broadcast log used for stream fan-out and step accumulation.
//!
//! The caller supplies the allocator, normally the step arena. Entries are
//! intentionally retained for the entire broadcast lifetime: memory usage is
//! proportional to the fastest-to-slowest consumer lag, and `streamText`
//! already retains every part to assemble `StepResult` values.

const std = @import("std");

pub fn Broadcast(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        log: std.ArrayList(T) = .empty,
        closed: bool = false,

        pub const Cursor = struct {
            broadcast: *Self,
            position: usize = 0,

            /// Blocks until the cursor's next entry exists or the broadcast is
            /// closed. `Condition.wait` is the cancellation point; it
            /// reacquires the mutex before `error.Canceled` is propagated.
            pub fn next(self: *Cursor, io: std.Io) std.Io.Cancelable!?T {
                try self.broadcast.mutex.lock(io);
                defer self.broadcast.mutex.unlock(io);

                while (self.position >= self.broadcast.log.items.len and !self.broadcast.closed) {
                    try self.broadcast.condition.wait(io, &self.broadcast.mutex);
                }
                if (self.position >= self.broadcast.log.items.len) return null;

                const item = self.broadcast.log.items[self.position];
                self.position += 1;
                return item;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.log.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn append(self: *Self, io: std.Io, item: T) (std.mem.Allocator.Error || std.Io.Cancelable)!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            std.debug.assert(!self.closed);
            try self.log.append(self.allocator, item);
            self.condition.broadcast(io);
        }

        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return;
            self.closed = true;
            self.condition.broadcast(io);
        }

        /// Every cursor starts at zero, including cursors created after
        /// appends or closure, so late consumers replay the complete log.
        pub fn cursor(self: *Self) Cursor {
            return .{ .broadcast = self };
        }

        /// Returns the retained log. Call only after producer synchronization
        /// (normally after `close`) or while the caller otherwise excludes
        /// concurrent `append`; the returned slice is invalidated by growth.
        pub fn snapshot(self: *const Self) []const T {
            return self.log.items;
        }
    };
}

test "Broadcast cursors at different paces observe identical sequences" {
    const io = std.testing.io;
    var broadcast = Broadcast(u32).init(std.testing.allocator);
    defer broadcast.deinit();
    var fast = broadcast.cursor();
    var slow = broadcast.cursor();

    try broadcast.append(io, 10);
    try broadcast.append(io, 20);
    try std.testing.expectEqual(10, (try fast.next(io)).?);
    try std.testing.expectEqual(20, (try fast.next(io)).?);
    try std.testing.expectEqual(10, (try slow.next(io)).?);
    try broadcast.append(io, 30);
    broadcast.close(io);

    try std.testing.expectEqual(30, (try fast.next(io)).?);
    try std.testing.expectEqual(null, try fast.next(io));
    try std.testing.expectEqual(20, (try slow.next(io)).?);
    try std.testing.expectEqual(30, (try slow.next(io)).?);
    try std.testing.expectEqual(null, try slow.next(io));
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, broadcast.snapshot());
}

test "Broadcast cursor created late replays from zero" {
    const io = std.testing.io;
    var broadcast = Broadcast([]const u8).init(std.testing.allocator);
    defer broadcast.deinit();
    try broadcast.append(io, "first");
    try broadcast.append(io, "second");
    broadcast.close(io);

    var late = broadcast.cursor();
    try std.testing.expectEqualStrings("first", (try late.next(io)).?);
    try std.testing.expectEqualStrings("second", (try late.next(io)).?);
    try std.testing.expectEqual(null, try late.next(io));
}

test "Broadcast blocked cursor propagates cancellation" {
    const io = std.testing.io;
    var broadcast = Broadcast(u8).init(std.testing.allocator);
    defer broadcast.deinit();
    var cursor = broadcast.cursor();
    var entered: std.Io.Event = .unset;

    const Waiter = struct {
        fn run(target: *Broadcast(u8).Cursor, task_io: std.Io, ready: *std.Io.Event) std.Io.Cancelable!?u8 {
            ready.set(task_io);
            return target.next(task_io);
        }
    };

    var future = try io.concurrent(Waiter.run, .{ &cursor, io, &entered });
    try entered.wait(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
}
