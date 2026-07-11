//! One-connection in-process WebSocket server for integration tests.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    run_fn: *const fn (
        ctx: ?*anyopaque,
        io: Io,
        socket: *std.http.Server.WebSocket,
        request: *std.http.Server.Request,
    ) anyerror!void,
};

pub const ScriptServer = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    handler: Handler,
    stopping: std.atomic.Value(bool) = .init(false),
    stream_ready: Io.Event = .unset,
    done: Io.Event = .unset,
    thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    active_stream: ?Io.net.Stream = null,
    serve_error: ?anyerror = null,

    pub fn start(gpa: Allocator, io: Io, handler: Handler) !*ScriptServer {
        var listener = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true });
        const self = try gpa.create(ScriptServer);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .handler = handler,
        };
        errdefer {
            listener.deinit(io);
            gpa.destroy(self);
        }
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    pub fn port(self: *const ScriptServer) u16 {
        return switch (self.listener.socket.address) {
            .ip4 => |address| address.port,
            .ip6 => |address| address.port,
        };
    }

    pub fn url(self: *const ScriptServer, buffer: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "ws://127.0.0.1:{d}{s}", .{ self.port(), path }) catch
            @panic("ScriptServer.url buffer is too small");
    }

    pub fn wait(self: *ScriptServer) !void {
        self.done.waitUncancelable(self.io);
        self.join();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.serve_error) |err| return err;
    }

    pub fn stop(self: *ScriptServer) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        var wake = self.listener.socket.address.connect(self.io, .{ .mode = .stream }) catch null;
        if (wake) |*stream| stream.close(self.io);
        self.stream_ready.waitUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        if (self.active_stream) |stream| stream.shutdown(self.io, .both) catch {};
        self.mutex.unlock(self.io);
        self.join();
    }

    pub fn deinit(self: *ScriptServer) void {
        self.stop();
        self.listener.deinit(self.io);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn join(self: *ScriptServer) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn threadMain(self: *ScriptServer) void {
        self.serve() catch |err| {
            if (!self.stopping.load(.acquire)) {
                self.mutex.lockUncancelable(self.io);
                self.serve_error = err;
                self.mutex.unlock(self.io);
            }
        };
        self.stream_ready.set(self.io);
        self.done.set(self.io);
    }

    fn serve(self: *ScriptServer) !void {
        const stream = try self.listener.accept(self.io);
        self.mutex.lockUncancelable(self.io);
        self.active_stream = stream;
        self.mutex.unlock(self.io);
        self.stream_ready.set(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.active_stream = null;
            self.mutex.unlock(self.io);
            stream.close(self.io);
        }
        if (self.stopping.load(.acquire)) return;

        const receive_buffer = try self.gpa.alloc(u8, 256 * 1024);
        defer self.gpa.free(receive_buffer);
        const send_buffer = try self.gpa.alloc(u8, 32 * 1024);
        defer self.gpa.free(send_buffer);
        var stream_reader = stream.reader(self.io, receive_buffer);
        var stream_writer = stream.writer(self.io, send_buffer);
        var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = try server.receiveHead();
        const key = switch (request.upgradeRequested()) {
            .websocket => |maybe_key| maybe_key orelse return error.MissingWebSocketKey,
            else => return error.WebSocketUpgradeRequired,
        };
        const protocol = firstProtocol(&request);
        const headers: []const std.http.Header = if (protocol) |value|
            &.{.{ .name = "sec-websocket-protocol", .value = value }}
        else
            &.{};
        var socket = try request.respondWebSocket(.{ .key = key, .extra_headers = headers });
        try socket.flush();
        try self.handler.run_fn(self.handler.ctx, self.io, &socket, &request);
    }
};

pub fn readText(socket: *std.http.Server.WebSocket) ![]u8 {
    const message = try socket.readSmallMessage();
    if (message.opcode != .text) return error.ExpectedTextMessage;
    return message.data;
}

pub fn sendJson(socket: *std.http.Server.WebSocket, json: []const u8) !void {
    return socket.writeMessage(json, .text);
}

pub fn closeNormally(socket: *std.http.Server.WebSocket) !void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, 1000, .big);
    try socket.writeMessage(&payload, .connection_close);
}

pub fn closeNormallyAndAwaitEcho(socket: *std.http.Server.WebSocket) !void {
    try closeNormally(socket);
    _ = socket.readSmallMessage() catch |err| switch (err) {
        error.ConnectionClose => return,
        else => return err,
    };
    return error.ExpectedConnectionClose;
}

fn firstProtocol(request: *std.http.Server.Request) ?[]const u8 {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) continue;
        const comma = std.mem.indexOfScalar(u8, header.value, ',') orelse header.value.len;
        return std.mem.trim(u8, header.value[0..comma], " \t");
    }
    return null;
}
