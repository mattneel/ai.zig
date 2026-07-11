const std = @import("std");
const fix_json = @import("fix_json.zig");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;

pub const State = enum {
    undefined_input,
    successful_parse,
    repaired_parse,
    failed_parse,
};

pub const Result = struct {
    value: ?std.json.Value,
    state: State,
};

pub fn parsePartialJson(arena: Allocator, text: ?[]const u8) Allocator.Error!Result {
    const input = text orelse return .{ .value = null, .state = .undefined_input };

    switch (json.safeParseJson(std.json.Value, arena, input)) {
        .success => |success| return .{ .value = success.value, .state = .successful_parse },
        .failure => {},
    }

    const repaired = try fix_json.fixJson(arena, input);
    switch (json.safeParseJson(std.json.Value, arena, repaired)) {
        .success => |success| return .{ .value = success.value, .state = .repaired_parse },
        .failure => return .{ .value = null, .state = .failed_parse },
    }
}

test "parsePartialJson complete upstream corpus (4 cases)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var result = try parsePartialJson(arena, null);
    try std.testing.expectEqual(State.undefined_input, result.state);
    try std.testing.expectEqual(null, result.value);

    result = try parsePartialJson(arena, "{\"key\":\"value\"}");
    try std.testing.expectEqual(State.successful_parse, result.state);
    try std.testing.expectEqualStrings("value", result.value.?.object.get("key").?.string);

    result = try parsePartialJson(arena, "{\"key\":\"value\"");
    try std.testing.expectEqual(State.repaired_parse, result.state);
    try std.testing.expectEqualStrings("value", result.value.?.object.get("key").?.string);

    result = try parsePartialJson(arena, "not json at all");
    try std.testing.expectEqual(State.failed_parse, result.state);
    try std.testing.expectEqual(null, result.value);
}
