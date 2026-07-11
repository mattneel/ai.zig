const std = @import("std");

pub const SystemMessageMode = enum { remove, system, developer };

pub const LanguageModelCapabilities = struct {
    is_reasoning_model: bool,
    system_message_mode: SystemMessageMode,
    supports_flex_processing: bool,
    supports_priority_processing: bool,
    supports_non_reasoning_parameters: bool,
};

pub fn getLanguageModelCapabilities(model_id: []const u8) LanguageModelCapabilities {
    const is_gpt5_reasoning = std.mem.startsWith(u8, model_id, "gpt-5") and
        !std.mem.startsWith(u8, model_id, "gpt-5-chat");
    const is_reasoning_model = std.mem.startsWith(u8, model_id, "o1") or
        std.mem.startsWith(u8, model_id, "o3") or
        std.mem.startsWith(u8, model_id, "o4-mini") or
        is_gpt5_reasoning;

    const supports_flex_processing = std.mem.startsWith(u8, model_id, "o3") or
        std.mem.startsWith(u8, model_id, "o4-mini") or
        is_gpt5_reasoning;

    const supports_priority_processing = std.mem.startsWith(u8, model_id, "gpt-4") or
        (std.mem.startsWith(u8, model_id, "gpt-5") and
            !std.mem.startsWith(u8, model_id, "gpt-5-nano") and
            !std.mem.startsWith(u8, model_id, "gpt-5-chat") and
            !std.mem.startsWith(u8, model_id, "gpt-5.4-nano")) or
        std.mem.startsWith(u8, model_id, "o3") or
        std.mem.startsWith(u8, model_id, "o4-mini");

    const supports_non_reasoning_parameters =
        std.mem.startsWith(u8, model_id, "gpt-5.1") or
        std.mem.startsWith(u8, model_id, "gpt-5.2") or
        std.mem.startsWith(u8, model_id, "gpt-5.3") or
        std.mem.startsWith(u8, model_id, "gpt-5.4") or
        std.mem.startsWith(u8, model_id, "gpt-5.5") or
        std.mem.startsWith(u8, model_id, "gpt-5.6");

    return .{
        .is_reasoning_model = is_reasoning_model,
        .system_message_mode = if (is_reasoning_model) .developer else .system,
        .supports_flex_processing = supports_flex_processing,
        .supports_priority_processing = supports_priority_processing,
        .supports_non_reasoning_parameters = supports_non_reasoning_parameters,
    };
}

test "OpenAI capability table matches reasoning family allowlist" {
    const Case = struct { id: []const u8, expected: bool };
    const cases = [_]Case{
        .{ .id = "gpt-4.1", .expected = false },
        .{ .id = "gpt-4o-mini", .expected = false },
        .{ .id = "gpt-5-chat-latest", .expected = false },
        .{ .id = "o1", .expected = true },
        .{ .id = "o3-mini-2025-01-31", .expected = true },
        .{ .id = "o4-mini", .expected = true },
        .{ .id = "gpt-5", .expected = true },
        .{ .id = "gpt-5.4-nano", .expected = true },
        .{ .id = "custom-model", .expected = false },
        .{ .id = "ft:gpt-4o-2024-08-06:org:custom", .expected = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, getLanguageModelCapabilities(case.id).is_reasoning_model);
    }
}

test "OpenAI capability table preserves processing and GPT-5.1+ parameter rules" {
    try std.testing.expect(getLanguageModelCapabilities("o4-mini").supports_flex_processing);
    try std.testing.expect(!getLanguageModelCapabilities("gpt-4o").supports_flex_processing);
    try std.testing.expect(getLanguageModelCapabilities("gpt-4o").supports_priority_processing);
    try std.testing.expect(!getLanguageModelCapabilities("gpt-5-nano").supports_priority_processing);
    try std.testing.expect(!getLanguageModelCapabilities("gpt-5.4-nano").supports_priority_processing);
    try std.testing.expect(!getLanguageModelCapabilities("gpt-5").supports_non_reasoning_parameters);
    try std.testing.expect(getLanguageModelCapabilities("gpt-5.1-codex").supports_non_reasoning_parameters);
    try std.testing.expect(getLanguageModelCapabilities("gpt-5.6-terra").supports_non_reasoning_parameters);
}
