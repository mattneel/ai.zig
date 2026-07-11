//! Client-side UI message stream reducer.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const chunks = @import("ui_chunks.zig");
const messages = @import("ui_messages.zig");
const stream_api = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const NamedSchema = struct {
    name: []const u8,
    schema: provider_utils.Schema,
};

pub const WriteSnapshot = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, io: std.Io, snapshot: messages.UIMessage) anyerror!void,

    pub fn call(self: WriteSnapshot, io: std.Io, snapshot: messages.UIMessage) anyerror!void {
        return self.call_fn(self.ctx, io, snapshot);
    }
};

pub const OnError = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, message: []const u8) void,

    pub fn call(self: OnError, message: []const u8) void {
        self.call_fn(self.ctx, message);
    }
};

pub const OnData = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        part: messages.DataUIPart,
        transient: bool,
    ) anyerror!void,

    pub fn call(self: OnData, io: std.Io, part: messages.DataUIPart, transient: bool) anyerror!void {
        return self.call_fn(self.ctx, io, part, transient);
    }
};

pub const OnToolCall = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        part: messages.ToolUIPart,
        dynamic: bool,
    ) anyerror!void,

    pub fn call(self: OnToolCall, io: std.Io, part: messages.ToolUIPart, dynamic: bool) anyerror!void {
        return self.call_fn(self.ctx, io, part, dynamic);
    }
};

pub const Options = struct {
    message_metadata_schema: ?provider_utils.Schema = null,
    data_part_schemas: []const NamedSchema = &.{},
    write: ?WriteSnapshot = null,
    on_error: ?OnError = null,
    on_data: ?OnData = null,
    on_tool_call: ?OnToolCall = null,
    diag: ?*provider.Diagnostics = null,
};

pub const PartialToolCall = struct {
    text: std.ArrayList(u8) = .empty,
    tool_name: []const u8,
    dynamic: bool,
    title: ?[]const u8 = null,
    tool_metadata: ?JsonValue = null,
};

pub const StreamingState = struct {
    message: messages.UIMessage,
    parts: std.ArrayList(messages.UIMessagePart) = .empty,
    active_text_parts: std.StringHashMapUnmanaged(usize) = .empty,
    active_reasoning_parts: std.StringHashMapUnmanaged(usize) = .empty,
    partial_tool_calls: std.StringHashMapUnmanaged(PartialToolCall) = .empty,
    finish_reason: ?provider.FinishReasonUnified = null,

    pub fn init(
        arena: Allocator,
        last_message: ?messages.UIMessage,
        message_id: []const u8,
    ) !StreamingState {
        var state: StreamingState = undefined;
        if (last_message) |last| {
            if (last.role == .assistant) {
                const cloned = try messages.cloneMessage(arena, last);
                state = .{
                    .message = cloned,
                    .parts = .empty,
                };
                try state.parts.appendSlice(arena, cloned.parts);
                state.syncParts();
                return state;
            }
        }
        state = .{
            .message = .{
                .id = try arena.dupe(u8, message_id),
                .role = .assistant,
                .parts = &.{},
            },
        };
        return state;
    }

    pub fn deinit(self: *StreamingState, allocator: Allocator) void {
        var iterator = self.partial_tool_calls.valueIterator();
        while (iterator.next()) |partial| partial.text.deinit(allocator);
        self.partial_tool_calls.deinit(allocator);
        self.active_reasoning_parts.deinit(allocator);
        self.active_text_parts.deinit(allocator);
        self.parts.deinit(allocator);
        self.* = undefined;
    }

    fn syncParts(self: *StreamingState) void {
        self.message.parts = self.parts.items;
    }
};

pub fn applyChunk(
    io: std.Io,
    arena: Allocator,
    state: *StreamingState,
    chunk: chunks.UIMessageChunk,
    options: Options,
) anyerror!void {
    switch (chunk) {
        .text_start => |value| {
            const id = try arena.dupe(u8, value.id);
            try state.parts.append(arena, .{ .text = .{
                .text = "",
                .state = .streaming,
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            try state.active_text_parts.put(arena, id, state.parts.items.len - 1);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .text_delta => |value| {
            const index = state.active_text_parts.get(value.id) orelse
                return streamError(arena, options.diag, "text-delta", value.id, "Received text-delta without a preceding text-start chunk");
            var part = &state.parts.items[index].text;
            part.text = try std.mem.concat(arena, u8, &.{ part.text, value.delta });
            if (value.provider_metadata) |metadata| part.provider_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .text_end => |value| {
            const index = state.active_text_parts.get(value.id) orelse
                return streamError(arena, options.diag, "text-end", value.id, "Received text-end without a preceding text-start chunk");
            var part = &state.parts.items[index].text;
            part.state = .done;
            if (value.provider_metadata) |metadata| part.provider_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            _ = state.active_text_parts.remove(value.id);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .reasoning_start => |value| {
            const id = try arena.dupe(u8, value.id);
            try state.parts.append(arena, .{ .reasoning = .{
                .text = "",
                .state = .streaming,
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            try state.active_reasoning_parts.put(arena, id, state.parts.items.len - 1);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .reasoning_delta => |value| {
            const index = state.active_reasoning_parts.get(value.id) orelse
                return streamError(arena, options.diag, "reasoning-delta", value.id, "Received reasoning-delta without a preceding reasoning-start chunk");
            var part = &state.parts.items[index].reasoning;
            part.text = try std.mem.concat(arena, u8, &.{ part.text, value.delta });
            if (value.provider_metadata) |metadata| part.provider_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .reasoning_end => |value| {
            const index = state.active_reasoning_parts.get(value.id) orelse
                return streamError(arena, options.diag, "reasoning-end", value.id, "Received reasoning-end without a preceding reasoning-start chunk");
            var part = &state.parts.items[index].reasoning;
            part.state = .done;
            if (value.provider_metadata) |metadata| part.provider_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            _ = state.active_reasoning_parts.remove(value.id);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .custom => |value| {
            try state.parts.append(arena, .{ .custom = .{
                .kind = try arena.dupe(u8, value.kind),
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .file => |value| {
            try state.parts.append(arena, .{ .file = .{
                .url = try arena.dupe(u8, value.url),
                .media_type = try arena.dupe(u8, value.media_type),
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .reasoning_file => |value| {
            try state.parts.append(arena, .{ .reasoning_file = .{
                .url = try arena.dupe(u8, value.url),
                .media_type = try arena.dupe(u8, value.media_type),
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .source_url => |value| {
            try state.parts.append(arena, .{ .source_url = .{
                .source_id = try arena.dupe(u8, value.source_id),
                .url = try arena.dupe(u8, value.url),
                .title = try cloneOptionalString(arena, value.title),
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .source_document => |value| {
            try state.parts.append(arena, .{ .source_document = .{
                .source_id = try arena.dupe(u8, value.source_id),
                .media_type = try arena.dupe(u8, value.media_type),
                .title = try arena.dupe(u8, value.title),
                .filename = try cloneOptionalString(arena, value.filename),
                .provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
            } });
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .tool_input_start => |value| {
            const key = try arena.dupe(u8, value.tool_call_id);
            try state.partial_tool_calls.put(arena, key, .{
                .tool_name = try arena.dupe(u8, value.tool_name),
                .dynamic = value.dynamic orelse false,
                .title = try cloneOptionalString(arena, value.title),
                .tool_metadata = try cloneOptionalValue(arena, value.tool_metadata),
            });
            _ = try updateToolPart(arena, state, .{
                .dynamic = value.dynamic orelse false,
                .name = value.tool_name,
                .tool_call_id = value.tool_call_id,
                .title = value.title,
                .tool_metadata = value.tool_metadata,
                .provider_executed = value.provider_executed,
                .state = .{ .input_streaming = .{
                    .input = null,
                    .call_provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
                } },
            });
            try emit(io, arena, state, options.write);
        },
        .tool_input_delta => |value| {
            const partial = state.partial_tool_calls.getPtr(value.tool_call_id) orelse
                return streamError(arena, options.diag, "tool-input-delta", value.tool_call_id, "Received tool-input-delta without a preceding tool-input-start chunk");
            try partial.text.appendSlice(arena, value.input_text_delta);
            const parsed = try provider_utils.parsePartialJson(arena, partial.text.items);
            _ = try updateToolPart(arena, state, .{
                .dynamic = partial.dynamic,
                .name = partial.tool_name,
                .tool_call_id = value.tool_call_id,
                .title = partial.title,
                .tool_metadata = partial.tool_metadata,
                .state = .{ .input_streaming = .{ .input = parsed.value } },
            });
            try emit(io, arena, state, options.write);
        },
        .tool_input_available => |value| {
            const dynamic = value.dynamic orelse existingToolDynamic(state, value.tool_call_id) orelse false;
            const index = try updateToolPart(arena, state, .{
                .dynamic = dynamic,
                .name = value.tool_name,
                .tool_call_id = value.tool_call_id,
                .title = value.title,
                .tool_metadata = value.tool_metadata,
                .provider_executed = value.provider_executed,
                .state = .{ .input_available = .{
                    .input = try provider_utils.cloneJsonValue(arena, value.input),
                    .call_provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
                } },
            });
            try emit(io, arena, state, options.write);
            if (options.on_tool_call) |hook| {
                const tool = state.parts.items[index].toolPartConst().?.*;
                if (tool.provider_executed != true) try hook.call(io, tool, dynamic);
            }
        },
        .tool_input_error => |value| {
            const dynamic = existingToolDynamic(state, value.tool_call_id) orelse (value.dynamic orelse false);
            const error_state: messages.ToolState = if (dynamic)
                .{ .output_error = .{
                    .input = try provider_utils.cloneJsonValue(arena, value.input),
                    .error_text = try arena.dupe(u8, value.error_text),
                    .result_provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
                } }
            else
                .{ .output_error = .{
                    .raw_input = try provider_utils.cloneJsonValue(arena, value.input),
                    .error_text = try arena.dupe(u8, value.error_text),
                    .result_provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
                } };
            _ = try updateToolPart(arena, state, .{
                .dynamic = dynamic,
                .name = value.tool_name,
                .tool_call_id = value.tool_call_id,
                .title = value.title,
                .tool_metadata = value.tool_metadata,
                .provider_executed = value.provider_executed,
                .state = error_state,
            });
            try emit(io, arena, state, options.write);
        },
        .tool_approval_request => |value| {
            const index = findToolIndex(state, value.tool_call_id) orelse
                return streamError(arena, options.diag, "tool-approval-request", value.tool_call_id, "No tool invocation found for approval request");
            const tool = state.parts.items[index].toolPart().?;
            const input = toolInput(tool.state) orelse
                return streamError(arena, options.diag, "tool-approval-request", value.tool_call_id, "Tool approval request has no available input");
            const call_metadata = stateCallMetadata(tool.state);
            tool.state = .{ .approval_requested = .{
                .input = input,
                .approval = .{
                    .id = try arena.dupe(u8, value.approval_id),
                    .is_automatic = value.is_automatic,
                    .signature = try cloneOptionalString(arena, value.signature),
                },
                .call_provider_metadata = call_metadata,
            } };
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .tool_approval_response => |value| {
            const index = findToolByApprovalId(state, value.approval_id) orelse
                return streamError(arena, options.diag, "tool-approval-response", value.approval_id, "No tool invocation found for approval response");
            const tool = state.parts.items[index].toolPart().?;
            const request = stateApproval(tool.state) orelse
                return streamError(arena, options.diag, "tool-approval-response", value.approval_id, "Tool invocation has no approval request");
            const input = toolInput(tool.state) orelse .null;
            var call_metadata = stateCallMetadata(tool.state);
            if (value.provider_metadata) |metadata| call_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            tool.state = .{ .approval_responded = .{
                .input = input,
                .approval = .{
                    .id = try arena.dupe(u8, value.approval_id),
                    .approved = value.approved,
                    .reason = try cloneOptionalString(arena, value.reason),
                    .is_automatic = request.is_automatic,
                    .signature = request.signature,
                },
                .call_provider_metadata = call_metadata,
            } };
            if (value.provider_executed) |provider_executed| tool.provider_executed = provider_executed;
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .tool_output_available => |value| {
            const index = findToolIndex(state, value.tool_call_id) orelse
                return streamError(arena, options.diag, "tool-output-available", value.tool_call_id, "No tool invocation found for tool output");
            const tool = state.parts.items[index].toolPart().?;
            const input = toolInput(tool.state) orelse .null;
            const approval = approvedApproval(tool.state);
            const call_metadata = stateCallMetadata(tool.state);
            tool.state = .{ .output_available = .{
                .input = input,
                .output = try provider_utils.cloneJsonValue(arena, value.output),
                .call_provider_metadata = call_metadata,
                .result_provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
                .preliminary = value.preliminary,
                .approval = approval,
            } };
            if (value.provider_executed) |provider_executed| tool.provider_executed = provider_executed;
            if (value.tool_metadata) |metadata| tool.tool_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .tool_output_error => |value| {
            const index = findToolIndex(state, value.tool_call_id) orelse
                return streamError(arena, options.diag, "tool-output-error", value.tool_call_id, "No tool invocation found for tool error");
            const tool = state.parts.items[index].toolPart().?;
            const input = toolInput(tool.state);
            const raw_input = stateRawInput(tool.state);
            const approval = approvedApproval(tool.state);
            const call_metadata = stateCallMetadata(tool.state);
            tool.state = .{ .output_error = .{
                .input = input,
                .raw_input = raw_input,
                .error_text = try arena.dupe(u8, value.error_text),
                .call_provider_metadata = call_metadata,
                .result_provider_metadata = try cloneOptionalValue(arena, value.provider_metadata),
                .approval = approval,
            } };
            if (value.provider_executed) |provider_executed| tool.provider_executed = provider_executed;
            if (value.tool_metadata) |metadata| tool.tool_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .tool_output_denied => |value| {
            const index = findToolIndex(state, value.tool_call_id) orelse
                return streamError(arena, options.diag, "tool-output-denied", value.tool_call_id, "No tool invocation found for denied tool output");
            const tool = state.parts.items[index].toolPart().?;
            const approval = responseApproval(tool.state) orelse
                return streamError(arena, options.diag, "tool-output-denied", value.tool_call_id, "Denied tool output has no approval response");
            const input = toolInput(tool.state) orelse .null;
            const call_metadata = stateCallMetadata(tool.state);
            tool.state = .{ .output_denied = .{
                .input = input,
                .approval = approval,
                .call_provider_metadata = call_metadata,
            } };
            state.syncParts();
            try emit(io, arena, state, options.write);
        },
        .data => |value| {
            const data_part: messages.DataUIPart = .{
                .name = try arena.dupe(u8, value.name),
                .id = try cloneOptionalString(arena, value.id),
                .data = try provider_utils.cloneJsonValue(arena, value.data),
            };
            if (schemaFor(options.data_part_schemas, value.name)) |schema| {
                try validateSchema(arena, schema, data_part.data, options.diag);
            }
            const transient = value.transient orelse false;
            if (!transient) {
                if (data_part.id) |id| {
                    if (findDataPart(state, data_part.name, id)) |index| {
                        state.parts.items[index].data.data = data_part.data;
                    } else {
                        try state.parts.append(arena, .{ .data = data_part });
                    }
                } else {
                    try state.parts.append(arena, .{ .data = data_part });
                }
                state.syncParts();
            }
            if (options.on_data) |hook| try hook.call(io, data_part, transient);
            if (!transient) try emit(io, arena, state, options.write);
        },
        .start_step => {
            try state.parts.append(arena, .{ .step_start = {} });
            state.syncParts();
        },
        .finish_step => {
            state.active_text_parts.clearRetainingCapacity();
            state.active_reasoning_parts.clearRetainingCapacity();
        },
        .start => |value| {
            var changed = false;
            if (value.message_id) |id| {
                state.message.id = try arena.dupe(u8, id);
                changed = true;
            }
            if (value.message_metadata) |metadata| {
                try updateMetadata(arena, state, metadata, options);
                changed = true;
            }
            if (changed) try emit(io, arena, state, options.write);
        },
        .finish => |value| {
            if (value.finish_reason) |reason| state.finish_reason = reason;
            if (value.message_metadata) |metadata| {
                try updateMetadata(arena, state, metadata, options);
                try emit(io, arena, state, options.write);
            }
        },
        .message_metadata => |value| {
            try updateMetadata(arena, state, value.message_metadata, options);
            try emit(io, arena, state, options.write);
        },
        .err => |value| if (options.on_error) |handler| handler.call(value.error_text),
        .abort => {},
    }
}

pub const Processor = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    input: stream_api.ChunkStream,
    state: StreamingState,
    options: Options,
    input_deinitialized: bool = false,

    pub fn create(
        gpa: Allocator,
        input: stream_api.ChunkStream,
        last_message: ?messages.UIMessage,
        message_id: []const u8,
        options: Options,
    ) !*Processor {
        const self = try gpa.create(Processor);
        self.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .input = input,
            .state = undefined,
            .options = options,
        };
        errdefer {
            self.arena_state.deinit();
            gpa.destroy(self);
        }
        self.state = try .init(self.arena_state.allocator(), last_message, message_id);
        return self;
    }

    pub fn stream(self: *Processor) stream_api.ChunkStream {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: stream_api.ChunkStream.VTable = .{
        .next = next,
        .deinit = deinit,
        .cancel = cancel,
    };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *Processor = @ptrCast(@alignCast(raw));
        const chunk = (try self.input.next(io)) orelse return null;
        try applyChunk(io, self.arena_state.allocator(), &self.state, chunk, self.options);
        return chunk;
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *Processor = @ptrCast(@alignCast(raw));
        self.input.cancel(io);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *Processor = @ptrCast(@alignCast(raw));
        if (!self.input_deinitialized) self.input.deinit(io);
        self.state.deinit(self.arena_state.allocator());
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

pub fn processUIMessageStream(
    gpa: Allocator,
    input: stream_api.ChunkStream,
    last_message: ?messages.UIMessage,
    message_id: []const u8,
    options: Options,
) !stream_api.ChunkStream {
    const processor = try Processor.create(gpa, input, last_message, message_id, options);
    return processor.stream();
}

pub const MessageStream = struct {
    ctx: *ReadState,

    pub fn next(self: MessageStream, io: std.Io) anyerror!?messages.UIMessage {
        while (true) {
            self.ctx.pending = null;
            const chunk = try self.ctx.processor_stream.next(io);
            if (self.ctx.pending) |snapshot| return snapshot;
            if (chunk == null) return null;
        }
    }

    pub fn deinit(self: MessageStream, io: std.Io) void {
        self.ctx.processor_stream.deinit(io);
        self.ctx.gpa.destroy(self.ctx);
    }
};

const ReadState = struct {
    gpa: Allocator,
    processor_stream: stream_api.ChunkStream,
    pending: ?messages.UIMessage = null,

    fn write(raw: ?*anyopaque, _: std.Io, snapshot: messages.UIMessage) anyerror!void {
        const self: *ReadState = @ptrCast(@alignCast(raw.?));
        self.pending = snapshot;
    }
};

pub fn readUIMessageStream(
    gpa: Allocator,
    input: stream_api.ChunkStream,
    message: ?messages.UIMessage,
    options: Options,
) !MessageStream {
    const read_state = try gpa.create(ReadState);
    errdefer gpa.destroy(read_state);
    var processor_options = options;
    processor_options.write = .{ .ctx = read_state, .call_fn = ReadState.write };
    const processor = try Processor.create(
        gpa,
        input,
        message,
        if (message) |existing| existing.id else "",
        processor_options,
    );
    read_state.* = .{
        .gpa = gpa,
        .processor_stream = processor.stream(),
    };
    return .{ .ctx = read_state };
}

const ToolUpdate = struct {
    dynamic: bool,
    name: []const u8,
    tool_call_id: []const u8,
    title: ?[]const u8 = null,
    tool_metadata: ?JsonValue = null,
    provider_executed: ?bool = null,
    state: messages.ToolState,
};

fn updateToolPart(
    arena: Allocator,
    state: *StreamingState,
    update: ToolUpdate,
) !usize {
    if (findToolIndex(state, update.tool_call_id)) |index| {
        const part = &state.parts.items[index];
        const existing_dynamic = part.* == .dynamic_tool;
        if (existing_dynamic == update.dynamic) {
            const tool = part.toolPart().?;
            tool.name = try arena.dupe(u8, update.name);
            tool.state = update.state;
            if (update.title) |title| tool.title = try arena.dupe(u8, title);
            if (update.tool_metadata) |metadata| tool.tool_metadata = try provider_utils.cloneJsonValue(arena, metadata);
            if (update.provider_executed) |provider_executed| tool.provider_executed = provider_executed;
            state.syncParts();
            return index;
        }
    }

    const tool: messages.ToolUIPart = .{
        .name = try arena.dupe(u8, update.name),
        .tool_call_id = try arena.dupe(u8, update.tool_call_id),
        .title = try cloneOptionalString(arena, update.title),
        .tool_metadata = try cloneOptionalValue(arena, update.tool_metadata),
        .provider_executed = update.provider_executed,
        .state = update.state,
    };
    try state.parts.append(arena, if (update.dynamic)
        .{ .dynamic_tool = tool }
    else
        .{ .tool = tool });
    state.syncParts();
    return state.parts.items.len - 1;
}

fn findToolIndex(state: *StreamingState, tool_call_id: []const u8) ?usize {
    for (state.parts.items, 0..) |*part, index| {
        const tool = part.toolPartConst() orelse continue;
        if (std.mem.eql(u8, tool.tool_call_id, tool_call_id)) return index;
    }
    return null;
}

fn existingToolDynamic(state: *StreamingState, tool_call_id: []const u8) ?bool {
    const index = findToolIndex(state, tool_call_id) orelse return null;
    return state.parts.items[index] == .dynamic_tool;
}

fn findToolByApprovalId(state: *StreamingState, approval_id: []const u8) ?usize {
    for (state.parts.items, 0..) |*part, index| {
        const tool = part.toolPartConst() orelse continue;
        const approval = stateApproval(tool.state) orelse continue;
        if (std.mem.eql(u8, approval.id, approval_id)) return index;
    }
    return null;
}

fn findDataPart(state: *StreamingState, name: []const u8, id: []const u8) ?usize {
    for (state.parts.items, 0..) |part, index| switch (part) {
        .data => |data| if (data.id) |part_id| {
            if (std.mem.eql(u8, data.name, name) and std.mem.eql(u8, part_id, id)) return index;
        },
        else => {},
    };
    return null;
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

fn stateRawInput(state: messages.ToolState) ?JsonValue {
    return switch (state) {
        .output_error => |value| value.raw_input,
        else => null,
    };
}

fn stateCallMetadata(state: messages.ToolState) ?provider.ProviderMetadata {
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

fn stateApproval(state: messages.ToolState) ?messages.ApprovalRequest {
    return switch (state) {
        .approval_requested => |value| value.approval,
        .approval_responded => |value| .{
            .id = value.approval.id,
            .is_automatic = value.approval.is_automatic,
            .signature = value.approval.signature,
        },
        .output_available => |value| if (value.approval) |approval| .{
            .id = approval.id,
            .is_automatic = approval.is_automatic,
            .signature = approval.signature,
        } else null,
        .output_error => |value| if (value.approval) |approval| .{
            .id = approval.id,
            .is_automatic = approval.is_automatic,
            .signature = approval.signature,
        } else null,
        .output_denied => |value| .{
            .id = value.approval.id,
            .is_automatic = value.approval.is_automatic,
            .signature = value.approval.signature,
        },
        else => null,
    };
}

fn responseApproval(state: messages.ToolState) ?messages.ApprovalResponse {
    return switch (state) {
        .approval_responded => |value| value.approval,
        .output_available => |value| value.approval,
        .output_error => |value| value.approval,
        .output_denied => |value| value.approval,
        else => null,
    };
}

fn approvedApproval(state: messages.ToolState) ?messages.ApprovalResponse {
    const approval = responseApproval(state) orelse return null;
    return if (approval.approved) approval else null;
}

fn updateMetadata(arena: Allocator, state: *StreamingState, metadata: JsonValue, options: Options) !void {
    const merged = if (state.message.metadata) |base|
        try mergeValues(arena, base, metadata)
    else
        try provider_utils.cloneJsonValue(arena, metadata);
    if (options.message_metadata_schema) |schema| try validateSchema(arena, schema, merged, options.diag);
    state.message.metadata = merged;
}

fn mergeValues(arena: Allocator, base: JsonValue, overrides: JsonValue) Allocator.Error!JsonValue {
    if (base != .object or overrides != .object) return provider_utils.cloneJsonValue(arena, overrides);
    var result: std.json.ObjectMap = .empty;
    var base_iterator = base.object.iterator();
    while (base_iterator.next()) |entry| {
        try result.put(
            arena,
            try arena.dupe(u8, entry.key_ptr.*),
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
        );
    }
    var override_iterator = overrides.object.iterator();
    while (override_iterator.next()) |entry| {
        const value = if (result.get(entry.key_ptr.*)) |existing|
            try mergeValues(arena, existing, entry.value_ptr.*)
        else
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*);
        try result.put(arena, try arena.dupe(u8, entry.key_ptr.*), value);
    }
    return .{ .object = result };
}

fn schemaFor(schemas: []const NamedSchema, name: []const u8) ?provider_utils.Schema {
    for (schemas) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.schema;
    return null;
}

fn validateSchema(
    arena: Allocator,
    schema: provider_utils.Schema,
    value: JsonValue,
    diag: ?*provider.Diagnostics,
) !void {
    const validator = schema.validator orelse {
        provider.Diagnostics.set(diag, if (diag) |value_diag| value_diag.allocator else arena, .{ .type_validation = .{
            .message = "Schema has no runtime validator",
        } });
        return error.TypeValidationError;
    };
    try validator.validate(arena, value, diag);
}

fn emit(io: std.Io, arena: Allocator, state: *StreamingState, writer: ?WriteSnapshot) !void {
    const callback = writer orelse return;
    state.syncParts();
    const snapshot = try messages.cloneMessage(arena, state.message);
    try callback.call(io, snapshot);
}

fn streamError(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    chunk_type: []const u8,
    chunk_id: []const u8,
    text: []const u8,
) provider.Error {
    const message = std.fmt.allocPrint(arena, "{s} (id: {s})", .{ text, chunk_id }) catch text;
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else arena, .{ .ui_message_stream = .{
        .message = message,
        .chunk_type = chunk_type,
        .chunk_id = chunk_id,
    } });
    return error.UIMessageStreamError;
}

fn cloneOptionalString(arena: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (value) |text| try arena.dupe(u8, text) else null;
}

fn cloneOptionalValue(arena: Allocator, value: ?JsonValue) Allocator.Error!?JsonValue {
    return if (value) |item| try provider_utils.cloneJsonValue(arena, item) else null;
}

test "processUIMessageStream enforces deltas, reparses partial tool input, data semantics, metadata, and steps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try StreamingState.init(arena, null, "generated");
    defer state.deinit(arena);

    var transient_count: usize = 0;
    const Hooks = struct {
        fn onData(raw: ?*anyopaque, _: std.Io, _: messages.DataUIPart, transient: bool) anyerror!void {
            if (transient) {
                const count: *usize = @ptrCast(@alignCast(raw.?));
                count.* += 1;
            }
        }
    };
    const options: Options = .{ .on_data = .{ .ctx = &transient_count, .call_fn = Hooks.onData } };

    try applyChunk(std.testing.io, arena, &state, .{ .start = .{ .message_id = "server" } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .start_step = .{} }, options);
    try std.testing.expect(state.message.parts[0] == .step_start);
    try applyChunk(std.testing.io, arena, &state, .{ .text_start = .{ .id = "t" } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .text_delta = .{ .id = "t", .delta = "Hi" } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .text_end = .{ .id = "t" } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_input_start = .{ .tool_call_id = "c", .tool_name = "weather" } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_input_delta = .{ .tool_call_id = "c", .input_text_delta = "{\"city\":\"N" } }, options);
    const tool_index = findToolIndex(&state, "c").?;
    try std.testing.expectEqualStrings("N", state.parts.items[tool_index].tool.state.input_streaming.input.?.object.get("city").?.string);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_input_delta = .{ .tool_call_id = "c", .input_text_delta = "YC\"}" } }, options);
    try std.testing.expectEqualStrings("NYC", state.parts.items[tool_index].tool.state.input_streaming.input.?.object.get("city").?.string);

    try applyChunk(std.testing.io, arena, &state, .{ .data = .{ .name = "status", .data = .{ .integer = 1 }, .transient = true } }, options);
    try std.testing.expectEqual(1, transient_count);
    try applyChunk(std.testing.io, arena, &state, .{ .data = .{ .name = "status", .id = "d", .data = .{ .integer = 1 } } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .data = .{ .name = "status", .id = "d", .data = .{ .integer = 2 } } }, options);
    try std.testing.expectEqual(2, state.parts.items[findDataPart(&state, "status", "d").?].data.data.integer);

    const metadata_one = try std.json.parseFromSliceLeaky(JsonValue, arena, "{\"nested\":{\"a\":1}}", .{});
    const metadata_two = try std.json.parseFromSliceLeaky(JsonValue, arena, "{\"nested\":{\"b\":2}}", .{});
    try applyChunk(std.testing.io, arena, &state, .{ .message_metadata = .{ .message_metadata = metadata_one } }, options);
    try applyChunk(std.testing.io, arena, &state, .{ .finish = .{ .finish_reason = .stop, .message_metadata = metadata_two } }, options);
    try std.testing.expectEqual(1, state.message.metadata.?.object.get("nested").?.object.get("a").?.integer);
    try std.testing.expectEqual(2, state.message.metadata.?.object.get("nested").?.object.get("b").?.integer);

    try applyChunk(std.testing.io, arena, &state, .{ .finish_step = .{} }, options);
    try std.testing.expectEqual(0, state.active_text_parts.count());
    try std.testing.expectEqual(.stop, state.finish_reason.?);

    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.UIMessageStreamError,
        applyChunk(std.testing.io, arena, &state, .{ .text_delta = .{ .id = "missing", .delta = "x" } }, .{ .diag = &diagnostics }),
    );
    try std.testing.expectEqualStrings("text-delta", diagnostics.payload.ui_message_stream.chunk_type);
}

test "processUIMessageStream covers seven tool lifecycle states and approvals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try StreamingState.init(arena, null, "m");
    defer state.deinit(arena);

    try applyChunk(std.testing.io, arena, &state, .{ .tool_input_start = .{ .tool_call_id = "c", .tool_name = "weather" } }, .{});
    try std.testing.expect(state.parts.items[0].tool.state == .input_streaming);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_input_available = .{
        .tool_call_id = "c",
        .tool_name = "weather",
        .input = .{ .string = "NYC" },
        .provider_metadata = .{ .string = "call-metadata" },
    } }, .{});
    try std.testing.expect(state.parts.items[0].tool.state == .input_available);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_approval_request = .{ .approval_id = "a", .tool_call_id = "c", .is_automatic = true, .signature = "sig" } }, .{});
    try std.testing.expect(state.parts.items[0].tool.state == .approval_requested);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_approval_response = .{ .approval_id = "a", .approved = true } }, .{});
    try std.testing.expect(state.parts.items[0].tool.state == .approval_responded);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_output_available = .{ .tool_call_id = "c", .output = .{ .string = "sunny" }, .preliminary = true } }, .{});
    try std.testing.expect(state.parts.items[0].tool.state == .output_available);
    try std.testing.expect(state.parts.items[0].tool.state.output_available.approval.?.approved);
    try std.testing.expectEqualStrings("call-metadata", state.parts.items[0].tool.state.output_available.call_provider_metadata.?.string);
    try applyChunk(std.testing.io, arena, &state, .{ .tool_output_error = .{ .tool_call_id = "c", .error_text = "late failure" } }, .{});
    try std.testing.expect(state.parts.items[0].tool.state == .output_error);
    try std.testing.expectEqualStrings("call-metadata", state.parts.items[0].tool.state.output_error.call_provider_metadata.?.string);

    try applyChunk(std.testing.io, arena, &state, .{ .tool_input_available = .{
        .tool_call_id = "d",
        .tool_name = "deny",
        .input = .null,
        .provider_metadata = .{ .string = "denied-metadata" },
    } }, .{});
    try applyChunk(std.testing.io, arena, &state, .{ .tool_approval_request = .{ .approval_id = "ad", .tool_call_id = "d" } }, .{});
    try applyChunk(std.testing.io, arena, &state, .{ .tool_approval_response = .{ .approval_id = "ad", .approved = false, .reason = "no" } }, .{});
    try applyChunk(std.testing.io, arena, &state, .{ .tool_output_denied = .{ .tool_call_id = "d" } }, .{});
    try std.testing.expect(state.parts.items[1].tool.state == .output_denied);
    try std.testing.expectEqualStrings("no", state.parts.items[1].tool.state.output_denied.approval.reason.?);
    try std.testing.expectEqualStrings("denied-metadata", state.parts.items[1].tool.state.output_denied.call_provider_metadata.?.string);
}
