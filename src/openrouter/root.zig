//! Mirrors `@openrouter/ai-sdk-provider` as ai.zig's default gateway provider.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
