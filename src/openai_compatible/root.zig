//! Mirrors `@ai-sdk/openai-compatible`.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
