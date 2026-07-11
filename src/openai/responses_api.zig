//! Tolerant OpenAI Responses wire helpers.
//!
//! The upstream schemas are deliberately partial and coerce unrecognized
//! event types to an ignorable variant. This Zig port parses each SSE payload
//! as `std.json.Value`, dispatches only the fields it needs, and therefore has
//! the same forward-compatible unknown-event behavior.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub fn convertUsage(arena: Allocator, value: ?std.json.Value) Allocator.Error!provider.Usage {
    const usage = value orelse return .{ .input_tokens = .{}, .output_tokens = .{} };
    if (usage != .object) return .{ .input_tokens = .{}, .output_tokens = .{} };
    const input_tokens = optionalU64(usage.object.get("input_tokens")) orelse 0;
    const output_tokens = optionalU64(usage.object.get("output_tokens")) orelse 0;
    const cached_tokens = nestedU64(usage.object, "input_tokens_details", "cached_tokens") orelse 0;
    const cache_write_tokens = nestedU64(usage.object, "input_tokens_details", "cache_write_tokens");
    const reasoning_tokens = nestedU64(usage.object, "output_tokens_details", "reasoning_tokens") orelse 0;
    return .{
        .input_tokens = .{
            .total = input_tokens,
            .no_cache = input_tokens -| cached_tokens -| (cache_write_tokens orelse 0),
            .cache_read = cached_tokens,
            .cache_write = cache_write_tokens,
        },
        .output_tokens = .{
            .total = output_tokens,
            .text = output_tokens -| reasoning_tokens,
            .reasoning = reasoning_tokens,
        },
        .raw = try provider_utils.cloneJsonValue(arena, usage),
    };
}

pub fn mapFinishReason(value: ?[]const u8, has_function_call: bool) provider.FinishReasonUnified {
    const reason = value orelse return if (has_function_call) .tool_calls else .stop;
    if (std.mem.eql(u8, reason, "max_output_tokens")) return .length;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    return if (has_function_call) .tool_calls else .other;
}

pub fn isChatCompletionShape(value: std.json.Value) bool {
    if (value != .object or value.object.get("type") != null) return false;
    const choices = value.object.get("choices") orelse return false;
    return choices == .array;
}

pub fn eventType(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    return optionalString(value.object, "type");
}

/// JSON.stringify(delta).slice(1, -1), byte-for-byte. The returned slice is
/// backed by the surrounding allocated JSON string and remains valid for the
/// request/stream arena lifetime.
pub fn escapeJsonDelta(arena: Allocator, delta: []const u8) Allocator.Error![]const u8 {
    const encoded = try provider_utils.stringifyJsonValueAlloc(arena, .{ .string = delta });
    std.debug.assert(encoded.len >= 2 and encoded[0] == '"' and encoded[encoded.len - 1] == '"');
    return encoded[1 .. encoded.len - 1];
}

pub fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn objectField(object: std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    const value = object.get(field) orelse return null;
    return if (value == .object) value.object else null;
}

pub fn arrayField(object: std.json.ObjectMap, field: []const u8) ?std.json.Array {
    const value = object.get(field) orelse return null;
    return if (value == .array) value.array else null;
}

pub fn optionalIndex(value: ?std.json.Value) ?usize {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

pub fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        else => null,
    };
}

pub fn timestampMillis(value: ?std.json.Value) ?i64 {
    const seconds = value orelse return null;
    const number: f64 = switch (seconds) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return null,
    };
    const milliseconds = number * 1000;
    if (!std.math.isFinite(milliseconds) or milliseconds > @as(f64, @floatFromInt(std.math.maxInt(i64))) or milliseconds < @as(f64, @floatFromInt(std.math.minInt(i64)))) return null;
    return @intFromFloat(milliseconds);
}

fn nestedU64(object: std.json.ObjectMap, outer: []const u8, inner: []const u8) ?u64 {
    const nested = objectField(object, outer) orelse return null;
    return optionalU64(nested.get(inner));
}

test "Responses usage includes cached, cache-write, reasoning, and raw details" {
    // Fixture shape ported from convert-openai-responses-usage.ts tests in
    // openai-responses-language-model.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":40,\"cache_write_tokens\":25},\"output_tokens\":20,\"output_tokens_details\":{\"reasoning_tokens\":5}}", .{});
    const usage = try convertUsage(arena, value);
    try std.testing.expectEqual(100, usage.input_tokens.total.?);
    try std.testing.expectEqual(35, usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(40, usage.input_tokens.cache_read.?);
    try std.testing.expectEqual(25, usage.input_tokens.cache_write.?);
    try std.testing.expectEqual(15, usage.output_tokens.text.?);
    try std.testing.expectEqual(5, usage.output_tokens.reasoning.?);
}

test "Responses synthetic JSON delta escaping matches JSON.stringify slicing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const escaped = try escapeJsonDelta(arena_state.allocator(), "line 1\n\"quoted\"\\tail");
    try std.testing.expectEqualStrings("line 1\\n\\\"quoted\\\"\\\\tail", escaped);
}
