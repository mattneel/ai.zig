const std = @import("std");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

/// Converts the JSON Schema subset accepted by the provider boundary into the
/// OpenAPI 3 schema shape consumed by Gemini, matching @ai-sdk/google.
pub fn convert(arena: Allocator, schema: std.json.Value) Allocator.Error!?std.json.Value {
    return convertInner(arena, schema, true);
}

fn convertInner(arena: Allocator, schema: std.json.Value, is_root: bool) Allocator.Error!?std.json.Value {
    if (schema == .bool) {
        var output: std.json.ObjectMap = .empty;
        try putString(&output, arena, "type", "boolean");
        try output.put(arena, "properties", .{ .object = .empty });
        return .{ .object = output };
    }
    if (schema != .object) return null;
    if (isEmptyObjectSchema(schema.object)) {
        if (is_root) return null;
        var output: std.json.ObjectMap = .empty;
        try putString(&output, arena, "type", "object");
        if (schema.object.get("description")) |description| if (description == .string) {
            try putString(&output, arena, "description", description.string);
        };
        return .{ .object = output };
    }

    const source = schema.object;
    var output: std.json.ObjectMap = .empty;
    try copyScalar(arena, source, &output, "description");
    try copyScalar(arena, source, &output, "required");
    try copyScalar(arena, source, &output, "format");

    if (source.get("const")) |constant| {
        var values = std.json.Array.init(arena);
        try values.append(try provider_utils.cloneJsonValue(arena, constant));
        try output.put(arena, "enum", .{ .array = values });
    } else if (source.get("enum")) |values| {
        try output.put(arena, "enum", try provider_utils.cloneJsonValue(arena, values));
    }

    if (source.get("type")) |type_value| switch (type_value) {
        .string => |value| try putString(&output, arena, "type", value),
        .array => |values| {
            var alternatives = std.json.Array.init(arena);
            var nullable = false;
            for (values.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, "null")) {
                    nullable = true;
                    continue;
                }
                var alternative: std.json.ObjectMap = .empty;
                try putString(&alternative, arena, "type", item.string);
                try alternatives.append(.{ .object = alternative });
            }
            if (alternatives.items.len == 0 and nullable) {
                try putString(&output, arena, "type", "null");
            } else {
                try output.put(arena, "anyOf", .{ .array = alternatives });
                if (nullable) try output.put(arena, "nullable", .{ .bool = true });
            }
        },
        else => {},
    };

    if (source.get("properties")) |properties| if (properties == .object) {
        var converted_properties: std.json.ObjectMap = .empty;
        var iterator = properties.object.iterator();
        while (iterator.next()) |entry| {
            const converted = (try convertInner(arena, entry.value_ptr.*, false)) orelse std.json.Value{ .object = .empty };
            try converted_properties.put(arena, try arena.dupe(u8, entry.key_ptr.*), converted);
        }
        try output.put(arena, "properties", .{ .object = converted_properties });
    };

    if (source.get("items")) |items| switch (items) {
        .array => |values| {
            var converted_items = std.json.Array.init(arena);
            for (values.items) |item| {
                try converted_items.append((try convertInner(arena, item, false)) orelse std.json.Value{ .object = .empty });
            }
            try output.put(arena, "items", .{ .array = converted_items });
        },
        else => if (try convertInner(arena, items, false)) |converted| try output.put(arena, "items", converted),
    };

    try convertSchemaArray(arena, source, &output, "allOf", false);
    try convertAnyOf(arena, source, &output);
    try convertSchemaArray(arena, source, &output, "oneOf", false);
    try copyScalar(arena, source, &output, "minLength");
    return .{ .object = output };
}

fn convertAnyOf(
    arena: Allocator,
    source: std.json.ObjectMap,
    output: *std.json.ObjectMap,
) Allocator.Error!void {
    const value = source.get("anyOf") orelse return;
    if (value != .array) return;
    var non_null: std.ArrayList(std.json.Value) = .empty;
    defer non_null.deinit(arena);
    var has_null = false;
    for (value.array.items) |item| {
        if (item == .object) {
            if (item.object.get("type")) |kind| if (kind == .string and std.mem.eql(u8, kind.string, "null")) {
                has_null = true;
                continue;
            };
        }
        try non_null.append(arena, item);
    }
    if (!has_null) {
        try convertSchemaArray(arena, source, output, "anyOf", false);
        return;
    }

    if (non_null.items.len == 1) {
        if (try convertInner(arena, non_null.items[0], false)) |converted| {
            if (converted == .object) {
                try output.put(arena, "nullable", .{ .bool = true });
                var iterator = converted.object.iterator();
                while (iterator.next()) |entry| {
                    try output.put(arena, try arena.dupe(u8, entry.key_ptr.*), try provider_utils.cloneJsonValue(arena, entry.value_ptr.*));
                }
            }
        }
        return;
    }

    var alternatives = std.json.Array.init(arena);
    for (non_null.items) |item| try alternatives.append((try convertInner(arena, item, false)) orelse std.json.Value{ .object = .empty });
    try output.put(arena, "anyOf", .{ .array = alternatives });
    try output.put(arena, "nullable", .{ .bool = true });
}

fn convertSchemaArray(
    arena: Allocator,
    source: std.json.ObjectMap,
    output: *std.json.ObjectMap,
    key: []const u8,
    _: bool,
) Allocator.Error!void {
    const value = source.get(key) orelse return;
    if (value != .array) return;
    var converted = std.json.Array.init(arena);
    for (value.array.items) |item| try converted.append((try convertInner(arena, item, false)) orelse std.json.Value{ .object = .empty });
    try output.put(arena, key, .{ .array = converted });
}

fn copyScalar(
    arena: Allocator,
    source: std.json.ObjectMap,
    output: *std.json.ObjectMap,
    key: []const u8,
) Allocator.Error!void {
    if (source.get(key)) |value| try output.put(arena, key, try provider_utils.cloneJsonValue(arena, value));
}

fn isEmptyObjectSchema(object: std.json.ObjectMap) bool {
    const kind = object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "object")) return false;
    if (object.get("properties")) |properties| if (properties != .object or properties.object.count() != 0) return false;
    if (object.get("additionalProperties")) |additional| return additional == .bool and !additional.bool;
    return true;
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

test "Google OpenAPI conversion drops unsupported JSON Schema keywords" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}
    , .{});
    const output = (try convert(arena, input)).?;
    try std.testing.expect(output.object.get("$schema") == null);
    try std.testing.expect(output.object.get("additionalProperties") == null);
    try std.testing.expectEqualStrings("object", output.object.get("type").?.string);
    try std.testing.expect(output.object.get("properties").?.object.get("value") != null);
}

test "Google OpenAPI conversion maps nullable anyOf and const" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"anyOf":[{"type":"string","const":"x"},{"type":"null"}]}
    , .{});
    const output = (try convert(arena, input)).?;
    try std.testing.expectEqual(true, output.object.get("nullable").?.bool);
    try std.testing.expectEqualStrings("string", output.object.get("type").?.string);
    try std.testing.expectEqualStrings("x", output.object.get("enum").?.array.items[0].string);
}

test "Google OpenAPI conversion omits an empty root object schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}", .{});
    try std.testing.expect((try convert(arena, input)) == null);
}
