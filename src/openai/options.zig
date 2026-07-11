const std = @import("std");
const provider = @import("provider");
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
