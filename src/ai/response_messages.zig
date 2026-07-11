//! Shared conversion from assembled step content to continuation messages.
//!
//! Both `generateText` and `streamText` use this path so tool-result ordering,
//! approval replay, and provider/client error encoding cannot drift.

const std = @import("std");
const provider = @import("provider");
const message = @import("message.zig");
const prompt_api = @import("prompt.zig");
const tool_api = @import("tool.zig");
const tool_common = @import("tool_execution_common.zig");
const types = @import("generate_text_types.zig");

const Allocator = std.mem.Allocator;

pub fn toResponseMessages(
    arena: Allocator,
    tools: tool_api.ToolSet,
    input_content: []const types.ContentPart,
) anyerror![]const message.ModelMessage {
    var result: std.ArrayList(message.ModelMessage) = .empty;
    defer result.deinit(arena);
    var assistant: std.ArrayList(message.AssistantContentPart) = .empty;
    defer assistant.deinit(arena);
    var tool_content: std.ArrayList(message.ToolContentPart) = .empty;
    defer tool_content.deinit(arena);
    var call_order: std.ArrayList([]const u8) = .empty;
    defer call_order.deinit(arena);

    for (input_content) |part| switch (part) {
        .source => {},
        .text => |value| if (value.text.len != 0) try assistant.append(arena, .{ .text = .{
            .text = value.text,
            .provider_options = value.provider_metadata,
        } }),
        .reasoning => |value| try assistant.append(arena, .{ .reasoning = .{
            .text = value.text,
            .provider_options = value.provider_metadata,
        } }),
        .custom => |value| try assistant.append(arena, .{ .custom = .{
            .kind = value.kind,
            .provider_options = value.provider_metadata,
        } }),
        .file => |value| try assistant.append(arena, .{ .file = generatedFileMessage(value) }),
        .reasoning_file => |value| try assistant.append(arena, .{ .reasoning_file = generatedReasoningFileMessage(value) }),
        .tool_call => |value| {
            if (orderOf(call_order.items, value.tool_call_id) == null) {
                try call_order.append(arena, value.tool_call_id);
            }
            try assistant.append(arena, .{ .tool_call = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .input = if (value.invalid and value.input != .object) emptyJsonObject() else value.input,
                .provider_executed = value.provider_executed,
                .provider_options = value.provider_metadata,
            } });
        },
        .tool_result => |value| if (value.provider_executed) {
            const model_output = try prompt_api.createToolModelOutput(
                arena,
                value.tool_call_id,
                value.input orelse std.json.Value.null,
                value.output,
                if (tool_common.findTool(tools, value.tool_name)) |named| &named.tool else null,
                .none,
            );
            try assistant.append(arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .output = model_output,
                .provider_options = value.provider_metadata,
            } });
        },
        .tool_error => |value| if (value.provider_executed) {
            const model_output = try prompt_api.createToolModelOutput(
                arena,
                value.tool_call_id,
                value.input orelse std.json.Value.null,
                value.error_value,
                if (tool_common.findTool(tools, value.tool_name)) |named| &named.tool else null,
                .json,
            );
            try assistant.append(arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .output = model_output,
                .provider_options = value.provider_metadata,
            } });
        },
        .tool_approval_request => |value| try assistant.append(arena, .{ .tool_approval_request = .{
            .approval_id = value.approval_id,
            .tool_call_id = value.tool_call.tool_call_id,
            .is_automatic = value.is_automatic,
            .signature = value.signature,
        } }),
        .tool_approval_response => {},
    };

    if (assistant.items.len != 0) try result.append(arena, .{ .assistant = .{
        .content = .{ .parts = try assistant.toOwnedSlice(arena) },
    } });

    for (input_content) |part| switch (part) {
        .tool_approval_response => |value| {
            try tool_content.append(arena, .{ .tool_approval_response = .{
                .approval_id = value.approval_id,
                .approved = value.approved,
                .reason = value.reason,
                .provider_executed = value.provider_executed,
            } });
            if (!value.approved) try tool_content.append(arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call.tool_call_id,
                .tool_name = value.tool_call.tool_name,
                .output = .{ .execution_denied = .{ .reason = value.reason } },
            } });
        },
        .tool_result => |value| if (!value.provider_executed) {
            const model_output = try prompt_api.createToolModelOutput(
                arena,
                value.tool_call_id,
                value.input orelse std.json.Value.null,
                value.output,
                if (tool_common.findTool(tools, value.tool_name)) |named| &named.tool else null,
                .none,
            );
            try tool_content.append(arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .output = model_output,
                .provider_options = value.provider_metadata,
            } });
        },
        .tool_error => |value| if (!value.provider_executed) {
            const model_output = try prompt_api.createToolModelOutput(
                arena,
                value.tool_call_id,
                value.input orelse std.json.Value.null,
                value.error_value,
                if (tool_common.findTool(tools, value.tool_name)) |named| &named.tool else null,
                .text,
            );
            try tool_content.append(arena, .{ .tool_result = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .output = model_output,
                .provider_options = value.provider_metadata,
            } });
        },
        else => {},
    };

    if (tool_content.items.len != 0) {
        const sorted = try sortToolResults(arena, tool_content.items, call_order.items);
        try result.append(arena, .{ .tool = .{ .content = sorted } });
    }
    return result.toOwnedSlice(arena);
}

const SortableToolResult = struct {
    part: message.ToolContentPart,
    original_index: usize,
    order: ?usize,
};

fn sortToolResults(
    arena: Allocator,
    content: []const message.ToolContentPart,
    call_order: []const []const u8,
) Allocator.Error![]const message.ToolContentPart {
    var sortable: std.ArrayList(SortableToolResult) = .empty;
    defer sortable.deinit(arena);
    for (content, 0..) |part, index| switch (part) {
        .tool_result => |value| try sortable.append(arena, .{
            .part = part,
            .original_index = index,
            .order = orderOf(call_order, value.tool_call_id),
        }),
        else => {},
    };
    std.mem.sort(SortableToolResult, sortable.items, {}, struct {
        fn lessThan(_: void, a: SortableToolResult, b: SortableToolResult) bool {
            if (a.order == null and b.order == null) return a.original_index < b.original_index;
            if (a.order == null) return false;
            if (b.order == null) return true;
            if (a.order.? == b.order.?) return a.original_index < b.original_index;
            return a.order.? < b.order.?;
        }
    }.lessThan);

    const output = try arena.alloc(message.ToolContentPart, content.len);
    var result_index: usize = 0;
    for (content, output) |part, *destination| switch (part) {
        .tool_result => {
            destination.* = sortable.items[result_index].part;
            result_index += 1;
        },
        else => destination.* = part,
    };
    return output;
}

fn orderOf(order: []const []const u8, id: []const u8) ?usize {
    for (order, 0..) |value, index| if (std.mem.eql(u8, value, id)) return index;
    return null;
}

fn generatedFileMessage(value: provider.GeneratedFile) message.FilePart {
    return .{
        .data = generatedFileData(value.data),
        .media_type = value.media_type,
        .provider_options = value.provider_metadata,
    };
}

fn generatedReasoningFileMessage(value: provider.GeneratedReasoningFile) message.ReasoningFilePart {
    return .{
        .data = generatedFileData(value.data),
        .media_type = value.media_type,
        .provider_options = value.provider_metadata,
    };
}

fn generatedFileData(value: provider.GeneratedFileData) message.FilePartData {
    return switch (value) {
        .data => |data| .{ .data = switch (data.data) {
            .bytes => |bytes| .{ .bytes = bytes },
            .base64 => |base64| .{ .base64 = base64 },
        } },
        .url => |url| .{ .data = .{ .base64 = url.url } },
    };
}

fn emptyJsonObject() std.json.Value {
    return .{ .object = .empty };
}

test "shared response-message conversion preserves client tool-call order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const content = [_]types.ContentPart{
        .{ .tool_call = .{ .tool_call_id = "b", .tool_name = "tool", .input = .null } },
        .{ .tool_call = .{ .tool_call_id = "a", .tool_name = "tool", .input = .null } },
        .{ .tool_result = .{ .tool_call_id = "a", .tool_name = "tool", .input = .null, .output = .{ .string = "a" } } },
        .{ .tool_result = .{ .tool_call_id = "b", .tool_name = "tool", .input = .null, .output = .{ .string = "b" } } },
    };
    const messages = try toResponseMessages(arena, &.{}, &content);
    try std.testing.expectEqual(2, messages.len);
    try std.testing.expectEqualStrings("b", messages[1].tool.content[0].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("a", messages[1].tool.content[1].tool_result.tool_call_id);
}
