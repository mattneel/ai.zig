//! Mirrors the `@ai-sdk/provider@4.0.3` V4 provider specification.

const std = @import("std");

pub const errors = @import("errors.zig");
pub const Error = errors.Error;
pub const Diagnostics = errors.Diagnostics;
pub const Payload = errors.Payload;
pub const Header = errors.Header;
pub const ModelType = errors.ModelType;
pub const RetryReason = errors.RetryReason;
pub const FinishReason = errors.FinishReason;
pub const TypeValidationContext = errors.TypeValidationContext;
pub const isRetryableStatus = errors.isRetryableStatus;

comptime {
    _ = errors.Error;
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
