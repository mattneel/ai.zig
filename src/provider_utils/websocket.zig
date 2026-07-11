//! RFC 6455 client transport built on top of `std.http.Client`.
//!
//! The HTTP client owns the TCP/TLS setup and the upgrade request. After a
//! validated 101 response this module takes ownership of the connection and
//! runs a dedicated receive task plus an optional keepalive task. Application
//! writes, automatic pongs, keepalive pings, and close frames share one mutex.

const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Opcode = std.http.Server.WebSocket.Opcode;
const Header0 = std.http.Server.WebSocket.Header0;
const Header1 = std.http.Server.WebSocket.Header1;

pub const default_max_message_size: usize = 4 * 1024 * 1024;
pub const default_idle_ms: u64 = 30_000;
pub const default_close_timeout_ms: u64 = 5_000;
pub const default_queue_capacity: usize = 32;

pub const MessageKind = enum {
    text,
    binary,
};

/// `payload` remains valid until the next `receive` call on the same socket.
pub const Message = struct {
    kind: MessageKind,
    payload: []const u8,
};

/// The peer close reason remains valid until the socket is deinitialized.
pub const CloseInfo = struct {
    code: ?u16,
    reason: []const u8,
};

pub const ConnectOptions = struct {
    protocols: []const []const u8 = &.{},
    headers: []const provider.Header = &.{},
    max_message_size: usize = default_max_message_size,
    idle_ms: u64 = default_idle_ms,
    close_timeout_ms: u64 = default_close_timeout_ms,
    queue_capacity: usize = default_queue_capacity,
};

pub const WebSocketLikeVTable = struct {
    send: *const fn (ctx: *anyopaque, kind: MessageKind, payload: []const u8) anyerror!void,
    receive: *const fn (ctx: *anyopaque, io: Io) anyerror!?Message,
    close: *const fn (ctx: *anyopaque, code: u16, reason: []const u8) anyerror!void,
    negotiated_protocol: *const fn (ctx: *const anyopaque) ?[]const u8,
    close_info: *const fn (ctx: *const anyopaque) ?CloseInfo,
    deinit: *const fn (ctx: *anyopaque) void,
};

/// Injection surface used by realtime sessions, transcription, tests, and FFI.
pub const WebSocketLike = struct {
    ctx: *anyopaque,
    vtable: *const WebSocketLikeVTable,

    pub fn send(self: WebSocketLike, kind: MessageKind, payload: []const u8) !void {
        return self.vtable.send(self.ctx, kind, payload);
    }

    pub fn sendText(self: WebSocketLike, payload: []const u8) !void {
        return self.send(.text, payload);
    }

    pub fn sendBinary(self: WebSocketLike, payload: []const u8) !void {
        return self.send(.binary, payload);
    }

    pub fn receive(self: WebSocketLike, io: Io) !?Message {
        return self.vtable.receive(self.ctx, io);
    }

    pub fn close(self: WebSocketLike, code: u16, reason: []const u8) !void {
        return self.vtable.close(self.ctx, code, reason);
    }

    pub fn negotiatedProtocol(self: WebSocketLike) ?[]const u8 {
        return self.vtable.negotiated_protocol(self.ctx);
    }

    pub fn closeInfo(self: WebSocketLike) ?CloseInfo {
        return self.vtable.close_info(self.ctx);
    }

    pub fn deinit(self: *WebSocketLike) void {
        self.vtable.deinit(self.ctx);
        self.* = undefined;
    }
};

pub const WebSocketFactoryVTable = struct {
    connect: *const fn (
        ctx: ?*anyopaque,
        gpa: Allocator,
        io: Io,
        url: []const u8,
        options: ConnectOptions,
        diag: ?*provider.Diagnostics,
    ) anyerror!WebSocketLike,
};

pub const WebSocketFactory = struct {
    ctx: ?*anyopaque = null,
    vtable: *const WebSocketFactoryVTable,

    pub fn connect(
        self: WebSocketFactory,
        gpa: Allocator,
        io: Io,
        url: []const u8,
        options: ConnectOptions,
        diag: ?*provider.Diagnostics,
    ) !WebSocketLike {
        return self.vtable.connect(self.ctx, gpa, io, url, options, diag);
    }
};

pub const default_factory: WebSocketFactory = .{ .vtable = &real_factory_vtable };

const real_factory_vtable: WebSocketFactoryVTable = .{ .connect = realFactoryConnect };

fn realFactoryConnect(
    _: ?*anyopaque,
    gpa: Allocator,
    io: Io,
    url: []const u8,
    options: ConnectOptions,
    diag: ?*provider.Diagnostics,
) !WebSocketLike {
    const socket = try RealWebSocket.connect(gpa, io, url, options, diag);
    return socket.websocket();
}

pub fn toWebSocketUrl(allocator: Allocator, url: []const u8) ![]u8 {
    const separator = std.mem.indexOf(u8, url, "://") orelse return error.UnsupportedUriScheme;
    const scheme = url[0..separator];
    const suffix = url[separator + "://".len ..];
    if (std.ascii.eqlIgnoreCase(scheme, "ws"))
        return std.fmt.allocPrint(allocator, "ws://{s}", .{suffix});
    if (std.ascii.eqlIgnoreCase(scheme, "wss"))
        return std.fmt.allocPrint(allocator, "wss://{s}", .{suffix});
    if (std.ascii.eqlIgnoreCase(scheme, "http"))
        return std.fmt.allocPrint(allocator, "ws://{s}", .{suffix});
    if (std.ascii.eqlIgnoreCase(scheme, "https"))
        return std.fmt.allocPrint(allocator, "wss://{s}", .{suffix});
    return error.UnsupportedUriScheme;
}

pub const RealWebSocket = struct {
    gpa: Allocator,
    io: Io,
    client: std.http.Client,
    connection: ?*std.http.Client.Connection,
    negotiated_protocol: ?[]u8,
    max_message_size: usize,
    idle_ms: u64,
    close_timeout_ms: u64,

    writer_mutex: Io.Mutex,
    lifecycle_mutex: Io.Mutex,
    tasks: Io.Group,
    activity_epoch: std.atomic.Value(u32),
    stop_requested: std.atomic.Value(bool),
    close_sent: std.atomic.Value(bool),
    tearing_down: std.atomic.Value(bool),
    finalized: std.atomic.Value(bool),
    peer_close: Io.Event,

    inbound_storage: []Inbound,
    inbound: Io.Queue(Inbound),
    last_payload: ?[]u8,
    last_close_payload: ?[]u8,
    last_close: ?CloseInfo,

    const OwnedMessage = struct {
        kind: MessageKind,
        payload: []u8,
    };

    const OwnedClose = struct {
        code: ?u16,
        payload: []u8,
    };

    const Inbound = union(enum) {
        message: OwnedMessage,
        closed: OwnedClose,
        failure: anyerror,
    };

    const Frame = struct {
        opcode: Opcode,
        fin: bool,
        payload: []u8,
    };

    pub fn connect(
        gpa: Allocator,
        io: Io,
        url: []const u8,
        options: ConnectOptions,
        diag: ?*provider.Diagnostics,
    ) !*RealWebSocket {
        if (options.max_message_size == 0) return error.InvalidMaximumMessageSize;
        if (options.queue_capacity == 0) return error.InvalidQueueCapacity;
        if (options.close_timeout_ms > std.math.maxInt(i64)) return error.InvalidCloseTimeout;
        if (options.idle_ms > std.math.maxInt(i64)) return error.InvalidIdleTimeout;
        try validateProtocols(options.protocols);
        try validateExtraHeaders(options.headers);

        const self = try gpa.create(RealWebSocket);
        errdefer gpa.destroy(self);
        const inbound_storage = try gpa.alloc(Inbound, options.queue_capacity);
        errdefer gpa.free(inbound_storage);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .client = .{ .allocator = gpa, .io = io },
            .connection = null,
            .negotiated_protocol = null,
            .max_message_size = options.max_message_size,
            .idle_ms = options.idle_ms,
            .close_timeout_ms = options.close_timeout_ms,
            .writer_mutex = .init,
            .lifecycle_mutex = .init,
            .tasks = .init,
            .activity_epoch = .init(0),
            .stop_requested = .init(false),
            .close_sent = .init(false),
            .tearing_down = .init(false),
            .finalized = .init(false),
            .peer_close = .unset,
            .inbound_storage = inbound_storage,
            .inbound = .init(inbound_storage),
            .last_payload = null,
            .last_close_payload = null,
            .last_close = null,
        };
        errdefer self.drainInbound();
        errdefer self.client.deinit();

        try self.performHandshake(url, options.protocols, options.headers);
        errdefer self.freeNegotiatedProtocol();
        errdefer self.destroyTakenConnection();

        self.tasks.concurrent(io, receiveTask, .{self}) catch |err| {
            setConcurrencyDiagnostic(diag);
            return err;
        };
        if (options.idle_ms != 0) {
            self.tasks.concurrent(io, keepaliveTask, .{self}) catch |err| {
                self.tasks.cancel(io);
                setConcurrencyDiagnostic(diag);
                return err;
            };
        }

        return self;
    }

    pub fn websocket(self: *RealWebSocket) WebSocketLike {
        return .{ .ctx = self, .vtable = &like_vtable };
    }

    fn performHandshake(
        self: *RealWebSocket,
        url: []const u8,
        protocols: []const []const u8,
        supplied_headers: []const provider.Header,
    ) !void {
        errdefer self.freeNegotiatedProtocol();
        const uri = try std.Uri.parse(url);

        var raw_key: [16]u8 = undefined;
        self.io.random(&raw_key);
        var encoded_key: [24]u8 = undefined;
        std.debug.assert(std.base64.standard.Encoder.encode(&encoded_key, &raw_key).len == encoded_key.len);

        var protocol_writer: Io.Writer.Allocating = .init(self.gpa);
        defer protocol_writer.deinit();
        for (protocols, 0..) |protocol, index| {
            if (index != 0) try protocol_writer.writer.writeAll(", ");
            try protocol_writer.writer.writeAll(protocol);
        }
        const joined_protocols = protocol_writer.writer.buffered();

        const required_count: usize = 3 + @as(usize, @intFromBool(protocols.len != 0));
        const headers = try self.gpa.alloc(std.http.Header, required_count + supplied_headers.len);
        defer self.gpa.free(headers);
        headers[0] = .{ .name = "upgrade", .value = "websocket" };
        headers[1] = .{ .name = "sec-websocket-version", .value = "13" };
        headers[2] = .{ .name = "sec-websocket-key", .value = &encoded_key };
        var next: usize = 3;
        if (protocols.len != 0) {
            headers[next] = .{ .name = "sec-websocket-protocol", .value = joined_protocols };
            next += 1;
        }
        for (supplied_headers) |header| {
            headers[next] = .{ .name = header.name, .value = header.value };
            next += 1;
        }

        var request = try self.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .host = if (hasHeader(supplied_headers, "host")) .omit else .default,
                .authorization = if (hasHeader(supplied_headers, "authorization")) .omit else .default,
                .user_agent = if (hasHeader(supplied_headers, "user-agent")) .omit else .default,
                .connection = .{ .override = "Upgrade" },
                .accept_encoding = .omit,
                .content_type = if (hasHeader(supplied_headers, "content-type")) .omit else .default,
            },
            .extra_headers = headers,
        });
        errdefer request.deinit();

        try request.sendBodiless();
        const response = try request.receiveHead(&.{});
        if (response.head.status != .switching_protocols) return error.WebSocketHandshakeRejected;

        var accept: ?[]const u8 = null;
        var negotiated: ?[]const u8 = null;
        var saw_upgrade = false;
        var saw_connection_upgrade = false;
        var saw_extensions = false;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
                if (accept != null) return error.InvalidWebSocketAccept;
                accept = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) {
                if (negotiated != null) return error.InvalidNegotiatedProtocol;
                negotiated = std.mem.trim(u8, header.value, " \t");
            } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
                saw_upgrade = saw_upgrade or
                    headerContainsToken(header.value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
                saw_connection_upgrade = saw_connection_upgrade or headerContainsToken(header.value, "upgrade");
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-extensions")) {
                saw_extensions = true;
            }
        }
        if (!saw_upgrade or !saw_connection_upgrade) return error.InvalidWebSocketUpgrade;
        if (saw_extensions) return error.UnsupportedWebSocketExtension;

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(&encoded_key);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        sha1.final(&digest);
        var expected_accept: [28]u8 = undefined;
        std.debug.assert(std.base64.standard.Encoder.encode(&expected_accept, &digest).len == expected_accept.len);
        if (accept == null or !std.mem.eql(u8, accept.?, &expected_accept))
            return error.InvalidWebSocketAccept;

        if (negotiated) |protocol| {
            if (protocols.len == 0 or !containsProtocol(protocols, protocol))
                return error.InvalidNegotiatedProtocol;
            self.negotiated_protocol = try self.gpa.dupe(u8, protocol);
        }

        const connection = request.connection orelse return error.WebSocketConnectionMissing;
        request.connection = null;
        request.deinit();
        self.connection = connection;
    }

    fn send(self: *RealWebSocket, kind: MessageKind, payload: []const u8) !void {
        if (kind == .text and !std.unicode.utf8ValidateSlice(payload))
            return error.InvalidTextEncoding;
        if (self.close_sent.load(.acquire) or
            self.tearing_down.load(.acquire) or
            self.finalized.load(.acquire))
            return error.WebSocketClosed;
        try self.writeFrame(switch (kind) {
            .text => .text,
            .binary => .binary,
        }, payload, true, false);
    }

    fn receive(self: *RealWebSocket, io: Io) !?Message {
        if (self.last_payload) |payload| {
            self.gpa.free(payload);
            self.last_payload = null;
        }

        const inbound = self.inbound.getOne(io) catch |err| switch (err) {
            error.Closed => return null,
            error.Canceled => return error.Canceled,
        };
        return switch (inbound) {
            .message => |owned| blk: {
                self.last_payload = owned.payload;
                break :blk .{ .kind = owned.kind, .payload = owned.payload };
            },
            .closed => |owned| blk: {
                if (self.last_close_payload) |payload| self.gpa.free(payload);
                self.last_close_payload = owned.payload;
                self.last_close = .{
                    .code = owned.code,
                    .reason = if (owned.code == null) "" else owned.payload[2..],
                };
                break :blk null;
            },
            .failure => |err| return err,
        };
    }

    fn close(self: *RealWebSocket, code: u16, reason: []const u8) !void {
        if (!validCloseCode(code)) return error.InvalidCloseCode;
        if (reason.len > 123 or !std.unicode.utf8ValidateSlice(reason))
            return error.InvalidCloseReason;
        if (self.finalized.load(.acquire)) return;
        if (self.tearing_down.load(.acquire)) {
            self.finalize();
            return;
        }
        errdefer self.finalize();

        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        @memcpy(payload[2..][0..reason.len], reason);
        try self.sendCloseOnce(payload[0 .. reason.len + 2]);

        const timeout: Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(self.close_timeout_ms)),
            .clock = .awake,
        } };
        self.peer_close.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        self.finalize();
    }

    fn closeInfo(self: *const RealWebSocket) ?CloseInfo {
        return self.last_close;
    }

    fn negotiatedProtocol(self: *const RealWebSocket) ?[]const u8 {
        return self.negotiated_protocol;
    }

    fn deinit(self: *RealWebSocket) void {
        if (!self.finalized.load(.acquire)) {
            self.close(1000, "") catch self.finalize();
        }
        if (self.last_payload) |payload| self.gpa.free(payload);
        if (self.last_close_payload) |payload| self.gpa.free(payload);
        self.drainInbound();
        if (self.negotiated_protocol) |protocol| self.gpa.free(protocol);
        self.gpa.free(self.inbound_storage);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn receiveTask(self: *RealWebSocket) Io.Cancelable!void {
        return self.receiveLoop();
    }

    fn keepaliveTask(self: *RealWebSocket) Io.Cancelable!void {
        const idle_duration: Io.Clock.Duration = .{
            .raw = .fromMilliseconds(@intCast(self.idle_ms)),
            .clock = .awake,
        };
        var observed = self.activity_epoch.load(.acquire);
        var deadline = Io.Clock.Timestamp.fromNow(self.io, idle_duration);
        while (!self.stop_requested.load(.acquire) and !self.close_sent.load(.acquire)) {
            try self.io.futexWaitTimeout(
                u32,
                &self.activity_epoch.raw,
                observed,
                .{ .deadline = deadline },
            );
            if (self.stop_requested.load(.acquire) or self.close_sent.load(.acquire)) return;

            const current = self.activity_epoch.load(.acquire);
            if (current != observed) {
                observed = current;
                deadline = Io.Clock.Timestamp.fromNow(self.io, idle_duration);
                continue;
            }
            const now = Io.Clock.Timestamp.now(self.io, .awake);
            if (deadline.compare(.gt, now)) continue;
            self.writeFrame(.ping, "", false, false) catch |err| {
                if (err == error.WebSocketClosed) return;
                if (err == error.Canceled) return error.Canceled;
                return self.signalFailure(err);
            };
            deadline = Io.Clock.Timestamp.fromNow(self.io, idle_duration);
        }
    }

    fn receiveLoop(self: *RealWebSocket) Io.Cancelable!void {
        var fragmented_kind: ?MessageKind = null;
        var assembly: std.ArrayList(u8) = .empty;
        defer assembly.deinit(self.gpa);

        while (true) {
            const frame = self.readFrame() catch |err| {
                if (err == error.ReadFailed) {
                    if (self.connection) |connection| {
                        if (connection.getReadError()) |cause| {
                            if (cause == error.Canceled) return error.Canceled;
                            return self.signalFailure(cause);
                        }
                    }
                }
                if (err == error.WebSocketMessageTooLarge) {
                    self.sendTooLargeClose() catch |close_err| try propagateCancellation(close_err);
                } else if (isProtocolError(err)) {
                    self.sendProtocolClose() catch |close_err| try propagateCancellation(close_err);
                }
                return self.signalFailure(err);
            };
            var frame_owned = true;
            defer if (frame_owned) self.gpa.free(frame.payload);
            self.noteActivity();

            switch (frame.opcode) {
                .ping => {
                    self.writeFrame(.pong, frame.payload, false, true) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        return self.signalFailure(err);
                    };
                },
                .pong => {
                    // Receiving every frame, including pong, resets the idle deadline.
                },
                .connection_close => {
                    const close_code = parseClose(frame.payload) catch |err| {
                        self.sendProtocolClose() catch |close_err| try propagateCancellation(close_err);
                        return self.signalFailure(err);
                    };
                    self.sendCloseOnce(frame.payload) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        return self.signalFailure(err);
                    };
                    self.requestStop();
                    self.peer_close.set(self.io);
                    const owned = frame.payload;
                    frame_owned = false;
                    defer self.inbound.close(self.io);
                    try self.putInbound(.{ .closed = .{ .code = close_code, .payload = owned } });
                    return;
                },
                .text, .binary => {
                    if (fragmented_kind != null) {
                        self.sendProtocolClose() catch |err| try propagateCancellation(err);
                        return self.signalFailure(error.UnexpectedDataFrame);
                    }
                    const kind: MessageKind = if (frame.opcode == .text) .text else .binary;
                    if (frame.fin) {
                        if (kind == .text and !std.unicode.utf8ValidateSlice(frame.payload)) {
                            self.sendInvalidPayloadClose() catch |err| try propagateCancellation(err);
                            return self.signalFailure(error.InvalidTextEncoding);
                        }
                        const owned = frame.payload;
                        frame_owned = false;
                        try self.putInbound(.{ .message = .{ .kind = kind, .payload = owned } });
                    } else {
                        fragmented_kind = kind;
                        tryAppend(&assembly, self.gpa, frame.payload, self.max_message_size) catch |err| {
                            self.sendTooLargeClose() catch |close_err| try propagateCancellation(close_err);
                            return self.signalFailure(err);
                        };
                    }
                },
                .continuation => {
                    const kind = fragmented_kind orelse {
                        self.sendProtocolClose() catch |err| try propagateCancellation(err);
                        return self.signalFailure(error.UnexpectedContinuation);
                    };
                    tryAppend(&assembly, self.gpa, frame.payload, self.max_message_size) catch |err| {
                        self.sendTooLargeClose() catch |close_err| try propagateCancellation(close_err);
                        return self.signalFailure(err);
                    };
                    if (frame.fin) {
                        const owned = assembly.toOwnedSlice(self.gpa) catch |err| {
                            return self.signalFailure(err);
                        };
                        if (kind == .text and !std.unicode.utf8ValidateSlice(owned)) {
                            self.gpa.free(owned);
                            self.sendInvalidPayloadClose() catch |err| try propagateCancellation(err);
                            return self.signalFailure(error.InvalidTextEncoding);
                        }
                        fragmented_kind = null;
                        try self.putInbound(.{ .message = .{ .kind = kind, .payload = owned } });
                    }
                },
                else => {
                    self.sendProtocolClose() catch |err| try propagateCancellation(err);
                    return self.signalFailure(error.UnexpectedOpcode);
                },
            }
        }
    }

    fn readFrame(self: *RealWebSocket) !Frame {
        const reader = self.connection orelse return error.WebSocketClosed;
        const input = reader.reader();
        const header = try input.takeArray(2);
        const h0: Header0 = @bitCast(header[0]);
        const h1: Header1 = @bitCast(header[1]);
        if (h0.rsv1 != 0 or h0.rsv2 != 0 or h0.rsv3 != 0)
            return error.ReservedBitSet;
        if (h1.mask) return error.MaskedServerFrame;

        const encoded_len = @intFromEnum(h1.payload_len);
        const payload_len_u64: u64 = switch (h1.payload_len) {
            .len16 => blk: {
                const value = try input.takeInt(u16, .big);
                if (value < 126) return error.NonCanonicalPayloadLength;
                break :blk value;
            },
            .len64 => blk: {
                const value = try input.takeInt(u64, .big);
                if (value < 65_536 or value >> 63 != 0) return error.NonCanonicalPayloadLength;
                break :blk value;
            },
            else => encoded_len,
        };
        const control = switch (h0.opcode) {
            .connection_close, .ping, .pong => true,
            else => false,
        };
        if (control and (!h0.fin or payload_len_u64 > 125))
            return error.InvalidControlFrame;
        const payload_len = std.math.cast(usize, payload_len_u64) orelse
            return error.WebSocketMessageTooLarge;
        if (!control and payload_len > self.max_message_size)
            return error.WebSocketMessageTooLarge;

        const payload = try self.gpa.alloc(u8, payload_len);
        errdefer self.gpa.free(payload);
        try input.readSliceAll(payload);
        return .{ .opcode = h0.opcode, .fin = h0.fin, .payload = payload };
    }

    fn writeFrame(
        self: *RealWebSocket,
        opcode: Opcode,
        payload: []const u8,
        mark_activity: bool,
        allow_after_close: bool,
    ) !void {
        if (self.tearing_down.load(.acquire) or
            self.finalized.load(.acquire) or
            (!allow_after_close and self.close_sent.load(.acquire)))
            return error.WebSocketClosed;
        const control = switch (opcode) {
            .connection_close, .ping, .pong => true,
            else => false,
        };
        if (control and payload.len > 125) return error.InvalidControlFrame;

        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        if (self.tearing_down.load(.acquire) or
            self.finalized.load(.acquire) or
            (!allow_after_close and self.close_sent.load(.acquire)))
            return error.WebSocketClosed;
        const connection = self.connection orelse return error.WebSocketClosed;
        try writeMaskedFrame(connection.writer(), self.io, opcode, payload);
        try connection.flush();
        if (mark_activity) self.noteActivity();
    }

    fn sendCloseOnce(self: *RealWebSocket, payload: []const u8) !void {
        if (self.close_sent.swap(true, .acq_rel)) return;
        try self.writeFrame(.connection_close, payload, true, true);
    }

    fn sendProtocolClose(self: *RealWebSocket) !void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, 1002, .big);
        return self.sendCloseOnce(&payload);
    }

    fn sendInvalidPayloadClose(self: *RealWebSocket) !void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, 1007, .big);
        return self.sendCloseOnce(&payload);
    }

    fn sendTooLargeClose(self: *RealWebSocket) !void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, 1009, .big);
        return self.sendCloseOnce(&payload);
    }

    fn signalFailure(self: *RealWebSocket, err: anyerror) Io.Cancelable!void {
        self.requestStop();
        self.peer_close.set(self.io);
        defer self.inbound.close(self.io);
        try self.putInbound(.{ .failure = err });
    }

    fn putInbound(self: *RealWebSocket, value: Inbound) Io.Cancelable!void {
        self.inbound.putOne(self.io, value) catch |err| switch (err) {
            error.Closed => {
                freeInbound(self.gpa, value);
                return;
            },
            error.Canceled => {
                freeInbound(self.gpa, value);
                return error.Canceled;
            },
        };
    }

    fn finalize(self: *RealWebSocket) void {
        self.lifecycle_mutex.lockUncancelable(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        if (self.finalized.load(.acquire)) return;

        self.tearing_down.store(true, .release);
        self.requestStop();
        self.tasks.cancel(self.io);
        self.writer_mutex.lockUncancelable(self.io);
        self.destroyTakenConnection();
        self.client.deinit();
        self.writer_mutex.unlock(self.io);
        self.finalized.store(true, .release);
        self.inbound.close(self.io);
    }

    fn destroyTakenConnection(self: *RealWebSocket) void {
        const connection = self.connection orelse return;
        self.connection = null;

        connection.end() catch {};
        self.client.connection_pool.mutex.lockUncancelable(self.io);
        self.client.connection_pool.used.remove(&connection.pool_node);
        self.client.connection_pool.mutex.unlock(self.io);
        connection.destroy(self.io);
    }

    fn drainInbound(self: *RealWebSocket) void {
        var buffer: [1]Inbound = undefined;
        while (true) {
            const count = self.inbound.get(self.io, &buffer, 0) catch break;
            if (count == 0) break;
            freeInbound(self.gpa, buffer[0]);
        }
    }

    fn freeNegotiatedProtocol(self: *RealWebSocket) void {
        if (self.negotiated_protocol) |protocol| {
            self.gpa.free(protocol);
            self.negotiated_protocol = null;
        }
    }

    fn noteActivity(self: *RealWebSocket) void {
        _ = self.activity_epoch.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.activity_epoch.raw, std.math.maxInt(u32));
    }

    fn requestStop(self: *RealWebSocket) void {
        self.stop_requested.store(true, .release);
        self.io.futexWake(u32, &self.activity_epoch.raw, std.math.maxInt(u32));
    }

    const like_vtable: WebSocketLikeVTable = .{
        .send = likeSend,
        .receive = likeReceive,
        .close = likeClose,
        .negotiated_protocol = likeNegotiatedProtocol,
        .close_info = likeCloseInfo,
        .deinit = likeDeinit,
    };

    fn likeSend(raw: *anyopaque, kind: MessageKind, payload: []const u8) !void {
        const self: *RealWebSocket = @ptrCast(@alignCast(raw));
        return self.send(kind, payload);
    }

    fn likeReceive(raw: *anyopaque, io: Io) !?Message {
        const self: *RealWebSocket = @ptrCast(@alignCast(raw));
        return self.receive(io);
    }

    fn likeClose(raw: *anyopaque, code: u16, reason: []const u8) !void {
        const self: *RealWebSocket = @ptrCast(@alignCast(raw));
        return self.close(code, reason);
    }

    fn likeNegotiatedProtocol(raw: *const anyopaque) ?[]const u8 {
        const self: *const RealWebSocket = @ptrCast(@alignCast(raw));
        return self.negotiatedProtocol();
    }

    fn likeCloseInfo(raw: *const anyopaque) ?CloseInfo {
        const self: *const RealWebSocket = @ptrCast(@alignCast(raw));
        return self.closeInfo();
    }

    fn likeDeinit(raw: *anyopaque) void {
        const self: *RealWebSocket = @ptrCast(@alignCast(raw));
        self.deinit();
    }
};

fn writeMaskedFrame(writer: *Io.Writer, io: Io, opcode: Opcode, payload: []const u8) !void {
    try writer.writeByte(@bitCast(@as(Header0, .{ .opcode = opcode, .fin = true })));
    switch (payload.len) {
        0...125 => try writer.writeByte(@bitCast(@as(Header1, .{
            .payload_len = @enumFromInt(payload.len),
            .mask = true,
        }))),
        126...0xffff => {
            try writer.writeByte(@bitCast(@as(Header1, .{ .payload_len = .len16, .mask = true })));
            try writer.writeInt(u16, @intCast(payload.len), .big);
        },
        else => {
            try writer.writeByte(@bitCast(@as(Header1, .{ .payload_len = .len64, .mask = true })));
            try writer.writeInt(u64, payload.len, .big);
        },
    }

    var mask: [4]u8 = undefined;
    io.random(&mask);
    try writer.writeAll(&mask);
    var scratch: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const len = @min(scratch.len, payload.len - offset);
        @memcpy(scratch[0..len], payload[offset..][0..len]);
        for (scratch[0..len], 0..) |*byte, index| byte.* ^= mask[(offset + index) & 3];
        try writer.writeAll(scratch[0..len]);
        offset += len;
    }
}

fn parseClose(payload: []const u8) !?u16 {
    if (payload.len == 0) return null;
    if (payload.len == 1) return error.InvalidClosePayload;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!validCloseCode(code)) return error.InvalidCloseCode;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidCloseReason;
    return code;
}

fn validCloseCode(code: u16) bool {
    if (code >= 3000 and code <= 4999) return true;
    return switch (code) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014 => true,
        else => false,
    };
}

fn tryAppend(list: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum - list.items.len) return error.WebSocketMessageTooLarge;
    try list.appendSlice(gpa, bytes);
}

fn freeInbound(gpa: Allocator, inbound: RealWebSocket.Inbound) void {
    switch (inbound) {
        .message => |message| gpa.free(message.payload),
        .closed => |closed| gpa.free(closed.payload),
        .failure => {},
    }
}

fn isProtocolError(err: anyerror) bool {
    return err == error.ReservedBitSet or
        err == error.MaskedServerFrame or
        err == error.NonCanonicalPayloadLength or
        err == error.InvalidControlFrame or
        err == error.UnexpectedOpcode or
        err == error.UnexpectedDataFrame or
        err == error.UnexpectedContinuation or
        err == error.InvalidClosePayload or
        err == error.InvalidCloseCode or
        err == error.InvalidCloseReason;
}

fn propagateCancellation(err: anyerror) Io.Cancelable!void {
    if (err == error.Canceled) return error.Canceled;
}

fn validateProtocols(protocols: []const []const u8) !void {
    for (protocols, 0..) |protocol, index| {
        if (protocol.len == 0) return error.InvalidWebSocketProtocol;
        for (protocol) |byte| if (!isTokenByte(byte)) return error.InvalidWebSocketProtocol;
        for (protocols[0..index]) |prior| {
            if (std.mem.eql(u8, prior, protocol)) return error.DuplicateWebSocketProtocol;
        }
    }
}

fn validateExtraHeaders(headers: []const provider.Header) !void {
    for (headers) |header| {
        if (header.name.len == 0) return error.InvalidWebSocketHeader;
        for (header.name) |byte| if (!isTokenByte(byte)) return error.InvalidWebSocketHeader;
        if (std.mem.indexOfScalar(u8, header.value, '\r') != null or
            std.mem.indexOfScalar(u8, header.value, '\n') != null)
            return error.InvalidWebSocketHeader;
        if (std.ascii.eqlIgnoreCase(header.name, "connection") or
            std.ascii.eqlIgnoreCase(header.name, "upgrade") or
            std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version") or
            std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key") or
            std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol"))
            return error.ReservedWebSocketHeader;
    }
}

fn isTokenByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn containsProtocol(protocols: []const []const u8, needle: []const u8) bool {
    for (protocols) |protocol| if (std.mem.eql(u8, protocol, needle)) return true;
    return false;
}

fn hasHeader(headers: []const provider.Header, name: []const u8) bool {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    return false;
}

fn headerContainsToken(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), expected)) return true;
    }
    return false;
}

fn setConcurrencyDiagnostic(diag: ?*provider.Diagnostics) void {
    const diagnostics = diag orelse return;
    provider.Diagnostics.set(diag, diagnostics.allocator, .{ .unsupported_functionality = .{
        .message = "WebSocket construction requires real std.Io concurrency; io.concurrent returned ConcurrencyUnavailable",
        .functionality = "WebSocket receive and keepalive tasks",
    } });
}

const TestScript = enum {
    scripted,
    keepalive,
    masked_server_frame,
    peer_close,
    silent_close,
    wrong_accept,
    wrong_protocol,
    handshake_only,
};

const TestFrame = struct {
    opcode: Opcode,
    fin: bool,
    payload: []u8,
};

const TestWebSocketServer = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    thread: ?std.Thread,
    mutex: Io.Mutex,
    active_stream: ?Io.net.Stream,
    script: TestScript,
    last_error: ?anyerror,
    protocol_offered: bool,
    text_was_masked: bool,
    pong_was_masked: bool,
    ping_seen: Io.Event,

    fn start(gpa: Allocator, io: Io, script: TestScript) !*TestWebSocketServer {
        const listener = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true });
        const self = try gpa.create(TestWebSocketServer);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .thread = null,
            .mutex = .init,
            .active_stream = null,
            .script = script,
            .last_error = null,
            .protocol_offered = false,
            .text_was_masked = false,
            .pong_was_masked = false,
            .ping_seen = .unset,
        };
        errdefer {
            self.listener.deinit(io);
            gpa.destroy(self);
        }
        self.thread = try std.Thread.spawn(.{}, testServerThread, .{self});
        return self;
    }

    fn port(self: *const TestWebSocketServer) u16 {
        return switch (self.listener.socket.address) {
            .ip4 => |address| address.port,
            .ip6 => |address| address.port,
        };
    }

    fn url(self: *const TestWebSocketServer, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "ws://127.0.0.1:{d}/realtime", .{self.port()}) catch
            @panic("test WebSocket URL buffer too small");
    }

    fn wait(self: *TestWebSocketServer) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn deinit(self: *TestWebSocketServer) void {
        if (self.thread != null) {
            self.mutex.lockUncancelable(self.io);
            const active = self.active_stream;
            self.active_stream = null;
            self.mutex.unlock(self.io);
            if (active) |stream| {
                stream.close(self.io);
            } else {
                var wake = self.listener.socket.address.connect(self.io, .{ .mode = .stream }) catch null;
                if (wake) |*stream| stream.close(self.io);
            }
            self.wait();
        }
        self.listener.deinit(self.io);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn serve(self: *TestWebSocketServer) !void {
        const stream = try self.listener.accept(self.io);
        self.mutex.lockUncancelable(self.io);
        self.active_stream = stream;
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            const should_close = self.active_stream != null;
            self.active_stream = null;
            self.mutex.unlock(self.io);
            if (should_close) stream.close(self.io);
        }

        var receive_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [8 * 1024]u8 = undefined;
        var stream_reader = stream.reader(self.io, &receive_buffer);
        var stream_writer = stream.writer(self.io, &send_buffer);
        var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = try server.receiveHead();

        var offered_protocol: ?[]const u8 = null;
        var header_iterator = request.iterateHeaders();
        while (header_iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol"))
                offered_protocol = header.value;
        }
        self.protocol_offered = if (offered_protocol) |value| headerContainsToken(value, "realtime") else false;

        if (self.script == .wrong_accept) {
            try stream_writer.interface.writeAll(
                "HTTP/1.1 101 Switching Protocols\r\n" ++
                    "connection: upgrade\r\n" ++
                    "upgrade: websocket\r\n" ++
                    "sec-websocket-accept: definitely-wrong\r\n\r\n",
            );
            try stream_writer.interface.flush();
            return;
        }

        const key = switch (request.upgradeRequested()) {
            .websocket => |maybe_key| maybe_key orelse return error.MissingWebSocketKey,
            else => return error.UpgradeNotRequested,
        };
        const selected_protocol = switch (self.script) {
            .wrong_protocol => "other",
            else => "realtime",
        };
        var socket = try request.respondWebSocket(.{
            .key = key,
            .extra_headers = &.{.{
                .name = "sec-websocket-protocol",
                .value = selected_protocol,
            }},
        });
        try socket.flush();
        if (self.script == .wrong_protocol or self.script == .handshake_only) return;

        switch (self.script) {
            .scripted => try self.runScripted(&socket),
            .keepalive => try self.runKeepalive(&socket),
            .masked_server_frame => try self.runMaskedServerFrame(&socket),
            .peer_close => try self.runPeerClose(&socket),
            .silent_close => try self.runSilentClose(&socket),
            .wrong_accept, .wrong_protocol, .handshake_only => unreachable,
        }
    }

    fn runScripted(self: *TestWebSocketServer, socket: *std.http.Server.WebSocket) !void {
        const text = try socket.readSmallMessage();
        try std.testing.expectEqual(Opcode.text, text.opcode);
        try std.testing.expectEqualStrings("from client", text.data);
        self.text_was_masked = true;

        try writeServerFrame(socket.output, .ping, true, "probe");
        try socket.output.flush();
        const pong = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(pong.payload);
        try std.testing.expectEqual(Opcode.pong, pong.opcode);
        try std.testing.expectEqualStrings("probe", pong.payload);
        self.pong_was_masked = true;

        try writeServerFrame(socket.output, .text, false, "hel");
        try writeServerFrame(socket.output, .continuation, true, "lo");
        const large = try self.gpa.alloc(u8, 70 * 1024);
        defer self.gpa.free(large);
        @memset(large, 'z');
        try writeServerFrame(socket.output, .binary, true, large);
        try socket.output.flush();

        const close_frame = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(close_frame.payload);
        try std.testing.expectEqual(Opcode.connection_close, close_frame.opcode);
        try writeServerFrame(socket.output, .connection_close, true, close_frame.payload);
        try socket.output.flush();
    }

    fn runKeepalive(self: *TestWebSocketServer, socket: *std.http.Server.WebSocket) !void {
        const ping = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(ping.payload);
        try std.testing.expectEqual(Opcode.ping, ping.opcode);
        self.ping_seen.set(self.io);
        try writeServerFrame(socket.output, .pong, true, ping.payload);
        try socket.output.flush();

        const close_frame = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(close_frame.payload);
        try std.testing.expectEqual(Opcode.connection_close, close_frame.opcode);
        try writeServerFrame(socket.output, .connection_close, true, close_frame.payload);
        try socket.output.flush();
    }

    fn runMaskedServerFrame(self: *TestWebSocketServer, socket: *std.http.Server.WebSocket) !void {
        try writeMaskedFrame(socket.output, self.io, .text, "invalid masked server frame");
        try socket.output.flush();
        const close_frame = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(close_frame.payload);
        try std.testing.expectEqual(Opcode.connection_close, close_frame.opcode);
        try std.testing.expectEqual(@as(u16, 1002), std.mem.readInt(u16, close_frame.payload[0..2], .big));
    }

    fn runPeerClose(self: *TestWebSocketServer, socket: *std.http.Server.WebSocket) !void {
        const payload = [_]u8{ 0x03, 0xe9, 'b', 'y', 'e' };
        try writeServerFrame(socket.output, .connection_close, true, &payload);
        try socket.output.flush();
        const echoed = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(echoed.payload);
        try std.testing.expectEqual(Opcode.connection_close, echoed.opcode);
        try std.testing.expectEqualSlices(u8, &payload, echoed.payload);
    }

    fn runSilentClose(self: *TestWebSocketServer, socket: *std.http.Server.WebSocket) !void {
        const close_frame = try readClientFrame(self.gpa, socket.input);
        defer self.gpa.free(close_frame.payload);
        try std.testing.expectEqual(Opcode.connection_close, close_frame.opcode);
        try self.io.sleep(.fromMilliseconds(200), .awake);
    }

    fn recordError(self: *TestWebSocketServer, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.last_error = err;
    }
};

fn testServerThread(server: *TestWebSocketServer) void {
    server.serve() catch |err| server.recordError(err);
}

fn readClientFrame(gpa: Allocator, reader: *Io.Reader) !TestFrame {
    const header = try reader.takeArray(2);
    const h0: Header0 = @bitCast(header[0]);
    const h1: Header1 = @bitCast(header[1]);
    if (!h1.mask) return error.MissingMaskBit;
    const len: usize = switch (h1.payload_len) {
        .len16 => try reader.takeInt(u16, .big),
        .len64 => std.math.cast(usize, try reader.takeInt(u64, .big)) orelse return error.MessageTooLarge,
        else => @intFromEnum(h1.payload_len),
    };
    const mask = (try reader.takeArray(4)).*;
    const payload = try gpa.alloc(u8, len);
    errdefer gpa.free(payload);
    try reader.readSliceAll(payload);
    for (payload, 0..) |*byte, index| byte.* ^= mask[index & 3];
    return .{ .opcode = h0.opcode, .fin = h0.fin, .payload = payload };
}

fn writeServerFrame(writer: *Io.Writer, opcode: Opcode, fin: bool, payload: []const u8) !void {
    try writer.writeByte(@bitCast(@as(Header0, .{ .opcode = opcode, .fin = fin })));
    switch (payload.len) {
        0...125 => try writer.writeByte(@bitCast(@as(Header1, .{
            .payload_len = @enumFromInt(payload.len),
            .mask = false,
        }))),
        126...0xffff => {
            try writer.writeByte(@bitCast(@as(Header1, .{ .payload_len = .len16, .mask = false })));
            try writer.writeInt(u16, @intCast(payload.len), .big);
        },
        else => {
            try writer.writeByte(@bitCast(@as(Header1, .{ .payload_len = .len64, .mask = false })));
            try writer.writeInt(u64, payload.len, .big);
        },
    }
    try writer.writeAll(payload);
}

test "toWebSocketUrl converts HTTP schemes" {
    const allocator = std.testing.allocator;
    const ws = try toWebSocketUrl(allocator, "http://example.test/v1");
    defer allocator.free(ws);
    try std.testing.expectEqualStrings("ws://example.test/v1", ws);

    const wss = try toWebSocketUrl(allocator, "https://example.test/v1");
    defer allocator.free(wss);
    try std.testing.expectEqualStrings("wss://example.test/v1", wss);
}

test "client frame writer masks without mutating caller payload" {
    const allocator = std.testing.allocator;
    const payload = "immutable websocket payload";
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try writeMaskedFrame(&output.writer, std.testing.io, .text, payload);
    const bytes = output.writer.buffered();
    const h0: Header0 = @bitCast(bytes[0]);
    const h1: Header1 = @bitCast(bytes[1]);
    try std.testing.expect(h0.fin);
    try std.testing.expectEqual(Opcode.text, h0.opcode);
    try std.testing.expect(h1.mask);
    try std.testing.expectEqual(payload.len, @intFromEnum(h1.payload_len));
    const mask = bytes[2..6];
    for (payload, bytes[6..], 0..) |expected, masked, index| {
        try std.testing.expectEqual(expected, masked ^ mask[index & 3]);
    }
    try std.testing.expectEqualStrings("immutable websocket payload", payload);
}

test "protocol and close validation" {
    try validateProtocols(&.{ "realtime", "openai-insecure-api-key.token" });
    try std.testing.expectError(error.DuplicateWebSocketProtocol, validateProtocols(&.{ "x", "x" }));
    try std.testing.expectError(error.InvalidWebSocketProtocol, validateProtocols(&.{"not a token"}));
    try std.testing.expectEqual(@as(?u16, 1000), try parseClose(&.{ 0x03, 0xe8 }));
    try std.testing.expectError(error.InvalidClosePayload, parseClose(&.{0x03}));
}

test "loopback WebSocket validates handshake masking ping fragmentation large messages and close" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestWebSocketServer.start(allocator, io, .scripted);
    defer server.deinit();

    var url_buffer: [96]u8 = undefined;
    var socket = try default_factory.connect(allocator, io, server.url(&url_buffer), .{
        .protocols = &.{"realtime"},
        .idle_ms = 10_000,
    }, null);
    defer socket.deinit();

    try std.testing.expectEqualStrings("realtime", socket.negotiatedProtocol().?);
    try socket.sendText("from client");

    const fragmented = (try socket.receive(io)).?;
    try std.testing.expectEqual(MessageKind.text, fragmented.kind);
    try std.testing.expectEqualStrings("hello", fragmented.payload);

    const large = (try socket.receive(io)).?;
    try std.testing.expectEqual(MessageKind.binary, large.kind);
    try std.testing.expectEqual(@as(usize, 70 * 1024), large.payload.len);
    try std.testing.expectEqual(@as(u8, 'z'), large.payload[0]);
    try std.testing.expectEqual(@as(u8, 'z'), large.payload[large.payload.len - 1]);

    try socket.close(1000, "done");
    try std.testing.expectEqual(@as(?Message, null), try socket.receive(io));
    try std.testing.expectEqual(@as(?u16, 1000), socket.closeInfo().?.code);
    try std.testing.expectEqualStrings("done", socket.closeInfo().?.reason);

    server.wait();
    try std.testing.expectEqual(@as(?anyerror, null), server.last_error);
    try std.testing.expect(server.protocol_offered);
    try std.testing.expect(server.text_was_masked);
    try std.testing.expect(server.pong_was_masked);
}

test "keepalive sends a masked ping after idle and accepts pong" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestWebSocketServer.start(allocator, io, .keepalive);
    defer server.deinit();

    var url_buffer: [96]u8 = undefined;
    var socket = try default_factory.connect(allocator, io, server.url(&url_buffer), .{
        .protocols = &.{"realtime"},
        .idle_ms = 10,
    }, null);
    defer socket.deinit();

    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };
    try server.ping_seen.waitTimeout(io, timeout);
    try socket.close(1000, "");
    server.wait();
    try std.testing.expectEqual(@as(?anyerror, null), server.last_error);
}

test "masked server frames are rejected as protocol errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestWebSocketServer.start(allocator, io, .masked_server_frame);
    defer server.deinit();

    var url_buffer: [96]u8 = undefined;
    var socket = try default_factory.connect(allocator, io, server.url(&url_buffer), .{
        .protocols = &.{"realtime"},
        .idle_ms = 0,
    }, null);
    defer socket.deinit();

    try std.testing.expectError(error.MaskedServerFrame, socket.receive(io));
    server.wait();
    try std.testing.expectEqual(@as(?anyerror, null), server.last_error);
}

test "peer initiated close is echoed and surfaced" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestWebSocketServer.start(allocator, io, .peer_close);
    defer server.deinit();

    var url_buffer: [96]u8 = undefined;
    var socket = try default_factory.connect(allocator, io, server.url(&url_buffer), .{
        .protocols = &.{"realtime"},
        .idle_ms = 0,
    }, null);
    defer socket.deinit();

    try std.testing.expectEqual(@as(?Message, null), try socket.receive(io));
    try std.testing.expectEqual(@as(?u16, 1001), socket.closeInfo().?.code);
    try std.testing.expectEqualStrings("bye", socket.closeInfo().?.reason);
    server.wait();
    try std.testing.expectEqual(@as(?anyerror, null), server.last_error);
}

test "close cancels the receive task and unblocks a consumer on another thread" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestWebSocketServer.start(allocator, io, .silent_close);
    defer server.deinit();

    var url_buffer: [96]u8 = undefined;
    var socket = try default_factory.connect(allocator, io, server.url(&url_buffer), .{
        .protocols = &.{"realtime"},
        .idle_ms = 0,
        .close_timeout_ms = 10,
    }, null);
    defer socket.deinit();

    const Waiter = struct {
        fn run(ws: WebSocketLike, waiter_io: Io, result: *anyerror!bool) void {
            const received = ws.receive(waiter_io) catch |err| {
                result.* = err;
                return;
            };
            result.* = received == null;
        }
    };
    var waiter_result: anyerror!bool = undefined;
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ socket, io, &waiter_result });
    try socket.close(1000, "");
    waiter.join();
    try std.testing.expect(try waiter_result);

    server.wait();
    try std.testing.expectEqual(@as(?anyerror, null), server.last_error);
}

test "wrong accept and unoffered negotiated protocols reject the handshake" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const wrong_accept = try TestWebSocketServer.start(allocator, io, .wrong_accept);
    defer wrong_accept.deinit();
    var first_url: [96]u8 = undefined;
    try std.testing.expectError(error.InvalidWebSocketAccept, default_factory.connect(
        allocator,
        io,
        wrong_accept.url(&first_url),
        .{ .protocols = &.{"realtime"} },
        null,
    ));
    wrong_accept.wait();

    const wrong_protocol = try TestWebSocketServer.start(allocator, io, .wrong_protocol);
    defer wrong_protocol.deinit();
    var second_url: [96]u8 = undefined;
    try std.testing.expectError(error.InvalidNegotiatedProtocol, default_factory.connect(
        allocator,
        io,
        wrong_protocol.url(&second_url),
        .{ .protocols = &.{"realtime"} },
        null,
    ));
    wrong_protocol.wait();
}

test "construction reports ConcurrencyUnavailable with diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try TestWebSocketServer.start(allocator, io, .handshake_only);
    defer server.deinit();

    var single_threaded = Io.Threaded.init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer single_threaded.deinit();
    const unavailable_io = single_threaded.io();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    var url_buffer: [96]u8 = undefined;
    try std.testing.expectError(error.ConcurrencyUnavailable, default_factory.connect(
        allocator,
        unavailable_io,
        server.url(&url_buffer),
        .{ .protocols = &.{"realtime"}, .idle_ms = 0 },
        &diagnostics,
    ));
    const message = try diagnostics.message(allocator);
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "ConcurrencyUnavailable") != null);
    server.wait();
}
