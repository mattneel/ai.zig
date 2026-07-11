//! Pull-stream interface for UI message chunks.

const std = @import("std");
const chunks = @import("ui_chunks.zig");

pub const ChunkStream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ctx: *anyopaque, io: std.Io) anyerror!?chunks.UIMessageChunk,
        deinit: ?*const fn (ctx: *anyopaque, io: std.Io) void = null,
        cancel: ?*const fn (ctx: *anyopaque, io: std.Io) void = null,
    };

    pub fn next(self: ChunkStream, io: std.Io) anyerror!?chunks.UIMessageChunk {
        return self.vtable.next(self.ctx, io);
    }

    pub fn deinit(self: ChunkStream, io: std.Io) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ctx, io);
    }

    pub fn cancel(self: ChunkStream, io: std.Io) void {
        if (self.vtable.cancel) |cancel_fn| cancel_fn(self.ctx, io);
    }
};

pub const Cleanup = struct {
    ctx: *anyopaque,
    deinit_fn: *const fn (ctx: *anyopaque, io: std.Io) void,

    pub fn deinit(self: Cleanup, io: std.Io) void {
        self.deinit_fn(self.ctx, io);
    }
};

/// Stack-friendly stream used by tests, scripted transports, and embeddings.
/// The caller retains the backing slice for the stream lifetime.
pub const SliceStream = struct {
    values: []const chunks.UIMessageChunk,
    index: usize = 0,

    pub fn stream(self: *SliceStream) ChunkStream {
        return .{ .ctx = self, .vtable = &.{ .next = next } };
    }

    fn next(raw: *anyopaque, _: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *SliceStream = @ptrCast(@alignCast(raw));
        if (self.index == self.values.len) return null;
        defer self.index += 1;
        return self.values[self.index];
    }
};

test "ChunkStream slice preserves order" {
    const values = [_]chunks.UIMessageChunk{
        .{ .start = .{} },
        .{ .finish = .{} },
    };
    var source: SliceStream = .{ .values = &values };
    const stream = source.stream();
    try std.testing.expect((try stream.next(std.testing.io)).? == .start);
    try std.testing.expect((try stream.next(std.testing.io)).? == .finish);
    try std.testing.expectEqual(null, try stream.next(std.testing.io));
}
