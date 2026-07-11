//! Language model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for language-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;
/// Error boundary for language-model-v4-stream-result.ts pulls.
pub const NextError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors json-value.ts in language model fields.
pub const JsonValue = shared.JsonValue;
/// Mirrors shared-v4-provider-options.ts in language model fields.
pub const ProviderOptions = shared.ProviderOptions;
/// Mirrors shared-v4-provider-metadata.ts in language model fields.
pub const ProviderMetadata = shared.ProviderMetadata;
/// Mirrors shared-v4-headers.ts in language model fields.
pub const Headers = shared.Headers;
/// Mirrors shared-v4-warning.ts in language model fields.
pub const Warning = shared.Warning;
/// Mirrors shared-v4-file-data.ts in prompt fields.
pub const FileData = shared.FileData;
/// Mirrors language-model-v4-file.ts generated file data.
pub const GeneratedFileData = shared.GeneratedFileData;
/// Mirrors language-model-v4-finish-reason.ts.
pub const FinishReason = errors.FinishReason;
/// Mirrors language-model-v4-finish-reason.ts unified values.
pub const FinishReasonUnified = errors.FinishReasonUnified;

/// Mirrors language-model-v4-call-options.ts reasoning values.
pub const ReasoningEffort = enum {
    provider_default,
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub const wire_values = .{
        .{ .provider_default, "provider-default" },
        .{ .none, "none" },
        .{ .minimal, "minimal" },
        .{ .low, "low" },
        .{ .medium, "medium" },
        .{ .high, "high" },
        .{ .xhigh, "xhigh" },
    };
};

/// Mirrors language-model-v4-call-options.ts responseFormat.
pub const ResponseFormat = union(enum) {
    text: Text,
    json: Json,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .json, "json" },
    };

    /// Mirrors language-model-v4-call-options.ts text response format.
    pub const Text = struct {};
    /// Mirrors language-model-v4-call-options.ts JSON response format.
    pub const Json = struct {
        schema: ?JsonValue = null,
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };
};

/// Mirrors language-model-v4-prompt.ts text part.
pub const TextPart = struct {
    text: []const u8,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts reasoning part.
pub const ReasoningPart = struct {
    text: []const u8,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts reasoning-file part.
pub const ReasoningFilePart = struct {
    data: GeneratedFileData,
    media_type: []const u8,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts custom part.
pub const CustomPart = struct {
    kind: []const u8,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts file part.
pub const FilePart = struct {
    filename: ?[]const u8 = null,
    data: FileData,
    media_type: []const u8,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts prompt-side tool-call part. Its input
/// is parsed JSON, unlike generated tool calls whose input is a JSON string.
pub const ToolCallPart = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: JsonValue,
    provider_executed: ?bool = null,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts tool-result part.
pub const ToolResultPart = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    output: ToolResultOutput,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-prompt.ts tool-approval-response part.
pub const ToolApprovalResponsePart = struct {
    approval_id: []const u8,
    approved: bool,
    reason: ?[]const u8 = null,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors the nested content list in language-model-v4-prompt.ts.
pub const ToolResultContentPart = union(enum) {
    text: Text,
    file: File,
    custom: Custom,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .file, "file" },
        .{ .custom, "custom" },
    };

    /// Mirrors language-model-v4-prompt.ts nested text tool output.
    pub const Text = struct {
        text: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts nested file tool output.
    pub const File = struct {
        data: FileData,
        media_type: []const u8,
        filename: ?[]const u8 = null,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts nested custom tool output.
    pub const Custom = struct {
        provider_options: ?ProviderOptions = null,
    };
};

/// Mirrors language-model-v4-prompt.ts ToolResultOutput.
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

    /// Mirrors language-model-v4-prompt.ts text ToolResultOutput.
    pub const Text = struct {
        value: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts JSON ToolResultOutput.
    pub const Json = struct {
        value: JsonValue,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts execution-denied ToolResultOutput.
    pub const ExecutionDenied = struct {
        reason: ?[]const u8 = null,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts error-text ToolResultOutput.
    pub const ErrorText = struct {
        value: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts error-json ToolResultOutput.
    pub const ErrorJson = struct {
        value: JsonValue,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts content ToolResultOutput.
    pub const ContentOutput = struct {
        value: []const ToolResultContentPart,
    };
};

/// Mirrors the user-role content union in language-model-v4-prompt.ts.
pub const UserContentPart = union(enum) {
    text: TextPart,
    file: FilePart,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .file, "file" },
    };
};

/// Mirrors the assistant-role content union in language-model-v4-prompt.ts.
pub const AssistantContentPart = union(enum) {
    text: TextPart,
    file: FilePart,
    custom: CustomPart,
    reasoning: ReasoningPart,
    reasoning_file: ReasoningFilePart,
    tool_call: ToolCallPart,
    tool_result: ToolResultPart,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .file, "file" },
        .{ .custom, "custom" },
        .{ .reasoning, "reasoning" },
        .{ .reasoning_file, "reasoning-file" },
        .{ .tool_call, "tool-call" },
        .{ .tool_result, "tool-result" },
    };
};

/// Mirrors the tool-role content union in language-model-v4-prompt.ts.
pub const ToolContentPart = union(enum) {
    tool_result: ToolResultPart,
    tool_approval_response: ToolApprovalResponsePart,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .tool_result, "tool-result" },
        .{ .tool_approval_response, "tool-approval-response" },
    };
};

/// Mirrors language-model-v4-prompt.ts Message.
pub const Message = union(enum) {
    system: System,
    user: User,
    assistant: Assistant,
    tool: ToolMessage,

    pub const wire_tag_field = "role";
    pub const wire_tags = .{
        .{ .system, "system" },
        .{ .user, "user" },
        .{ .assistant, "assistant" },
        .{ .tool, "tool" },
    };

    /// Mirrors language-model-v4-prompt.ts system message.
    pub const System = struct {
        content: []const u8,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts user message.
    pub const User = struct {
        content: []const UserContentPart,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts assistant message.
    pub const Assistant = struct {
        content: []const AssistantContentPart,
        provider_options: ?ProviderOptions = null,
    };
    /// Mirrors language-model-v4-prompt.ts tool message.
    pub const ToolMessage = struct {
        content: []const ToolContentPart,
        provider_options: ?ProviderOptions = null,
    };
};

/// Mirrors language-model-v4-prompt.ts Prompt.
pub const Prompt = []const Message;

/// Mirrors language-model-v4-function-tool.ts.
pub const FunctionTool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema: JsonValue,
    input_examples: ?[]const InputExample = null,
    strict: ?bool = null,
    provider_options: ?ProviderOptions = null,

    /// Mirrors language-model-v4-function-tool.ts input example.
    pub const InputExample = struct { input: JsonValue };
};

/// Mirrors language-model-v4-provider-tool.ts.
pub const ProviderTool = struct {
    id: []const u8,
    name: []const u8,
    args: JsonValue,
};

/// Mirrors the function|provider tool union in language-model-v4-call-options.ts.
pub const Tool = union(enum) {
    function: FunctionTool,
    provider: ProviderTool,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .function, "function" },
        .{ .provider, "provider" },
    };
};

/// Mirrors language-model-v4-tool-choice.ts.
pub const ToolChoice = union(enum) {
    auto: Empty,
    none: Empty,
    required: Empty,
    tool: Named,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .auto, "auto" },
        .{ .none, "none" },
        .{ .required, "required" },
        .{ .tool, "tool" },
    };

    /// Mirrors language-model-v4-tool-choice.ts empty choice payloads.
    pub const Empty = struct {};
    /// Mirrors language-model-v4-tool-choice.ts named-tool payload.
    pub const Named = struct { tool_name: []const u8 };
};

/// Mirrors language-model-v4-call-options.ts. AbortSignal is intentionally
/// absent: cancelation is provided by the `std.Io` passed to model calls.
pub const CallOptions = struct {
    prompt: Prompt,
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    response_format: ?ResponseFormat = null,
    seed: ?i64 = null,
    tools: ?[]const Tool = null,
    tool_choice: ?ToolChoice = null,
    include_raw_chunks: ?bool = null,
    headers: ?Headers = null,
    reasoning: ?ReasoningEffort = null,
    provider_options: ?ProviderOptions = null,
};

/// Mirrors language-model-v4-usage.ts inputTokens.
pub const InputTokens = struct {
    total: ?u64 = null,
    no_cache: ?u64 = null,
    cache_read: ?u64 = null,
    cache_write: ?u64 = null,
};

/// Mirrors language-model-v4-usage.ts outputTokens.
pub const OutputTokens = struct {
    total: ?u64 = null,
    text: ?u64 = null,
    reasoning: ?u64 = null,
};

/// Mirrors language-model-v4-usage.ts.
pub const Usage = struct {
    input_tokens: InputTokens,
    output_tokens: OutputTokens,
    raw: ?JsonValue = null,
};

/// Mirrors language-model-v4-text.ts.
pub const TextContent = struct {
    text: []const u8,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-reasoning.ts.
pub const ReasoningContent = struct {
    text: []const u8,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-custom-content.ts.
pub const CustomContent = struct {
    kind: []const u8,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-file.ts.
pub const GeneratedFile = struct {
    media_type: []const u8,
    data: GeneratedFileData,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-reasoning-file.ts.
pub const GeneratedReasoningFile = struct {
    media_type: []const u8,
    data: GeneratedFileData,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-tool-approval-request.ts.
pub const ToolApprovalRequest = struct {
    approval_id: []const u8,
    tool_call_id: []const u8,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-tool-call.ts. `input` is stringified JSON.
pub const GeneratedToolCall = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: []const u8,
    provider_executed: ?bool = null,
    dynamic: ?bool = null,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-tool-result.ts.
pub const GeneratedToolResult = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    result: JsonValue,
    is_error: ?bool = null,
    preliminary: ?bool = null,
    dynamic: ?bool = null,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-source.ts using its `sourceType`
/// sub-discriminator. When nested in Content or StreamPart its fields are
/// flattened into the enclosing `type:"source"` object by the wire codec.
pub const Source = union(enum) {
    url: Url,
    document: Document,

    pub const wire_tag_field = "sourceType";
    pub const wire_tags = .{
        .{ .url, "url" },
        .{ .document, "document" },
    };

    /// Mirrors language-model-v4-source.ts URL source.
    pub const Url = struct {
        id: []const u8,
        url: []const u8,
        title: ?[]const u8 = null,
        provider_metadata: ?ProviderMetadata = null,
    };
    /// Mirrors language-model-v4-source.ts document source.
    pub const Document = struct {
        id: []const u8,
        media_type: []const u8,
        title: []const u8,
        filename: ?[]const u8 = null,
        provider_metadata: ?ProviderMetadata = null,
    };
};

/// Mirrors language-model-v4-content.ts.
pub const Content = union(enum) {
    text: TextContent,
    reasoning: ReasoningContent,
    custom: CustomContent,
    reasoning_file: GeneratedReasoningFile,
    file: GeneratedFile,
    tool_approval_request: ToolApprovalRequest,
    source: Source,
    tool_call: GeneratedToolCall,
    tool_result: GeneratedToolResult,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .reasoning, "reasoning" },
        .{ .custom, "custom" },
        .{ .reasoning_file, "reasoning-file" },
        .{ .file, "file" },
        .{ .tool_approval_request, "tool-approval-request" },
        .{ .source, "source" },
        .{ .tool_call, "tool-call" },
        .{ .tool_result, "tool-result" },
    };
};

/// Mirrors language-model-v4-response-metadata.ts.
pub const ResponseMetadata = struct {
    id: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors the stream text/reasoning start/end shapes.
pub const BlockBoundary = struct {
    provider_metadata: ?ProviderMetadata = null,
    id: []const u8,
};

/// Mirrors the stream text/reasoning delta shapes.
pub const BlockDelta = struct {
    id: []const u8,
    provider_metadata: ?ProviderMetadata = null,
    delta: []const u8,
};

/// Mirrors language-model-v4-stream-part.ts tool-input-start.
pub const ToolInputStart = struct {
    id: []const u8,
    tool_name: []const u8,
    provider_metadata: ?ProviderMetadata = null,
    provider_executed: ?bool = null,
    dynamic: ?bool = null,
    title: ?[]const u8 = null,
};

/// Mirrors language-model-v4-stream-part.ts tool-input-delta.
pub const ToolInputDelta = struct {
    id: []const u8,
    delta: []const u8,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-stream-part.ts tool-input-end.
pub const ToolInputEnd = struct {
    id: []const u8,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-stream-part.ts stream-start.
pub const StreamStart = struct { warnings: []const Warning };

/// Mirrors language-model-v4-stream-part.ts finish.
pub const FinishPart = struct {
    usage: Usage,
    finish_reason: FinishReason,
    provider_metadata: ?ProviderMetadata = null,
};

/// Mirrors language-model-v4-stream-part.ts raw.
pub const RawPart = struct { raw_value: JsonValue };

/// Mirrors language-model-v4-stream-part.ts error.
pub const ErrorPart = struct {
    error_value: JsonValue,

    pub const wire_field_names = .{
        .{ "error_value", "error" },
    };
};

/// Mirrors every variant of language-model-v4-stream-part.ts. The upstream
/// union has 22 concrete shapes when the two source subtypes share one outer
/// `source` tag.
pub const StreamPart = union(enum) {
    text_start: BlockBoundary,
    text_delta: BlockDelta,
    text_end: BlockBoundary,
    reasoning_start: BlockBoundary,
    reasoning_delta: BlockDelta,
    reasoning_end: BlockBoundary,
    tool_input_start: ToolInputStart,
    tool_input_delta: ToolInputDelta,
    tool_input_end: ToolInputEnd,
    tool_approval_request: ToolApprovalRequest,
    tool_call: GeneratedToolCall,
    tool_result: GeneratedToolResult,
    custom: CustomContent,
    file: GeneratedFile,
    reasoning_file: GeneratedReasoningFile,
    source: Source,
    stream_start: StreamStart,
    response_metadata: ResponseMetadata,
    finish: FinishPart,
    raw: RawPart,
    err: ErrorPart,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text_start, "text-start" },
        .{ .text_delta, "text-delta" },
        .{ .text_end, "text-end" },
        .{ .reasoning_start, "reasoning-start" },
        .{ .reasoning_delta, "reasoning-delta" },
        .{ .reasoning_end, "reasoning-end" },
        .{ .tool_input_start, "tool-input-start" },
        .{ .tool_input_delta, "tool-input-delta" },
        .{ .tool_input_end, "tool-input-end" },
        .{ .tool_approval_request, "tool-approval-request" },
        .{ .tool_call, "tool-call" },
        .{ .tool_result, "tool-result" },
        .{ .custom, "custom" },
        .{ .file, "file" },
        .{ .reasoning_file, "reasoning-file" },
        .{ .source, "source" },
        .{ .stream_start, "stream-start" },
        .{ .response_metadata, "response-metadata" },
        .{ .finish, "finish" },
        .{ .raw, "raw" },
        .{ .err, "error" },
    };
};

/// Mirrors language-model-v4-stream-result.ts request information.
pub const RequestInfo = struct {
    body: ?JsonValue = null,
};

/// Mirrors language-model-v4-generate-result.ts response information.
pub const ResponseInfo = struct {
    id: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,
    headers: ?Headers = null,
    body: ?JsonValue = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors language-model-v4-stream-result.ts response information. Providers
/// must make these headers available before the first stream part is pulled.
pub const StreamResponseInfo = struct {
    headers: ?Headers = null,
};

/// Mirrors language-model-v4-generate-result.ts.
pub const GenerateResult = struct {
    content: []const Content,
    finish_reason: FinishReason,
    usage: Usage,
    provider_metadata: ?ProviderMetadata = null,
    request: ?RequestInfo = null,
    response: ?ResponseInfo = null,
    warnings: []const Warning,
};

/// Pull-based replacement for `ReadableStream<LanguageModelV4StreamPart>`.
/// A returned part and every slice reachable from it remain valid only until
/// the next `next()` call or `deinit()` (borrow-until-next-call, matching the
/// `std.json.Token` lifetime idiom).
pub const PartStream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors language-model-v4-stream-result.ts stream operations.
    pub const VTable = struct {
        next: *const fn (ctx: *anyopaque, io: std.Io) NextError!?StreamPart,
        deinit: *const fn (ctx: *anyopaque, io: std.Io) void,
    };

    pub fn next(self: PartStream, io: std.Io) NextError!?StreamPart {
        return self.vtable.next(self.ctx, io);
    }

    pub fn deinit(self: PartStream, io: std.Io) void {
        self.vtable.deinit(self.ctx, io);
    }
};

/// Mirrors language-model-v4-stream-result.ts with the locked pull boundary.
pub const StreamResult = struct {
    stream: PartStream,
    request: RequestInfo = .{},
    response: StreamResponseInfo = .{},
};

/// Mirrors language-model-v4.ts as a Zig fat-pointer interface. Upstream
/// PromiseLike properties become possibly-blocking calls, and cancelation is
/// provided by `std.Io` rather than AbortSignal.
pub const LanguageModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors language-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        urlIsSupported: *const fn (
            ctx: *anyopaque,
            media_type: []const u8,
            url: []const u8,
        ) bool,
        doGenerate: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!GenerateResult,
        doStream: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!StreamResult,
    };

    pub fn provider(self: LanguageModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: LanguageModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn urlIsSupported(self: LanguageModel, media_type: []const u8, url: []const u8) bool {
        return self.vtable.urlIsSupported(self.ctx, media_type, url);
    }

    pub fn doGenerate(
        self: LanguageModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!GenerateResult {
        return self.vtable.doGenerate(self.ctx, io, arena, options, diag);
    }

    pub fn doStream(
        self: LanguageModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!StreamResult {
        return self.vtable.doStream(self.ctx, io, arena, options, diag);
    }
};

comptime {
    _ = std;
}
