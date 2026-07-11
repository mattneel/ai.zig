//! MCP Streamable HTTP transport with sessions and resumable inbound SSE.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const json_rpc = @import("json_rpc.zig");
const transport_api = @import("transport.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const SessionChangedHook = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (ctx: ?*anyopaque, session_id: ?[]const u8) void,
};

pub const SessionExpiredHook = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (ctx: ?*anyopaque, session_id: []const u8) void,
};

pub const Config = struct {
    url: []const u8,
    headers: []const provider.Header = &.{},
    transport: ?provider_utils.HttpTransport = null,
    auth_hook: ?transport_api.AuthHook = null,
    initial_session_id: ?[]const u8 = null,
    initial_protocol_version: ?[]const u8 = null,
    on_session_changed: ?SessionChangedHook = null,
    on_session_expired: ?SessionExpiredHook = null,
    terminate_session_on_close: bool = true,
};

pub const HttpTransport = struct {
    gpa: Allocator,
    url: []u8,
    custom_headers: []const provider.Header,
    custom_transport: ?provider_utils.HttpTransport,
    owned_client: ?provider_utils.HttpClientTransport = null,
    http: ?provider_utils.HttpTransport = null,
    auth_hook: ?transport_api.AuthHook,
    callbacks: transport_api.Callbacks = .{},
    state_mutex: std.atomic.Mutex = .unlocked,
    protocol_version: []u8,
    session_id: ?[]u8,
    last_event_id: ?[]u8 = null,
    on_session_changed: ?SessionChangedHook,
    on_session_expired: ?SessionExpiredHook,
    terminate_session_on_close: bool,
    started: bool = false,
    closing: std.atomic.Value(bool) = .init(false),
    close_notified: std.atomic.Value(bool) = .init(false),
    inbound_mutex: std.Io.Mutex = .init,
    inbound_running: std.atomic.Value(bool) = .init(false),
    inbound_future: ?std.Io.Future(void) = null,
    request_tasks: std.Io.Group = .init,

    const Reconnect = struct {
        const initial_delay_ms: u64 = 1000;
        const factor_numerator: u64 = 3;
        const factor_denominator: u64 = 2;
        const cap_ms: u64 = 30_000;
        const max_retries: u32 = 2;
    };

    const PostSseWork = struct {
        arena: std.heap.ArenaAllocator,
        response: provider_utils.Response = undefined,
    };

    pub fn init(gpa: Allocator, config: Config) Allocator.Error!HttpTransport {
        const headers = try cloneHeaders(gpa, config.headers);
        errdefer freeHeaders(gpa, headers);
        const url = try gpa.dupe(u8, config.url);
        errdefer gpa.free(url);
        const protocol = try gpa.dupe(u8, config.initial_protocol_version orelse types.LATEST_PROTOCOL_VERSION);
        errdefer gpa.free(protocol);
        const session_id = if (config.initial_session_id) |value| try gpa.dupe(u8, value) else null;
        return .{
            .gpa = gpa,
            .url = url,
            .custom_headers = headers,
            .custom_transport = config.transport,
            .auth_hook = config.auth_hook,
            .protocol_version = protocol,
            .session_id = session_id,
            .on_session_changed = config.on_session_changed,
            .on_session_expired = config.on_session_expired,
            .terminate_session_on_close = config.terminate_session_on_close,
        };
    }

    pub fn deinit(self: *HttpTransport) void {
        std.debug.assert(!self.started);
        if (self.owned_client) |*client| client.deinit();
        if (self.session_id) |value| self.gpa.free(value);
        if (self.last_event_id) |value| self.gpa.free(value);
        self.gpa.free(self.protocol_version);
        freeHeaders(self.gpa, self.custom_headers);
        self.gpa.free(self.url);
        self.* = undefined;
    }

    pub fn transport(self: *HttpTransport) transport_api.MCPTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn start(self: *HttpTransport, io: std.Io) anyerror!void {
        if (self.started) return error.TransportAlreadyStarted;
        self.started = true;
        self.closing.store(false, .release);
        self.close_notified.store(false, .release);
        if (self.custom_transport) |custom| {
            self.http = custom;
        } else {
            self.owned_client = provider_utils.HttpClientTransport.init(self.gpa, io);
            if (self.owned_client) |*client| self.http = client.transport();
        }
        self.startInbound(io) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {}, // Optional standing GET is unavailable; POST still works.
            else => return err,
        };
    }

    pub fn send(self: *HttpTransport, io: std.Io, message: json_rpc.Message) anyerror!void {
        if (!self.started or self.http == null) return error.TransportNotConnected;
        return self.sendAttempt(io, message, false);
    }

    pub fn close(self: *HttpTransport, io: std.Io) anyerror!void {
        if (!self.started) return;
        self.closing.store(true, .release);

        var close_error: ?anyerror = null;
        const session = try self.sessionSnapshot(self.gpa);
        defer if (session) |value| self.gpa.free(value);
        if (session != null and self.terminate_session_on_close) {
            self.deleteSession(io, session.?) catch |err| {
                close_error = err;
            };
        }

        self.inbound_mutex.lockUncancelable(io);
        if (self.inbound_future) |*future| {
            future.cancel(io);
            self.inbound_future = null;
        }
        self.inbound_running.store(false, .release);
        self.inbound_mutex.unlock(io);
        self.request_tasks.cancel(io);

        self.http = null;
        if (self.owned_client) |*client| client.deinit();
        self.owned_client = null;
        self.started = false;
        self.notifyClose();
        if (close_error) |err| return err;
    }

    fn sendAttempt(self: *HttpTransport, io: std.Io, message: json_rpc.Message, tried_auth: bool) anyerror!void {
        const work = try self.gpa.create(PostSseWork);
        work.* = .{ .arena = .init(self.gpa) };
        var response: ?provider_utils.Response = null;
        var detached = false;
        defer if (!detached) {
            if (response) |*value| value.body.deinit(io);
            work.arena.deinit();
            self.gpa.destroy(work);
        };
        const arena = work.arena.allocator();
        const encoded = try json_rpc.serialize(arena, message);
        const is_initialize = message == .request and std.mem.eql(u8, message.request.method, "initialize");
        const session = if (is_initialize) null else try self.sessionSnapshot(arena);
        const headers = try self.commonHeaders(io, arena, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json, text/event-stream" },
        }, session, null);
        var diagnostics = provider.Diagnostics.init(self.gpa);
        defer diagnostics.deinit();
        response = self.http.?.request(io, arena, .{
            .method = .POST,
            .url = self.url,
            .headers = headers,
            .body = encoded,
            .redirect_behavior = .not_allowed,
        }, &diagnostics) catch |err| {
            const mapped = mapRequestError(err, &diagnostics);
            self.callbacks.errorInfo(.{ .err = mapped, .message = "MCP HTTP POST failed", .url = self.url });
            return mapped;
        };
        try self.applySessionHeader(response.?.headers);

        if (response.?.status == 401 and !tried_auth) {
            if (self.auth_hook) |hook| {
                if (try hook.authorize(io, self.url, response.?.status)) {
                    return self.sendAttempt(io, message, true);
                }
            }
        }

        if (response.?.status == 202) {
            if (!self.inbound_running.load(.acquire)) {
                self.startInbound(io) catch |err| switch (err) {
                    error.ConcurrencyUnavailable => {},
                    else => self.callbacks.errorInfo(.{ .err = err, .message = "failed to start inbound MCP SSE", .url = self.url }),
                };
            }
            return;
        }

        if (response.?.status < 200 or response.?.status >= 300) {
            const body = if (response.?.has_body)
                provider_utils.http_transport.readBodyWithLimit(arena, &response.?.body, 64 * 1024) catch null
            else
                null;
            if (response.?.status == 404 and session != null) try self.expireSession(session.?);
            const err: anyerror = if (isRetryableStatus(response.?.status))
                error.RetryableTransportError
            else
                error.APICallError;
            self.callbacks.errorInfo(.{
                .err = err,
                .message = if (response.?.status == 404 and session != null)
                    "MCP session expired"
                else
                    "MCP HTTP POST returned an error",
                .status_code = response.?.status,
                .url = self.url,
                .response_body = body,
            });
            return err;
        }

        if (message == .notification) return;
        const content_type = provider_utils.getHeader(response.?.headers, "content-type") orelse "";
        if (std.mem.indexOf(u8, content_type, "application/json") != null) {
            if (!response.?.has_body) return error.InvalidResponseDataError;
            const body = try provider_utils.http_transport.readBodyWithLimit(arena, &response.?.body, 16 * 1024 * 1024);
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidResponseDataError;
            try self.dispatchJsonValue(value);
            return;
        }
        if (std.mem.indexOf(u8, content_type, "text/event-stream") != null) {
            if (!response.?.has_body) return error.InvalidResponseDataError;
            work.response = response.?;
            response = null;
            detached = true;
            self.request_tasks.concurrent(io, postSseMain, .{ self, io, work }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    detached = false;
                    response = work.response;
                    return self.readSseResponse(response.?.body.reader());
                },
            };
            return;
        }
        self.callbacks.errorInfo(.{
            .err = error.InvalidResponseDataError,
            .message = "unexpected MCP HTTP response content type",
            .status_code = response.?.status,
            .url = self.url,
        });
        return error.InvalidResponseDataError;
    }

    fn postSseMain(self: *HttpTransport, io: std.Io, work: *PostSseWork) std.Io.Cancelable!void {
        defer {
            work.response.body.deinit(io);
            work.arena.deinit();
            self.gpa.destroy(work);
        }
        self.readSseResponse(work.response.body.reader()) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.callbacks.errorInfo(.{ .err = err, .message = "MCP per-request SSE failed", .url = self.url });
        };
    }

    fn dispatchJsonValue(self: *HttpTransport, value: std.json.Value) anyerror!void {
        if (value == .array) {
            for (value.array.items) |item| self.callbacks.message(try json_rpc.validate(item));
        } else {
            self.callbacks.message(try json_rpc.validate(value));
        }
    }

    fn readSseResponse(self: *HttpTransport, reader: *std.Io.Reader) anyerror!void {
        var decoder = provider_utils.SseDecoder.init(self.gpa, reader, .{});
        defer decoder.deinit();
        while (try decoder.next()) |event| {
            if (event.event != null and !std.mem.eql(u8, event.event.?, "message")) continue;
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const message = json_rpc.parse(arena_state.allocator(), event.data) catch |err| {
                self.callbacks.errorInfo(.{ .err = err, .message = "failed to parse MCP HTTP SSE message", .url = self.url });
                continue;
            };
            self.callbacks.message(message);
        }
    }

    fn startInbound(self: *HttpTransport, io: std.Io) anyerror!void {
        try self.inbound_mutex.lock(io);
        defer self.inbound_mutex.unlock(io);
        if (self.inbound_running.load(.acquire) or self.closing.load(.acquire)) return;
        if (self.inbound_future) |*previous| {
            previous.await(io);
            self.inbound_future = null;
        }
        self.inbound_running.store(true, .release);
        self.inbound_future = io.concurrent(inboundMain, .{ self, io }) catch |err| {
            self.inbound_running.store(false, .release);
            return err;
        };
    }

    fn inboundMain(self: *HttpTransport, io: std.Io) void {
        defer self.inbound_running.store(false, .release);
        var retries: u32 = 0;
        var delay_ms = Reconnect.initial_delay_ms;
        var tried_auth = false;
        while (!self.closing.load(.acquire)) {
            const outcome = self.openInbound(io, tried_auth) catch |err| blk: {
                if (err == error.Canceled or self.closing.load(.acquire)) return;
                self.callbacks.errorInfo(.{ .err = err, .message = "MCP inbound SSE failed", .url = self.url });
                break :blk .retry;
            };
            switch (outcome) {
                .done, .unsupported => return,
                .authorized => {
                    tried_auth = true;
                    continue;
                },
                .retry => {},
            }
            if (retries >= Reconnect.max_retries) {
                self.callbacks.errorInfo(.{
                    .err = error.ReconnectLimitExceeded,
                    .message = "maximum MCP inbound SSE reconnection attempts exceeded",
                    .url = self.url,
                });
                return;
            }
            io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch return;
            retries += 1;
            delay_ms = @min(
                std.math.mul(u64, delay_ms, Reconnect.factor_numerator) catch Reconnect.cap_ms,
                Reconnect.cap_ms * Reconnect.factor_denominator,
            ) / Reconnect.factor_denominator;
        }
    }

    const InboundOutcome = enum { done, unsupported, authorized, retry };

    fn openInbound(self: *HttpTransport, io: std.Io, tried_auth: bool) anyerror!InboundOutcome {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const session = try self.sessionSnapshot(arena);
        const last_event_id = try self.lastEventIdSnapshot(arena);
        const headers = try self.commonHeaders(
            io,
            arena,
            &.{.{ .name = "accept", .value = "text/event-stream" }},
            session,
            last_event_id,
        );
        var diagnostics = provider.Diagnostics.init(self.gpa);
        defer diagnostics.deinit();
        var response = self.http.?.request(io, arena, .{
            .method = .GET,
            .url = self.url,
            .headers = headers,
            .redirect_behavior = .not_allowed,
        }, &diagnostics) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.callbacks.errorInfo(.{ .err = mapRequestError(err, &diagnostics), .message = "MCP inbound GET failed", .url = self.url });
            return .retry;
        };
        defer response.body.deinit(io);
        try self.applySessionHeader(response.headers);

        if (response.status == 401 and !tried_auth) {
            if (self.auth_hook) |hook| {
                if (try hook.authorize(io, self.url, response.status)) return .authorized;
            }
        }
        if (response.status == 405) return .unsupported;
        if (response.status == 404 and session != null) {
            try self.expireSession(session.?);
            self.callbacks.errorInfo(.{
                .err = error.SessionExpired,
                .message = "MCP session expired",
                .status_code = response.status,
                .url = self.url,
            });
            return .done;
        }
        if (response.status < 200 or response.status >= 300 or !response.has_body) {
            self.callbacks.errorInfo(.{
                .err = error.APICallError,
                .message = "MCP inbound GET returned an error",
                .status_code = response.status,
                .url = self.url,
            });
            return .retry;
        }

        var decoder = provider_utils.SseDecoder.init(self.gpa, response.body.reader(), .{});
        defer decoder.deinit();
        while (!self.closing.load(.acquire)) {
            const event = (try decoder.next()) orelse return .retry;
            if (event.id) |id| try self.setLastEventId(id);
            if (event.event != null and !std.mem.eql(u8, event.event.?, "message")) continue;
            var message_arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer message_arena_state.deinit();
            const message = json_rpc.parse(message_arena_state.allocator(), event.data) catch |err| {
                self.callbacks.errorInfo(.{ .err = err, .message = "failed to parse inbound MCP SSE message", .url = self.url });
                continue;
            };
            self.callbacks.message(message);
        }
        return .done;
    }

    fn deleteSession(self: *HttpTransport, io: std.Io, session: []const u8) anyerror!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const headers = try self.commonHeaders(io, arena, &.{}, session, null);
        var response = try self.http.?.request(io, arena, .{
            .method = .DELETE,
            .url = self.url,
            .headers = headers,
            .redirect_behavior = .not_allowed,
        }, null);
        defer response.body.deinit(io);
    }

    fn commonHeaders(
        self: *HttpTransport,
        _: std.Io,
        arena: Allocator,
        base: []const provider.Header,
        session: ?[]const u8,
        last_event_id: ?[]const u8,
    ) Allocator.Error![]const provider.Header {
        lockAtomic(&self.state_mutex);
        defer self.state_mutex.unlock();
        const extra_count: usize = 1 +
            @as(usize, @intFromBool(session != null)) +
            @as(usize, @intFromBool(last_event_id != null));
        const entries = try arena.alloc(provider_utils.HeaderEntry, self.custom_headers.len + base.len + extra_count);
        var index: usize = 0;
        for (self.custom_headers) |header| {
            entries[index] = .{ .name = header.name, .value = header.value };
            index += 1;
        }
        for (base) |header| {
            entries[index] = .{ .name = header.name, .value = header.value };
            index += 1;
        }
        entries[index] = .{ .name = "mcp-protocol-version", .value = self.protocol_version };
        index += 1;
        if (session) |value| {
            entries[index] = .{ .name = "mcp-session-id", .value = value };
            index += 1;
        }
        if (last_event_id) |value| {
            entries[index] = .{ .name = "last-event-id", .value = value };
        }
        const normalized = try provider_utils.normalizeHeaders(arena, entries);
        return provider_utils.withUserAgentSuffix(arena, normalized, &.{"ai-sdk-zig-mcp/0.1.0"});
    }

    fn applySessionHeader(self: *HttpTransport, headers: []const provider.Header) Allocator.Error!void {
        const value = provider_utils.getHeader(headers, "mcp-session-id") orelse return;
        return self.setSessionId(value);
    }

    fn setSessionId(self: *HttpTransport, value: ?[]const u8) Allocator.Error!void {
        const owned = if (value) |item| try self.gpa.dupe(u8, item) else null;
        lockAtomic(&self.state_mutex);
        if (optionalEql(self.session_id, value)) {
            self.state_mutex.unlock();
            if (owned) |item| self.gpa.free(item);
            return;
        }
        const previous = self.session_id;
        self.session_id = owned;
        const callback_value = if (self.session_id) |item| @as(?[]const u8, item) else null;
        self.state_mutex.unlock();
        if (previous) |item| self.gpa.free(item);
        if (self.on_session_changed) |hook| hook.callback(hook.ctx, callback_value);
    }

    fn expireSession(self: *HttpTransport, expired: []const u8) Allocator.Error!void {
        const callback_copy = try self.gpa.dupe(u8, expired);
        defer self.gpa.free(callback_copy);
        lockAtomic(&self.state_mutex);
        const is_current = if (self.session_id) |current| std.mem.eql(u8, current, expired) else false;
        self.state_mutex.unlock();
        if (is_current) try self.setSessionId(null);
        if (self.on_session_expired) |hook| hook.callback(hook.ctx, callback_copy);
    }

    fn setLastEventId(self: *HttpTransport, value: []const u8) Allocator.Error!void {
        const owned = try self.gpa.dupe(u8, value);
        lockAtomic(&self.state_mutex);
        const previous = self.last_event_id;
        self.last_event_id = owned;
        self.state_mutex.unlock();
        if (previous) |item| self.gpa.free(item);
    }

    fn sessionSnapshot(self: *HttpTransport, arena: Allocator) Allocator.Error!?[]u8 {
        lockAtomic(&self.state_mutex);
        defer self.state_mutex.unlock();
        return if (self.session_id) |value| try arena.dupe(u8, value) else null;
    }

    fn lastEventIdSnapshot(self: *HttpTransport, arena: Allocator) Allocator.Error!?[]u8 {
        lockAtomic(&self.state_mutex);
        defer self.state_mutex.unlock();
        return if (self.last_event_id) |value| try arena.dupe(u8, value) else null;
    }

    fn notifyClose(self: *HttpTransport) void {
        if (!self.close_notified.swap(true, .acq_rel)) self.callbacks.closed();
    }

    fn setCallbacks(raw: *anyopaque, callbacks: transport_api.Callbacks) void {
        const self: *HttpTransport = @ptrCast(@alignCast(raw));
        self.callbacks = callbacks;
    }

    fn getProtocolVersion(raw: *anyopaque) ?[]const u8 {
        const self: *HttpTransport = @ptrCast(@alignCast(raw));
        lockAtomic(&self.state_mutex);
        defer self.state_mutex.unlock();
        return self.protocol_version;
    }

    fn setProtocolVersion(raw: *anyopaque, version: []const u8) anyerror!void {
        const self: *HttpTransport = @ptrCast(@alignCast(raw));
        const owned = try self.gpa.dupe(u8, version);
        lockAtomic(&self.state_mutex);
        const previous = self.protocol_version;
        self.protocol_version = owned;
        self.state_mutex.unlock();
        self.gpa.free(previous);
    }

    fn startAdapter(raw: *anyopaque, io: std.Io) anyerror!void {
        const self: *HttpTransport = @ptrCast(@alignCast(raw));
        return self.start(io);
    }

    fn sendAdapter(raw: *anyopaque, io: std.Io, message: json_rpc.Message) anyerror!void {
        const self: *HttpTransport = @ptrCast(@alignCast(raw));
        return self.send(io, message);
    }

    fn closeAdapter(raw: *anyopaque, io: std.Io) anyerror!void {
        const self: *HttpTransport = @ptrCast(@alignCast(raw));
        return self.close(io);
    }

    const vtable: transport_api.VTable = .{
        .start = startAdapter,
        .send = sendAdapter,
        .close = closeAdapter,
        .set_callbacks = setCallbacks,
        .get_protocol_version = getProtocolVersion,
        .set_protocol_version = setProtocolVersion,
    };
};

fn mapRequestError(err: anyerror, diagnostics: *const provider.Diagnostics) anyerror {
    if (err == error.Canceled or err == error.OutOfMemory) return err;
    if (diagnostics.available and diagnostics.payload == .api_call and diagnostics.payload.api_call.is_retryable) {
        return error.RetryableTransportError;
    }
    return err;
}

fn isRetryableStatus(status: u16) bool {
    return status == 408 or status == 409 or status == 429 or status >= 500;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn lockAtomic(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn cloneHeaders(gpa: Allocator, source: []const provider.Header) Allocator.Error![]const provider.Header {
    const result = try gpa.alloc(provider.Header, source.len);
    errdefer gpa.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |header| {
        gpa.free(header.name);
        gpa.free(header.value);
    };
    for (source, result) |header, *owned| {
        const name = try gpa.dupe(u8, header.name);
        errdefer gpa.free(name);
        const value = try gpa.dupe(u8, header.value);
        owned.* = .{
            .name = name,
            .value = value,
        };
        initialized += 1;
    }
    return result;
}

fn freeHeaders(gpa: Allocator, headers: []const provider.Header) void {
    for (headers) |header| {
        gpa.free(header.name);
        gpa.free(header.value);
    }
    gpa.free(headers);
}

test "Streamable HTTP retry status classification matches MCP client contract" {
    try std.testing.expect(isRetryableStatus(408));
    try std.testing.expect(isRetryableStatus(409));
    try std.testing.expect(isRetryableStatus(429));
    try std.testing.expect(isRetryableStatus(500));
    try std.testing.expect(!isRetryableStatus(401));
    try std.testing.expect(!isRetryableStatus(422));
}
