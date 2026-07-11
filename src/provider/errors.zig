const std = @import("std");

const Allocator = std.mem.Allocator;

// Zig error names are structural and global, so the complete SDK error set lives
// at the dependency floor even though upstream declares it across packages.
pub const Error = error{
    APICallError,
    EmptyResponseBodyError,
    InvalidArgumentError,
    InvalidPromptError,
    InvalidResponseDataError,
    JSONParseError,
    LoadAPIKeyError,
    LoadSettingError,
    NoContentGeneratedError,
    NoSuchModelError,
    NoSuchProviderReferenceError,
    TooManyEmbeddingValuesForCallError,
    TypeValidationError,
    UnsupportedFunctionalityError,
    DownloadError,
    InvalidStreamPartError,
    InvalidToolApprovalError,
    InvalidToolApprovalSignatureError,
    InvalidToolInputError,
    MissingToolResultsError,
    NoImageGeneratedError,
    NoObjectGeneratedError,
    NoOutputGeneratedError,
    NoSpeechGeneratedError,
    NoSuchToolError,
    NoTranscriptGeneratedError,
    NoVideoGeneratedError,
    ToolCallNotFoundForApprovalError,
    ToolCallRepairError,
    UIMessageStreamError,
    UnsupportedModelVersionError,
    InvalidDataContentError,
    InvalidMessageRoleError,
    MessageConversionError,
    NoSuchProviderError,
    RetryError,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ModelType = enum {
    language_model,
    embedding_model,
    image_model,
    transcription_model,
    speech_model,
    reranking_model,
    video_model,
};

pub const RetryReason = enum {
    max_retries_exceeded,
    error_not_retryable,
    abort,
};

pub const FinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    @"error",
    other,
};

pub const TypeValidationContext = struct {
    field: ?[]const u8 = null,
    entity_name: ?[]const u8 = null,
    entity_id: ?[]const u8 = null,
};

pub const Simple = struct {
    message: []const u8,
};

pub const ApiCall = struct {
    message: []const u8,
    url: []const u8,
    status_code: ?u16 = null,
    response_headers: []const Header = &.{},
    response_body: ?[]const u8 = null,
    is_retryable: bool,
    request_body_json: ?[]const u8 = null,
    data_json: ?[]const u8 = null,
    cause_message: ?[]const u8 = null,
};

pub const InvalidArgument = struct {
    message: []const u8,
    parameter: []const u8,
    value_json: ?[]const u8 = null,
};

pub const InvalidPrompt = struct {
    message: []const u8,
    prompt_json: ?[]const u8 = null,
    cause_message: ?[]const u8 = null,
};

pub const InvalidResponseData = struct {
    message: []const u8,
    data_json: ?[]const u8 = null,
};

pub const JsonParse = struct {
    message: []const u8,
    text: []const u8,
    cause_message: ?[]const u8 = null,
};

pub const NoSuchModel = struct {
    message: []const u8,
    model_id: []const u8,
    model_type: ModelType,
};

pub const NoSuchProviderReference = struct {
    message: []const u8,
    provider: []const u8,
    reference_json: []const u8,
};

pub const TooManyEmbeddingValuesForCall = struct {
    message: []const u8,
    provider: []const u8,
    model_id: []const u8,
    max_embeddings_per_call: usize,
    values_json: []const u8,
};

pub const TypeValidation = struct {
    message: []const u8,
    value_json: ?[]const u8 = null,
    context: ?TypeValidationContext = null,
    cause_message: ?[]const u8 = null,
};

pub const UnsupportedFunctionality = struct {
    message: []const u8,
    functionality: []const u8,
};

pub const Download = struct {
    message: []const u8,
    url: []const u8,
    status_code: ?u16 = null,
    status_text: ?[]const u8 = null,
    cause_message: ?[]const u8 = null,
};

pub const InvalidStreamPart = struct {
    message: []const u8,
    chunk_json: []const u8,
};

pub const InvalidToolApproval = struct {
    message: []const u8,
    approval_id: []const u8,
};

pub const InvalidToolApprovalSignature = struct {
    message: []const u8,
    approval_id: []const u8,
    tool_call_id: []const u8,
    reason: []const u8,
};

pub const InvalidToolInput = struct {
    message: []const u8,
    tool_name: []const u8,
    tool_input: []const u8,
    cause_message: ?[]const u8 = null,
};

pub const MissingToolResults = struct {
    message: []const u8,
    tool_call_ids: []const []const u8,
};

pub const NoImageGenerated = struct {
    message: []const u8,
    responses_json: ?[]const u8 = null,
    cause_message: ?[]const u8 = null,
};

pub const NoObjectGenerated = struct {
    message: []const u8,
    text: ?[]const u8 = null,
    response_json: ?[]const u8 = null,
    usage_json: ?[]const u8 = null,
    finish_reason: ?FinishReason = null,
    cause_message: ?[]const u8 = null,
};

pub const Responses = struct {
    message: []const u8,
    responses_json: []const u8,
};

pub const NoSuchTool = struct {
    message: []const u8,
    tool_name: []const u8,
    available_tools: ?[]const []const u8 = null,
};

pub const ToolCallNotFoundForApproval = struct {
    message: []const u8,
    tool_call_id: []const u8,
    approval_id: []const u8,
};

pub const ToolCallRepair = struct {
    message: []const u8,
    original_error_json: []const u8,
    cause_message: ?[]const u8 = null,
};

pub const UIMessageStream = struct {
    message: []const u8,
    chunk_type: []const u8,
    chunk_id: []const u8,
};

pub const UnsupportedModelVersion = struct {
    message: []const u8,
    version: []const u8,
    provider: []const u8,
    model_id: []const u8,
};

pub const InvalidDataContent = struct {
    message: []const u8,
    content_json: ?[]const u8 = null,
    cause_message: ?[]const u8 = null,
};

pub const InvalidMessageRole = struct {
    message: []const u8,
    role: []const u8,
};

pub const MessageConversion = struct {
    message: []const u8,
    original_message_json: []const u8,
};

pub const NoSuchProvider = struct {
    message: []const u8,
    model_id: []const u8,
    model_type: ModelType,
    provider_id: []const u8,
    available_providers: []const []const u8,
};

pub const Retry = struct {
    message: []const u8,
    reason: RetryReason,
    last_error_message: ?[]const u8 = null,
    errors: []const []const u8 = &.{},
};

pub const Payload = union(enum) {
    api_call: ApiCall,
    empty_response_body: Simple,
    invalid_argument: InvalidArgument,
    invalid_prompt: InvalidPrompt,
    invalid_response_data: InvalidResponseData,
    json_parse: JsonParse,
    load_api_key: Simple,
    load_setting: Simple,
    no_content_generated: Simple,
    no_such_model: NoSuchModel,
    no_such_provider_reference: NoSuchProviderReference,
    too_many_embedding_values_for_call: TooManyEmbeddingValuesForCall,
    type_validation: TypeValidation,
    unsupported_functionality: UnsupportedFunctionality,
    download: Download,
    invalid_stream_part: InvalidStreamPart,
    invalid_tool_approval: InvalidToolApproval,
    invalid_tool_approval_signature: InvalidToolApprovalSignature,
    invalid_tool_input: InvalidToolInput,
    missing_tool_results: MissingToolResults,
    no_image_generated: NoImageGenerated,
    no_object_generated: NoObjectGenerated,
    no_output_generated: Simple,
    no_speech_generated: Responses,
    no_such_tool: NoSuchTool,
    no_transcript_generated: Responses,
    no_video_generated: Responses,
    tool_call_not_found_for_approval: ToolCallNotFoundForApproval,
    tool_call_repair: ToolCallRepair,
    ui_message_stream: UIMessageStream,
    unsupported_model_version: UnsupportedModelVersion,
    invalid_data_content: InvalidDataContent,
    invalid_message_role: InvalidMessageRole,
    message_conversion: MessageConversion,
    no_such_provider: NoSuchProvider,
    retry: Retry,
};

pub const Diagnostics = struct {
    allocator: Allocator,
    payload: Payload,
    available: bool,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) Diagnostics {
        return .{
            .allocator = allocator,
            .payload = unavailablePayload(),
            .available = false,
            .arena = .init(allocator),
        };
    }

    pub fn fromPayload(allocator: Allocator, payload: Payload) Diagnostics {
        var diagnostics = init(allocator);
        set(&diagnostics, allocator, payload);
        return diagnostics;
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Replaces a diagnostic payload with an owned deep copy. Diagnostic
    /// collection must never hide the original failure, so allocation failure
    /// becomes a static unavailable state.
    pub fn set(diag: ?*Diagnostics, allocator: Allocator, payload: Payload) void {
        const self = diag orelse return;
        self.arena.deinit();
        self.allocator = allocator;
        self.arena = .init(allocator);
        self.payload = clonePayload(self.arena.allocator(), payload) catch {
            self.arena.deinit();
            self.arena = .init(allocator);
            self.payload = unavailablePayload();
            self.available = false;
            return;
        };
        self.available = true;
    }

    pub fn format(self: *const Diagnostics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!self.available) return writer.writeAll("diagnostics unavailable");

        switch (self.payload) {
            .invalid_prompt => |payload| try writer.print("Invalid prompt: {s}", .{payload.message}),
            inline else => |payload| try writer.writeAll(payload.message),
        }
    }

    pub fn message(self: *const Diagnostics, allocator: Allocator) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try self.format(&output.writer);
        return try output.toOwnedSlice();
    }
};

pub fn isRetryableStatus(status: ?u16) bool {
    const value = status orelse return false;
    return value == 408 or value == 409 or value == 429 or value >= 500;
}

fn unavailablePayload() Payload {
    return .{ .invalid_argument = .{
        .message = "diagnostics unavailable",
        .parameter = "",
    } };
}

fn clonePayload(allocator: Allocator, payload: Payload) Allocator.Error!Payload {
    return switch (payload) {
        .api_call => |value| .{ .api_call = try cloneValue(allocator, value) },
        .empty_response_body => |value| .{ .empty_response_body = try cloneValue(allocator, value) },
        .invalid_argument => |value| .{ .invalid_argument = try cloneValue(allocator, value) },
        .invalid_prompt => |value| .{ .invalid_prompt = try cloneValue(allocator, value) },
        .invalid_response_data => |value| .{ .invalid_response_data = try cloneValue(allocator, value) },
        .json_parse => |value| .{ .json_parse = try cloneValue(allocator, value) },
        .load_api_key => |value| .{ .load_api_key = try cloneValue(allocator, value) },
        .load_setting => |value| .{ .load_setting = try cloneValue(allocator, value) },
        .no_content_generated => |value| .{ .no_content_generated = try cloneValue(allocator, value) },
        .no_such_model => |value| .{ .no_such_model = try cloneValue(allocator, value) },
        .no_such_provider_reference => |value| .{ .no_such_provider_reference = try cloneValue(allocator, value) },
        .too_many_embedding_values_for_call => |value| .{ .too_many_embedding_values_for_call = try cloneValue(allocator, value) },
        .type_validation => |value| .{ .type_validation = try cloneValue(allocator, value) },
        .unsupported_functionality => |value| .{ .unsupported_functionality = try cloneValue(allocator, value) },
        .download => |value| .{ .download = try cloneValue(allocator, value) },
        .invalid_stream_part => |value| .{ .invalid_stream_part = try cloneValue(allocator, value) },
        .invalid_tool_approval => |value| .{ .invalid_tool_approval = try cloneValue(allocator, value) },
        .invalid_tool_approval_signature => |value| .{ .invalid_tool_approval_signature = try cloneValue(allocator, value) },
        .invalid_tool_input => |value| .{ .invalid_tool_input = try cloneValue(allocator, value) },
        .missing_tool_results => |value| .{ .missing_tool_results = try cloneValue(allocator, value) },
        .no_image_generated => |value| .{ .no_image_generated = try cloneValue(allocator, value) },
        .no_object_generated => |value| .{ .no_object_generated = try cloneValue(allocator, value) },
        .no_output_generated => |value| .{ .no_output_generated = try cloneValue(allocator, value) },
        .no_speech_generated => |value| .{ .no_speech_generated = try cloneValue(allocator, value) },
        .no_such_tool => |value| .{ .no_such_tool = try cloneValue(allocator, value) },
        .no_transcript_generated => |value| .{ .no_transcript_generated = try cloneValue(allocator, value) },
        .no_video_generated => |value| .{ .no_video_generated = try cloneValue(allocator, value) },
        .tool_call_not_found_for_approval => |value| .{ .tool_call_not_found_for_approval = try cloneValue(allocator, value) },
        .tool_call_repair => |value| .{ .tool_call_repair = try cloneValue(allocator, value) },
        .ui_message_stream => |value| .{ .ui_message_stream = try cloneValue(allocator, value) },
        .unsupported_model_version => |value| .{ .unsupported_model_version = try cloneValue(allocator, value) },
        .invalid_data_content => |value| .{ .invalid_data_content = try cloneValue(allocator, value) },
        .invalid_message_role => |value| .{ .invalid_message_role = try cloneValue(allocator, value) },
        .message_conversion => |value| .{ .message_conversion = try cloneValue(allocator, value) },
        .no_such_provider => |value| .{ .no_such_provider = try cloneValue(allocator, value) },
        .retry => |value| .{ .retry = try cloneValue(allocator, value) },
    };
}

fn cloneValue(allocator: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => blk: {
                const copy = try allocator.alloc(pointer.child, value.len);
                for (value, copy) |item, *destination| {
                    destination.* = try cloneValue(allocator, item);
                }
                break :blk copy;
            },
            else => value,
        },
        .optional => if (value) |item| try cloneValue(allocator, item) else null,
        .@"struct" => blk: {
            var copy: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                @field(copy, field.name) = try cloneValue(allocator, @field(value, field.name));
            }
            break :blk copy;
        },
        else => value,
    };
}

test "Diagnostics owns API call strings and headers" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();

    var message_source = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', ' ', 'f', 'a', 'i', 'l', 'e', 'd' };
    var url_source = [_]u8{ 'h', 't', 't', 'p', ':', '/', '/', 'a', 'p', 'i' };
    var header_name = [_]u8{ 'x', '-', 'i', 'd' };
    var header_value = [_]u8{ 'a', 'b', 'c' };
    const headers = [_]Header{.{ .name = &header_name, .value = &header_value }};

    Diagnostics.set(&diagnostics, allocator, .{ .api_call = .{
        .message = &message_source,
        .url = &url_source,
        .status_code = 429,
        .response_headers = &headers,
        .response_body = "limited",
        .is_retryable = true,
        .request_body_json = "{\"model\":\"test\"}",
    } });

    message_source[0] = 'X';
    url_source[0] = 'X';
    header_name[0] = 'X';
    header_value[0] = 'X';

    const api_call = diagnostics.payload.api_call;
    try std.testing.expectEqualStrings("request failed", api_call.message);
    try std.testing.expectEqualStrings("http://api", api_call.url);
    try std.testing.expectEqualStrings("x-id", api_call.response_headers[0].name);
    try std.testing.expectEqualStrings("abc", api_call.response_headers[0].value);

    const rendered = try diagnostics.message(allocator);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("request failed", rendered);
}

test "Diagnostics owns nested string lists" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();

    var first = [_]u8{ 'c', 'a', 'l', 'l', '-', '1' };
    const ids = [_][]const u8{ &first, "call-2" };
    Diagnostics.set(&diagnostics, allocator, .{ .missing_tool_results = .{
        .message = "missing results",
        .tool_call_ids = &ids,
    } });
    first[0] = 'X';

    try std.testing.expectEqualStrings("call-1", diagnostics.payload.missing_tool_results.tool_call_ids[0]);
}

test "Diagnostics degrades cleanly when payload copying runs out of memory" {
    var diagnostics = Diagnostics.init(std.testing.failing_allocator);
    defer diagnostics.deinit();

    Diagnostics.set(&diagnostics, std.testing.failing_allocator, .{ .load_api_key = .{
        .message = "missing API key",
    } });
    try std.testing.expect(!diagnostics.available);

    const rendered = try diagnostics.message(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("diagnostics unavailable", rendered);
}

test "Diagnostics formats no-such-model and invalid-prompt messages" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics.fromPayload(allocator, .{ .no_such_model = .{
        .message = "No such language model: missing-model",
        .model_id = "missing-model",
        .model_type = .language_model,
    } });
    defer diagnostics.deinit();

    var rendered = try diagnostics.message(allocator);
    try std.testing.expectEqualStrings("No such language model: missing-model", rendered);
    allocator.free(rendered);

    Diagnostics.set(&diagnostics, allocator, .{ .invalid_prompt = .{
        .message = "unsupported role",
        .prompt_json = "[]",
    } });
    rendered = try diagnostics.message(allocator);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("Invalid prompt: unsupported role", rendered);
}

test "isRetryableStatus matches APICallError defaults" {
    const cases = [_]struct { status: ?u16, expected: bool }{
        .{ .status = null, .expected = false },
        .{ .status = 200, .expected = false },
        .{ .status = 400, .expected = false },
        .{ .status = 408, .expected = true },
        .{ .status = 409, .expected = true },
        .{ .status = 429, .expected = true },
        .{ .status = 499, .expected = false },
        .{ .status = 500, .expected = true },
        .{ .status = 599, .expected = true },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, isRetryableStatus(case.status));
    }
}
