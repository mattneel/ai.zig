const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const prompt_api = @import("prompt.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

pub const Result = struct {
    tools: ?std.json.Value,
    tool_choice: ?std.json.Value,
    betas: utils.BetaSet,
};

pub fn prepare(
    allocator: Allocator,
    input_tools: ?[]const provider.Tool,
    tool_choice: ?provider.ToolChoice,
    disable_parallel: ?bool,
    cache_validator: *prompt_api.CacheControlValidator,
    supports_structured_output: bool,
    supports_strict_tools: bool,
    default_eager_input_streaming: bool,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!Result {
    var betas: utils.BetaSet = .{};
    const items = input_tools orelse return .{ .tools = null, .tool_choice = null, .betas = betas };
    if (items.len == 0) return .{ .tools = null, .tool_choice = null, .betas = betas };

    var output = std.json.Array.init(allocator);
    for (items) |tool| switch (tool) {
        .function => |function| {
            var object: std.json.ObjectMap = .empty;
            try utils.putString(&object, allocator, "name", function.name);
            if (function.description) |description| try utils.putString(&object, allocator, "description", description);
            try object.put(allocator, "input_schema", try provider_utils.cloneJsonValue(allocator, function.input_schema));
            if (try cache_validator.get(
                allocator,
                function.provider_options,
                "tool definition",
                true,
                warnings,
            )) |cache| try object.put(allocator, "cache_control", cache);

            const anthropic = anthropicOptions(function.provider_options);
            const eager = if (anthropic) |options|
                utils.optionalBool(options, "eagerInputStreaming") orelse default_eager_input_streaming
            else
                default_eager_input_streaming;
            if (eager) try object.put(allocator, "eager_input_streaming", .{ .bool = true });
            if (anthropic) |options| {
                if (utils.optionalBool(options, "deferLoading")) |value| {
                    try object.put(allocator, "defer_loading", .{ .bool = value });
                }
                if (options.get("allowedCallers")) |allowed| {
                    if (allowed == .array) try object.put(
                        allocator,
                        "allowed_callers",
                        try provider_utils.cloneJsonValue(allocator, allowed),
                    );
                    try betas.add(allocator, "advanced-tool-use-2025-11-20");
                }
            }
            if (function.strict) |strict| {
                if (supports_strict_tools) {
                    try object.put(allocator, "strict", .{ .bool = strict });
                } else {
                    try warnings.append(allocator, .{ .unsupported = .{
                        .feature = "strict",
                        .details = try std.fmt.allocPrint(
                            allocator,
                            "Tool '{s}' has strict: {}, but strict mode is not supported by this provider. The strict property will be ignored.",
                            .{ function.name, strict },
                        ),
                    } });
                }
            }
            if (supports_structured_output) try betas.add(allocator, "structured-outputs-2025-11-13");
            if (function.input_examples) |examples| {
                var input_examples = std.json.Array.init(allocator);
                for (examples) |example| try input_examples.append(
                    try provider_utils.cloneJsonValue(allocator, example.input),
                );
                try object.put(allocator, "input_examples", .{ .array = input_examples });
                try betas.add(allocator, "advanced-tool-use-2025-11-20");
            }
            try output.append(.{ .object = object });
        },
        .provider => |tool_value| {
            if (try prepareProviderTool(allocator, tool_value, &betas)) |value| {
                try output.append(value);
            } else {
                try warnings.append(allocator, .{ .unsupported = .{
                    .feature = try std.fmt.allocPrint(
                        allocator,
                        "provider-defined tool {s}",
                        .{tool_value.id},
                    ),
                } });
            }
        },
    };

    if (tool_choice) |choice| if (choice == .none) {
        return .{ .tools = null, .tool_choice = null, .betas = betas };
    };
    var choice_value: ?std.json.Value = null;
    if (tool_choice) |choice| {
        var object: std.json.ObjectMap = .empty;
        switch (choice) {
            .auto => try utils.putString(&object, allocator, "type", "auto"),
            .required => try utils.putString(&object, allocator, "type", "any"),
            .tool => |named| {
                try utils.putString(&object, allocator, "type", "tool");
                try utils.putString(&object, allocator, "name", named.tool_name);
            },
            .none => unreachable,
        }
        if (disable_parallel) |value| try object.put(
            allocator,
            "disable_parallel_tool_use",
            .{ .bool = value },
        );
        choice_value = .{ .object = object };
    } else if (disable_parallel orelse false) {
        var object: std.json.ObjectMap = .empty;
        try utils.putString(&object, allocator, "type", "auto");
        try object.put(allocator, "disable_parallel_tool_use", .{ .bool = true });
        choice_value = .{ .object = object };
    }
    return .{
        .tools = .{ .array = output },
        .tool_choice = choice_value,
        .betas = betas,
    };
}

fn prepareProviderTool(
    allocator: Allocator,
    tool: provider.ProviderTool,
    betas: *utils.BetaSet,
) Allocator.Error!?std.json.Value {
    var object: std.json.ObjectMap = .empty;
    const id = tool.id;
    if (std.mem.eql(u8, id, "anthropic.code_execution_20250522")) {
        try betas.add(allocator, "code-execution-2025-05-22");
        try utils.putString(&object, allocator, "type", "code_execution_20250522");
        try utils.putString(&object, allocator, "name", "code_execution");
    } else if (std.mem.eql(u8, id, "anthropic.code_execution_20250825")) {
        try betas.add(allocator, "code-execution-2025-08-25");
        try utils.putString(&object, allocator, "type", "code_execution_20250825");
        try utils.putString(&object, allocator, "name", "code_execution");
    } else if (std.mem.eql(u8, id, "anthropic.code_execution_20260120")) {
        try utils.putString(&object, allocator, "type", "code_execution_20260120");
        try utils.putString(&object, allocator, "name", "code_execution");
    } else if (std.mem.eql(u8, id, "anthropic.computer_20241022")) {
        try betas.add(allocator, "computer-use-2024-10-22");
        try namedTypedArgs(allocator, &object, "computer", "computer_20241022", tool.args, &.{
            .{ "displayWidthPx", "display_width_px" },
            .{ "displayHeightPx", "display_height_px" },
            .{ "displayNumber", "display_number" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.computer_20250124")) {
        try betas.add(allocator, "computer-use-2025-01-24");
        try namedTypedArgs(allocator, &object, "computer", "computer_20250124", tool.args, &.{
            .{ "displayWidthPx", "display_width_px" },
            .{ "displayHeightPx", "display_height_px" },
            .{ "displayNumber", "display_number" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.computer_20251124")) {
        try betas.add(allocator, "computer-use-2025-11-24");
        try namedTypedArgs(allocator, &object, "computer", "computer_20251124", tool.args, &.{
            .{ "displayWidthPx", "display_width_px" },
            .{ "displayHeightPx", "display_height_px" },
            .{ "displayNumber", "display_number" },
            .{ "enableZoom", "enable_zoom" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.text_editor_20241022")) {
        try betas.add(allocator, "computer-use-2024-10-22");
        try namedTypedArgs(allocator, &object, "str_replace_editor", "text_editor_20241022", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.text_editor_20250124")) {
        try betas.add(allocator, "computer-use-2025-01-24");
        try namedTypedArgs(allocator, &object, "str_replace_editor", "text_editor_20250124", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.text_editor_20250429")) {
        try betas.add(allocator, "computer-use-2025-01-24");
        try namedTypedArgs(allocator, &object, "str_replace_based_edit_tool", "text_editor_20250429", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.text_editor_20250728")) {
        try namedTypedArgs(allocator, &object, "str_replace_based_edit_tool", "text_editor_20250728", tool.args, &.{
            .{ "maxCharacters", "max_characters" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.bash_20241022")) {
        try betas.add(allocator, "computer-use-2024-10-22");
        try namedTypedArgs(allocator, &object, "bash", "bash_20241022", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.bash_20250124")) {
        try betas.add(allocator, "computer-use-2025-01-24");
        try namedTypedArgs(allocator, &object, "bash", "bash_20250124", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.memory_20250818")) {
        try betas.add(allocator, "context-management-2025-06-27");
        try namedTypedArgs(allocator, &object, "memory", "memory_20250818", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.web_search_20250305")) {
        try namedTypedArgs(allocator, &object, "web_search", "web_search_20250305", tool.args, &.{
            .{ "maxUses", "max_uses" },
            .{ "allowedDomains", "allowed_domains" },
            .{ "blockedDomains", "blocked_domains" },
            .{ "userLocation", "user_location" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.web_search_20260209")) {
        try betas.add(allocator, "code-execution-web-tools-2026-02-09");
        try namedTypedArgs(allocator, &object, "web_search", "web_search_20260209", tool.args, &.{
            .{ "maxUses", "max_uses" },
            .{ "allowedDomains", "allowed_domains" },
            .{ "blockedDomains", "blocked_domains" },
            .{ "userLocation", "user_location" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.web_fetch_20250910")) {
        try betas.add(allocator, "web-fetch-2025-09-10");
        try namedTypedArgs(allocator, &object, "web_fetch", "web_fetch_20250910", tool.args, &.{
            .{ "maxUses", "max_uses" },
            .{ "allowedDomains", "allowed_domains" },
            .{ "blockedDomains", "blocked_domains" },
            .{ "citations", "citations" },
            .{ "maxContentTokens", "max_content_tokens" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.web_fetch_20260209")) {
        try betas.add(allocator, "code-execution-web-tools-2026-02-09");
        try namedTypedArgs(allocator, &object, "web_fetch", "web_fetch_20260209", tool.args, &.{
            .{ "maxUses", "max_uses" },
            .{ "allowedDomains", "allowed_domains" },
            .{ "blockedDomains", "blocked_domains" },
            .{ "citations", "citations" },
            .{ "maxContentTokens", "max_content_tokens" },
        });
    } else if (std.mem.eql(u8, id, "anthropic.tool_search_regex_20251119")) {
        try namedTypedArgs(allocator, &object, "tool_search_tool_regex", "tool_search_tool_regex_20251119", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.tool_search_bm25_20251119")) {
        try namedTypedArgs(allocator, &object, "tool_search_tool_bm25", "tool_search_tool_bm25_20251119", tool.args, &.{});
    } else if (std.mem.eql(u8, id, "anthropic.advisor_20260301")) {
        try betas.add(allocator, "advisor-tool-2026-03-01");
        try namedTypedArgs(allocator, &object, "advisor", "advisor_20260301", tool.args, &.{
            .{ "model", "model" },
            .{ "maxUses", "max_uses" },
            .{ "caching", "caching" },
        });
    } else return null;
    return .{ .object = object };
}

const FieldMapping = struct { []const u8, []const u8 };

fn namedTypedArgs(
    allocator: Allocator,
    destination: *std.json.ObjectMap,
    name: []const u8,
    kind: []const u8,
    args: std.json.Value,
    mappings: []const FieldMapping,
) Allocator.Error!void {
    try utils.putString(destination, allocator, "name", name);
    try utils.putString(destination, allocator, "type", kind);
    if (args != .object) return;
    for (mappings) |mapping| {
        if (args.object.get(mapping[0])) |value| if (value != .null) {
            try destination.put(
                allocator,
                mapping[1],
                try provider_utils.cloneJsonValue(allocator, value),
            );
        };
    }
}

fn anthropicOptions(provider_options: ?provider.ProviderOptions) ?std.json.ObjectMap {
    const root = provider_options orelse return null;
    if (root != .object) return null;
    const value = root.object.get("anthropic") orelse return null;
    return if (value == .object) value.object else null;
}

test "prepareTools maps provider tools and beta headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"maxUses\":3,\"allowedDomains\":[\"example.com\"]}",
        .{},
    );
    const input = [_]provider.Tool{.{ .provider = .{
        .id = "anthropic.web_fetch_20250910",
        .name = "fetch",
        .args = args,
    } }};
    var warnings: std.ArrayList(provider.Warning) = .empty;
    var validator: prompt_api.CacheControlValidator = .{};
    const result = try prepare(
        allocator,
        &input,
        null,
        null,
        &validator,
        false,
        false,
        false,
        &warnings,
    );
    try std.testing.expectEqualStrings("web_fetch_20250910", result.tools.?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqual(3, result.tools.?.array.items[0].object.get("max_uses").?.integer);
    try std.testing.expectEqualStrings("web-fetch-2025-09-10", result.betas.order.items[0]);
}
