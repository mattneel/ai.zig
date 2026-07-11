const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const ToolCallErrorWire = struct {
    kind: []const u8,
    message: []const u8,
    code: []const u8,
    original_kind: ?[]const u8 = null,
};

const ToolCallWire = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: std.json.Value,
    provider_executed: bool,
    provider_metadata: ?provider.ProviderMetadata,
    tool_metadata: ?std.json.Value,
    dynamic: bool,
    invalid: bool,
    err: ?ToolCallErrorWire,
};

const ToolResultWire = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: ?std.json.Value,
    output: std.json.Value,
    provider_executed: bool,
    provider_metadata: ?provider.ProviderMetadata,
    tool_metadata: ?std.json.Value,
    dynamic: bool,
    preliminary: bool,
};

const ToolErrorWire = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: ?std.json.Value,
    error_value: std.json.Value,
    error_code: ?[]const u8,
    provider_executed: bool,
    provider_metadata: ?provider.ProviderMetadata,
    tool_metadata: ?std.json.Value,
    dynamic: bool,

    pub const wire_field_names = .{
        .{ "error_value", "error" },
    };
};

const ApprovalRequestWire = struct {
    approval_id: []const u8,
    tool_call: std.json.Value,
    is_automatic: bool,
    signature: ?[]const u8,
};

const ApprovalResponseWire = struct {
    approval_id: []const u8,
    tool_call: std.json.Value,
    approved: bool,
    reason: ?[]const u8,
    provider_executed: bool,
};

const StreamErrorWire = struct {
    error_value: std.json.Value,
    error_code: ?[]const u8,

    pub const wire_field_names = .{
        .{ "error_value", "error" },
    };
};

pub fn contentValues(arena: Allocator, values: []const ai.ContentPart) ![]const std.json.Value {
    const result = try arena.alloc(std.json.Value, values.len);
    for (values, result) |value, *destination| destination.* = try contentValue(arena, value);
    return result;
}

pub fn contentValue(arena: Allocator, value: ai.ContentPart) !std.json.Value {
    return switch (value) {
        .text => |payload| taggedWire(arena, "text", payload),
        .reasoning => |payload| taggedWire(arena, "reasoning", payload),
        .reasoning_file => |payload| taggedWire(arena, "reasoning-file", payload),
        .file => |payload| taggedWire(arena, "file", payload),
        .source => |payload| taggedWire(arena, "source", payload),
        .custom => |payload| taggedWire(arena, "custom", payload),
        .tool_call => |payload| taggedValue(arena, "tool-call", try toolCallValue(arena, payload)),
        .tool_result => |payload| taggedValue(arena, "tool-result", try toolResultValue(arena, payload)),
        .tool_error => |payload| taggedValue(arena, "tool-error", try toolErrorValue(arena, payload)),
        .tool_approval_request => |payload| taggedWire(arena, "tool-approval-request", ApprovalRequestWire{
            .approval_id = payload.approval_id,
            .tool_call = try toolCallValue(arena, payload.tool_call),
            .is_automatic = payload.is_automatic,
            .signature = payload.signature,
        }),
        .tool_approval_response => |payload| taggedWire(arena, "tool-approval-response", ApprovalResponseWire{
            .approval_id = payload.approval_id,
            .tool_call = try toolCallValue(arena, payload.tool_call),
            .approved = payload.approved,
            .reason = payload.reason,
            .provider_executed = payload.provider_executed,
        }),
    };
}

pub fn partType(value: ai.TextStreamPart) types.PartType {
    return switch (value) {
        .text_start => .text_start,
        .text_end => .text_end,
        .text_delta => .text_delta,
        .reasoning_start => .reasoning_start,
        .reasoning_end => .reasoning_end,
        .reasoning_delta => .reasoning_delta,
        .custom => .custom,
        .tool_input_start => .tool_input_start,
        .tool_input_end => .tool_input_end,
        .tool_input_delta => .tool_input_delta,
        .source => .source,
        .file => .file,
        .reasoning_file => .reasoning_file,
        .tool_call => .tool_call,
        .tool_result => .tool_result,
        .tool_error => .tool_error,
        .tool_output_denied => .tool_output_denied,
        .tool_approval_request => .tool_approval_request,
        .tool_approval_response => .tool_approval_response,
        .start_step => .start_step,
        .finish_step => .finish_step,
        .start => .start,
        .finish => .finish,
        .abort => .abort,
        .err => .err,
        .raw => .raw,
    };
}

pub fn partText(value: ai.TextStreamPart) ?[]const u8 {
    return switch (value) {
        .text_delta => |payload| payload.text,
        else => null,
    };
}

pub fn partValue(arena: Allocator, value: ai.TextStreamPart) !std.json.Value {
    return switch (value) {
        .text_start => |payload| taggedWire(arena, "text-start", payload),
        .text_end => |payload| taggedWire(arena, "text-end", payload),
        .text_delta => |payload| taggedWire(arena, "text-delta", payload),
        .reasoning_start => |payload| taggedWire(arena, "reasoning-start", payload),
        .reasoning_end => |payload| taggedWire(arena, "reasoning-end", payload),
        .reasoning_delta => |payload| taggedWire(arena, "reasoning-delta", payload),
        .custom => |payload| taggedWire(arena, "custom", payload),
        .tool_input_start => |payload| taggedWire(arena, "tool-input-start", payload),
        .tool_input_end => |payload| taggedWire(arena, "tool-input-end", payload),
        .tool_input_delta => |payload| taggedWire(arena, "tool-input-delta", payload),
        .source => |payload| taggedWire(arena, "source", payload),
        .file => |payload| taggedWire(arena, "file", payload),
        .reasoning_file => |payload| taggedWire(arena, "reasoning-file", payload),
        .tool_call => |payload| taggedValue(arena, "tool-call", try toolCallValue(arena, payload)),
        .tool_result => |payload| taggedValue(arena, "tool-result", try toolResultValue(arena, payload)),
        .tool_error => |payload| taggedValue(arena, "tool-error", try toolErrorValue(arena, payload)),
        .tool_output_denied => |payload| taggedWire(arena, "tool-output-denied", payload),
        .tool_approval_request => |payload| taggedWire(arena, "tool-approval-request", ApprovalRequestWire{
            .approval_id = payload.approval_id,
            .tool_call = try toolCallValue(arena, payload.tool_call),
            .is_automatic = payload.is_automatic,
            .signature = payload.signature,
        }),
        .tool_approval_response => |payload| taggedWire(arena, "tool-approval-response", ApprovalResponseWire{
            .approval_id = payload.approval_id,
            .tool_call = try toolCallValue(arena, payload.tool_call),
            .approved = payload.approved,
            .reason = payload.reason,
            .provider_executed = payload.provider_executed,
        }),
        .start_step => |payload| taggedWire(arena, "start-step", payload),
        .finish_step => |payload| taggedWire(arena, "finish-step", payload),
        .start => taggedOnly(arena, "start"),
        .finish => |payload| taggedWire(arena, "finish", payload),
        .abort => |payload| taggedWire(arena, "abort", payload),
        .err => |payload| taggedWire(arena, "error", StreamErrorWire{
            .error_value = payload.error_value,
            .error_code = if (payload.error_code) |err| @errorName(err) else null,
        }),
        .raw => |payload| taggedWire(arena, "raw", struct { raw_value: std.json.Value }{
            .raw_value = payload,
        }),
    };
}

pub fn stringifyPart(arena: Allocator, value: ai.TextStreamPart) ![]u8 {
    return provider.wire.stringifyAlloc(arena, try partValue(arena, value));
}

pub fn finishReasonName(value: provider.FinishReason) []const u8 {
    return switch (value.unified) {
        .stop => "stop",
        .length => "length",
        .content_filter => "content-filter",
        .tool_calls => "tool-calls",
        .@"error" => "error",
        .other => "other",
    };
}

fn toolCallValue(arena: Allocator, value: ai.TypedToolCall) !std.json.Value {
    const retained_error: ?ToolCallErrorWire = if (value.err) |err| .{
        .kind = @tagName(err.kind),
        .message = err.message,
        .code = @errorName(err.err),
        .original_kind = if (err.original_kind) |kind| @tagName(kind) else null,
    } else null;
    return wireValue(arena, ToolCallWire{
        .tool_call_id = value.tool_call_id,
        .tool_name = value.tool_name,
        .input = value.input,
        .provider_executed = value.provider_executed,
        .provider_metadata = value.provider_metadata,
        .tool_metadata = value.tool_metadata,
        .dynamic = value.dynamic,
        .invalid = value.invalid,
        .err = retained_error,
    });
}

fn toolResultValue(arena: Allocator, value: ai.TypedToolResult) !std.json.Value {
    return wireValue(arena, ToolResultWire{
        .tool_call_id = value.tool_call_id,
        .tool_name = value.tool_name,
        .input = value.input,
        .output = value.output,
        .provider_executed = value.provider_executed,
        .provider_metadata = value.provider_metadata,
        .tool_metadata = value.tool_metadata,
        .dynamic = value.dynamic,
        .preliminary = value.preliminary,
    });
}

fn toolErrorValue(arena: Allocator, value: ai.TypedToolError) !std.json.Value {
    return wireValue(arena, ToolErrorWire{
        .tool_call_id = value.tool_call_id,
        .tool_name = value.tool_name,
        .input = value.input,
        .error_value = value.error_value,
        .error_code = if (value.error_code) |err| @errorName(err) else null,
        .provider_executed = value.provider_executed,
        .provider_metadata = value.provider_metadata,
        .tool_metadata = value.tool_metadata,
        .dynamic = value.dynamic,
    });
}

fn taggedWire(arena: Allocator, tag: []const u8, payload: anytype) !std.json.Value {
    return taggedValue(arena, tag, try wireValue(arena, payload));
}

fn taggedOnly(arena: Allocator, tag: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "type", .{ .string = tag });
    return .{ .object = object };
}

fn taggedValue(arena: Allocator, tag: []const u8, payload: std.json.Value) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "type", .{ .string = tag });
    if (payload == .object) {
        var iterator = payload.object.iterator();
        while (iterator.next()) |entry| {
            try object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    } else {
        try object.put(arena, "value", payload);
    }
    return .{ .object = object };
}

fn wireValue(arena: Allocator, payload: anytype) !std.json.Value {
    const text = try provider.wire.stringifyAlloc(arena, payload);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
}

test "text stream part uses canonical tag and text payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const part: ai.TextStreamPart = .{ .text_delta = .{ .id = "t", .text = "hello" } };
    const json = try stringifyPart(arena, part);
    try std.testing.expectEqualStrings(
        "{\"type\":\"text-delta\",\"id\":\"t\",\"text\":\"hello\"}",
        json,
    );
    try std.testing.expectEqual(types.PartType.text_delta, partType(part));
}
