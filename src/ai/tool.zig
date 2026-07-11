//! Runtime-shaped tool definitions used by the Phase 4 text loop.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const message = @import("message.zig");

pub const ToolKind = enum {
    function,
    dynamic,
    provider_defined,
    provider_executed,
};

pub const ToolExecutionOptions = struct {
    tool_call_id: []const u8,
    messages: []const message.ModelMessage,
    context: ?std.json.Value = null,
};

/// Pull replacement for an AsyncIterable tool result. Every non-final item is
/// preliminary; the last yielded value is the final tool output.
pub const PreliminaryStream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ctx: *anyopaque, io: std.Io) anyerror!?std.json.Value,
        deinit: ?*const fn (ctx: *anyopaque, io: std.Io) void = null,
    };

    pub fn next(self: PreliminaryStream, io: std.Io) anyerror!?std.json.Value {
        return self.vtable.next(self.ctx, io);
    }

    pub fn deinit(self: PreliminaryStream, io: std.Io) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ctx, io);
    }
};

pub const ToolOutput = union(enum) {
    value: std.json.Value,
    stream: PreliminaryStream,
};

pub const ToolExecute = struct {
    ctx: ?*anyopaque = null,
    execute_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        options: ToolExecutionOptions,
    ) anyerror!ToolOutput,

    pub fn execute(
        self: ToolExecute,
        io: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        options: ToolExecutionOptions,
    ) anyerror!ToolOutput {
        return self.execute_fn(self.ctx, io, arena, input, options);
    }
};

pub const DescriptionResolver = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (
        ctx: ?*anyopaque,
        tool_context: ?std.json.Value,
    ) anyerror![]const u8,

    pub fn resolve(self: DescriptionResolver, tool_context: ?std.json.Value) anyerror![]const u8 {
        return self.resolve_fn(self.ctx, tool_context);
    }
};

pub const Description = union(enum) {
    text: []const u8,
    resolver: DescriptionResolver,
};

pub const ApprovalResolver = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (
        ctx: ?*anyopaque,
        input: std.json.Value,
        options: ToolExecutionOptions,
    ) anyerror!bool,

    pub fn resolve(
        self: ApprovalResolver,
        input: std.json.Value,
        options: ToolExecutionOptions,
    ) anyerror!bool {
        return self.resolve_fn(self.ctx, input, options);
    }
};

pub const NeedsApproval = union(enum) {
    no,
    yes,
    resolver: ApprovalResolver,
};

pub const InputStartCallback = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (ctx: ?*anyopaque, options: ToolExecutionOptions) anyerror!void,
};

pub const InputDeltaCallback = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (
        ctx: ?*anyopaque,
        input_text_delta: []const u8,
        options: ToolExecutionOptions,
    ) anyerror!void,
};

pub const InputAvailableCallback = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (
        ctx: ?*anyopaque,
        input: std.json.Value,
        options: ToolExecutionOptions,
    ) anyerror!void,
};

pub const ToModelOutput = struct {
    ctx: ?*anyopaque = null,
    convert_fn: *const fn (
        ctx: ?*anyopaque,
        arena: std.mem.Allocator,
        tool_call_id: []const u8,
        input: std.json.Value,
        output: std.json.Value,
    ) anyerror!message.ToolResultOutput,

    pub fn convert(
        self: ToModelOutput,
        arena: std.mem.Allocator,
        tool_call_id: []const u8,
        input: std.json.Value,
        output: std.json.Value,
    ) anyerror!message.ToolResultOutput {
        return self.convert_fn(self.ctx, arena, tool_call_id, input, output);
    }
};

pub const InputExample = struct { input: std.json.Value };

pub const Tool = struct {
    kind: ToolKind = .function,
    name: ?[]const u8 = null,
    description: ?Description = null,
    input_schema: provider_utils.Schema,
    output_schema: ?provider_utils.Schema = null,
    execute: ?ToolExecute = null,
    needs_approval: NeedsApproval = .no,
    on_input_start: ?InputStartCallback = null,
    on_input_delta: ?InputDeltaCallback = null,
    on_input_available: ?InputAvailableCallback = null,
    to_model_output: ?ToModelOutput = null,
    metadata: ?std.json.Value = null,
    provider_options: ?provider.ProviderOptions = null,
    strict: ?bool = null,
    input_examples: ?[]const InputExample = null,

    // Provider-defined/provider-executed fields.
    provider_id: ?[]const u8 = null,
    provider_args: ?std.json.Value = null,
    supports_deferred_results: bool = false,
};

pub const NamedTool = struct {
    name: []const u8,
    tool: Tool,
};

/// Runtime ToolSet path. Comptime struct-of-tools sugar belongs with the
/// generic generateText surface in Phase 4b.
pub const ToolSet = []const NamedTool;

test "PreliminaryStream preserves pull order" {
    const State = struct {
        index: usize = 0,

        fn next(raw: *anyopaque, _: std.Io) anyerror!?std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .integer = 1 },
                1 => .{ .integer = 2 },
                else => null,
            };
        }
    };

    var state: State = .{};
    const stream: PreliminaryStream = .{
        .ctx = &state,
        .vtable = &.{ .next = State.next },
    };
    try std.testing.expectEqual(1, (try stream.next(std.testing.io)).?.integer);
    try std.testing.expectEqual(2, (try stream.next(std.testing.io)).?.integer);
    try std.testing.expectEqual(null, try stream.next(std.testing.io));
}
