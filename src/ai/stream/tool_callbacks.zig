//! Stage 2: inline tool-input callback delivery.

const std = @import("std");
const message = @import("../message.zig");
const tool_api = @import("../tool.zig");
const tool_common = @import("../tool_execution_common.zig");
const part_stream = @import("part_stream.zig");
const parts = @import("parts.zig");

pub const Options = struct {
    upstream: part_stream.PartStream(parts.LanguageModelStreamPart),
    tools: tool_api.ToolSet = &.{},
    messages: []const message.ModelMessage = &.{},
    runtime_context: ?std.json.Value = null,
};

/// Returns an owning passthrough stage. Callback completion pauses the pull;
/// callback failures are swallowed, matching upstream `notify` semantics.
pub fn invokeToolCallbacksFromStream(
    arena: std.mem.Allocator,
    options: Options,
) std.mem.Allocator.Error!part_stream.PartStream(parts.LanguageModelStreamPart) {
    if (options.tools.len == 0) return options.upstream;
    const state = try arena.create(State);
    state.* = .{
        .arena = arena,
        .upstream = options.upstream,
        .tools = options.tools,
        .messages = options.messages,
        .runtime_context = options.runtime_context,
    };
    return .{ .ctx = state, .vtable = &State.vtable };
}

const State = struct {
    arena: std.mem.Allocator,
    upstream: part_stream.PartStream(parts.LanguageModelStreamPart),
    tools: tool_api.ToolSet,
    messages: []const message.ModelMessage,
    runtime_context: ?std.json.Value,
    names_by_id: std.StringHashMapUnmanaged([]const u8) = .empty,
    deinitialized: bool = false,

    const vtable: part_stream.PartStream(parts.LanguageModelStreamPart).VTable = .{
        .next = next,
        .deinit = deinit,
    };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?parts.LanguageModelStreamPart {
        const self: *State = @ptrCast(@alignCast(raw));
        const part = (try self.upstream.next(io)) orelse return null;
        switch (part) {
            .tool_input_start => |value| {
                try self.names_by_id.put(self.arena, value.id, value.tool_name);
                const named = tool_common.findTool(self.tools, value.tool_name) orelse return part;
                if (named.tool.on_input_start) |callback| callback.callback(callback.ctx, .{
                    .tool_call_id = value.id,
                    .messages = self.messages,
                    .context = self.runtime_context,
                }) catch {};
            },
            .tool_input_delta => |value| {
                const name = self.names_by_id.get(value.id) orelse return part;
                const named = tool_common.findTool(self.tools, name) orelse return part;
                if (named.tool.on_input_delta) |callback| callback.callback(callback.ctx, value.delta, .{
                    .tool_call_id = value.id,
                    .messages = self.messages,
                    .context = self.runtime_context,
                }) catch {};
            },
            .tool_call => |value| {
                const name = self.names_by_id.get(value.tool_call_id) orelse return part;
                _ = self.names_by_id.remove(value.tool_call_id);
                const named = tool_common.findTool(self.tools, name) orelse return part;
                if (named.tool.on_input_available) |callback| callback.callback(callback.ctx, value.input, .{
                    .tool_call_id = value.tool_call_id,
                    .messages = self.messages,
                    .context = self.runtime_context,
                }) catch {};
            },
            else => {},
        }
        return part;
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.upstream.deinit(io);
    }
};

test "tool callback stage fires in order and passes every part through" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Input = struct {
        parts_list: []const parts.LanguageModelStreamPart,
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?parts.LanguageModelStreamPart {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == self.parts_list.len) return null;
            defer self.index += 1;
            return self.parts_list[self.index];
        }
    };
    const Recorder = struct {
        order: [4]u8 = undefined,
        len: usize = 0,
        fn push(self: *@This(), value: u8) void {
            self.order[self.len] = value;
            self.len += 1;
        }
        fn start(raw: ?*anyopaque, _: tool_api.ToolExecutionOptions) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.push(1);
        }
        fn delta(raw: ?*anyopaque, text: []const u8, _: tool_api.ToolExecutionOptions) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.push(if (text[0] == 'a') 2 else 3);
        }
        fn available(raw: ?*anyopaque, _: std.json.Value, _: tool_api.ToolExecutionOptions) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.push(4);
        }
    };

    const input_parts = [_]parts.LanguageModelStreamPart{
        .{ .text_delta = .{ .id = "t", .text = "hello" } },
        .{ .tool_input_start = .{ .id = "c", .tool_name = "weather" } },
        .{ .tool_input_delta = .{ .id = "c", .delta = "a" } },
        .{ .tool_input_delta = .{ .id = "c", .delta = "b" } },
        .{ .tool_call = .{ .tool_call_id = "c", .tool_name = "weather", .input = .null } },
    };
    var input: Input = .{ .parts_list = &input_parts };
    var recorder: Recorder = .{};
    const tools = [_]tool_api.NamedTool{.{ .name = "weather", .tool = .{
        .input_schema = @import("provider_utils").rawSchema("{}", null),
        .on_input_start = .{ .ctx = &recorder, .callback = Recorder.start },
        .on_input_delta = .{ .ctx = &recorder, .callback = Recorder.delta },
        .on_input_available = .{ .ctx = &recorder, .callback = Recorder.available },
    } }};
    const upstream: part_stream.PartStream(parts.LanguageModelStreamPart) = .{
        .ctx = &input,
        .vtable = &.{ .next = Input.next },
    };
    const stage = try invokeToolCallbacksFromStream(arena, .{ .upstream = upstream, .tools = &tools });
    defer stage.deinit(std.testing.io);

    var count: usize = 0;
    while (try stage.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(input_parts.len, count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, recorder.order[0..recorder.len]);
}
