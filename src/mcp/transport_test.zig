const std = @import("std");
const http_api = @import("http_transport.zig");
const json_rpc = @import("json_rpc.zig");
const sse_api = @import("sse_transport.zig");
const test_support = @import("test_support");

const Recorder = struct {
    messages: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
    last_id: std.atomic.Value(i64) = .init(-1),

    fn onMessage(raw: ?*anyopaque, message: json_rpc.Message) void {
        const self: *Recorder = @ptrCast(@alignCast(raw.?));
        if (message.id()) |id| if (id.asInteger()) |value| self.last_id.store(value, .release);
        _ = self.messages.fetchAdd(1, .acq_rel);
    }

    fn onError(raw: ?*anyopaque, _: @import("transport.zig").ErrorInfo) void {
        const self: *Recorder = @ptrCast(@alignCast(raw.?));
        _ = self.errors.fetchAdd(1, .acq_rel);
    }
};

fn waitForRequests(server: *test_support.MockServer, io: std.Io, count: usize) !void {
    var attempts: usize = 0;
    while (server.recordedRequests().len < count and attempts < 500) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(server.recordedRequests().len >= count);
}

fn waitForMessages(recorder: *Recorder, io: std.Io, count: usize) !void {
    var attempts: usize = 0;
    while (recorder.messages.load(.acquire) < count and attempts < 1000) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(recorder.messages.load(.acquire) >= count);
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

test "Streamable HTTP dispatches JSON single and array responses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .status = .method_not_allowed, .content_type = "text/plain", .body = .{ .text = "" } });

    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/mcp", .{server.baseUrl(&base_buffer)});
    var transport = try http_api.HttpTransport.init(allocator, .{ .url = url });
    defer transport.deinit();
    var recorder: Recorder = .{};
    const iface = transport.transport();
    iface.setCallbacks(.{ .ctx = &recorder, .on_message = Recorder.onMessage, .on_error = Recorder.onError });
    try iface.start(io);
    defer iface.close(io) catch {};
    try waitForRequests(server, io, 1);

    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}" },
    });
    try iface.send(io, .{ .request = .{ .id = .{ .integer = 1 }, .method = "initialize", .params = .{ .object = .empty } } });
    try std.testing.expectEqual(1, recorder.messages.load(.acquire));

    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "[{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}},{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}]" },
    });
    try iface.send(io, .{ .request = .{ .id = .{ .integer = 2 }, .method = "tools/list" } });
    try std.testing.expectEqual(3, recorder.messages.load(.acquire));
    try std.testing.expectEqual(3, recorder.last_id.load(.acquire));
    try iface.close(io);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(.GET, requests[0].method);
    try std.testing.expectEqual(.POST, requests[1].method);
    try std.testing.expectEqualStrings("application/json, text/event-stream", headerValue(requests[1].headers, "accept").?);
    try std.testing.expectEqualStrings("2025-11-25", headerValue(requests[1].headers, "mcp-protocol-version").?);
}

test "Streamable HTTP parses per-request SSE and invokes the deferred auth seam once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .status = .method_not_allowed, .content_type = "text/plain", .body = .{ .text = "" } });

    const Auth = struct {
        calls: usize = 0,
        fn authorize(raw: ?*anyopaque, _: std.Io, _: []const u8, status: u16) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return status == 401;
        }
    };
    var auth: Auth = .{};
    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/mcp", .{server.baseUrl(&base_buffer)});
    var transport = try http_api.HttpTransport.init(allocator, .{
        .url = url,
        .auth_hook = .{ .ctx = &auth, .authorize_fn = Auth.authorize },
    });
    defer transport.deinit();
    var recorder: Recorder = .{};
    const iface = transport.transport();
    iface.setCallbacks(.{ .ctx = &recorder, .on_message = Recorder.onMessage, .on_error = Recorder.onError });
    try iface.start(io);
    defer iface.close(io) catch {};
    try waitForRequests(server, io, 1);

    try server.enqueue(.{ .status = .unauthorized, .content_type = "text/plain", .body = .{ .text = "unauthorized" } });
    try server.enqueue(.{
        .content_type = "ignored",
        .body = .{ .sse = &.{.{
            .event = "message",
            .data = "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"ok\":true}}",
        }} },
    });
    try iface.send(io, .{ .request = .{ .id = .{ .integer = 11 }, .method = "initialize" } });
    try waitForMessages(&recorder, io, 1);
    try std.testing.expectEqual(1, auth.calls);
    try std.testing.expectEqual(1, recorder.messages.load(.acquire));
    try std.testing.expectEqual(11, recorder.last_id.load(.acquire));
    try iface.close(io);
}

test "Streamable HTTP captures sessions, resumes inbound SSE, expires on 404, and deletes on close" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .status = .method_not_allowed, .content_type = "text/plain", .body = .{ .text = "" } });

    const SessionRecorder = struct {
        changes: std.atomic.Value(usize) = .init(0),
        expired: std.atomic.Value(usize) = .init(0),
        fn changed(raw: ?*anyopaque, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.changes.fetchAdd(1, .acq_rel);
        }
        fn expire(raw: ?*anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.expired.fetchAdd(1, .acq_rel);
        }
    };
    var sessions: SessionRecorder = .{};
    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/mcp", .{server.baseUrl(&base_buffer)});
    var transport = try http_api.HttpTransport.init(allocator, .{
        .url = url,
        .on_session_changed = .{ .ctx = &sessions, .callback = SessionRecorder.changed },
        .on_session_expired = .{ .ctx = &sessions, .callback = SessionRecorder.expire },
    });
    defer transport.deinit();
    var recorder: Recorder = .{};
    const iface = transport.transport();
    iface.setCallbacks(.{ .ctx = &recorder, .on_message = Recorder.onMessage, .on_error = Recorder.onError });
    try iface.start(io);
    defer iface.close(io) catch {};
    try waitForRequests(server, io, 1);

    try server.enqueue(.{
        .status = .accepted,
        .content_type = "text/plain",
        .extra_headers = &.{.{ .name = "mcp-session-id", .value = "session-1" }},
        .body = .{ .text = "" },
    });
    try server.enqueue(.{
        .content_type = "ignored",
        .body = .{ .sse = &.{.{
            .id = "event-7",
            .data = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"source\":\"first\"}}",
        }} },
    });
    try server.enqueue(.{
        .content_type = "ignored",
        .body = .{ .sse = &.{.{
            .id = "event-8",
            .data = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"source\":\"resumed\"}}",
        }} },
    });
    try iface.send(io, .{ .notification = .{ .method = "notifications/initialized" } });
    try waitForMessages(&recorder, io, 2);
    try std.testing.expectEqual(1, sessions.changes.load(.acquire));

    try server.enqueue(.{ .content_type = "text/plain", .body = .{ .text = "" } });
    try iface.close(io);
    const requests = server.recordedRequests();
    try std.testing.expect(requests.len >= 5);
    try std.testing.expectEqual(.GET, requests[2].method);
    try std.testing.expectEqualStrings("session-1", headerValue(requests[2].headers, "mcp-session-id").?);
    try std.testing.expectEqual(.GET, requests[3].method);
    try std.testing.expectEqualStrings("event-7", headerValue(requests[3].headers, "last-event-id").?);
    try std.testing.expectEqualStrings("session-1", headerValue(requests[3].headers, "mcp-session-id").?);
    try std.testing.expectEqual(.DELETE, requests[requests.len - 1].method);

    // A separate resumed transport covers the 404 expiry hook deterministically.
    try server.enqueue(.{ .status = .method_not_allowed, .content_type = "text/plain", .body = .{ .text = "" } });
    var expired_transport = try http_api.HttpTransport.init(allocator, .{
        .url = url,
        .initial_session_id = "expired",
        .on_session_changed = .{ .ctx = &sessions, .callback = SessionRecorder.changed },
        .on_session_expired = .{ .ctx = &sessions, .callback = SessionRecorder.expire },
        .terminate_session_on_close = false,
    });
    defer expired_transport.deinit();
    const expired_iface = expired_transport.transport();
    try expired_iface.start(io);
    defer expired_iface.close(io) catch {};
    try waitForRequests(server, io, requests.len + 1);
    try server.enqueue(.{ .status = .not_found, .content_type = "text/plain", .body = .{ .text = "gone" } });
    try std.testing.expectError(
        error.APICallError,
        expired_iface.send(io, .{ .request = .{ .id = .{ .integer = 9 }, .method = "tools/list" } }),
    );
    try std.testing.expectEqual(1, sessions.expired.load(.acquire));
    try expired_iface.close(io);

    try server.enqueue(.{ .status = .not_found, .content_type = "text/plain", .body = .{ .text = "gone" } });
    var inbound_expired = try http_api.HttpTransport.init(allocator, .{
        .url = url,
        .initial_session_id = "expired-inbound",
        .on_session_changed = .{ .ctx = &sessions, .callback = SessionRecorder.changed },
        .on_session_expired = .{ .ctx = &sessions, .callback = SessionRecorder.expire },
        .terminate_session_on_close = false,
    });
    defer inbound_expired.deinit();
    const inbound_expired_iface = inbound_expired.transport();
    try inbound_expired_iface.start(io);
    defer inbound_expired_iface.close(io) catch {};
    var expiry_waits: usize = 0;
    while (sessions.expired.load(.acquire) < 2 and expiry_waits < 500) : (expiry_waits += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(2, sessions.expired.load(.acquire));
    try inbound_expired_iface.close(io);
}

test "legacy SSE accepts endpoint then messages and rejects cross-origin endpoints" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    var base_buffer: [64]u8 = undefined;
    const base = server.baseUrl(&base_buffer);
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/sse", .{base});
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/messages", .{base});
    try server.enqueue(.{
        .content_type = "ignored",
        .body = .{ .sse = &.{
            .{ .event = "endpoint", .data = endpoint, .delay_ms = 20 },
            .{ .event = "message", .data = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}" },
        } },
        .hold_open = true,
    });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"accepted\":true}" } });
    var transport = try sse_api.SseTransport.init(allocator, .{ .url = url });
    defer transport.deinit();
    var recorder: Recorder = .{};
    const iface = transport.transport();
    iface.setCallbacks(.{ .ctx = &recorder, .on_message = Recorder.onMessage, .on_error = Recorder.onError });
    try iface.start(io);
    defer iface.close(io) catch {};
    try waitForMessages(&recorder, io, 1);
    try std.testing.expectEqual(1, recorder.last_id.load(.acquire));
    try iface.send(io, .{ .request = .{ .id = .{ .integer = 5 }, .method = "tools/list" } });
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expectEqual(.POST, requests[1].method);
    try std.testing.expectEqualStrings("/messages", requests[1].target);
    try iface.close(io);

    try server.enqueue(.{
        .content_type = "ignored",
        .body = .{ .sse = &.{.{ .event = "endpoint", .data = "http://example.com/messages" }} },
    });
    var rejected = try sse_api.SseTransport.init(allocator, .{ .url = url });
    defer rejected.deinit();
    defer rejected.close(io) catch {};
    try std.testing.expectError(error.CrossOriginEndpoint, rejected.start(io));
    try rejected.close(io);
}

test "legacy SSE retries a 401 through the deferred auth seam once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    var base_buffer: [64]u8 = undefined;
    const base = server.baseUrl(&base_buffer);
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/sse", .{base});
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/messages", .{base});
    try server.enqueue(.{ .status = .unauthorized, .content_type = "text/plain", .body = .{ .text = "unauthorized" } });
    try server.enqueue(.{
        .content_type = "ignored",
        .body = .{ .sse = &.{.{ .event = "endpoint", .data = endpoint }} },
    });
    const Auth = struct {
        calls: usize = 0,
        fn authorize(raw: ?*anyopaque, _: std.Io, _: []const u8, _: u16) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return true;
        }
    };
    var auth: Auth = .{};
    var transport = try sse_api.SseTransport.init(allocator, .{
        .url = url,
        .auth_hook = .{ .ctx = &auth, .authorize_fn = Auth.authorize },
    });
    defer transport.deinit();
    const iface = transport.transport();
    try iface.start(io);
    defer iface.close(io) catch {};
    try std.testing.expectEqual(1, auth.calls);
    try iface.close(io);
}
