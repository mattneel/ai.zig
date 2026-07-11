const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;

pub const Prepared = struct {
    tools: ?std.json.Value,
    tool_config: ?std.json.Value,
    warnings: []const provider.Warning,
};

pub fn prepare(
    arena: Allocator,
    input_tools: ?[]const provider.Tool,
    tool_choice: ?provider.ToolChoice,
    model_id: []const u8,
) Allocator.Error!Prepared {
    const input = input_tools orelse return .{ .tools = null, .tool_config = null, .warnings = &.{} };
    if (input.len == 0) return .{ .tools = null, .tool_config = null, .warnings = &.{} };

    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var has_functions = false;
    var has_provider_tools = false;
    for (input) |tool| switch (tool) {
        .function => has_functions = true,
        .provider => has_provider_tools = true,
    };

    const gemini3 = contains(model_id, "gemini-3");
    if (has_functions and has_provider_tools and !gemini3) try warnings.append(arena, .{ .unsupported = .{
        .feature = "combination of function and provider-defined tools",
    } });

    var provider_items = std.json.Array.init(arena);
    if (has_provider_tools) for (input) |tool| switch (tool) {
        .function => {},
        .provider => |value| if (try providerTool(arena, value, model_id, &warnings)) |converted| {
            try provider_items.append(converted);
        },
    };

    if (has_provider_tools and (!has_functions or !gemini3)) {
        return .{
            .tools = if (provider_items.items.len == 0) null else .{ .array = provider_items },
            .tool_config = null,
            .warnings = try warnings.toOwnedSlice(arena),
        };
    }

    var declarations = std.json.Array.init(arena);
    var has_strict = false;
    for (input) |tool| switch (tool) {
        .provider => {},
        .function => |function| {
            var declaration: std.json.ObjectMap = .empty;
            try putString(&declaration, arena, "name", function.name);
            try putString(&declaration, arena, "description", function.description orelse "");
            if (try schema.convert(arena, function.input_schema)) |parameters| {
                try declaration.put(arena, "parameters", parameters);
            }
            try declarations.append(.{ .object = declaration });
            has_strict = has_strict or (function.strict orelse false);
        },
    };

    var declaration_wrapper: std.json.ObjectMap = .empty;
    try declaration_wrapper.put(arena, "functionDeclarations", .{ .array = declarations });
    try provider_items.append(.{ .object = declaration_wrapper });

    const mode = switch (tool_choice orelse provider.ToolChoice{ .auto = .{} }) {
        .auto => if (has_strict or (has_provider_tools and gemini3)) "VALIDATED" else "AUTO",
        .none => "NONE",
        .required => if (has_strict) "VALIDATED" else "ANY",
        .tool => if (has_strict) "VALIDATED" else "ANY",
    };
    var function_config: std.json.ObjectMap = .empty;
    try putString(&function_config, arena, "mode", mode);
    if (tool_choice) |choice| switch (choice) {
        .tool => |named| {
            var names = std.json.Array.init(arena);
            try names.append(.{ .string = try arena.dupe(u8, named.tool_name) });
            try function_config.put(arena, "allowedFunctionNames", .{ .array = names });
        },
        else => {},
    };
    var config: std.json.ObjectMap = .empty;
    try config.put(arena, "functionCallingConfig", .{ .object = function_config });
    if (has_provider_tools and gemini3) try config.put(arena, "includeServerSideToolInvocations", .{ .bool = true });

    const should_emit_config = tool_choice != null or has_strict or (has_provider_tools and gemini3);
    return .{
        .tools = .{ .array = provider_items },
        .tool_config = if (should_emit_config) .{ .object = config } else null,
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn providerTool(
    arena: Allocator,
    tool: provider.ProviderTool,
    model_id: []const u8,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!?std.json.Value {
    const modern = contains(model_id, "gemini-2") or contains(model_id, "gemini-3") or
        contains(model_id, "nano-banana") or std.mem.endsWith(u8, model_id, "-latest");
    const file_search = contains(model_id, "gemini-2.5") or contains(model_id, "gemini-3");
    var object: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, tool.id, "google.google_search")) {
        if (!modern) return unsupportedProviderTool(arena, warnings, tool.id, "Google Search requires Gemini 2.0 or newer.");
        try object.put(arena, "googleSearch", try provider_utils.cloneJsonValue(arena, tool.args));
    } else if (std.mem.eql(u8, tool.id, "google.enterprise_web_search")) {
        if (!modern) return unsupportedProviderTool(arena, warnings, tool.id, "Enterprise Web Search requires Gemini 2.0 or newer.");
        try object.put(arena, "enterpriseWebSearch", .{ .object = .empty });
    } else if (std.mem.eql(u8, tool.id, "google.url_context")) {
        if (!modern) return unsupportedProviderTool(arena, warnings, tool.id, "URL context requires Gemini 2.0 or newer.");
        try object.put(arena, "urlContext", .{ .object = .empty });
    } else if (std.mem.eql(u8, tool.id, "google.code_execution")) {
        if (!modern) return unsupportedProviderTool(arena, warnings, tool.id, "Code execution requires Gemini 2.0 or newer.");
        try object.put(arena, "codeExecution", .{ .object = .empty });
    } else if (std.mem.eql(u8, tool.id, "google.file_search")) {
        if (!file_search) return unsupportedProviderTool(arena, warnings, tool.id, "File Search requires Gemini 2.5 or newer.");
        try object.put(arena, "fileSearch", try provider_utils.cloneJsonValue(arena, tool.args));
    } else if (std.mem.eql(u8, tool.id, "google.google_maps")) {
        if (!modern) return unsupportedProviderTool(arena, warnings, tool.id, "Google Maps requires Gemini 2.0 or newer.");
        try object.put(arena, "googleMaps", .{ .object = .empty });
    } else {
        try warnings.append(arena, .{ .unsupported = .{
            .feature = try std.fmt.allocPrint(arena, "provider-defined tool {s}", .{tool.id}),
        } });
        return null;
    }
    return .{ .object = object };
}

fn unsupportedProviderTool(
    arena: Allocator,
    warnings: *std.ArrayList(provider.Warning),
    id: []const u8,
    details: []const u8,
) Allocator.Error!?std.json.Value {
    try warnings.append(arena, .{ .unsupported = .{
        .feature = try std.fmt.allocPrint(arena, "provider-defined tool {s}", .{id}),
        .details = details,
    } });
    return null;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

test "Google tools map function declarations and named tool choice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema_value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}
    , .{});
    const input = [_]provider.Tool{.{ .function = .{ .name = "test-tool", .input_schema = schema_value } }};
    const prepared = try prepare(arena, &input, .{ .tool = .{ .tool_name = "test-tool" } }, "gemini-2.5-flash");
    const declaration = prepared.tools.?.array.items[0].object.get("functionDeclarations").?.array.items[0].object;
    try std.testing.expectEqualStrings("test-tool", declaration.get("name").?.string);
    const config = prepared.tool_config.?.object.get("functionCallingConfig").?.object;
    try std.testing.expectEqualStrings("ANY", config.get("mode").?.string);
    try std.testing.expectEqualStrings("test-tool", config.get("allowedFunctionNames").?.array.items[0].string);
}

test "Google strict tools select VALIDATED mode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\"}", .{});
    const input = [_]provider.Tool{.{ .function = .{ .name = "strict-tool", .input_schema = schema_value, .strict = true } }};
    const prepared = try prepare(arena, &input, null, "gemini-3-pro-preview");
    try std.testing.expectEqualStrings(
        "VALIDATED",
        prepared.tool_config.?.object.get("functionCallingConfig").?.object.get("mode").?.string,
    );
}

test "Google Gemini 3 combines native and function tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const input = [_]provider.Tool{
        .{ .provider = .{ .id = "google.google_search", .name = "google_search", .args = args } },
        .{ .function = .{ .name = "lookup", .input_schema = schema_value } },
    };
    const prepared = try prepare(arena, &input, null, "gemini-3-pro-preview");
    try std.testing.expectEqual(2, prepared.tools.?.array.items.len);
    try std.testing.expectEqual(true, prepared.tool_config.?.object.get("includeServerSideToolInvocations").?.bool);
}
