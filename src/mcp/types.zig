//! Loose MCP result payloads.
//!
//! Unknown fields are tolerated deliberately. This contrasts with the strict
//! JSON-RPC envelope in `json_rpc.zig` and preserves MCP extension points.

const std = @import("std");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const LATEST_PROTOCOL_VERSION = "2025-11-25";
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    LATEST_PROTOCOL_VERSION,
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

pub fn isSupportedProtocolVersion(version: []const u8) bool {
    for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.eql(u8, supported, version)) return true;
    }
    return false;
}

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
};

pub const ServerCapabilities = struct {
    experimental: ?std.json.Value = null,
    logging: ?std.json.Value = null,
    completions: ?std.json.Value = null,
    prompts: ?std.json.Value = null,
    resources: ?std.json.Value = null,
    tools: ?std.json.Value = null,
    elicitation: ?std.json.Value = null,
};

pub const ClientCapabilities = struct {
    elicitation: ?std.json.Value = null,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
    instructions: ?[]const u8 = null,
};

pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
};

pub const Tool = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
    outputSchema: ?std.json.Value = null,
    annotations: ?ToolAnnotations = null,
    _meta: ?std.json.Value = null,

    pub fn resolvedTitle(self: Tool) ?[]const u8 {
        return self.title orelse if (self.annotations) |annotations| annotations.title else null;
    }
};

pub const ListToolsResult = struct {
    tools: []const Tool,
    nextCursor: ?[]const u8 = null,
};

pub const Content = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    resource: ?std.json.Value = null,
    uri: ?[]const u8 = null,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const CallToolResult = union(enum) {
    content: ContentResult,
    tool_result: ToolResult,

    pub const ContentResult = struct {
        raw: std.json.Value,
        parts: []const Content,
        structured_content: ?std.json.Value = null,
        is_error: bool = false,
    };

    pub const ToolResult = struct {
        raw: std.json.Value,
        value: std.json.Value,
    };

    pub fn rawValue(self: CallToolResult) std.json.Value {
        return switch (self) {
            .content => |result| result.raw,
            .tool_result => |result| result.raw,
        };
    }

    pub fn contentParts(self: CallToolResult) ?[]const Content {
        return switch (self) {
            .content => |result| result.parts,
            .tool_result => null,
        };
    }

    pub fn structuredContent(self: CallToolResult) ?std.json.Value {
        return switch (self) {
            .content => |result| result.structured_content,
            .tool_result => null,
        };
    }

    pub fn isError(self: CallToolResult) bool {
        return switch (self) {
            .content => |result| result.is_error,
            .tool_result => false,
        };
    }
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    size: ?std.json.Value = null,
};

pub const ListResourcesResult = struct {
    resources: []const Resource,
    nextCursor: ?[]const u8 = null,
};

pub const ResourceContents = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
};

pub const ReadResourceResult = struct {
    contents: []const ResourceContents,
};

pub const ResourceTemplate = struct {
    uriTemplate: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const ListResourceTemplatesResult = struct {
    resourceTemplates: []const ResourceTemplate,
};

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
};

pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    nextCursor: ?[]const u8 = null,
};

pub const PromptMessage = struct {
    role: []const u8,
    content: Content,
};

pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
};

pub const CompleteResult = struct {
    completion: Completion,

    pub const Completion = struct {
        values: []const []const u8,
        total: ?i64 = null,
        hasMore: ?bool = null,
    };
};

pub const ElicitResult = struct {
    action: Action,
    content: ?std.json.Value = null,

    pub const Action = enum { accept, decline, cancel };
};

pub const ParseError = Allocator.Error || error{InvalidResult};

pub fn parseInitializeResult(arena: Allocator, value: std.json.Value) ParseError!InitializeResult {
    const result = try parseLoose(InitializeResult, arena, value);
    inline for (.{
        result.capabilities.experimental,
        result.capabilities.logging,
        result.capabilities.completions,
        result.capabilities.prompts,
        result.capabilities.resources,
        result.capabilities.tools,
        result.capabilities.elicitation,
    }) |capability| {
        if (capability) |item| if (item != .object) return error.InvalidResult;
    }
    return result;
}

pub fn parseListToolsResult(arena: Allocator, value: std.json.Value) ParseError!ListToolsResult {
    const result = try parseLoose(ListToolsResult, arena, value);
    for (result.tools) |tool| {
        if (tool.inputSchema != .object) return error.InvalidResult;
        const schema_type = tool.inputSchema.object.get("type") orelse return error.InvalidResult;
        if (schema_type != .string or !std.mem.eql(u8, schema_type.string, "object")) {
            return error.InvalidResult;
        }
        if (tool.inputSchema.object.get("properties")) |properties| {
            if (properties != .object) return error.InvalidResult;
        }
        if (tool.outputSchema) |output_schema| if (output_schema != .object) return error.InvalidResult;
        if (tool._meta) |meta| if (meta != .object) return error.InvalidResult;
    }
    return result;
}

pub fn parseCallToolResult(arena: Allocator, value: std.json.Value) ParseError!CallToolResult {
    const raw = try provider_utils.cloneJsonValue(arena, value);
    if (raw != .object) return error.InvalidResult;
    const object = raw.object;
    if (object.get("toolResult")) |tool_result| {
        return .{ .tool_result = .{ .raw = raw, .value = tool_result } };
    }
    const content_value = object.get("content") orelse return error.InvalidResult;
    const content = try parseLoose([]const Content, arena, content_value);
    for (content) |part| try validateContent(arena, part);
    const is_error = if (object.get("isError")) |item| switch (item) {
        .bool => |flag| flag,
        else => return error.InvalidResult,
    } else false;
    return .{ .content = .{
        .raw = raw,
        .parts = content,
        .structured_content = object.get("structuredContent"),
        .is_error = is_error,
    } };
}

pub fn parseListResourcesResult(arena: Allocator, value: std.json.Value) ParseError!ListResourcesResult {
    const result = try parseLoose(ListResourcesResult, arena, value);
    for (result.resources) |resource| if (resource.size) |size| switch (size) {
        .integer, .float => {},
        else => return error.InvalidResult,
    };
    return result;
}

pub fn parseReadResourceResult(arena: Allocator, value: std.json.Value) ParseError!ReadResourceResult {
    const result = try parseLoose(ReadResourceResult, arena, value);
    for (result.contents) |content| {
        if ((content.text == null) == (content.blob == null)) return error.InvalidResult;
        if (content.blob) |blob| try validateBase64(arena, blob);
    }
    return result;
}

pub fn parseListResourceTemplatesResult(arena: Allocator, value: std.json.Value) ParseError!ListResourceTemplatesResult {
    return parseLoose(ListResourceTemplatesResult, arena, value);
}

pub fn parseListPromptsResult(arena: Allocator, value: std.json.Value) ParseError!ListPromptsResult {
    return parseLoose(ListPromptsResult, arena, value);
}

pub fn parseGetPromptResult(arena: Allocator, value: std.json.Value) ParseError!GetPromptResult {
    const result = try parseLoose(GetPromptResult, arena, value);
    for (result.messages) |message| {
        if (!std.mem.eql(u8, message.role, "user") and !std.mem.eql(u8, message.role, "assistant")) {
            return error.InvalidResult;
        }
        try validateContent(arena, message.content);
    }
    return result;
}

pub fn parseCompleteResult(arena: Allocator, value: std.json.Value) ParseError!CompleteResult {
    const result = try parseLoose(CompleteResult, arena, value);
    if (result.completion.values.len > 100) return error.InvalidResult;
    return result;
}

pub fn parseElicitResult(arena: Allocator, value: std.json.Value) ParseError!ElicitResult {
    const result = try parseLoose(ElicitResult, arena, value);
    if (result.content) |content| if (content != .object) return error.InvalidResult;
    return result;
}

fn validateContent(arena: Allocator, part: Content) ParseError!void {
    if (std.mem.eql(u8, part.type, "text")) {
        if (part.text == null) return error.InvalidResult;
        return;
    }
    if (std.mem.eql(u8, part.type, "image")) {
        const data = part.data orelse return error.InvalidResult;
        if (part.mimeType == null) return error.InvalidResult;
        return validateBase64(arena, data);
    }
    if (std.mem.eql(u8, part.type, "resource")) {
        if (part.resource == null or part.resource.? != .object) return error.InvalidResult;
        return;
    }
    if (std.mem.eql(u8, part.type, "resource_link")) {
        if (part.uri == null or part.name == null) return error.InvalidResult;
        return;
    }
    return error.InvalidResult;
}

fn validateBase64(arena: Allocator, encoded: []const u8) ParseError!void {
    _ = provider_utils.decodeBase64(arena, encoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResult,
    };
}

fn parseLoose(comptime T: type, arena: Allocator, value: std.json.Value) ParseError!T {
    return std.json.parseFromValueLeaky(T, arena, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResult,
    };
}

test "loose initialize and tools payloads preserve extensions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const initialize_value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{},\"futureCapability\":{}},\"serverInfo\":{\"name\":\"echo\",\"version\":\"1\",\"future\":true},\"futureTopLevel\":1}",
        .{},
    );
    const initialize = try parseInitializeResult(arena, initialize_value);
    try std.testing.expectEqualStrings("echo", initialize.serverInfo.name);
    try std.testing.expect(initialize.capabilities.tools != null);

    const tools_value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"tools\":[{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"future\":1},\"futureToolField\":true}],\"futureResultField\":true}",
        .{},
    );
    const tools = try parseListToolsResult(arena, tools_value);
    try std.testing.expectEqualStrings("echo", tools.tools[0].name);
}

test "loose CallToolResult validates known content variants and retains raw JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"content\":[{\"type\":\"text\",\"text\":\"ok\",\"extension\":1},{\"type\":\"image\",\"data\":\"YQ==\",\"mimeType\":\"image/png\"}],\"structuredContent\":{\"ok\":true},\"isError\":false,\"future\":true}",
        .{},
    );
    const result = try parseCallToolResult(arena, value);
    try std.testing.expect(result == .content);
    try std.testing.expectEqual(2, result.content.parts.len);
    try std.testing.expect(result.rawValue().object.get("future") != null);
    try std.testing.expect(result.structuredContent() != null);

    const legacy_value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"toolResult\":{\"legacy\":true},\"extension\":1}",
        .{},
    );
    const legacy = try parseCallToolResult(arena, legacy_value);
    try std.testing.expect(legacy == .tool_result);
    try std.testing.expect(legacy.tool_result.value.object.get("legacy").?.bool);
}

test "MCP payload validators reject malformed required fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad_tool = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"tools\":[{\"name\":\"x\",\"inputSchema\":{\"type\":\"string\"}}]}",
        .{},
    );
    try std.testing.expectError(error.InvalidResult, parseListToolsResult(arena, bad_tool));

    const bad_content = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"content\":[{\"type\":\"image\",\"data\":\"YQ==\"}]}",
        .{},
    );
    try std.testing.expectError(error.InvalidResult, parseCallToolResult(arena, bad_content));
}
