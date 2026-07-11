//! Canonical provider V4 JSON wire codec.
//!
//! Struct fields are emitted in declaration order, with automatic
//! snake_case-to-camelCase names. Types can declare `wire_field_names` for
//! irregular field names, `wire_values` for enum strings, and internally
//! tagged unions declare `wire_tag_field` plus exhaustive `wire_tags`.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");
const iso8601 = @import("iso8601.zig");
const language = @import("language_model.zig");
const realtime = @import("realtime_model.zig");
const transcription = @import("transcription_model.zig");
const video = @import("video_model.zig");
const files_module = @import("files.zig");
const skills_module = @import("skills.zig");

pub const ParseError = errors.Error || std.mem.Allocator.Error || iso8601.Error || error{
    UnknownUnionTag,
};

const ParseContext = struct {
    field: ?[]const u8 = null,
    unknown_tag: ?[]const u8 = null,
};

/// Parses an already-decoded JSON value into an arena-owned provider type.
/// Unknown object fields are ignored and JSON null maps to absent optionals.
pub fn parse(comptime T: type, arena: std.mem.Allocator, value: std.json.Value) ParseError!T {
    return parseInternal(T, arena, value, null);
}

/// Writes a provider type with deterministic declaration-order fields.
pub fn write(value: anytype, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    return writeInternal(@TypeOf(value), value, writer);
}

/// Writes one canonical minified provider JSON document.
pub fn writeValue(value: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try write(value, &stringify);
}

/// Returns an allocator-owned canonical minified JSON document.
pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeValue(value, &output.writer);
    return output.toOwnedSlice();
}

fn parseInternal(
    comptime T: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!T {
    if (comptime hasDecl(T, "wireParse")) return T.wireParse(arena, value);
    if (comptime T == std.json.Value) return cloneJsonValue(arena, value);
    if (comptime T == shared.BinaryData) return parseBinaryData(arena, value, context);
    if (comptime T == shared.Headers) return parseHeaders(arena, value, context);

    return switch (@typeInfo(T)) {
        .optional => |optional| if (value == .null)
            null
        else
            try parseInternal(optional.child, arena, value, context),
        .bool => switch (value) {
            .bool => |item| item,
            else => validation(context, null),
        },
        .int => parseInteger(T, value, context),
        .float => parseFloat(T, value, context),
        .@"enum" => parseEnum(T, value, context),
        .pointer => |pointer| parsePointer(T, pointer, arena, value, context),
        .@"struct" => parseStruct(T, arena, value, context),
        .@"union" => parseUnion(T, arena, value, context),
        else => @compileError("provider wire parser does not support " ++ @typeName(T)),
    };
}

fn parsePointer(
    comptime T: type,
    comptime pointer: std.builtin.Type.Pointer,
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!T {
    if (pointer.size != .slice) {
        @compileError("provider wire parser only supports pointer slices: " ++ @typeName(T));
    }
    if (pointer.child == u8) {
        const text = switch (value) {
            .string => |item| item,
            else => return validation(context, null),
        };
        return try arena.dupe(u8, text);
    }
    const array = switch (value) {
        .array => |item| item,
        else => return validation(context, null),
    };
    const result = try arena.alloc(pointer.child, array.items.len);
    for (array.items, result) |item, *destination| {
        destination.* = try parseInternal(pointer.child, arena, item, context);
    }
    return result;
}

fn parseStruct(
    comptime T: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!T {
    const object = switch (value) {
        .object => |item| item,
        else => return validation(context, null),
    };
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        const wire_name = fieldWireName(T, field.name);
        if (object.get(wire_name)) |field_value| {
            if (comptime isTimestampField(field.name, field.type)) {
                @field(result, field.name) = parseTimestamp(field.type, field_value, context) catch |err| {
                    markField(context, wire_name);
                    return err;
                };
            } else if (comptime T == video.VideoData.Bytes and std.mem.eql(u8, field.name, "data")) {
                @field(result, field.name) = parseBytes(arena, field_value, context) catch |err| {
                    markField(context, wire_name);
                    return err;
                };
            } else if (comptime isProviderReferenceField(T, field.name)) {
                validateProviderReference(field_value, context) catch |err| {
                    markField(context, wire_name);
                    return err;
                };
                @field(result, field.name) = parseInternal(field.type, arena, field_value, context) catch |err| {
                    markField(context, wire_name);
                    return err;
                };
            } else if (comptime T == language.GeneratedToolResult and std.mem.eql(u8, field.name, "result")) {
                if (field_value == .null) return validation(context, wire_name);
                @field(result, field.name) = parseInternal(field.type, arena, field_value, context) catch |err| {
                    markField(context, wire_name);
                    return err;
                };
            } else {
                @field(result, field.name) = parseInternal(field.type, arena, field_value, context) catch |err| {
                    markField(context, wire_name);
                    return err;
                };
            }
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else {
            return validation(context, wire_name);
        }
    }
    return result;
}

fn parseUnion(
    comptime T: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!T {
    assertUnionTagTable(T);
    const union_info = @typeInfo(T).@"union";
    const Tag = union_info.tag_type.?;
    const object = switch (value) {
        .object => |item| item,
        else => return validation(context, null),
    };
    const tag_value = object.get(T.wire_tag_field) orelse
        return validation(context, T.wire_tag_field);
    const tag_text = switch (tag_value) {
        .string => |item| item,
        else => return validation(context, T.wire_tag_field),
    };

    inline for (T.wire_tags) |mapping| {
        if (std.mem.eql(u8, tag_text, mapping[1])) {
            const mapped_tag: Tag = mapping[0];
            inline for (union_info.fields) |field| {
                if (mapped_tag == @field(Tag, field.name)) {
                    const payload = try parseInternal(field.type, arena, value, context);
                    return @unionInit(T, field.name, payload);
                }
            }
            unreachable;
        }
    }
    if (context) |ctx| ctx.unknown_tag = tag_text;
    return error.UnknownUnionTag;
}

fn parseEnum(
    comptime T: type,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!T {
    const text = switch (value) {
        .string => |item| item,
        else => return validation(context, null),
    };
    if (comptime hasDecl(T, "wire_values")) {
        assertEnumValueTable(T);
        inline for (T.wire_values) |mapping| {
            if (std.mem.eql(u8, text, mapping[1])) {
                const result: T = mapping[0];
                return result;
            }
        }
        return validation(context, null);
    }
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(T, field.name);
    }
    return validation(context, null);
}

fn parseInteger(comptime T: type, value: std.json.Value, context: ?*ParseContext) ParseError!T {
    const integer: i128 = switch (value) {
        .integer => |item| item,
        .number_string => |item| std.fmt.parseInt(i128, item, 10) catch
            return validation(context, null),
        .float => |item| blk: {
            if (!std.math.isFinite(item) or @trunc(item) != item) return validation(context, null);
            break :blk @intFromFloat(item);
        },
        else => return validation(context, null),
    };
    return std.math.cast(T, integer) orelse validation(context, null);
}

fn parseFloat(comptime T: type, value: std.json.Value, context: ?*ParseContext) ParseError!T {
    const result: T = switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| @floatCast(item),
        .number_string => |item| std.fmt.parseFloat(T, item) catch
            return validation(context, null),
        else => return validation(context, null),
    };
    if (!std.math.isFinite(result)) return validation(context, null);
    return result;
}

fn parseTimestamp(
    comptime T: type,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!T {
    if (comptime T == ?i64) {
        if (value == .null) return null;
    }
    const text = switch (value) {
        .string => |item| item,
        else => return validation(context, "timestamp"),
    };
    const parsed = iso8601.parse(text) catch return validation(context, "timestamp");
    return parsed;
}

fn parseBinaryData(
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!shared.BinaryData {
    return switch (value) {
        .string => |item| .{ .base64 = try arena.dupe(u8, item) },
        .array => .{ .bytes = try parseBytes(arena, value, context) },
        else => validation(context, null),
    };
}

fn parseBytes(
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError![]const u8 {
    switch (value) {
        .string => |encoded| {
            const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return validation(context, null);
            const result = try arena.alloc(u8, size);
            std.base64.standard.Decoder.decode(result, encoded) catch
                return validation(context, null);
            return result;
        },
        .array => |array| {
            const result = try arena.alloc(u8, array.items.len);
            for (array.items, result) |item, *destination| {
                destination.* = try parseInteger(u8, item, context);
            }
            return result;
        },
        else => return validation(context, null),
    }
}

fn parseHeaders(
    arena: std.mem.Allocator,
    value: std.json.Value,
    context: ?*ParseContext,
) ParseError!shared.Headers {
    const object = switch (value) {
        .object => |item| item,
        else => return validation(context, null),
    };
    const result = try arena.alloc(shared.Header, object.count());
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const header_value = switch (entry.value_ptr.*) {
            .string => |item| item,
            else => return validation(context, entry.key_ptr.*),
        };
        result[index] = .{
            .name = try arena.dupe(u8, entry.key_ptr.*),
            .value = try arena.dupe(u8, header_value),
        };
    }
    return result;
}

fn validateProviderReference(value: std.json.Value, context: ?*ParseContext) ParseError!void {
    const object = switch (value) {
        .object => |item| item,
        else => return validation(context, null),
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type")) return validation(context, "type");
        if (entry.value_ptr.* != .string) return validation(context, entry.key_ptr.*);
    }
}

fn writeInternal(comptime T: type, value: T, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    if (comptime hasDecl(T, "wireWrite")) return T.wireWrite(value, writer);
    if (comptime T == std.json.Value) return writer.write(value);
    if (comptime T == shared.BinaryData) return writeBinaryData(value, writer);
    if (comptime T == shared.Headers) return writeHeaders(value, writer);

    switch (@typeInfo(T)) {
        .optional => if (value) |item|
            try writeInternal(@TypeOf(item), item, writer)
        else
            try writer.write(null),
        .bool, .int, .float => try writer.write(value),
        .@"enum" => try writeEnum(T, value, writer),
        .pointer => |pointer| try writePointer(T, pointer, value, writer),
        .@"struct" => {
            try writer.beginObject();
            try writeStructFields(T, value, writer);
            try writer.endObject();
        },
        .@"union" => {
            try writer.beginObject();
            try writeUnionFields(T, value, writer);
            try writer.endObject();
        },
        else => @compileError("provider wire writer does not support " ++ @typeName(T)),
    }
}

fn writePointer(
    comptime T: type,
    comptime pointer: std.builtin.Type.Pointer,
    value: T,
    writer: *std.json.Stringify,
) std.Io.Writer.Error!void {
    if (pointer.size != .slice) {
        @compileError("provider wire writer only supports pointer slices: " ++ @typeName(T));
    }
    if (pointer.child == u8) return writer.write(value);
    try writer.beginArray();
    for (value) |item| try writeInternal(pointer.child, item, writer);
    try writer.endArray();
}

fn writeStructFields(
    comptime T: type,
    value: T,
    writer: *std.json.Stringify,
) std.Io.Writer.Error!void {
    inline for (std.meta.fields(T)) |field| {
        if (comptime @typeInfo(field.type) == .optional) {
            if (@field(value, field.name) != null) {
                try writeStructField(T, field, value, writer);
            }
        } else {
            try writeStructField(T, field, value, writer);
        }
    }
}

fn writeStructField(
    comptime T: type,
    comptime field: std.builtin.Type.StructField,
    value: T,
    writer: *std.json.Stringify,
) std.Io.Writer.Error!void {
    try writer.objectField(fieldWireName(T, field.name));
    if (comptime isTimestampField(field.name, field.type)) {
        const timestamp = if (comptime field.type == ?i64)
            @field(value, field.name).?
        else
            @field(value, field.name);
        var buffer: [24]u8 = undefined;
        try writer.write(iso8601.format(timestamp, &buffer));
    } else if (comptime T == video.VideoData.Bytes and std.mem.eql(u8, field.name, "data")) {
        try writeBase64(@field(value, field.name), writer);
    } else {
        try writeInternal(field.type, @field(value, field.name), writer);
    }
}

fn writeUnionFields(
    comptime T: type,
    value: T,
    writer: *std.json.Stringify,
) std.Io.Writer.Error!void {
    assertUnionTagTable(T);
    const union_info = @typeInfo(T).@"union";
    const Tag = union_info.tag_type.?;
    const active = std.meta.activeTag(value);

    inline for (T.wire_tags) |mapping| {
        const mapped_tag: Tag = mapping[0];
        if (active == mapped_tag) {
            try writer.objectField(T.wire_tag_field);
            try writer.write(mapping[1]);
            inline for (union_info.fields) |field| {
                if (mapped_tag == @field(Tag, field.name)) {
                    const payload = @field(value, field.name);
                    switch (@typeInfo(field.type)) {
                        .@"struct" => try writeStructFields(field.type, payload, writer),
                        .@"union" => try writeUnionFields(field.type, payload, writer),
                        else => @compileError(
                            "internally tagged union payload must be a struct or tagged union: " ++
                                @typeName(field.type),
                        ),
                    }
                    return;
                }
            }
            unreachable;
        }
    }
    unreachable;
}

fn writeEnum(
    comptime T: type,
    value: T,
    writer: *std.json.Stringify,
) std.Io.Writer.Error!void {
    if (comptime hasDecl(T, "wire_values")) {
        assertEnumValueTable(T);
        inline for (T.wire_values) |mapping| {
            const mapped: T = mapping[0];
            if (value == mapped) return writer.write(mapping[1]);
        }
        unreachable;
    }
    return writer.write(@tagName(value));
}

fn writeBinaryData(value: shared.BinaryData, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    switch (value) {
        .bytes => |bytes| try writeBase64(bytes, writer),
        .base64 => |base64| try writer.write(base64),
    }
}

fn writeBase64(bytes: []const u8, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    try writer.beginWriteRaw();
    try writer.writer.writeByte('"');
    try std.base64.standard.Encoder.encodeWriter(writer.writer, bytes);
    try writer.writer.writeByte('"');
    writer.endWriteRaw();
}

fn writeHeaders(headers: shared.Headers, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    try writer.beginObject();
    for (headers) |header| {
        try writer.objectField(header.name);
        try writer.write(header.value);
    }
    try writer.endObject();
}

fn cloneJsonValue(arena: std.mem.Allocator, value: std.json.Value) ParseError!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{ .number_string = try arena.dupe(u8, item) },
        .string => |item| .{ .string = try arena.dupe(u8, item) },
        .array => |item| blk: {
            var array = std.json.Array.init(arena);
            for (item.items) |element| try array.append(try cloneJsonValue(arena, element));
            break :blk .{ .array = array };
        },
        .object => |item| blk: {
            var object: std.json.ObjectMap = .empty;
            var iterator = item.iterator();
            while (iterator.next()) |entry| {
                try object.put(
                    arena,
                    try arena.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(arena, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = object };
        },
    };
}

fn assertUnionTagTable(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(20_000);
        const union_info = @typeInfo(T).@"union";
        const Tag = union_info.tag_type orelse
            @compileError("wire union must be tagged: " ++ @typeName(T));
        if (!@hasDecl(T, "wire_tag_field") or !@hasDecl(T, "wire_tags")) {
            @compileError("wire union lacks wire_tag_field/wire_tags: " ++ @typeName(T));
        }
        if (T.wire_tags.len != union_info.fields.len) {
            @compileError("wire tag count does not match union variants: " ++ @typeName(T));
        }
        for (union_info.fields) |field| {
            var matches: usize = 0;
            for (T.wire_tags) |mapping| {
                const mapped: Tag = mapping[0];
                if (mapped == @field(Tag, field.name)) matches += 1;
            }
            if (matches != 1) {
                @compileError("wire union variant lacks exactly one tag mapping: " ++
                    @typeName(T) ++ "." ++ field.name);
            }
        }
        for (T.wire_tags, 0..) |left, left_index| {
            for (T.wire_tags, 0..) |right, right_index| {
                if (left_index < right_index and std.mem.eql(u8, left[1], right[1])) {
                    @compileError("wire union has duplicate tag string: " ++ @typeName(T));
                }
            }
        }
    }
}

fn assertEnumValueTable(comptime T: type) void {
    comptime {
        if (T.wire_values.len != std.meta.fields(T).len) {
            @compileError("wire enum value count does not match enum fields: " ++ @typeName(T));
        }
        for (std.meta.fields(T)) |field| {
            var matches: usize = 0;
            for (T.wire_values) |mapping| {
                const mapped: T = mapping[0];
                if (mapped == @field(T, field.name)) matches += 1;
            }
            if (matches != 1) {
                @compileError("wire enum field lacks exactly one value mapping: " ++
                    @typeName(T) ++ "." ++ field.name);
            }
        }
    }
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
            var input_index: usize = 0;
            var output_index: usize = 0;
            var uppercase = false;
            while (input_index < name.len) : (input_index += 1) {
                const byte = name[input_index];
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

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

fn isTimestampField(comptime name: []const u8, comptime T: type) bool {
    return std.mem.eql(u8, name, "timestamp_ms") and (T == i64 or T == ?i64);
}

fn isProviderReferenceField(comptime T: type, comptime name: []const u8) bool {
    if (T == shared.FileData.Reference) return std.mem.eql(u8, name, "reference");
    if (T == files_module.UploadFileResult or T == skills_module.UploadSkillResult) {
        return std.mem.eql(u8, name, "provider_reference");
    }
    return false;
}

fn markField(context: ?*ParseContext, field: []const u8) void {
    if (context) |ctx| if (ctx.field == null) {
        ctx.field = field;
    };
}

fn validation(context: ?*ParseContext, field: ?[]const u8) errors.Error {
    if (field) |name| markField(context, name);
    return error.TypeValidationError;
}

fn parseJsonText(
    comptime T: type,
    arena: std.mem.Allocator,
    json_text: []const u8,
    diag: ?*errors.Diagnostics,
) !T {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            setJsonParseDiagnostics(diag, json_text);
            return error.JSONParseError;
        },
    };
    var context: ParseContext = .{};
    return parseInternal(T, arena, value, &context) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            setValidationDiagnostics(diag, json_text, context.field);
            return err;
        },
    };
}

fn setJsonParseDiagnostics(diag: ?*errors.Diagnostics, text: []const u8) void {
    const value = diag orelse return;
    errors.Diagnostics.set(diag, value.allocator, .{ .json_parse = .{
        .message = "invalid provider wire JSON",
        .text = text,
    } });
}

fn setValidationDiagnostics(
    diag: ?*errors.Diagnostics,
    text: []const u8,
    field: ?[]const u8,
) void {
    const value = diag orelse return;
    errors.Diagnostics.set(diag, value.allocator, .{ .type_validation = .{
        .message = "provider wire value failed type validation",
        .value_json = text,
        .context = if (field) |name| .{ .field = name } else null,
    } });
}

/// Canonical language stream-part parser.
pub fn parseStreamPart(arena: std.mem.Allocator, json_text: []const u8) !language.StreamPart {
    return parseStreamPartWithDiagnostics(arena, json_text, null);
}

/// Canonical language stream-part parser with diagnostic payloads.
pub fn parseStreamPartWithDiagnostics(
    arena: std.mem.Allocator,
    json_text: []const u8,
    diag: ?*errors.Diagnostics,
) !language.StreamPart {
    return parseJsonText(language.StreamPart, arena, json_text, diag) catch |err| switch (err) {
        error.UnknownUnionTag => {
            if (diag) |value| errors.Diagnostics.set(diag, value.allocator, .{ .invalid_stream_part = .{
                .message = "unknown language model stream part type",
                .chunk_json = json_text,
            } });
            return error.InvalidStreamPartError;
        },
        else => return err,
    };
}

pub fn writeStreamPart(value: language.StreamPart, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseCallOptions(arena: std.mem.Allocator, json_text: []const u8) !language.CallOptions {
    return parseJsonText(language.CallOptions, arena, json_text, null);
}

pub fn writeCallOptions(value: language.CallOptions, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parsePrompt(arena: std.mem.Allocator, json_text: []const u8) !language.Prompt {
    return parseJsonText(language.Prompt, arena, json_text, null);
}

pub fn writePrompt(value: language.Prompt, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseMessage(arena: std.mem.Allocator, json_text: []const u8) !language.Message {
    return parseJsonText(language.Message, arena, json_text, null);
}

pub fn writeMessage(value: language.Message, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseContent(arena: std.mem.Allocator, json_text: []const u8) !language.Content {
    return parseJsonText(language.Content, arena, json_text, null);
}

pub fn writeContent(value: language.Content, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseGenerateResult(arena: std.mem.Allocator, json_text: []const u8) !language.GenerateResult {
    return parseJsonText(language.GenerateResult, arena, json_text, null);
}

pub fn writeGenerateResult(value: language.GenerateResult, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseClientEvent(arena: std.mem.Allocator, json_text: []const u8) !realtime.ClientEvent {
    return parseJsonText(realtime.ClientEvent, arena, json_text, null);
}

pub fn writeClientEvent(value: realtime.ClientEvent, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseServerEvent(arena: std.mem.Allocator, json_text: []const u8) !realtime.ServerEvent {
    return parseJsonText(realtime.ServerEvent, arena, json_text, null);
}

pub fn writeServerEvent(value: realtime.ServerEvent, writer: *std.Io.Writer) !void {
    return writeValue(value, writer);
}

pub fn parseTranscriptionStreamPart(
    arena: std.mem.Allocator,
    json_text: []const u8,
) !transcription.StreamPart {
    return parseJsonText(transcription.StreamPart, arena, json_text, null);
}

pub fn writeTranscriptionStreamPart(
    value: transcription.StreamPart,
    writer: *std.Io.Writer,
) !void {
    return writeValue(value, writer);
}

test "wire generic snake to camel conversion" {
    try std.testing.expectEqualStrings("toolCallId", camelCase("tool_call_id"));
    try std.testing.expectEqualStrings("providerOptions", camelCase("provider_options"));
}
