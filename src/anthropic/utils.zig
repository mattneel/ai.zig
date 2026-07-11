const std = @import("std");

const Allocator = std.mem.Allocator;

pub const BetaSet = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,
    order: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *BetaSet, allocator: Allocator, beta: []const u8) Allocator.Error!void {
        const result = try self.map.getOrPut(allocator, beta);
        if (result.found_existing) return;
        result.value_ptr.* = {};
        try self.order.append(allocator, beta);
    }

    pub fn addCsv(self: *BetaSet, allocator: Allocator, value: []const u8) Allocator.Error!void {
        var iterator = std.mem.splitScalar(u8, value, ',');
        while (iterator.next()) |item| {
            const beta = std.mem.trim(u8, item, " \t\r\n");
            if (beta.len != 0) try self.add(allocator, beta);
        }
    }

    pub fn merge(self: *BetaSet, allocator: Allocator, other: *const BetaSet) Allocator.Error!void {
        for (other.order.items) |beta| try self.add(allocator, beta);
    }

    pub fn join(self: *const BetaSet, allocator: Allocator) Allocator.Error!?[]const u8 {
        if (self.order.items.len == 0) return null;
        const joined: []const u8 = try std.mem.join(allocator, ",", self.order.items);
        return joined;
    }

    pub fn deinit(self: *BetaSet, allocator: Allocator) void {
        self.map.deinit(allocator);
        self.order.deinit(allocator);
        self.* = undefined;
    }
};

pub fn putString(
    object: *std.json.ObjectMap,
    allocator: Allocator,
    key: []const u8,
    value: []const u8,
) Allocator.Error!void {
    try object.put(allocator, key, .{ .string = try allocator.dupe(u8, value) });
}

pub fn uintValue(allocator: Allocator, value: u64) Allocator.Error!std.json.Value {
    if (value <= std.math.maxInt(i64)) return .{ .integer = @intCast(value) };
    return .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{value}) };
}

pub fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

pub fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0 and @floor(number) == number) @intFromFloat(number) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}
