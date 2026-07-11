//! Public pull-stream transform interface used by `streamText`.

const std = @import("std");
const tool_api = @import("../tool.zig");
const part_stream = @import("part_stream.zig");
const parts = @import("parts.zig");

pub const StopStreamFn = struct {
    ctx: *anyopaque,
    call_fn: *const fn (ctx: *anyopaque, io: std.Io) void,

    pub fn call(self: StopStreamFn, io: std.Io) void {
        self.call_fn(self.ctx, io);
    }
};

pub const TransformOptions = struct {
    tools: tool_api.ToolSet,
    stop_stream: StopStreamFn,
};

/// Factory fat pointer. The returned stage owns `upstream`; callback/config
/// storage referenced by `ctx` must remain valid until `StreamTextResult`
/// deinitialization.
pub const StreamTransform = struct {
    ctx: ?*anyopaque = null,
    wrap_fn: *const fn (
        ctx: ?*anyopaque,
        arena: std.mem.Allocator,
        upstream: part_stream.PartStream(parts.TextStreamPart),
        options: TransformOptions,
    ) anyerror!part_stream.PartStream(parts.TextStreamPart),

    pub fn wrap(
        self: StreamTransform,
        arena: std.mem.Allocator,
        upstream: part_stream.PartStream(parts.TextStreamPart),
        options: TransformOptions,
    ) anyerror!part_stream.PartStream(parts.TextStreamPart) {
        return self.wrap_fn(self.ctx, arena, upstream, options);
    }
};
