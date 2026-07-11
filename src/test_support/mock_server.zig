const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Header = std.http.Header;

pub const SseEvent = struct {
    data: []const u8,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    delay_ms: u64 = 0,
};

pub const Body = union(enum) {
    text: []const u8,
    sse: []const SseEvent,
};

pub const CannedResponse = struct {
    status: std.http.Status = .ok,
    content_type: []const u8,
    extra_headers: []const Header = &.{},
    body: Body,
    hold_open: bool = false,
};

pub const RecordedRequest = struct {
    method: std.http.Method,
    target: []const u8,
    headers: []const Header,
    body: []const u8,
};

pub const ServeErrorReport = struct {
    count: usize,
    last: anyerror,
};

pub const MockServer = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    listener: Io.net.Server,
    thread: ?std.Thread,
    held_connections: Io.Group,
    stopping: std.atomic.Value(bool),
    mutex: Io.Mutex,
    responses: std.ArrayList(CannedResponse),
    next_response: usize,
    requests: std.ArrayList(RecordedRequest),
    serve_error_count: usize,
    last_serve_error: ?anyerror,

    pub fn start(gpa: Allocator, io: Io) !*MockServer {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const listener = try address.listen(io, .{ .reuse_address = true });

        const self = try gpa.create(MockServer);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .listener = listener,
            .thread = null,
            .held_connections = .init,
            .stopping = .init(false),
            .mutex = .init,
            .responses = .empty,
            .next_response = 0,
            .requests = .empty,
            .serve_error_count = 0,
            .last_serve_error = null,
        };
        errdefer {
            self.listener.deinit(io);
            self.arena.deinit();
            gpa.destroy(self);
        }

        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    pub fn port(self: *const MockServer) u16 {
        return switch (self.listener.socket.address) {
            .ip4 => |address| address.port,
            .ip6 => |address| address.port,
        };
    }

    pub fn baseUrl(self: *const MockServer, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}", .{self.port()}) catch
            @panic("MockServer.baseUrl buffer is too small");
    }

    pub fn enqueue(self: *MockServer, response: CannedResponse) Allocator.Error!void {
        const owned = try self.cloneResponse(response);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.responses.append(self.gpa, owned);
    }

    /// The returned view remains valid until another request is recorded.
    pub fn recordedRequests(self: *MockServer) []const RecordedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.requests.items;
    }

    pub fn serveErrorCount(self: *MockServer) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.serve_error_count;
    }

    pub fn takeServeErrors(self: *MockServer) ?ServeErrorReport {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.serve_error_count == 0) return null;
        const report: ServeErrorReport = .{
            .count = self.serve_error_count,
            .last = self.last_serve_error.?,
        };
        self.serve_error_count = 0;
        self.last_serve_error = null;
        return report;
    }

    pub fn stop(self: *MockServer) void {
        if (self.stopping.swap(true, .acq_rel)) return;

        var wake_stream = self.listener.socket.address.connect(self.io, .{ .mode = .stream }) catch null;
        if (wake_stream) |*stream| stream.close(self.io);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.held_connections.cancel(self.io);
    }

    pub fn deinit(self: *MockServer) void {
        self.stop();
        self.listener.deinit(self.io);
        self.responses.deinit(self.gpa);
        self.requests.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    fn cloneResponse(self: *MockServer, response: CannedResponse) Allocator.Error!CannedResponse {
        const arena = self.arena.allocator();
        const extra_headers = try arena.alloc(Header, response.extra_headers.len);
        for (response.extra_headers, extra_headers) |source, *destination| {
            destination.* = .{
                .name = try arena.dupe(u8, source.name),
                .value = try arena.dupe(u8, source.value),
            };
        }

        return .{
            .status = response.status,
            .content_type = try arena.dupe(u8, response.content_type),
            .extra_headers = extra_headers,
            .body = switch (response.body) {
                .text => |text| .{ .text = try arena.dupe(u8, text) },
                .sse => |events| blk: {
                    const owned_events = try arena.alloc(SseEvent, events.len);
                    for (events, owned_events) |event, *owned| {
                        owned.* = .{
                            .data = try arena.dupe(u8, event.data),
                            .event = if (event.event) |value| try arena.dupe(u8, value) else null,
                            .id = if (event.id) |value| try arena.dupe(u8, value) else null,
                            .delay_ms = event.delay_ms,
                        };
                    }
                    break :blk .{ .sse = owned_events };
                },
            },
            .hold_open = response.hold_open,
        };
    }

    fn takeHeldSseResponse(self: *MockServer) ?CannedResponse {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.next_response == self.responses.items.len) return null;
        const response = self.responses.items[self.next_response];
        if (!response.hold_open or response.body != .sse) return null;
        self.next_response += 1;
        return response;
    }

    fn takeResponse(self: *MockServer) ?CannedResponse {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.next_response == self.responses.items.len) return null;
        defer self.next_response += 1;
        return self.responses.items[self.next_response];
    }

    fn recordServeError(self: *MockServer, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.serve_error_count +|= 1;
        self.last_serve_error = err;
    }

    fn record(self: *MockServer, request: *std.http.Server.Request) !void {
        const arena = self.arena.allocator();
        const method = request.head.method;
        const target = try arena.dupe(u8, request.head.target);

        var headers: std.ArrayList(Header) = .empty;
        defer headers.deinit(arena);
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| {
            try headers.append(arena, .{
                .name = try arena.dupe(u8, header.name),
                .value = try arena.dupe(u8, header.value),
            });
        }
        const owned_headers = try headers.toOwnedSlice(arena);

        var request_buffer: [4096]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&request_buffer);
        var body_output: Io.Writer.Allocating = .init(arena);
        defer body_output.deinit();
        _ = try body_reader.streamRemaining(&body_output.writer);
        const body = try body_output.toOwnedSlice();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.requests.append(self.gpa, .{
            .method = method,
            .target = target,
            .headers = owned_headers,
            .body = body,
        });
    }

    fn serveResponse(self: *MockServer, request: *std.http.Server.Request, canned: CannedResponse) !void {
        const content_type = switch (canned.body) {
            .text => canned.content_type,
            .sse => "text/event-stream",
        };
        const headers = try self.gpa.alloc(Header, canned.extra_headers.len + 1);
        defer self.gpa.free(headers);
        headers[0] = .{ .name = "content-type", .value = content_type };
        @memcpy(headers[1..], canned.extra_headers);

        switch (canned.body) {
            .text => |text| try request.respond(text, .{
                .status = canned.status,
                .keep_alive = false,
                .extra_headers = headers,
            }),
            .sse => |events| {
                var maximum_event_len: usize = 1;
                for (events) |event| {
                    var event_len = "data: \n\n".len + event.data.len;
                    if (event.event) |value| event_len += "event: \n".len + value.len;
                    if (event.id) |value| event_len += "id: \n".len + value.len;
                    maximum_event_len = @max(maximum_event_len, event_len);
                }

                const response_buffer = try self.gpa.alloc(u8, maximum_event_len);
                defer self.gpa.free(response_buffer);
                var response = try request.respondStreaming(response_buffer, .{
                    .respond_options = .{
                        .status = canned.status,
                        .keep_alive = false,
                        .extra_headers = headers,
                    },
                });

                for (events, 0..) |event, index| {
                    if (event.event) |value| try response.writer.print("event: {s}\n", .{value});
                    if (event.id) |value| try response.writer.print("id: {s}\n", .{value});
                    try response.writer.print("data: {s}\n\n", .{event.data});
                    if (canned.hold_open) try response.writer.flush();
                    try response.flush();

                    if (event.delay_ms != 0 and index + 1 < events.len) {
                        const delay_ms: i64 = @intCast(@min(event.delay_ms, std.math.maxInt(i64)));
                        try self.io.sleep(.fromMilliseconds(delay_ms), .awake);
                    }
                }
                if (canned.hold_open) {
                    _ = request.server.reader.in.discardRemaining() catch {};
                } else {
                    try response.end();
                }
            },
        }
    }

    fn serveConnection(self: *MockServer, stream: Io.net.Stream, canned_override: ?CannedResponse) !void {
        defer stream.close(self.io);

        var receive_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [8 * 1024]u8 = undefined;
        var stream_reader = stream.reader(self.io, &receive_buffer);
        var stream_writer = stream.writer(self.io, &send_buffer);
        var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = try server.receiveHead();

        try self.record(&request);
        const response = canned_override orelse self.takeResponse() orelse CannedResponse{
            .status = .internal_server_error,
            .content_type = "text/plain",
            .body = .{ .text = "no canned response enqueued" },
        };
        try self.serveResponse(&request, response);
    }

    fn serveHeldConnection(self: *MockServer, stream: Io.net.Stream, response: CannedResponse) void {
        self.serveConnection(stream, response) catch |err| {
            if (!self.stopping.load(.acquire)) self.recordServeError(err);
        };
    }

    fn serveLoop(self: *MockServer) !void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) return;
                return err;
            };
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            if (self.takeHeldSseResponse()) |response| {
                self.held_connections.concurrent(
                    self.io,
                    serveHeldConnection,
                    .{ self, stream, response },
                ) catch |err| {
                    stream.close(self.io);
                    return err;
                };
                continue;
            }
            self.serveConnection(stream, null) catch |err| {
                self.recordServeError(err);
                continue;
            };
        }
    }

    fn threadMain(self: *MockServer) void {
        self.serveLoop() catch |err| {
            self.recordServeError(err);
        };
    }
};

test "MockServer JSON round-trip records request" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try MockServer.start(allocator, io);
    defer server.deinit();

    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"ok\":true}" },
    });

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/chat", .{server.baseUrl(&base_buffer)});
    const uri = try std.Uri.parse(url);

    const payload = "{\"prompt\":\"hello\"}";
    var request = try client.request(.POST, uri, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = payload.len };
    var request_body = try request.sendBody(&.{});
    try request_body.writer.writeAll(payload);
    try request_body.end();

    var redirect_buffer: [256]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    try std.testing.expectEqual(.ok, response.head.status);
    try std.testing.expectEqualStrings("application/json", response.head.content_type.?);

    var transfer_buffer: [1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);
    var body_buffer: [128]u8 = undefined;
    var body_writer: Io.Writer = .fixed(&body_buffer);
    _ = try response_reader.streamRemaining(&body_writer);
    try std.testing.expectEqualStrings("{\"ok\":true}", body_writer.buffered());

    const recorded = server.recordedRequests();
    try std.testing.expectEqual(1, recorded.len);
    try std.testing.expectEqual(.POST, recorded[0].method);
    try std.testing.expectEqualStrings("/v1/chat", recorded[0].target);
    try std.testing.expectEqualStrings(payload, recorded[0].body);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "MockServer sse streaming preserves event order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try MockServer.start(allocator, io);
    defer server.deinit();

    try server.enqueue(.{
        .content_type = "ignored-for-sse",
        .body = .{ .sse = &.{
            .{ .data = "{\"delta\":\"Hel\"}", .event = "message", .id = "1", .delay_ms = 2 },
            .{ .data = "{\"delta\":\"lo\"}", .delay_ms = 2 },
            .{ .data = "[DONE]" },
        } },
    });

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/stream", .{server.baseUrl(&base_buffer)});
    const uri = try std.Uri.parse(url);

    var request = try client.request(.POST, uri, .{});
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = 2 };
    var request_body = try request.sendBody(&.{});
    try request_body.writer.writeAll("{}");
    try request_body.end();

    var redirect_buffer: [256]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    try std.testing.expectEqual(.ok, response.head.status);
    try std.testing.expectEqualStrings("text/event-stream", response.head.content_type.?);

    var transfer_buffer: [1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);
    var data_lines: std.ArrayList([]u8) = .empty;
    defer {
        for (data_lines.items) |line| allocator.free(line);
        data_lines.deinit(allocator);
    }
    var saw_event = false;
    var saw_id = false;

    while (true) {
        const line = (try response_reader.takeDelimiter('\n')) orelse break;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "event: ")) {
            try std.testing.expectEqualStrings("event: message", trimmed);
            saw_event = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "id: ")) {
            try std.testing.expectEqualStrings("id: 1", trimmed);
            saw_id = true;
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "data: ")) continue;
        try data_lines.append(allocator, try allocator.dupe(u8, trimmed["data: ".len..]));
    }

    try std.testing.expect(saw_event);
    try std.testing.expect(saw_id);
    try std.testing.expectEqual(3, data_lines.items.len);
    try std.testing.expectEqualStrings("{\"delta\":\"Hel\"}", data_lines.items[0]);
    try std.testing.expectEqualStrings("{\"delta\":\"lo\"}", data_lines.items[1]);
    try std.testing.expectEqualStrings("[DONE]", data_lines.items[2]);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "MockServer survives early sse client disconnect and serves next request" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try MockServer.start(allocator, io);
    defer server.deinit();

    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "first", .delay_ms = 15 },
            .{ .data = "second", .delay_ms = 15 },
            .{ .data = "third", .delay_ms = 15 },
            .{ .data = "fourth", .delay_ms = 15 },
            .{ .data = "fifth", .delay_ms = 15 },
            .{ .data = "sixth" },
        } },
    });

    {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        var base_buffer: [64]u8 = undefined;
        var url_buffer: [96]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/abort", .{server.baseUrl(&base_buffer)});
        const uri = try std.Uri.parse(url);

        var request = try client.request(.POST, uri, .{});
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = 2 };
        var request_body = try request.sendBody(&.{});
        try request_body.writer.writeAll("{}");
        try request_body.end();

        var redirect_buffer: [256]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        var transfer_buffer: [512]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        while (true) {
            const line = (try response_reader.takeDelimiter('\n')) orelse return error.UnexpectedEndOfStream;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (!std.mem.startsWith(u8, trimmed, "data: ")) continue;
            try std.testing.expectEqualStrings("first", trimmed["data: ".len..]);
            break;
        }
    }

    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"recovered\":true}" },
    });

    {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        var base_buffer: [64]u8 = undefined;
        var url_buffer: [96]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/after-abort", .{server.baseUrl(&base_buffer)});
        const uri = try std.Uri.parse(url);

        var request = try client.request(.POST, uri, .{});
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = 2 };
        var request_body = try request.sendBody(&.{});
        try request_body.writer.writeAll("{}");
        try request_body.end();

        var redirect_buffer: [256]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        try std.testing.expectEqual(.ok, response.head.status);
        try std.testing.expectEqualStrings("application/json", response.head.content_type.?);

        var transfer_buffer: [512]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);
        var body_buffer: [128]u8 = undefined;
        var body_writer: Io.Writer = .fixed(&body_buffer);
        _ = try response_reader.streamRemaining(&body_writer);
        try std.testing.expectEqualStrings("{\"recovered\":true}", body_writer.buffered());
    }

    const recorded = server.recordedRequests();
    try std.testing.expectEqual(2, recorded.len);
    try std.testing.expectEqualStrings("/v1/abort", recorded[0].target);
    try std.testing.expectEqualStrings("/v1/after-abort", recorded[1].target);

    try std.testing.expect(server.serveErrorCount() >= 1);
    const errors = server.takeServeErrors().?;
    try std.testing.expect(errors.count >= 1);
    try std.testing.expectEqual(error.WriteFailed, errors.last);
    try std.testing.expectEqual(0, server.serveErrorCount());
}
