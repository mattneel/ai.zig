const std = @import("std");

pub const ModelCapabilities = struct {
    max_output_tokens: u64,
    supports_structured_output: bool,
    supports_adaptive_thinking: bool,
    rejects_sampling_parameters: bool,
    supports_xhigh_effort: bool,
    is_known_model: bool,
};

pub fn getModelCapabilities(model_id: []const u8) ModelCapabilities {
    if (containsAny(model_id, &.{
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-fable-5",
        "claude-sonnet-5",
    })) return .{
        .max_output_tokens = 128_000,
        .supports_structured_output = true,
        .supports_adaptive_thinking = true,
        .rejects_sampling_parameters = true,
        .supports_xhigh_effort = true,
        .is_known_model = true,
    };
    if (containsAny(model_id, &.{ "claude-sonnet-4-6", "claude-opus-4-6" })) return .{
        .max_output_tokens = 128_000,
        .supports_structured_output = true,
        .supports_adaptive_thinking = true,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = true,
    };
    if (containsAny(model_id, &.{
        "claude-sonnet-4-5",
        "claude-opus-4-5",
        "claude-haiku-4-5",
    })) return .{
        .max_output_tokens = 64_000,
        .supports_structured_output = true,
        .supports_adaptive_thinking = false,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = true,
    };
    if (std.mem.indexOf(u8, model_id, "claude-opus-4-1") != null) return .{
        .max_output_tokens = 32_000,
        .supports_structured_output = true,
        .supports_adaptive_thinking = false,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = true,
    };
    if (std.mem.indexOf(u8, model_id, "claude-sonnet-4-") != null) return .{
        .max_output_tokens = 64_000,
        .supports_structured_output = false,
        .supports_adaptive_thinking = false,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = true,
    };
    if (std.mem.indexOf(u8, model_id, "claude-opus-4-") != null) return .{
        .max_output_tokens = 32_000,
        .supports_structured_output = false,
        .supports_adaptive_thinking = false,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = true,
    };
    if (std.mem.indexOf(u8, model_id, "claude-3-haiku") != null) return .{
        .max_output_tokens = 4_096,
        .supports_structured_output = false,
        .supports_adaptive_thinking = false,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = true,
    };
    return .{
        .max_output_tokens = 4_096,
        .supports_structured_output = false,
        .supports_adaptive_thinking = false,
        .rejects_sampling_parameters = false,
        .supports_xhigh_effort = false,
        .is_known_model = false,
    };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

test "Anthropic capability table preserves upstream family precedence" {
    const newest = getModelCapabilities("prefix-claude-opus-4-8-suffix");
    try std.testing.expectEqual(128_000, newest.max_output_tokens);
    try std.testing.expect(newest.supports_adaptive_thinking);
    try std.testing.expect(newest.rejects_sampling_parameters);
    try std.testing.expect(newest.supports_xhigh_effort);

    const sonnet = getModelCapabilities("claude-sonnet-4-5-20250929");
    try std.testing.expectEqual(64_000, sonnet.max_output_tokens);
    try std.testing.expect(sonnet.supports_structured_output);
    try std.testing.expect(!sonnet.supports_adaptive_thinking);

    const haiku = getModelCapabilities("claude-3-haiku-20240307");
    try std.testing.expectEqual(4_096, haiku.max_output_tokens);
    try std.testing.expect(haiku.is_known_model);

    const unknown = getModelCapabilities("third-party-anthropic-wire-model");
    try std.testing.expectEqual(4_096, unknown.max_output_tokens);
    try std.testing.expect(!unknown.is_known_model);
}
