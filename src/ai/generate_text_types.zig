//! Owned result and content types for the non-streaming text tool loop.
//!
//! `content` is the authoritative representation for a step. The slices used
//! by the convenience accessors are derived once from it in the call arena.

const std = @import("std");
const provider = @import("provider");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;

pub const ToolCallErrorKind = enum {
    no_such_tool,
    invalid_input,
    repair_failed,
    other,
};

pub const ToolCallError = struct {
    kind: ToolCallErrorKind,
    err: anyerror,
    message: []const u8,
    original_kind: ?ToolCallErrorKind = null,
};

pub const TypedToolCall = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: std.json.Value,
    provider_executed: bool = false,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?std.json.Value = null,
    dynamic: bool = false,
    invalid: bool = false,
    err: ?ToolCallError = null,
};

pub const TypedToolResult = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: ?std.json.Value,
    output: std.json.Value,
    provider_executed: bool = false,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?std.json.Value = null,
    dynamic: bool = false,
    preliminary: bool = false,
};

pub const TypedToolError = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: ?std.json.Value,
    error_value: std.json.Value,
    error_code: ?anyerror = null,
    provider_executed: bool = false,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?std.json.Value = null,
    dynamic: bool = false,
};

pub const ToolApprovalRequest = struct {
    approval_id: []const u8,
    tool_call: TypedToolCall,
    is_automatic: bool = false,
    signature: ?[]const u8 = null,
};

pub const ToolApprovalResponse = struct {
    approval_id: []const u8,
    tool_call: TypedToolCall,
    approved: bool,
    reason: ?[]const u8 = null,
    provider_executed: bool = false,
};

pub const ContentPart = union(enum) {
    text: provider.TextContent,
    reasoning: provider.ReasoningContent,
    reasoning_file: provider.GeneratedReasoningFile,
    file: provider.GeneratedFile,
    source: provider.Source,
    custom: provider.CustomContent,
    tool_call: TypedToolCall,
    tool_result: TypedToolResult,
    tool_error: TypedToolError,
    tool_approval_request: ToolApprovalRequest,
    tool_approval_response: ToolApprovalResponse,
};

pub const ReasoningOutput = union(enum) {
    reasoning: provider.ReasoningContent,
    reasoning_file: provider.GeneratedReasoningFile,
};

pub const ToolExecutionTiming = struct {
    tool_call_id: []const u8,
    milliseconds: f64,
};

pub const StepPerformance = struct {
    effective_output_tokens_per_second: f64,
    output_tokens_per_second: ?f64 = null,
    input_tokens_per_second: ?f64 = null,
    effective_total_tokens_per_second: f64,
    step_time_ms: f64,
    response_time_ms: f64,
    tool_execution_ms: []const ToolExecutionTiming = &.{},
    time_to_first_output_ms: ?f64 = null,
};

pub const RequestMetadata = struct {
    body: ?std.json.Value = null,
    messages: ?[]const message.ModelMessage = null,
};

pub const ResponseMetadata = struct {
    id: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,
    headers: ?provider.Headers = null,
    body: ?std.json.Value = null,
    messages: []const message.ModelMessage = &.{},
};

pub const ModelInfo = struct {
    provider_name: []const u8,
    model_id: []const u8,
};

pub const StepResult = struct {
    call_id: []const u8,
    step_number: usize,
    model: ModelInfo,
    tools_context: ?std.json.Value,
    runtime_context: ?std.json.Value,
    content: []const ContentPart,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    performance: StepPerformance,
    warnings: []const provider.Warning,
    request: RequestMetadata,
    response: ResponseMetadata,
    provider_metadata: ?provider.ProviderMetadata,

    text_value: []const u8 = "",
    reasoning_value: []const ReasoningOutput = &.{},
    reasoning_text_value: ?[]const u8 = null,
    files_value: []const provider.GeneratedFile = &.{},
    sources_value: []const provider.Source = &.{},
    tool_calls_value: []const TypedToolCall = &.{},
    static_tool_calls_value: []const TypedToolCall = &.{},
    dynamic_tool_calls_value: []const TypedToolCall = &.{},
    tool_results_value: []const TypedToolResult = &.{},
    static_tool_results_value: []const TypedToolResult = &.{},
    dynamic_tool_results_value: []const TypedToolResult = &.{},
    tool_errors_value: []const TypedToolError = &.{},

    pub fn derive(self: *StepResult, arena: Allocator) Allocator.Error!void {
        var text_parts: std.ArrayList(u8) = .empty;
        defer text_parts.deinit(arena);
        var reasoning_parts: std.ArrayList(u8) = .empty;
        defer reasoning_parts.deinit(arena);
        var reasoning_outputs: std.ArrayList(ReasoningOutput) = .empty;
        defer reasoning_outputs.deinit(arena);
        var file_list: std.ArrayList(provider.GeneratedFile) = .empty;
        defer file_list.deinit(arena);
        var source_list: std.ArrayList(provider.Source) = .empty;
        defer source_list.deinit(arena);
        var calls: std.ArrayList(TypedToolCall) = .empty;
        defer calls.deinit(arena);
        var static_calls: std.ArrayList(TypedToolCall) = .empty;
        defer static_calls.deinit(arena);
        var dynamic_calls: std.ArrayList(TypedToolCall) = .empty;
        defer dynamic_calls.deinit(arena);
        var result_list: std.ArrayList(TypedToolResult) = .empty;
        defer result_list.deinit(arena);
        var static_results: std.ArrayList(TypedToolResult) = .empty;
        defer static_results.deinit(arena);
        var dynamic_results: std.ArrayList(TypedToolResult) = .empty;
        defer dynamic_results.deinit(arena);
        var error_list: std.ArrayList(TypedToolError) = .empty;
        defer error_list.deinit(arena);

        for (self.content) |part| switch (part) {
            .text => |value| try text_parts.appendSlice(arena, value.text),
            .reasoning => |value| {
                try reasoning_parts.appendSlice(arena, value.text);
                try reasoning_outputs.append(arena, .{ .reasoning = value });
            },
            .reasoning_file => |value| try reasoning_outputs.append(arena, .{ .reasoning_file = value }),
            .file => |value| try file_list.append(arena, value),
            .source => |value| try source_list.append(arena, value),
            .tool_call => |value| {
                try calls.append(arena, value);
                if (value.dynamic) {
                    try dynamic_calls.append(arena, value);
                } else {
                    try static_calls.append(arena, value);
                }
            },
            .tool_result => |value| {
                try result_list.append(arena, value);
                if (value.dynamic) {
                    try dynamic_results.append(arena, value);
                } else {
                    try static_results.append(arena, value);
                }
            },
            .tool_error => |value| try error_list.append(arena, value),
            .custom, .tool_approval_request, .tool_approval_response => {},
        };

        self.text_value = try text_parts.toOwnedSlice(arena);
        self.reasoning_value = try reasoning_outputs.toOwnedSlice(arena);
        self.reasoning_text_value = if (reasoning_parts.items.len == 0)
            null
        else
            try reasoning_parts.toOwnedSlice(arena);
        self.files_value = try file_list.toOwnedSlice(arena);
        self.sources_value = try source_list.toOwnedSlice(arena);
        self.tool_calls_value = try calls.toOwnedSlice(arena);
        self.static_tool_calls_value = try static_calls.toOwnedSlice(arena);
        self.dynamic_tool_calls_value = try dynamic_calls.toOwnedSlice(arena);
        self.tool_results_value = try result_list.toOwnedSlice(arena);
        self.static_tool_results_value = try static_results.toOwnedSlice(arena);
        self.dynamic_tool_results_value = try dynamic_results.toOwnedSlice(arena);
        self.tool_errors_value = try error_list.toOwnedSlice(arena);
    }

    pub fn text(self: *const StepResult) []const u8 {
        return self.text_value;
    }

    pub fn reasoningText(self: *const StepResult) ?[]const u8 {
        return self.reasoning_text_value;
    }

    pub fn reasoning(self: *const StepResult) []const ReasoningOutput {
        return self.reasoning_value;
    }

    pub fn files(self: *const StepResult) []const provider.GeneratedFile {
        return self.files_value;
    }

    pub fn sources(self: *const StepResult) []const provider.Source {
        return self.sources_value;
    }

    pub fn toolCalls(self: *const StepResult) []const TypedToolCall {
        return self.tool_calls_value;
    }

    pub fn staticToolCalls(self: *const StepResult) []const TypedToolCall {
        return self.static_tool_calls_value;
    }

    pub fn dynamicToolCalls(self: *const StepResult) []const TypedToolCall {
        return self.dynamic_tool_calls_value;
    }

    pub fn toolResults(self: *const StepResult) []const TypedToolResult {
        return self.tool_results_value;
    }

    pub fn staticToolResults(self: *const StepResult) []const TypedToolResult {
        return self.static_tool_results_value;
    }

    pub fn dynamicToolResults(self: *const StepResult) []const TypedToolResult {
        return self.dynamic_tool_results_value;
    }

    pub fn toolErrors(self: *const StepResult) []const TypedToolError {
        return self.tool_errors_value;
    }
};

pub const OutputValue = union(enum) {
    text: []const u8,
    json: std.json.Value,
};

pub const GenerateTextResult = struct {
    arena_state: std.heap.ArenaAllocator,
    steps: []const StepResult,
    total_usage: provider.Usage,
    response_messages: []const message.ModelMessage,
    initial_response_messages: []const message.ModelMessage,
    all_content: []const ContentPart,
    all_files: []const provider.GeneratedFile,
    all_sources: []const provider.Source,
    all_tool_calls: []const TypedToolCall,
    all_static_tool_calls: []const TypedToolCall,
    all_dynamic_tool_calls: []const TypedToolCall,
    all_tool_results: []const TypedToolResult,
    all_static_tool_results: []const TypedToolResult,
    all_dynamic_tool_results: []const TypedToolResult,
    all_warnings: []const provider.Warning,
    parsed_output: ?OutputValue,

    pub fn deinit(self: *GenerateTextResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn finalStep(self: *const GenerateTextResult) *const StepResult {
        return &self.steps[self.steps.len - 1];
    }

    pub fn content(self: *const GenerateTextResult) []const ContentPart {
        return self.all_content;
    }

    pub fn text(self: *const GenerateTextResult) []const u8 {
        return self.finalStep().text();
    }

    pub fn reasoningText(self: *const GenerateTextResult) ?[]const u8 {
        return self.finalStep().reasoningText();
    }

    pub fn reasoning(self: *const GenerateTextResult) []const ReasoningOutput {
        return self.finalStep().reasoning();
    }

    pub fn files(self: *const GenerateTextResult) []const provider.GeneratedFile {
        return self.all_files;
    }

    pub fn sources(self: *const GenerateTextResult) []const provider.Source {
        return self.all_sources;
    }

    pub fn toolCalls(self: *const GenerateTextResult) []const TypedToolCall {
        return self.all_tool_calls;
    }

    pub fn staticToolCalls(self: *const GenerateTextResult) []const TypedToolCall {
        return self.all_static_tool_calls;
    }

    pub fn dynamicToolCalls(self: *const GenerateTextResult) []const TypedToolCall {
        return self.all_dynamic_tool_calls;
    }

    pub fn toolResults(self: *const GenerateTextResult) []const TypedToolResult {
        return self.all_tool_results;
    }

    pub fn staticToolResults(self: *const GenerateTextResult) []const TypedToolResult {
        return self.all_static_tool_results;
    }

    pub fn dynamicToolResults(self: *const GenerateTextResult) []const TypedToolResult {
        return self.all_dynamic_tool_results;
    }

    pub fn finishReason(self: *const GenerateTextResult) provider.FinishReason {
        return self.finalStep().finish_reason;
    }

    pub fn rawFinishReason(self: *const GenerateTextResult) ?[]const u8 {
        return self.finalStep().finish_reason.raw;
    }

    pub fn usage(self: *const GenerateTextResult) provider.Usage {
        return self.total_usage;
    }

    pub fn warnings(self: *const GenerateTextResult) []const provider.Warning {
        return self.all_warnings;
    }

    pub fn request(self: *const GenerateTextResult) RequestMetadata {
        return self.finalStep().request;
    }

    pub fn response(self: *const GenerateTextResult) ResponseMetadata {
        return self.finalStep().response;
    }

    pub fn providerMetadata(self: *const GenerateTextResult) ?provider.ProviderMetadata {
        return self.finalStep().provider_metadata;
    }

    pub fn responseMessages(self: *const GenerateTextResult) []const message.ModelMessage {
        return self.response_messages;
    }

    pub fn output(self: *const GenerateTextResult) provider.Error!OutputValue {
        return self.parsed_output orelse error.NoOutputGeneratedError;
    }
};

pub fn addTokenCounts(a: ?u64, b: ?u64) ?u64 {
    if (a == null and b == null) return null;
    return (a orelse 0) +| (b orelse 0);
}

pub fn addUsage(a: provider.Usage, b: provider.Usage) provider.Usage {
    return .{
        .input_tokens = .{
            .total = addTokenCounts(a.input_tokens.total, b.input_tokens.total),
            .no_cache = addTokenCounts(a.input_tokens.no_cache, b.input_tokens.no_cache),
            .cache_read = addTokenCounts(a.input_tokens.cache_read, b.input_tokens.cache_read),
            .cache_write = addTokenCounts(a.input_tokens.cache_write, b.input_tokens.cache_write),
        },
        .output_tokens = .{
            .total = addTokenCounts(a.output_tokens.total, b.output_tokens.total),
            .text = addTokenCounts(a.output_tokens.text, b.output_tokens.text),
            .reasoning = addTokenCounts(a.output_tokens.reasoning, b.output_tokens.reasoning),
        },
        .raw = null,
    };
}

pub const zero_usage: provider.Usage = .{
    .input_tokens = .{},
    .output_tokens = .{},
};

test "usage accumulation preserves undefined plus undefined" {
    const first: provider.Usage = .{
        .input_tokens = .{ .total = 3, .cache_read = 2 },
        .output_tokens = .{ .total = 4, .text = 4 },
    };
    const second: provider.Usage = .{
        .input_tokens = .{ .total = 5 },
        .output_tokens = .{ .total = 6, .reasoning = 1 },
    };
    const total = addUsage(first, second);
    try std.testing.expectEqual(8, total.input_tokens.total.?);
    try std.testing.expectEqual(2, total.input_tokens.cache_read.?);
    try std.testing.expectEqual(null, total.input_tokens.no_cache);
    try std.testing.expectEqual(10, total.output_tokens.total.?);
    try std.testing.expectEqual(4, total.output_tokens.text.?);
    try std.testing.expectEqual(1, total.output_tokens.reasoning.?);
}
