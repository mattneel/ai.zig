//! Legacy MCP HTTP+SSE transport.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const json_rpc = @import("json_rpc.zig");
const transport_api = @import("transport.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    url: []const u8,
    headers: []const provider.Header = &.{},
    transport: ?provider_utils.HttpTransport = null,
    auth_hook: ?transport_api.AuthHook = null,
};

pub const SseTransport = struct {
    gpa: Allocator,
    url: []u8,
    custom_headers: []const provider.Header,
    custom_transport: ?provider_utils.HttpTransport,
    owned_client: ?provider_utils.HttpClientTransport = null,
    http: ?provider_utils.HttpTransport = null,
    auth_hook: ?transport_api.AuthHook,
    callbacks: transport_api.Callbacks = .{},
    protocol_version: []u8,
    endpoint: ?[]u8 = null,
    started: bool = false,
    connected: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    close_notified: std.atomic.Value(bool) = .init(false),
    start_cell: provider_utils.OneShot(anyerror!void) = .{},
    reader_future: ?std.Io.Future(void) = null,

    pub fn init(gpa: Allocator, config: Config) Allocator.Error!SseTransport {
        const headers = try cloneHeaders(gpa, config.headers);
        errdefer freeHeaders(gpa, headers);
        const url = try gpa.dupe(u8, config.url);
        errdefer gpa.free(url);
        const protocol_version = try gpa.dupe(u8, types.LATEST_PROTOCOL_VERSION);
        return .{
            .gpa = gpa,
            .url = url,
            .custom_headers = headers,
            .custom_transport = config.transport,
            .auth_hook = config.auth_hook,
            .protocol_version = protocol_version,
        };
    }

    pub fn deinit(self: *SseTransport) void {
        std.debug.assert(!self.started);
        if (self.endpoint) |endpoint| self.gpa.free(endpoint);
        if (self.owned_client) |*client| client.deinit();
        freeHeaders(self.gpa, self.custom_headers);
        self.gpa.free(self.url);
        self.gpa.free(self.protocol_version);
        self.* = undefined;
    }

    pub fn transport(self: *SseTransport) transport_api.MCPTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn start(self: *SseTransport, io: std.Io) anyerror!void {
        if (self.started) return error.TransportAlreadyStarted;
        self.started = true;
        self.closing.store(false, .release);
        self.close_notified.store(false, .release);
        self.start_cell = .{};
        if (self.custom_transport) |custom| {
            self.http = custom;
        } else {
            self.owned_client = provider_utils.HttpClientTransport.init(self.gpa, io);
            if (self.owned_client) |*client| self.http = client.transport();
        }

        self.reader_future = io.concurrent(readerMain, .{ self, io }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                self.started = false;
                return error.ConcurrencyUnavailable;
            },
        };
        return try self.start_cell.wait(io);
    }

    pub fn send(self: *SseTransport, io: std.Io, message: json_rpc.Message) anyerror!void {
        if (!self.connected.load(.acquire) or self.endpoint == null) return error.TransportNotConnected;
        return self.sendAttempt(io, message, false);
    }

    pub fn close(self: *SseTransport, io: std.Io) anyerror!void {
        if (!self.started) return;
        self.closing.store(true, .release);
        self.connected.store(false, .release);
        if (self.reader_future) |*future| {
            future.cancel(io);
            self.reader_future = null;
        }
        if (self.endpoint) |endpoint| {
            self.gpa.free(endpoint);
            self.endpoint = null;
        }
        self.http = null;
        if (self.owned_client) |*client| client.deinit();
        self.owned_client = null;
        self.started = false;
        self.notifyClose();
    }

    fn readerMain(self: *SseTransport, io: std.Io) void {
        self.runReader(io, false) catch |err| {
            if (!self.closing.load(.acquire)) {
                self.callbacks.errorInfo(.{ .err = err, .message = "MCP SSE transport reader failed", .url = self.url });
                if (!self.start_cell.event.isSet()) self.start_cell.resolve(io, err);
            }
        };
    }

    fn runReader(self: *SseTransport, io: std.Io, tried_auth: bool) anyerror!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const headers = try self.commonHeaders(arena, &.{.{ .name = "accept", .value = "text/event-stream" }});
        var diagnostics = provider.Diagnostics.init(self.gpa);
        defer diagnostics.deinit();
        var response = try self.http.?.request(io, arena, .{
            .method = .GET,
            .url = self.url,
            .headers = headers,
            .redirect_behavior = .not_allowed,
        }, &diagnostics);
        defer response.body.deinit(io);

        if (response.status == 401 and !tried_auth and self.auth_hook != null) {
            if (try self.auth_hook.?.authorize(io, self.url, response.status)) {
                return self.runReader(io, true);
            }
        }
        if (response.status < 200 or response.status >= 300 or !response.has_body) {
            return error.APICallError;
        }

        var decoder = provider_utils.SseDecoder.init(self.gpa, response.body.reader(), .{});
        defer decoder.deinit();
        while (!self.closing.load(.acquire)) {
            const event = (try decoder.next()) orelse break;
            if (event.event != null and std.mem.eql(u8, event.event.?, "endpoint")) {
                if (self.endpoint != null) continue;
                self.endpoint = try resolveEndpoint(self.gpa, self.url, event.data);
                self.connected.store(true, .release);
                if (!self.start_cell.event.isSet()) self.start_cell.resolve(io, {});
                continue;
            }
            if (event.event == null or std.mem.eql(u8, event.event.?, "message")) {
                var message_arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer message_arena_state.deinit();
                const message = json_rpc.parse(message_arena_state.allocator(), event.data) catch |err| {
                    self.callbacks.errorInfo(.{ .err = err, .message = "failed to parse MCP SSE message", .url = self.url });
                    continue;
                };
                self.callbacks.message(message);
            }
        }

        if (!self.start_cell.event.isSet()) {
            self.start_cell.resolve(io, error.MissingEndpoint);
        } else if (!self.closing.load(.acquire)) {
            self.connected.store(false, .release);
            return error.ConnectionClosed;
        }
    }

    fn sendAttempt(self: *SseTransport, io: std.Io, message: json_rpc.Message, tried_auth: bool) anyerror!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const encoded = try json_rpc.serialize(arena, message);
        const headers = try self.commonHeaders(arena, &.{.{ .name = "content-type", .value = "application/json" }});
        var diagnostics = provider.Diagnostics.init(self.gpa);
        defer diagnostics.deinit();
        var response = self.http.?.request(io, arena, .{
            .method = .POST,
            .url = self.endpoint.?,
            .headers = headers,
            .body = encoded,
            .redirect_behavior = .not_allowed,
        }, &diagnostics) catch |err| {
            self.callbacks.errorInfo(.{ .err = err, .message = "MCP SSE POST failed", .url = self.endpoint.? });
            return err;
        };
        defer response.body.deinit(io);

        if (response.status == 401 and !tried_auth) {
            if (self.auth_hook) |hook| {
                if (try hook.authorize(io, self.url, response.status)) {
                    return self.sendAttempt(io, message, true);
                }
            }
        }
        if (response.status < 200 or response.status >= 300) {
            const body = if (response.has_body)
                provider_utils.http_transport.readBodyWithLimit(arena, &response.body, 64 * 1024) catch null
            else
                null;
            self.callbacks.errorInfo(.{
                .err = error.APICallError,
                .message = "MCP SSE endpoint POST returned an error",
                .status_code = response.status,
                .url = self.endpoint,
                .response_body = body,
            });
            return error.APICallError;
        }
    }

    fn commonHeaders(self: *SseTransport, arena: Allocator, base: []const provider.Header) Allocator.Error![]const provider.Header {
        const entries = try arena.alloc(provider_utils.HeaderEntry, self.custom_headers.len + base.len + 1);
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
        const normalized = try provider_utils.normalizeHeaders(arena, entries);
        return provider_utils.withUserAgentSuffix(arena, normalized, &.{"ai-sdk-zig-mcp/0.1.0"});
    }

    fn notifyClose(self: *SseTransport) void {
        if (!self.close_notified.swap(true, .acq_rel)) self.callbacks.closed();
    }

    fn setCallbacks(raw: *anyopaque, callbacks: transport_api.Callbacks) void {
        const self: *SseTransport = @ptrCast(@alignCast(raw));
        self.callbacks = callbacks;
    }

    fn getProtocolVersion(raw: *anyopaque) ?[]const u8 {
        const self: *SseTransport = @ptrCast(@alignCast(raw));
        return self.protocol_version;
    }

    fn setProtocolVersion(raw: *anyopaque, version: []const u8) anyerror!void {
        const self: *SseTransport = @ptrCast(@alignCast(raw));
        const owned = try self.gpa.dupe(u8, version);
        self.gpa.free(self.protocol_version);
        self.protocol_version = owned;
    }

    fn startAdapter(raw: *anyopaque, io: std.Io) anyerror!void {
        const self: *SseTransport = @ptrCast(@alignCast(raw));
        return self.start(io);
    }

    fn sendAdapter(raw: *anyopaque, io: std.Io, message: json_rpc.Message) anyerror!void {
        const self: *SseTransport = @ptrCast(@alignCast(raw));
        return self.send(io, message);
    }

    fn closeAdapter(raw: *anyopaque, io: std.Io) anyerror!void {
        const self: *SseTransport = @ptrCast(@alignCast(raw));
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

fn resolveEndpoint(gpa: Allocator, base_url: []const u8, endpoint_data: []const u8) anyerror![]u8 {
    const endpoint = std.mem.trim(u8, endpoint_data, " \t\r\n");
    const absolute = if (std.mem.indexOf(u8, endpoint, "://") != null)
        try gpa.dupe(u8, endpoint)
    else blk: {
        const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidUrl;
        const authority_start = scheme_end + 3;
        const path_start = std.mem.findScalarPos(u8, base_url, authority_start, '/') orelse base_url.len;
        if (endpoint.len != 0 and endpoint[0] == '/') {
            break :blk try std.mem.concat(gpa, u8, &.{ base_url[0..path_start], endpoint });
        }
        if (path_start == base_url.len) {
            break :blk try std.mem.concat(gpa, u8, &.{ base_url, "/", endpoint });
        }
        const directory_end = if (std.mem.lastIndexOfScalar(u8, base_url[0..path_start], '/')) |index|
            index + 1
        else
            path_start;
        const base_directory_end = if (path_start < base_url.len)
            (std.mem.lastIndexOfScalar(u8, base_url, '/') orelse path_start) + 1
        else
            directory_end;
        break :blk try std.mem.concat(gpa, u8, &.{ base_url[0..base_directory_end], endpoint });
    };
    errdefer gpa.free(absolute);

    const base = std.Uri.parse(base_url) catch return error.InvalidUrl;
    const resolved = std.Uri.parse(absolute) catch return error.InvalidUrl;
    if (!sameOrigin(base, resolved)) return error.CrossOriginEndpoint;
    return absolute;
}

fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    const a_host = a.host orelse return false;
    const b_host = b.host orelse return false;
    const a_host_bytes = switch (a_host) {
        .raw, .percent_encoded => |value| value,
    };
    const b_host_bytes = switch (b_host) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.ascii.eqlIgnoreCase(a_host_bytes, b_host_bytes)) return false;
    return effectivePort(a) == effectivePort(b);
}

fn effectivePort(uri: std.Uri) ?u16 {
    return uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        80
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        443
    else
        null;
}

test "legacy SSE endpoint resolution enforces same origin" {
    const allocator = std.testing.allocator;
    const relative = try resolveEndpoint(allocator, "http://localhost:3000/sse", "/messages");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("http://localhost:3000/messages", relative);

    try std.testing.expectError(
        error.CrossOriginEndpoint,
        resolveEndpoint(allocator, "http://localhost:3000/sse", "http://localhost:3333/messages"),
    );
}
