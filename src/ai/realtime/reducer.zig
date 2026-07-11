//! Persistent realtime event reducer.
//!
//! `Reducer` owns every string, JSON value, UI message, and retained server
//! event exposed through `state`. Message/event slices remain valid until the
//! next method that changes those lists. Returned effects/tool-output strings
//! use scratch storage valid until the next `reduceServerEvent`,
//! `addUserTextMessage`, or `addToolOutput`. All storage is released by
//! `deinit`.
//!
//! Messages and ring entries use independent arenas. Replacing a streaming
//! message or evicting a capped event therefore releases the displaced
//! payload instead of growing a session-wide arena without bound.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const ui = @import("../ui/ui_messages.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const default_max_events: usize = 500;

pub const Status = enum {
    disconnected,
    connecting,
    connected,
    @"error",
};

pub const State = struct {
    status: Status = .disconnected,
    messages: []const ui.UIMessage = &.{},
    events: []const provider.ServerEvent = &.{},
    is_capturing: bool = false,
    is_playing: bool = false,
};

pub fn createInitialRealtimeState() State {
    return .{};
}

pub const Changes = struct {
    status: bool = false,
    messages: bool = false,
    events: bool = false,
    is_capturing: bool = false,
    is_playing: bool = false,

    pub fn any(self: Changes) bool {
        return self.status or self.messages or self.events or
            self.is_capturing or self.is_playing;
    }
};

pub const Effect = union(enum) {
    play_audio: PlayAudio,
    speech_started: void,
    tool_call: ToolCall,
    err: ErrorEffect,

    pub const PlayAudio = struct {
        item_id: []const u8,
        delta_base64: []const u8,
    };

    pub const ToolCall = struct {
        call_id: []const u8,
        name: []const u8,
        args_json: JsonValue,
        raw: []const u8,
    };

    pub const ErrorEffect = struct {
        message: []const u8,
        code: ?[]const u8 = null,
    };
};

pub const ReduceResult = struct {
    state: State,
    effects: []const Effect,
    changes: Changes,
};

pub const ToolOutput = struct {
    call_id: []const u8,
    name: ?[]const u8,
    output: []const u8,
};

pub const ToolOutputResult = struct {
    state: State,
    output: ToolOutput,
    changes: Changes,
};

const PartLocation = struct {
    message_id: []const u8,
    part_index: usize,
};

pub const Reducer = struct {
    allocator: Allocator,
    max_events: usize,
    state: State = .{},

    messages: std.ArrayList(OwnedMessage) = .empty,
    message_view: std.ArrayList(ui.UIMessage) = .empty,
    events: std.ArrayList(OwnedEvent) = .empty,
    event_view: std.ArrayList(provider.ServerEvent) = .empty,

    current_assistant_message_id: ?[]u8 = null,
    text_accumulators: OwnedStringMap = .{},
    tool_arg_accumulators: OwnedStringMap = .{},
    tool_call_id_to_message_id: OwnedStringMap = .{},
    tool_call_id_to_name: OwnedStringMap = .{},
    input_audio_message_insert_index: OwnedUsizeMap = .{},
    item_id_to_part_location: OwnedLocationMap = .{},

    effect_arena_state: std.heap.ArenaAllocator,
    effects: std.ArrayList(Effect) = .empty,
    next_message_id: u64 = 1,

    pub fn init(allocator: Allocator, max_events: usize) Reducer {
        return .{
            .allocator = allocator,
            .max_events = max_events,
            .effect_arena_state = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn initDefault(allocator: Allocator) Reducer {
        return init(allocator, default_max_events);
    }

    pub fn deinit(self: *Reducer) void {
        if (self.current_assistant_message_id) |id| self.allocator.free(id);
        self.text_accumulators.deinit(self.allocator);
        self.tool_arg_accumulators.deinit(self.allocator);
        self.tool_call_id_to_message_id.deinit(self.allocator);
        self.tool_call_id_to_name.deinit(self.allocator);
        self.input_audio_message_insert_index.deinit(self.allocator);
        self.item_id_to_part_location.deinit(self.allocator);

        for (self.messages.items) |*message| message.deinit();
        self.messages.deinit(self.allocator);
        self.message_view.deinit(self.allocator);
        for (self.events.items) |*event| event.deinit();
        self.events.deinit(self.allocator);
        self.event_view.deinit(self.allocator);

        self.effect_arena_state.deinit();
        self.effects.deinit(self.allocator);
        self.* = undefined;
    }

    /// Deep-clones the public state into caller-owned storage. The caller must
    /// serialize this read with reducer mutations; the returned snapshot then
    /// remains valid independently of later mutations and reducer teardown for
    /// as long as `arena` remains valid.
    pub fn snapshot(self: *const Reducer, arena: Allocator) !State {
        return self.snapshotChanges(arena, .{ .messages = true, .events = true });
    }

    /// Clones only collection fields selected by `changes`; unselected
    /// collections are empty and never borrow reducer storage. Scalar fields
    /// are always copied. This is the efficient publication path for per-key
    /// callbacks.
    pub fn snapshotChanges(
        self: *const Reducer,
        arena: Allocator,
        changes: Changes,
    ) !State {
        const messages = if (changes.messages) blk: {
            const cloned = try arena.alloc(ui.UIMessage, self.state.messages.len);
            for (self.state.messages, cloned) |message, *destination| {
                destination.* = try cloneReducerMessage(arena, message);
            }
            break :blk cloned;
        } else &.{};

        const events = if (changes.events) blk: {
            const cloned = try arena.alloc(provider.ServerEvent, self.state.events.len);
            for (self.state.events, cloned) |event, *destination| {
                destination.* = try cloneServerEvent(arena, event);
            }
            break :blk cloned;
        } else &.{};

        return .{
            .status = self.state.status,
            .messages = messages,
            .events = events,
            .is_capturing = self.state.is_capturing,
            .is_playing = self.state.is_playing,
        };
    }

    pub fn setStatus(self: *Reducer, status: Status) bool {
        if (self.state.status == status) return false;
        self.state.status = status;
        return true;
    }

    pub fn setCapturing(self: *Reducer, is_capturing: bool) bool {
        if (self.state.is_capturing == is_capturing) return false;
        self.state.is_capturing = is_capturing;
        return true;
    }

    pub fn setPlaying(self: *Reducer, is_playing: bool) bool {
        if (self.state.is_playing == is_playing) return false;
        self.state.is_playing = is_playing;
        return true;
    }

    pub fn addUserTextMessage(self: *Reducer, text: []const u8) !Changes {
        self.beginMutation();
        const id = try self.nextMessageId("user-local");
        defer self.allocator.free(id);

        const part: ui.UIMessagePart = .{ .text = .{
            .text = text,
            .state = .done,
        } };
        try self.appendMessage(.{
            .id = id,
            .role = .user,
            .parts = &.{part},
        });
        return .{ .messages = true };
    }

    pub fn addToolOutput(
        self: *Reducer,
        call_id: []const u8,
        result: JsonValue,
    ) !ToolOutputResult {
        self.beginMutation();
        const changed = try self.updateToolPartState(call_id, result);
        const effect_arena = self.effect_arena_state.allocator();
        const name = if (self.tool_call_id_to_name.get(call_id)) |value|
            try effect_arena.dupe(u8, value)
        else
            null;

        return .{
            .state = self.state,
            .output = .{
                .call_id = try effect_arena.dupe(u8, call_id),
                .name = name,
                .output = try provider_utils.stringifyJsonValueAlloc(effect_arena, result),
            },
            .changes = .{ .messages = changed },
        };
    }

    pub fn reduceServerEvent(
        self: *Reducer,
        event: provider.ServerEvent,
    ) !ReduceResult {
        self.beginMutation();
        var changes: Changes = .{};
        changes.events = try self.pushEvent(event);

        switch (event) {
            .session_created, .session_updated => {
                if (self.state.status == .connecting) {
                    self.state.status = .connected;
                    changes.status = true;
                }
            },
            .audio_delta => |value| {
                const arena = self.effect_arena_state.allocator();
                try self.effects.append(self.allocator, .{ .play_audio = .{
                    .item_id = try arena.dupe(u8, value.item_id),
                    .delta_base64 = try arena.dupe(u8, value.delta),
                } });
            },
            .audio_committed => |value| {
                if (value.item_id) |item_id| {
                    try self.input_audio_message_insert_index.put(
                        self.allocator,
                        item_id,
                        self.messages.items.len,
                    );
                }
            },
            .audio_transcript_delta, .text_delta => |value| {
                changes.messages = try self.appendTextDelta(value.item_id, value.delta);
            },
            .audio_transcript_done => |value| {
                changes.messages = try self.finalizeText(value.item_id, value.transcript);
            },
            .text_done => |value| {
                changes.messages = try self.finalizeText(value.item_id, value.text);
            },
            .input_transcription_completed => |value| {
                changes.messages = try self.addInputTranscriptionMessage(
                    value.item_id,
                    value.transcript,
                );
            },
            .response_created, .response_done => self.clearCurrentAssistantMessage(),
            .speech_started => {
                self.clearCurrentAssistantMessage();
                try self.effects.append(self.allocator, .{ .speech_started = {} });
            },
            .function_call_arguments_delta => |value| {
                const message_id = try self.getOrCreateAssistantMessage();
                try self.tool_call_id_to_message_id.put(
                    self.allocator,
                    value.call_id,
                    message_id,
                );
                try self.tool_arg_accumulators.append(
                    self.allocator,
                    value.call_id,
                    value.delta,
                );
                _ = try self.ensureToolPart(message_id, value.call_id);
                // Upstream rebuilds the messages array for every argument
                // delta, even after the placeholder tool part exists. Keep
                // that publication cadence for per-key state callbacks.
                changes.messages = true;
            },
            .function_call_arguments_done => |value| {
                try self.tool_call_id_to_name.put(
                    self.allocator,
                    value.call_id,
                    value.name,
                );

                const effect_arena = self.effect_arena_state.allocator();
                const parsed: ?JsonValue = std.json.parseFromSliceLeaky(
                    JsonValue,
                    effect_arena,
                    value.arguments,
                    .{ .allocate = .alloc_always },
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => null,
                };
                const input: JsonValue = parsed orelse .{ .object = .empty };

                if (self.tool_call_id_to_message_id.get(value.call_id)) |message_id| {
                    changes.messages = try self.markToolInputAvailable(
                        message_id,
                        value.call_id,
                        value.name,
                        input,
                    );
                }
                self.tool_arg_accumulators.remove(self.allocator, value.call_id);

                if (parsed) |args| {
                    try self.effects.append(self.allocator, .{ .tool_call = .{
                        .call_id = try effect_arena.dupe(u8, value.call_id),
                        .name = try effect_arena.dupe(u8, value.name),
                        .args_json = args,
                        .raw = try effect_arena.dupe(u8, value.arguments),
                    } });
                } else {
                    try self.effects.append(self.allocator, .{ .err = .{
                        .message = try std.fmt.allocPrint(
                            effect_arena,
                            "Failed to parse tool arguments: {s}",
                            .{value.arguments},
                        ),
                    } });
                }
            },
            .err => |value| {
                const arena = self.effect_arena_state.allocator();
                try self.effects.append(self.allocator, .{ .err = .{
                    .message = try arena.dupe(u8, value.message),
                    .code = if (value.code) |code| try arena.dupe(u8, code) else null,
                } });
            },
            .speech_stopped,
            .conversation_item_added,
            .output_item_added,
            .output_item_done,
            .content_part_added,
            .content_part_done,
            .audio_done,
            .custom,
            => {},
        }

        return .{
            .state = self.state,
            .effects = self.effects.items,
            .changes = changes,
        };
    }

    fn beginMutation(self: *Reducer) void {
        _ = self.effect_arena_state.reset(.retain_capacity);
        self.effects.clearRetainingCapacity();
    }

    fn pushEvent(self: *Reducer, event: provider.ServerEvent) !bool {
        if (self.max_events == 0) return false;

        const next_len = @min(self.events.items.len + 1, self.max_events);
        try self.events.ensureTotalCapacity(self.allocator, next_len);
        try self.event_view.ensureTotalCapacity(self.allocator, next_len);
        var owned = try OwnedEvent.init(self.allocator, event);
        errdefer owned.deinit();

        if (self.events.items.len == self.max_events) {
            var removed = self.events.orderedRemove(0);
            removed.deinit();
        }
        self.events.appendAssumeCapacity(owned);
        self.refreshEventView();
        return true;
    }

    fn refreshEventView(self: *Reducer) void {
        self.event_view.clearRetainingCapacity();
        for (self.events.items) |entry| self.event_view.appendAssumeCapacity(entry.value);
        self.state.events = self.event_view.items;
    }

    fn refreshMessageView(self: *Reducer) void {
        self.message_view.clearRetainingCapacity();
        for (self.messages.items) |entry| self.message_view.appendAssumeCapacity(entry.value);
        self.state.messages = self.message_view.items;
    }

    fn nextMessageId(self: *Reducer, prefix: []const u8) ![]u8 {
        const id = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{d}",
            .{ prefix, self.next_message_id },
        );
        self.next_message_id += 1;
        return id;
    }

    fn clearCurrentAssistantMessage(self: *Reducer) void {
        if (self.current_assistant_message_id) |id| self.allocator.free(id);
        self.current_assistant_message_id = null;
    }

    fn getOrCreateAssistantMessage(self: *Reducer) ![]const u8 {
        if (self.current_assistant_message_id) |id| return id;

        const id = try self.nextMessageId("assistant");
        defer self.allocator.free(id);
        var message = try OwnedMessage.init(self.allocator, .{
            .id = id,
            .role = .assistant,
            .parts = &.{},
        });
        errdefer message.deinit();
        const current_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(current_id);

        try self.messages.ensureTotalCapacity(self.allocator, self.messages.items.len + 1);
        try self.message_view.ensureTotalCapacity(self.allocator, self.messages.items.len + 1);
        self.messages.appendAssumeCapacity(message);
        self.current_assistant_message_id = current_id;
        self.refreshMessageView();
        return current_id;
    }

    fn appendMessage(self: *Reducer, source: ui.UIMessage) !void {
        try self.messages.ensureTotalCapacity(self.allocator, self.messages.items.len + 1);
        try self.message_view.ensureTotalCapacity(self.allocator, self.messages.items.len + 1);
        var message = try OwnedMessage.init(self.allocator, source);
        errdefer message.deinit();
        self.messages.appendAssumeCapacity(message);
        self.refreshMessageView();
    }

    fn insertMessage(self: *Reducer, index: usize, source: ui.UIMessage) !void {
        try self.messages.ensureTotalCapacity(self.allocator, self.messages.items.len + 1);
        try self.message_view.ensureTotalCapacity(self.allocator, self.messages.items.len + 1);
        var message = try OwnedMessage.init(self.allocator, source);
        errdefer message.deinit();
        try self.messages.insert(self.allocator, index, message);
        self.refreshMessageView();
    }

    fn replaceMessage(self: *Reducer, index: usize, source: ui.UIMessage) !void {
        var replacement = try OwnedMessage.init(self.allocator, source);
        errdefer replacement.deinit();
        var previous = self.messages.items[index];
        self.messages.items[index] = replacement;
        previous.deinit();
        self.refreshMessageView();
    }

    fn findMessageIndex(self: *const Reducer, message_id: []const u8) ?usize {
        for (self.messages.items, 0..) |message, index| {
            if (std.mem.eql(u8, message.value.id, message_id)) return index;
        }
        return null;
    }

    fn addInputTranscriptionMessage(
        self: *Reducer,
        item_id: []const u8,
        transcript: []const u8,
    ) !bool {
        const message_id = try std.fmt.allocPrint(self.allocator, "user-{s}", .{item_id});
        defer self.allocator.free(message_id);
        const part: ui.UIMessagePart = .{ .text = .{
            .text = transcript,
            .state = .done,
        } };
        const source: ui.UIMessage = .{
            .id = message_id,
            .role = .user,
            .parts = &.{part},
        };

        if (self.findMessageIndex(message_id)) |index| {
            try self.replaceMessage(index, source);
            return true;
        }

        const recorded_index = self.input_audio_message_insert_index.get(item_id) orelse
            self.messages.items.len;
        try self.insertMessage(@min(recorded_index, self.messages.items.len), source);
        return true;
    }

    fn appendTextDelta(
        self: *Reducer,
        item_id: []const u8,
        delta: []const u8,
    ) !bool {
        const message_id = try self.getOrCreateAssistantMessage();
        try self.text_accumulators.append(self.allocator, item_id, delta);
        const text = self.text_accumulators.get(item_id).?;
        const part: ui.UIMessagePart = .{ .text = .{
            .text = text,
            .state = .streaming,
        } };

        if (self.item_id_to_part_location.get(item_id)) |location| {
            return self.replaceMessagePart(
                location.message_id,
                location.part_index,
                part,
            );
        }

        const message_index = self.findMessageIndex(message_id) orelse return false;
        const part_index = self.messages.items[message_index].value.parts.len;
        try self.item_id_to_part_location.put(self.allocator, item_id, .{
            .message_id = message_id,
            .part_index = part_index,
        });
        errdefer self.item_id_to_part_location.remove(self.allocator, item_id);
        return self.appendMessagePart(message_id, part);
    }

    fn finalizeText(
        self: *Reducer,
        item_id: []const u8,
        final_text: ?[]const u8,
    ) !bool {
        const text = final_text orelse self.text_accumulators.get(item_id) orelse "";
        const location = self.item_id_to_part_location.get(item_id) orelse {
            self.text_accumulators.remove(self.allocator, item_id);
            return false;
        };
        const part: ui.UIMessagePart = .{ .text = .{
            .text = text,
            .state = .done,
        } };
        const changed = try self.replaceMessagePart(
            location.message_id,
            location.part_index,
            part,
        );
        self.text_accumulators.remove(self.allocator, item_id);
        self.item_id_to_part_location.remove(self.allocator, item_id);
        return changed;
    }

    fn appendMessagePart(
        self: *Reducer,
        message_id: []const u8,
        part: ui.UIMessagePart,
    ) !bool {
        const index = self.findMessageIndex(message_id) orelse return false;
        const message = self.messages.items[index].value;
        const parts = try self.allocator.alloc(ui.UIMessagePart, message.parts.len + 1);
        defer self.allocator.free(parts);
        @memcpy(parts[0..message.parts.len], message.parts);
        parts[message.parts.len] = part;
        try self.replaceMessage(index, .{
            .id = message.id,
            .role = message.role,
            .metadata = message.metadata,
            .parts = parts,
        });
        return true;
    }

    fn replaceMessagePart(
        self: *Reducer,
        message_id: []const u8,
        part_index: usize,
        part: ui.UIMessagePart,
    ) !bool {
        const index = self.findMessageIndex(message_id) orelse return false;
        const message = self.messages.items[index].value;
        if (part_index >= message.parts.len) return false;
        const parts = try self.allocator.dupe(ui.UIMessagePart, message.parts);
        defer self.allocator.free(parts);
        parts[part_index] = part;
        try self.replaceMessage(index, .{
            .id = message.id,
            .role = message.role,
            .metadata = message.metadata,
            .parts = parts,
        });
        return true;
    }

    fn ensureToolPart(
        self: *Reducer,
        message_id: []const u8,
        call_id: []const u8,
    ) !bool {
        const index = self.findMessageIndex(message_id) orelse return false;
        for (self.messages.items[index].value.parts) |part| switch (part) {
            .dynamic_tool => |tool_part| {
                if (std.mem.eql(u8, tool_part.tool_call_id, call_id)) return false;
            },
            else => {},
        };

        return self.appendMessagePart(message_id, .{ .dynamic_tool = .{
            .name = "",
            .tool_call_id = call_id,
            .state = .{ .input_streaming = .{} },
        } });
    }

    fn markToolInputAvailable(
        self: *Reducer,
        message_id: []const u8,
        call_id: []const u8,
        name: []const u8,
        input: JsonValue,
    ) !bool {
        const index = self.findMessageIndex(message_id) orelse return false;
        const message = self.messages.items[index].value;
        for (message.parts, 0..) |part, part_index| switch (part) {
            .dynamic_tool => |tool_part| {
                if (!std.mem.eql(u8, tool_part.tool_call_id, call_id)) continue;
                var updated = tool_part;
                updated.name = name;
                updated.state = .{ .input_available = .{ .input = input } };
                return self.replaceMessagePart(
                    message_id,
                    part_index,
                    .{ .dynamic_tool = updated },
                );
            },
            else => {},
        };
        return false;
    }

    fn updateToolPartState(
        self: *Reducer,
        call_id: []const u8,
        output: JsonValue,
    ) !bool {
        const message_id = self.tool_call_id_to_message_id.get(call_id) orelse return false;
        const index = self.findMessageIndex(message_id) orelse return false;
        const message = self.messages.items[index].value;
        for (message.parts, 0..) |part, part_index| switch (part) {
            .dynamic_tool => |tool_part| {
                if (!std.mem.eql(u8, tool_part.tool_call_id, call_id)) continue;
                const input: JsonValue = switch (tool_part.state) {
                    .input_available => |state| state.input,
                    .output_available => |state| state.input,
                    .approval_requested => |state| state.input,
                    .approval_responded => |state| state.input,
                    .output_denied => |state| state.input,
                    .input_streaming => |state| state.input orelse .null,
                    .output_error => |state| state.input orelse .null,
                };
                var updated = tool_part;
                updated.state = .{ .output_available = .{
                    .input = input,
                    .output = output,
                } };
                return self.replaceMessagePart(
                    message_id,
                    part_index,
                    .{ .dynamic_tool = updated },
                );
            },
            else => {},
        };
        return false;
    }
};

const OwnedMessage = struct {
    arena_state: std.heap.ArenaAllocator,
    value: ui.UIMessage,

    fn init(allocator: Allocator, source: ui.UIMessage) !OwnedMessage {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const value = try cloneReducerMessage(arena, source);
        return .{
            .arena_state = arena_state,
            .value = value,
        };
    }

    fn deinit(self: *OwnedMessage) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

fn cloneReducerMessage(arena: Allocator, source: ui.UIMessage) !ui.UIMessage {
    const parts = try arena.alloc(ui.UIMessagePart, source.parts.len);
    for (source.parts, parts) |part, *destination| {
        destination.* = try cloneReducerPart(arena, part);
    }
    return .{
        .id = try arena.dupe(u8, source.id),
        .role = source.role,
        .metadata = if (source.metadata) |metadata|
            try provider_utils.cloneJsonValue(arena, metadata)
        else
            null,
        .parts = parts,
    };
}

fn cloneReducerPart(arena: Allocator, part: ui.UIMessagePart) !ui.UIMessagePart {
    return switch (part) {
        .text => |value| .{ .text = .{
            .text = try arena.dupe(u8, value.text),
            .state = value.state,
            .provider_metadata = if (value.provider_metadata) |metadata|
                try provider_utils.cloneJsonValue(arena, metadata)
            else
                null,
        } },
        .dynamic_tool => |value| .{ .dynamic_tool = try cloneToolPart(arena, value) },
        // Reducer-created messages contain only text and dynamic tool parts.
        // Keeping this invariant explicit prevents silently shallow-cloning a
        // future UI part that would outlive its source arena.
        else => unreachable,
    };
}

fn cloneToolPart(arena: Allocator, source: ui.ToolUIPart) !ui.ToolUIPart {
    return .{
        .name = try arena.dupe(u8, source.name),
        .tool_call_id = try arena.dupe(u8, source.tool_call_id),
        .title = if (source.title) |value| try arena.dupe(u8, value) else null,
        .tool_metadata = if (source.tool_metadata) |value|
            try provider_utils.cloneJsonValue(arena, value)
        else
            null,
        .provider_executed = source.provider_executed,
        .state = try cloneToolState(arena, source.state),
    };
}

fn cloneToolState(arena: Allocator, source: ui.ToolState) !ui.ToolState {
    return switch (source) {
        .input_streaming => |value| .{ .input_streaming = .{
            .input = if (value.input) |input|
                try provider_utils.cloneJsonValue(arena, input)
            else
                null,
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
        } },
        .input_available => |value| .{ .input_available = .{
            .input = try provider_utils.cloneJsonValue(arena, value.input),
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
        } },
        .approval_requested => |value| .{ .approval_requested = .{
            .input = try provider_utils.cloneJsonValue(arena, value.input),
            .approval = try cloneApprovalRequest(arena, value.approval),
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
        } },
        .approval_responded => |value| .{ .approval_responded = .{
            .input = try provider_utils.cloneJsonValue(arena, value.input),
            .approval = try cloneApprovalResponse(arena, value.approval),
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
        } },
        .output_available => |value| .{ .output_available = .{
            .input = try provider_utils.cloneJsonValue(arena, value.input),
            .output = try provider_utils.cloneJsonValue(arena, value.output),
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
            .result_provider_metadata = try cloneOptionalJson(arena, value.result_provider_metadata),
            .preliminary = value.preliminary,
            .approval = if (value.approval) |approval|
                try cloneApprovalResponse(arena, approval)
            else
                null,
        } },
        .output_error => |value| .{ .output_error = .{
            .input = try cloneOptionalJson(arena, value.input),
            .raw_input = try cloneOptionalJson(arena, value.raw_input),
            .error_text = try arena.dupe(u8, value.error_text),
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
            .result_provider_metadata = try cloneOptionalJson(arena, value.result_provider_metadata),
            .approval = if (value.approval) |approval|
                try cloneApprovalResponse(arena, approval)
            else
                null,
        } },
        .output_denied => |value| .{ .output_denied = .{
            .input = try provider_utils.cloneJsonValue(arena, value.input),
            .approval = try cloneApprovalResponse(arena, value.approval),
            .call_provider_metadata = try cloneOptionalJson(arena, value.call_provider_metadata),
        } },
    };
}

fn cloneOptionalJson(arena: Allocator, value: ?JsonValue) !?JsonValue {
    return if (value) |item| try provider_utils.cloneJsonValue(arena, item) else null;
}

fn cloneApprovalRequest(arena: Allocator, value: ui.ApprovalRequest) !ui.ApprovalRequest {
    return .{
        .id = try arena.dupe(u8, value.id),
        .is_automatic = value.is_automatic,
        .signature = if (value.signature) |item| try arena.dupe(u8, item) else null,
    };
}

fn cloneApprovalResponse(arena: Allocator, value: ui.ApprovalResponse) !ui.ApprovalResponse {
    return .{
        .id = try arena.dupe(u8, value.id),
        .approved = value.approved,
        .reason = if (value.reason) |item| try arena.dupe(u8, item) else null,
        .is_automatic = value.is_automatic,
        .signature = if (value.signature) |item| try arena.dupe(u8, item) else null,
    };
}

const OwnedEvent = struct {
    arena_state: std.heap.ArenaAllocator,
    value: provider.ServerEvent,

    fn init(allocator: Allocator, source: provider.ServerEvent) !OwnedEvent {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const value = try cloneServerEvent(arena_state.allocator(), source);
        return .{
            .arena_state = arena_state,
            .value = value,
        };
    }

    fn deinit(self: *OwnedEvent) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

fn cloneServerEvent(arena: Allocator, source: provider.ServerEvent) !provider.ServerEvent {
    return switch (source) {
        .session_created => |value| .{ .session_created = .{
            .session_id = try cloneOptionalString(arena, value.session_id),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .session_updated => |value| .{ .session_updated = .{
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .speech_started => |value| .{ .speech_started = .{
            .item_id = try cloneOptionalString(arena, value.item_id),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .speech_stopped => |value| .{ .speech_stopped = .{
            .item_id = try cloneOptionalString(arena, value.item_id),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .audio_committed => |value| .{ .audio_committed = .{
            .item_id = try cloneOptionalString(arena, value.item_id),
            .previous_item_id = try cloneOptionalString(arena, value.previous_item_id),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .conversation_item_added => |value| .{ .conversation_item_added = .{
            .item_id = try arena.dupe(u8, value.item_id),
            .item = try provider_utils.cloneJsonValue(arena, value.item),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .input_transcription_completed => |value| .{ .input_transcription_completed = .{
            .item_id = try arena.dupe(u8, value.item_id),
            .transcript = try arena.dupe(u8, value.transcript),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .response_created => |value| .{ .response_created = .{
            .response_id = try arena.dupe(u8, value.response_id),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .response_done => |value| .{ .response_done = .{
            .response_id = try arena.dupe(u8, value.response_id),
            .status = try arena.dupe(u8, value.status),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .output_item_added => |value| .{ .output_item_added = try cloneItemEvent(arena, value) },
        .output_item_done => |value| .{ .output_item_done = try cloneItemEvent(arena, value) },
        .content_part_added => |value| .{ .content_part_added = try cloneItemEvent(arena, value) },
        .content_part_done => |value| .{ .content_part_done = try cloneItemEvent(arena, value) },
        .audio_delta => |value| .{ .audio_delta = try cloneDeltaEvent(arena, value) },
        .audio_done => |value| .{ .audio_done = try cloneItemEvent(arena, value) },
        .audio_transcript_delta => |value| .{ .audio_transcript_delta = try cloneDeltaEvent(arena, value) },
        .audio_transcript_done => |value| .{ .audio_transcript_done = .{
            .response_id = try arena.dupe(u8, value.response_id),
            .item_id = try arena.dupe(u8, value.item_id),
            .transcript = try cloneOptionalString(arena, value.transcript),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .text_delta => |value| .{ .text_delta = try cloneDeltaEvent(arena, value) },
        .text_done => |value| .{ .text_done = .{
            .response_id = try arena.dupe(u8, value.response_id),
            .item_id = try arena.dupe(u8, value.item_id),
            .text = try cloneOptionalString(arena, value.text),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .function_call_arguments_delta => |value| .{ .function_call_arguments_delta = .{
            .response_id = try arena.dupe(u8, value.response_id),
            .item_id = try arena.dupe(u8, value.item_id),
            .call_id = try arena.dupe(u8, value.call_id),
            .delta = try arena.dupe(u8, value.delta),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .function_call_arguments_done => |value| .{ .function_call_arguments_done = .{
            .response_id = try arena.dupe(u8, value.response_id),
            .item_id = try arena.dupe(u8, value.item_id),
            .call_id = try arena.dupe(u8, value.call_id),
            .name = try arena.dupe(u8, value.name),
            .arguments = try arena.dupe(u8, value.arguments),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .err => |value| .{ .err = .{
            .message = try arena.dupe(u8, value.message),
            .code = try cloneOptionalString(arena, value.code),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
        .custom => |value| .{ .custom = .{
            .raw_type = try arena.dupe(u8, value.raw_type),
            .raw = try provider_utils.cloneJsonValue(arena, value.raw),
        } },
    };
}

fn cloneItemEvent(arena: Allocator, value: provider.ServerEvent.ItemEvent) !provider.ServerEvent.ItemEvent {
    return .{
        .response_id = try arena.dupe(u8, value.response_id),
        .item_id = try arena.dupe(u8, value.item_id),
        .raw = try provider_utils.cloneJsonValue(arena, value.raw),
    };
}

fn cloneDeltaEvent(arena: Allocator, value: provider.ServerEvent.DeltaEvent) !provider.ServerEvent.DeltaEvent {
    return .{
        .response_id = try arena.dupe(u8, value.response_id),
        .item_id = try arena.dupe(u8, value.item_id),
        .delta = try arena.dupe(u8, value.delta),
        .raw = try provider_utils.cloneJsonValue(arena, value.raw),
    };
}

fn cloneOptionalString(arena: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |item| try arena.dupe(u8, item) else null;
}

const OwnedStringMap = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(self: *OwnedStringMap, allocator: Allocator) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(allocator);
    }

    fn get(self: *const OwnedStringMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    fn put(
        self: *OwnedStringMap,
        allocator: Allocator,
        key: []const u8,
        value: []const u8,
    ) !void {
        if (self.map.getPtr(key)) |existing| {
            const replacement = try allocator.dupe(u8, value);
            allocator.free(existing.*);
            existing.* = replacement;
            return;
        }

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        try self.map.put(allocator, owned_key, owned_value);
    }

    fn append(
        self: *OwnedStringMap,
        allocator: Allocator,
        key: []const u8,
        suffix: []const u8,
    ) !void {
        if (self.map.getPtr(key)) |existing| {
            const old_len = existing.*.len;
            existing.* = try allocator.realloc(existing.*, old_len + suffix.len);
            @memcpy(existing.*[old_len..], suffix);
            return;
        }
        try self.put(allocator, key, suffix);
    }

    fn remove(self: *OwnedStringMap, allocator: Allocator, key: []const u8) void {
        const removed = self.map.fetchRemove(key) orelse return;
        allocator.free(removed.key);
        allocator.free(removed.value);
    }
};

const OwnedUsizeMap = struct {
    map: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *OwnedUsizeMap, allocator: Allocator) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.map.deinit(allocator);
    }

    fn get(self: *const OwnedUsizeMap, key: []const u8) ?usize {
        return self.map.get(key);
    }

    fn put(
        self: *OwnedUsizeMap,
        allocator: Allocator,
        key: []const u8,
        value: usize,
    ) !void {
        if (self.map.getPtr(key)) |existing| {
            existing.* = value;
            return;
        }
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        try self.map.put(allocator, owned_key, value);
    }
};

const OwnedLocationMap = struct {
    map: std.StringHashMapUnmanaged(PartLocation) = .empty,

    fn deinit(self: *OwnedLocationMap, allocator: Allocator) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.message_id);
        }
        self.map.deinit(allocator);
    }

    fn get(self: *const OwnedLocationMap, key: []const u8) ?PartLocation {
        return self.map.get(key);
    }

    fn put(
        self: *OwnedLocationMap,
        allocator: Allocator,
        key: []const u8,
        value: PartLocation,
    ) !void {
        if (self.map.getPtr(key)) |existing| {
            const message_id = try allocator.dupe(u8, value.message_id);
            allocator.free(existing.message_id);
            existing.* = .{
                .message_id = message_id,
                .part_index = value.part_index,
            };
            return;
        }

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const message_id = try allocator.dupe(u8, value.message_id);
        errdefer allocator.free(message_id);
        try self.map.put(allocator, owned_key, .{
            .message_id = message_id,
            .part_index = value.part_index,
        });
    }

    fn remove(self: *OwnedLocationMap, allocator: Allocator, key: []const u8) void {
        const removed = self.map.fetchRemove(key) orelse return;
        allocator.free(removed.key);
        allocator.free(removed.value.message_id);
    }
};

fn textDelta(item_id: []const u8, delta: []const u8) provider.ServerEvent {
    return .{ .text_delta = .{
        .response_id = "response-1",
        .item_id = item_id,
        .delta = delta,
        .raw = .null,
    } };
}

fn textDone(item_id: []const u8, text: ?[]const u8) provider.ServerEvent {
    return .{ .text_done = .{
        .response_id = "response-1",
        .item_id = item_id,
        .text = text,
        .raw = .null,
    } };
}

test "initial state and explicit setters report only real changes" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    try std.testing.expectEqual(Status.disconnected, reducer.state.status);
    try std.testing.expectEqual(@as(usize, 0), reducer.state.messages.len);
    try std.testing.expect(!reducer.setStatus(.disconnected));
    try std.testing.expect(reducer.setStatus(.connecting));
    try std.testing.expect(reducer.setCapturing(true));
    try std.testing.expect(!reducer.setCapturing(true));
    try std.testing.expect(reducer.setPlaying(true));
    try std.testing.expect(reducer.state.is_capturing);
    try std.testing.expect(reducer.state.is_playing);
}

test "deep snapshots outlive reducer mutation and teardown" {
    var reducer = Reducer.init(std.testing.allocator, 1);
    var reducer_live = true;
    defer if (reducer_live) reducer.deinit();
    _ = reducer.setStatus(.connected);
    _ = reducer.setCapturing(true);
    _ = reducer.setPlaying(true);
    _ = try reducer.reduceServerEvent(textDelta("item-1", "stable"));

    var snapshot_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer snapshot_arena_state.deinit();
    const snapshot_arena = snapshot_arena_state.allocator();
    const full = try reducer.snapshot(snapshot_arena);
    const messages_only = try reducer.snapshotChanges(snapshot_arena, .{ .messages = true });
    const events_only = try reducer.snapshotChanges(snapshot_arena, .{ .events = true });

    try std.testing.expectEqual(@as(usize, 0), messages_only.events.len);
    try std.testing.expectEqual(@as(usize, 0), events_only.messages.len);

    // Replaces the message arena and evicts the retained event arena.
    _ = try reducer.reduceServerEvent(textDelta("item-1", "-mutated"));
    reducer.deinit();
    reducer_live = false;

    try std.testing.expectEqual(Status.connected, full.status);
    try std.testing.expect(full.is_capturing);
    try std.testing.expect(full.is_playing);
    try std.testing.expectEqual(@as(usize, 1), full.messages.len);
    try expectTextPart(full.messages[0].parts[0], "stable", .streaming);
    try expectTextPart(messages_only.messages[0].parts[0], "stable", .streaming);
    switch (full.events[0]) {
        .text_delta => |event| try std.testing.expectEqualStrings("stable", event.delta),
        else => return error.UnexpectedEvent,
    }
    switch (events_only.events[0]) {
        .text_delta => |event| try std.testing.expectEqualStrings("stable", event.delta),
        else => return error.UnexpectedEvent,
    }
}

test "session events connect only a connecting reducer" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();
    _ = reducer.setStatus(.connecting);

    const created = try reducer.reduceServerEvent(.{ .session_created = .{
        .session_id = "session-1",
        .raw = .null,
    } });
    try std.testing.expectEqual(Status.connected, created.state.status);
    try std.testing.expect(created.changes.status);

    _ = reducer.setStatus(.@"error");
    const updated = try reducer.reduceServerEvent(.{ .session_updated = .{ .raw = .null } });
    try std.testing.expectEqual(Status.@"error", updated.state.status);
    try std.testing.expect(!updated.changes.status);
}

test "text and transcript deltas assemble and finalize independent parts" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    _ = try reducer.reduceServerEvent(textDelta("text-item", "Hel"));
    var result = try reducer.reduceServerEvent(textDelta("text-item", "lo"));
    try std.testing.expectEqual(@as(usize, 1), result.state.messages.len);
    try std.testing.expectEqual(@as(usize, 1), result.state.messages[0].parts.len);
    try expectTextPart(result.state.messages[0].parts[0], "Hello", .streaming);

    _ = try reducer.reduceServerEvent(.{ .audio_transcript_delta = .{
        .response_id = "response-1",
        .item_id = "audio-item",
        .delta = "spoken",
        .raw = .null,
    } });
    result = try reducer.reduceServerEvent(.{ .audio_transcript_done = .{
        .response_id = "response-1",
        .item_id = "audio-item",
        .transcript = null,
        .raw = .null,
    } });
    try std.testing.expectEqual(@as(usize, 2), result.state.messages[0].parts.len);
    try expectTextPart(result.state.messages[0].parts[1], "spoken", .done);

    result = try reducer.reduceServerEvent(textDone("text-item", "Hello!"));
    try expectTextPart(result.state.messages[0].parts[0], "Hello!", .done);

    result = try reducer.reduceServerEvent(textDone("missing", "ignored"));
    try std.testing.expect(!result.changes.messages);
}

test "response and speech boundaries split assistant messages" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    _ = try reducer.reduceServerEvent(textDelta("item-1", "one"));
    _ = try reducer.reduceServerEvent(.{ .response_done = .{
        .response_id = "response-1",
        .status = "completed",
        .raw = .null,
    } });
    _ = try reducer.reduceServerEvent(textDelta("item-2", "two"));
    try std.testing.expectEqual(@as(usize, 2), reducer.state.messages.len);

    const speech = try reducer.reduceServerEvent(.{ .speech_started = .{
        .item_id = "user-item",
        .raw = .null,
    } });
    try std.testing.expectEqual(@as(usize, 1), speech.effects.len);
    try std.testing.expect(speech.effects[0] == .speech_started);
    _ = try reducer.reduceServerEvent(textDelta("item-3", "three"));
    try std.testing.expectEqual(@as(usize, 3), reducer.state.messages.len);

    _ = try reducer.reduceServerEvent(.{ .response_created = .{
        .response_id = "response-2",
        .raw = .null,
    } });
    _ = try reducer.reduceServerEvent(textDelta("item-4", "four"));
    try std.testing.expectEqual(@as(usize, 4), reducer.state.messages.len);
}

test "audio effects and delayed input transcription preserve conversation order" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    _ = try reducer.reduceServerEvent(.{ .audio_committed = .{
        .item_id = "user-item-1",
        .raw = .null,
    } });
    _ = try reducer.reduceServerEvent(textDelta("assistant-item-1", "Yes."));
    _ = try reducer.reduceServerEvent(textDone("assistant-item-1", "Yes."));
    _ = try reducer.reduceServerEvent(.{ .input_transcription_completed = .{
        .item_id = "user-item-1",
        .transcript = "Can you hear me?",
        .raw = .null,
    } });
    try std.testing.expectEqual(@as(usize, 2), reducer.state.messages.len);
    try std.testing.expectEqual(ui.Role.user, reducer.state.messages[0].role);
    try std.testing.expectEqualStrings("user-user-item-1", reducer.state.messages[0].id);
    try expectTextPart(reducer.state.messages[0].parts[0], "Can you hear me?", .done);
    try std.testing.expectEqual(ui.Role.assistant, reducer.state.messages[1].role);

    _ = try reducer.reduceServerEvent(.{ .input_transcription_completed = .{
        .item_id = "user-item-1",
        .transcript = "Updated transcript",
        .raw = .null,
    } });
    try std.testing.expectEqual(@as(usize, 2), reducer.state.messages.len);
    try expectTextPart(reducer.state.messages[0].parts[0], "Updated transcript", .done);

    const audio = try reducer.reduceServerEvent(.{ .audio_delta = .{
        .response_id = "response-1",
        .item_id = "assistant-item-1",
        .delta = "cGNt",
        .raw = .null,
    } });
    switch (audio.effects[0]) {
        .play_audio => |effect| {
            try std.testing.expectEqualStrings("assistant-item-1", effect.item_id);
            try std.testing.expectEqualStrings("cGNt", effect.delta_base64);
        },
        else => return error.UnexpectedEffect,
    }
}

test "local user messages are done text messages with monotonic ids" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    const first = try reducer.addUserTextMessage("first");
    try std.testing.expect(first.messages);
    _ = try reducer.addUserTextMessage("second");
    try std.testing.expectEqualStrings("user-local-1", reducer.state.messages[0].id);
    try std.testing.expectEqualStrings("user-local-2", reducer.state.messages[1].id);
    try expectTextPart(reducer.state.messages[1].parts[0], "second", .done);
}

test "tool arguments become available and output retains the tool name" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    _ = try reducer.reduceServerEvent(.{ .function_call_arguments_delta = .{
        .response_id = "response-1",
        .item_id = "item-1",
        .call_id = "call-1",
        .delta = "{\"city\":",
        .raw = .null,
    } });
    const duplicate_delta = try reducer.reduceServerEvent(.{ .function_call_arguments_delta = .{
        .response_id = "response-1",
        .item_id = "item-1",
        .call_id = "call-1",
        .delta = "\"Paris\"}",
        .raw = .null,
    } });
    try std.testing.expect(duplicate_delta.changes.messages);

    const done = try reducer.reduceServerEvent(.{ .function_call_arguments_done = .{
        .response_id = "response-1",
        .item_id = "item-1",
        .call_id = "call-1",
        .name = "getWeather",
        .arguments = "{\"city\":\"Paris\"}",
        .raw = .null,
    } });
    try std.testing.expect(done.changes.messages);
    switch (done.effects[0]) {
        .tool_call => |effect| {
            try std.testing.expectEqualStrings("call-1", effect.call_id);
            try std.testing.expectEqualStrings("getWeather", effect.name);
            try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", effect.raw);
            try std.testing.expectEqualStrings("Paris", effect.args_json.object.get("city").?.string);
        },
        else => return error.UnexpectedEffect,
    }

    const output_object = try jsonObject(std.testing.allocator, "temperature", .{ .integer = 22 });
    defer output_object.deinit();
    const output = try reducer.addToolOutput("call-1", .{ .object = output_object.value });
    try std.testing.expect(output.changes.messages);
    try std.testing.expectEqualStrings("getWeather", output.output.name.?);
    try std.testing.expectEqualStrings("{\"temperature\":22}", output.output.output);

    const tool_part = switch (output.state.messages[0].parts[0]) {
        .dynamic_tool => |part| part,
        else => return error.UnexpectedPart,
    };
    try std.testing.expectEqualStrings("getWeather", tool_part.name);
    switch (tool_part.state) {
        .output_available => |state| {
            try std.testing.expectEqualStrings("Paris", state.input.object.get("city").?.string);
            try std.testing.expectEqual(@as(i64, 22), state.output.object.get("temperature").?.integer);
        },
        else => return error.UnexpectedToolState,
    }
}

test "invalid tool arguments mark empty input and emit a parse error" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    _ = try reducer.reduceServerEvent(.{ .function_call_arguments_delta = .{
        .response_id = "response-1",
        .item_id = "item-1",
        .call_id = "bad-call",
        .delta = "{",
        .raw = .null,
    } });
    const result = try reducer.reduceServerEvent(.{ .function_call_arguments_done = .{
        .response_id = "response-1",
        .item_id = "item-1",
        .call_id = "bad-call",
        .name = "broken",
        .arguments = "{",
        .raw = .null,
    } });
    switch (result.effects[0]) {
        .err => |effect| try std.testing.expectEqualStrings(
            "Failed to parse tool arguments: {",
            effect.message,
        ),
        else => return error.UnexpectedEffect,
    }
    const tool_part = switch (result.state.messages[0].parts[0]) {
        .dynamic_tool => |part| part,
        else => return error.UnexpectedPart,
    };
    try std.testing.expectEqualStrings("broken", tool_part.name);
    switch (tool_part.state) {
        .input_available => |state| try std.testing.expectEqual(@as(usize, 0), state.input.object.count()),
        else => return error.UnexpectedToolState,
    }
}

test "unknown tool output still serializes without changing messages" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    const result = try reducer.addToolOutput("unknown", .{ .bool = true });
    try std.testing.expect(!result.changes.messages);
    try std.testing.expect(result.output.name == null);
    try std.testing.expectEqualStrings("true", result.output.output);
}

test "provider errors pass through message and code" {
    var reducer = Reducer.init(std.testing.allocator, 500);
    defer reducer.deinit();

    const result = try reducer.reduceServerEvent(.{ .err = .{
        .message = "rate limited",
        .code = "rate_limit",
        .raw = .null,
    } });
    switch (result.effects[0]) {
        .err => |effect| {
            try std.testing.expectEqualStrings("rate limited", effect.message);
            try std.testing.expectEqualStrings("rate_limit", effect.code.?);
        },
        else => return error.UnexpectedEffect,
    }
}

test "event history is an owned capped ring and zero disables history" {
    var reducer = Reducer.init(std.testing.allocator, 2);
    defer reducer.deinit();

    const mutable_id = try std.testing.allocator.dupe(u8, "one");
    _ = try reducer.reduceServerEvent(.{ .custom = .{
        .raw_type = mutable_id,
        .raw = .null,
    } });
    @memset(mutable_id, 'x');
    std.testing.allocator.free(mutable_id);
    try std.testing.expectEqualStrings("one", reducer.state.events[0].custom.raw_type);

    _ = try reducer.reduceServerEvent(.{ .custom = .{ .raw_type = "two", .raw = .null } });
    _ = try reducer.reduceServerEvent(.{ .custom = .{ .raw_type = "three", .raw = .null } });
    try std.testing.expectEqual(@as(usize, 2), reducer.state.events.len);
    try std.testing.expectEqualStrings("two", reducer.state.events[0].custom.raw_type);
    try std.testing.expectEqualStrings("three", reducer.state.events[1].custom.raw_type);

    var no_history = Reducer.init(std.testing.allocator, 0);
    defer no_history.deinit();
    const result = try no_history.reduceServerEvent(.{ .custom = .{
        .raw_type = "ignored",
        .raw = .null,
    } });
    try std.testing.expectEqual(@as(usize, 0), result.state.events.len);
    try std.testing.expect(!result.changes.events);
}

test "passive server variants are retained without effects" {
    var reducer = Reducer.init(std.testing.allocator, 32);
    defer reducer.deinit();

    const item: provider.ServerEvent.ItemEvent = .{
        .response_id = "response",
        .item_id = "item",
        .raw = .null,
    };
    const events = [_]provider.ServerEvent{
        .{ .speech_stopped = .{ .item_id = "item", .raw = .null } },
        .{ .conversation_item_added = .{
            .item_id = "item",
            .item = .null,
            .raw = .null,
        } },
        .{ .output_item_added = item },
        .{ .output_item_done = item },
        .{ .content_part_added = item },
        .{ .content_part_done = item },
        .{ .audio_done = item },
        .{ .custom = .{ .raw_type = "future.event", .raw = .null } },
    };
    for (events) |event| {
        const result = try reducer.reduceServerEvent(event);
        try std.testing.expectEqual(@as(usize, 0), result.effects.len);
    }
    try std.testing.expectEqual(events.len, reducer.state.events.len);
}

fn expectTextPart(part: ui.UIMessagePart, text: []const u8, state: ui.PartState) !void {
    switch (part) {
        .text => |value| {
            try std.testing.expectEqualStrings(text, value.text);
            try std.testing.expectEqual(state, value.state.?);
        },
        else => return error.UnexpectedPart,
    }
}

const OwnedTestObject = struct {
    arena_state: std.heap.ArenaAllocator,
    value: std.json.ObjectMap,

    fn deinit(self: *const OwnedTestObject) void {
        var mutable = self.arena_state;
        mutable.deinit();
    }
};

fn jsonObject(allocator: Allocator, key: []const u8, value: JsonValue) !OwnedTestObject {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    var object: std.json.ObjectMap = .empty;
    try object.put(arena_state.allocator(), key, value);
    return .{ .arena_state = arena_state, .value = object };
}
