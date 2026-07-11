//! LanguageModelV4 prompt to OpenAI Responses input-item conversion.
//!
//! Ported from
//! `packages/openai/src/responses/convert-to-openai-responses-input.ts`.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const capabilities = @import("capabilities.zig");
const options_api = @import("options.zig");
const responses_tools = @import("responses_tools.zig");

const Allocator = std.mem.Allocator;
pub const ConvertError = provider.Error || Allocator.Error;

pub const ConvertOptions = struct {
    system_message_mode: capabilities.SystemMessageMode,
    provider_options_name: []const u8,
    store: bool,
    has_conversation: bool = false,
    has_previous_response_id: bool = false,
    pass_through_unsupported_files: bool = false,
    tools: ?[]const provider.Tool = null,
};

pub const ConvertedInput = struct {
    value: std.json.Value,
    warnings: []const provider.Warning,
};

pub fn convertToOpenAIResponsesInput(
    arena: Allocator,
    prompt: provider.Prompt,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!ConvertedInput {
    var input = std.json.Array.init(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var reasoning_indices: std.StringHashMapUnmanaged(usize) = .empty;
    defer reasoning_indices.deinit(arena);
    var processed_approval_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer processed_approval_ids.deinit(arena);

    for (prompt) |message| switch (message) {
        .system => |system| try convertSystem(arena, &input, &warnings, system, options),
        .user => |user| try convertUser(arena, &input, user, options, diag),
        .assistant => |assistant| try convertAssistant(
            arena,
            &input,
            &warnings,
            &reasoning_indices,
            assistant,
            options,
            diag,
        ),
        .tool => |tool_message| try convertToolMessage(
            arena,
            &input,
            &warnings,
            &processed_approval_ids,
            tool_message,
            options,
            diag,
        ),
    };

    if (!options.store) {
        var removed_reasoning = false;
        var index: usize = 0;
        while (index < input.items.len) {
            const item = input.items[index];
            if (item == .object and std.mem.eql(u8, optionalString(item.object, "type") orelse "", "reasoning") and
                nullish(item.object.get("encrypted_content")))
            {
                _ = input.orderedRemove(index);
                removed_reasoning = true;
                continue;
            }
            index += 1;
        }
        if (removed_reasoning) try warnings.append(arena, .{ .other = .{
            .message = "Reasoning parts without encrypted content are not supported when store is false. Skipping reasoning parts.",
        } });
    }

    return .{
        .value = .{ .array = input },
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn convertSystem(
    arena: Allocator,
    input: *std.json.Array,
    warnings: *std.ArrayList(provider.Warning),
    message: provider.Message.System,
    options: ConvertOptions,
) Allocator.Error!void {
    if (options.system_message_mode == .remove) {
        try warnings.append(arena, .{ .other = .{ .message = "system messages are removed for this model" } });
        return;
    }
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "role", if (options.system_message_mode == .developer) "developer" else "system");
    if (promptCacheBreakpoint(message.provider_options, options.provider_options_name)) |breakpoint| {
        var content = std.json.Array.init(arena);
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "input_text");
        try putString(&item, arena, "text", message.content);
        try item.put(arena, "prompt_cache_breakpoint", try provider_utils.cloneJsonValue(arena, breakpoint));
        try content.append(.{ .object = item });
        try object.put(arena, "content", .{ .array = content });
    } else try putString(&object, arena, "content", message.content);
    try input.append(.{ .object = object });
}

fn convertUser(
    arena: Allocator,
    input: *std.json.Array,
    message: provider.Message.User,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "role", "user");
    var content = std.json.Array.init(arena);
    for (message.content, 0..) |part, index| switch (part) {
        .text => |text| {
            var item: std.json.ObjectMap = .empty;
            try putString(&item, arena, "type", "input_text");
            try putString(&item, arena, "text", text.text);
            try addPromptCacheBreakpoint(arena, &item, text.provider_options, options.provider_options_name);
            try content.append(.{ .object = item });
        },
        .file => |file| try content.append(try convertInputFile(arena, file, index, options, diag)),
    };
    try object.put(arena, "content", .{ .array = content });
    try input.append(.{ .object = object });
}

fn convertAssistant(
    arena: Allocator,
    input: *std.json.Array,
    warnings: *std.ArrayList(provider.Warning),
    reasoning_indices: *std.StringHashMapUnmanaged(usize),
    message: provider.Message.Assistant,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    for (message.content) |part| switch (part) {
        .text => |text| {
            const part_options = options_api.namespaceObject(text.provider_options, options.provider_options_name);
            const id = if (part_options) |object| optionalString(object, "itemId") else null;
            const phase = if (part_options) |object| optionalString(object, "phase") else null;
            if (options.has_conversation and id != null) continue;
            if (options.store and id != null) {
                try input.append(try itemReference(arena, id.?));
                continue;
            }
            var content = std.json.Array.init(arena);
            var content_part: std.json.ObjectMap = .empty;
            try putString(&content_part, arena, "type", "output_text");
            try putString(&content_part, arena, "text", text.text);
            try content.append(.{ .object = content_part });
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "role", "assistant");
            try object.put(arena, "content", .{ .array = content });
            if (id) |value| try putString(&object, arena, "id", value);
            if (phase) |value| try putString(&object, arena, "phase", value);
            try input.append(.{ .object = object });
        },
        .reasoning => |reasoning| try convertReasoning(
            arena,
            input,
            warnings,
            reasoning_indices,
            reasoning,
            options,
        ),
        .tool_call => |tool_call| try convertAssistantToolCall(arena, input, tool_call, options, diag),
        .tool_result => |tool_result| try convertAssistantToolResult(arena, input, warnings, tool_result, options, diag),
        .custom => |custom| try convertCompaction(arena, input, custom, options),
        .file, .reasoning_file => try warnings.append(arena, .{ .unsupported = .{
            .feature = try std.fmt.allocPrint(arena, "assistant content type: {s}", .{@tagName(part)}),
        } }),
    };
}

fn convertReasoning(
    arena: Allocator,
    input: *std.json.Array,
    warnings: *std.ArrayList(provider.Warning),
    reasoning_indices: *std.StringHashMapUnmanaged(usize),
    part: provider.ReasoningPart,
    options: ConvertOptions,
) Allocator.Error!void {
    const part_options = options_api.namespaceObject(part.provider_options, options.provider_options_name);
    const id = if (part_options) |object| optionalString(object, "itemId") else null;
    const encrypted = if (part_options) |object| nullableString(object, "reasoningEncryptedContent") else null;

    if ((options.has_conversation or options.has_previous_response_id) and id != null) return;
    if (id) |reasoning_id| {
        if (options.store) {
            if (!reasoning_indices.contains(reasoning_id)) {
                try input.append(try itemReference(arena, reasoning_id));
                try reasoning_indices.put(arena, reasoning_id, input.items.len - 1);
            }
            return;
        }

        if (reasoning_indices.get(reasoning_id)) |index| {
            const object = &input.items[index].object;
            if (part.text.len == 0) {
                try warnings.append(arena, .{ .other = .{
                    .message = "Cannot append empty reasoning part to existing reasoning sequence. Skipping reasoning part.",
                } });
            } else {
                const summary = object.getPtr("summary").?;
                try summary.array.append(try summaryText(arena, part.text));
            }
            if (encrypted) |value| try putString(object, arena, "encrypted_content", value);
            return;
        }

        var summary = std.json.Array.init(arena);
        if (part.text.len != 0) try summary.append(try summaryText(arena, part.text));
        var object: std.json.ObjectMap = .empty;
        try putString(&object, arena, "type", "reasoning");
        try putString(&object, arena, "id", reasoning_id);
        if (encrypted) |value| try putString(&object, arena, "encrypted_content", value);
        try object.put(arena, "summary", .{ .array = summary });
        try input.append(.{ .object = object });
        try reasoning_indices.put(arena, reasoning_id, input.items.len - 1);
        return;
    }

    if (encrypted) |value| {
        var summary = std.json.Array.init(arena);
        if (part.text.len != 0) try summary.append(try summaryText(arena, part.text));
        var object: std.json.ObjectMap = .empty;
        try putString(&object, arena, "type", "reasoning");
        try putString(&object, arena, "encrypted_content", value);
        try object.put(arena, "summary", .{ .array = summary });
        try input.append(.{ .object = object });
    } else try warnings.append(arena, .{ .other = .{
        .message = "Non-OpenAI reasoning parts are not supported. Skipping reasoning part.",
    } });
}

fn convertAssistantToolCall(
    arena: Allocator,
    input: *std.json.Array,
    part: provider.ToolCallPart,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    const part_options = options_api.namespaceObject(part.provider_options, options.provider_options_name);
    const id = if (part_options) |object| optionalString(object, "itemId") else null;
    const namespace = if (part_options) |object| optionalString(object, "namespace") else null;
    if (options.has_conversation and id != null) return;

    const provider_name = responses_tools.toProviderToolName(options.tools, part.tool_name);
    if (std.mem.eql(u8, provider_name, "tool_search")) {
        if (options.store and id != null) {
            try input.append(try itemReference(arena, id.?));
            return;
        }
        const object = try requireObjectValue(arena, part.input, diag, "tool_search input must be an object");
        const call_id = nullableString(object, "call_id");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "tool_search_call");
        try putString(&item, arena, "id", id orelse part.tool_call_id);
        try putString(&item, arena, "execution", if (call_id != null) "client" else "server");
        if (call_id) |value| try putString(&item, arena, "call_id", value) else try item.put(arena, "call_id", .null);
        try putString(&item, arena, "status", "completed");
        try item.put(arena, "arguments", try provider_utils.cloneJsonValue(arena, object.get("arguments") orelse .null));
        try input.append(.{ .object = item });
        return;
    }

    if (part.provider_executed orelse false) {
        if (options.store and id != null) try input.append(try itemReference(arena, id.?));
        return;
    }
    if (options.has_previous_response_id and options.store and id != null) return;

    const provider_defined = (responses_tools.hasProviderTool(options.tools, "openai.local_shell") and std.mem.eql(u8, provider_name, "local_shell")) or
        (responses_tools.hasProviderTool(options.tools, "openai.shell") and std.mem.eql(u8, provider_name, "shell")) or
        (responses_tools.hasProviderTool(options.tools, "openai.apply_patch") and std.mem.eql(u8, provider_name, "apply_patch")) or
        responses_tools.isCustomProviderTool(options.tools, provider_name);
    if (options.store and id != null and provider_defined) {
        try input.append(try itemReference(arena, id.?));
        return;
    }

    if (responses_tools.hasProviderTool(options.tools, "openai.local_shell") and std.mem.eql(u8, provider_name, "local_shell")) {
        const root = try requireObjectValue(arena, part.input, diag, "local_shell input must be an object");
        const action = try requireObjectField(arena, root, "action", diag);
        var mapped_action: std.json.ObjectMap = .empty;
        try putString(&mapped_action, arena, "type", "exec");
        if (action.get("command")) |command| try mapped_action.put(arena, "command", try cloneStringArray(arena, command, diag, "local_shell command"));
        try copyOptionalNumber(&mapped_action, arena, action, "timeoutMs", "timeout_ms");
        try copyOptionalString(&mapped_action, arena, action, "user", "user");
        try copyOptionalString(&mapped_action, arena, action, "workingDirectory", "working_directory");
        if (action.get("env")) |env| if (env != .null) try mapped_action.put(arena, "env", try provider_utils.cloneJsonValue(arena, env));
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "local_shell_call");
        try putString(&item, arena, "call_id", part.tool_call_id);
        try putString(&item, arena, "id", id orelse part.tool_call_id);
        try item.put(arena, "action", .{ .object = mapped_action });
        try input.append(.{ .object = item });
        return;
    }

    if (responses_tools.hasProviderTool(options.tools, "openai.shell") and std.mem.eql(u8, provider_name, "shell")) {
        const root = try requireObjectValue(arena, part.input, diag, "shell input must be an object");
        const action = try requireObjectField(arena, root, "action", diag);
        var mapped_action: std.json.ObjectMap = .empty;
        if (action.get("commands")) |commands| try mapped_action.put(arena, "commands", try cloneStringArray(arena, commands, diag, "shell commands"));
        try copyOptionalNumber(&mapped_action, arena, action, "timeoutMs", "timeout_ms");
        try copyOptionalNumber(&mapped_action, arena, action, "maxOutputLength", "max_output_length");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "shell_call");
        try putString(&item, arena, "call_id", part.tool_call_id);
        try putString(&item, arena, "id", id orelse part.tool_call_id);
        try putString(&item, arena, "status", "completed");
        try item.put(arena, "action", .{ .object = mapped_action });
        try input.append(.{ .object = item });
        return;
    }

    if (responses_tools.hasProviderTool(options.tools, "openai.apply_patch") and std.mem.eql(u8, provider_name, "apply_patch")) {
        const root = try requireObjectValue(arena, part.input, diag, "apply_patch input must be an object");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "apply_patch_call");
        try putString(&item, arena, "call_id", optionalString(root, "callId") orelse part.tool_call_id);
        try putString(&item, arena, "id", id orelse part.tool_call_id);
        try putString(&item, arena, "status", "completed");
        try item.put(arena, "operation", try provider_utils.cloneJsonValue(arena, root.get("operation") orelse .null));
        try input.append(.{ .object = item });
        return;
    }

    if (responses_tools.isCustomProviderTool(options.tools, provider_name)) {
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "custom_tool_call");
        try putString(&item, arena, "call_id", part.tool_call_id);
        try putString(&item, arena, "name", provider_name);
        try putString(&item, arena, "input", if (part.input == .string) part.input.string else try provider_utils.stringifyJsonValueAlloc(arena, part.input));
        if (id) |value| try putString(&item, arena, "id", value);
        try input.append(.{ .object = item });
        return;
    }

    // Client function calls are deliberately always reconstructed in full.
    // A function_call_output pairs by call_id (call_...), not by the persisted
    // item id (fc_...), so an item_reference would break subsequent tool steps.
    var item: std.json.ObjectMap = .empty;
    try putString(&item, arena, "type", "function_call");
    try putString(&item, arena, "call_id", part.tool_call_id);
    try putString(&item, arena, "name", provider_name);
    try putString(&item, arena, "arguments", if (part.input == .null) "{}" else try provider_utils.stringifyJsonValueAlloc(arena, part.input));
    if (namespace) |value| try putString(&item, arena, "namespace", value);
    try input.append(.{ .object = item });
}

fn convertAssistantToolResult(
    arena: Allocator,
    input: *std.json.Array,
    warnings: *std.ArrayList(provider.Warning),
    part: provider.ToolResultPart,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    if (isExecutionDenied(part.output)) return;
    if (options.has_conversation) return;
    const provider_name = responses_tools.toProviderToolName(options.tools, part.tool_name);
    if (std.mem.eql(u8, provider_name, "tool_search")) {
        const item_id = partItemId(part.provider_options, options.provider_options_name) orelse part.tool_call_id;
        if (options.store) try input.append(try itemReference(arena, item_id)) else if (part.output == .json) {
            var item: std.json.ObjectMap = .empty;
            try putString(&item, arena, "type", "tool_search_output");
            try putString(&item, arena, "id", item_id);
            try putString(&item, arena, "execution", "server");
            try item.put(arena, "call_id", .null);
            try putString(&item, arena, "status", "completed");
            const root = try requireObjectValue(arena, part.output.json.value, diag, "tool_search output must be an object");
            try item.put(arena, "tools", try provider_utils.cloneJsonValue(arena, root.get("tools") orelse .{ .array = .init(arena) }));
            try input.append(.{ .object = item });
        }
        return;
    }
    if (std.mem.eql(u8, provider_name, "shell") and responses_tools.hasProviderTool(options.tools, "openai.shell")) {
        if (part.output == .json) try input.append(try shellOutputItem(arena, part.tool_call_id, part.output.json.value, diag));
        return;
    }
    if (options.store) {
        try input.append(try itemReference(arena, partItemId(part.provider_options, options.provider_options_name) orelse part.tool_call_id));
    } else try warnings.append(arena, .{ .other = .{
        .message = try std.fmt.allocPrint(arena, "Results for OpenAI tool {s} are not sent to the API when store is false", .{part.tool_name}),
    } });
}

fn convertCompaction(arena: Allocator, input: *std.json.Array, part: provider.CustomPart, options: ConvertOptions) Allocator.Error!void {
    if (!std.mem.eql(u8, part.kind, "openai.compaction")) return;
    const part_options = options_api.namespaceObject(part.provider_options, options.provider_options_name) orelse return;
    const id = optionalString(part_options, "itemId") orelse return;
    if (options.has_conversation) return;
    if (options.store) {
        try input.append(try itemReference(arena, id));
        return;
    }
    const encrypted = optionalString(part_options, "encryptedContent") orelse return;
    var item: std.json.ObjectMap = .empty;
    try putString(&item, arena, "type", "compaction");
    try putString(&item, arena, "id", id);
    try putString(&item, arena, "encrypted_content", encrypted);
    try input.append(.{ .object = item });
}

fn convertToolMessage(
    arena: Allocator,
    input: *std.json.Array,
    warnings: *std.ArrayList(provider.Warning),
    processed_approval_ids: *std.StringHashMapUnmanaged(void),
    message: provider.Message.ToolMessage,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    _ = warnings;
    for (message.content) |part| switch (part) {
        .tool_approval_response => |approval| {
            if (processed_approval_ids.contains(approval.approval_id)) continue;
            try processed_approval_ids.put(arena, approval.approval_id, {});
            if (options.store) try input.append(try itemReference(arena, approval.approval_id));
            var item: std.json.ObjectMap = .empty;
            try putString(&item, arena, "type", "mcp_approval_response");
            try putString(&item, arena, "approval_request_id", approval.approval_id);
            try item.put(arena, "approve", .{ .bool = approval.approved });
            try input.append(.{ .object = item });
        },
        .tool_result => |result| try convertToolResult(arena, input, result, options, diag),
    };
}

fn convertToolResult(
    arena: Allocator,
    input: *std.json.Array,
    part: provider.ToolResultPart,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    if (part.output == .execution_denied) {
        const denied_options = part.output.execution_denied.provider_options;
        if (options_api.namespaceObject(denied_options, options.provider_options_name)) |object| {
            if (optionalString(object, "approvalId") != null) return;
        }
    }
    const provider_name = responses_tools.toProviderToolName(options.tools, part.tool_name);
    if (std.mem.eql(u8, provider_name, "tool_search") and part.output == .json) {
        const root = try requireObjectValue(arena, part.output.json.value, diag, "tool_search output must be an object");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "tool_search_output");
        try putString(&item, arena, "execution", "client");
        try putString(&item, arena, "call_id", part.tool_call_id);
        try putString(&item, arena, "status", "completed");
        try item.put(arena, "tools", try provider_utils.cloneJsonValue(arena, root.get("tools") orelse .{ .array = .init(arena) }));
        try input.append(.{ .object = item });
        return;
    }
    if (std.mem.eql(u8, provider_name, "local_shell") and part.output == .json and
        responses_tools.hasProviderTool(options.tools, "openai.local_shell"))
    {
        const root = try requireObjectValue(arena, part.output.json.value, diag, "local_shell output must be an object");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "local_shell_call_output");
        try putString(&item, arena, "call_id", part.tool_call_id);
        try item.put(arena, "output", try provider_utils.cloneJsonValue(arena, root.get("output") orelse .{ .string = "" }));
        try input.append(.{ .object = item });
        return;
    }
    if (std.mem.eql(u8, provider_name, "shell") and part.output == .json and
        responses_tools.hasProviderTool(options.tools, "openai.shell"))
    {
        try input.append(try shellOutputItem(arena, part.tool_call_id, part.output.json.value, diag));
        return;
    }
    if (std.mem.eql(u8, provider_name, "apply_patch") and part.output == .json and
        responses_tools.hasProviderTool(options.tools, "openai.apply_patch"))
    {
        const root = try requireObjectValue(arena, part.output.json.value, diag, "apply_patch output must be an object");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "type", "apply_patch_call_output");
        try putString(&item, arena, "call_id", part.tool_call_id);
        try putString(&item, arena, "status", optionalString(root, "status") orelse "completed");
        if (root.get("output")) |output| if (output != .null) try item.put(arena, "output", try provider_utils.cloneJsonValue(arena, output));
        try input.append(.{ .object = item });
        return;
    }

    const output = try toolResultOutput(arena, part.output, options, diag);
    var item: std.json.ObjectMap = .empty;
    if (responses_tools.isCustomProviderTool(options.tools, provider_name)) {
        try putString(&item, arena, "type", "custom_tool_call_output");
    } else try putString(&item, arena, "type", "function_call_output");
    try putString(&item, arena, "call_id", part.tool_call_id);
    try item.put(arena, "output", output);
    try input.append(.{ .object = item });
}

fn shellOutputItem(arena: Allocator, call_id: []const u8, value: std.json.Value, diag: ?*provider.Diagnostics) ConvertError!std.json.Value {
    const root = try requireObjectValue(arena, value, diag, "shell output must be an object");
    const source = root.get("output") orelse return typeValidation(arena, diag, "shell output requires output");
    if (source != .array) return typeValidation(arena, diag, "shell output must be an array");
    var output = std.json.Array.init(arena);
    for (source.array.items) |entry| {
        if (entry != .object) return typeValidation(arena, diag, "shell output entry must be an object");
        var mapped: std.json.ObjectMap = .empty;
        try putString(&mapped, arena, "stdout", optionalString(entry.object, "stdout") orelse "");
        try putString(&mapped, arena, "stderr", optionalString(entry.object, "stderr") orelse "");
        const outcome = try requireObjectField(arena, entry.object, "outcome", diag);
        var mapped_outcome: std.json.ObjectMap = .empty;
        const kind = optionalString(outcome, "type") orelse "timeout";
        try putString(&mapped_outcome, arena, "type", kind);
        if (std.mem.eql(u8, kind, "exit")) {
            if (outcome.get("exitCode")) |code| try mapped_outcome.put(arena, "exit_code", try provider_utils.cloneJsonValue(arena, code));
        }
        try mapped.put(arena, "outcome", .{ .object = mapped_outcome });
        try output.append(.{ .object = mapped });
    }
    var item: std.json.ObjectMap = .empty;
    try putString(&item, arena, "type", "shell_call_output");
    try putString(&item, arena, "call_id", call_id);
    try item.put(arena, "output", .{ .array = output });
    return .{ .object = item };
}

fn toolResultOutput(arena: Allocator, output: provider.ToolResultOutput, options: ConvertOptions, diag: ?*provider.Diagnostics) ConvertError!std.json.Value {
    return switch (output) {
        .text => |value| .{ .string = try arena.dupe(u8, value.value) },
        .error_text => |value| .{ .string = try arena.dupe(u8, value.value) },
        .execution_denied => |value| .{ .string = try arena.dupe(u8, value.reason orelse "Tool call execution denied.") },
        .json => |value| .{ .string = try provider_utils.stringifyJsonValueAlloc(arena, value.value) },
        .error_json => |value| .{ .string = try provider_utils.stringifyJsonValueAlloc(arena, value.value) },
        .content => |value| blk: {
            var content = std.json.Array.init(arena);
            for (value.value, 0..) |part, index| switch (part) {
                .text => |text| {
                    var item: std.json.ObjectMap = .empty;
                    try putString(&item, arena, "type", "input_text");
                    try putString(&item, arena, "text", text.text);
                    try addPromptCacheBreakpoint(arena, &item, text.provider_options, options.provider_options_name);
                    try content.append(.{ .object = item });
                },
                .file => |file| try content.append(try convertInputFile(arena, .{
                    .filename = file.filename,
                    .data = file.data,
                    .media_type = file.media_type,
                    .provider_options = file.provider_options,
                }, index, options, diag)),
                .custom => {},
            };
            break :blk .{ .array = content };
        },
    };
}

fn convertInputFile(
    arena: Allocator,
    file: provider.FilePart,
    index: usize,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) ConvertError!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    const top_level = provider_utils.getTopLevelMediaType(file.media_type);
    if (file.data == .reference) {
        const id = try resolveReference(arena, file.data.reference.reference, options.provider_options_name, diag);
        if (std.mem.eql(u8, top_level, "image")) {
            try putString(&object, arena, "type", "input_image");
            try putString(&object, arena, "file_id", id);
            if (partStringOption(file.provider_options, options.provider_options_name, "imageDetail")) |detail| try putString(&object, arena, "detail", detail);
        } else {
            try putString(&object, arena, "type", "input_file");
            try putString(&object, arena, "file_id", id);
        }
        try addPromptCacheBreakpoint(arena, &object, file.provider_options, options.provider_options_name);
        return .{ .object = object };
    }
    if (file.data == .text) return unsupported(arena, diag, "text file parts");

    if (std.mem.eql(u8, top_level, "image")) {
        try putString(&object, arena, "type", "input_image");
        switch (file.data) {
            .url => |url| try putString(&object, arena, "image_url", url.url),
            .data => |data| switch (data.data) {
                .base64 => |base64| if (isFileId(base64))
                    try putString(&object, arena, "file_id", base64)
                else
                    try putString(&object, arena, "image_url", try dataUri(arena, file.media_type, data.data, diag)),
                .bytes => try putString(&object, arena, "image_url", try dataUri(arena, file.media_type, data.data, diag)),
            },
            .reference, .text => unreachable,
        }
        if (partStringOption(file.provider_options, options.provider_options_name, "imageDetail")) |detail| try putString(&object, arena, "detail", detail);
    } else {
        try putString(&object, arena, "type", "input_file");
        switch (file.data) {
            .url => |url| try putString(&object, arena, "file_url", url.url),
            .data => |data| switch (data.data) {
                .base64 => |base64| if (isFileId(base64))
                    try putString(&object, arena, "file_id", base64)
                else {
                    const media_type = try resolvedInlineMediaType(arena, file.media_type, data.data, diag);
                    if (!std.mem.eql(u8, media_type, "application/pdf") and !options.pass_through_unsupported_files) {
                        return unsupported(arena, diag, try std.fmt.allocPrint(arena, "file part media type {s}", .{media_type}));
                    }
                    try putString(&object, arena, "filename", file.filename orelse if (std.mem.eql(u8, media_type, "application/pdf")) try std.fmt.allocPrint(arena, "part-{d}.pdf", .{index}) else try std.fmt.allocPrint(arena, "part-{d}", .{index}));
                    try putString(&object, arena, "file_data", try dataUri(arena, media_type, data.data, diag));
                },
                .bytes => {
                    const media_type = try resolvedInlineMediaType(arena, file.media_type, data.data, diag);
                    if (!std.mem.eql(u8, media_type, "application/pdf") and !options.pass_through_unsupported_files) {
                        return unsupported(arena, diag, try std.fmt.allocPrint(arena, "file part media type {s}", .{media_type}));
                    }
                    try putString(&object, arena, "filename", file.filename orelse if (std.mem.eql(u8, media_type, "application/pdf")) try std.fmt.allocPrint(arena, "part-{d}.pdf", .{index}) else try std.fmt.allocPrint(arena, "part-{d}", .{index}));
                    try putString(&object, arena, "file_data", try dataUri(arena, media_type, data.data, diag));
                },
            },
            .reference, .text => unreachable,
        }
    }
    try addPromptCacheBreakpoint(arena, &object, file.provider_options, options.provider_options_name);
    return .{ .object = object };
}

fn dataUri(arena: Allocator, media_type: []const u8, data: provider.BinaryData, diag: ?*provider.Diagnostics) ConvertError![]const u8 {
    const full_media_type = try resolvedInlineMediaType(arena, media_type, data, diag);
    const encoded = switch (data) {
        .bytes => |bytes| try provider_utils.encodeBase64(arena, bytes),
        .base64 => |base64| try arena.dupe(u8, base64),
    };
    return std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ full_media_type, encoded });
}

fn resolvedInlineMediaType(arena: Allocator, media_type: []const u8, data: provider.BinaryData, diag: ?*provider.Diagnostics) ConvertError![]const u8 {
    if (provider_utils.isFullMediaType(media_type)) return media_type;
    const detected = provider_utils.detectMediaType(arena, switch (data) {
        .bytes => |bytes| .{ .bytes = bytes },
        .base64 => |base64| .{ .base64 = base64 },
    }, provider_utils.getTopLevelMediaType(media_type)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return detected orelse unsupported(arena, diag, "file part media type could not be resolved");
}

fn resolveReference(arena: Allocator, reference: provider.ProviderReference, namespace: []const u8, diag: ?*provider.Diagnostics) ConvertError![]const u8 {
    if (reference == .object) {
        if (reference.object.get(namespace)) |value| if (value == .string) return value.string;
        if (!std.mem.eql(u8, namespace, "openai")) if (reference.object.get("openai")) |value| if (value == .string) return value.string;
    }
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .no_such_provider_reference = .{
            .message = "No OpenAI provider reference was found",
            .provider = namespace,
            .reference_json = try provider_utils.stringifyJsonValueAlloc(arena, reference),
        },
    });
    return error.NoSuchProviderReferenceError;
}

fn summaryText(arena: Allocator, text: []const u8) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "type", "summary_text");
    try putString(&object, arena, "text", text);
    return .{ .object = object };
}

fn itemReference(arena: Allocator, id: []const u8) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "type", "item_reference");
    try putString(&object, arena, "id", id);
    return .{ .object = object };
}

fn partItemId(provider_options: ?provider.ProviderOptions, namespace: []const u8) ?[]const u8 {
    const options = options_api.namespaceObject(provider_options, namespace) orelse return null;
    return optionalString(options, "itemId");
}

fn isExecutionDenied(output: provider.ToolResultOutput) bool {
    if (output == .execution_denied) return true;
    if (output == .json and output.json.value == .object) {
        return std.mem.eql(u8, optionalString(output.json.value.object, "type") orelse "", "execution-denied");
    }
    return false;
}

fn isFileId(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "file-");
}

fn promptCacheBreakpoint(provider_options: ?provider.ProviderOptions, namespace: []const u8) ?std.json.Value {
    const options = options_api.namespaceObject(provider_options, namespace) orelse return null;
    const value = options.get("promptCacheBreakpoint") orelse return null;
    return if (value == .object) value else null;
}

fn partStringOption(provider_options: ?provider.ProviderOptions, namespace: []const u8, name: []const u8) ?[]const u8 {
    const options = options_api.namespaceObject(provider_options, namespace) orelse return null;
    return optionalString(options, name);
}

fn addPromptCacheBreakpoint(arena: Allocator, object: *std.json.ObjectMap, provider_options: ?provider.ProviderOptions, namespace: []const u8) Allocator.Error!void {
    if (promptCacheBreakpoint(provider_options, namespace)) |breakpoint| {
        try object.put(arena, "prompt_cache_breakpoint", try provider_utils.cloneJsonValue(arena, breakpoint));
    }
}

fn nullableString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn nullish(value: ?std.json.Value) bool {
    const item = value orelse return true;
    return item == .null;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn requireObjectValue(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics, message: []const u8) provider.Error!std.json.ObjectMap {
    return if (value == .object) value.object else typeValidation(arena, diag, message);
}

fn requireObjectField(arena: Allocator, object: std.json.ObjectMap, name: []const u8, diag: ?*provider.Diagnostics) provider.Error!std.json.ObjectMap {
    const value = object.get(name) orelse return typeValidation(arena, diag, "required object field is missing");
    return requireObjectValue(arena, value, diag, "required field must be an object");
}

fn cloneStringArray(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics, message: []const u8) ConvertError!std.json.Value {
    if (value != .array) return typeValidation(arena, diag, message);
    var output = std.json.Array.init(arena);
    for (value.array.items) |item| {
        if (item != .string) return typeValidation(arena, diag, message);
        try output.append(.{ .string = try arena.dupe(u8, item.string) });
    }
    return .{ .array = output };
}

fn copyOptionalString(destination: *std.json.ObjectMap, arena: Allocator, source: std.json.ObjectMap, source_name: []const u8, destination_name: []const u8) Allocator.Error!void {
    if (optionalString(source, source_name)) |value| try putString(destination, arena, destination_name, value);
}

fn copyOptionalNumber(destination: *std.json.ObjectMap, arena: Allocator, source: std.json.ObjectMap, source_name: []const u8, destination_name: []const u8) Allocator.Error!void {
    if (source.get(source_name)) |value| switch (value) {
        .integer, .float, .number_string => try destination.put(arena, destination_name, try provider_utils.cloneJsonValue(arena, value)),
        else => {},
    };
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn unsupported(arena: Allocator, diag: ?*provider.Diagnostics, functionality: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .unsupported_functionality = .{
            .message = "OpenAI Responses prompt feature is unsupported",
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

test "Responses input preserves store references but never references client function calls" {
    // Fixture ported verbatim in shape from
    // convert-to-openai-responses-input.test.ts "should not use
    // item_reference for client-executed tool calls (store: true)".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"itemId\":\"msg_123\"}}", .{});
    const call_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"itemId\":\"fc_456\"}}", .{});
    var arguments: std.json.ObjectMap = .empty;
    try arguments.put(arena, "query", .{ .string = "weather in San Francisco" });
    const content = [_]provider.AssistantContentPart{
        .{ .text = .{ .text = "I will search.", .provider_options = text_options } },
        .{ .tool_call = .{ .tool_call_id = "call_123", .tool_name = "search", .input = .{ .object = arguments }, .provider_options = call_options } },
    };
    const prompt = [_]provider.Message{.{ .assistant = .{ .content = &content } }};
    const result = try convertToOpenAIResponsesInput(arena, &prompt, .{
        .system_message_mode = .system,
        .provider_options_name = "openai",
        .store = true,
    }, null);
    try std.testing.expectEqual(2, result.value.array.items.len);
    try std.testing.expectEqualStrings("item_reference", result.value.array.items[0].object.get("type").?.string);
    const call = result.value.array.items[1].object;
    try std.testing.expectEqualStrings("function_call", call.get("type").?.string);
    try std.testing.expect(call.get("id") == null);
}

test "Responses input merges store-false reasoning and keeps encrypted content" {
    // Fixture ported from convert-to-openai-responses-input.test.ts
    // "should merge consecutive parts with same reasoning ID".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"itemId\":\"reasoning_001\"}}", .{});
    const second_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"itemId\":\"reasoning_001\",\"reasoningEncryptedContent\":\"encrypted_content_001\"}}", .{});
    const content = [_]provider.AssistantContentPart{
        .{ .reasoning = .{ .text = "First reasoning step", .provider_options = first_options } },
        .{ .reasoning = .{ .text = "Second reasoning step", .provider_options = second_options } },
    };
    const prompt = [_]provider.Message{.{ .assistant = .{ .content = &content } }};
    const result = try convertToOpenAIResponsesInput(arena, &prompt, .{
        .system_message_mode = .developer,
        .provider_options_name = "openai",
        .store = false,
    }, null);
    const reasoning = result.value.array.items[0].object;
    try std.testing.expectEqualStrings("encrypted_content_001", reasoning.get("encrypted_content").?.string);
    try std.testing.expectEqual(2, reasoning.get("summary").?.array.items.len);
}

test "Responses input matrix maps user text images files references detail and developer messages" {
    // Fixture matrix ported from the user/system sections of
    // convert-to-openai-responses-input.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const detail = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"imageDetail\":\"high\"}}", .{});
    var reference_object: std.json.ObjectMap = .empty;
    try reference_object.put(arena, "openai", .{ .string = "file-image-123" });
    const user_content = [_]provider.UserContentPart{
        .{ .text = .{ .text = "Hello" } },
        .{ .file = .{ .media_type = "image/png", .data = .{ .url = .{ .url = "https://example.test/image.png" } }, .provider_options = detail } },
        .{ .file = .{ .media_type = "image/jpeg", .data = .{ .reference = .{ .reference = .{ .object = reference_object } } } } },
        .{ .file = .{ .media_type = "application/pdf", .data = .{ .url = .{ .url = "https://example.test/document.pdf" } } } },
        .{ .file = .{ .media_type = "application/pdf", .filename = "inline.pdf", .data = .{ .data = .{ .data = .{ .bytes = "%PDF" } } } } },
    };
    const prompt = [_]provider.Message{
        .{ .system = .{ .content = "Rules" } },
        .{ .user = .{ .content = &user_content } },
    };
    const result = try convertToOpenAIResponsesInput(arena, &prompt, .{
        .system_message_mode = .developer,
        .provider_options_name = "openai",
        .store = true,
    }, null);
    try std.testing.expectEqualStrings("developer", result.value.array.items[0].object.get("role").?.string);
    const content = result.value.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(5, content.len);
    try std.testing.expectEqualStrings("input_text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("https://example.test/image.png", content[1].object.get("image_url").?.string);
    try std.testing.expectEqualStrings("high", content[1].object.get("detail").?.string);
    try std.testing.expectEqualStrings("file-image-123", content[2].object.get("file_id").?.string);
    try std.testing.expectEqualStrings("https://example.test/document.pdf", content[3].object.get("file_url").?.string);
    try std.testing.expectEqualStrings("inline.pdf", content[4].object.get("filename").?.string);
    try std.testing.expect(std.mem.startsWith(u8, content[4].object.get("file_data").?.string, "data:application/pdf;base64,"));
}

test "Responses input round-trips item references approvals and compaction by store mode" {
    // Fixtures ported from the item-reference, MCP approval, and compaction
    // sections of convert-to-openai-responses-input.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"itemId\":\"msg_1\",\"phase\":\"final_answer\"}}", .{});
    const compaction_options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"openai\":{\"type\":\"compaction\",\"itemId\":\"cmp_1\",\"encryptedContent\":\"compact-secret\"}}", .{});
    const assistant = [_]provider.AssistantContentPart{
        .{ .text = .{ .text = "answer", .provider_options = text_options } },
        .{ .custom = .{ .kind = "openai.compaction", .provider_options = compaction_options } },
    };
    const tool = [_]provider.ToolContentPart{.{ .tool_approval_response = .{ .approval_id = "approval_1", .approved = true } }};
    const prompt = [_]provider.Message{
        .{ .assistant = .{ .content = &assistant } },
        .{ .tool = .{ .content = &tool } },
    };
    const stored = try convertToOpenAIResponsesInput(arena, &prompt, .{
        .system_message_mode = .system,
        .provider_options_name = "openai",
        .store = true,
    }, null);
    try std.testing.expectEqualStrings("item_reference", stored.value.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("msg_1", stored.value.array.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("cmp_1", stored.value.array.items[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("approval_1", stored.value.array.items[2].object.get("id").?.string);
    try std.testing.expectEqualStrings("mcp_approval_response", stored.value.array.items[3].object.get("type").?.string);

    const unstored = try convertToOpenAIResponsesInput(arena, &prompt, .{
        .system_message_mode = .system,
        .provider_options_name = "openai",
        .store = false,
    }, null);
    try std.testing.expectEqualStrings("assistant", unstored.value.array.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("final_answer", unstored.value.array.items[0].object.get("phase").?.string);
    try std.testing.expectEqualStrings("compaction", unstored.value.array.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("compact-secret", unstored.value.array.items[1].object.get("encrypted_content").?.string);
    try std.testing.expectEqualStrings("mcp_approval_response", unstored.value.array.items[2].object.get("type").?.string);
}
