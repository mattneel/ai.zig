//! Realtime session orchestration and injectable host interfaces.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const prompt = @import("../prompt.zig");
const tool_api = @import("../tool.zig");
const reducer_api = @import("reducer.zig");
const ui = @import("../ui/ui_messages.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

threadlocal var active_session_callback: ?*RealtimeSession = null;

pub const TransportConnectConfig = struct {
    url: []const u8,
    protocols: []const []const u8 = &.{},
    headers: []const provider.Header = &.{},
};

pub const TransportCallbacks = struct {
    ctx: *anyopaque,
    on_server_event: *const fn (ctx: *anyopaque, event: provider.ServerEvent) anyerror!void,
    on_error: *const fn (ctx: *anyopaque, err: anyerror) void,
    on_close: *const fn (ctx: *anyopaque) void,
};

pub const RawMessage = union(enum) {
    text: []const u8,
    binary: []const u8,
    json: JsonValue,
};

pub const RealtimeTransport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// `disconnect` must quiesce all callbacks before it returns. Implementors
    /// must not invoke callbacks after `disconnect` or `deinit` completes.
    pub const VTable = struct {
        connect: *const fn (
            ctx: *anyopaque,
            config: TransportConnectConfig,
            callbacks: TransportCallbacks,
            diag: ?*provider.Diagnostics,
        ) anyerror!void,
        send_event: *const fn (
            ctx: *anyopaque,
            event: provider.ClientEvent,
            diag: ?*provider.Diagnostics,
        ) anyerror!void,
        send_raw: *const fn (ctx: *anyopaque, message: RawMessage) anyerror!void,
        disconnect: *const fn (ctx: *anyopaque) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn connect(
        self: RealtimeTransport,
        config: TransportConnectConfig,
        callbacks: TransportCallbacks,
        diag: ?*provider.Diagnostics,
    ) !void {
        return self.vtable.connect(self.ctx, config, callbacks, diag);
    }

    pub fn sendEvent(self: RealtimeTransport, event: provider.ClientEvent, diag: ?*provider.Diagnostics) !void {
        return self.vtable.send_event(self.ctx, event, diag);
    }

    pub fn sendRaw(self: RealtimeTransport, message: RawMessage) !void {
        return self.vtable.send_raw(self.ctx, message);
    }

    pub fn disconnect(self: RealtimeTransport) void {
        self.vtable.disconnect(self.ctx);
    }

    pub fn deinit(self: RealtimeTransport) void {
        self.vtable.deinit(self.ctx);
    }
};

const DefaultTransport = struct {
    gpa: Allocator,
    io: std.Io,
    model: provider.RealtimeModel,
    websocket_factory: provider_utils.WebSocketFactory,
    socket: ?provider_utils.WebSocketLike = null,
    callbacks: ?TransportCallbacks = null,
    receive_future: ?std.Io.Future(anyerror!void) = null,
    lifecycle_mutex: std.Io.Mutex = .init,
    shutdown_mutex: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        model: provider.RealtimeModel,
        websocket_factory: provider_utils.WebSocketFactory,
    ) DefaultTransport {
        return .{
            .gpa = gpa,
            .io = io,
            .model = model,
            .websocket_factory = websocket_factory,
        };
    }

    pub fn transport(self: *DefaultTransport) RealtimeTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: RealtimeTransport.VTable = .{
        .connect = vConnect,
        .send_event = vSendEvent,
        .send_raw = vSendRaw,
        .disconnect = vDisconnect,
        .deinit = vDeinit,
    };

    fn fromRaw(raw: *anyopaque) *DefaultTransport {
        return @ptrCast(@alignCast(raw));
    }

    fn vConnect(
        raw: *anyopaque,
        config: TransportConnectConfig,
        callbacks: TransportCallbacks,
        diag: ?*provider.Diagnostics,
    ) anyerror!void {
        return fromRaw(raw).connect(config, callbacks, diag);
    }

    fn vSendEvent(raw: *anyopaque, event: provider.ClientEvent, diag: ?*provider.Diagnostics) anyerror!void {
        return fromRaw(raw).sendEvent(event, diag);
    }

    fn vSendRaw(raw: *anyopaque, message: RawMessage) anyerror!void {
        return fromRaw(raw).sendRaw(message);
    }

    fn vDisconnect(raw: *anyopaque) void {
        fromRaw(raw).disconnect();
    }

    fn vDeinit(raw: *anyopaque) void {
        fromRaw(raw).disconnect();
    }

    fn connect(
        self: *DefaultTransport,
        config: TransportConnectConfig,
        callbacks: TransportCallbacks,
        diag: ?*provider.Diagnostics,
    ) !void {
        self.disconnect();
        self.stopping.store(false, .release);
        var socket = try self.websocket_factory.connect(
            self.gpa,
            self.io,
            config.url,
            .{ .protocols = config.protocols, .headers = config.headers },
            diag,
        );
        errdefer socket.deinit();
        self.socket = socket;
        self.callbacks = callbacks;
        self.receive_future = self.io.concurrent(receiveLoop, .{self}) catch |err| {
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, self.gpa), .{ .unsupported_functionality = .{
                .message = "Realtime transport requires a concurrent WebSocket message pump",
                .functionality = "realtime transport receive pump",
            } });
            self.socket = null;
            self.callbacks = null;
            return err;
        };
    }

    fn sendEvent(self: *DefaultTransport, event: provider.ClientEvent, diag: ?*provider.Diagnostics) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const serialized = try self.model.serializeClientEvent(self.io, arena, &event, diag);
        return self.sendRaw(.{ .json = serialized });
    }

    fn sendRaw(self: *DefaultTransport, message: RawMessage) !void {
        try self.lifecycle_mutex.lock(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        const socket = self.socket orelse return error.WebSocketClosed;
        switch (message) {
            .text => |text| try socket.sendText(text),
            .binary => |bytes| try socket.sendBinary(bytes),
            .json => |value| {
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                const text = try provider_utils.stringifyJsonValueAlloc(arena_state.allocator(), value);
                try socket.sendText(text);
            },
        }
    }

    fn receiveLoop(self: *DefaultTransport) anyerror!void {
        self.lifecycle_mutex.lockUncancelable(self.io);
        const socket = self.socket orelse {
            self.lifecycle_mutex.unlock(self.io);
            return;
        };
        self.lifecycle_mutex.unlock(self.io);

        while (!self.stopping.load(.acquire)) {
            const maybe_message = socket.receive(self.io) catch |err| {
                if (!self.stopping.load(.acquire)) if (self.callbacks) |callbacks| callbacks.on_error(callbacks.ctx, err);
                break;
            };
            const message = maybe_message orelse break;
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const raw = std.json.parseFromSliceLeaky(JsonValue, arena, message.payload, .{
                .allocate = .alloc_always,
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (self.callbacks) |callbacks| callbacks.on_error(callbacks.ctx, error.OutOfMemory);
                    break;
                },
                else => continue,
            };
            if (try self.model.getHealthCheckResponse(arena, &raw, null)) |response| {
                self.sendRaw(.{ .json = response }) catch |err| {
                    if (self.callbacks) |callbacks| callbacks.on_error(callbacks.ctx, err);
                    break;
                };
            }
            const events = self.model.parseServerEvent(arena, &raw, null) catch |err| {
                if (self.callbacks) |callbacks| callbacks.on_error(callbacks.ctx, err);
                break;
            };
            if (self.callbacks) |callbacks| for (events) |event| {
                callbacks.on_server_event(callbacks.ctx, event) catch |err| {
                    callbacks.on_error(callbacks.ctx, err);
                    return;
                };
            };
        }
        if (self.callbacks) |callbacks| callbacks.on_close(callbacks.ctx);
    }

    fn disconnect(self: *DefaultTransport) void {
        self.shutdown_mutex.lockUncancelable(self.io);
        defer self.shutdown_mutex.unlock(self.io);
        self.lifecycle_mutex.lockUncancelable(self.io);
        self.stopping.store(true, .release);
        const maybe_socket = self.socket;
        const maybe_future = self.receive_future;
        self.socket = null;
        self.receive_future = null;
        self.lifecycle_mutex.unlock(self.io);

        if (maybe_socket) |socket| socket.close(1000, "") catch {};
        if (maybe_future) |future_value| {
            var future = future_value;
            _ = future.cancel(self.io) catch {};
        }
        if (maybe_socket) |socket_value| {
            var socket = socket_value;
            socket.deinit();
        }

        self.lifecycle_mutex.lockUncancelable(self.io);
        self.callbacks = null;
        self.lifecycle_mutex.unlock(self.io);
    }
};

pub const AudioPayload = union(enum) {
    base64: []const u8,
    pcm16: []const i16,
};

pub const CaptureCallback = struct {
    ctx: *anyopaque,
    on_audio: *const fn (ctx: *anyopaque, base64_audio: []const u8) void,
};

pub const RealtimeAudio = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// `stop_capture` must quiesce capture callbacks before it returns, and
    /// `deinit` must not allow any later host callback into the session.
    pub const VTable = struct {
        play: *const fn (ctx: *anyopaque, io: std.Io, item_id: []const u8, audio: AudioPayload) anyerror!void,
        stop_playback: *const fn (ctx: *anyopaque, io: std.Io) void,
        playback_offset_ms: *const fn (ctx: *anyopaque) u64,
        start_capture: *const fn (ctx: *anyopaque, io: std.Io, callback: CaptureCallback) anyerror!void,
        stop_capture: *const fn (ctx: *anyopaque, io: std.Io) void,
        deinit: *const fn (ctx: *anyopaque, io: std.Io) void,
    };

    pub fn play(self: RealtimeAudio, io: std.Io, item_id: []const u8, audio: AudioPayload) !void {
        return self.vtable.play(self.ctx, io, item_id, audio);
    }
    pub fn stopPlayback(self: RealtimeAudio, io: std.Io) void {
        self.vtable.stop_playback(self.ctx, io);
    }
    pub fn playbackOffsetMs(self: RealtimeAudio) u64 {
        return self.vtable.playback_offset_ms(self.ctx);
    }
    pub fn startCapture(self: RealtimeAudio, io: std.Io, callback: CaptureCallback) !void {
        return self.vtable.start_capture(self.ctx, io, callback);
    }
    pub fn stopCapture(self: RealtimeAudio, io: std.Io) void {
        self.vtable.stop_capture(self.ctx, io);
    }
    pub fn deinit(self: RealtimeAudio, io: std.Io) void {
        self.vtable.deinit(self.ctx, io);
    }
};

var null_audio_marker: u8 = 0;
pub const null_audio: RealtimeAudio = .{ .ctx = &null_audio_marker, .vtable = &null_audio_vtable };

const null_audio_vtable: RealtimeAudio.VTable = .{
    .play = struct {
        fn call(_: *anyopaque, _: std.Io, _: []const u8, _: AudioPayload) anyerror!void {}
    }.call,
    .stop_playback = struct {
        fn call(_: *anyopaque, _: std.Io) void {}
    }.call,
    .playback_offset_ms = struct {
        fn call(_: *anyopaque) u64 {
            return 0;
        }
    }.call,
    .start_capture = struct {
        fn call(_: *anyopaque, _: std.Io, _: CaptureCallback) anyerror!void {}
    }.call,
    .stop_capture = struct {
        fn call(_: *anyopaque, _: std.Io) void {}
    }.call,
    .deinit = struct {
        fn call(_: *anyopaque, _: std.Io) void {}
    }.call,
};

pub const StateCallbacks = struct {
    ctx: ?*anyopaque = null,
    on_status: ?*const fn (ctx: ?*anyopaque, status: reducer_api.Status) void = null,
    /// Collection snapshots are deeply owned for the duration of the callback
    /// and are released immediately after it returns.
    on_messages: ?*const fn (ctx: ?*anyopaque, messages: []const ui.UIMessage) void = null,
    on_events: ?*const fn (ctx: ?*anyopaque, events: []const provider.ServerEvent) void = null,
    on_is_capturing: ?*const fn (ctx: ?*anyopaque, value: bool) void = null,
    on_is_playing: ?*const fn (ctx: ?*anyopaque, value: bool) void = null,
};

const StatePublication = struct {
    arena_state: std.heap.ArenaAllocator,
    state: reducer_api.State,
    changes: reducer_api.Changes,
    sequence: u64,

    fn init(
        gpa: Allocator,
        reducer: *const reducer_api.Reducer,
        callbacks: StateCallbacks,
        changes: reducer_api.Changes,
        sequence: u64,
    ) !StatePublication {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const wanted: reducer_api.Changes = .{
            .messages = changes.messages and callbacks.on_messages != null,
            .events = changes.events and callbacks.on_events != null,
        };
        const state = try reducer.snapshotChanges(arena_state.allocator(), wanted);
        return .{
            .arena_state = arena_state,
            .state = state,
            .changes = changes,
            .sequence = sequence,
        };
    }

    fn deinit(self: *StatePublication) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

const DeliveredPublicationSequences = struct {
    status: u64 = 0,
    messages: u64 = 0,
    events: u64 = 0,
    is_capturing: u64 = 0,
    is_playing: u64 = 0,
};

pub const ErrorInfo = struct {
    err: anyerror,
    message: []const u8,
};

pub const EventCallback = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, event: provider.ServerEvent) void,
};

pub const ErrorCallback = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, info: ErrorInfo) void,
};

pub const ToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    args: JsonValue,
    raw_arguments: []const u8,
};

pub const ToolCallHandler = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        tool_call: ToolCall,
    ) anyerror!?JsonValue,
};

pub const Options = struct {
    model: provider.RealtimeModel,
    session_config: provider.SessionConfig = .{},
    tools: tool_api.ToolSet = &.{},
    tools_context: ?JsonValue = null,
    max_events: usize = 500,
    transport: ?RealtimeTransport = null,
    websocket_factory: provider_utils.WebSocketFactory = provider_utils.defaultWebSocketFactory,
    audio: RealtimeAudio = null_audio,
    state_callbacks: StateCallbacks = .{},
    on_tool_call: ?ToolCallHandler = null,
    on_event: ?EventCallback = null,
    on_error: ?ErrorCallback = null,
    diag: ?*provider.Diagnostics = null,
};

pub const ResponseOptions = struct {
    modalities: ?[]const []const u8 = null,
    instructions: ?[]const u8 = null,
    metadata: ?JsonValue = null,
};

pub const DeferredLifecycleAction = enum(u8) {
    none,
    disconnect,
    dispose,
};

pub const LifecycleState = enum(u8) {
    active,
    disposing,
    disposed,
};

pub const RealtimeSession = struct {
    gpa: Allocator,
    io: std.Io,
    arena_state: std.heap.ArenaAllocator,
    model: provider.RealtimeModel,
    session_config: provider.SessionConfig,
    reducer: reducer_api.Reducer,
    state_mutex: std.Io.Mutex = .init,
    publication_mutex: std.Io.Mutex = .init,
    publication_queue: std.ArrayList(StatePublication) = .empty,
    publication_queue_head: usize = 0,
    publication_draining: bool = false,
    next_publication_sequence: u64 = 1,
    delivered_publication_sequences: DeliveredPublicationSequences = .{},
    tool_group: std.Io.Group = .init,
    default_transport: ?DefaultTransport,
    transport: RealtimeTransport,
    audio: RealtimeAudio,
    state_callbacks: StateCallbacks,
    on_tool_call: ?ToolCallHandler,
    on_event: ?EventCallback,
    on_error: ?ErrorCallback,
    diag: ?*provider.Diagnostics,
    current_response_item_id: ?[]u8 = null,
    tool_calls_in_response: std.StringHashMapUnmanaged(void) = .empty,
    submitted_tool_outputs: std.StringHashMapUnmanaged(void) = .empty,
    response_tool_calls_closed: bool = false,
    tool_response_send_in_flight: bool = false,
    active_calls: std.atomic.Value(u32) = .init(0),
    callback_depth: std.atomic.Value(u32) = .init(0),
    deferred_lifecycle_action: std.atomic.Value(u8) = .init(@intFromEnum(DeferredLifecycleAction.none)),
    lifecycle_state: std.atomic.Value(LifecycleState) = .init(.active),

    pub fn init(gpa: Allocator, io: std.Io, options: Options) anyerror!*RealtimeSession {
        const self = try gpa.create(RealtimeSession);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = .init(gpa),
            .model = options.model,
            .session_config = undefined,
            .reducer = reducer_api.Reducer.init(gpa, options.max_events),
            .default_transport = null,
            .transport = undefined,
            .audio = options.audio,
            .state_callbacks = options.state_callbacks,
            .on_tool_call = options.on_tool_call,
            .on_event = options.on_event,
            .on_error = options.on_error,
            .diag = options.diag,
        };
        errdefer self.reducer.deinit();
        errdefer self.arena_state.deinit();
        errdefer self.publication_queue.deinit(gpa);
        try self.publication_queue.ensureTotalCapacity(gpa, 8);
        const arena = self.arena_state.allocator();
        self.session_config = try cloneSessionConfig(arena, options.session_config);
        if (options.tools.len != 0) {
            self.session_config.tools = try getRealtimeToolDefinitions(
                arena,
                options.tools,
                options.tools_context,
                options.diag,
            );
        }
        if (options.transport) |transport| {
            self.transport = transport;
        } else {
            self.default_transport = DefaultTransport.init(gpa, io, options.model, options.websocket_factory);
            self.transport = self.default_transport.?.transport();
        }
        return self;
    }

    /// Returns a caller-owned deep snapshot. The snapshot remains valid until
    /// `arena` is released, independent of concurrent realtime mutations.
    pub fn state(self: *RealtimeSession, arena: Allocator) anyerror!reducer_api.State {
        const guard = try self.enterCall();
        defer guard.deinit();
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.reducer.snapshot(arena);
    }

    pub fn connect(self: *RealtimeSession) anyerror!void {
        const guard = try self.enterCall();
        defer guard.deinit();
        try self.setStatus(.connecting);
        const secret = self.model.doCreateClientSecret(self.io, self.arena_state.allocator(), &.{
            .session_config = self.session_config,
        }, self.diag) catch |err| return self.fail(err);
        const ws_config = self.model.getWebSocketConfig(self.arena_state.allocator(), &.{
            .token = secret.token,
            .url = secret.url,
        }, self.diag) catch |err| return self.fail(err);
        self.transport.connect(.{
            .url = ws_config.url,
            .protocols = ws_config.protocols orelse &.{},
        }, .{
            .ctx = self,
            .on_server_event = onTransportServerEvent,
            .on_error = onTransportError,
            .on_close = onTransportClose,
        }, self.diag) catch |err| return self.fail(err);
        self.transport.sendEvent(.{ .session_update = .{ .config = self.session_config } }, self.diag) catch |err| {
            self.transport.disconnect();
            return self.fail(err);
        };
    }

    pub fn disconnect(self: *RealtimeSession) void {
        const guard = self.tryEnterCall() orelse return;
        defer guard.deinit();
        if (active_session_callback == self) {
            self.deferLifecycleAction(.disconnect);
            return;
        }
        self.transport.disconnect();
        self.setStatus(.disconnected) catch {};
    }

    pub fn sendEvent(self: *RealtimeSession, event: provider.ClientEvent) anyerror!void {
        const guard = try self.enterCall();
        defer guard.deinit();
        self.transport.sendEvent(event, self.diag) catch |err| return self.fail(err);
    }

    pub fn sendRaw(self: *RealtimeSession, message: RawMessage) anyerror!void {
        const guard = try self.enterCall();
        defer guard.deinit();
        self.transport.sendRaw(message) catch |err| return self.fail(err);
    }

    pub fn sendTextMessage(self: *RealtimeSession, text: []const u8) anyerror!void {
        const guard = try self.enterCall();
        defer guard.finishDeferredLifecycleAction();
        try self.sendEvent(.{ .conversation_item_create = .{ .item = .{ .text_message = .{
            .role = .user,
            .text = text,
        } } } });
        try self.sendEvent(.{ .response_create = .{} });
        var publication = try self.addUserTextPublication(text);
        try self.dispatchPublication(&publication);
    }

    pub fn sendAudio(self: *RealtimeSession, base64_audio: []const u8) anyerror!void {
        return self.sendEvent(.{ .input_audio_append = .{ .audio = base64_audio } });
    }

    pub fn commitAudio(self: *RealtimeSession) anyerror!void {
        return self.sendEvent(.{ .input_audio_commit = .{} });
    }

    pub fn clearAudioBuffer(self: *RealtimeSession) anyerror!void {
        return self.sendEvent(.{ .input_audio_clear = .{} });
    }

    pub fn requestResponse(self: *RealtimeSession, options: ?ResponseOptions) anyerror!void {
        return self.sendEvent(.{ .response_create = .{ .options = if (options) |value| .{
            .modalities = value.modalities,
            .instructions = value.instructions,
            .metadata = value.metadata,
        } else null } });
    }

    pub fn cancelResponse(self: *RealtimeSession) anyerror!void {
        return self.sendEvent(.{ .response_cancel = .{} });
    }

    pub fn addToolOutput(self: *RealtimeSession, call_id: []const u8, result: JsonValue) anyerror!void {
        const guard = try self.enterCall();
        defer guard.deinit();
        var staging_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer staging_arena_state.deinit();
        var staged = try self.stageToolOutput(staging_arena_state.allocator(), call_id, result);
        try self.dispatchPublication(&staged.publication);
        try self.transport.sendEvent(.{ .conversation_item_create = .{ .item = .{ .function_call_output = .{
            .call_id = staged.call_id,
            .name = staged.name,
            .output = staged.output,
        } } } }, self.diag);
        try self.sendClaimedToolResponse(try self.recordSubmittedToolOutput(call_id));
    }

    pub fn startAudioCapture(self: *RealtimeSession) anyerror!void {
        const guard = try self.enterCall();
        defer guard.deinit();
        try self.audio.startCapture(self.io, .{ .ctx = self, .on_audio = onCapturedAudio });
        var publication = try self.setCapturingPublication(true);
        try self.dispatchPublication(&publication);
    }

    pub fn stopAudioCapture(self: *RealtimeSession) void {
        const guard = self.tryEnterCall() orelse return;
        defer guard.deinit();
        self.audio.stopCapture(self.io);
        var publication = self.setCapturingPublication(false) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
            return;
        };
        self.dispatchPublication(&publication) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
        };
    }

    pub fn stopPlayback(self: *RealtimeSession) void {
        const guard = self.tryEnterCall() orelse return;
        defer guard.deinit();
        self.audio.stopPlayback(self.io);
        var publication = self.setPlayingPublication(false) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
            return;
        };
        self.dispatchPublication(&publication) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
        };
    }

    pub fn dispose(self: *RealtimeSession) void {
        if (active_session_callback == self) {
            self.deferLifecycleAction(.dispose);
            return;
        }
        if (!self.claimDisposal()) return;
        self.disposeClaimed();
    }

    fn claimDisposal(self: *RealtimeSession) bool {
        return self.lifecycle_state.cmpxchgStrong(
            .active,
            .disposing,
            .acq_rel,
            .acquire,
        ) == null;
    }

    fn disposeClaimed(self: *RealtimeSession) void {
        std.debug.assert(self.lifecycleState() == .disposing);
        self.audio.stopCapture(self.io);
        self.audio.stopPlayback(self.io);
        self.transport.disconnect();
        self.tool_group.cancel(self.io);
        self.waitForActiveCalls();
        self.deferred_lifecycle_action.store(@intFromEnum(DeferredLifecycleAction.none), .release);
        self.transport.deinit();
        var final_publication = self.finalPublication() catch null;
        self.audio.deinit(self.io);
        if (final_publication) |*publication| {
            self.dispatchPublication(publication) catch {};
        }
        std.debug.assert(!self.publication_draining);
        std.debug.assert(self.publication_queue.items.len == 0);
        self.publication_queue.deinit(self.gpa);
        self.reducer.deinit();
        self.tool_calls_in_response.deinit(self.gpa);
        self.submitted_tool_outputs.deinit(self.gpa);
        if (self.current_response_item_id) |item_id| self.gpa.free(item_id);
        self.arena_state.deinit();
        const gpa = self.gpa;
        self.lifecycle_state.store(.disposed, .release);
        self.* = undefined;
        gpa.destroy(self);
    }

    fn takeDeferredLifecycleActionHeld(self: *RealtimeSession) DeferredLifecycleAction {
        std.debug.assert(self.active_calls.load(.acquire) != 0);
        return @enumFromInt(self.deferred_lifecycle_action.swap(
            @intFromEnum(DeferredLifecycleAction.none),
            .acq_rel,
        ));
    }

    fn handleServerEvent(self: *RealtimeSession, event: provider.ServerEvent) anyerror!void {
        var staging_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer staging_arena_state.deinit();
        var staged = try self.reduceAndStage(staging_arena_state.allocator(), event);

        try self.dispatchPublication(&staged.publication);
        if (self.on_event) |callback| {
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback.call(callback.ctx, event);
        }

        for (staged.effects) |effect| switch (effect) {
            .play_audio => |audio_effect| self.handlePlayAudio(audio_effect),
            .speech_started => try self.handleSpeechStarted(),
            .tool_call => |tool_effect| try self.handleToolCall(tool_effect),
            .err => |effect_error| self.notifyError(.{
                .err = error.InvalidResponseDataError,
                .message = effect_error.message,
            }),
        };

        if (event == .response_done)
            try self.sendClaimedToolResponse(try self.markResponseToolCallsClosed());
    }

    const StagedEvent = struct {
        publication: StatePublication,
        effects: []const reducer_api.Effect,
    };

    fn reduceAndStage(
        self: *RealtimeSession,
        arena: Allocator,
        event: provider.ServerEvent,
    ) !StagedEvent {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const result = try self.reducer.reduceServerEvent(event);
        return .{
            .publication = try self.makePublicationLocked(result.changes),
            .effects = try cloneEffects(arena, result.effects),
        };
    }

    fn handlePlayAudio(self: *RealtimeSession, effect: reducer_api.Effect.PlayAudio) void {
        const owned_id = self.gpa.dupe(u8, effect.item_id) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
            return;
        };
        self.state_mutex.lockUncancelable(self.io);
        if (self.current_response_item_id) |item_id| self.gpa.free(item_id);
        self.current_response_item_id = owned_id;
        self.state_mutex.unlock(self.io);

        {
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            self.audio.play(self.io, effect.item_id, .{ .base64 = effect.delta_base64 }) catch |err| {
                self.notifyError(.{ .err = err, .message = @errorName(err) });
                return;
            };
        }
        var publication = self.setPlayingPublication(true) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
            return;
        };
        self.dispatchPublication(&publication) catch |err| {
            self.notifyError(.{ .err = err, .message = @errorName(err) });
        };
    }

    fn handleSpeechStarted(self: *RealtimeSession) !void {
        self.state_mutex.lockUncancelable(self.io);
        const was_playing = self.reducer.state.is_playing;
        const item_id = if (was_playing and self.current_response_item_id != null)
            self.gpa.dupe(u8, self.current_response_item_id.?) catch |err| {
                self.state_mutex.unlock(self.io);
                return err;
            }
        else
            null;
        self.state_mutex.unlock(self.io);
        defer if (item_id) |owned| self.gpa.free(owned);
        if (!was_playing) return;

        const offset = blk: {
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            const value = self.audio.playbackOffsetMs();
            self.audio.stopPlayback(self.io);
            break :blk value;
        };
        var publication = try self.setPlayingPublication(false);
        try self.dispatchPublication(&publication);
        if (item_id) |owned| try self.transport.sendEvent(.{ .conversation_item_truncate = .{
            .item_id = owned,
            .content_index = 0,
            .audio_end_ms = offset,
        } }, self.diag);
    }

    fn handleToolCall(self: *RealtimeSession, effect: reducer_api.Effect.ToolCall) !void {
        const call_id = try self.recordToolCall(effect.call_id);
        const handler = self.on_tool_call orelse {
            var message_arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer message_arena_state.deinit();
            const message = try std.fmt.allocPrint(
                message_arena_state.allocator(),
                "No handler provided for tool \"{s}\"",
                .{effect.name},
            );
            self.notifyError(.{ .err = error.UnsupportedFunctionalityError, .message = message });
            return;
        };
        const task = try ToolTask.init(self, handler, .{
            .call_id = call_id,
            .name = effect.name,
            .args = effect.args_json,
            .raw_arguments = effect.raw,
        });
        self.tool_group.concurrent(self.io, ToolTask.run, .{task}) catch |err| {
            task.deinit();
            self.notifyError(.{ .err = err, .message = @errorName(err) });
        };
    }

    fn recordToolCall(self: *RealtimeSession, call_id: []const u8) ![]const u8 {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.tool_calls_in_response.getKey(call_id)) |existing| return existing;
        const owned = try self.arena_state.allocator().dupe(u8, call_id);
        try self.tool_calls_in_response.put(self.gpa, owned, {});
        return owned;
    }

    fn markResponseToolCallsClosed(self: *RealtimeSession) !bool {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.tool_calls_in_response.count() == 0) return false;
        self.response_tool_calls_closed = true;
        return self.claimReadyToolResponseLocked();
    }

    fn claimReadyToolResponseLocked(self: *RealtimeSession) bool {
        if (self.tool_response_send_in_flight) return false;
        if (!self.response_tool_calls_closed or self.tool_calls_in_response.count() == 0) return false;
        var iterator = self.tool_calls_in_response.iterator();
        while (iterator.next()) |entry| {
            if (!self.submitted_tool_outputs.contains(entry.key_ptr.*)) return false;
        }
        self.tool_response_send_in_flight = true;
        return true;
    }

    fn sendClaimedToolResponse(self: *RealtimeSession, claimed: bool) !void {
        if (!claimed) return;
        self.transport.sendEvent(.{ .response_create = .{} }, self.diag) catch |err| {
            self.finishToolResponseSend(false);
            self.notifyError(.{ .err = err, .message = @errorName(err) });
            return err;
        };
        self.finishToolResponseSend(true);
    }

    fn finishToolResponseSend(self: *RealtimeSession, accepted: bool) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        std.debug.assert(self.tool_response_send_in_flight);
        if (accepted) {
            self.tool_calls_in_response.clearRetainingCapacity();
            self.submitted_tool_outputs.clearRetainingCapacity();
            self.response_tool_calls_closed = false;
        }
        self.tool_response_send_in_flight = false;
    }

    fn setStatus(self: *RealtimeSession, status: reducer_api.Status) anyerror!void {
        if (self.lifecycleState() != .active) return error.RealtimeSessionDisposed;
        var publication = try self.setStatusPublication(status);
        try self.dispatchPublication(&publication);
    }

    fn makePublicationLocked(self: *RealtimeSession, changes: reducer_api.Changes) !StatePublication {
        const sequence = self.next_publication_sequence;
        if (sequence == std.math.maxInt(u64))
            return error.RealtimeStatePublicationSequenceExhausted;
        const publication = try StatePublication.init(
            self.gpa,
            &self.reducer,
            self.state_callbacks,
            changes,
            sequence,
        );
        self.next_publication_sequence = sequence + 1;
        return publication;
    }

    fn setStatusPublication(self: *RealtimeSession, status: reducer_api.Status) !StatePublication {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const changed = self.reducer.setStatus(status);
        return self.makePublicationLocked(.{ .status = changed });
    }

    fn setCapturingPublication(self: *RealtimeSession, value: bool) !StatePublication {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const changed = self.reducer.setCapturing(value);
        return self.makePublicationLocked(.{ .is_capturing = changed });
    }

    fn setPlayingPublication(self: *RealtimeSession, value: bool) !StatePublication {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const changed = self.reducer.setPlaying(value);
        return self.makePublicationLocked(.{ .is_playing = changed });
    }

    fn addUserTextPublication(self: *RealtimeSession, text: []const u8) !StatePublication {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const changes = try self.reducer.addUserTextMessage(text);
        return self.makePublicationLocked(changes);
    }

    const StagedToolOutput = struct {
        publication: StatePublication,
        call_id: []const u8,
        name: ?[]const u8,
        output: []const u8,
    };

    fn stageToolOutput(
        self: *RealtimeSession,
        arena: Allocator,
        call_id: []const u8,
        result: JsonValue,
    ) !StagedToolOutput {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const reduced = try self.reducer.addToolOutput(call_id, result);
        return .{
            .publication = try self.makePublicationLocked(reduced.changes),
            .call_id = try arena.dupe(u8, reduced.output.call_id),
            .name = if (reduced.output.name) |name| try arena.dupe(u8, name) else null,
            .output = try arena.dupe(u8, reduced.output.output),
        };
    }

    fn recordSubmittedToolOutput(self: *RealtimeSession, call_id: []const u8) !bool {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const canonical = self.tool_calls_in_response.getKey(call_id) orelse
            try self.arena_state.allocator().dupe(u8, call_id);
        try self.submitted_tool_outputs.put(self.gpa, canonical, {});
        return self.claimReadyToolResponseLocked();
    }

    fn finalPublication(self: *RealtimeSession) !StatePublication {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const changes: reducer_api.Changes = .{
            .status = self.reducer.setStatus(.disconnected),
            .is_capturing = self.reducer.setCapturing(false),
            .is_playing = self.reducer.setPlaying(false),
        };
        return self.makePublicationLocked(changes);
    }

    /// Always consumes `publication`, including when enqueueing fails.
    fn dispatchPublication(self: *RealtimeSession, publication: *StatePublication) Allocator.Error!void {
        self.publication_mutex.lockUncancelable(self.io);
        self.publication_queue.append(self.gpa, publication.*) catch |err| {
            self.publication_mutex.unlock(self.io);
            publication.deinit();
            return err;
        };
        publication.* = undefined;

        if (self.publication_draining) {
            self.publication_mutex.unlock(self.io);
            return;
        }
        self.publication_draining = true;
        self.publication_mutex.unlock(self.io);
        self.drainPublications();
    }

    fn drainPublications(self: *RealtimeSession) void {
        while (true) {
            self.publication_mutex.lockUncancelable(self.io);
            if (self.publication_queue.items.len == 0) {
                std.debug.assert(self.publication_queue_head == 0);
                self.publication_draining = false;
                self.publication_mutex.unlock(self.io);
                return;
            }

            var publication = self.publication_queue.items[self.publication_queue_head];
            self.publication_queue_head += 1;
            if (self.publication_queue_head == self.publication_queue.items.len) {
                self.publication_queue.clearRetainingCapacity();
                self.publication_queue_head = 0;
            }
            self.publication_mutex.unlock(self.io);

            self.deliverPublication(publication);
            publication.deinit();
        }
    }

    fn deliverPublication(self: *RealtimeSession, publication: StatePublication) void {
        const state_value = publication.state;
        const changes = publication.changes;
        const sequence = publication.sequence;
        if (changes.status and sequence > self.delivered_publication_sequences.status) if (self.state_callbacks.on_status) |callback| {
            self.delivered_publication_sequences.status = sequence;
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback(self.state_callbacks.ctx, state_value.status);
        };
        if (changes.messages and sequence > self.delivered_publication_sequences.messages) if (self.state_callbacks.on_messages) |callback| {
            self.delivered_publication_sequences.messages = sequence;
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback(self.state_callbacks.ctx, state_value.messages);
        };
        if (changes.events and sequence > self.delivered_publication_sequences.events) if (self.state_callbacks.on_events) |callback| {
            self.delivered_publication_sequences.events = sequence;
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback(self.state_callbacks.ctx, state_value.events);
        };
        if (changes.is_capturing and sequence > self.delivered_publication_sequences.is_capturing) if (self.state_callbacks.on_is_capturing) |callback| {
            self.delivered_publication_sequences.is_capturing = sequence;
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback(self.state_callbacks.ctx, state_value.is_capturing);
        };
        if (changes.is_playing and sequence > self.delivered_publication_sequences.is_playing) if (self.state_callbacks.on_is_playing) |callback| {
            self.delivered_publication_sequences.is_playing = sequence;
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback(self.state_callbacks.ctx, state_value.is_playing);
        };
    }

    const CallbackGuard = struct {
        session: *RealtimeSession,
        previous: ?*RealtimeSession,

        fn deinit(self: CallbackGuard) void {
            std.debug.assert(self.session.callback_depth.fetchSub(1, .acq_rel) != 0);
            active_session_callback = self.previous;
        }
    };

    fn enterCallback(self: *RealtimeSession) CallbackGuard {
        const previous = active_session_callback;
        active_session_callback = self;
        _ = self.callback_depth.fetchAdd(1, .acq_rel);
        return .{ .session = self, .previous = previous };
    }

    fn deferLifecycleAction(self: *RealtimeSession, action: DeferredLifecycleAction) void {
        if (self.lifecycleState() != .active) return;
        if (action == .dispose) {
            self.deferred_lifecycle_action.store(@intFromEnum(action), .release);
            return;
        }
        _ = self.deferred_lifecycle_action.cmpxchgStrong(
            @intFromEnum(DeferredLifecycleAction.none),
            @intFromEnum(action),
            .acq_rel,
            .acquire,
        );
    }

    const CallGuard = struct {
        session: *RealtimeSession,

        fn deinit(self: CallGuard) void {
            self.session.leaveCall();
        }

        /// Consumes a callback-deferred lifecycle request while this call still
        /// holds the session alive. A deferred disposer claims teardown before
        /// releasing the hold; a racing external disposer either already owns
        /// teardown or loses its own CAS and becomes a no-op.
        fn finishDeferredLifecycleAction(self: CallGuard) void {
            const session = self.session;
            if (active_session_callback == session) {
                session.leaveCall();
                return;
            }

            while (true) switch (session.takeDeferredLifecycleActionHeld()) {
                .none => {
                    session.leaveCall();
                    return;
                },
                .disconnect => {
                    session.transport.disconnect();
                    session.setStatus(.disconnected) catch {};
                },
                .dispose => {
                    if (!session.claimDisposal()) {
                        session.leaveCall();
                        return;
                    }
                    session.leaveCall();
                    session.disposeClaimed();
                    return;
                },
            };
        }
    };

    fn enterCall(self: *RealtimeSession) anyerror!CallGuard {
        _ = self.active_calls.fetchAdd(1, .acq_rel);
        if (self.lifecycleState() != .active) {
            self.leaveCall();
            return error.RealtimeSessionDisposed;
        }
        return .{ .session = self };
    }

    fn lifecycleState(self: *const RealtimeSession) LifecycleState {
        return self.lifecycle_state.load(.acquire);
    }

    fn tryEnterCall(self: *RealtimeSession) ?CallGuard {
        return self.enterCall() catch null;
    }

    fn leaveCall(self: *RealtimeSession) void {
        const previous = self.active_calls.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous == 1) self.io.futexWake(u32, &self.active_calls.raw, std.math.maxInt(u32));
    }

    fn waitForActiveCalls(self: *RealtimeSession) void {
        while (true) {
            const active = self.active_calls.load(.acquire);
            if (active == 0) return;
            self.io.futexWaitUncancelable(u32, &self.active_calls.raw, active);
        }
    }

    fn fail(self: *RealtimeSession, err: anyerror) anyerror {
        self.setStatus(.@"error") catch {};
        self.notifyError(.{ .err = err, .message = @errorName(err) });
        return err;
    }

    fn notifyError(self: *RealtimeSession, info: ErrorInfo) void {
        if (self.on_error) |callback| {
            const callback_guard = self.enterCallback();
            defer callback_guard.deinit();
            callback.call(callback.ctx, info);
        }
    }

    fn onTransportServerEvent(raw: *anyopaque, event: provider.ServerEvent) anyerror!void {
        const self: *RealtimeSession = @ptrCast(@alignCast(raw));
        const guard = try self.enterCall();
        defer guard.deinit();
        return self.handleServerEvent(event);
    }

    fn onTransportError(raw: *anyopaque, err: anyerror) void {
        const self: *RealtimeSession = @ptrCast(@alignCast(raw));
        const guard = self.tryEnterCall() orelse return;
        defer guard.deinit();
        self.setStatus(.@"error") catch {};
        self.notifyError(.{ .err = err, .message = @errorName(err) });
    }

    fn onTransportClose(raw: *anyopaque) void {
        const self: *RealtimeSession = @ptrCast(@alignCast(raw));
        const guard = self.tryEnterCall() orelse return;
        defer guard.deinit();
        self.setStatus(.disconnected) catch {};
    }

    fn onCapturedAudio(raw: *anyopaque, base64_audio: []const u8) void {
        const self: *RealtimeSession = @ptrCast(@alignCast(raw));
        const guard = self.tryEnterCall() orelse return;
        defer guard.deinit();
        self.sendAudio(base64_audio) catch |err| self.notifyError(.{ .err = err, .message = @errorName(err) });
    }
};

fn cloneEffects(arena: Allocator, effects: []const reducer_api.Effect) ![]const reducer_api.Effect {
    const cloned = try arena.alloc(reducer_api.Effect, effects.len);
    for (effects, cloned) |effect, *destination| destination.* = switch (effect) {
        .play_audio => |value| .{ .play_audio = .{
            .item_id = try arena.dupe(u8, value.item_id),
            .delta_base64 = try arena.dupe(u8, value.delta_base64),
        } },
        .speech_started => .{ .speech_started = {} },
        .tool_call => |value| .{ .tool_call = .{
            .call_id = try arena.dupe(u8, value.call_id),
            .name = try arena.dupe(u8, value.name),
            .args_json = try provider_utils.cloneJsonValue(arena, value.args_json),
            .raw = try arena.dupe(u8, value.raw),
        } },
        .err => |value| .{ .err = .{
            .message = try arena.dupe(u8, value.message),
            .code = if (value.code) |code| try arena.dupe(u8, code) else null,
        } },
    };
    return cloned;
}

const ToolTask = struct {
    session: *RealtimeSession,
    handler: ToolCallHandler,
    arena_state: std.heap.ArenaAllocator,
    call: ToolCall,

    fn init(session: *RealtimeSession, handler: ToolCallHandler, source: ToolCall) !*ToolTask {
        const self = try session.gpa.create(ToolTask);
        errdefer session.gpa.destroy(self);
        self.* = .{
            .session = session,
            .handler = handler,
            .arena_state = .init(session.gpa),
            .call = undefined,
        };
        errdefer self.arena_state.deinit();
        const arena = self.arena_state.allocator();
        self.call = .{
            .call_id = try arena.dupe(u8, source.call_id),
            .name = try arena.dupe(u8, source.name),
            .args = try provider_utils.cloneJsonValue(arena, source.args),
            .raw_arguments = try arena.dupe(u8, source.raw_arguments),
        };
        return self;
    }

    fn run(self: *ToolTask) std.Io.Cancelable!void {
        defer self.deinit();
        const output = blk: {
            const callback_guard = self.session.enterCallback();
            defer callback_guard.deinit();
            break :blk self.handler.call(
                self.handler.ctx,
                self.session.io,
                self.arena_state.allocator(),
                self.call,
            ) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.session.notifyError(.{ .err = err, .message = @errorName(err) });
                return;
            };
        };
        if (output) |value| self.session.addToolOutput(self.call.call_id, value) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.RealtimeSessionDisposed) return;
            self.session.notifyError(.{ .err = err, .message = @errorName(err) });
        };
    }

    fn deinit(self: *ToolTask) void {
        const gpa = self.session.gpa;
        self.arena_state.deinit();
        gpa.destroy(self);
    }
};

fn cloneSessionConfig(arena: Allocator, source: provider.SessionConfig) anyerror!provider.SessionConfig {
    const text = try provider.wire.stringifyAlloc(arena, source);
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, text, .{ .allocate = .alloc_always });
    return provider.wire.parse(provider.SessionConfig, arena, value);
}

fn getRealtimeToolDefinitions(
    arena: Allocator,
    tools: tool_api.ToolSet,
    tools_context: ?JsonValue,
    diag: ?*provider.Diagnostics,
) anyerror![]const provider.RealtimeToolDefinition {
    const prepared = (try prompt.prepareTools(arena, tools, null, tools_context, diag)) orelse return &.{};
    const definitions = try arena.alloc(provider.RealtimeToolDefinition, prepared.len);
    var count: usize = 0;
    for (prepared) |item| switch (item) {
        .function => |function| {
            definitions[count] = .{ .function = .{
                .name = function.name,
                .description = function.description,
                .parameters = function.input_schema,
            } };
            count += 1;
        },
        .provider => {},
    };
    return definitions[0..count];
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

const FakeModel = struct {
    fn model(self: *FakeModel) provider.RealtimeModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.RealtimeModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .doCreateClientSecret = createSecret,
        .getWebSocketConfig = websocketConfig,
        .parseServerEvent = parseEvent,
        .serializeClientEvent = serializeEvent,
        .buildSessionConfig = buildConfig,
        .getHealthCheckResponse = null,
    };

    fn providerName(_: *anyopaque) []const u8 {
        return "fake.realtime";
    }
    fn modelId(_: *anyopaque) []const u8 {
        return "fake-model";
    }
    fn createSecret(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.ClientSecretOptions,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.ClientSecretResult {
        return .{ .token = "ephemeral", .url = "ws://fake/realtime" };
    }
    fn websocketConfig(
        _: *anyopaque,
        _: Allocator,
        options: *const provider.WebSocketOptions,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.WebSocketConfig {
        return .{ .url = options.url, .protocols = &.{"realtime"} };
    }
    fn parseEvent(
        _: *anyopaque,
        _: Allocator,
        _: *const JsonValue,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError![]const provider.ServerEvent {
        return &.{};
    }
    fn serializeEvent(
        _: *anyopaque,
        _: std.Io,
        arena: Allocator,
        event: *const provider.ClientEvent,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!JsonValue {
        const text = provider.wire.stringifyAlloc(arena, event.*) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponseDataError,
        };
        return std.json.parseFromSliceLeaky(JsonValue, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidResponseDataError,
        };
    }
    fn buildConfig(
        _: *anyopaque,
        _: Allocator,
        _: *const provider.SessionConfig,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!JsonValue {
        return .null;
    }
};

const FakeTransport = struct {
    allocator: Allocator,
    io: std.Io,
    callbacks: ?TransportCallbacks = null,
    sent: std.ArrayList([]u8) = .empty,
    mutex: std.Io.Mutex = .init,
    outputs_done: std.Io.Event = .unset,
    response_created: std.Io.Event = .unset,
    output_count: usize = 0,
    response_create_count: usize = 0,
    response_create_attempt_count: usize = 0,
    fail_response_create_sends: usize = 0,
    disconnect_count: usize = 0,
    deinit_count: usize = 0,
    disconnect_entered: ?*std.Io.Event = null,
    disconnect_release: ?*std.Io.Event = null,
    connected: bool = false,
    deinitialized: bool = false,

    fn transport(self: *FakeTransport) RealtimeTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn cleanup(self: *FakeTransport) void {
        for (self.sent.items) |message| self.allocator.free(message);
        self.sent.deinit(self.allocator);
    }

    fn emit(self: *FakeTransport, event: provider.ServerEvent) !void {
        return self.callbacks.?.on_server_event(self.callbacks.?.ctx, event);
    }

    fn countContaining(self: *FakeTransport, needle: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.sent.items) |message| if (std.mem.indexOf(u8, message, needle) != null) {
            count += 1;
        };
        return count;
    }

    const vtable: RealtimeTransport.VTable = .{
        .connect = connect,
        .send_event = sendEvent,
        .send_raw = sendRaw,
        .disconnect = disconnect,
        .deinit = deinitTransport,
    };

    fn fromRaw(raw: *anyopaque) *FakeTransport {
        return @ptrCast(@alignCast(raw));
    }
    fn connect(
        raw: *anyopaque,
        _: TransportConnectConfig,
        callbacks: TransportCallbacks,
        _: ?*provider.Diagnostics,
    ) anyerror!void {
        const self = fromRaw(raw);
        self.callbacks = callbacks;
        self.connected = true;
    }
    fn sendEvent(raw: *anyopaque, event: provider.ClientEvent, _: ?*provider.Diagnostics) anyerror!void {
        const self = fromRaw(raw);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (event == .response_create) {
            self.response_create_attempt_count += 1;
            if (self.fail_response_create_sends != 0) {
                self.fail_response_create_sends -= 1;
                return error.ScriptedResponseCreateFailure;
            }
        }
        const text = try provider.wire.stringifyAlloc(self.allocator, event);
        try self.sent.append(self.allocator, text);
        switch (event) {
            .response_create => {
                self.response_create_count += 1;
                self.response_created.set(self.io);
            },
            .conversation_item_create => |value| switch (value.item) {
                .function_call_output => {
                    self.output_count += 1;
                    if (self.output_count >= 2) self.outputs_done.set(self.io);
                },
                else => {},
            },
            else => {},
        }
    }
    fn sendRaw(_: *anyopaque, _: RawMessage) anyerror!void {}
    fn disconnect(raw: *anyopaque) void {
        const self = fromRaw(raw);
        self.mutex.lockUncancelable(self.io);
        self.connected = false;
        self.disconnect_count += 1;
        const entered = self.disconnect_entered;
        const release = self.disconnect_release;
        self.mutex.unlock(self.io);
        if (entered) |event| event.set(self.io);
        if (release) |event| event.waitUncancelable(self.io);
    }
    fn deinitTransport(raw: *anyopaque) void {
        const self = fromRaw(raw);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.deinitialized = true;
        self.deinit_count += 1;
    }
};

const FakeAudio = struct {
    offset_ms: u64 = 0,
    played_item: [64]u8 = undefined,
    played_item_len: usize = 0,
    stopped: bool = false,

    fn audio(self: *FakeAudio) RealtimeAudio {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: RealtimeAudio.VTable = .{
        .play = play,
        .stop_playback = stop,
        .playback_offset_ms = offset,
        .start_capture = startCapture,
        .stop_capture = stopCapture,
        .deinit = deinitAudio,
    };
    fn fromRaw(raw: *anyopaque) *FakeAudio {
        return @ptrCast(@alignCast(raw));
    }
    fn play(raw: *anyopaque, _: std.Io, item_id: []const u8, _: AudioPayload) anyerror!void {
        const self = fromRaw(raw);
        self.played_item_len = @min(item_id.len, self.played_item.len);
        @memcpy(self.played_item[0..self.played_item_len], item_id[0..self.played_item_len]);
    }
    fn stop(raw: *anyopaque, _: std.Io) void {
        fromRaw(raw).stopped = true;
    }
    fn offset(raw: *anyopaque) u64 {
        return fromRaw(raw).offset_ms;
    }
    fn startCapture(_: *anyopaque, _: std.Io, _: CaptureCallback) anyerror!void {}
    fn stopCapture(_: *anyopaque, _: std.Io) void {}
    fn deinitAudio(_: *anyopaque, _: std.Io) void {}
};

const StateRecorder = struct {
    status: reducer_api.Status = .disconnected,
    status_changes: usize = 0,
    message_changes: usize = 0,

    fn callbacks(self: *StateRecorder) StateCallbacks {
        return .{
            .ctx = self,
            .on_status = onStatus,
            .on_messages = onMessages,
        };
    }
    fn onStatus(raw: ?*anyopaque, value: reducer_api.Status) void {
        const self: *StateRecorder = @ptrCast(@alignCast(raw.?));
        self.status = value;
        self.status_changes += 1;
    }
    fn onMessages(raw: ?*anyopaque, _: []const @import("../ui/ui_messages.zig").UIMessage) void {
        const self: *StateRecorder = @ptrCast(@alignCast(raw.?));
        self.message_changes += 1;
    }
};

const ErrorRecorder = struct {
    count: std.atomic.Value(usize) = .init(0),

    fn callback(self: *ErrorRecorder) ErrorCallback {
        return .{ .ctx = self, .call = onError };
    }

    fn onError(raw: ?*anyopaque, _: ErrorInfo) void {
        const self: *ErrorRecorder = @ptrCast(@alignCast(raw.?));
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

fn functionDone(call_id: []const u8, name: []const u8) provider.ServerEvent {
    return .{ .function_call_arguments_done = .{
        .response_id = "response-1",
        .item_id = "item-1",
        .call_id = call_id,
        .name = name,
        .arguments = "{}",
        .raw = .null,
    } };
}

fn responseDone() provider.ServerEvent {
    return .{ .response_done = .{
        .response_id = "response-1",
        .status = "completed",
        .raw = .null,
    } };
}

test "RealtimeSession connect publishes state and sends session update" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    var recorder: StateRecorder = .{};
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .state_callbacks = recorder.callbacks(),
    });
    defer session.dispose();

    try session.connect();
    try std.testing.expect(transport.connected);
    try std.testing.expectEqual(reducer_api.Status.connecting, recorder.status);
    try std.testing.expectEqual(1, transport.countContaining("session-update"));
    try transport.emit(.{ .session_created = .{ .session_id = "session-1", .raw = .null } });
    try std.testing.expectEqual(reducer_api.Status.connected, recorder.status);

    try session.sendTextMessage("hello");
    try std.testing.expectEqual(1, recorder.message_changes);
    try std.testing.expectEqual(1, transport.countContaining("text-message"));
}

test "RealtimeSession coalesces a stale publication after a newer snapshot is delivered" {
    const Recorder = struct {
        deliveries: usize = 0,
        message_count: usize = 0,
        last_text: [32]u8 = undefined,
        last_text_len: usize = 0,

        fn messages(raw: ?*anyopaque, values: []const ui.UIMessage) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.deliveries += 1;
            self.message_count = values.len;
            const text = values[values.len - 1].parts[0].text.text;
            self.last_text_len = @min(text.len, self.last_text.len);
            @memcpy(self.last_text[0..self.last_text_len], text[0..self.last_text_len]);
        }
    };
    const Interleaving = struct {
        session: *RealtimeSession,
        io: std.Io,
        older_built: std.Io.Event = .unset,
        newer_dispatched: std.Io.Event = .unset,
        failed: std.atomic.Value(bool) = .init(false),

        fn recordFailure(self: *@This()) void {
            self.failed.store(true, .release);
            self.older_built.set(self.io);
            self.newer_dispatched.set(self.io);
        }

        fn buildOlder(self: *@This()) void {
            var publication = self.session.addUserTextPublication("older") catch {
                self.recordFailure();
                return;
            };
            self.older_built.set(self.io);
            self.newer_dispatched.waitUncancelable(self.io);
            self.session.dispatchPublication(&publication) catch {
                self.recordFailure();
            };
        }

        fn buildNewer(self: *@This()) void {
            self.older_built.waitUncancelable(self.io);
            var publication = self.session.addUserTextPublication("newer") catch {
                self.recordFailure();
                return;
            };
            self.session.dispatchPublication(&publication) catch {
                self.recordFailure();
                return;
            };
            self.newer_dispatched.set(self.io);
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    var recorder: Recorder = .{};
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .state_callbacks = .{ .ctx = &recorder, .on_messages = Recorder.messages },
    });
    defer session.dispose();

    var interleaving: Interleaving = .{ .session = session, .io = io };
    const older_thread = try std.Thread.spawn(.{}, Interleaving.buildOlder, .{&interleaving});
    const newer_thread = std.Thread.spawn(.{}, Interleaving.buildNewer, .{&interleaving}) catch |err| {
        interleaving.recordFailure();
        older_thread.join();
        return err;
    };
    older_thread.join();
    newer_thread.join();

    try std.testing.expect(!interleaving.failed.load(.acquire));
    try std.testing.expectEqual(1, recorder.deliveries);
    try std.testing.expectEqual(2, recorder.message_count);
    try std.testing.expectEqualStrings("newer", recorder.last_text[0..recorder.last_text_len]);
}

test "RealtimeSession newer status publication does not swallow an older messages publication" {
    const Recorder = struct {
        status_deliveries: usize = 0,
        status: reducer_api.Status = .disconnected,
        message_deliveries: usize = 0,
        message_count: usize = 0,

        fn statusChanged(raw: ?*anyopaque, value: reducer_api.Status) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.status_deliveries += 1;
            self.status = value;
        }

        fn messages(raw: ?*anyopaque, values: []const ui.UIMessage) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.message_deliveries += 1;
            self.message_count = values.len;
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    var recorder: Recorder = .{};
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .state_callbacks = .{
            .ctx = &recorder,
            .on_status = Recorder.statusChanged,
            .on_messages = Recorder.messages,
        },
    });
    defer session.dispose();

    var messages_publication = try session.addUserTextPublication("message");
    var status_publication = session.setStatusPublication(.connecting) catch |err| {
        messages_publication.deinit();
        return err;
    };
    session.dispatchPublication(&status_publication) catch |err| {
        messages_publication.deinit();
        return err;
    };
    try session.dispatchPublication(&messages_publication);

    try std.testing.expectEqual(1, recorder.status_deliveries);
    try std.testing.expectEqual(reducer_api.Status.connecting, recorder.status);
    try std.testing.expectEqual(1, recorder.message_deliveries);
    try std.testing.expectEqual(1, recorder.message_count);
}

test "RealtimeSession queues a publication triggered by a reentrant state callback" {
    const Reentrant = struct {
        session: ?*RealtimeSession = null,
        deliveries: usize = 0,
        first_snapshot_correct: bool = false,
        second_snapshot_correct: bool = false,
        in_callback: bool = false,
        callbacks_overlapped: bool = false,
        send_failed: bool = false,

        fn messages(raw: ?*anyopaque, values: []const ui.UIMessage) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.in_callback) self.callbacks_overlapped = true;
            self.in_callback = true;
            defer self.in_callback = false;

            self.deliveries += 1;
            if (self.deliveries == 1) {
                self.first_snapshot_correct = values.len == 1 and
                    std.mem.eql(u8, values[0].parts[0].text.text, "outer");
                self.session.?.sendTextMessage("inner") catch {
                    self.send_failed = true;
                };
            } else if (self.deliveries == 2) {
                self.second_snapshot_correct = values.len == 2 and
                    std.mem.eql(u8, values[0].parts[0].text.text, "outer") and
                    std.mem.eql(u8, values[1].parts[0].text.text, "inner");
            }
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    var reentrant: Reentrant = .{};
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .state_callbacks = .{ .ctx = &reentrant, .on_messages = Reentrant.messages },
    });
    defer session.dispose();
    reentrant.session = session;

    try session.sendTextMessage("outer");

    try std.testing.expect(!reentrant.send_failed);
    try std.testing.expect(!reentrant.callbacks_overlapped);
    try std.testing.expectEqual(2, reentrant.deliveries);
    try std.testing.expect(reentrant.first_snapshot_correct);
    try std.testing.expect(reentrant.second_snapshot_correct);
}

test "RealtimeSession gates out-of-order multi-tool outputs behind response done" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    const Manual = struct {
        fn call(_: ?*anyopaque, _: std.Io, _: Allocator, _: ToolCall) anyerror!?JsonValue {
            return null;
        }
    };
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .on_tool_call = .{ .call = Manual.call },
    });
    defer session.dispose();
    try session.connect();

    try transport.emit(functionDone("call-1", "one"));
    try transport.emit(functionDone("call-2", "two"));
    try transport.emit(responseDone());
    try session.addToolOutput("call-2", .{ .string = "second" });
    try std.testing.expectEqual(0, transport.response_create_count);
    try session.addToolOutput("call-1", .{ .string = "first" });
    try std.testing.expectEqual(1, transport.response_create_count);
    try std.testing.expectEqual(2, transport.output_count);
}

test "RealtimeSession auto tool outputs request one response when response closes last" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    const Automatic = struct {
        fn call(_: ?*anyopaque, _: std.Io, _: Allocator, tool_call: ToolCall) anyerror!?JsonValue {
            return .{ .string = tool_call.name };
        }
    };
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .on_tool_call = .{ .call = Automatic.call },
    });
    defer session.dispose();
    try session.connect();

    try transport.emit(functionDone("call-1", "one"));
    try transport.emit(functionDone("call-2", "two"));
    try transport.outputs_done.wait(io);
    try std.testing.expectEqual(0, transport.response_create_count);
    try transport.emit(responseDone());
    try transport.response_created.wait(io);
    try std.testing.expectEqual(1, transport.response_create_count);
}

test "RealtimeSession barge-in stops playback and sends rounded truncate offset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    var audio: FakeAudio = .{ .offset_ms = 1_234 };
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .audio = audio.audio(),
    });
    defer session.dispose();
    try session.connect();

    try transport.emit(.{ .audio_delta = .{
        .response_id = "response-1",
        .item_id = "assistant-item",
        .delta = "AA==",
        .raw = .null,
    } });
    try std.testing.expectEqualStrings("assistant-item", audio.played_item[0..audio.played_item_len]);
    try transport.emit(.{ .speech_started = .{ .item_id = "user-item", .raw = .null } });
    try std.testing.expect(audio.stopped);
    try std.testing.expectEqual(1, transport.countContaining("conversation-item-truncate"));
    try std.testing.expectEqual(1, transport.countContaining("1234"));
}

test "RealtimeSession callbacks receive owned snapshots and reject reentrant disposal" {
    const Reentrant = struct {
        session: ?*RealtimeSession = null,
        snapshot_valid: bool = false,
        callback_returned: bool = false,

        fn messages(raw: ?*anyopaque, values: []const ui.UIMessage) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const snapshot = self.session.?.state(arena_state.allocator()) catch return;
            self.snapshot_valid = values.len == 1 and snapshot.messages.len == 1 and
                std.mem.eql(u8, values[0].parts[0].text.text, "hello") and
                std.mem.eql(u8, snapshot.messages[0].parts[0].text.text, "hello");
            self.session.?.dispose();
            self.callback_returned = true;
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    var reentrant: Reentrant = .{};
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .state_callbacks = .{ .ctx = &reentrant, .on_messages = Reentrant.messages },
    });
    reentrant.session = session;
    try session.connect();

    try session.sendTextMessage("hello");
    try std.testing.expect(reentrant.snapshot_valid);
    try std.testing.expect(reentrant.callback_returned);
    try std.testing.expectEqual(1, transport.disconnect_count);
    try std.testing.expectEqual(1, transport.deinit_count);
}

test "RealtimeSession retries a failed gated response create without losing state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{
        .allocator = allocator,
        .io = io,
        .fail_response_create_sends = 1,
    };
    defer transport.cleanup();
    var errors: ErrorRecorder = .{};
    const Manual = struct {
        fn call(_: ?*anyopaque, _: std.Io, _: Allocator, _: ToolCall) anyerror!?JsonValue {
            return null;
        }
    };
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
        .on_tool_call = .{ .call = Manual.call },
        .on_error = errors.callback(),
    });
    defer session.dispose();
    try session.connect();

    try transport.emit(functionDone("call-1", "one"));
    try transport.emit(responseDone());
    try std.testing.expectError(
        error.ScriptedResponseCreateFailure,
        session.addToolOutput("call-1", .{ .string = "result" }),
    );

    {
        session.state_mutex.lockUncancelable(io);
        defer session.state_mutex.unlock(io);
        try std.testing.expectEqual(1, session.tool_calls_in_response.count());
        try std.testing.expectEqual(1, session.submitted_tool_outputs.count());
        try std.testing.expect(session.response_tool_calls_closed);
        try std.testing.expect(!session.tool_response_send_in_flight);
    }
    try std.testing.expectEqual(1, transport.response_create_attempt_count);
    try std.testing.expectEqual(0, transport.response_create_count);
    try std.testing.expectEqual(1, errors.count.load(.acquire));

    try transport.emit(responseDone());
    try std.testing.expectEqual(2, transport.response_create_attempt_count);
    try std.testing.expectEqual(1, transport.response_create_count);
    {
        session.state_mutex.lockUncancelable(io);
        defer session.state_mutex.unlock(io);
        try std.testing.expectEqual(0, session.tool_calls_in_response.count());
        try std.testing.expectEqual(0, session.submitted_tool_outputs.count());
        try std.testing.expect(!session.response_tool_calls_closed);
        try std.testing.expect(!session.tool_response_send_in_flight);
    }
}

test "RealtimeSession callback dispose collapses while external dispose is in flight" {
    const CallbackContext = struct {
        session: *RealtimeSession,
        io: std.Io,
        dispose_requested: std.Io.Event = .unset,
        disconnect_entered: std.Io.Event = .unset,
        callback_dispose_returned: std.Io.Event = .unset,

        fn messages(raw: ?*anyopaque, _: []const ui.UIMessage) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.session.dispose();
            self.dispose_requested.set(self.io);
            self.disconnect_entered.waitUncancelable(self.io);
            self.callback_dispose_returned.set(self.io);
        }
    };
    const Emitter = struct {
        session: *RealtimeSession,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.session.sendTextMessage("race") catch self.failed.store(true, .release);
        }
    };
    const Disposer = struct {
        fn run(session: *RealtimeSession) void {
            session.dispose();
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var model: FakeModel = .{};
    var transport: FakeTransport = .{ .allocator = allocator, .io = io };
    defer transport.cleanup();
    const session = try RealtimeSession.init(allocator, io, .{
        .model = model.model(),
        .transport = transport.transport(),
    });
    try session.connect();
    var callback_context: CallbackContext = .{ .session = session, .io = io };
    session.state_callbacks = .{ .ctx = &callback_context, .on_messages = CallbackContext.messages };
    transport.disconnect_entered = &callback_context.disconnect_entered;

    var emitter: Emitter = .{ .session = session };
    const emitter_thread = try std.Thread.spawn(.{}, Emitter.run, .{&emitter});
    callback_context.dispose_requested.waitUncancelable(io);
    const dispose_thread = try std.Thread.spawn(.{}, Disposer.run, .{session});
    callback_context.disconnect_entered.waitUncancelable(io);
    callback_context.callback_dispose_returned.waitUncancelable(io);
    emitter_thread.join();
    dispose_thread.join();

    try std.testing.expect(!emitter.failed.load(.acquire));
    try std.testing.expectEqual(1, transport.disconnect_count);
    try std.testing.expectEqual(1, transport.deinit_count);
}

test "RealtimeSession drops delayed tool outputs during disposal" {
    const DelayedTool = struct {
        io: std.Io,
        started: std.Io.Event = .unset,
        returned: std.Io.Event = .unset,

        fn call(
            raw: ?*anyopaque,
            task_io: std.Io,
            _: Allocator,
            _: ToolCall,
        ) anyerror!?JsonValue {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.started.set(self.io);
            task_io.sleep(.fromSeconds(30), .awake) catch |err| switch (err) {
                error.Canceled => {},
            };
            self.returned.set(self.io);
            return .{ .string = "late-output" };
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for (0..50) |_| {
        var model: FakeModel = .{};
        var transport: FakeTransport = .{ .allocator = allocator, .io = io };
        defer transport.cleanup();
        var delayed: DelayedTool = .{ .io = io };
        const session = try RealtimeSession.init(allocator, io, .{
            .model = model.model(),
            .transport = transport.transport(),
            .on_tool_call = .{ .ctx = &delayed, .call = DelayedTool.call },
        });
        try session.connect();
        try transport.emit(functionDone("call-1", "one"));
        delayed.started.waitUncancelable(io);

        session.dispose();

        try std.testing.expect(delayed.returned.isSet());
        try std.testing.expectEqual(0, transport.output_count);
        try std.testing.expectEqual(1, transport.disconnect_count);
        try std.testing.expectEqual(1, transport.deinit_count);
    }
}

test "RealtimeSession external disposal waits for an active transport callback" {
    const BlockingCallback = struct {
        io: std.Io,
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn event(raw: ?*anyopaque, _: provider.ServerEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.entered.set(self.io);
            self.release.waitUncancelable(self.io);
        }
    };
    const Emitter = struct {
        transport: *FakeTransport,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.transport.emit(.{ .session_created = .{
                .session_id = "session-1",
                .raw = .null,
            } }) catch self.failed.store(true, .release);
        }
    };
    const Disposer = struct {
        fn run(session: *RealtimeSession) void {
            session.dispose();
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for (0..50) |_| {
        var model: FakeModel = .{};
        var transport: FakeTransport = .{ .allocator = allocator, .io = io };
        defer transport.cleanup();
        const session = try RealtimeSession.init(allocator, io, .{
            .model = model.model(),
            .transport = transport.transport(),
        });
        try session.connect();
        var callback: BlockingCallback = .{ .io = io };
        session.on_event = .{ .ctx = &callback, .call = BlockingCallback.event };
        var disconnect_entered: std.Io.Event = .unset;
        transport.disconnect_entered = &disconnect_entered;

        var emitter: Emitter = .{ .transport = &transport };
        const emitter_thread = try std.Thread.spawn(.{}, Emitter.run, .{&emitter});
        callback.entered.waitUncancelable(io);
        const dispose_thread = try std.Thread.spawn(.{}, Disposer.run, .{session});
        disconnect_entered.waitUncancelable(io);
        callback.release.set(io);
        emitter_thread.join();
        dispose_thread.join();

        try std.testing.expect(!emitter.failed.load(.acquire));
        try std.testing.expectEqual(1, transport.disconnect_count);
        try std.testing.expectEqual(1, transport.deinit_count);
    }
}
