const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const Document = union(enum) {
    text: []const u8,
    value: std.json.Value,
};

pub const Validator = struct {
    ctx: ?*anyopaque = null,
    validate_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        value: std.json.Value,
        diag: ?*provider.Diagnostics,
    ) error{TypeValidationError}!void,

    pub fn validate(
        self: Validator,
        arena: Allocator,
        value: std.json.Value,
        diag: ?*provider.Diagnostics,
    ) error{TypeValidationError}!void {
        return self.validate_fn(self.ctx, arena, value, diag);
    }
};

pub const Schema = struct {
    document: Document,
    validator: ?Validator = null,
};

pub fn schemaFromType(comptime T: type) Schema {
    return .{
        .document = .{ .text = schemaText(T) },
        .validator = .{ .validate_fn = GeneratedValidator(T).validate },
    };
}

pub fn rawSchema(document_json: []const u8, validator: ?Validator) Schema {
    return .{ .document = .{ .text = document_json }, .validator = validator };
}

fn GeneratedValidator(comptime T: type) type {
    return struct {
        fn validate(
            _: ?*anyopaque,
            arena: Allocator,
            value: std.json.Value,
            diag: ?*provider.Diagnostics,
        ) error{TypeValidationError}!void {
            const normalized = normalizeForType(T, arena, value) catch |err| {
                provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .type_validation = .{
                    .message = "Type validation failed",
                    .cause_message = @errorName(err),
                } });
                return error.TypeValidationError;
            };
            _ = std.json.parseFromValueLeaky(T, arena, normalized, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .type_validation = .{
                    .message = "Type validation failed",
                    .cause_message = @errorName(err),
                } });
                return error.TypeValidationError;
            };
        }
    };
}

fn normalizeForType(
    comptime T: type,
    arena: Allocator,
    value: std.json.Value,
) Allocator.Error!std.json.Value {
    if (T == std.json.Value) return value;
    return switch (@typeInfo(T)) {
        .optional => |info| if (value == .null)
            value
        else
            normalizeForType(info.child, arena, value),
        .@"struct" => if (value != .object)
            value
        else
            normalizeStruct(T, arena, value.object),
        .pointer => |info| if (info.size != .slice or info.child == u8 or value != .array)
            value
        else
            normalizeArray(info.child, arena, value.array),
        else => value,
    };
}

fn normalizeStruct(
    comptime T: type,
    arena: Allocator,
    source: std.json.ObjectMap,
) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    inline for (std.meta.fields(T)) |field| {
        const wire_name = comptime fieldWireName(T, field.name);
        if (source.get(wire_name)) |field_value| {
            try object.put(
                arena,
                field.name,
                try normalizeForType(field.type, arena, field_value),
            );
        }
    }
    return .{ .object = object };
}

fn normalizeArray(
    comptime Child: type,
    arena: Allocator,
    source: std.json.Array,
) Allocator.Error!std.json.Value {
    var array = std.json.Array.init(arena);
    for (source.items) |item| try array.append(try normalizeForType(Child, arena, item));
    return .{ .array = array };
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

fn schemaText(comptime T: type) []const u8 {
    if (T == std.json.Value) return "{}";

    return switch (@typeInfo(T)) {
        .optional => |info| schemaText(info.child),
        .bool => "{\"type\":\"boolean\"}",
        .int, .comptime_int => "{\"type\":\"integer\"}",
        .float, .comptime_float => "{\"type\":\"number\"}",
        .pointer => |info| pointerSchema(T, info),
        .@"enum" => enumSchema(T),
        .@"struct" => structSchema(T),
        .@"union" => @compileError(
            "schemaFromType does not support unions; provide rawSchema for " ++ @typeName(T),
        ),
        else => @compileError(
            "schemaFromType does not support " ++ @typeName(T) ++ "; provide rawSchema instead",
        ),
    };
}

fn pointerSchema(comptime T: type, comptime info: std.builtin.Type.Pointer) []const u8 {
    if (info.size != .slice) {
        @compileError("schemaFromType only supports pointer slices: " ++ @typeName(T));
    }
    if (info.child == u8) return "{\"type\":\"string\"}";
    return "{\"type\":\"array\",\"items\":" ++ schemaText(info.child) ++ "}";
}

fn enumSchema(comptime T: type) []const u8 {
    comptime var result: []const u8 = "{\"type\":\"string\",\"enum\":[";
    inline for (std.meta.fields(T), 0..) |field, index| {
        if (index != 0) result = result ++ ",";
        result = result ++ "\"" ++ field.name ++ "\"";
    }
    return result ++ "]}";
}

fn structSchema(comptime T: type) []const u8 {
    comptime var result: []const u8 = "{\"type\":\"object\",\"properties\":{";
    inline for (std.meta.fields(T), 0..) |field, index| {
        const field_name = comptime fieldWireName(T, field.name);
        const field_schema = comptime schemaText(field.type);
        if (index != 0) result = result ++ ",";
        result = result ++ "\"" ++ field_name ++ "\":" ++ field_schema;
    }
    result = result ++ "},\"required\":[";

    comptime var required_count: usize = 0;
    inline for (std.meta.fields(T)) |field| {
        const field_name = comptime fieldWireName(T, field.name);
        if (@typeInfo(field.type) == .optional or field.defaultValue() != null) continue;
        if (required_count != 0) result = result ++ ",";
        result = result ++ "\"" ++ field_name ++ "\"";
        required_count += 1;
    }
    return result ++ "],\"additionalProperties\":false}";
}

fn fieldWireName(comptime T: type, comptime zig_name: []const u8) []const u8 {
    if (@hasDecl(T, "wire_field_names")) {
        inline for (T.wire_field_names) |mapping| {
            if (comptime std.mem.eql(u8, zig_name, mapping[0])) return mapping[1];
        }
    }
    return camelCase(zig_name);
}

fn camelCase(comptime name: []const u8) []const u8 {
    const Static = struct {
        const len = camelCaseLength(name);
        const value: [len]u8 = make: {
            var result: [len]u8 = undefined;
            var output_index: usize = 0;
            var uppercase = false;
            for (name) |byte| {
                if (byte == '_') {
                    uppercase = true;
                    continue;
                }
                result[output_index] = if (uppercase and byte >= 'a' and byte <= 'z')
                    byte - ('a' - 'A')
                else
                    byte;
                uppercase = false;
                output_index += 1;
            }
            break :make result;
        };
    };
    return &Static.value;
}

fn camelCaseLength(comptime name: []const u8) usize {
    comptime var length: usize = 0;
    inline for (name) |byte| if (byte != '_') {
        length += 1;
    };
    return length;
}

/// Mutates a dynamic JSON Schema tree, forcing additionalProperties:false on
/// every object schema reachable through the draft-07 structural keywords.
pub fn addAdditionalPropertiesToJsonSchema(
    arena: Allocator,
    document: *std.json.Value,
) Allocator.Error!void {
    try visit(arena, document);
}

fn visit(arena: Allocator, value: *std.json.Value) Allocator.Error!void {
    if (value.* != .object) return;
    var object = &value.object;

    if (isObjectSchema(object)) {
        try object.put(arena, "additionalProperties", .{ .bool = false });
    }

    if (object.getPtr("properties")) |properties| {
        if (properties.* == .object) {
            var iterator = properties.object.iterator();
            while (iterator.next()) |entry| try visit(arena, entry.value_ptr);
        }
    }
    if (object.getPtr("items")) |items| {
        if (items.* == .array) {
            for (items.array.items) |*item| try visit(arena, item);
        } else {
            try visit(arena, items);
        }
    }
    inline for (.{ "anyOf", "allOf", "oneOf" }) |keyword| {
        if (object.getPtr(keyword)) |alternatives| {
            if (alternatives.* == .array) {
                for (alternatives.array.items) |*alternative| try visit(arena, alternative);
            }
        }
    }
    if (object.getPtr("definitions")) |definitions| {
        if (definitions.* == .object) {
            var iterator = definitions.object.iterator();
            while (iterator.next()) |entry| try visit(arena, entry.value_ptr);
        }
    }
}

fn isObjectSchema(object: *const std.json.ObjectMap) bool {
    const type_value = object.get("type") orelse return false;
    return switch (type_value) {
        .string => |text| std.mem.eql(u8, text, "object"),
        .array => |types| blk: {
            for (types.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "object")) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "schemaFromType emits camel-cased draft-07 document" {
    const Mode = enum { fast, careful };
    const Child = struct { child_name: []const u8 };
    const Shape = struct {
        required_text: []const u8,
        optional_count: ?u32 = null,
        defaulted_label: []const u8 = "default",
        children: []const Child,
        mode: Mode,
    };
    const schema = schemaFromType(Shape);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"requiredText\":{\"type\":\"string\"},\"optionalCount\":{\"type\":\"integer\"},\"defaultedLabel\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"childName\":{\"type\":\"string\"}},\"required\":[\"childName\"],\"additionalProperties\":false}},\"mode\":{\"type\":\"string\",\"enum\":[\"fast\",\"careful\"]}},\"required\":[\"requiredText\",\"children\",\"mode\"],\"additionalProperties\":false}",
        schema.document.text,
    );
}

test "schema typed validator reports TypeValidationError" {
    const Shape = struct {
        user_name: []const u8,
        age: u32,

        pub const wire_field_names = .{.{ "user_name", "user" }};
    };
    const schema = schemaFromType(Shape);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const valid = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"user\":\"A\",\"age\":2}", .{});
    try schema.validator.?.validate(arena, valid, null);

    const invalid = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"user\":\"A\",\"age\":\"old\"}", .{});
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.TypeValidationError,
        schema.validator.?.validate(arena, invalid, &diagnostics),
    );
    try std.testing.expect(diagnostics.available);
}

test "schema addAdditionalProperties walks properties items combinators and definitions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}},\"choice\":{\"anyOf\":[{\"type\":\"object\"},{\"type\":\"string\"}]}},\"definitions\":{\"Node\":{\"type\":[\"object\",\"null\"]}}}",
        .{},
    );
    try addAdditionalPropertiesToJsonSchema(arena, &document);

    try std.testing.expect(!document.object.get("additionalProperties").?.bool);
    const properties = document.object.get("properties").?.object;
    const items = properties.get("items").?.object.get("items").?.object;
    try std.testing.expect(!items.get("additionalProperties").?.bool);
    const choice = properties.get("choice").?.object.get("anyOf").?.array.items[0].object;
    try std.testing.expect(!choice.get("additionalProperties").?.bool);
    const node = document.object.get("definitions").?.object.get("Node").?.object;
    try std.testing.expect(!node.get("additionalProperties").?.bool);
}
