//! Public and inter-stage streaming vocabularies.
//!
//! Every payload is POD-with-slices so it can cross `std.Io.Queue` by value.
//! The slices retain the arena that created the containing step.

const std = @import("std");
const provider = @import("provider");
const types = @import("../generate_text_types.zig");

pub const TypedToolCall = types.TypedToolCall;
pub const TypedToolResult = types.TypedToolResult;
pub const TypedToolError = types.TypedToolError;
pub const ToolApprovalRequest = types.ToolApprovalRequest;
pub const ToolApprovalResponse = types.ToolApprovalResponse;
pub const ChunkTimingStats = types.ChunkTimingStats;
pub const StepPerformance = types.StepPerformance;
pub const ToolExecutionTiming = types.ToolExecutionTiming;

pub const TextBlockBoundary = struct {
    id: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const TextDelta = struct {
    id: []const u8,
    text: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const Custom = struct {
    kind: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ToolInputStart = struct {
    id: []const u8,
    tool_name: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
    tool_metadata: ?std.json.Value = null,
    provider_executed: ?bool = null,
    dynamic: ?bool = null,
    title: ?[]const u8 = null,
};

pub const ToolInputDelta = struct {
    id: []const u8,
    delta: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ToolInputEnd = struct {
    id: []const u8,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const ToolOutputDenied = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    provider_executed: bool = false,
    dynamic: bool = false,
};

pub const StartStep = struct {
    request: types.RequestMetadata,
    warnings: []const provider.Warning,
};

pub const FinishStep = struct {
    response: types.ResponseMetadata,
    usage: provider.Usage,
    performance: StepPerformance,
    finish_reason: provider.FinishReason,
    raw_finish_reason: ?[]const u8 = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const Finish = struct {
    finish_reason: provider.FinishReason,
    raw_finish_reason: ?[]const u8 = null,
    total_usage: provider.Usage,
};

pub const Abort = struct { reason: ?[]const u8 = null };

pub const StreamError = struct {
    error_value: std.json.Value,
    error_code: ?anyerror = null,
};

/// Public `streamText` part vocabulary. Keep switches over this union
/// exhaustive so upstream additions become compile failures.
pub const TextStreamPart = union(enum) {
    text_start: TextBlockBoundary,
    text_delta: TextDelta,
    text_end: TextBlockBoundary,
    reasoning_start: TextBlockBoundary,
    reasoning_delta: TextDelta,
    reasoning_end: TextBlockBoundary,
    custom: Custom,
    tool_input_start: ToolInputStart,
    tool_input_delta: ToolInputDelta,
    tool_input_end: ToolInputEnd,
    source: provider.Source,
    file: provider.GeneratedFile,
    reasoning_file: provider.GeneratedReasoningFile,
    tool_call: TypedToolCall,
    tool_result: TypedToolResult,
    tool_error: TypedToolError,
    tool_output_denied: ToolOutputDenied,
    tool_approval_request: ToolApprovalRequest,
    tool_approval_response: ToolApprovalResponse,
    start_step: StartStep,
    finish_step: FinishStep,
    start: void,
    finish: Finish,
    abort: Abort,
    err: StreamError,
    raw: std.json.Value,
};

pub const ModelCallPerformance = struct {
    response_time_ms: f64,
    effective_output_tokens_per_second: f64,
    output_tokens_per_second: ?f64 = null,
    input_tokens_per_second: ?f64 = null,
    effective_total_tokens_per_second: f64,
    time_to_first_output_ms: ?f64 = null,
    time_between_output_chunks_ms: ?ChunkTimingStats = null,
};

pub const ModelCallStart = struct { warnings: []const provider.Warning };

pub const ModelCallResponseMetadata = struct {
    id: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,
};

pub const ModelCallEnd = struct {
    finish_reason: provider.FinishReason,
    raw_finish_reason: ?[]const u8 = null,
    usage: provider.Usage,
    provider_metadata: ?provider.ProviderMetadata = null,
    performance: ModelCallPerformance,
};

pub const ToolExecutionEnd = struct {
    tool_call_id: []const u8,
    tool_execution_ms: f64,
};

/// Internal vocabulary shared by the model-call, callback, tool-execution,
/// and Phase 5b step-assembly stages.
pub const LanguageModelStreamPart = union(enum) {
    text_start: TextBlockBoundary,
    text_delta: TextDelta,
    text_end: TextBlockBoundary,
    reasoning_start: TextBlockBoundary,
    reasoning_delta: TextDelta,
    reasoning_end: TextBlockBoundary,
    custom: Custom,
    tool_input_start: ToolInputStart,
    tool_input_delta: ToolInputDelta,
    tool_input_end: ToolInputEnd,
    source: provider.Source,
    file: provider.GeneratedFile,
    reasoning_file: provider.GeneratedReasoningFile,
    tool_call: TypedToolCall,
    tool_result: TypedToolResult,
    tool_error: TypedToolError,
    tool_approval_request: ToolApprovalRequest,
    tool_approval_response: ToolApprovalResponse,
    raw: std.json.Value,
    err: StreamError,
    model_call_start: ModelCallStart,
    model_call_response_metadata: ModelCallResponseMetadata,
    model_call_end: ModelCallEnd,
    tool_execution_end: ToolExecutionEnd,
};

pub fn calculateNearestRankPercentile(sorted_values: []const f64, percentile: f64) f64 {
    std.debug.assert(sorted_values.len > 0);
    std.debug.assert(percentile > 0 and percentile <= 1);
    const rank = @as(usize, @intFromFloat(@ceil(percentile * @as(f64, @floatFromInt(sorted_values.len)))));
    return sorted_values[rank - 1];
}

pub fn calculateChunkTimingStats(allocator: std.mem.Allocator, timings_ms: []const f64) std.mem.Allocator.Error!ChunkTimingStats {
    std.debug.assert(timings_ms.len > 0);
    const sorted = try allocator.dupe(f64, timings_ms);
    defer allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));

    var sum: f64 = 0;
    for (timings_ms) |timing| sum += timing;
    return .{
        .min = sorted[0],
        .p10 = calculateNearestRankPercentile(sorted, 0.1),
        .median = calculateNearestRankPercentile(sorted, 0.5),
        .avg = sum / @as(f64, @floatFromInt(timings_ms.len)),
        .p90 = calculateNearestRankPercentile(sorted, 0.9),
        .max = sorted[sorted.len - 1],
    };
}

fn classify(part: TextStreamPart) usize {
    return switch (part) {
        .text_start => 0,
        .text_delta => 1,
        .text_end => 2,
        .reasoning_start => 3,
        .reasoning_delta => 4,
        .reasoning_end => 5,
        .custom => 6,
        .tool_input_start => 7,
        .tool_input_delta => 8,
        .tool_input_end => 9,
        .source => 10,
        .file => 11,
        .reasoning_file => 12,
        .tool_call => 13,
        .tool_result => 14,
        .tool_error => 15,
        .tool_output_denied => 16,
        .tool_approval_request => 17,
        .tool_approval_response => 18,
        .start_step => 19,
        .finish_step => 20,
        .start => 21,
        .finish => 22,
        .abort => 23,
        .err => 24,
        .raw => 25,
    };
}

test "TextStreamPart vocabulary switch is exhaustive" {
    try std.testing.expectEqual(21, classify(.{ .start = {} }));
    try std.testing.expectEqual(1, classify(.{ .text_delta = .{ .id = "t", .text = "x" } }));
}

test "nearest-rank percentiles and chunk timing stats match hand-computed fixture" {
    const timings = [_]f64{ 10, 90, 20, 80, 30, 70, 40, 60, 50, 100 };
    const stats = try calculateChunkTimingStats(std.testing.allocator, &timings);
    try std.testing.expectEqual(10, stats.min);
    try std.testing.expectEqual(10, stats.p10);
    try std.testing.expectEqual(50, stats.median);
    try std.testing.expectEqual(55, stats.avg);
    try std.testing.expectEqual(90, stats.p90);
    try std.testing.expectEqual(100, stats.max);
}
