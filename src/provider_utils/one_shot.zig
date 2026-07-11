const std = @import("std");

pub fn OneShot(comptime T: type) type {
    return struct {
        const Self = @This();

        event: std.Io.Event = .unset,
        value: T = undefined,

        pub fn resolve(self: *Self, io: std.Io, value: T) void {
            std.debug.assert(!self.event.isSet());
            self.value = value;
            self.event.set(io);
        }

        pub fn wait(self: *Self, io: std.Io) std.Io.Cancelable!T {
            try self.event.wait(io);
            return self.value;
        }

        pub fn tryGet(self: *const Self) ?T {
            if (!self.event.isSet()) return null;
            return self.value;
        }
    };
}

test "OneShot resolve before wait" {
    const io = std.testing.io;
    var one_shot: OneShot(u32) = .{};

    try std.testing.expectEqual(null, one_shot.tryGet());
    one_shot.resolve(io, 42);
    try std.testing.expectEqual(42, one_shot.tryGet().?);
    try std.testing.expectEqual(42, try one_shot.wait(io));
}

test "OneShot wait from a task then resolve" {
    const io = std.testing.io;
    var one_shot: OneShot(u32) = .{};

    const Waiter = struct {
        fn run(cell: *OneShot(u32), task_io: std.Io) std.Io.Cancelable!u32 {
            return cell.wait(task_io);
        }
    };

    var waiter = io.async(Waiter.run, .{ &one_shot, io });
    defer _ = waiter.cancel(io) catch {};

    one_shot.resolve(io, 77);
    try std.testing.expectEqual(77, try waiter.await(io));
}

test "OneShot releases multiple waiters" {
    const io = std.testing.io;
    var one_shot: OneShot(u32) = .{};

    const Waiter = struct {
        fn run(cell: *OneShot(u32), task_io: std.Io, result: *u32) !void {
            result.* = try cell.wait(task_io);
        }
    };

    var first_result: u32 = 0;
    var second_result: u32 = 0;
    const first = try std.Thread.spawn(.{}, Waiter.run, .{ &one_shot, io, &first_result });
    const second = std.Thread.spawn(.{}, Waiter.run, .{ &one_shot, io, &second_result }) catch |err| {
        one_shot.resolve(io, 91);
        first.join();
        return err;
    };

    one_shot.resolve(io, 91);
    first.join();
    second.join();
    try std.testing.expectEqual(91, first_result);
    try std.testing.expectEqual(91, second_result);
}

test "OneShot supports error union values" {
    const io = std.testing.io;
    var one_shot: OneShot(anyerror!u32) = .{};

    one_shot.resolve(io, error.ExpectedFailure);
    const value = try one_shot.wait(io);
    try std.testing.expectError(error.ExpectedFailure, value);
}
