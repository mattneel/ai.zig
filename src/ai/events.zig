//! Stable telemetry event shapes for the AI core lifecycle.
//!
//! Phase 4b replaces the reserved opaque result slots with the concrete
//! non-streaming text result types.

const std = @import("std");
const provider = @import("provider");
const message = @import("message.zig");
const tool = @import("tool.zig");
const text_types = @import("generate_text_types.zig");

pub const GenerateTextStartEvent = struct {
    call_id: []const u8,
    operation_id: []const u8 = "ai.generateText",
    provider_name: []const u8,
    model_id: []const u8,
    instructions: ?[]const u8 = null,
    messages: []const message.ModelMessage = &.{},
    tools: tool.ToolSet = &.{},
    tool_choice: ?provider.ToolChoice = null,
    max_retries: u32 = 2,
    timeout_ms: ?u64 = null,
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?i64 = null,
    reasoning: ?provider.ReasoningEffort = null,
    provider_options: ?provider.ProviderOptions = null,
    output: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    tools_context: ?std.json.Value = null,
};

pub const StepStartEvent = struct {
    call_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    step_number: usize,
    instructions: ?[]const u8 = null,
    messages: []const message.ModelMessage = &.{},
    prompt_messages: provider.Prompt = &.{},
    tools: tool.ToolSet = &.{},
    step_tools: ?[]const provider.Tool = null,
    tool_choice: ?provider.ToolChoice = null,
    previous_steps: []const text_types.StepResult = &.{},
    provider_options: ?provider.ProviderOptions = null,
    output: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    tools_context: ?std.json.Value = null,
};

pub const LanguageModelCallStartEvent = struct {
    call_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    instructions: ?[]const u8 = null,
    messages: []const message.ModelMessage = &.{},
    tools: ?[]const provider.Tool = null,
    options: *const provider.CallOptions,
};

pub const Performance = struct {
    response_time_ms: f64,
    effective_output_tokens_per_second: f64,
    effective_total_tokens_per_second: f64,
    time_to_first_output_ms: ?f64 = null,
};

pub const LanguageModelCallEndEvent = struct {
    call_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    content: []const text_types.ContentPart,
    response_id: ?[]const u8 = null,
    performance: Performance,
};

pub const ToolCall = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: std.json.Value,
    provider_executed: bool = false,
    dynamic: bool = false,
};

pub const ToolExecutionStartEvent = struct {
    call_id: []const u8,
    tool_call: ToolCall,
    messages: []const message.ModelMessage,
    tool_context: ?std.json.Value = null,
};

pub const ToolExecutionOutput = union(enum) {
    result: std.json.Value,
    err: anyerror,
};

pub const ToolExecutionEndEvent = struct {
    call_id: []const u8,
    tool_call: ToolCall,
    messages: []const message.ModelMessage,
    tool_context: ?std.json.Value = null,
    tool_output: ToolExecutionOutput,
    tool_execution_ms: f64,
};

pub const StepEndEvent = struct {
    call_id: []const u8,
    step_number: usize,
    step_result: *const text_types.StepResult,
};

pub const EndEvent = struct {
    call_id: []const u8,
    step_number: usize,
    model: provider.LanguageModel,
    text: []const u8,
    content: []const text_types.ContentPart,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    warnings: []const provider.Warning,
    response_messages: []const message.ModelMessage = &.{},
    steps: []const text_types.StepResult = &.{},
    final_step: ?*const text_types.StepResult = null,
    runtime_context: ?std.json.Value = null,
    tools_context: ?std.json.Value = null,
};

pub const AbortEvent = struct {
    call_id: []const u8,
    reason: ?[]const u8 = null,
};

pub const ErrorEvent = struct {
    call_id: []const u8,
    err: anyerror,
    diag: ?*const provider.Diagnostics = null,
};

// ABI-stable callback slots reserved for later operation phases. Their dense
// shapes carry correlation and model identity now; later phases may append
// fields without changing the Telemetry vtable layout.
pub const ObjectStepStartEvent = struct {
    call_id: []const u8,
    step_number: usize,
    provider_name: []const u8,
    model_id: []const u8,
};

pub const ObjectStepEndEvent = struct {
    call_id: []const u8,
    step_number: usize,
    object_text: []const u8,
};

pub const EmbedStartEvent = struct {
    call_id: []const u8,
    embed_call_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    values: []const std.json.Value,
};

pub const EmbedEndEvent = struct {
    call_id: []const u8,
    embed_call_id: []const u8,
    embeddings: []const []const f32,
    warnings: []const provider.Warning = &.{},
};

pub const RerankStartEvent = struct {
    call_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    query: []const u8,
    top_n: ?usize = null,
};

pub const RerankEndEvent = struct {
    call_id: []const u8,
    ranking: []const provider.Ranking,
};
