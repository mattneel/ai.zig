const std = @import("std");

pub const abi_version_major: u32 = 1;
pub const abi_version_minor: u32 = 0;
pub const abi_version_patch: u32 = 0;
pub const abi_version: u32 =
    (abi_version_major << 24) | (abi_version_minor << 16) | abi_version_patch;
pub const abi_version_string: [:0]const u8 = "1.0.0";

/// ABI-v1 numeric values are frozen. New values are append-only and old
/// values are never renumbered or reused.
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

/// ABI-v1 numeric values are frozen. New values are append-only and old
/// values are never renumbered or reused.
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
    object = 26,
    ui_message = 27,
    unknown = -1,
    _,
};

pub const OpenAiLanguageApi = enum(c_int) {
    responses = 0,
    chat = 1,
    unknown = -1,
    _,
};

pub const ai_runtime = opaque {};
pub const ai_provider = opaque {};
pub const ai_model = opaque {};
pub const ai_embedding_model = opaque {};
pub const ai_image_model = opaque {};
pub const ai_speech_model = opaque {};
pub const ai_transcription_model = opaque {};
pub const ai_result = opaque {};
pub const ai_stream = opaque {};
pub const ai_agent = opaque {};
pub const ai_telemetry_registration = opaque {};

/// Frozen two-word borrowed view. This value type is intentionally not
/// extensible; its return ABI is guarded by the ABI major/version query.
pub const ai_string = extern struct {
    ptr: [*c]const u8,
    len: usize,
};

pub const ai_runtime_config = extern struct {
    struct_size: usize,
    async_limit: usize,
    concurrent_limit: usize,
};

pub const ai_anthropic_config = extern struct {
    struct_size: usize,
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
};

pub const ai_openrouter_config = extern struct {
    struct_size: usize,
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
    struct_size: usize,
    name_ptr: [*c]const u8,
    name_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
};

pub const ai_openai_config = extern struct {
    struct_size: usize,
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
    organization_ptr: [*c]const u8,
    organization_len: usize,
    project_ptr: [*c]const u8,
    project_len: usize,
    language_api: OpenAiLanguageApi,
};

pub const ai_xai_config = extern struct {
    struct_size: usize,
    api_key_ptr: [*c]const u8,
    api_key_len: usize,
    base_url_ptr: [*c]const u8,
    base_url_len: usize,
};

/// Callback-owned output. The SDK initializes struct_size before invocation.
pub const ai_tool_result = extern struct {
    struct_size: usize,
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
    struct_size: usize,
    name_ptr: [*c]const u8,
    name_len: usize,
    description_ptr: [*c]const u8,
    description_len: usize,
    input_schema_json_ptr: [*c]const u8,
    input_schema_json_len: usize,
    execute: ToolExecuteFn,
    user_data: ?*anyopaque,
};

/// Caller-initialized output. ai_stream_next requires struct_size to be set.
pub const ai_part = extern struct {
    struct_size: usize,
    type: PartType,
    json_ptr: [*c]const u8,
    json_len: usize,
    text_ptr: [*c]const u8,
    text_len: usize,
};

/// Library-owned byte buffer. Free ptr/len with ai_buf_free.
pub const ai_buffer = extern struct {
    struct_size: usize,
    ptr: [*c]u8,
    len: usize,
};

pub const ai_agent_config = extern struct {
    struct_size: usize,
    tools: [*c]const ai_tool,
    tools_len: usize,
    system_ptr: [*c]const u8,
    system_len: usize,
    max_steps: u32,
};

pub const TelemetryEventFn = ?*const fn (
    user_data: ?*anyopaque,
    event_name: [*c]const u8,
    event_name_len: usize,
    event_json: [*c]const u8,
    event_json_len: usize,
) callconv(.c) void;

pub const TelemetryEnterFn = ?*const fn (
    user_data: ?*anyopaque,
    scope_name: [*c]const u8,
    scope_name_len: usize,
    call_id: [*c]const u8,
    call_id_len: usize,
) callconv(.c) ?*anyopaque;

pub const TelemetryExitFn = ?*const fn (
    user_data: ?*anyopaque,
    scope_name: [*c]const u8,
    scope_name_len: usize,
    token: ?*anyopaque,
) callconv(.c) void;

pub const ai_telemetry_vtable = extern struct {
    struct_size: usize,
    user_data: ?*anyopaque,
    on_event: TelemetryEventFn,
    enter: TelemetryEnterFn,
    exit: TelemetryExitFn,
};

pub const empty_string: ai_string = .{ .ptr = null, .len = 0 };

pub fn string(value: []const u8) ai_string {
    return .{ .ptr = value.ptr, .len = value.len };
}

pub fn initialized(comptime T: type) T {
    var value: T = std.mem.zeroes(T);
    value.struct_size = @sizeOf(T);
    return value;
}

/// Reads only the leading size_t before reading the full known prefix. Larger
/// structs are accepted and their unknown tail is ignored.
pub fn readStruct(comptime T: type, ptr: [*c]const T) error{InvalidArgumentError}!T {
    if (ptr == null) return error.InvalidArgumentError;
    const size_ptr: [*c]const usize = @ptrCast(ptr);
    const caller_size = size_ptr[0];
    if (caller_size < minimumStructSize(T)) return error.InvalidArgumentError;
    var value = std.mem.zeroes(T);
    const destination = std.mem.asBytes(&value);
    const source: [*]const u8 = @ptrCast(ptr);
    @memcpy(destination[0..@min(caller_size, destination.len)], source[0..@min(caller_size, destination.len)]);
    return value;
}

pub fn validateOutputStruct(comptime T: type, ptr: [*c]T) error{InvalidArgumentError}!void {
    if (ptr == null) return error.InvalidArgumentError;
    const size_ptr: [*c]const usize = @ptrCast(ptr);
    if (size_ptr[0] < minimumStructSize(T)) return error.InvalidArgumentError;
}

/// Writes only the caller-declared prefix, preserving an unknown newer tail
/// and preventing a newer library from overrunning an older v1 caller.
pub fn writeOutputStruct(comptime T: type, ptr: [*c]T, value: T) void {
    const caller_size: *const usize = @ptrCast(ptr);
    const source = std.mem.asBytes(&value);
    const destination: [*]u8 = @ptrCast(ptr);
    @memcpy(destination[0..@min(caller_size.*, source.len)], source[0..@min(caller_size.*, source.len)]);
}

/// Frozen v1 prefix sizes. Keep these formulas unchanged when appending
/// optional fields in later ABI-v1 minors.
pub fn minimumStructSize(comptime T: type) usize {
    const word = @sizeOf(usize);
    if (T == ai_runtime_config) return 3 * word;
    if (T == ai_anthropic_config) return 5 * word;
    if (T == ai_openrouter_config) return 9 * word;
    if (T == ai_openai_compatible_config) return 7 * word;
    if (T == ai_openai_config) return 10 * word;
    if (T == ai_xai_config) return 5 * word;
    if (T == ai_tool_result) return 3 * word;
    if (T == ai_tool) return 9 * word;
    if (T == ai_part) return 6 * word;
    if (T == ai_buffer) return 3 * word;
    if (T == ai_agent_config) return 6 * word;
    if (T == ai_telemetry_vtable) return 5 * word;
    @compileError("no frozen ABI-v1 prefix size for " ++ @typeName(T));
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

test "struct reader rejects short prefixes and accepts larger callers" {
    var config: ai_runtime_config = .{
        .struct_size = @sizeOf(ai_runtime_config) - 1,
        .async_limit = 0,
        .concurrent_limit = 0,
    };
    try std.testing.expectError(error.InvalidArgumentError, readStruct(ai_runtime_config, &config));
    config.struct_size = @sizeOf(ai_runtime_config) + 64;
    _ = try readStruct(ai_runtime_config, &config);
}
