//! Framework-agnostic Chat state machine.
//!
//! Reactive wrappers provide a ChatState vtable. This keeps ownership and
//! notifications host-defined and maps cleanly to opaque FFI handles.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const chunks = @import("ui_chunks.zig");
const messages = @import("ui_messages.zig");
const process = @import("process_ui_stream.zig");
const stream_api = @import("chunk_stream.zig");
const transports = @import("transports.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const Status = enum { submitted, streaming, ready, @"error" };

pub const ErrorInfo = struct {
    code: ?anyerror = null,
    message: []const u8,
};

pub const ChatState = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_status: *const fn (ctx: *anyopaque) Status,
        set_status: *const fn (ctx: *anyopaque, status: Status, err: ?ErrorInfo) anyerror!void,
        get_error: *const fn (ctx: *anyopaque) ?ErrorInfo,
        message_count: *const fn (ctx: *anyopaque) usize,
        get_message: *const fn (ctx: *anyopaque, index: usize) messages.UIMessage,
        push_message: *const fn (ctx: *anyopaque, value: messages.UIMessage) anyerror!void,
        pop_message: *const fn (ctx: *anyopaque) anyerror!void,
        replace_message: *const fn (ctx: *anyopaque, index: usize, value: messages.UIMessage) anyerror!void,
        truncate_messages: *const fn (ctx: *anyopaque, length: usize) anyerror!void,
        snapshot: *const fn (ctx: *anyopaque, arena: Allocator, value: messages.UIMessage) anyerror!messages.UIMessage,
    };

    pub fn status(self: ChatState) Status {
        return self.vtable.get_status(self.ctx);
    }
    pub fn setStatus(self: ChatState, value: Status, err: ?ErrorInfo) anyerror!void {
        return self.vtable.set_status(self.ctx, value, err);
    }
    pub fn errorInfo(self: ChatState) ?ErrorInfo {
        return self.vtable.get_error(self.ctx);
    }
    pub fn messageCount(self: ChatState) usize {
        return self.vtable.message_count(self.ctx);
    }
    pub fn message(self: ChatState, index: usize) messages.UIMessage {
        return self.vtable.get_message(self.ctx, index);
    }
    pub fn push(self: ChatState, value: messages.UIMessage) anyerror!void {
        return self.vtable.push_message(self.ctx, value);
    }
    pub fn pop(self: ChatState) anyerror!void {
        return self.vtable.pop_message(self.ctx);
    }
    pub fn replace(self: ChatState, index: usize, value: messages.UIMessage) anyerror!void {
        return self.vtable.replace_message(self.ctx, index, value);
    }
    pub fn truncate(self: ChatState, length: usize) anyerror!void {
        return self.vtable.truncate_messages(self.ctx, length);
    }
    pub fn snapshot(self: ChatState, arena: Allocator, value: messages.UIMessage) anyerror!messages.UIMessage {
        return self.vtable.snapshot(self.ctx, arena, value);
    }
};

pub const MemoryChatState = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    status_value: Status = .ready,
    error_value: ?ErrorInfo = null,
    message_list: std.ArrayList(messages.UIMessage) = .empty,
    status_history: std.ArrayList(Status) = .empty,

    pub fn create(gpa: Allocator, initial: []const messages.UIMessage) !*MemoryChatState {
        const self = try gpa.create(MemoryChatState);
        self.* = .{ .gpa = gpa, .arena_state = std.heap.ArenaAllocator.init(gpa) };
        errdefer {
            self.arena_state.deinit();
            gpa.destroy(self);
        }
        for (initial) |value| try self.message_list.append(
            self.arena_state.allocator(),
            try messages.cloneMessage(self.arena_state.allocator(), value),
        );
        return self;
    }

    pub fn deinit(self: *MemoryChatState) void {
        self.status_history.deinit(self.arena_state.allocator());
        self.message_list.deinit(self.arena_state.allocator());
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    pub fn asState(self: *MemoryChatState) ChatState {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ChatState.VTable = .{
        .get_status = getStatus,
        .set_status = setStatus,
        .get_error = getError,
        .message_count = messageCount,
        .get_message = getMessage,
        .push_message = pushMessage,
        .pop_message = popMessage,
        .replace_message = replaceMessage,
        .truncate_messages = truncateMessages,
        .snapshot = snapshot,
    };

    fn getStatus(raw: *anyopaque) Status {
        return (@as(*MemoryChatState, @ptrCast(@alignCast(raw)))).status_value;
    }
    fn setStatus(raw: *anyopaque, value: Status, err: ?ErrorInfo) anyerror!void {
        const self: *MemoryChatState = @ptrCast(@alignCast(raw));
        self.status_value = value;
        try self.status_history.append(self.arena_state.allocator(), value);
        self.error_value = if (err) |info| .{
            .code = info.code,
            .message = try self.arena_state.allocator().dupe(u8, info.message),
        } else null;
    }
    fn getError(raw: *anyopaque) ?ErrorInfo {
        return (@as(*MemoryChatState, @ptrCast(@alignCast(raw)))).error_value;
    }
    fn messageCount(raw: *anyopaque) usize {
        return (@as(*MemoryChatState, @ptrCast(@alignCast(raw)))).message_list.items.len;
    }
    fn getMessage(raw: *anyopaque, index: usize) messages.UIMessage {
        return (@as(*MemoryChatState, @ptrCast(@alignCast(raw)))).message_list.items[index];
    }
    fn pushMessage(raw: *anyopaque, value: messages.UIMessage) anyerror!void {
        const self: *MemoryChatState = @ptrCast(@alignCast(raw));
        try self.message_list.append(
            self.arena_state.allocator(),
            try messages.cloneMessage(self.arena_state.allocator(), value),
        );
    }
    fn popMessage(raw: *anyopaque) anyerror!void {
        const self: *MemoryChatState = @ptrCast(@alignCast(raw));
        if (self.message_list.items.len != 0) _ = self.message_list.pop();
    }
    fn replaceMessage(raw: *anyopaque, index: usize, value: messages.UIMessage) anyerror!void {
        const self: *MemoryChatState = @ptrCast(@alignCast(raw));
        self.message_list.items[index] = try messages.cloneMessage(self.arena_state.allocator(), value);
    }
    fn truncateMessages(raw: *anyopaque, length: usize) anyerror!void {
        const self: *MemoryChatState = @ptrCast(@alignCast(raw));
        if (length > self.message_list.items.len) return error.InvalidArgumentError;
        self.message_list.shrinkRetainingCapacity(length);
    }
    fn snapshot(_: *anyopaque, arena: Allocator, value: messages.UIMessage) anyerror!messages.UIMessage {
        return messages.cloneMessage(arena, value);
    }
};

pub const OnError = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, err: ErrorInfo) void,
    pub fn call(self: OnError, err: ErrorInfo) void {
        self.call_fn(self.ctx, err);
    }
};

pub const OnFinishOptions = struct {
    message: messages.UIMessage,
    messages: []const messages.UIMessage,
    is_abort: bool,
    is_disconnect: bool,
    is_error: bool,
    finish_reason: ?provider.FinishReasonUnified,
};

pub const OnFinish = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, io: std.Io, options: OnFinishOptions) anyerror!void,
    pub fn call(self: OnFinish, io: std.Io, options: OnFinishOptions) anyerror!void {
        return self.call_fn(self.ctx, io, options);
    }
};

pub const SendAutomaticallyWhen = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, io: std.Io, values: []const messages.UIMessage) anyerror!bool,
    pub fn call(self: SendAutomaticallyWhen, io: std.Io, values: []const messages.UIMessage) anyerror!bool {
        return self.call_fn(self.ctx, io, values);
    }
};

pub const Init = struct {
    state: ChatState,
    transport: transports.ChatTransport,
    id: ?[]const u8 = null,
    message_metadata_schema: ?provider_utils.Schema = null,
    data_part_schemas: []const process.NamedSchema = &.{},
    on_error: ?OnError = null,
    on_tool_call: ?process.OnToolCall = null,
    on_finish: ?OnFinish = null,
    on_data: ?process.OnData = null,
    send_automatically_when: ?SendAutomaticallyWhen = null,
    diag: ?*provider.Diagnostics = null,
};

pub const CreateMessage = struct {
    id: ?[]const u8 = null,
    role: messages.Role = .user,
    metadata: ?JsonValue = null,
    parts: ?[]const messages.UIMessagePart = null,
    text: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
};

pub const ToolOutput = union(enum) {
    available: JsonValue,
    err: []const u8,
};

pub const Chat = struct {
    io: std.Io,
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    id: []const u8,
    id_generator: provider_utils.IdGenerator,
    state: ChatState,
    transport: transports.ChatTransport,
    message_metadata_schema: ?provider_utils.Schema,
    data_part_schemas: []const process.NamedSchema,
    on_error: ?OnError,
    on_tool_call: ?process.OnToolCall,
    on_finish: ?OnFinish,
    on_data: ?process.OnData,
    send_automatically_when: ?SendAutomaticallyWhen,
    diag: ?*provider.Diagnostics,
    request_mutex: std.Io.Mutex = .init,
    job_mutex: std.Io.Mutex = .init,
    state_mutex: std.Io.Mutex = .init,
    active_mutex: std.Io.Mutex = .init,
    active_stream: ?*const stream_api.ChunkStream = null,
    active_state: ?*process.StreamingState = null,
    active_arena: ?Allocator = null,
    stop_requested: std.atomic.Value(bool) = .init(false),

    pub fn create(io: std.Io, gpa: Allocator, init: Init) !*Chat {
        const self = try gpa.create(Chat);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .id = undefined,
            .id_generator = try provider_utils.IdGenerator.initFromIo(io, .{}, init.diag),
            .state = init.state,
            .transport = init.transport,
            .message_metadata_schema = init.message_metadata_schema,
            .data_part_schemas = init.data_part_schemas,
            .on_error = init.on_error,
            .on_tool_call = init.on_tool_call,
            .on_finish = init.on_finish,
            .on_data = init.on_data,
            .send_automatically_when = init.send_automatically_when,
            .diag = init.diag,
        };
        errdefer {
            self.arena_state.deinit();
            gpa.destroy(self);
        }
        self.id = if (init.id) |id|
            try self.arena_state.allocator().dupe(u8, id)
        else
            try self.id_generator.nextAlloc(self.arena_state.allocator());
        return self;
    }

    pub fn deinit(self: *Chat) void {
        self.stop();
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }
    pub fn status(self: *const Chat) Status {
        return self.state.status();
    }
    pub fn errorInfo(self: *const Chat) ?ErrorInfo {
        return self.state.errorInfo();
    }

    pub fn sendMessage(self: *Chat, value: ?CreateMessage, request: transports.RequestOptions) anyerror!void {
        try self.request_mutex.lock(self.io);
        defer self.request_mutex.unlock(self.io);
        if (value) |create_value| {
            {
                try self.state_mutex.lock(self.io);
                defer self.state_mutex.unlock(self.io);
                const new_message = try self.createMessage(create_value);
                if (create_value.message_id) |replace_id| {
                    const index = self.findMessage(replace_id) orelse return error.InvalidArgumentError;
                    if (self.state.message(index).role != .user) return error.InvalidMessageRoleError;
                    try self.state.truncate(index + 1);
                    var replacement = new_message;
                    replacement.id = try self.arena_state.allocator().dupe(u8, replace_id);
                    try self.state.replace(index, replacement);
                } else {
                    try self.state.push(new_message);
                }
            }
        }
        try self.makeRequest(.submit_message, if (value) |item| item.message_id else self.lastMessageId(), request, null);
    }

    pub fn regenerate(self: *Chat, message_id: ?[]const u8, request: transports.RequestOptions) anyerror!void {
        try self.request_mutex.lock(self.io);
        defer self.request_mutex.unlock(self.io);
        try self.state_mutex.lock(self.io);
        const count = self.state.messageCount();
        const index = if (message_id) |id|
            self.findMessage(id) orelse {
                self.state_mutex.unlock(self.io);
                return error.InvalidArgumentError;
            }
        else if (count == 0) {
            self.state_mutex.unlock(self.io);
            return error.InvalidArgumentError;
        } else count - 1;
        const keep = if (self.state.message(index).role == .assistant) index else index + 1;
        try self.state.truncate(keep);
        self.state_mutex.unlock(self.io);
        try self.makeRequest(.regenerate_message, message_id, request, null);
    }

    pub fn resumeStream(self: *Chat, request: transports.RequestOptions) anyerror!void {
        try self.request_mutex.lock(self.io);
        defer self.request_mutex.unlock(self.io);
        const reconnect = self.transport.reconnectToStream(self.io, self.gpa, .{
            .chat_id = self.id,
            .request = request,
            .diag = self.diag,
        }) catch |err| {
            try self.fail(err, @errorName(err));
            return;
        } orelse return;
        try self.makeRequest(.resume_stream, null, request, reconnect);
    }

    pub fn stop(self: *Chat) void {
        const current = self.status();
        if (current != .submitted and current != .streaming) return;
        self.stop_requested.store(true, .release);
        self.active_mutex.lockUncancelable(self.io);
        defer self.active_mutex.unlock(self.io);
        if (self.active_stream) |active| active.cancel(self.io);
    }

    pub fn clearError(self: *Chat) anyerror!void {
        if (self.status() == .@"error") try self.state.setStatus(.ready, null);
    }

    pub fn addToolOutput(
        self: *Chat,
        tool_name: []const u8,
        tool_call_id: []const u8,
        output: ToolOutput,
        request: transports.RequestOptions,
    ) anyerror!void {
        {
            try self.job_mutex.lock(self.io);
            defer self.job_mutex.unlock(self.io);
            try self.updateTool(tool_name, tool_call_id, output, null);
        }
        try self.maybeAutoSubmit(request);
    }

    pub fn addToolApprovalResponse(
        self: *Chat,
        approval_id: []const u8,
        approved: bool,
        reason: ?[]const u8,
        request: transports.RequestOptions,
    ) anyerror!void {
        {
            try self.job_mutex.lock(self.io);
            defer self.job_mutex.unlock(self.io);
            try self.updateTool("", "", null, .{ .id = approval_id, .approved = approved, .reason = reason });
        }
        try self.maybeAutoSubmit(request);
    }

    // Every caller holds request_mutex once for this entire iterative lifecycle.
    fn makeRequest(
        self: *Chat,
        trigger: transports.Trigger,
        message_id: ?[]const u8,
        request: transports.RequestOptions,
        resumed: ?stream_api.ChunkStream,
    ) anyerror!void {
        var next_trigger = trigger;
        var next_message_id = message_id;
        var next_resumed = resumed;

        while (true) {
            const can_auto_submit = try self.makeRequestOnce(
                next_trigger,
                next_message_id,
                request,
                next_resumed,
            );
            if (!can_auto_submit) return;

            const should_auto_submit = check: {
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                break :check try self.shouldSendAutomatically(arena_state.allocator());
            };
            if (!should_auto_submit) return;

            next_trigger = .submit_message;
            next_message_id = self.lastMessageId();
            next_resumed = null;
        }
    }

    fn makeRequestOnce(
        self: *Chat,
        trigger: transports.Trigger,
        message_id: ?[]const u8,
        request: transports.RequestOptions,
        resumed: ?stream_api.ChunkStream,
    ) anyerror!bool {
        self.stop_requested.store(false, .release);
        try self.state.setStatus(.submitted, null);
        var request_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer request_arena_state.deinit();
        const arena = request_arena_state.allocator();
        const request_messages = try self.snapshotMessages(arena);
        const last = if (request_messages.len == 0) null else request_messages[request_messages.len - 1];
        const last_snapshot = if (last) |item| try self.state.snapshot(arena, item) else null;
        var streaming_state = try process.StreamingState.init(
            arena,
            last_snapshot,
            try self.id_generator.nextAlloc(arena),
        );
        defer streaming_state.deinit(arena);

        var owned_stream = resumed orelse self.transport.sendMessages(self.io, self.gpa, .{
            .chat_id = self.id,
            .messages = request_messages,
            .trigger = trigger,
            .message_id = message_id,
            .request = request,
            .diag = self.diag,
        }) catch |err| {
            try self.fail(err, @errorName(err));
            return false;
        };
        defer owned_stream.deinit(self.io);
        const active_stream = owned_stream;
        self.active_mutex.lockUncancelable(self.io);
        self.active_stream = &active_stream;
        self.active_state = &streaming_state;
        self.active_arena = arena;
        self.active_mutex.unlock(self.io);
        defer {
            self.active_mutex.lockUncancelable(self.io);
            self.active_stream = null;
            self.active_state = null;
            self.active_arena = null;
            self.active_mutex.unlock(self.io);
        }

        var update_context: UpdateContext = .{ .chat = self };
        var stream_error: StreamErrorCapture = .{};
        const reducer_options: process.Options = .{
            .message_metadata_schema = self.message_metadata_schema,
            .data_part_schemas = self.data_part_schemas,
            .write = .{ .ctx = &update_context, .call_fn = UpdateContext.write },
            .on_error = .{ .ctx = &stream_error, .call_fn = StreamErrorCapture.capture },
            .on_data = self.on_data,
            .on_tool_call = self.on_tool_call,
            .diag = self.diag,
        };
        var terminal_error: ?anyerror = null;
        while (true) {
            const maybe_chunk = owned_stream.next(self.io) catch |err| {
                terminal_error = err;
                break;
            };
            const chunk = maybe_chunk orelse break;
            self.active_mutex.lockUncancelable(self.io);
            process.applyChunk(self.io, arena, &streaming_state, chunk, reducer_options) catch |err| {
                self.active_mutex.unlock(self.io);
                terminal_error = err;
                break;
            };
            self.active_mutex.unlock(self.io);
            if (stream_error.message != null) {
                terminal_error = error.UIMessageStreamError;
                break;
            }
        }

        const stopped = self.stop_requested.load(.acquire);
        const was_canceled = if (terminal_error) |err| err == error.Canceled else false;
        var is_disconnect = false;
        var is_error = false;
        if (stopped or was_canceled) {
            try self.state.setStatus(.ready, null);
        } else if (terminal_error) |err| {
            is_error = true;
            is_disconnect = isDisconnectError(err);
            try self.fail(err, stream_error.message orelse @errorName(err));
        } else {
            try self.state.setStatus(.ready, null);
        }
        try self.callOnFinish(
            arena,
            streaming_state.message,
            stopped or was_canceled,
            is_disconnect,
            is_error,
            streaming_state.finish_reason,
        );
        return !is_error and !stopped and !was_canceled;
    }

    fn createMessage(self: *Chat, create_value: CreateMessage) !messages.UIMessage {
        const arena = self.arena_state.allocator();
        const parts = if (create_value.parts) |provided|
            try cloneParts(arena, provided)
        else if (create_value.text) |text|
            try cloneParts(arena, &.{.{ .text = .{ .text = text } }})
        else
            &.{};
        return .{
            .id = if (create_value.id) |id| try arena.dupe(u8, id) else try self.id_generator.nextAlloc(arena),
            .role = create_value.role,
            .metadata = if (create_value.metadata) |metadata| try provider_utils.cloneJsonValue(arena, metadata) else null,
            .parts = parts,
        };
    }

    fn findMessage(self: *Chat, id: []const u8) ?usize {
        for (0..self.state.messageCount()) |index| {
            if (std.mem.eql(u8, self.state.message(index).id, id)) return index;
        }
        return null;
    }
    fn lastMessageId(self: *Chat) ?[]const u8 {
        const count = self.state.messageCount();
        return if (count == 0) null else self.state.message(count - 1).id;
    }
    fn snapshotMessages(self: *Chat, arena: Allocator) ![]const messages.UIMessage {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const result = try arena.alloc(messages.UIMessage, self.state.messageCount());
        for (result, 0..) |*slot, index| slot.* = try self.state.snapshot(arena, self.state.message(index));
        return result;
    }

    const ApprovalInput = struct { id: []const u8, approved: bool, reason: ?[]const u8 };

    fn updateTool(
        self: *Chat,
        tool_name: []const u8,
        tool_call_id: []const u8,
        output: ?ToolOutput,
        approval: ?ApprovalInput,
    ) !void {
        try self.active_mutex.lock(self.io);
        defer self.active_mutex.unlock(self.io);
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const count = self.state.messageCount();
        if (count == 0) return error.InvalidArgumentError;
        const latest = try messages.cloneMessage(self.arena_state.allocator(), self.state.message(count - 1));
        const mutable_parts = @constCast(latest.parts);
        if (!try mutateToolParts(self.arena_state.allocator(), mutable_parts, tool_name, tool_call_id, output, approval))
            return error.InvalidArgumentError;
        try self.state.replace(count - 1, latest);

        if (self.active_state) |active| {
            const active_arena = self.active_arena.?;
            const active_copy = try messages.cloneMessage(active_arena, latest);
            active.parts.clearRetainingCapacity();
            try active.parts.appendSlice(active_arena, active_copy.parts);
            active.message = active_copy;
            active.message.parts = active.parts.items;
        }
    }

    fn maybeAutoSubmit(self: *Chat, request: transports.RequestOptions) !void {
        const current = self.status();
        if (current == .streaming or current == .submitted) return;
        try self.request_mutex.lock(self.io);
        defer self.request_mutex.unlock(self.io);
        const locked_status = self.status();
        if (locked_status == .streaming or locked_status == .submitted) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        if (try self.shouldSendAutomatically(arena_state.allocator())) {
            try self.makeRequest(.submit_message, self.lastMessageId(), request, null);
        }
    }
    fn shouldSendAutomatically(self: *Chat, arena: Allocator) !bool {
        const callback = self.send_automatically_when orelse return false;
        return callback.call(self.io, try self.snapshotMessages(arena));
    }
    fn fail(self: *Chat, err: anyerror, text: []const u8) !void {
        const info: ErrorInfo = .{ .code = err, .message = text };
        try self.state.setStatus(.@"error", info);
        if (self.on_error) |callback| callback.call(info);
    }
    fn callOnFinish(
        self: *Chat,
        arena: Allocator,
        response: messages.UIMessage,
        is_abort: bool,
        is_disconnect: bool,
        is_error: bool,
        finish_reason: ?provider.FinishReasonUnified,
    ) !void {
        const callback = self.on_finish orelse return;
        try callback.call(self.io, .{
            .message = try messages.cloneMessage(arena, response),
            .messages = try self.snapshotMessages(arena),
            .is_abort = is_abort,
            .is_disconnect = is_disconnect,
            .is_error = is_error,
            .finish_reason = finish_reason,
        });
    }
};

const UpdateContext = struct {
    chat: *Chat,
    fn write(raw: ?*anyopaque, io: std.Io, snapshot: messages.UIMessage) anyerror!void {
        const self: *UpdateContext = @ptrCast(@alignCast(raw.?));
        try self.chat.state_mutex.lock(io);
        defer self.chat.state_mutex.unlock(io);
        if (self.chat.status() != .streaming) try self.chat.state.setStatus(.streaming, null);
        const count = self.chat.state.messageCount();
        if (count != 0 and std.mem.eql(u8, self.chat.state.message(count - 1).id, snapshot.id)) {
            try self.chat.state.replace(count - 1, snapshot);
        } else {
            try self.chat.state.push(snapshot);
        }
    }
};

const StreamErrorCapture = struct {
    message: ?[]const u8 = null,
    fn capture(raw: ?*anyopaque, text: []const u8) void {
        const self: *StreamErrorCapture = @ptrCast(@alignCast(raw.?));
        self.message = text;
    }
};

fn mutateToolParts(
    arena: Allocator,
    parts: []messages.UIMessagePart,
    tool_name: []const u8,
    tool_call_id: []const u8,
    output: ?ToolOutput,
    approval: ?Chat.ApprovalInput,
) !bool {
    for (parts) |*part| {
        const tool = part.toolPart() orelse continue;
        if (approval) |response| {
            const request = toolApprovalRequest(tool.state) orelse continue;
            if (!std.mem.eql(u8, request.id, response.id)) continue;
            const input = toolInput(tool.state) orelse .null;
            const call_metadata = stateCallMetadata(tool.state);
            tool.state = .{ .approval_responded = .{
                .input = input,
                .approval = .{
                    .id = try arena.dupe(u8, response.id),
                    .approved = response.approved,
                    .reason = if (response.reason) |reason| try arena.dupe(u8, reason) else null,
                    .is_automatic = request.is_automatic,
                    .signature = request.signature,
                },
                .call_provider_metadata = call_metadata,
            } };
            return true;
        }
        if (!std.mem.eql(u8, tool.tool_call_id, tool_call_id)) continue;
        if (tool_name.len != 0 and !std.mem.eql(u8, tool.name, tool_name)) return error.InvalidArgumentError;
        const selected = output orelse return false;
        const input = toolInput(tool.state) orelse .null;
        const call_metadata = stateCallMetadata(tool.state);
        const approved = approvedApproval(tool.state);
        switch (selected) {
            .available => |value| tool.state = .{ .output_available = .{
                .input = input,
                .output = try provider_utils.cloneJsonValue(arena, value),
                .call_provider_metadata = call_metadata,
                .approval = approved,
            } },
            .err => |text| tool.state = .{ .output_error = .{
                .input = input,
                .error_text = try arena.dupe(u8, text),
                .call_provider_metadata = call_metadata,
                .approval = approved,
            } },
        }
        return true;
    }
    return false;
}

pub fn lastAssistantMessageIsCompleteWithToolCalls(values: []const messages.UIMessage) bool {
    const message = if (values.len == 0) return false else values[values.len - 1];
    if (message.role != .assistant) return false;
    const last_step_parts = partsAfterLastStepStart(message.parts);
    var count: usize = 0;
    for (last_step_parts) |part| {
        const tool = part.toolPartConst() orelse continue;
        if (tool.provider_executed == true) continue;
        count += 1;
        switch (tool.state) {
            .output_available, .output_error => {},
            else => return false,
        }
    }
    return count != 0;
}

pub fn lastAssistantMessageIsCompleteWithApprovalResponses(values: []const messages.UIMessage) bool {
    const message = if (values.len == 0) return false else values[values.len - 1];
    if (message.role != .assistant) return false;
    const last_step_parts = partsAfterLastStepStart(message.parts);
    var responded: usize = 0;
    for (last_step_parts) |part| {
        const tool = part.toolPartConst() orelse continue;
        switch (tool.state) {
            .approval_responded => responded += 1,
            .output_available, .output_error => {},
            else => return false,
        }
    }
    return responded != 0;
}

fn partsAfterLastStepStart(parts: []const messages.UIMessagePart) []const messages.UIMessagePart {
    var last_index: ?usize = null;
    for (parts, 0..) |part, index| if (part == .step_start) {
        last_index = index;
    };
    return if (last_index) |index| parts[index + 1 ..] else parts;
}
fn isDisconnectError(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.indexOf(u8, name, "Connection") != null or
        std.mem.indexOf(u8, name, "Network") != null or
        std.mem.indexOf(u8, name, "Fetch") != null;
}
fn cloneParts(arena: Allocator, parts: []const messages.UIMessagePart) ![]const messages.UIMessagePart {
    return (try messages.cloneMessage(arena, .{ .id = "clone", .role = .user, .parts = parts })).parts;
}
fn toolInput(state: messages.ToolState) ?JsonValue {
    return switch (state) {
        .input_streaming => |value| value.input,
        .input_available => |value| value.input,
        .approval_requested => |value| value.input,
        .approval_responded => |value| value.input,
        .output_available => |value| value.input,
        .output_error => |value| value.input,
        .output_denied => |value| value.input,
    };
}
fn stateCallMetadata(state: messages.ToolState) ?JsonValue {
    return switch (state) {
        .input_streaming => |value| value.call_provider_metadata,
        .input_available => |value| value.call_provider_metadata,
        .approval_requested => |value| value.call_provider_metadata,
        .approval_responded => |value| value.call_provider_metadata,
        .output_available => |value| value.call_provider_metadata,
        .output_error => |value| value.call_provider_metadata,
        .output_denied => |value| value.call_provider_metadata,
    };
}
fn toolApprovalRequest(state: messages.ToolState) ?messages.ApprovalRequest {
    return switch (state) {
        .approval_requested => |value| value.approval,
        .approval_responded => |value| .{
            .id = value.approval.id,
            .is_automatic = value.approval.is_automatic,
            .signature = value.approval.signature,
        },
        else => null,
    };
}
fn approvedApproval(state: messages.ToolState) ?messages.ApprovalResponse {
    return switch (state) {
        .approval_responded => |value| if (value.approval.approved) value.approval else null,
        .output_available => |value| value.approval,
        .output_error => |value| value.approval,
        else => null,
    };
}

const TestTransport = struct {
    mode: Mode,
    mutex: std.Io.Mutex = .init,
    calls: usize = 0,
    active: usize = 0,
    max_active: usize = 0,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,

    const Mode = enum { success, fail, block, tool_then_success };

    fn asTransport(self: *TestTransport) transports.ChatTransport {
        return .{ .ctx = self, .vtable = &.{
            .send_messages = send,
            .reconnect_to_stream = reconnect,
        } };
    }

    fn send(
        raw: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        _: transports.SendMessagesOptions,
    ) anyerror!stream_api.ChunkStream {
        const self: *TestTransport = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(io);
        self.calls += 1;
        self.active += 1;
        self.max_active = @max(self.max_active, self.active);
        const call_number = self.calls;
        self.mutex.unlock(io);
        const stream = try gpa.create(TestStream);
        stream.* = .{
            .gpa = gpa,
            .owner = self,
            .mode = self.mode,
            .call_number = call_number,
        };
        return stream.asStream();
    }

    fn reconnect(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: transports.ReconnectOptions,
    ) anyerror!?stream_api.ChunkStream {
        return null;
    }
};

const TestStream = struct {
    gpa: Allocator,
    owner: *TestTransport,
    mode: TestTransport.Mode,
    call_number: usize,
    index: usize = 0,
    canceled: std.atomic.Value(bool) = .init(false),

    fn asStream(self: *TestStream) stream_api.ChunkStream {
        return .{ .ctx = self, .vtable = &.{ .next = next, .deinit = deinit, .cancel = cancel } };
    }

    fn next(raw: *anyopaque, io: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *TestStream = @ptrCast(@alignCast(raw));
        if (self.canceled.load(.acquire)) return null;
        if (self.mode == .fail) {
            if (self.index == 0) {
                self.index = 1;
                return error.NetworkFailure;
            }
            return null;
        }
        if (self.mode == .block) {
            const result: ?chunks.UIMessageChunk = switch (self.index) {
                0 => .{ .start = .{} },
                1 => .{ .start_step = .{} },
                2 => .{ .text_start = .{ .id = "t" } },
                3 => blk: {
                    self.owner.entered.set(io);
                    try self.owner.release.wait(io);
                    break :blk null;
                },
                else => null,
            };
            self.index += 1;
            return result;
        }
        if (self.mode == .tool_then_success and self.call_number == 1) {
            const result: ?chunks.UIMessageChunk = switch (self.index) {
                0 => .{ .start = .{} },
                1 => .{ .start_step = .{} },
                2 => .{ .tool_input_available = .{
                    .tool_call_id = "call-1",
                    .tool_name = "weather",
                    .input = .{ .string = "NYC" },
                } },
                3 => .{ .finish = .{ .finish_reason = .tool_calls } },
                else => null,
            };
            self.index += 1;
            return result;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
        const result: ?chunks.UIMessageChunk = switch (self.index) {
            0 => .{ .start = .{} },
            1 => .{ .start_step = .{} },
            2 => .{ .text_start = .{ .id = "t" } },
            3 => .{ .text_delta = .{ .id = "t", .delta = "ok" } },
            4 => .{ .text_end = .{ .id = "t" } },
            5 => .{ .finish = .{ .finish_reason = .stop } },
            else => null,
        };
        self.index += 1;
        return result;
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *TestStream = @ptrCast(@alignCast(raw));
        self.canceled.store(true, .release);
        self.owner.release.set(io);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *TestStream = @ptrCast(@alignCast(raw));
        self.owner.mutex.lockUncancelable(io);
        self.owner.active -= 1;
        self.owner.mutex.unlock(io);
        self.gpa.destroy(self);
    }
};

test "Chat transitions submitted-streaming-ready and serializes concurrent sends" {
    var scripted: TestTransport = .{ .mode = .success };
    const memory = try MemoryChatState.create(std.testing.allocator, &.{});
    defer memory.deinit();
    const chat = try Chat.create(std.testing.io, std.testing.allocator, .{
        .state = memory.asState(),
        .transport = scripted.asTransport(),
        .id = "chat",
    });
    defer chat.deinit();

    const Runner = struct {
        fn run(target: *Chat, text: []const u8) anyerror!void {
            return target.sendMessage(.{ .text = text }, .{});
        }
    };
    var first = try std.testing.io.concurrent(Runner.run, .{ chat, "one" });
    defer _ = first.cancel(std.testing.io) catch {};
    var second = try std.testing.io.concurrent(Runner.run, .{ chat, "two" });
    defer _ = second.cancel(std.testing.io) catch {};
    try first.await(std.testing.io);
    try second.await(std.testing.io);

    try std.testing.expectEqual(1, scripted.max_active);
    try std.testing.expectEqual(2, scripted.calls);
    try std.testing.expectEqual(Status.ready, chat.status());
    try std.testing.expectEqual(4, memory.message_list.items.len);
    try std.testing.expect(memory.message_list.items[1].parts[0] == .step_start);
    try std.testing.expectEqualStrings("ok", memory.message_list.items[1].parts[1].text.text);
    try std.testing.expectEqualSlices(
        Status,
        &.{ .submitted, .streaming, .ready, .submitted, .streaming, .ready },
        memory.status_history.items,
    );
}

test "Chat records transport errors and stop cancels a mid-stream response" {
    {
        var scripted: TestTransport = .{ .mode = .fail };
        const memory = try MemoryChatState.create(std.testing.allocator, &.{});
        defer memory.deinit();
        const chat = try Chat.create(std.testing.io, std.testing.allocator, .{
            .state = memory.asState(),
            .transport = scripted.asTransport(),
        });
        defer chat.deinit();
        try chat.sendMessage(.{ .text = "fail" }, .{});
        try std.testing.expectEqual(Status.@"error", chat.status());
        try std.testing.expectEqual(error.NetworkFailure, chat.errorInfo().?.code.?);
        try chat.clearError();
        try std.testing.expectEqual(Status.ready, chat.status());
    }

    {
        var scripted: TestTransport = .{ .mode = .block };
        const memory = try MemoryChatState.create(std.testing.allocator, &.{});
        defer memory.deinit();
        const chat = try Chat.create(std.testing.io, std.testing.allocator, .{
            .state = memory.asState(),
            .transport = scripted.asTransport(),
        });
        defer chat.deinit();
        const Runner = struct {
            fn run(target: *Chat) anyerror!void {
                return target.sendMessage(.{ .text = "stop" }, .{});
            }
        };
        var future = try std.testing.io.concurrent(Runner.run, .{chat});
        defer _ = future.cancel(std.testing.io) catch {};
        try scripted.entered.wait(std.testing.io);
        chat.stop();
        try future.await(std.testing.io);
        try std.testing.expectEqual(Status.ready, chat.status());
    }
}

test "Chat addToolOutput auto-resubmits with completion helper" {
    var scripted: TestTransport = .{ .mode = .tool_then_success };
    const memory = try MemoryChatState.create(std.testing.allocator, &.{});
    defer memory.deinit();
    const Auto = struct {
        fn call(_: ?*anyopaque, _: std.Io, values: []const messages.UIMessage) anyerror!bool {
            return lastAssistantMessageIsCompleteWithToolCalls(values);
        }
    };
    const chat = try Chat.create(std.testing.io, std.testing.allocator, .{
        .state = memory.asState(),
        .transport = scripted.asTransport(),
        .send_automatically_when = .{ .call_fn = Auto.call },
    });
    defer chat.deinit();
    try chat.sendMessage(.{ .text = "weather" }, .{});
    try std.testing.expectEqual(1, scripted.calls);
    try chat.addToolOutput("weather", "call-1", .{ .available = .{ .string = "sunny" } }, .{});
    try std.testing.expectEqual(2, scripted.calls);
    try std.testing.expectEqual(Status.ready, chat.status());
    const assistant = memory.message_list.items[memory.message_list.items.len - 1];
    try std.testing.expectEqual(4, assistant.parts.len);
    try std.testing.expect(assistant.parts[0] == .step_start);
    try std.testing.expect(assistant.parts[1].tool.state == .output_available);
    try std.testing.expect(assistant.parts[2] == .step_start);
    try std.testing.expectEqualStrings("ok", assistant.parts[3].text.text);
}

test "lastAssistantMessageIsCompleteWithToolCalls only considers client tools in the last step" {
    const completed: messages.UIMessagePart = .{ .tool = .{
        .name = "weather",
        .tool_call_id = "call-1",
        .state = .{ .output_available = .{ .input = .null, .output = .null } },
    } };
    const failed: messages.UIMessagePart = .{ .dynamic_tool = .{
        .name = "lookup",
        .tool_call_id = "call-2",
        .state = .{ .output_error = .{ .error_text = "failed" } },
    } };
    const provider_completed: messages.UIMessagePart = .{ .tool = .{
        .name = "provider",
        .tool_call_id = "call-provider",
        .provider_executed = true,
        .state = .{ .output_available = .{ .input = .null, .output = .null } },
    } };
    const incomplete: messages.UIMessagePart = .{ .tool = .{
        .name = "weather",
        .tool_call_id = "call-incomplete",
        .state = .{ .input_available = .{ .input = .null } },
    } };

    try std.testing.expect(!lastAssistantMessageIsCompleteWithToolCalls(&.{}));
    try std.testing.expect(!lastAssistantMessageIsCompleteWithToolCalls(&.{.{
        .id = "user",
        .role = .user,
        .parts = &.{completed},
    }}));
    try std.testing.expect(lastAssistantMessageIsCompleteWithToolCalls(&.{.{
        .id = "assistant",
        .role = .assistant,
        .parts = &.{ .{ .step_start = {} }, completed, failed },
    }}));
    try std.testing.expect(!lastAssistantMessageIsCompleteWithToolCalls(&.{.{
        .id = "assistant",
        .role = .assistant,
        .parts = &.{
            .{ .step_start = {} },
            completed,
            .{ .step_start = {} },
            .{ .text = .{ .text = "next step" } },
        },
    }}));
    try std.testing.expect(!lastAssistantMessageIsCompleteWithToolCalls(&.{.{
        .id = "assistant",
        .role = .assistant,
        .parts = &.{ .{ .step_start = {} }, provider_completed },
    }}));
    try std.testing.expect(!lastAssistantMessageIsCompleteWithToolCalls(&.{.{
        .id = "assistant",
        .role = .assistant,
        .parts = &.{ .{ .step_start = {} }, incomplete },
    }}));
}
