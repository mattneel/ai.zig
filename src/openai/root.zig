//! Mirrors `@ai-sdk/openai`.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
