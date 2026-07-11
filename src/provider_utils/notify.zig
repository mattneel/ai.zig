const std = @import("std");

pub fn Callback(comptime Event: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        func: *const fn (ctx: ?*anyopaque, event: Event) anyerror!void,
    };
}

pub fn notify(
    io: std.Io,
    event: anytype,
    callbacks: []const ?Callback(@TypeOf(event)),
) std.Io.Cancelable!void {
    const Event = @TypeOf(event);
    const Runner = struct {
        fn run(callback: Callback(Event), callback_event: Event) void {
            callback.func(callback.ctx, callback_event) catch {};
        }
    };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (callbacks) |maybe_callback| {
        const callback = maybe_callback orelse continue;
        group.async(io, Runner.run, .{ callback, event });
    }
    try group.await(io);
}

test "notify invokes every callback" {
    const Context = struct {
        calls: std.atomic.Value(usize) = .init(0),

        fn callback(raw: ?*anyopaque, event: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqual(9, event);
            _ = self.calls.fetchAdd(1, .monotonic);
        }
    };

    var context: Context = .{};
    const callbacks = [_]?Callback(u32){
        .{ .ctx = &context, .func = Context.callback },
        .{ .ctx = &context, .func = Context.callback },
        .{ .ctx = &context, .func = Context.callback },
    };

    try notify(std.testing.io, @as(u32, 9), &callbacks);
    try std.testing.expectEqual(3, context.calls.load(.monotonic));
}

test "notify swallows callback errors and skips null entries" {
    const Context = struct {
        calls: std.atomic.Value(usize) = .init(0),

        fn succeeds(raw: ?*anyopaque, _: u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.calls.fetchAdd(1, .monotonic);
        }

        fn fails(raw: ?*anyopaque, _: u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.calls.fetchAdd(1, .monotonic);
            return error.CallbackFailed;
        }
    };

    var context: Context = .{};
    const callbacks = [_]?Callback(u8){
        .{ .ctx = &context, .func = Context.fails },
        null,
        .{ .ctx = &context, .func = Context.succeeds },
    };

    try notify(std.testing.io, @as(u8, 1), &callbacks);
    try std.testing.expectEqual(2, context.calls.load(.monotonic));
}
