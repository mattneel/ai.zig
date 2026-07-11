const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const capabilities = @import("capabilities.zig");

const Allocator = std.mem.Allocator;
pub const ParseError = provider.Error || Allocator.Error;

pub const Logprobs = union(enum) {
    boolean: bool,
    count: u64,
};

pub const ChatOptions = struct {
    logit_bias: ?std.json.Value = null,
    logprobs: ?Logprobs = null,
    parallel_tool_calls: ?bool = null,
    user: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    max_completion_tokens: ?u64 = null,
    store: ?bool = null,
    metadata: ?std.json.Value = null,
    prediction: ?std.json.Value = null,
    service_tier: ?[]const u8 = null,
    strict_json_schema: bool = true,
    text_verbosity: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?std.json.Value = null,
    prompt_cache_retention: ?[]const u8 = null,
    safety_identifier: ?[]const u8 = null,
    system_message_mode: ?capabilities.SystemMessageMode = null,
    force_reasoning: ?bool = null,
};

pub const ContextManagement = struct {
    compact_threshold: std.json.Value,
};

pub const AllowedTools = struct {
    tool_names: []const []const u8,
    mode: []const u8 = "auto",
};

/// Provider options accepted by the OpenAI Responses API model. Field names
/// intentionally mirror the upstream camelCase namespace while this parsed
/// representation mirrors the wire spelling used by request assembly.
pub const ResponsesOptions = struct {
    conversation: ?[]const u8 = null,
    include: ?[]const []const u8 = null,
    instructions: ?[]const u8 = null,
    logprobs: ?Logprobs = null,
    max_tool_calls: ?u64 = null,
    metadata: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    previous_response_id: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?std.json.Value = null,
    prompt_cache_retention: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    reasoning_mode: ?[]const u8 = null,
    reasoning_context: ?[]const u8 = null,
    reasoning_summary: ?[]const u8 = null,
    reasoning_summary_set: bool = false,
    safety_identifier: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    store: ?bool = null,
    pass_through_unsupported_files: bool = false,
    strict_json_schema: bool = true,
    text_verbosity: ?[]const u8 = null,
    truncation: ?[]const u8 = null,
    user: ?[]const u8 = null,
    system_message_mode: ?capabilities.SystemMessageMode = null,
    force_reasoning: ?bool = null,
    context_management: ?[]const ContextManagement = null,
    allowed_tools: ?AllowedTools = null,
};

pub const EmbeddingOptions = struct {
    dimensions: ?u64 = null,
    user: ?[]const u8 = null,
    encoding_format: []const u8 = "float",
};

pub fn parseChatOptions(
    arena: Allocator,
    value: ?provider.ProviderOptions,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!ChatOptions {
    var result: ChatOptions = .{};
    const root = try providerOptionsRoot(arena, value, diag) orelse return result;
    if (root.get("openai")) |canonical| try applyChatNamespace(arena, &result, canonical, diag);
    if (!std.mem.eql(u8, namespace, "openai")) {
        if (root.get(namespace)) |custom| try applyChatNamespace(arena, &result, custom, diag);
    }
    return result;
}

pub fn parseEmbeddingOptions(
    arena: Allocator,
    value: ?provider.ProviderOptions,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!EmbeddingOptions {
    var result: EmbeddingOptions = .{};
    const root = try providerOptionsRoot(arena, value, diag) orelse return result;
    if (root.get("openai")) |canonical| try applyEmbeddingNamespace(arena, &result, canonical, diag);
    if (!std.mem.eql(u8, namespace, "openai")) {
        if (root.get(namespace)) |custom| try applyEmbeddingNamespace(arena, &result, custom, diag);
    }
    return result;
}

pub fn parseResponsesOptions(
    arena: Allocator,
    value: ?provider.ProviderOptions,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!ResponsesOptions {
    var result: ResponsesOptions = .{};
    const root = try providerOptionsRoot(arena, value, diag) orelse return result;
    if (root.get("openai")) |canonical| try applyResponsesNamespace(arena, &result, canonical, diag);
    if (!std.mem.eql(u8, namespace, "openai")) {
        if (root.get(namespace)) |custom| try applyResponsesNamespace(arena, &result, custom, diag);
    }
    return result;
}

/// Resolves part/message options using the custom namespace first and the
/// canonical `openai` namespace as fallback.
pub fn namespaceObject(
    value: ?provider.ProviderOptions,
    namespace: []const u8,
) ?std.json.ObjectMap {
    const root_value = value orelse return null;
    if (root_value != .object) return null;
    if (root_value.object.get(namespace)) |custom| {
        if (custom == .object) return custom.object;
    }
    if (!std.mem.eql(u8, namespace, "openai")) {
        if (root_value.object.get("openai")) |canonical| {
            if (canonical == .object) return canonical.object;
        }
    }
    return null;
}

fn providerOptionsRoot(
    arena: Allocator,
    value: ?provider.ProviderOptions,
    diag: ?*provider.Diagnostics,
) ParseError!?std.json.ObjectMap {
    const root = value orelse return null;
    return switch (root) {
        .object => |object| object,
        .null => null,
        else => invalid(arena, diag, "providerOptions must be a JSON object"),
    };
}

fn applyChatNamespace(
    arena: Allocator,
    result: *ChatOptions,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) ParseError!void {
    if (value == .null) return;
    if (value != .object) return invalid(arena, diag, "OpenAI provider options namespace must be an object");
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const item = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "logitBias")) {
            if (item == .null) result.logit_bias = null else if (item == .object) result.logit_bias = item else return invalid(arena, diag, "logitBias must be an object");
        } else if (std.mem.eql(u8, name, "logprobs")) {
            result.logprobs = switch (item) {
                .bool => |boolean| .{ .boolean = boolean },
                .integer => |number| if (number >= 0) .{ .count = @intCast(number) } else return invalid(arena, diag, "logprobs must be a boolean or non-negative integer"),
                .null => null,
                else => return invalid(arena, diag, "logprobs must be a boolean or non-negative integer"),
            };
        } else if (std.mem.eql(u8, name, "parallelToolCalls")) {
            result.parallel_tool_calls = try optionalBool(arena, item, diag, "parallelToolCalls");
        } else if (std.mem.eql(u8, name, "user")) {
            result.user = try optionalString(arena, item, diag, "user");
        } else if (std.mem.eql(u8, name, "reasoningEffort")) {
            result.reasoning_effort = try optionalEnumString(arena, item, diag, "reasoningEffort", &.{ "none", "minimal", "low", "medium", "high", "xhigh", "max" });
        } else if (std.mem.eql(u8, name, "maxCompletionTokens")) {
            result.max_completion_tokens = try optionalU64(arena, item, diag, "maxCompletionTokens");
        } else if (std.mem.eql(u8, name, "store")) {
            result.store = try optionalBool(arena, item, diag, "store");
        } else if (std.mem.eql(u8, name, "metadata")) {
            result.metadata = try optionalObject(arena, item, diag, "metadata");
        } else if (std.mem.eql(u8, name, "prediction")) {
            result.prediction = if (item == .null) null else item;
        } else if (std.mem.eql(u8, name, "serviceTier")) {
            result.service_tier = try optionalEnumString(arena, item, diag, "serviceTier", &.{ "auto", "flex", "priority", "default" });
        } else if (std.mem.eql(u8, name, "strictJsonSchema")) {
            result.strict_json_schema = (try optionalBool(arena, item, diag, "strictJsonSchema")) orelse true;
        } else if (std.mem.eql(u8, name, "textVerbosity")) {
            result.text_verbosity = try optionalEnumString(arena, item, diag, "textVerbosity", &.{ "low", "medium", "high" });
        } else if (std.mem.eql(u8, name, "promptCacheKey")) {
            result.prompt_cache_key = try optionalString(arena, item, diag, "promptCacheKey");
        } else if (std.mem.eql(u8, name, "promptCacheOptions")) {
            result.prompt_cache_options = try optionalObject(arena, item, diag, "promptCacheOptions");
        } else if (std.mem.eql(u8, name, "promptCacheRetention")) {
            result.prompt_cache_retention = try optionalEnumString(arena, item, diag, "promptCacheRetention", &.{ "in_memory", "24h" });
        } else if (std.mem.eql(u8, name, "safetyIdentifier")) {
            result.safety_identifier = try optionalString(arena, item, diag, "safetyIdentifier");
        } else if (std.mem.eql(u8, name, "systemMessageMode")) {
            const mode = try optionalEnumString(arena, item, diag, "systemMessageMode", &.{ "system", "developer", "remove" });
            result.system_message_mode = if (mode) |selected|
                if (std.mem.eql(u8, selected, "system")) .system else if (std.mem.eql(u8, selected, "developer")) .developer else .remove
            else
                null;
        } else if (std.mem.eql(u8, name, "forceReasoning")) {
            result.force_reasoning = try optionalBool(arena, item, diag, "forceReasoning");
        }
    }
}

fn applyEmbeddingNamespace(
    arena: Allocator,
    result: *EmbeddingOptions,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) ParseError!void {
    if (value == .null) return;
    if (value != .object) return invalid(arena, diag, "OpenAI provider options namespace must be an object");
    if (value.object.get("dimensions")) |item| result.dimensions = try optionalU64(arena, item, diag, "dimensions");
    if (value.object.get("user")) |item| result.user = try optionalString(arena, item, diag, "user");
    if (value.object.get("encodingFormat")) |item| {
        result.encoding_format = (try optionalEnumString(arena, item, diag, "encodingFormat", &.{ "float", "base64" })) orelse "float";
    }
}

fn applyResponsesNamespace(
    arena: Allocator,
    result: *ResponsesOptions,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) ParseError!void {
    if (value == .null) return;
    if (value != .object) return invalid(arena, diag, "OpenAI provider options namespace must be an object");
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const item = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "conversation")) {
            result.conversation = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "include")) {
            result.include = try parseInclude(arena, item, diag);
        } else if (std.mem.eql(u8, name, "instructions")) {
            result.instructions = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "logprobs")) {
            result.logprobs = switch (item) {
                .bool => |enabled| .{ .boolean = enabled },
                .integer => |count| if (count >= 1 and count <= 20) .{ .count = @intCast(count) } else return invalidField(arena, diag, name, "must be true, false, or an integer from 1 through 20"),
                .null => null,
                else => return invalidField(arena, diag, name, "must be true, false, or an integer from 1 through 20"),
            };
        } else if (std.mem.eql(u8, name, "maxToolCalls")) {
            result.max_tool_calls = try optionalU64(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "metadata")) {
            result.metadata = if (item == .null) null else try provider_utils.cloneJsonValue(arena, item);
        } else if (std.mem.eql(u8, name, "parallelToolCalls")) {
            result.parallel_tool_calls = try optionalBool(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "previousResponseId")) {
            result.previous_response_id = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "promptCacheKey")) {
            result.prompt_cache_key = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "promptCacheOptions")) {
            result.prompt_cache_options = try parsePromptCacheOptions(arena, item, diag);
        } else if (std.mem.eql(u8, name, "promptCacheRetention")) {
            result.prompt_cache_retention = try optionalEnumString(arena, item, diag, name, &.{ "in_memory", "24h" });
        } else if (std.mem.eql(u8, name, "reasoningEffort")) {
            result.reasoning_effort = try optionalEnumString(arena, item, diag, name, &.{ "none", "minimal", "low", "medium", "high", "xhigh", "max" });
        } else if (std.mem.eql(u8, name, "reasoningMode")) {
            result.reasoning_mode = try optionalEnumString(arena, item, diag, name, &.{ "standard", "pro" });
        } else if (std.mem.eql(u8, name, "reasoningContext")) {
            result.reasoning_context = try optionalEnumString(arena, item, diag, name, &.{ "auto", "current_turn", "all_turns" });
        } else if (std.mem.eql(u8, name, "reasoningSummary")) {
            result.reasoning_summary_set = true;
            result.reasoning_summary = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "safetyIdentifier")) {
            result.safety_identifier = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "serviceTier")) {
            result.service_tier = try optionalEnumString(arena, item, diag, name, &.{ "auto", "flex", "priority", "default" });
        } else if (std.mem.eql(u8, name, "store")) {
            result.store = try optionalBool(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "passThroughUnsupportedFiles")) {
            result.pass_through_unsupported_files = (try optionalBool(arena, item, diag, name)) orelse false;
        } else if (std.mem.eql(u8, name, "strictJsonSchema")) {
            result.strict_json_schema = (try optionalBool(arena, item, diag, name)) orelse true;
        } else if (std.mem.eql(u8, name, "textVerbosity")) {
            result.text_verbosity = try optionalEnumString(arena, item, diag, name, &.{ "low", "medium", "high" });
        } else if (std.mem.eql(u8, name, "truncation")) {
            result.truncation = try optionalEnumString(arena, item, diag, name, &.{ "auto", "disabled" });
        } else if (std.mem.eql(u8, name, "user")) {
            result.user = try optionalString(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "systemMessageMode")) {
            const mode = try optionalEnumString(arena, item, diag, name, &.{ "system", "developer", "remove" });
            result.system_message_mode = if (mode) |selected|
                if (std.mem.eql(u8, selected, "system")) .system else if (std.mem.eql(u8, selected, "developer")) .developer else .remove
            else
                null;
        } else if (std.mem.eql(u8, name, "forceReasoning")) {
            result.force_reasoning = try optionalBool(arena, item, diag, name);
        } else if (std.mem.eql(u8, name, "contextManagement")) {
            result.context_management = try parseContextManagement(arena, item, diag);
        } else if (std.mem.eql(u8, name, "allowedTools")) {
            result.allowed_tools = try parseAllowedTools(arena, item, diag);
        }
    }
}

fn parseInclude(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!?[]const []const u8 {
    const values = try optionalStringList(arena, value, diag, "include") orelse return null;
    const allowed = [_][]const u8{
        "reasoning.encrypted_content",
        "file_search_call.results",
        "web_search_call.results",
        "message.output_text.logprobs",
    };
    for (values) |value_item| {
        var supported = false;
        for (allowed) |candidate| if (std.mem.eql(u8, value_item, candidate)) {
            supported = true;
            break;
        };
        if (!supported) return invalidField(arena, diag, "include", "contains an unsupported value");
    }
    return values;
}

fn parsePromptCacheOptions(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!?std.json.Value {
    if (value == .null) return null;
    if (value != .object) return invalidField(arena, diag, "promptCacheOptions", "must be an object");
    var output: std.json.ObjectMap = .empty;
    if (value.object.get("mode")) |mode_value| {
        const mode = try optionalEnumString(arena, mode_value, diag, "promptCacheOptions.mode", &.{ "implicit", "explicit" });
        if (mode) |selected| try output.put(arena, "mode", .{ .string = selected });
    }
    if (value.object.get("ttl")) |ttl_value| {
        const ttl = try optionalString(arena, ttl_value, diag, "promptCacheOptions.ttl");
        if (ttl) |selected| {
            if (!std.mem.eql(u8, selected, "30m")) return invalidField(arena, diag, "promptCacheOptions.ttl", "must be 30m");
            try output.put(arena, "ttl", .{ .string = selected });
        }
    }
    return .{ .object = output };
}

fn optionalStringList(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
    name: []const u8,
) ParseError!?[]const []const u8 {
    if (value == .null) return null;
    if (value != .array) return invalidField(arena, diag, name, "must be an array of strings");
    const result = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, result) |item, *destination| {
        if (item != .string) return invalidField(arena, diag, name, "must be an array of strings");
        destination.* = item.string;
    }
    return result;
}

fn parseContextManagement(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) ParseError!?[]const ContextManagement {
    if (value == .null) return null;
    if (value != .array) return invalidField(arena, diag, "contextManagement", "must be an array");
    const result = try arena.alloc(ContextManagement, value.array.items.len);
    for (value.array.items, result) |item, *destination| {
        if (item != .object) return invalidField(arena, diag, "contextManagement", "entries must be objects");
        const kind = item.object.get("type") orelse return invalidField(arena, diag, "contextManagement", "entries require type");
        if (kind != .string or !std.mem.eql(u8, kind.string, "compaction")) return invalidField(arena, diag, "contextManagement", "only compaction is supported");
        const threshold = item.object.get("compactThreshold") orelse return invalidField(arena, diag, "contextManagement", "entries require compactThreshold");
        destination.* = .{ .compact_threshold = switch (threshold) {
            .integer, .float, .number_string => try provider_utils.cloneJsonValue(arena, threshold),
            else => return invalidField(arena, diag, "contextManagement", "compactThreshold must be a number"),
        } };
    }
    return result;
}

fn parseAllowedTools(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) ParseError!?AllowedTools {
    if (value == .null) return null;
    if (value != .object) return invalidField(arena, diag, "allowedTools", "must be an object");
    const names = value.object.get("toolNames") orelse return invalidField(arena, diag, "allowedTools", "requires toolNames");
    const tool_names = (try optionalStringList(arena, names, diag, "allowedTools.toolNames")) orelse
        return invalidField(arena, diag, "allowedTools", "requires toolNames");
    if (tool_names.len == 0) return invalidField(arena, diag, "allowedTools.toolNames", "must not be empty");
    const mode = if (value.object.get("mode")) |item|
        (try optionalEnumString(arena, item, diag, "allowedTools.mode", &.{ "auto", "required" })) orelse "auto"
    else
        "auto";
    return .{ .tool_names = tool_names, .mode = mode };
}

fn optionalString(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics, name: []const u8) ParseError!?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => invalidField(arena, diag, name, "must be a string"),
    };
}

fn optionalBool(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics, name: []const u8) ParseError!?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        .null => null,
        else => invalidField(arena, diag, name, "must be a boolean"),
    };
}

fn optionalU64(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics, name: []const u8) ParseError!?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else invalidField(arena, diag, name, "must be a non-negative integer"),
        .null => null,
        else => invalidField(arena, diag, name, "must be a non-negative integer"),
    };
}

fn optionalObject(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics, name: []const u8) ParseError!?std.json.Value {
    return switch (value) {
        .object => value,
        .null => null,
        else => invalidField(arena, diag, name, "must be an object"),
    };
}

fn optionalEnumString(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
    name: []const u8,
    allowed: []const []const u8,
) ParseError!?[]const u8 {
    const text = try optionalString(arena, value, diag, name) orelse return null;
    for (allowed) |candidate| if (std.mem.eql(u8, text, candidate)) return text;
    return invalidField(arena, diag, name, "has an unsupported value");
}

fn invalidField(arena: Allocator, diag: ?*provider.Diagnostics, name: []const u8, suffix: []const u8) ParseError {
    const text = try std.fmt.allocPrint(arena, "{s} {s}", .{ name, suffix });
    return invalid(arena, diag, text);
}

fn invalid(arena: Allocator, diag: ?*provider.Diagnostics, text: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .type_validation = .{ .message = text },
    });
    return error.TypeValidationError;
}
