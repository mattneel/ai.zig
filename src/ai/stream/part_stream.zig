const std = @import("std");

/// Pull-stream fat pointer shared by the Phase 5 pipeline stages.
///
/// Implementations own their upstream stream. `deinit` is idempotent by
/// contract, and must be called before the arena backing the implementation is
/// released. Values are copied by value; slices retain their producing arena's
/// lifetime.
pub fn PartStream(comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            next: *const fn (ctx: *anyopaque, io: std.Io) anyerror!?T,
            deinit: ?*const fn (ctx: *anyopaque, io: std.Io) void = null,
        };

        pub fn next(self: Self, io: std.Io) anyerror!?T {
            return self.vtable.next(self.ctx, io);
        }

        pub fn deinit(self: Self, io: std.Io) void {
            if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ctx, io);
        }
    };
}

test "PartStream preserves pull order" {
    const State = struct {
        index: usize = 0,

        fn next(raw: *anyopaque, _: std.Io) anyerror!?u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => 4,
                1 => 9,
                else => null,
            };
        }
    };

    var state: State = .{};
    const stream: PartStream(u8) = .{ .ctx = &state, .vtable = &.{ .next = State.next } };
    try std.testing.expectEqual(4, (try stream.next(std.testing.io)).?);
    try std.testing.expectEqual(9, (try stream.next(std.testing.io)).?);
    try std.testing.expectEqual(null, try stream.next(std.testing.io));
}
