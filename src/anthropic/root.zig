//! Mirrors `@ai-sdk/anthropic`.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
