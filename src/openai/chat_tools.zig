const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const PreparedTools = struct {
    tools: ?std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    warnings: []const provider.Warning,
};

pub fn prepareChatTools(
    arena: Allocator,
    tools: ?[]const provider.Tool,
    tool_choice: ?provider.ToolChoice,
) Allocator.Error!PreparedTools {
    const input = tools orelse return .{ .warnings = &.{} };
    if (input.len == 0) return .{ .warnings = &.{} };

    var output = std.json.Array.init(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    for (input) |tool| switch (tool) {
        .function => |function_tool| {
            var item: std.json.ObjectMap = .empty;
            try putString(&item, arena, "type", "function");
            var function: std.json.ObjectMap = .empty;
            try putString(&function, arena, "name", function_tool.name);
            if (function_tool.description) |description| try putString(&function, arena, "description", description);
            try function.put(arena, "parameters", try provider_utils.cloneJsonValue(arena, function_tool.input_schema));
            if (function_tool.strict) |strict| try function.put(arena, "strict", .{ .bool = strict });
            try item.put(arena, "function", .{ .object = function });
            try output.append(.{ .object = item });
        },
        .provider => try warnings.append(arena, .{ .unsupported = .{ .feature = "tool type: provider" } }),
    };

    const prepared_choice: ?std.json.Value = if (tool_choice) |choice| switch (choice) {
        .auto => .{ .string = "auto" },
        .none => .{ .string = "none" },
        .required => .{ .string = "required" },
        .tool => |named| blk: {
            var choice_object: std.json.ObjectMap = .empty;
            try putString(&choice_object, arena, "type", "function");
            var function: std.json.ObjectMap = .empty;
            try putString(&function, arena, "name", named.tool_name);
            try choice_object.put(arena, "function", .{ .object = function });
            break :blk .{ .object = choice_object };
        },
    } else null;

    return .{
        .tools = .{ .array = output },
        .tool_choice = prepared_choice,
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

test "OpenAI chat tools map functions, strict, tool choice, and provider warnings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const tools = [_]provider.Tool{
        .{ .function = .{
            .name = "weather",
            .description = "Get weather",
            .input_schema = .{ .object = schema },
            .strict = true,
        } },
        .{ .provider = .{ .id = "openai.unsupported", .name = "unsupported", .args = .{ .object = .empty } } },
    };
    const prepared = try prepareChatTools(arena, &tools, .{ .tool = .{ .tool_name = "weather" } });
    try std.testing.expectEqual(1, prepared.tools.?.array.items.len);
    const function = prepared.tools.?.array.items[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("weather", function.get("name").?.string);
    try std.testing.expect(function.get("strict").?.bool);
    try std.testing.expectEqualStrings("weather", prepared.tool_choice.?.object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqual(1, prepared.warnings.len);
}
