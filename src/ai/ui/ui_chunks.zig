//! Strict UI message stream wire vocabulary.
//!
//! Provider model wire parsing is intentionally tolerant of unknown fields.
//! UI chunks are client-facing protocol messages and therefore reject both
//! unknown discriminators and unknown fields.

const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const Empty = struct {};

pub const TextStart = struct {
    id: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const TextDelta = struct {
    id: []const u8,
    delta: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ErrorChunk = struct { error_text: []const u8 };

pub const ToolInputStart = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    provider_executed: ?bool = null,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?JsonValue = null,
    dynamic: ?bool = null,
    title: ?[]const u8 = null,
};

pub const ToolInputDelta = struct {
    tool_call_id: []const u8,
    input_text_delta: []const u8,
};

pub const ToolInputAvailable = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: JsonValue,
    provider_executed: ?bool = null,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?JsonValue = null,
    dynamic: ?bool = null,
    title: ?[]const u8 = null,
};

pub const ToolInputError = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: JsonValue,
    provider_executed: ?bool = null,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?JsonValue = null,
    dynamic: ?bool = null,
    error_text: []const u8,
    title: ?[]const u8 = null,
};

pub const ToolApprovalRequest = struct {
    approval_id: []const u8,
    tool_call_id: []const u8,
    is_automatic: ?bool = null,
    signature: ?[]const u8 = null,
};

pub const ToolApprovalResponse = struct {
    approval_id: []const u8,
    approved: bool,
    reason: ?[]const u8 = null,
    provider_executed: ?bool = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ToolOutputAvailable = struct {
    tool_call_id: []const u8,
    output: JsonValue,
    provider_executed: ?bool = null,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?JsonValue = null,
    dynamic: ?bool = null,
    preliminary: ?bool = null,
};

pub const ToolOutputError = struct {
    tool_call_id: []const u8,
    error_text: []const u8,
    provider_executed: ?bool = null,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?JsonValue = null,
    dynamic: ?bool = null,
};

pub const ToolOutputDenied = struct { tool_call_id: []const u8 };

pub const Custom = struct {
    kind: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const SourceUrl = struct {
    source_id: []const u8,
    url: []const u8,
    title: ?[]const u8 = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const SourceDocument = struct {
    source_id: []const u8,
    media_type: []const u8,
    title: []const u8,
    filename: ?[]const u8 = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const File = struct {
    url: []const u8,
    media_type: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const Data = struct {
    name: []const u8,
    id: ?[]const u8 = null,
    data: JsonValue,
    transient: ?bool = null,
};

pub const Start = struct {
    message_id: ?[]const u8 = null,
    message_metadata: ?JsonValue = null,
};

pub const Finish = struct {
    finish_reason: ?provider.FinishReasonUnified = null,
    message_metadata: ?JsonValue = null,
};

pub const Abort = struct { reason: ?[]const u8 = null };
pub const MessageMetadata = struct { message_metadata: JsonValue };

const StaticChunk = union(enum) {
    text_start: TextStart,
    text_delta: TextDelta,
    text_end: TextStart,
    reasoning_start: TextStart,
    reasoning_delta: TextDelta,
    reasoning_end: TextStart,
    err: ErrorChunk,
    tool_input_start: ToolInputStart,
    tool_input_delta: ToolInputDelta,
    tool_input_available: ToolInputAvailable,
    tool_input_error: ToolInputError,
    tool_approval_request: ToolApprovalRequest,
    tool_approval_response: ToolApprovalResponse,
    tool_output_available: ToolOutputAvailable,
    tool_output_error: ToolOutputError,
    tool_output_denied: ToolOutputDenied,
    custom: Custom,
    source_url: SourceUrl,
    source_document: SourceDocument,
    file: File,
    reasoning_file: File,
    start_step: Empty,
    finish_step: Empty,
    start: Start,
    finish: Finish,
    abort: Abort,
    message_metadata: MessageMetadata,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text_start, "text-start" },
        .{ .text_delta, "text-delta" },
        .{ .text_end, "text-end" },
        .{ .reasoning_start, "reasoning-start" },
        .{ .reasoning_delta, "reasoning-delta" },
        .{ .reasoning_end, "reasoning-end" },
        .{ .err, "error" },
        .{ .tool_input_start, "tool-input-start" },
        .{ .tool_input_delta, "tool-input-delta" },
        .{ .tool_input_available, "tool-input-available" },
        .{ .tool_input_error, "tool-input-error" },
        .{ .tool_approval_request, "tool-approval-request" },
        .{ .tool_approval_response, "tool-approval-response" },
        .{ .tool_output_available, "tool-output-available" },
        .{ .tool_output_error, "tool-output-error" },
        .{ .tool_output_denied, "tool-output-denied" },
        .{ .custom, "custom" },
        .{ .source_url, "source-url" },
        .{ .source_document, "source-document" },
        .{ .file, "file" },
        .{ .reasoning_file, "reasoning-file" },
        .{ .start_step, "start-step" },
        .{ .finish_step, "finish-step" },
        .{ .start, "start" },
        .{ .finish, "finish" },
        .{ .abort, "abort" },
        .{ .message_metadata, "message-metadata" },
    };
};

pub const UIMessageChunk = union(enum) {
    text_start: TextStart,
    text_delta: TextDelta,
    text_end: TextStart,
    reasoning_start: TextStart,
    reasoning_delta: TextDelta,
    reasoning_end: TextStart,
    err: ErrorChunk,
    tool_input_start: ToolInputStart,
    tool_input_delta: ToolInputDelta,
    tool_input_available: ToolInputAvailable,
    tool_input_error: ToolInputError,
    tool_approval_request: ToolApprovalRequest,
    tool_approval_response: ToolApprovalResponse,
    tool_output_available: ToolOutputAvailable,
    tool_output_error: ToolOutputError,
    tool_output_denied: ToolOutputDenied,
    custom: Custom,
    source_url: SourceUrl,
    source_document: SourceDocument,
    file: File,
    reasoning_file: File,
    data: Data,
    start_step: Empty,
    finish_step: Empty,
    start: Start,
    finish: Finish,
    abort: Abort,
    message_metadata: MessageMetadata,

    pub fn wireParse(arena: Allocator, value: JsonValue) provider.wire.ParseError!UIMessageChunk {
        const object = switch (value) {
            .object => |item| item,
            else => return error.TypeValidationError,
        };
        const type_value = object.get("type") orelse return error.TypeValidationError;
        const type_name = switch (type_value) {
            .string => |item| item,
            else => return error.TypeValidationError,
        };
        try checkStrictFields(type_name, object);
        if (std.mem.startsWith(u8, type_name, "data-") and type_name.len > "data-".len) {
            return .{ .data = .{
                .name = try arena.dupe(u8, type_name["data-".len..]),
                .id = try optionalString(arena, object, "id"),
                .data = try provider.wire.parse(JsonValue, arena, object.get("data") orelse return error.TypeValidationError),
                .transient = try optionalBool(object, "transient"),
            } };
        }
        return fromStatic(try provider.wire.parse(StaticChunk, arena, value));
    }

    pub fn wireWrite(value: UIMessageChunk, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (value) {
            .data => |part| {
                try writer.beginObject();
                try writer.objectField("type");
                var type_buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
                defer type_buffer.deinit();
                try type_buffer.writer.writeAll("data-");
                try type_buffer.writer.writeAll(part.name);
                try writer.write(type_buffer.writer.buffered());
                if (part.id) |id| {
                    try writer.objectField("id");
                    try writer.write(id);
                }
                try writer.objectField("data");
                try writer.write(part.data);
                if (part.transient) |transient| {
                    try writer.objectField("transient");
                    try writer.write(transient);
                }
                try writer.endObject();
            },
            inline else => |payload, tag| try provider.wire.write(toStatic(tag, payload), writer),
        }
    }
};

pub fn parseChunk(
    arena: Allocator,
    json_text: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!UIMessageChunk {
    const value = std.json.parseFromSliceLeaky(JsonValue, arena, json_text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setDiagnostic(diag, "invalid JSON UI message chunk", "unknown", "");
            return error.UIMessageStreamError;
        },
    };
    return parseChunkValue(arena, value, diag);
}

pub fn parseChunkValue(
    arena: Allocator,
    value: JsonValue,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!UIMessageChunk {
    const identity = chunkIdentity(value);
    return UIMessageChunk.wireParse(arena, value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            setDiagnostic(diag, switch (err) {
                error.UnknownUnionTag => "unknown UI message chunk type",
                error.UIMessageStreamError => "UI message chunk contains an unknown field",
                else => "UI message chunk failed strict validation",
            }, identity.type_name, identity.id);
            return error.UIMessageStreamError;
        },
    };
}

pub fn writeChunk(value: UIMessageChunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return provider.wire.writeValue(value, writer);
}

pub fn cloneChunk(arena: Allocator, value: UIMessageChunk) !UIMessageChunk {
    const encoded = try provider.wire.stringifyAlloc(arena, value);
    return parseChunk(arena, encoded, null);
}

fn fromStatic(value: StaticChunk) UIMessageChunk {
    return switch (value) {
        inline else => |payload, tag| @unionInit(UIMessageChunk, @tagName(tag), payload),
    };
}

fn toStatic(comptime tag: std.meta.Tag(UIMessageChunk), payload: anytype) StaticChunk {
    return @unionInit(StaticChunk, @tagName(tag), payload);
}

fn checkStrictFields(type_name: []const u8, object: std.json.ObjectMap) provider.wire.ParseError!void {
    const fields = allowedFields(type_name) orelse return error.UnknownUnionTag;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UIMessageStreamError;
    }
}

fn allowedFields(type_name: []const u8) ?[]const []const u8 {
    if (std.mem.startsWith(u8, type_name, "data-") and type_name.len > "data-".len)
        return &.{ "type", "id", "data", "transient" };
    const type_only = &.{"type"};
    if (eqlAny(type_name, &.{ "start-step", "finish-step" })) return type_only;
    if (eqlAny(type_name, &.{ "text-start", "text-end", "reasoning-start", "reasoning-end" }))
        return &.{ "type", "id", "providerMetadata" };
    if (eqlAny(type_name, &.{ "text-delta", "reasoning-delta" }))
        return &.{ "type", "id", "delta", "providerMetadata" };
    if (std.mem.eql(u8, type_name, "error")) return &.{ "type", "errorText" };
    if (std.mem.eql(u8, type_name, "tool-input-start"))
        return &.{ "type", "toolCallId", "toolName", "providerExecuted", "providerMetadata", "toolMetadata", "dynamic", "title" };
    if (std.mem.eql(u8, type_name, "tool-input-delta"))
        return &.{ "type", "toolCallId", "inputTextDelta" };
    if (std.mem.eql(u8, type_name, "tool-input-available"))
        return &.{ "type", "toolCallId", "toolName", "input", "providerExecuted", "providerMetadata", "toolMetadata", "dynamic", "title" };
    if (std.mem.eql(u8, type_name, "tool-input-error"))
        return &.{ "type", "toolCallId", "toolName", "input", "providerExecuted", "providerMetadata", "toolMetadata", "dynamic", "errorText", "title" };
    if (std.mem.eql(u8, type_name, "tool-approval-request"))
        return &.{ "type", "approvalId", "toolCallId", "isAutomatic", "signature" };
    if (std.mem.eql(u8, type_name, "tool-approval-response"))
        return &.{ "type", "approvalId", "approved", "reason", "providerExecuted", "providerMetadata" };
    if (std.mem.eql(u8, type_name, "tool-output-available"))
        return &.{ "type", "toolCallId", "output", "providerExecuted", "providerMetadata", "toolMetadata", "dynamic", "preliminary" };
    if (std.mem.eql(u8, type_name, "tool-output-error"))
        return &.{ "type", "toolCallId", "errorText", "providerExecuted", "providerMetadata", "toolMetadata", "dynamic" };
    if (std.mem.eql(u8, type_name, "tool-output-denied")) return &.{ "type", "toolCallId" };
    if (std.mem.eql(u8, type_name, "custom")) return &.{ "type", "kind", "providerMetadata" };
    if (std.mem.eql(u8, type_name, "source-url"))
        return &.{ "type", "sourceId", "url", "title", "providerMetadata" };
    if (std.mem.eql(u8, type_name, "source-document"))
        return &.{ "type", "sourceId", "mediaType", "title", "filename", "providerMetadata" };
    if (eqlAny(type_name, &.{ "file", "reasoning-file" }))
        return &.{ "type", "url", "mediaType", "providerMetadata" };
    if (std.mem.eql(u8, type_name, "start")) return &.{ "type", "messageId", "messageMetadata" };
    if (std.mem.eql(u8, type_name, "finish")) return &.{ "type", "finishReason", "messageMetadata" };
    if (std.mem.eql(u8, type_name, "abort")) return &.{ "type", "reason" };
    if (std.mem.eql(u8, type_name, "message-metadata")) return &.{ "type", "messageMetadata" };
    return null;
}

fn eqlAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn optionalString(arena: Allocator, object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError!?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try arena.dupe(u8, text),
        else => error.TypeValidationError,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError!?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .bool => |item| item,
        else => error.TypeValidationError,
    };
}

const ChunkIdentity = struct { type_name: []const u8, id: []const u8 };

fn chunkIdentity(value: JsonValue) ChunkIdentity {
    if (value != .object) return .{ .type_name = "unknown", .id = "" };
    const object = value.object;
    const type_name = if (object.get("type")) |field_value|
        if (field_value == .string) field_value.string else "unknown"
    else
        "unknown";
    inline for (.{ "id", "toolCallId", "approvalId", "sourceId" }) |name| {
        if (object.get(name)) |field_value| if (field_value == .string) {
            return .{ .type_name = type_name, .id = field_value.string };
        };
    }
    return .{ .type_name = type_name, .id = "" };
}

fn setDiagnostic(
    diag: ?*provider.Diagnostics,
    message: []const u8,
    chunk_type: []const u8,
    chunk_id: []const u8,
) void {
    const diagnostics = diag orelse return;
    provider.Diagnostics.set(diag, diagnostics.allocator, .{ .ui_message_stream = .{
        .message = message,
        .chunk_type = chunk_type,
        .chunk_id = chunk_id,
    } });
}

test "UIMessageChunk strict wire round trips every variant" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunks = [_]UIMessageChunk{
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "x" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .reasoning_start = .{ .id = "r" } },
        .{ .reasoning_delta = .{ .id = "r", .delta = "why" } },
        .{ .reasoning_end = .{ .id = "r" } },
        .{ .err = .{ .error_text = "masked" } },
        .{ .tool_input_start = .{ .tool_call_id = "c", .tool_name = "weather", .dynamic = true } },
        .{ .tool_input_delta = .{ .tool_call_id = "c", .input_text_delta = "{" } },
        .{ .tool_input_available = .{ .tool_call_id = "c", .tool_name = "weather", .input = .{ .object = .empty } } },
        .{ .tool_input_error = .{ .tool_call_id = "c", .tool_name = "weather", .input = .null, .error_text = "bad" } },
        .{ .tool_approval_request = .{ .approval_id = "a", .tool_call_id = "c", .signature = "sig" } },
        .{ .tool_approval_response = .{ .approval_id = "a", .approved = true } },
        .{ .tool_output_available = .{ .tool_call_id = "c", .output = .null, .preliminary = false } },
        .{ .tool_output_error = .{ .tool_call_id = "c", .error_text = "failed" } },
        .{ .tool_output_denied = .{ .tool_call_id = "c" } },
        .{ .custom = .{ .kind = "provider.kind" } },
        .{ .source_url = .{ .source_id = "s", .url = "https://example.test" } },
        .{ .source_document = .{ .source_id = "s", .media_type = "text/plain", .title = "doc" } },
        .{ .file = .{ .url = "data:text/plain;base64,eA==", .media_type = "text/plain" } },
        .{ .reasoning_file = .{ .url = "data:text/plain;base64,eA==", .media_type = "text/plain" } },
        .{ .data = .{ .name = "status", .id = "d", .data = .{ .string = "ok" }, .transient = true } },
        .{ .start_step = .{} },
        .{ .finish_step = .{} },
        .{ .start = .{ .message_id = "m", .message_metadata = .{ .bool = true } } },
        .{ .finish = .{ .finish_reason = .tool_calls, .message_metadata = .null } },
        .{ .abort = .{ .reason = "stop" } },
        .{ .message_metadata = .{ .message_metadata = .{ .integer = 1 } } },
    };

    for (chunks) |chunk| {
        const encoded = try provider.wire.stringifyAlloc(arena, chunk);
        const parsed = try parseChunk(arena, encoded, null);
        try std.testing.expectEqual(std.meta.activeTag(chunk), std.meta.activeTag(parsed));
    }
}

test "UIMessageChunk rejects unknown types and fields with diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.UIMessageStreamError,
        parseChunk(arena, "{\"type\":\"future-chunk\",\"id\":\"x\"}", &diagnostics),
    );
    try std.testing.expectEqualStrings("future-chunk", diagnostics.payload.ui_message_stream.chunk_type);
    try std.testing.expectEqualStrings("x", diagnostics.payload.ui_message_stream.chunk_id);

    try std.testing.expectError(
        error.UIMessageStreamError,
        parseChunk(arena, "{\"type\":\"text-start\",\"id\":\"x\",\"extra\":1}", &diagnostics),
    );
    try std.testing.expectEqualStrings("UI message chunk contains an unknown field", diagnostics.payload.ui_message_stream.message);
}
