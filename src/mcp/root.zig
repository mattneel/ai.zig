//! Mirrors the Vercel AI SDK `@ai-sdk/mcp` package.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
