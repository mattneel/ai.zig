//! Mirrors the Vercel AI SDK `ai` core package.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
