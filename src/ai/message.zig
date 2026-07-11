//! Application-facing model messages.
//!
//! These types mirror `@ai-sdk/provider-utils` rather than the lower-level
//! provider prompt. Prompt conversion in `prompt.zig` performs the lowering.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const ProviderOptions = provider.ProviderOptions;
pub const ProviderReference = provider.ProviderReference;
pub const JsonValue = std.json.Value;

/// Raw application data. Byte slices and base64 strings intentionally remain
/// distinct in memory even though both use the canonical base64 JSON wire.
pub const DataContent = union(enum) {
    bytes: []const u8,
    base64: []const u8,

    pub fn wireParse(arena: Allocator, value: JsonValue) provider.wire.ParseError!DataContent {
        const parsed = try provider.wire.parse(provider.BinaryData, arena, value);
        return switch (parsed) {
            .bytes => |bytes| .{ .bytes = bytes },
            .base64 => |base64| .{ .base64 = base64 },
        };
    }

    pub fn wireWrite(value: DataContent, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        return provider.wire.write(switch (value) {
            .bytes => |bytes| provider.BinaryData{ .bytes = bytes },
            .base64 => |base64| provider.BinaryData{ .base64 = base64 },
        }, writer);
    }
};

/// File data accepts the four tagged upstream shapes plus the legacy bare
/// string shorthand. Bare strings are URL-probed by the prompt converter and
/// otherwise interpreted as base64.
pub const FilePartData = union(enum) {
    data: DataContent,
    url: []const u8,
    reference: ProviderReference,
    text: []const u8,
    string: []const u8,

    pub fn wireParse(arena: Allocator, value: JsonValue) provider.wire.ParseError!FilePartData {
        if (value == .string) return .{ .string = try arena.dupe(u8, value.string) };
        const object = switch (value) {
            .object => |object| object,
            else => return error.TypeValidationError,
        };
        const tag_value = object.get("type") orelse return error.TypeValidationError;
        const tag = switch (tag_value) {
            .string => |text| text,
            else => return error.TypeValidationError,
        };
        if (std.mem.eql(u8, tag, "data")) {
            return .{ .data = try DataContent.wireParse(arena, object.get("data") orelse return error.TypeValidationError) };
        }
        if (std.mem.eql(u8, tag, "url")) {
            const url = object.get("url") orelse return error.TypeValidationError;
            if (url != .string) return error.TypeValidationError;
            return .{ .url = try arena.dupe(u8, url.string) };
        }
        if (std.mem.eql(u8, tag, "reference")) {
            return .{ .reference = try provider_utils.cloneJsonValue(
                arena,
                object.get("reference") orelse return error.TypeValidationError,
            ) };
        }
        if (std.mem.eql(u8, tag, "text")) {
            const text = object.get("text") orelse return error.TypeValidationError;
            if (text != .string) return error.TypeValidationError;
            return .{ .text = try arena.dupe(u8, text.string) };
        }
        return error.UnknownUnionTag;
    }

    pub fn wireWrite(value: FilePartData, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (value) {
            .string => |text| try writer.write(text),
            .data => |data| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("data");
                try writer.objectField("data");
                try DataContent.wireWrite(data, writer);
                try writer.endObject();
            },
            .url => |url| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("url");
                try writer.objectField("url");
                try writer.write(url);
                try writer.endObject();
            },
            .reference => |reference| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("reference");
                try writer.objectField("reference");
                try writer.write(reference);
                try writer.endObject();
            },
            .text => |text| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("text");
                try writer.objectField("text");
                try writer.write(text);
                try writer.endObject();
            },
        }
    }
};

pub const TextPart = struct {
    text: []const u8,
    provider_options: ?ProviderOptions = null,
};

/// Deprecated upstream image part retained because prompt conversion must
/// accept and warn on it. It lowers to a file part with media type `image`.
pub const ImagePart = struct {
    image: FilePartData,
    media_type: ?[]const u8 = null,
    provider_options: ?ProviderOptions = null,
};

pub const FilePart = struct {
    data: FilePartData,
    filename: ?[]const u8 = null,
    media_type: []const u8,
    provider_options: ?ProviderOptions = null,
};

pub const ReasoningPart = struct {
    text: []const u8,
    provider_options: ?ProviderOptions = null,
};

pub const ReasoningFilePart = struct {
    data: FilePartData,
    media_type: []const u8,
    provider_options: ?ProviderOptions = null,
};

pub const CustomPart = struct {
    kind: []const u8,
    provider_options: ?ProviderOptions = null,
};

pub const ToolCallPart = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: JsonValue,
    provider_executed: ?bool = null,
    provider_options: ?ProviderOptions = null,
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
};

pub const FileId = union(enum) {
    id: []const u8,
    references: ProviderReference,

    pub fn wireParse(arena: Allocator, value: JsonValue) provider.wire.ParseError!FileId {
        return switch (value) {
            .string => |id| .{ .id = try arena.dupe(u8, id) },
            .object => .{ .references = try provider_utils.cloneJsonValue(arena, value) },
            else => error.TypeValidationError,
        };
    }

    pub fn wireWrite(value: FileId, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        return switch (value) {
            .id => |id| writer.write(id),
            .references => |references| writer.write(references),
        };
    }
};

pub const ToolResultContentPart = union(enum) {
    text: Text,
    file: File,
    file_data: FileData,
    file_url: FileUrl,
    file_id: FileIdPart,
    file_reference: FileReference,
    image_data: ImageData,
    image_url: ImageUrl,
    image_file_id: ImageFileId,
    image_file_reference: ImageFileReference,
    custom: Custom,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .file, "file" },
        .{ .file_data, "file-data" },
        .{ .file_url, "file-url" },
        .{ .file_id, "file-id" },
        .{ .file_reference, "file-reference" },
        .{ .image_data, "image-data" },
        .{ .image_url, "image-url" },
        .{ .image_file_id, "image-file-id" },
        .{ .image_file_reference, "image-file-reference" },
        .{ .custom, "custom" },
    };

    pub const Text = struct {
        text: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    pub const File = struct {
        data: FilePartData,
        media_type: []const u8,
        filename: ?[]const u8 = null,
        provider_options: ?ProviderOptions = null,
    };
    pub const FileData = struct {
        data: []const u8,
        media_type: []const u8,
        filename: ?[]const u8 = null,
        provider_options: ?ProviderOptions = null,
    };
    pub const FileUrl = struct {
        url: []const u8,
        media_type: ?[]const u8 = null,
        provider_options: ?ProviderOptions = null,
    };
    pub const FileIdPart = struct {
        file_id: FileId,
        provider_options: ?ProviderOptions = null,
    };
    pub const FileReference = struct {
        provider_reference: ProviderReference,
        provider_options: ?ProviderOptions = null,
    };
    pub const ImageData = struct {
        data: []const u8,
        media_type: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    pub const ImageUrl = struct {
        url: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    pub const ImageFileId = struct {
        file_id: FileId,
        provider_options: ?ProviderOptions = null,
    };
    pub const ImageFileReference = struct {
        provider_reference: ProviderReference,
        provider_options: ?ProviderOptions = null,
    };
    pub const Custom = struct {
        provider_options: ?ProviderOptions = null,
    };
};

pub const ToolResultOutput = union(enum) {
    text: Text,
    json: Json,
    execution_denied: ExecutionDenied,
    error_text: ErrorText,
    error_json: ErrorJson,
    content: ContentOutput,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .json, "json" },
        .{ .execution_denied, "execution-denied" },
        .{ .error_text, "error-text" },
        .{ .error_json, "error-json" },
        .{ .content, "content" },
    };

    pub const Text = struct {
        value: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    pub const Json = struct {
        value: JsonValue,
        provider_options: ?ProviderOptions = null,
    };
    pub const ExecutionDenied = struct {
        reason: ?[]const u8 = null,
        provider_options: ?ProviderOptions = null,
    };
    pub const ErrorText = struct {
        value: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    pub const ErrorJson = struct {
        value: JsonValue,
        provider_options: ?ProviderOptions = null,
    };
    pub const ContentOutput = struct { value: []const ToolResultContentPart };
};

pub const ToolResultPart = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    output: ToolResultOutput,
    provider_options: ?ProviderOptions = null,
};

pub const UserContentPart = union(enum) {
    text: TextPart,
    image: ImagePart,
    file: FilePart,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .image, "image" },
        .{ .file, "file" },
    };
};

pub const AssistantContentPart = union(enum) {
    text: TextPart,
    custom: CustomPart,
    file: FilePart,
    reasoning: ReasoningPart,
    reasoning_file: ReasoningFilePart,
    tool_call: ToolCallPart,
    tool_result: ToolResultPart,
    tool_approval_request: ToolApprovalRequest,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .custom, "custom" },
        .{ .file, "file" },
        .{ .reasoning, "reasoning" },
        .{ .reasoning_file, "reasoning-file" },
        .{ .tool_call, "tool-call" },
        .{ .tool_result, "tool-result" },
        .{ .tool_approval_request, "tool-approval-request" },
    };
};

pub const ToolContentPart = union(enum) {
    tool_result: ToolResultPart,
    tool_approval_response: ToolApprovalResponse,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .tool_result, "tool-result" },
        .{ .tool_approval_response, "tool-approval-response" },
    };
};

pub fn Content(comptime Part: type) type {
    return union(enum) {
        text: []const u8,
        parts: []const Part,

        const Self = @This();

        pub fn wireParse(arena: Allocator, value: JsonValue) provider.wire.ParseError!Self {
            return switch (value) {
                .string => |text| .{ .text = try arena.dupe(u8, text) },
                .array => .{ .parts = try provider.wire.parse([]const Part, arena, value) },
                else => error.TypeValidationError,
            };
        }

        pub fn wireWrite(value: Self, writer: *std.json.Stringify) std.Io.Writer.Error!void {
            return switch (value) {
                .text => |text| writer.write(text),
                .parts => |parts| provider.wire.write(parts, writer),
            };
        }
    };
}

pub const SystemModelMessage = struct {
    content: []const u8,
    provider_options: ?ProviderOptions = null,
};

pub const UserModelMessage = struct {
    content: Content(UserContentPart),
    provider_options: ?ProviderOptions = null,
};

pub const AssistantModelMessage = struct {
    content: Content(AssistantContentPart),
    provider_options: ?ProviderOptions = null,
};

pub const ToolModelMessage = struct {
    content: []const ToolContentPart,
    provider_options: ?ProviderOptions = null,
};

pub const ModelMessage = union(enum) {
    system: SystemModelMessage,
    user: UserModelMessage,
    assistant: AssistantModelMessage,
    tool: ToolModelMessage,

    pub const wire_tag_field = "role";
    pub const wire_tags = .{
        .{ .system, "system" },
        .{ .user, "user" },
        .{ .assistant, "assistant" },
        .{ .tool, "tool" },
    };
};

/// Deep-copies messages into the destination arena through the canonical wire
/// codec. This also locks the FFI/UI JSON representation to the declared wire
/// tags instead of maintaining a second handwritten clone tree.
pub fn cloneModelMessages(arena: Allocator, messages: []const ModelMessage) ![]const ModelMessage {
    const json_text = try provider.wire.stringifyAlloc(arena, messages);
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, json_text, .{});
    return provider.wire.parse([]const ModelMessage, arena, value);
}

test "ModelMessage canonical wire round-trip and deep clone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const parts = [_]UserContentPart{
        .{ .text = .{ .text = &text } },
        .{ .file = .{
            .data = .{ .url = "https://example.test/a.png" },
            .media_type = "image/png",
        } },
    };
    const input = [_]ModelMessage{.{ .user = .{ .content = .{ .parts = &parts } } }};
    const cloned = try cloneModelMessages(arena, &input);
    text[0] = 'X';

    try std.testing.expectEqualStrings("hello", cloned[0].user.content.parts[0].text.text);
    const encoded = try provider.wire.stringifyAlloc(arena, cloned);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"file\"") != null);
}
