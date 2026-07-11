//! Provides the stable C ABI over ai.zig packages.

const std = @import("std");

pub const types = @import("types.zig");
pub const runtime = @import("runtime.zig");
pub const providers = @import("providers.zig");
pub const options = @import("options.zig");
pub const wire_json = @import("wire_json.zig");
pub const result = @import("result.zig");
pub const stream = @import("stream.zig");

comptime {
    _ = runtime;
    _ = providers;
    _ = options;
    _ = wire_json;
    _ = result;
    _ = stream;
}

test "module declarations" {
    std.testing.refAllDecls(@This());
    _ = @import("abi_lock_test.zig");
    _ = @import("ffi_integration_test.zig");
}
