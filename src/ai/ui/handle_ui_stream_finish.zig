//! Response-message ID injection and persistence callbacks.

const std = @import("std");
const provider = @import("provider");
const chunks = @import("ui_chunks.zig");
const messages = @import("ui_messages.zig");
const process = @import("process_ui_stream.zig");
const stream_api = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;

pub const OnStepEndOptions = struct {
    is_continuation: bool,
    response_message: messages.UIMessage,
    messages: []const messages.UIMessage,
};

pub const OnStepEnd = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, io: std.Io, options: OnStepEndOptions) anyerror!void,

    pub fn call(self: OnStepEnd, io: std.Io, options: OnStepEndOptions) anyerror!void {
        return self.call_fn(self.ctx, io, options);
    }
};

pub const OnEndOptions = struct {
    is_aborted: bool,
    is_continuation: bool,
    response_message: messages.UIMessage,
    messages: []const messages.UIMessage,
    finish_reason: ?provider.FinishReasonUnified,
};

pub const OnEnd = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, io: std.Io, options: OnEndOptions) anyerror!void,

    pub fn call(self: OnEnd, io: std.Io, options: OnEndOptions) anyerror!void {
        return self.call_fn(self.ctx, io, options);
    }
};

pub const Options = struct {
    message_id: ?[]const u8 = null,
    original_messages: ?[]const messages.UIMessage = null,
    on_step_end: ?OnStepEnd = null,
    on_end: ?OnEnd = null,
    on_error: ?process.OnError = null,
    diag: ?*provider.Diagnostics = null,
};

pub fn getResponseUIMessageId(
    original_messages: ?[]const messages.UIMessage,
    generated_id: []const u8,
) ?[]const u8 {
    const original = original_messages orelse return null;
    if (original.len != 0 and original[original.len - 1].role == .assistant) {
        return original[original.len - 1].id;
    }
    return generated_id;
}

pub fn handleUIMessageStreamFinish(
    gpa: Allocator,
    input: stream_api.ChunkStream,
    options: Options,
) !stream_api.ChunkStream {
    const self = try gpa.create(FinishStream);
    self.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .input = input,
        .options = options,
    };
    errdefer {
        self.arena_state.deinit();
        gpa.destroy(self);
    }
    const arena = self.arena_state.allocator();
    self.original_messages = if (options.original_messages) |original|
        try messages.cloneMessages(arena, original)
    else
        &.{};

    var last_assistant: ?messages.UIMessage = null;
    if (self.original_messages.len != 0) {
        const last = self.original_messages[self.original_messages.len - 1];
        if (last.role == .assistant) last_assistant = last;
    }
    self.last_assistant_id = if (last_assistant) |last| last.id else null;
    self.effective_message_id = if (last_assistant) |last|
        last.id
    else if (options.message_id) |id|
        try arena.dupe(u8, id)
    else
        null;

    if (options.on_step_end != null or options.on_end != null) {
        self.state = try process.StreamingState.init(
            arena,
            last_assistant,
            self.effective_message_id orelse "",
        );
    }
    return .{ .ctx = self, .vtable = &FinishStream.vtable };
}

const FinishStream = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    input: stream_api.ChunkStream,
    options: Options,
    original_messages: []const messages.UIMessage = &.{},
    last_assistant_id: ?[]const u8 = null,
    effective_message_id: ?[]const u8 = null,
    state: ?process.StreamingState = null,
    is_aborted: bool = false,
    finish_called: bool = false,
    deinitialized: bool = false,

    const vtable: stream_api.ChunkStream.VTable = .{
        .next = next,
        .deinit = deinit,
        .cancel = cancel,
    };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *FinishStream = @ptrCast(@alignCast(raw));
        var chunk = (try self.input.next(io)) orelse {
            try self.callOnEnd(io);
            return null;
        };
        switch (chunk) {
            .start => |*start| if (start.message_id == null) {
                start.message_id = self.effective_message_id;
            },
            .abort => self.is_aborted = true,
            else => {},
        }

        if (self.state) |*state| {
            try process.applyChunk(io, self.arena_state.allocator(), state, chunk, .{
                .on_error = self.options.on_error,
                .diag = self.options.diag,
            });
            if (chunk == .finish_step) try self.callOnStepEnd(io);
        }
        return chunk;
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *FinishStream = @ptrCast(@alignCast(raw));
        self.input.cancel(io);
        self.callOnEnd(io) catch |err| self.reportError(err);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *FinishStream = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.callOnEnd(io) catch |err| self.reportError(err);
        self.input.deinit(io);
        if (self.state) |*state| state.deinit(self.arena_state.allocator());
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn callOnStepEnd(self: *FinishStream, io: std.Io) !void {
        const callback = self.options.on_step_end orelse return;
        const state = &(self.state orelse return);
        const response = try messages.cloneMessage(self.arena_state.allocator(), state.message);
        const is_continuation = self.isContinuation(response);
        const combined = try self.combinedMessages(response, is_continuation);
        callback.call(io, .{
            .is_continuation = is_continuation,
            .response_message = response,
            .messages = combined,
        }) catch |err| {
            self.reportError(err);
        };
    }

    fn callOnEnd(self: *FinishStream, io: std.Io) !void {
        if (self.finish_called) return;
        self.finish_called = true;
        const callback = self.options.on_end orelse return;
        const state = &(self.state orelse return);
        const response = try messages.cloneMessage(self.arena_state.allocator(), state.message);
        const is_continuation = self.isContinuation(response);
        try callback.call(io, .{
            .is_aborted = self.is_aborted,
            .is_continuation = is_continuation,
            .response_message = response,
            .messages = try self.combinedMessages(response, is_continuation),
            .finish_reason = state.finish_reason,
        });
    }

    fn combinedMessages(
        self: *FinishStream,
        response: messages.UIMessage,
        is_continuation: bool,
    ) ![]const messages.UIMessage {
        const prefix = if (is_continuation and self.original_messages.len != 0)
            self.original_messages[0 .. self.original_messages.len - 1]
        else
            self.original_messages;
        const combined = try self.arena_state.allocator().alloc(messages.UIMessage, prefix.len + 1);
        @memcpy(combined[0..prefix.len], prefix);
        combined[prefix.len] = response;
        return combined;
    }

    fn isContinuation(self: *FinishStream, response: messages.UIMessage) bool {
        const original_id = self.last_assistant_id orelse return false;
        return std.mem.eql(u8, original_id, response.id);
    }

    fn reportError(self: *FinishStream, err: anyerror) void {
        if (self.options.on_error) |handler| handler.call(@errorName(err));
    }
};

test "handleUIMessageStreamFinish injects ids and aggregates abort/end state" {
    const input_chunks = [_]chunks.UIMessageChunk{
        .{ .start = .{} },
        .{ .start_step = .{} },
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "hello" } },
        .{ .text_end = .{ .id = "t" } },
        .{ .finish_step = .{} },
        .{ .abort = .{ .reason = "client" } },
        .{ .finish = .{ .finish_reason = .stop } },
    };
    var source_state: stream_api.SliceStream = .{ .values = &input_chunks };

    const Capture = struct {
        called: usize = 0,
        aborted: bool = false,
        text: []const u8 = "",

        fn onEnd(raw: ?*anyopaque, _: std.Io, options: OnEndOptions) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.called += 1;
            self.aborted = options.is_aborted;
            self.text = options.response_message.parts[1].text.text;
        }
    };
    var capture: Capture = .{};
    const stream = try handleUIMessageStreamFinish(std.testing.allocator, source_state.stream(), .{
        .message_id = "server-id",
        .original_messages = &.{.{
            .id = "u",
            .role = .user,
            .parts = &.{.{ .text = .{ .text = "hi" } }},
        }},
        .on_end = .{ .ctx = &capture, .call_fn = Capture.onEnd },
    });
    defer stream.deinit(std.testing.io);

    const start = (try stream.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("server-id", start.start.message_id.?);
    while (try stream.next(std.testing.io)) |_| {}
    try std.testing.expectEqual(1, capture.called);
    try std.testing.expect(capture.aborted);
    try std.testing.expectEqualStrings("hello", capture.text);
}
