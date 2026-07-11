const std = @import("std");
const wire = @import("wire.zig");

pub const RoundTripOptions = struct {
    normalizes_binary: bool = false,
};

pub fn roundTrip(comptime T: type, fixture: []const u8) !void {
    return roundTripWithOptions(T, fixture, .{});
}

pub fn roundTripWithOptions(
    comptime T: type,
    fixture: []const u8,
    options: RoundTripOptions,
) !void {
    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    const first_allocator = first_arena.allocator();
    const first_json = try parseJson(first_allocator, fixture);
    const first = try wire.parse(T, first_allocator, first_json);
    const first_canonical = try wire.stringifyAlloc(std.testing.allocator, first);
    defer std.testing.allocator.free(first_canonical);

    const first_canonical_json = try parseJson(first_allocator, first_canonical);
    try std.testing.expect(try jsonEquivalent(
        std.testing.allocator,
        first_json,
        first_canonical_json,
        options,
    ));

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    const second_allocator = second_arena.allocator();
    const second_json = try parseJson(second_allocator, first_canonical);
    const second = try wire.parse(T, second_allocator, second_json);
    const second_canonical = try wire.stringifyAlloc(std.testing.allocator, second);
    defer std.testing.allocator.free(second_canonical);

    try std.testing.expectEqualStrings(first_canonical, second_canonical);
}

fn parseJson(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
}

fn jsonEquivalent(
    allocator: std.mem.Allocator,
    left: std.json.Value,
    right: std.json.Value,
    options: RoundTripOptions,
) std.mem.Allocator.Error!bool {
    return switch (left) {
        .null => right == .null,
        .bool => |left_value| switch (right) {
            .bool => |right_value| left_value == right_value,
            else => false,
        },
        .integer, .float, .number_string => numbersEquivalent(left, right),
        .string => |left_value| switch (right) {
            .string => |right_value| std.mem.eql(u8, left_value, right_value),
            .array => |right_value| options.normalizes_binary and
                try octetsEqualBase64(allocator, right_value, left_value),
            else => false,
        },
        .array => |left_value| switch (right) {
            .string => |right_value| options.normalizes_binary and
                try octetsEqualBase64(allocator, left_value, right_value),
            .array => |right_value| arraysEquivalent(
                allocator,
                left_value,
                right_value,
                options,
            ),
            else => false,
        },
        .object => |left_value| switch (right) {
            .object => |right_value| objectsEquivalent(
                allocator,
                left_value,
                right_value,
                options,
            ),
            else => false,
        },
    };
}

fn numbersEquivalent(left: std.json.Value, right: std.json.Value) bool {
    if (left == .number_string and right == .number_string and
        std.mem.eql(u8, left.number_string, right.number_string))
    {
        return true;
    }
    const left_value = numberAsFloat(left) orelse return false;
    const right_value = numberAsFloat(right) orelse return false;
    return left_value == right_value;
}

fn numberAsFloat(value: std.json.Value) ?f128 {
    return switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| @floatCast(item),
        .number_string => |item| std.fmt.parseFloat(f128, item) catch null,
        else => null,
    };
}

fn arraysEquivalent(
    allocator: std.mem.Allocator,
    left: std.json.Array,
    right: std.json.Array,
    options: RoundTripOptions,
) std.mem.Allocator.Error!bool {
    if (left.items.len != right.items.len) return false;
    for (left.items, right.items) |left_item, right_item| {
        if (!try jsonEquivalent(allocator, left_item, right_item, options)) return false;
    }
    return true;
}

fn objectsEquivalent(
    allocator: std.mem.Allocator,
    left: std.json.ObjectMap,
    right: std.json.ObjectMap,
    options: RoundTripOptions,
) std.mem.Allocator.Error!bool {
    var left_iterator = left.iterator();
    while (left_iterator.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        const right_value = right.get(entry.key_ptr.*) orelse return false;
        if (right_value == .null) return false;
        if (!try jsonEquivalent(allocator, entry.value_ptr.*, right_value, options)) return false;
    }

    var right_iterator = right.iterator();
    while (right_iterator.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        const left_value = left.get(entry.key_ptr.*) orelse return false;
        if (left_value == .null) return false;
    }
    return true;
}

fn octetsEqualBase64(
    allocator: std.mem.Allocator,
    octets: std.json.Array,
    encoded: []const u8,
) std.mem.Allocator.Error!bool {
    const decoder = std.base64.standard.Decoder;
    const decoded_length = decoder.calcSizeForSlice(encoded) catch return false;
    if (octets.items.len != decoded_length) return false;

    const decoded = try allocator.alloc(u8, decoded_length);
    defer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return false;

    for (octets.items, decoded) |item, byte| {
        const octet = jsonOctet(item) orelse return false;
        if (octet != byte) return false;
    }
    return true;
}

fn jsonOctet(value: std.json.Value) ?u8 {
    return switch (value) {
        .integer => |item| std.math.cast(u8, item),
        .float => |item| floatOctet(item),
        .number_string => |item| std.fmt.parseInt(u8, item, 10) catch blk: {
            const number = std.fmt.parseFloat(f64, item) catch return null;
            break :blk floatOctet(number);
        },
        else => null,
    };
}

fn floatOctet(value: f64) ?u8 {
    if (!std.math.isFinite(value) or @trunc(value) != value or value < 0 or value > 255) {
        return null;
    }
    return @intFromFloat(value);
}
