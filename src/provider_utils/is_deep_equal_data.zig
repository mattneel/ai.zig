//! Structural equality for parsed JSON data.
//!
//! `streamObject` and output-aware `streamText` call this on every accepted
//! partial. Keeping the comparison on `std.json.Value` avoids stringify/parse
//! churn on the streaming hot path.

const std = @import("std");

pub fn isDeepEqualData(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |values| {
            const other = right.array;
            if (values.items.len != other.items.len) return false;
            for (values.items, other.items) |value, other_value| {
                if (!isDeepEqualData(value, other_value)) return false;
            }
            return true;
        },
        .object => |values| {
            const other = right.object;
            if (values.count() != other.count()) return false;
            var iterator = values.iterator();
            while (iterator.next()) |entry| {
                const other_value = other.get(entry.key_ptr.*) orelse return false;
                if (!isDeepEqualData(entry.value_ptr.*, other_value)) return false;
            }
            return true;
        },
    };
}

pub fn optional(left: ?std.json.Value, right: ?std.json.Value) bool {
    if (left == null or right == null) return left == null and right == null;
    return isDeepEqualData(left.?, right.?);
}

test "isDeepEqualData compares JSON primitives, arrays, and objects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const equal_left = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"a\":[1,true,null,{\"b\":\"x\"}]}",
        .{},
    );
    const equal_right = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"a\":[1,true,null,{\"b\":\"x\"}]}",
        .{},
    );
    const different_value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"a\":[1,true,null,{\"b\":\"y\"}]}",
        .{},
    );
    const different_shape = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"a\":[1,true,null,{\"b\":\"x\"}],\"c\":0}",
        .{},
    );

    try std.testing.expect(isDeepEqualData(equal_left, equal_right));
    try std.testing.expect(!isDeepEqualData(equal_left, different_value));
    try std.testing.expect(!isDeepEqualData(equal_left, different_shape));
    try std.testing.expect(!isDeepEqualData(.{ .integer = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(optional(null, null));
    try std.testing.expect(!optional(equal_left, null));
}
