//! Provides the stable C ABI over ai.zig packages.

const std = @import("std");

test "module declarations" {
    std.testing.refAllDecls(@This());
}
