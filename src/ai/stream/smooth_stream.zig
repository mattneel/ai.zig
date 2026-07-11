//! `smoothStream` text/reasoning pacing transform.

const std = @import("std");
const part_stream = @import("part_stream.zig");
const parts = @import("parts.zig");
const transform_api = @import("transform.zig");

const Part = parts.TextStreamPart;

pub const Chunking = enum { word, line };

pub const Options = struct {
    delay_ms: ?u64 = 10,
    chunking: Chunking = .word,
};

/// Returns a transform fat pointer. The compact integer context makes the
/// returned value self-contained without hidden allocation or caller-owned
/// option storage.
pub fn smoothStream(options: Options) transform_api.StreamTransform {
    const max_delay = (std.math.maxInt(usize) >> 1) - 1;
    const delay_code: usize = if (options.delay_ms) |delay|
        @min(delay, max_delay) + 1
    else
        0;
    const encoded = (delay_code << 1) | @intFromEnum(options.chunking);
    return .{
        .ctx = @ptrFromInt(encoded + 1),
        .wrap_fn = wrap,
    };
}

fn wrap(
    raw: ?*anyopaque,
    arena: std.mem.Allocator,
    upstream: part_stream.PartStream(Part),
    _: transform_api.TransformOptions,
) anyerror!part_stream.PartStream(Part) {
    const encoded = @intFromPtr(raw.?) - 1;
    const delay_code = encoded >> 1;
    const state = try arena.create(State);
    state.* = .{
        .arena = arena,
        .upstream = upstream,
        .delay_ms = if (delay_code == 0) null else delay_code - 1,
        .chunking = @enumFromInt(encoded & 1),
    };
    return .{ .ctx = state, .vtable = &State.vtable };
}

const State = struct {
    arena: std.mem.Allocator,
    upstream: part_stream.PartStream(Part),
    delay_ms: ?u64,
    chunking: Chunking,
    buffer: std.ArrayList(u8) = .empty,
    id: []const u8 = "",
    kind: ?enum { text_delta, reasoning_delta } = null,
    provider_metadata: ?@import("provider").ProviderMetadata = null,
    held_input: ?Part = null,
    pending_passthrough: ?Part = null,
    sleep_pending: bool = false,
    deinitialized: bool = false,

    const vtable: part_stream.PartStream(Part).VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?Part {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.sleep_pending) {
            self.sleep_pending = false;
            if (self.delay_ms) |milliseconds| {
                const value: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
                try io.sleep(.fromMilliseconds(value), .awake);
            }
        }
        if (self.pending_passthrough) |part| {
            self.pending_passthrough = null;
            return part;
        }

        while (true) {
            if (self.detectChunk()) |length| return try self.takeChunk(length, true);

            const part = if (self.held_input) |held| blk: {
                self.held_input = null;
                break :blk held;
            } else (try self.upstream.next(io)) orelse {
                if (self.buffer.items.len != 0) return try self.takeChunk(self.buffer.items.len, false);
                return null;
            };

            const incoming_kind: ?@TypeOf(self.kind.?) = switch (part) {
                .text_delta => .text_delta,
                .reasoning_delta => .reasoning_delta,
                else => null,
            };
            if (incoming_kind == null) {
                if (self.buffer.items.len != 0) {
                    self.pending_passthrough = part;
                    return try self.takeChunk(self.buffer.items.len, false);
                }
                return part;
            }

            const incoming_id = switch (part) {
                .text_delta => |value| value.id,
                .reasoning_delta => |value| value.id,
                else => unreachable,
            };
            if (self.buffer.items.len != 0 and
                (self.kind.? != incoming_kind.? or !std.mem.eql(u8, self.id, incoming_id)))
            {
                self.held_input = part;
                return try self.takeChunk(self.buffer.items.len, false);
            }

            const delta = switch (part) {
                .text_delta => |value| value,
                .reasoning_delta => |value| value,
                else => unreachable,
            };
            try self.buffer.appendSlice(self.arena, delta.text);
            self.id = delta.id;
            self.kind = incoming_kind;
            if (delta.provider_metadata) |metadata| self.provider_metadata = metadata;
        }
    }

    fn detectChunk(self: *State) ?usize {
        const buffer = self.buffer.items;
        return switch (self.chunking) {
            .word => detectWord(buffer),
            .line => detectLine(buffer),
        };
    }

    fn takeChunk(self: *State, length: usize, paced: bool) std.mem.Allocator.Error!Part {
        const text = try self.arena.dupe(u8, self.buffer.items[0..length]);
        const id = self.id;
        const metadata = self.provider_metadata;
        const remaining = self.buffer.items.len - length;
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[length..]);
        self.buffer.items.len = remaining;
        if (remaining == 0) self.provider_metadata = null;
        if (paced) self.sleep_pending = true;
        return switch (self.kind.?) {
            .text_delta => .{ .text_delta = .{
                .id = id,
                .text = text,
                .provider_metadata = metadata,
            } },
            .reasoning_delta => .{ .reasoning_delta = .{
                .id = id,
                .text = text,
                .provider_metadata = metadata,
            } },
        };
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.upstream.deinit(io);
    }
};

fn detectWord(buffer: []const u8) ?usize {
    var index: usize = 0;
    while (index < buffer.len and isWhitespace(buffer[index])) index += 1;
    if (index == buffer.len) return null;
    while (index < buffer.len and !isWhitespace(buffer[index])) index += 1;
    if (index == buffer.len) return null;
    while (index < buffer.len and isWhitespace(buffer[index])) index += 1;
    return index;
}

fn detectLine(buffer: []const u8) ?usize {
    const first = std.mem.indexOfScalar(u8, buffer, '\n') orelse return null;
    var end = first + 1;
    while (end < buffer.len and buffer[end] == '\n') end += 1;
    return end;
}

fn isWhitespace(value: u8) bool {
    return switch (value) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

test "smoothStream word and line detectors retain trailing partials" {
    try std.testing.expectEqual(7, detectWord("Hello, world").?);
    try std.testing.expectEqual(null, detectWord("world"));
    try std.testing.expectEqual(4, detectLine("one\ntwo").?);
    try std.testing.expectEqual(null, detectLine("one"));
}
