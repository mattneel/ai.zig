//! Mirrors the `@ai-sdk/provider-utils` shared provider plumbing package.

const std = @import("std");

pub const one_shot = @import("one_shot.zig");
pub const OneShot = one_shot.OneShot;
pub const notify_api = @import("notify.zig");
pub const Callback = notify_api.Callback;
pub const notify = notify_api.notify;
pub const id = @import("id.zig");
pub const IdGenerator = id.IdGenerator;

comptime {
    _ = one_shot.OneShot;
    _ = notify_api.notify;
    _ = id.IdGenerator;
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
