//! Framework-neutral UI message model.
//!
//! `data-{name}` and `tool-{name}` are dynamic JSON discriminator values.
//! Zig keeps the dynamic suffix as a normal slice and reconstructs the wire
//! discriminator in `wireWrite`.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const Role = enum {
    system,
    user,
    assistant,
};

pub const PartState = enum {
    streaming,
    done,
};

pub const TextUIPart = struct {
    text: []const u8,
    state: ?PartState = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ReasoningUIPart = TextUIPart;

pub const CustomContentUIPart = struct {
    kind: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const SourceUrlUIPart = struct {
    source_id: []const u8,
    url: []const u8,
    title: ?[]const u8 = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const SourceDocumentUIPart = struct {
    source_id: []const u8,
    media_type: []const u8,
    title: []const u8,
    filename: ?[]const u8 = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const FileUIPart = struct {
    media_type: []const u8,
    filename: ?[]const u8 = null,
    url: []const u8,
    provider_reference: ?provider.ProviderReference = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ReasoningFileUIPart = struct {
    media_type: []const u8,
    url: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const DataUIPart = struct {
    name: []const u8,
    id: ?[]const u8 = null,
    data: JsonValue,
};

pub const ApprovalRequest = struct {
    id: []const u8,
    is_automatic: ?bool = null,
    signature: ?[]const u8 = null,
};

pub const ApprovalResponse = struct {
    id: []const u8,
    approved: bool,
    reason: ?[]const u8 = null,
    is_automatic: ?bool = null,
    signature: ?[]const u8 = null,
};

pub const ToolState = union(enum) {
    input_streaming: InputStreaming,
    input_available: InputAvailable,
    approval_requested: ApprovalRequested,
    approval_responded: ApprovalResponded,
    output_available: OutputAvailable,
    output_error: OutputError,
    output_denied: OutputDenied,

    pub const InputStreaming = struct {
        input: ?JsonValue = null,
        call_provider_metadata: ?provider.ProviderMetadata = null,
    };

    pub const InputAvailable = struct {
        input: JsonValue,
        call_provider_metadata: ?provider.ProviderMetadata = null,
    };

    pub const ApprovalRequested = struct {
        input: JsonValue,
        approval: ApprovalRequest,
        call_provider_metadata: ?provider.ProviderMetadata = null,
    };

    pub const ApprovalResponded = struct {
        input: JsonValue,
        approval: ApprovalResponse,
        call_provider_metadata: ?provider.ProviderMetadata = null,
    };

    pub const OutputAvailable = struct {
        input: JsonValue,
        output: JsonValue,
        call_provider_metadata: ?provider.ProviderMetadata = null,
        result_provider_metadata: ?provider.ProviderMetadata = null,
        preliminary: ?bool = null,
        approval: ?ApprovalResponse = null,
    };

    pub const OutputError = struct {
        input: ?JsonValue = null,
        raw_input: ?JsonValue = null,
        error_text: []const u8,
        call_provider_metadata: ?provider.ProviderMetadata = null,
        result_provider_metadata: ?provider.ProviderMetadata = null,
        approval: ?ApprovalResponse = null,
    };

    pub const OutputDenied = struct {
        input: JsonValue,
        approval: ApprovalResponse,
        call_provider_metadata: ?provider.ProviderMetadata = null,
    };
};

pub const ToolUIPart = struct {
    name: []const u8,
    tool_call_id: []const u8,
    title: ?[]const u8 = null,
    tool_metadata: ?JsonValue = null,
    provider_executed: ?bool = null,
    state: ToolState,

    pub fn isComplete(self: ToolUIPart) bool {
        return switch (self.state) {
            .output_available, .output_error, .output_denied => true,
            else => false,
        };
    }
};

pub const UIMessagePart = union(enum) {
    text: TextUIPart,
    reasoning: ReasoningUIPart,
    custom: CustomContentUIPart,
    tool: ToolUIPart,
    dynamic_tool: ToolUIPart,
    source_url: SourceUrlUIPart,
    source_document: SourceDocumentUIPart,
    file: FileUIPart,
    reasoning_file: ReasoningFileUIPart,
    data: DataUIPart,
    step_start: void,

    pub fn toolPart(self: *UIMessagePart) ?*ToolUIPart {
        return switch (self.*) {
            .tool => |*part| part,
            .dynamic_tool => |*part| part,
            else => null,
        };
    }

    pub fn toolPartConst(self: *const UIMessagePart) ?*const ToolUIPart {
        return switch (self.*) {
            .tool => |*part| part,
            .dynamic_tool => |*part| part,
            else => null,
        };
    }

    pub fn wireParse(arena: Allocator, value: JsonValue) provider.wire.ParseError!UIMessagePart {
        const object = try objectValue(value);
        const type_name = try requiredString(arena, object, "type");

        if (std.mem.eql(u8, type_name, "text")) {
            return .{ .text = try parseTextPart(arena, object) };
        }
        if (std.mem.eql(u8, type_name, "reasoning")) {
            return .{ .reasoning = try parseTextPart(arena, object) };
        }
        if (std.mem.eql(u8, type_name, "custom")) {
            return .{ .custom = .{
                .kind = try requiredString(arena, object, "kind"),
                .provider_metadata = try optionalValue(arena, object, "providerMetadata"),
            } };
        }
        if (std.mem.eql(u8, type_name, "source-url")) {
            return .{ .source_url = .{
                .source_id = try requiredString(arena, object, "sourceId"),
                .url = try requiredString(arena, object, "url"),
                .title = try optionalString(arena, object, "title"),
                .provider_metadata = try optionalValue(arena, object, "providerMetadata"),
            } };
        }
        if (std.mem.eql(u8, type_name, "source-document")) {
            return .{ .source_document = .{
                .source_id = try requiredString(arena, object, "sourceId"),
                .media_type = try requiredString(arena, object, "mediaType"),
                .title = try requiredString(arena, object, "title"),
                .filename = try optionalString(arena, object, "filename"),
                .provider_metadata = try optionalValue(arena, object, "providerMetadata"),
            } };
        }
        if (std.mem.eql(u8, type_name, "file")) {
            return .{ .file = .{
                .media_type = try requiredString(arena, object, "mediaType"),
                .filename = try optionalString(arena, object, "filename"),
                .url = try requiredString(arena, object, "url"),
                .provider_reference = try optionalValue(arena, object, "providerReference"),
                .provider_metadata = try optionalValue(arena, object, "providerMetadata"),
            } };
        }
        if (std.mem.eql(u8, type_name, "reasoning-file")) {
            return .{ .reasoning_file = .{
                .media_type = try requiredString(arena, object, "mediaType"),
                .url = try requiredString(arena, object, "url"),
                .provider_metadata = try optionalValue(arena, object, "providerMetadata"),
            } };
        }
        if (std.mem.eql(u8, type_name, "step-start")) return .{ .step_start = {} };
        if (std.mem.eql(u8, type_name, "dynamic-tool")) {
            const name = try requiredString(arena, object, "toolName");
            return .{ .dynamic_tool = try parseToolPart(arena, object, name) };
        }
        if (std.mem.startsWith(u8, type_name, "tool-") and type_name.len > "tool-".len) {
            return .{ .tool = try parseToolPart(arena, object, type_name["tool-".len..]) };
        }
        if (std.mem.startsWith(u8, type_name, "data-") and type_name.len > "data-".len) {
            return .{ .data = .{
                .name = try arena.dupe(u8, type_name["data-".len..]),
                .id = try optionalString(arena, object, "id"),
                .data = try requiredValue(arena, object, "data"),
            } };
        }
        return error.UnknownUnionTag;
    }

    pub fn wireWrite(value: UIMessagePart, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        try writer.beginObject();
        switch (value) {
            .text => |part| try writeTextPart("text", part, writer),
            .reasoning => |part| try writeTextPart("reasoning", part, writer),
            .custom => |part| {
                try typeField(writer, "custom");
                try field(writer, "kind", part.kind);
                try optionalField(writer, "providerMetadata", part.provider_metadata);
            },
            .tool => |part| try writeToolPart(part, false, writer),
            .dynamic_tool => |part| try writeToolPart(part, true, writer),
            .source_url => |part| {
                try typeField(writer, "source-url");
                try field(writer, "sourceId", part.source_id);
                try field(writer, "url", part.url);
                try optionalField(writer, "title", part.title);
                try optionalField(writer, "providerMetadata", part.provider_metadata);
            },
            .source_document => |part| {
                try typeField(writer, "source-document");
                try field(writer, "sourceId", part.source_id);
                try field(writer, "mediaType", part.media_type);
                try field(writer, "title", part.title);
                try optionalField(writer, "filename", part.filename);
                try optionalField(writer, "providerMetadata", part.provider_metadata);
            },
            .file => |part| {
                try typeField(writer, "file");
                try field(writer, "mediaType", part.media_type);
                try optionalField(writer, "filename", part.filename);
                try field(writer, "url", part.url);
                try optionalField(writer, "providerReference", part.provider_reference);
                try optionalField(writer, "providerMetadata", part.provider_metadata);
            },
            .reasoning_file => |part| {
                try typeField(writer, "reasoning-file");
                try field(writer, "mediaType", part.media_type);
                try field(writer, "url", part.url);
                try optionalField(writer, "providerMetadata", part.provider_metadata);
            },
            .data => |part| {
                try writer.objectField("type");
                try writer.beginWriteRaw();
                try writer.writer.writeAll("\"data-");
                try writeEscapedStringContents(writer.writer, part.name);
                try writer.writer.writeByte('"');
                writer.endWriteRaw();
                try optionalField(writer, "id", part.id);
                try field(writer, "data", part.data);
            },
            .step_start => try typeField(writer, "step-start"),
        }
        try writer.endObject();
    }
};

pub const UIMessage = struct {
    id: []const u8,
    role: Role,
    metadata: ?JsonValue = null,
    parts: []const UIMessagePart,
};

pub fn cloneMessage(arena: Allocator, source: UIMessage) !UIMessage {
    const text = try provider.wire.stringifyAlloc(arena, source);
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, text, .{ .allocate = .alloc_always });
    return provider.wire.parse(UIMessage, arena, value);
}

pub fn cloneMessages(arena: Allocator, source: []const UIMessage) ![]const UIMessage {
    const text = try provider.wire.stringifyAlloc(arena, source);
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, text, .{ .allocate = .alloc_always });
    return provider.wire.parse([]const UIMessage, arena, value);
}

fn parseTextPart(arena: Allocator, object: std.json.ObjectMap) provider.wire.ParseError!TextUIPart {
    const state = if (try optionalString(arena, object, "state")) |name|
        if (std.mem.eql(u8, name, "streaming")) PartState.streaming else if (std.mem.eql(u8, name, "done")) PartState.done else return error.TypeValidationError
    else
        null;
    return .{
        .text = try requiredString(arena, object, "text"),
        .state = state,
        .provider_metadata = try optionalValue(arena, object, "providerMetadata"),
    };
}

fn parseToolPart(
    arena: Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) provider.wire.ParseError!ToolUIPart {
    const state_name = try requiredString(arena, object, "state");
    const call_metadata = try optionalValue(arena, object, "callProviderMetadata");
    const state: ToolState = if (std.mem.eql(u8, state_name, "input-streaming"))
        .{ .input_streaming = .{
            .input = try optionalValue(arena, object, "input"),
            .call_provider_metadata = call_metadata,
        } }
    else if (std.mem.eql(u8, state_name, "input-available"))
        .{ .input_available = .{
            .input = try requiredValue(arena, object, "input"),
            .call_provider_metadata = call_metadata,
        } }
    else if (std.mem.eql(u8, state_name, "approval-requested"))
        .{ .approval_requested = .{
            .input = try requiredValue(arena, object, "input"),
            .approval = try parseApprovalRequest(arena, object.get("approval") orelse return error.TypeValidationError),
            .call_provider_metadata = call_metadata,
        } }
    else if (std.mem.eql(u8, state_name, "approval-responded"))
        .{ .approval_responded = .{
            .input = try requiredValue(arena, object, "input"),
            .approval = try parseApprovalResponse(arena, object.get("approval") orelse return error.TypeValidationError),
            .call_provider_metadata = call_metadata,
        } }
    else if (std.mem.eql(u8, state_name, "output-available"))
        .{ .output_available = .{
            .input = try requiredValue(arena, object, "input"),
            .output = try requiredValue(arena, object, "output"),
            .call_provider_metadata = call_metadata,
            .result_provider_metadata = try optionalValue(arena, object, "resultProviderMetadata"),
            .preliminary = try optionalBool(object, "preliminary"),
            .approval = if (object.get("approval")) |approval| try parseApprovalResponse(arena, approval) else null,
        } }
    else if (std.mem.eql(u8, state_name, "output-error"))
        .{ .output_error = .{
            .input = try optionalValue(arena, object, "input"),
            .raw_input = try optionalValue(arena, object, "rawInput"),
            .error_text = try requiredString(arena, object, "errorText"),
            .call_provider_metadata = call_metadata,
            .result_provider_metadata = try optionalValue(arena, object, "resultProviderMetadata"),
            .approval = if (object.get("approval")) |approval| try parseApprovalResponse(arena, approval) else null,
        } }
    else if (std.mem.eql(u8, state_name, "output-denied"))
        .{ .output_denied = .{
            .input = try requiredValue(arena, object, "input"),
            .approval = try parseApprovalResponse(arena, object.get("approval") orelse return error.TypeValidationError),
            .call_provider_metadata = call_metadata,
        } }
    else
        return error.TypeValidationError;

    return .{
        .name = try arena.dupe(u8, name),
        .tool_call_id = try requiredString(arena, object, "toolCallId"),
        .title = try optionalString(arena, object, "title"),
        .tool_metadata = try optionalValue(arena, object, "toolMetadata"),
        .provider_executed = try optionalBool(object, "providerExecuted"),
        .state = state,
    };
}

fn parseApprovalRequest(arena: Allocator, value: JsonValue) provider.wire.ParseError!ApprovalRequest {
    const object = try objectValue(value);
    return .{
        .id = try requiredString(arena, object, "id"),
        .is_automatic = try optionalBool(object, "isAutomatic"),
        .signature = try optionalString(arena, object, "signature"),
    };
}

fn parseApprovalResponse(arena: Allocator, value: JsonValue) provider.wire.ParseError!ApprovalResponse {
    const object = try objectValue(value);
    return .{
        .id = try requiredString(arena, object, "id"),
        .approved = try requiredBool(object, "approved"),
        .reason = try optionalString(arena, object, "reason"),
        .is_automatic = try optionalBool(object, "isAutomatic"),
        .signature = try optionalString(arena, object, "signature"),
    };
}

fn writeTextPart(type_name: []const u8, part: TextUIPart, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    try typeField(writer, type_name);
    try field(writer, "text", part.text);
    if (part.state) |state| try field(writer, "state", switch (state) {
        .streaming => "streaming",
        .done => "done",
    });
    try optionalField(writer, "providerMetadata", part.provider_metadata);
}

fn writeToolPart(part: ToolUIPart, dynamic: bool, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    if (dynamic) {
        try typeField(writer, "dynamic-tool");
        try field(writer, "toolName", part.name);
    } else {
        try writer.objectField("type");
        try writer.beginWriteRaw();
        try writer.writer.writeAll("\"tool-");
        try writeEscapedStringContents(writer.writer, part.name);
        try writer.writer.writeByte('"');
        writer.endWriteRaw();
    }
    try field(writer, "toolCallId", part.tool_call_id);
    try optionalField(writer, "title", part.title);
    try optionalField(writer, "toolMetadata", part.tool_metadata);
    try optionalField(writer, "providerExecuted", part.provider_executed);

    switch (part.state) {
        .input_streaming => |state| {
            try field(writer, "state", "input-streaming");
            try optionalField(writer, "input", state.input);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
        },
        .input_available => |state| {
            try field(writer, "state", "input-available");
            try field(writer, "input", state.input);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
        },
        .approval_requested => |state| {
            try field(writer, "state", "approval-requested");
            try field(writer, "input", state.input);
            try writer.objectField("approval");
            try writeApprovalRequest(state.approval, writer);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
        },
        .approval_responded => |state| {
            try field(writer, "state", "approval-responded");
            try field(writer, "input", state.input);
            try writer.objectField("approval");
            try writeApprovalResponse(state.approval, writer);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
        },
        .output_available => |state| {
            try field(writer, "state", "output-available");
            try field(writer, "input", state.input);
            try field(writer, "output", state.output);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
            try optionalField(writer, "resultProviderMetadata", state.result_provider_metadata);
            try optionalField(writer, "preliminary", state.preliminary);
            if (state.approval) |approval| {
                try writer.objectField("approval");
                try writeApprovalResponse(approval, writer);
            }
        },
        .output_error => |state| {
            try field(writer, "state", "output-error");
            try optionalField(writer, "input", state.input);
            try optionalField(writer, "rawInput", state.raw_input);
            try field(writer, "errorText", state.error_text);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
            try optionalField(writer, "resultProviderMetadata", state.result_provider_metadata);
            if (state.approval) |approval| {
                try writer.objectField("approval");
                try writeApprovalResponse(approval, writer);
            }
        },
        .output_denied => |state| {
            try field(writer, "state", "output-denied");
            try field(writer, "input", state.input);
            try writer.objectField("approval");
            try writeApprovalResponse(state.approval, writer);
            try optionalField(writer, "callProviderMetadata", state.call_provider_metadata);
        },
    }
}

fn writeApprovalRequest(value: ApprovalRequest, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    try writer.beginObject();
    try field(writer, "id", value.id);
    try optionalField(writer, "isAutomatic", value.is_automatic);
    try optionalField(writer, "signature", value.signature);
    try writer.endObject();
}

fn writeApprovalResponse(value: ApprovalResponse, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    try writer.beginObject();
    try field(writer, "id", value.id);
    try field(writer, "approved", value.approved);
    try optionalField(writer, "reason", value.reason);
    try optionalField(writer, "isAutomatic", value.is_automatic);
    try optionalField(writer, "signature", value.signature);
    try writer.endObject();
}

fn objectValue(value: JsonValue) provider.wire.ParseError!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.TypeValidationError,
    };
}

fn requiredValue(arena: Allocator, object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError!JsonValue {
    return provider_utils.cloneJsonValue(arena, object.get(name) orelse return error.TypeValidationError);
}

fn optionalValue(arena: Allocator, object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError!?JsonValue {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    return try provider_utils.cloneJsonValue(arena, value);
}

fn requiredString(arena: Allocator, object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError![]const u8 {
    const value = object.get(name) orelse return error.TypeValidationError;
    return switch (value) {
        .string => |text| try arena.dupe(u8, text),
        else => error.TypeValidationError,
    };
}

fn optionalString(arena: Allocator, object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError!?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try arena.dupe(u8, text),
        else => error.TypeValidationError,
    };
}

fn requiredBool(object: std.json.ObjectMap, name: []const u8) provider.wire.ParseError!bool {
    const value = object.get(name) orelse return error.TypeValidationError;
    return switch (value) {
        .bool => |item| item,
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

fn typeField(writer: *std.json.Stringify, type_name: []const u8) std.Io.Writer.Error!void {
    try field(writer, "type", type_name);
}

fn field(writer: *std.json.Stringify, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    try writer.objectField(name);
    try writer.write(value);
}

fn optionalField(writer: *std.json.Stringify, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    if (value) |item| try field(writer, name, item);
}

fn writeEscapedStringContents(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonStringChars(text, .{}, writer);
}

test "UIMessage dynamic data and tool wire round trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]UIMessagePart{
        .{ .data = .{ .name = "weather", .id = "d1", .data = .{ .integer = 72 } } },
        .{ .tool = .{
            .name = "weather-now",
            .tool_call_id = "call-1",
            .state = .{ .output_available = .{
                .input = .{ .string = "NYC" },
                .output = .{ .string = "sunny" },
            } },
        } },
        .{ .dynamic_tool = .{
            .name = "runtime-tool",
            .tool_call_id = "call-2",
            .state = .{ .input_available = .{ .input = .{ .bool = true } } },
        } },
    };
    const message: UIMessage = .{ .id = "m1", .role = .assistant, .parts = &parts };
    const encoded = try provider.wire.stringifyAlloc(arena, message);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"data-weather\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"tool-weather-now\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"dynamic-tool\"") != null);

    const parsed_value = try std.json.parseFromSliceLeaky(JsonValue, arena, encoded, .{});
    const parsed = try provider.wire.parse(UIMessage, arena, parsed_value);
    try std.testing.expectEqualStrings("weather", parsed.parts[0].data.name);
    try std.testing.expectEqualStrings("weather-now", parsed.parts[1].tool.name);
    try std.testing.expectEqualStrings("runtime-tool", parsed.parts[2].dynamic_tool.name);
}
