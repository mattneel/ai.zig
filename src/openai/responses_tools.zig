//! OpenAI Responses tool lowering.
//!
//! Ported from
//! `packages/openai/src/responses/openai-responses-prepare-tools.ts`.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const options_api = @import("options.zig");

const Allocator = std.mem.Allocator;
pub const PrepareError = provider.Error || Allocator.Error;

pub const PreparedTools = struct {
    tools: ?std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    warnings: []const provider.Warning,
    custom_provider_tool_names: []const []const u8 = &.{},
};

pub fn prepareResponsesTools(
    arena: Allocator,
    tools: ?[]const provider.Tool,
    tool_choice: ?provider.ToolChoice,
    allowed_tools: ?options_api.AllowedTools,
    diag: ?*provider.Diagnostics,
) PrepareError!PreparedTools {
    const input = tools orelse return .{ .warnings = &.{} };
    if (input.len == 0) return .{ .warnings = &.{} };

    var output = std.json.Array.init(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var custom_names: std.ArrayList([]const u8) = .empty;
    defer custom_names.deinit(arena);
    var namespace_indices: std.StringHashMapUnmanaged(usize) = .empty;
    defer namespace_indices.deinit(arena);

    for (input) |tool| switch (tool) {
        .function => |function_tool| {
            const function = try prepareFunctionTool(arena, function_tool);
            const namespace = functionNamespace(function_tool.provider_options);
            if (namespace == null) {
                try output.append(function);
                continue;
            }

            const selected = namespace.?;
            if (namespace_indices.get(selected.name)) |index| {
                const namespace_value = &output.items[index];
                const existing_description = optionalString(namespace_value.object, "description") orelse "";
                if (!std.mem.eql(u8, existing_description, selected.description)) {
                    const functionality = try std.fmt.allocPrint(
                        arena,
                        "conflicting descriptions for OpenAI tool namespace \"{s}\"",
                        .{selected.name},
                    );
                    return unsupported(arena, diag, functionality);
                }
                const nested = namespace_value.object.getPtr("tools").?;
                try nested.array.append(function);
            } else {
                var nested = std.json.Array.init(arena);
                try nested.append(function);
                var namespace_object: std.json.ObjectMap = .empty;
                try putString(&namespace_object, arena, "type", "namespace");
                try putString(&namespace_object, arena, "name", selected.name);
                try putString(&namespace_object, arena, "description", selected.description);
                try namespace_object.put(arena, "tools", .{ .array = nested });
                const index = output.items.len;
                try output.append(.{ .object = namespace_object });
                try namespace_indices.put(arena, selected.name, index);
            }
        },
        .provider => |provider_tool| {
            const lowered = try prepareProviderTool(arena, provider_tool, diag);
            if (lowered) |value| {
                try output.append(value);
                if (std.mem.eql(u8, provider_tool.id, "openai.custom")) {
                    try custom_names.append(arena, provider_tool.name);
                }
            } else {
                try warnings.append(arena, .{ .unsupported = .{
                    .feature = try std.fmt.allocPrint(arena, "provider tool: {s}", .{provider_tool.id}),
                } });
            }
        },
    };

    const prepared_choice = if (allowed_tools) |allowed|
        try prepareAllowedToolsChoice(arena, input, allowed)
    else if (tool_choice) |choice|
        try prepareToolChoice(arena, input, custom_names.items, choice)
    else
        null;

    return .{
        .tools = .{ .array = output },
        .tool_choice = prepared_choice,
        .warnings = try warnings.toOwnedSlice(arena),
        .custom_provider_tool_names = try custom_names.toOwnedSlice(arena),
    };
}

pub fn toProviderToolName(tools: ?[]const provider.Tool, custom_name: []const u8) []const u8 {
    if (tools) |items| for (items) |tool| switch (tool) {
        .function => {},
        .provider => |item| if (std.mem.eql(u8, item.name, custom_name)) {
            return providerWireName(item);
        },
    };
    return custom_name;
}

pub fn toCustomToolName(tools: ?[]const provider.Tool, provider_name: []const u8) []const u8 {
    if (tools) |items| for (items) |tool| switch (tool) {
        .function => {},
        .provider => |item| if (std.mem.eql(u8, providerWireName(item), provider_name)) return item.name,
    };
    return provider_name;
}

pub fn hasProviderTool(tools: ?[]const provider.Tool, id: []const u8) bool {
    if (tools) |items| for (items) |tool| switch (tool) {
        .function => {},
        .provider => |item| if (std.mem.eql(u8, item.id, id)) return true,
    };
    return false;
}

pub fn isCustomProviderTool(tools: ?[]const provider.Tool, provider_name: []const u8) bool {
    if (tools) |items| for (items) |tool| switch (tool) {
        .function => {},
        .provider => |item| if (std.mem.eql(u8, item.id, "openai.custom") and
            std.mem.eql(u8, item.name, provider_name)) return true,
    };
    return false;
}

pub fn webSearchToolName(tools: ?[]const provider.Tool) ?[]const u8 {
    if (tools) |items| for (items) |tool| switch (tool) {
        .function => {},
        .provider => |item| if (std.mem.eql(u8, item.id, "openai.web_search") or
            std.mem.eql(u8, item.id, "openai.web_search_preview")) return item.name,
    };
    return null;
}

pub fn shellIsProviderExecuted(tools: ?[]const provider.Tool) bool {
    if (tools) |items| for (items) |tool| switch (tool) {
        .function => {},
        .provider => |item| if (std.mem.eql(u8, item.id, "openai.shell") and item.args == .object) {
            const environment = item.args.object.get("environment") orelse return false;
            if (environment != .object) return false;
            const kind = optionalString(environment.object, "type") orelse return false;
            return std.mem.eql(u8, kind, "containerAuto") or std.mem.eql(u8, kind, "containerReference");
        },
    };
    return false;
}

fn prepareFunctionTool(arena: Allocator, tool: provider.FunctionTool) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "type", "function");
    try putString(&object, arena, "name", tool.name);
    if (tool.description) |description| try putString(&object, arena, "description", description);
    try object.put(arena, "parameters", try provider_utils.cloneJsonValue(arena, tool.input_schema));
    if (tool.strict) |strict| try object.put(arena, "strict", .{ .bool = strict });
    if (openAiToolOptions(tool.provider_options)) |options| {
        if (optionalBool(options, "deferLoading")) |defer_loading| {
            try object.put(arena, "defer_loading", .{ .bool = defer_loading });
        }
    }
    return .{ .object = object };
}

fn prepareProviderTool(
    arena: Allocator,
    tool: provider.ProviderTool,
    diag: ?*provider.Diagnostics,
) PrepareError!?std.json.Value {
    if (std.mem.eql(u8, tool.id, "openai.local_shell")) return @as(?std.json.Value, try typedEmptyTool(arena, tool, "local_shell", diag));
    if (std.mem.eql(u8, tool.id, "openai.apply_patch")) return @as(?std.json.Value, try typedEmptyTool(arena, tool, "apply_patch", diag));

    const args = try requireArgsObject(arena, tool, diag);
    var object: std.json.ObjectMap = .empty;

    if (std.mem.eql(u8, tool.id, "openai.file_search")) {
        try putString(&object, arena, "type", "file_search");
        const ids = try requireStringArrayField(arena, args, "vectorStoreIds", diag);
        try object.put(arena, "vector_store_ids", ids);
        try copyOptionalUnsigned(arena, &object, args, "maxNumResults", "max_num_results", diag);
        if (args.get("ranking")) |ranking| if (ranking != .null) {
            if (ranking != .object) return typeValidation(arena, diag, "openai.file_search ranking must be an object");
            var output: std.json.ObjectMap = .empty;
            try copyOptionalString(arena, &output, ranking.object, "ranker", "ranker", diag);
            try copyOptionalNumber(arena, &output, ranking.object, "scoreThreshold", "score_threshold", diag);
            try object.put(arena, "ranking_options", .{ .object = output });
        };
        if (args.get("filters")) |filters| if (filters != .null) {
            try object.put(arena, "filters", try provider_utils.cloneJsonValue(arena, filters));
        };
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.shell")) {
        try putString(&object, arena, "type", "shell");
        if (args.get("environment")) |environment| if (environment != .null) {
            try object.put(arena, "environment", try mapShellEnvironment(arena, environment, diag));
        };
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.web_search_preview")) {
        try putString(&object, arena, "type", "web_search_preview");
        try copyOptionalEnumString(arena, &object, args, "searchContextSize", "search_context_size", &.{ "low", "medium", "high" }, diag);
        if (args.get("userLocation")) |location| if (location != .null) {
            try object.put(arena, "user_location", try provider_utils.cloneJsonValue(arena, location));
        };
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.web_search")) {
        try putString(&object, arena, "type", "web_search");
        try copyOptionalBool(arena, &object, args, "externalWebAccess", "external_web_access", diag);
        try copyOptionalEnumString(arena, &object, args, "searchContextSize", "search_context_size", &.{ "low", "medium", "high" }, diag);
        if (args.get("filters")) |filters| if (filters != .null) {
            if (filters != .object) return typeValidation(arena, diag, "openai.web_search filters must be an object");
            var mapped: std.json.ObjectMap = .empty;
            if (filters.object.get("allowedDomains")) |domains| {
                try mapped.put(arena, "allowed_domains", try requireStringArray(arena, domains, "allowedDomains", diag));
            }
            try object.put(arena, "filters", .{ .object = mapped });
        };
        if (args.get("userLocation")) |location| if (location != .null) {
            try object.put(arena, "user_location", try provider_utils.cloneJsonValue(arena, location));
        };
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.code_interpreter")) {
        try putString(&object, arena, "type", "code_interpreter");
        const container = args.get("container") orelse std.json.Value.null;
        if (container == .string) {
            try putString(&object, arena, "container", container.string);
        } else {
            var mapped: std.json.ObjectMap = .empty;
            try putString(&mapped, arena, "type", "auto");
            if (container == .object) {
                if (container.object.get("fileIds")) |ids| {
                    try mapped.put(arena, "file_ids", try requireStringArray(arena, ids, "container.fileIds", diag));
                }
            } else if (container != .null) return typeValidation(arena, diag, "openai.code_interpreter container must be a string or object");
            try object.put(arena, "container", .{ .object = mapped });
        }
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.image_generation")) {
        try putString(&object, arena, "type", "image_generation");
        try copyOptionalEnumString(arena, &object, args, "background", "background", &.{ "auto", "opaque", "transparent" }, diag);
        try copyOptionalEnumString(arena, &object, args, "inputFidelity", "input_fidelity", &.{ "low", "high" }, diag);
        try copyOptionalString(arena, &object, args, "model", "model", diag);
        try copyOptionalEnumString(arena, &object, args, "moderation", "moderation", &.{"auto"}, diag);
        try copyOptionalEnumString(arena, &object, args, "outputFormat", "output_format", &.{ "png", "jpeg", "webp" }, diag);
        try copyOptionalEnumString(arena, &object, args, "quality", "quality", &.{ "auto", "low", "medium", "high" }, diag);
        try copyOptionalEnumString(arena, &object, args, "size", "size", &.{ "auto", "1024x1024", "1024x1536", "1536x1024" }, diag);
        try copyOptionalUnsigned(arena, &object, args, "outputCompression", "output_compression", diag);
        try copyOptionalUnsigned(arena, &object, args, "partialImages", "partial_images", diag);
        if (args.get("inputImageMask")) |mask| if (mask != .null) {
            if (mask != .object) return typeValidation(arena, diag, "openai.image_generation inputImageMask must be an object");
            var mapped: std.json.ObjectMap = .empty;
            try copyOptionalString(arena, &mapped, mask.object, "fileId", "file_id", diag);
            try copyOptionalString(arena, &mapped, mask.object, "imageUrl", "image_url", diag);
            try object.put(arena, "input_image_mask", .{ .object = mapped });
        };
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.mcp")) {
        try putString(&object, arena, "type", "mcp");
        const label = try requireStringField(arena, args, "serverLabel", diag);
        try putString(&object, arena, "server_label", label);
        try copyOptionalString(arena, &object, args, "authorization", "authorization", diag);
        try copyOptionalString(arena, &object, args, "connectorId", "connector_id", diag);
        try copyOptionalString(arena, &object, args, "serverDescription", "server_description", diag);
        try copyOptionalString(arena, &object, args, "serverUrl", "server_url", diag);
        if (args.get("headers")) |headers| if (headers != .null) {
            if (headers != .object) return typeValidation(arena, diag, "openai.mcp headers must be an object");
            try object.put(arena, "headers", try provider_utils.cloneJsonValue(arena, headers));
        };
        if (args.get("allowedTools")) |allowed| if (allowed != .null) {
            if (allowed == .array) {
                try object.put(arena, "allowed_tools", try requireStringArray(arena, allowed, "allowedTools", diag));
            } else if (allowed == .object) {
                var mapped: std.json.ObjectMap = .empty;
                try copyOptionalBool(arena, &mapped, allowed.object, "readOnly", "read_only", diag);
                if (allowed.object.get("toolNames")) |names| try mapped.put(arena, "tool_names", try requireStringArray(arena, names, "allowedTools.toolNames", diag));
                try object.put(arena, "allowed_tools", .{ .object = mapped });
            } else return typeValidation(arena, diag, "openai.mcp allowedTools must be an array or object");
        };
        if (args.get("requireApproval")) |approval| {
            try object.put(arena, "require_approval", try mapRequireApproval(arena, approval, diag));
        } else try putString(&object, arena, "require_approval", "never");
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.custom")) {
        try putString(&object, arena, "type", "custom");
        try putString(&object, arena, "name", tool.name);
        try copyOptionalString(arena, &object, args, "description", "description", diag);
        if (args.get("format")) |format| if (format != .null) {
            if (format != .object) return typeValidation(arena, diag, "openai.custom format must be an object");
            try object.put(arena, "format", try provider_utils.cloneJsonValue(arena, format));
        };
        return .{ .object = object };
    }

    if (std.mem.eql(u8, tool.id, "openai.tool_search")) {
        try putString(&object, arena, "type", "tool_search");
        try copyOptionalEnumString(arena, &object, args, "execution", "execution", &.{ "server", "client" }, diag);
        try copyOptionalString(arena, &object, args, "description", "description", diag);
        if (args.get("parameters")) |parameters| if (parameters != .null) {
            if (parameters != .object) return typeValidation(arena, diag, "openai.tool_search parameters must be an object");
            try object.put(arena, "parameters", try provider_utils.cloneJsonValue(arena, parameters));
        };
        return .{ .object = object };
    }

    return null;
}

fn typedEmptyTool(
    arena: Allocator,
    tool: provider.ProviderTool,
    wire_type: []const u8,
    diag: ?*provider.Diagnostics,
) PrepareError!std.json.Value {
    _ = try requireArgsObject(arena, tool, diag);
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "type", wire_type);
    return .{ .object = object };
}

fn prepareToolChoice(
    arena: Allocator,
    tools: []const provider.Tool,
    custom_names: []const []const u8,
    choice: provider.ToolChoice,
) Allocator.Error!?std.json.Value {
    return switch (choice) {
        .auto => .{ .string = "auto" },
        .none => .{ .string = "none" },
        .required => .{ .string = "required" },
        .tool => |named| blk: {
            const provider_name = toProviderToolName(tools, named.tool_name);
            var object: std.json.ObjectMap = .empty;
            if (isHostedChoice(provider_name)) {
                try putString(&object, arena, "type", provider_name);
            } else if (containsString(custom_names, provider_name)) {
                try putString(&object, arena, "type", "custom");
                try putString(&object, arena, "name", provider_name);
            } else {
                try putString(&object, arena, "type", "function");
                try putString(&object, arena, "name", provider_name);
            }
            break :blk .{ .object = object };
        },
    };
}

fn prepareAllowedToolsChoice(
    arena: Allocator,
    tools: []const provider.Tool,
    allowed: options_api.AllowedTools,
) Allocator.Error!std.json.Value {
    var names = std.json.Array.init(arena);
    for (allowed.tool_names) |name| {
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "function");
        try putString(&item, arena, "name", toProviderToolName(tools, name));
        try names.append(.{ .object = item });
    }
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "type", "allowed_tools");
    try putString(&object, arena, "mode", allowed.mode);
    try object.put(arena, "tools", .{ .array = names });
    return .{ .object = object };
}

fn mapShellEnvironment(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) PrepareError!std.json.Value {
    if (value != .object) return typeValidation(arena, diag, "openai.shell environment must be an object");
    const kind = optionalString(value.object, "type") orelse "local";
    var object: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, kind, "containerReference")) {
        try putString(&object, arena, "type", "container_reference");
        try putString(&object, arena, "container_id", try requireStringField(arena, value.object, "containerId", diag));
        return .{ .object = object };
    }
    if (std.mem.eql(u8, kind, "containerAuto")) {
        try putString(&object, arena, "type", "container_auto");
        if (value.object.get("fileIds")) |ids| try object.put(arena, "file_ids", try requireStringArray(arena, ids, "environment.fileIds", diag));
        try copyOptionalEnumString(arena, &object, value.object, "memoryLimit", "memory_limit", &.{ "1g", "4g", "16g", "64g" }, diag);
        if (value.object.get("networkPolicy")) |policy| if (policy != .null) {
            if (policy != .object) return typeValidation(arena, diag, "openai.shell networkPolicy must be an object");
            var mapped: std.json.ObjectMap = .empty;
            const policy_type = try requireStringField(arena, policy.object, "type", diag);
            try putString(&mapped, arena, "type", policy_type);
            if (std.mem.eql(u8, policy_type, "allowlist")) {
                try mapped.put(arena, "allowed_domains", try requireStringArrayField(arena, policy.object, "allowedDomains", diag));
                if (policy.object.get("domainSecrets")) |secrets| try mapped.put(arena, "domain_secrets", try provider_utils.cloneJsonValue(arena, secrets));
            }
            try object.put(arena, "network_policy", .{ .object = mapped });
        };
        if (value.object.get("skills")) |skills| if (skills != .null) {
            try object.put(arena, "skills", try mapShellSkills(arena, skills, diag));
        };
        return .{ .object = object };
    }
    if (!std.mem.eql(u8, kind, "local")) return typeValidation(arena, diag, "openai.shell environment type is unsupported");
    try putString(&object, arena, "type", "local");
    if (value.object.get("skills")) |skills| if (skills != .null) {
        try object.put(arena, "skills", try provider_utils.cloneJsonValue(arena, skills));
    };
    return .{ .object = object };
}

fn mapShellSkills(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) PrepareError!std.json.Value {
    if (value != .array) return typeValidation(arena, diag, "openai.shell skills must be an array");
    var output = std.json.Array.init(arena);
    for (value.array.items) |skill| {
        if (skill != .object) return typeValidation(arena, diag, "openai.shell skill must be an object");
        const kind = try requireStringField(arena, skill.object, "type", diag);
        var mapped: std.json.ObjectMap = .empty;
        if (std.mem.eql(u8, kind, "skillReference")) {
            try putString(&mapped, arena, "type", "skill_reference");
            const reference = skill.object.get("providerReference") orelse return typeValidation(arena, diag, "openai.shell skillReference requires providerReference");
            try putString(&mapped, arena, "skill_id", try resolveReference(arena, reference, diag));
            try putString(&mapped, arena, "version", optionalString(skill.object, "version") orelse "latest");
        } else if (std.mem.eql(u8, kind, "inline")) {
            try putString(&mapped, arena, "type", "inline");
            try putString(&mapped, arena, "name", try requireStringField(arena, skill.object, "name", diag));
            try putString(&mapped, arena, "description", try requireStringField(arena, skill.object, "description", diag));
            const source = skill.object.get("source") orelse return typeValidation(arena, diag, "openai.shell inline skill requires source");
            if (source != .object) return typeValidation(arena, diag, "openai.shell inline skill source must be an object");
            var mapped_source: std.json.ObjectMap = .empty;
            try putString(&mapped_source, arena, "type", "base64");
            try putString(&mapped_source, arena, "media_type", try requireStringField(arena, source.object, "mediaType", diag));
            try putString(&mapped_source, arena, "data", try requireStringField(arena, source.object, "data", diag));
            try mapped.put(arena, "source", .{ .object = mapped_source });
        } else return typeValidation(arena, diag, "openai.shell skill type is unsupported");
        try output.append(.{ .object = mapped });
    }
    return .{ .array = output };
}

fn mapRequireApproval(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) PrepareError!std.json.Value {
    if (value == .null) return .{ .string = "never" };
    if (value == .string) {
        if (!std.mem.eql(u8, value.string, "always") and !std.mem.eql(u8, value.string, "never")) {
            return typeValidation(arena, diag, "openai.mcp requireApproval must be always or never");
        }
        return .{ .string = try arena.dupe(u8, value.string) };
    }
    if (value != .object) return typeValidation(arena, diag, "openai.mcp requireApproval must be a string or object");
    const never = value.object.get("never") orelse return .{ .string = "never" };
    if (never != .object) return typeValidation(arena, diag, "openai.mcp requireApproval.never must be an object");
    var never_object: std.json.ObjectMap = .empty;
    if (never.object.get("toolNames")) |names| try never_object.put(arena, "tool_names", try requireStringArray(arena, names, "requireApproval.never.toolNames", diag));
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "never", .{ .object = never_object });
    return .{ .object = result };
}

const Namespace = struct { name: []const u8, description: []const u8 };

fn functionNamespace(provider_options: ?provider.ProviderOptions) ?Namespace {
    const options = openAiToolOptions(provider_options) orelse return null;
    const value = options.get("namespace") orelse return null;
    if (value != .object) return null;
    return .{
        .name = optionalString(value.object, "name") orelse return null,
        .description = optionalString(value.object, "description") orelse return null,
    };
}

fn openAiToolOptions(provider_options: ?provider.ProviderOptions) ?std.json.ObjectMap {
    const root = provider_options orelse return null;
    if (root != .object) return null;
    const value = root.object.get("openai") orelse return null;
    return if (value == .object) value.object else null;
}

fn providerWireName(tool: provider.ProviderTool) []const u8 {
    if (std.mem.eql(u8, tool.id, "openai.file_search")) return "file_search";
    if (std.mem.eql(u8, tool.id, "openai.local_shell")) return "local_shell";
    if (std.mem.eql(u8, tool.id, "openai.shell")) return "shell";
    if (std.mem.eql(u8, tool.id, "openai.apply_patch")) return "apply_patch";
    if (std.mem.eql(u8, tool.id, "openai.web_search_preview")) return "web_search_preview";
    if (std.mem.eql(u8, tool.id, "openai.web_search")) return "web_search";
    if (std.mem.eql(u8, tool.id, "openai.code_interpreter")) return "code_interpreter";
    if (std.mem.eql(u8, tool.id, "openai.image_generation")) return "image_generation";
    if (std.mem.eql(u8, tool.id, "openai.mcp")) return "mcp";
    if (std.mem.eql(u8, tool.id, "openai.tool_search")) return "tool_search";
    if (std.mem.eql(u8, tool.id, "openai.custom")) return tool.name;
    return tool.name;
}

fn isHostedChoice(name: []const u8) bool {
    return std.mem.eql(u8, name, "code_interpreter") or
        std.mem.eql(u8, name, "file_search") or
        std.mem.eql(u8, name, "image_generation") or
        std.mem.eql(u8, name, "web_search_preview") or
        std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "mcp") or
        std.mem.eql(u8, name, "apply_patch");
}

fn requireArgsObject(arena: Allocator, tool: provider.ProviderTool, diag: ?*provider.Diagnostics) PrepareError!std.json.ObjectMap {
    if (tool.args != .object) {
        return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} args must be an object", .{tool.id}));
    }
    return tool.args.object;
}

fn resolveReference(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) PrepareError![]const u8 {
    if (value == .object) {
        if (value.object.get("openai")) |reference| if (reference == .string) return reference.string;
    }
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .no_such_provider_reference = .{
            .message = "No OpenAI provider reference was found",
            .provider = "openai",
            .reference_json = try provider_utils.stringifyJsonValueAlloc(arena, value),
        },
    });
    return error.NoSuchProviderReferenceError;
}

fn requireStringArrayField(arena: Allocator, object: std.json.ObjectMap, name: []const u8, diag: ?*provider.Diagnostics) PrepareError!std.json.Value {
    const value = object.get(name) orelse return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} is required", .{name}));
    return requireStringArray(arena, value, name, diag);
}

fn requireStringArray(arena: Allocator, value: std.json.Value, name: []const u8, diag: ?*provider.Diagnostics) PrepareError!std.json.Value {
    if (value != .array) return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be an array of strings", .{name}));
    var output = std.json.Array.init(arena);
    for (value.array.items) |item| {
        if (item != .string) return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be an array of strings", .{name}));
        try output.append(.{ .string = try arena.dupe(u8, item.string) });
    }
    return .{ .array = output };
}

fn requireStringField(arena: Allocator, object: std.json.ObjectMap, name: []const u8, diag: ?*provider.Diagnostics) PrepareError![]const u8 {
    return optionalString(object, name) orelse typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be a string", .{name}));
}

fn copyOptionalString(arena: Allocator, destination: *std.json.ObjectMap, source: std.json.ObjectMap, source_name: []const u8, destination_name: []const u8, diag: ?*provider.Diagnostics) PrepareError!void {
    const value = source.get(source_name) orelse return;
    if (value == .null) return;
    if (value != .string) return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be a string", .{source_name}));
    try putString(destination, arena, destination_name, value.string);
}

fn copyOptionalEnumString(
    arena: Allocator,
    destination: *std.json.ObjectMap,
    source: std.json.ObjectMap,
    source_name: []const u8,
    destination_name: []const u8,
    allowed: []const []const u8,
    diag: ?*provider.Diagnostics,
) PrepareError!void {
    const value = source.get(source_name) orelse return;
    if (value == .null) return;
    if (value != .string) return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be a string", .{source_name}));
    for (allowed) |candidate| if (std.mem.eql(u8, value.string, candidate)) {
        try putString(destination, arena, destination_name, value.string);
        return;
    };
    return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} has an unsupported value", .{source_name}));
}

fn copyOptionalBool(arena: Allocator, destination: *std.json.ObjectMap, source: std.json.ObjectMap, source_name: []const u8, destination_name: []const u8, diag: ?*provider.Diagnostics) PrepareError!void {
    const value = source.get(source_name) orelse return;
    if (value == .null) return;
    if (value != .bool) return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be a boolean", .{source_name}));
    try destination.put(arena, destination_name, .{ .bool = value.bool });
}

fn copyOptionalUnsigned(arena: Allocator, destination: *std.json.ObjectMap, source: std.json.ObjectMap, source_name: []const u8, destination_name: []const u8, diag: ?*provider.Diagnostics) PrepareError!void {
    const value = source.get(source_name) orelse return;
    if (value == .null) return;
    if (value != .integer or value.integer < 0) return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be a non-negative integer", .{source_name}));
    try destination.put(arena, destination_name, .{ .integer = value.integer });
}

fn copyOptionalNumber(arena: Allocator, destination: *std.json.ObjectMap, source: std.json.ObjectMap, source_name: []const u8, destination_name: []const u8, diag: ?*provider.Diagnostics) PrepareError!void {
    const value = source.get(source_name) orelse return;
    if (value == .null) return;
    switch (value) {
        .integer, .float, .number_string => try destination.put(arena, destination_name, try provider_utils.cloneJsonValue(arena, value)),
        else => return typeValidation(arena, diag, try std.fmt.allocPrint(arena, "{s} must be a number", .{source_name})),
    }
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn unsupported(arena: Allocator, diag: ?*provider.Diagnostics, functionality: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .unsupported_functionality = .{
            .message = "OpenAI Responses tool configuration is unsupported",
            .functionality = functionality,
        },
    });
    return error.UnsupportedFunctionalityError;
}

fn typeValidation(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .type_validation = .{ .message = message },
    });
    return error.TypeValidationError;
}

test "Responses tools lower function namespaces and the hosted table" {
    // Fixtures ported from openai-responses-prepare-tools.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const namespace_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"openai\":{\"deferLoading\":true,\"namespace\":{\"name\":\"weather_tools\",\"description\":\"Weather tools\"}}}",
        .{},
    );
    const tool_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"vectorStoreIds\":[\"vs_123\"],\"maxNumResults\":3}",
        .{},
    );
    const tools = [_]provider.Tool{
        .{ .function = .{ .name = "weather", .description = "Get weather", .input_schema = .{ .object = schema }, .strict = true, .provider_options = namespace_options } },
        .{ .provider = .{ .id = "openai.file_search", .name = "files", .args = tool_args } },
    };
    const prepared = try prepareResponsesTools(arena, &tools, .{ .tool = .{ .tool_name = "files" } }, null, null);
    try std.testing.expectEqual(2, prepared.tools.?.array.items.len);
    const namespace = prepared.tools.?.array.items[0].object;
    try std.testing.expectEqualStrings("namespace", namespace.get("type").?.string);
    try std.testing.expect(namespace.get("tools").?.array.items[0].object.get("defer_loading").?.bool);
    try std.testing.expectEqualStrings("file_search", prepared.tool_choice.?.object.get("type").?.string);
}

test "Responses tools reject conflicting namespace descriptions" {
    // Fixture ported from openai-responses-prepare-tools.test.ts
    // "should reject conflicting descriptions".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const first = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"namespace\":{\"name\":\"tools\",\"description\":\"one\"}}}", .{});
    const second = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"namespace\":{\"name\":\"tools\",\"description\":\"two\"}}}", .{});
    const tools = [_]provider.Tool{
        .{ .function = .{ .name = "one", .input_schema = .{ .object = schema }, .provider_options = first } },
        .{ .function = .{ .name = "two", .input_schema = .{ .object = schema }, .provider_options = second } },
    };
    try std.testing.expectError(error.UnsupportedFunctionalityError, prepareResponsesTools(arena, &tools, null, null, null));
}

test "Responses hosted tool table lowers every upstream provider tool id" {
    // Table fixture ported from openai-responses-prepare-tools.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const file_search = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"vectorStoreIds\":[\"vs_1\"]}", .{});
    const mcp = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"serverLabel\":\"docs\"}", .{});
    const custom = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"description\":\"write SQL\",\"format\":{\"type\":\"text\"}}", .{});
    const search = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"execution\":\"client\"}", .{});
    const tools = [_]provider.Tool{
        .{ .provider = .{ .id = "openai.file_search", .name = "files", .args = file_search } },
        .{ .provider = .{ .id = "openai.local_shell", .name = "local", .args = empty } },
        .{ .provider = .{ .id = "openai.shell", .name = "shell", .args = empty } },
        .{ .provider = .{ .id = "openai.apply_patch", .name = "patch", .args = empty } },
        .{ .provider = .{ .id = "openai.web_search_preview", .name = "preview", .args = empty } },
        .{ .provider = .{ .id = "openai.web_search", .name = "web", .args = empty } },
        .{ .provider = .{ .id = "openai.code_interpreter", .name = "code", .args = empty } },
        .{ .provider = .{ .id = "openai.image_generation", .name = "image", .args = empty } },
        .{ .provider = .{ .id = "openai.mcp", .name = "mcp", .args = mcp } },
        .{ .provider = .{ .id = "openai.custom", .name = "write_sql", .args = custom } },
        .{ .provider = .{ .id = "openai.tool_search", .name = "toolSearch", .args = search } },
    };
    const prepared = try prepareResponsesTools(arena, &tools, null, null, null);
    const expected = [_][]const u8{
        "file_search", "local_shell", "shell", "apply_patch", "web_search_preview", "web_search", "code_interpreter", "image_generation", "mcp", "custom", "tool_search",
    };
    try std.testing.expectEqual(expected.len, prepared.tools.?.array.items.len);
    for (prepared.tools.?.array.items, expected) |actual, wanted| try std.testing.expectEqualStrings(wanted, actual.object.get("type").?.string);
    try std.testing.expectEqualStrings("never", prepared.tools.?.array.items[8].object.get("require_approval").?.string);
    try std.testing.expectEqualStrings("write_sql", prepared.tools.?.array.items[9].object.get("name").?.string);
    try std.testing.expectEqual(1, prepared.custom_provider_tool_names.len);
}

test "Responses allowed_tools overrides request tool choice with provider-name mapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const tools = [_]provider.Tool{.{ .function = .{ .name = "weather", .input_schema = .{ .object = schema } } }};
    const prepared = try prepareResponsesTools(arena, &tools, .{ .none = .{} }, .{
        .tool_names = &.{"weather"},
        .mode = "required",
    }, null);
    const choice = prepared.tool_choice.?.object;
    try std.testing.expectEqualStrings("allowed_tools", choice.get("type").?.string);
    try std.testing.expectEqualStrings("required", choice.get("mode").?.string);
    try std.testing.expectEqualStrings("weather", choice.get("tools").?.array.items[0].object.get("name").?.string);
}
