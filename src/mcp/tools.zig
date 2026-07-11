//! Lowers MCP server tool definitions into the runtime `ai.NamedTool` shape.

const std = @import("std");
const ai = @import("ai");
const provider_utils = @import("provider_utils");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const Caller = struct {
    ctx: *anyopaque,
    call_fn: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        arena: Allocator,
        name: []const u8,
        arguments: std.json.Value,
    ) anyerror!std.json.Value,

    pub fn call(
        self: Caller,
        io: std.Io,
        arena: Allocator,
        name: []const u8,
        arguments: std.json.Value,
    ) anyerror!std.json.Value {
        return self.call_fn(self.ctx, io, arena, name, arguments);
    }
};

pub const ExplicitSchema = struct {
    name: []const u8,
    input_schema: provider_utils.Schema,
    output_schema: ?provider_utils.Schema = null,
};

pub const Schemas = union(enum) {
    automatic,
    explicit: []const ExplicitSchema,
};

pub const Options = struct {
    schemas: Schemas = .automatic,
    client_name: []const u8 = "ai-sdk-zig-mcp-client",
};

const ExecuteContext = struct {
    caller: Caller,
    name: []const u8,
    output_schema: ?provider_utils.Schema,

    fn execute(
        raw: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        const self: *ExecuteContext = @ptrCast(@alignCast(raw.?));
        const result_value = try self.caller.call(io, arena, self.name, input);
        const result = try types.parseCallToolResult(arena, result_value);
        if (result.isError()) return .{ .value = result.rawValue() };

        const output_schema = self.output_schema orelse return .{ .value = result.rawValue() };
        if (result.structuredContent()) |structured| {
            try validateOutput(output_schema, arena, structured);
            return .{ .value = try provider_utils.cloneJsonValue(arena, structured) };
        }
        if (result.contentParts()) |content| {
            for (content) |part| {
                if (!std.mem.eql(u8, part.type, "text")) continue;
                const parsed = switch (provider_utils.safeParseJson(std.json.Value, arena, part.text.?)) {
                    .success => |success| success.value,
                    .failure => return error.InvalidToolOutput,
                };
                try validateOutput(output_schema, arena, parsed);
                return .{ .value = try provider_utils.cloneJsonValue(arena, parsed) };
            }
        }
        return error.MissingStructuredToolOutput;
    }
};

pub fn fromDefinitions(
    caller: Caller,
    arena: Allocator,
    definitions: types.ListToolsResult,
    options: Options,
) anyerror![]const ai.NamedTool {
    var result: std.ArrayList(ai.NamedTool) = .empty;
    for (definitions.tools) |definition| {
        const explicit = switch (options.schemas) {
            .automatic => null,
            .explicit => |schemas| findExplicit(schemas, definition.name) orelse continue,
        };

        const context = try arena.create(ExecuteContext);
        context.* = .{
            .caller = caller,
            .name = try arena.dupe(u8, definition.name),
            .output_schema = if (explicit) |schema| schema.output_schema else null,
        };

        const input_schema = if (explicit) |schema|
            schema.input_schema
        else blk: {
            var document = try provider_utils.cloneJsonValue(arena, definition.inputSchema);
            if (document == .object and document.object.get("properties") == null) {
                try document.object.put(arena, "properties", .{ .object = .empty });
            }
            try provider_utils.addAdditionalPropertiesToJsonSchema(arena, &document);
            break :blk provider_utils.Schema{ .document = .{ .value = document } };
        };

        try result.append(arena, .{
            .name = context.name,
            .tool = .{
                .kind = if (explicit == null) .dynamic else .function,
                .name = context.name,
                .description = if (definition.description) |description|
                    .{ .text = try arena.dupe(u8, description) }
                else
                    null,
                .input_schema = input_schema,
                .output_schema = if (explicit) |schema| schema.output_schema else null,
                .execute = .{ .ctx = context, .execute_fn = ExecuteContext.execute },
                .to_model_output = .{ .convert_fn = toModelOutput },
                .metadata = try metadataValue(arena, options.client_name, definition),
            },
        });
    }
    return result.toOwnedSlice(arena);
}

fn validateOutput(schema: provider_utils.Schema, arena: Allocator, value: std.json.Value) anyerror!void {
    if (schema.validator) |validator| try validator.validate(arena, value, null);
}

fn findExplicit(schemas: []const ExplicitSchema, name: []const u8) ?ExplicitSchema {
    for (schemas) |schema| if (std.mem.eql(u8, schema.name, name)) return schema;
    return null;
}

fn metadataValue(arena: Allocator, client_name: []const u8, definition: types.Tool) Allocator.Error!std.json.Value {
    var metadata: std.json.ObjectMap = .empty;
    try metadata.put(arena, "clientName", .{ .string = try arena.dupe(u8, client_name) });
    try metadata.put(arena, "toolName", .{ .string = try arena.dupe(u8, definition.name) });
    if (definition.resolvedTitle()) |title| {
        try metadata.put(arena, "title", .{ .string = try arena.dupe(u8, title) });
    }
    if (definition._meta) |meta| {
        try metadata.put(arena, "_meta", try provider_utils.cloneJsonValue(arena, meta));
    }
    return .{ .object = metadata };
}

fn toModelOutput(
    _: ?*anyopaque,
    arena: Allocator,
    _: []const u8,
    _: std.json.Value,
    output: std.json.Value,
) anyerror!ai.message.ToolResultOutput {
    if (output != .object) {
        return .{ .json = .{ .value = try provider_utils.cloneJsonValue(arena, output) } };
    }
    if (output.object.get("isError")) |is_error| {
        if (is_error == .bool and is_error.bool) {
            return .{ .error_json = .{ .value = try provider_utils.cloneJsonValue(arena, output) } };
        }
    }
    const content_value = output.object.get("content") orelse {
        return .{ .json = .{ .value = try provider_utils.cloneJsonValue(arena, output) } };
    };
    if (content_value != .array) {
        return .{ .json = .{ .value = try provider_utils.cloneJsonValue(arena, output) } };
    }

    const converted = try arena.alloc(ai.message.ToolResultContentPart, content_value.array.items.len);
    for (content_value.array.items, converted) |part, *destination| {
        if (part == .object) {
            const type_value = part.object.get("type");
            if (type_value != null and type_value.? == .string) {
                if (std.mem.eql(u8, type_value.?.string, "text")) {
                    const text = part.object.get("text");
                    if (text != null and text.? == .string) {
                        destination.* = .{ .text = .{ .text = try arena.dupe(u8, text.?.string) } };
                        continue;
                    }
                }
                if (std.mem.eql(u8, type_value.?.string, "image")) {
                    const data = part.object.get("data");
                    const media_type = part.object.get("mimeType");
                    if (data != null and data.? == .string and media_type != null and media_type.? == .string) {
                        destination.* = .{ .file = .{
                            .data = .{ .data = .{ .base64 = try arena.dupe(u8, data.?.string) } },
                            .media_type = try arena.dupe(u8, media_type.?.string),
                        } };
                        continue;
                    }
                }
            }
        }
        destination.* = .{ .text = .{ .text = try provider_utils.stringifyJsonValueAlloc(arena, part) } };
    }
    return .{ .content = .{ .value = converted } };
}

test "MCP model-output conversion maps text, image, unknown, empty, and error results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"image\",\"data\":\"YQ==\",\"mimeType\":\"image/png\"},{\"type\":\"resource_link\",\"uri\":\"x\",\"name\":\"x\"}]}",
        .{},
    );
    const converted = try toModelOutput(null, arena, "call", .null, value);
    try std.testing.expect(converted == .content);
    try std.testing.expect(converted.content.value[0] == .text);
    try std.testing.expect(converted.content.value[1] == .file);
    try std.testing.expectEqualStrings("image/png", converted.content.value[1].file.media_type);
    try std.testing.expect(converted.content.value[2] == .text);

    const no_content = try toModelOutput(null, arena, "call", .null, .{ .object = .empty });
    try std.testing.expect(no_content == .json);
    var error_object: std.json.ObjectMap = .empty;
    try error_object.put(arena, "isError", .{ .bool = true });
    const error_output = try toModelOutput(null, arena, "call", .null, .{ .object = error_object });
    try std.testing.expect(error_output == .error_json);
}

test "automatic MCP tools force additionalProperties false and preserve metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{\"nested\":{\"type\":\"object\"}}}", .{});
    const definitions = types.ListToolsResult{ .tools = &.{.{
        .name = "echo",
        .title = "Echo",
        .inputSchema = schema,
        ._meta = .{ .object = .empty },
    }} };
    const Dummy = struct {
        fn call(_: *anyopaque, _: std.Io, _: Allocator, _: []const u8, _: std.json.Value) anyerror!std.json.Value {
            return .{ .object = .empty };
        }
    };
    var marker: u8 = 0;
    const result = try fromDefinitions(.{ .ctx = &marker, .call_fn = Dummy.call }, arena, definitions, .{});
    try std.testing.expectEqual(1, result.len);
    try std.testing.expect(result[0].tool.kind == .dynamic);
    const document = result[0].tool.input_schema.document.value;
    try std.testing.expect(!document.object.get("additionalProperties").?.bool);
    const nested = document.object.get("properties").?.object.get("nested").?;
    try std.testing.expect(!nested.object.get("additionalProperties").?.bool);
    try std.testing.expectEqualStrings("ai-sdk-zig-mcp-client", result[0].tool.metadata.?.object.get("clientName").?.string);
    try std.testing.expectEqualStrings("Echo", result[0].tool.metadata.?.object.get("title").?.string);
    try std.testing.expect(result[0].tool.metadata.?.object.get("_meta") != null);
}

test "explicit MCP schemas select named tools and validate structured output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const server_schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\"}", .{});
    const definitions = types.ListToolsResult{ .tools = &.{
        .{ .name = "typed", .inputSchema = server_schema },
        .{ .name = "not-selected", .inputSchema = server_schema },
    } };
    const Dummy = struct {
        fn call(_: *anyopaque, _: std.Io, result_arena: Allocator, _: []const u8, _: std.json.Value) anyerror!std.json.Value {
            var structured: std.json.ObjectMap = .empty;
            try structured.put(result_arena, "ok", .{ .bool = true });
            var result: std.json.ObjectMap = .empty;
            try result.put(result_arena, "content", .{ .array = .init(result_arena) });
            try result.put(result_arena, "structuredContent", .{ .object = structured });
            return .{ .object = result };
        }
    };
    var marker: u8 = 0;
    const selected = try fromDefinitions(.{ .ctx = &marker, .call_fn = Dummy.call }, arena, definitions, .{
        .schemas = .{ .explicit = &.{.{
            .name = "typed",
            .input_schema = provider_utils.schemaFromType(struct { value: []const u8 }),
            .output_schema = provider_utils.schemaFromType(struct { ok: bool }),
        }} },
    });
    try std.testing.expectEqual(1, selected.len);
    try std.testing.expect(selected[0].tool.kind == .function);
    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "value", .{ .string = "x" });
    const output = try selected[0].tool.execute.?.execute(std.testing.io, arena, .{ .object = input }, .{
        .tool_call_id = "call",
        .messages = &.{},
    });
    try std.testing.expect(output == .value);
    try std.testing.expect(output.value.object.get("ok").?.bool);
}
