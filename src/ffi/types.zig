const std = @import("std");

pub const Status = enum(c_int) {
    ok = 0,
    stream_done = 1,

    invalid_argument = 10,
    api_call = 20,
    no_such_model = 30,
    no_such_provider = 31,
    load_api_key = 40,
    load_setting = 41,
    retry = 50,
    canceled = 60,
    timeout = 61,
    out_of_memory = 70,
    invalid_json = 80,
    invalid_prompt = 81,
    invalid_response = 82,
    no_such_tool = 90,
    tool_error = 91,
    unsupported = 100,
    unknown = -1,
    _,
};

pub const PartType = enum(c_int) {
    text_start = 0,
    text_end = 1,
    text_delta = 2,
    reasoning_start = 3,
    reasoning_end = 4,
    reasoning_delta = 5,
    custom = 6,
    tool_input_start = 7,
    tool_input_end = 8,
    tool_input_delta = 9,
    source = 10,
    file = 11,
    reasoning_file = 12,
    tool_call = 13,
    tool_result = 14,
    tool_error = 15,
    tool_output_denied = 16,
    tool_approval_request = 17,
    tool_approval_response = 18,
    start_step = 19,
    finish_step = 20,
    start = 21,
    finish = 22,
    abort = 23,
    err = 24,
    raw = 25,
    unknown = -1,
    _,
};

pub const ai_runtime = opaque {};
pub const ai_provider = opaque {};
pub const ai_model = opaque {};
pub const ai_result = opaque {};
pub const ai_stream = opaque {};

pub const ai_string = extern struct {
    ptr: [*c]const u8,
    len: usize,
};

pub const ai_runtime_config = extern struct {
    async_limit: usize,
    concurrent_limit: usize,
};

pub const ai_anthropic_config = extern struct {
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
};

pub const ai_openrouter_config = extern struct {
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
    referer_ptr: [*c]const u8,
    referer_len: usize,
    title_ptr: [*c]const u8,
    title_len: usize,
};

pub const ai_openai_compatible_config = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
};

pub const ai_tool_result = extern struct {
    ptr: [*c]u8,
    len: usize,
};

pub const ToolExecuteFn = ?*const fn (
    user_data: ?*anyopaque,
    input_json: [*c]const u8,
    input_len: usize,
    out: [*c]ai_tool_result,
) callconv(.c) Status;

pub const ai_tool = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    description_ptr: [*c]const u8,
    description_len: usize,
    input_schema_json_ptr: [*c]const u8,
    input_schema_json_len: usize,
    execute: ToolExecuteFn,
    user_data: ?*anyopaque,
};

pub const ai_part = extern struct {
    type: PartType,
    json_ptr: [*c]const u8,
    json_len: usize,
    text_ptr: [*c]const u8,
    text_len: usize,
};

pub const empty_string: ai_string = .{ .ptr = null, .len = 0 };

pub fn string(value: []const u8) ai_string {
    return .{ .ptr = value.ptr, .len = value.len };
}

pub fn statusFromError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Canceled => .canceled,
        error.Timeout => .timeout,
        error.InvalidArgumentError,
        error.TooManyEmbeddingValuesForCallError,
        error.InvalidToolApprovalError,
        error.InvalidToolApprovalSignatureError,
        error.ToolCallNotFoundForApprovalError,
        => .invalid_argument,
        error.APICallError,
        error.EmptyResponseBodyError,
        error.DownloadError,
        => .api_call,
        error.NoSuchModelError,
        error.UnsupportedModelVersionError,
        => .no_such_model,
        error.NoSuchProviderError,
        error.NoSuchProviderReferenceError,
        => .no_such_provider,
        error.LoadAPIKeyError => .load_api_key,
        error.LoadSettingError => .load_setting,
        error.RetryError => .retry,
        error.JSONParseError => .invalid_json,
        error.InvalidPromptError,
        error.InvalidMessageRoleError,
        error.MessageConversionError,
        error.InvalidDataContentError,
        => .invalid_prompt,
        error.InvalidResponseDataError,
        error.InvalidStreamPartError,
        error.TypeValidationError,
        error.NoContentGeneratedError,
        error.NoImageGeneratedError,
        error.NoObjectGeneratedError,
        error.NoOutputGeneratedError,
        error.NoSpeechGeneratedError,
        error.NoTranscriptGeneratedError,
        error.NoVideoGeneratedError,
        error.UIMessageStreamError,
        => .invalid_response,
        error.NoSuchToolError => .no_such_tool,
        error.InvalidToolInputError,
        error.ToolCallRepairError,
        error.MissingToolResultsError,
        => .tool_error,
        error.UnsupportedFunctionalityError => .unsupported,
        else => .unknown,
    };
}

pub fn errorFromStatus(status: Status) anyerror {
    return switch (status) {
        .out_of_memory => error.OutOfMemory,
        .canceled => error.Canceled,
        .timeout => error.Timeout,
        .invalid_argument => error.InvalidArgumentError,
        .api_call => error.APICallError,
        .no_such_model => error.NoSuchModelError,
        .no_such_provider => error.NoSuchProviderError,
        .load_api_key => error.LoadAPIKeyError,
        .load_setting => error.LoadSettingError,
        .retry => error.RetryError,
        .invalid_json => error.JSONParseError,
        .invalid_prompt => error.InvalidPromptError,
        .invalid_response => error.InvalidResponseDataError,
        .no_such_tool => error.NoSuchToolError,
        .tool_error => error.FfiToolCallbackError,
        .unsupported => error.UnsupportedFunctionalityError,
        else => error.FfiToolCallbackError,
    };
}

test "stable status mapping groups provider errors" {
    try std.testing.expectEqual(Status.api_call, statusFromError(error.APICallError));
    try std.testing.expectEqual(Status.invalid_argument, statusFromError(error.InvalidArgumentError));
    try std.testing.expectEqual(Status.canceled, statusFromError(error.Canceled));
    try std.testing.expectEqual(Status.unknown, statusFromError(error.Unexpected));
}
