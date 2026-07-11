//! Runtime MCP transport interface shared by stdio and HTTP transports.

const std = @import("std");
const json_rpc = @import("json_rpc.zig");

pub const ErrorInfo = struct {
    err: anyerror,
    message: []const u8 = "",
    status_code: ?u16 = null,
    url: ?[]const u8 = null,
    response_body: ?[]const u8 = null,
};

pub const Callbacks = struct {
    /// Message and error slices are borrowed for the duration of the callback.
    /// Consumers that retain them must deep-clone into their own allocator.
    ctx: ?*anyopaque = null,
    on_message: ?*const fn (ctx: ?*anyopaque, message: json_rpc.Message) void = null,
    on_error: ?*const fn (ctx: ?*anyopaque, info: ErrorInfo) void = null,
    on_close: ?*const fn (ctx: ?*anyopaque) void = null,

    pub fn message(self: Callbacks, value: json_rpc.Message) void {
        if (self.on_message) |callback| callback(self.ctx, value);
    }

    pub fn errorInfo(self: Callbacks, info: ErrorInfo) void {
        if (self.on_error) |callback| callback(self.ctx, info);
    }

    pub fn closed(self: Callbacks) void {
        if (self.on_close) |callback| callback(self.ctx);
    }
};

/// OAuth is intentionally deferred from Phase 9b. HTTP transports expose this
/// one-shot 401 recovery seam so a later OAuth module can authorize and ask
/// the transport to retry without changing the transport vtable.
pub const AuthHook = struct {
    ctx: ?*anyopaque = null,
    authorize_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        server_url: []const u8,
        status_code: u16,
    ) anyerror!bool,

    pub fn authorize(self: AuthHook, io: std.Io, server_url: []const u8, status_code: u16) anyerror!bool {
        return self.authorize_fn(self.ctx, io, server_url, status_code);
    }
};

pub const VTable = struct {
    start: *const fn (ctx: *anyopaque, io: std.Io) anyerror!void,
    send: *const fn (ctx: *anyopaque, io: std.Io, message: json_rpc.Message) anyerror!void,
    close: *const fn (ctx: *anyopaque, io: std.Io) anyerror!void,
    set_callbacks: *const fn (ctx: *anyopaque, callbacks: Callbacks) void,
    get_protocol_version: *const fn (ctx: *anyopaque) ?[]const u8,
    set_protocol_version: *const fn (ctx: *anyopaque, version: []const u8) anyerror!void,
};

pub const MCPTransport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn start(self: MCPTransport, io: std.Io) anyerror!void {
        return self.vtable.start(self.ctx, io);
    }

    pub fn send(self: MCPTransport, io: std.Io, message: json_rpc.Message) anyerror!void {
        return self.vtable.send(self.ctx, io, message);
    }

    pub fn close(self: MCPTransport, io: std.Io) anyerror!void {
        return self.vtable.close(self.ctx, io);
    }

    pub fn setCallbacks(self: MCPTransport, callbacks: Callbacks) void {
        self.vtable.set_callbacks(self.ctx, callbacks);
    }

    pub fn protocolVersion(self: MCPTransport) ?[]const u8 {
        return self.vtable.get_protocol_version(self.ctx);
    }

    pub fn setProtocolVersion(self: MCPTransport, version: []const u8) anyerror!void {
        return self.vtable.set_protocol_version(self.ctx, version);
    }
};

test "transport vtable forwards lifecycle, callbacks, and protocol version" {
    const Fake = struct {
        started: bool = false,
        closed: bool = false,
        callbacks: Callbacks = .{},
        version: ?[]const u8 = null,

        fn transport(self: *@This()) MCPTransport {
            return .{ .ctx = self, .vtable = &vtable };
        }

        fn start(raw: *anyopaque, _: std.Io) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started = true;
        }

        fn send(raw: *anyopaque, _: std.Io, message: json_rpc.Message) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callbacks.message(message);
        }

        fn close(raw: *anyopaque, _: std.Io) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closed = true;
            self.callbacks.closed();
        }

        fn setCallbacks(raw: *anyopaque, callbacks: Callbacks) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callbacks = callbacks;
        }

        fn getProtocolVersion(raw: *anyopaque) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.version;
        }

        fn setProtocolVersion(raw: *anyopaque, version: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.version = version;
        }

        const vtable: VTable = .{
            .start = start,
            .send = send,
            .close = close,
            .set_callbacks = setCallbacks,
            .get_protocol_version = getProtocolVersion,
            .set_protocol_version = setProtocolVersion,
        };
    };

    const Recorder = struct {
        messages: usize = 0,
        closes: usize = 0,
        fn message(raw: ?*anyopaque, _: json_rpc.Message) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.messages += 1;
        }
        fn close(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.closes += 1;
        }
    };

    var fake: Fake = .{};
    var recorder: Recorder = .{};
    const value = fake.transport();
    value.setCallbacks(.{ .ctx = &recorder, .on_message = Recorder.message, .on_close = Recorder.close });
    try value.start(std.testing.io);
    try value.setProtocolVersion("2025-06-18");
    try value.send(std.testing.io, .{ .notification = .{ .method = "ready" } });
    try value.close(std.testing.io);
    try std.testing.expect(fake.started and fake.closed);
    try std.testing.expectEqualStrings("2025-06-18", value.protocolVersion().?);
    try std.testing.expectEqual(1, recorder.messages);
    try std.testing.expectEqual(1, recorder.closes);
}
