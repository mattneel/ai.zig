const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const test_support = @import("test_support");

const api = provider_utils.api;
const retry_api = provider_utils.retry_api;

fn makeUrl(arena: std.mem.Allocator, server: *test_support.MockServer, path: []const u8) ![]const u8 {
    var base_buffer: [64]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ server.baseUrl(&base_buffer), path });
}

fn recordedHeader(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and
            std.mem.indexOf(u8, header.value, "ai-sdk-zig") != null)
        {
            return header.value;
        }
    }
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

const ErrorShape = struct {
    @"error": struct { message: []const u8 },
};

fn errorMessage(value: ErrorShape) []const u8 {
    return value.@"error".message;
}

test "integration postJsonToApi 200 JSON records combined headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"ok\":true,\"ignored\":1}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try makeUrl(arena, server, "/v1/json");
    const Shape = struct { ok: bool };
    const result = try api.postJsonToApi(
        Shape,
        io,
        arena,
        client.transport(),
        .{
            .url = url,
            .headers = &.{.{ .name = "x-test", .value = "present" }},
            .body_json = "{\"prompt\":\"hello\"}",
        },
        .{
            .success = api.jsonResponseHandler(Shape),
            .failure = api.statusCodeErrorResponseHandler(),
        },
        null,
    );
    try std.testing.expect(result.value.ok);
    try std.testing.expectEqualStrings("{\"ok\":true,\"ignored\":1}", result.raw_body.?);
    try std.testing.expectEqualStrings(
        "application/json",
        provider_utils.getHeader(result.response_headers, "content-type").?,
    );

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqual(.POST, requests[0].method);
    try std.testing.expectEqualStrings("{\"prompt\":\"hello\"}", requests[0].body);
    try std.testing.expectEqualStrings(
        "application/json",
        recordedHeader(requests[0].headers, "content-type").?,
    );
    const user_agent = recordedHeader(requests[0].headers, "user-agent").?;
    try std.testing.expect(std.mem.indexOf(
        u8,
        user_agent,
        "ai-sdk-zig/provider-utils/0.0.0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, user_agent, "runtime/zig/0.16.0") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration postJsonToApi 429 JSON error populates retryable diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .status = .too_many_requests,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"rate limited\"}}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try makeUrl(arena, server, "/v1/rate-limit");
    const Shape = struct { ok: bool };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.APICallError, api.postJsonToApi(
        Shape,
        io,
        arena,
        client.transport(),
        .{ .url = url, .body_json = "{}" },
        .{
            .success = api.jsonResponseHandler(Shape),
            .failure = api.jsonErrorResponseHandler(ErrorShape, errorMessage),
        },
        &diagnostics,
    ));
    const payload = diagnostics.payload.api_call;
    try std.testing.expectEqual(429, payload.status_code.?);
    try std.testing.expect(payload.is_retryable);
    try std.testing.expectEqualStrings("rate limited", payload.message);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"message\":\"rate limited\"}}",
        payload.data_json.?,
    );
}

test "integration eventSourceResponseHandler streams parse results and stops at DONE" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"index\":1}" },
            .{ .data = "malformed" },
            .{ .data = "{\"index\":2}" },
            .{ .data = "[DONE]" },
            .{ .data = "{\"index\":3}" },
        } },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var request_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer request_arena_state.deinit();
    const request_arena = request_arena_state.allocator();
    const url = try makeUrl(request_arena, server, "/v1/stream");
    const Chunk = struct { index: u32 };
    const Stream = provider_utils.JsonEventStream(Chunk);
    const result = try api.postJsonToApi(
        Stream,
        io,
        request_arena,
        client.transport(),
        .{ .url = url, .body_json = "{}" },
        .{
            .success = api.eventSourceResponseHandler(Chunk),
            .failure = api.statusCodeErrorResponseHandler(),
        },
        null,
    );
    var stream = result.value;
    defer stream.deinit();
    var event_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer event_arena_state.deinit();
    const event_arena = event_arena_state.allocator();

    switch ((try stream.next(event_arena)).?) {
        .success => |success| try std.testing.expectEqual(1, success.value.index),
        .failure => return error.UnexpectedParseFailure,
    }
    switch ((try stream.next(event_arena)).?) {
        .failure => |failure| try std.testing.expectEqualStrings("malformed", failure.raw),
        .success => return error.UnexpectedParseSuccess,
    }
    switch ((try stream.next(event_arena)).?) {
        .success => |success| try std.testing.expectEqual(2, success.value.index),
        .failure => return error.UnexpectedParseFailure,
    }
    try std.testing.expectEqual(null, try stream.next(event_arena));
    try std.testing.expectEqual(null, try stream.next(event_arena));
}

test "integration retry uses two 500 responses then succeeds and leaves first 400 raw" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .status = .internal_server_error,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"first\"}}" },
    });
    try server.enqueue(.{
        .status = .internal_server_error,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"second\"}}" },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"ok\":true}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Shape = struct { ok: bool };
    const Context = struct {
        arena: std.mem.Allocator,
        transport: provider_utils.HttpTransport,
        url: []const u8,

        fn op(
            self: *@This(),
            task_io: std.Io,
            _: u32,
            diag: ?*provider.Diagnostics,
        ) anyerror!Shape {
            const result = try api.postJsonToApi(
                Shape,
                task_io,
                self.arena,
                self.transport,
                .{ .url = self.url, .body_json = "{}" },
                .{
                    .success = api.jsonResponseHandler(Shape),
                    .failure = api.jsonErrorResponseHandler(ErrorShape, errorMessage),
                },
                diag,
            );
            return result.value;
        }
    };
    var context: Context = .{
        .arena = arena,
        .transport = client.transport(),
        .url = try makeUrl(arena, server, "/v1/retry"),
    };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const value = try retry_api.retry(
        Shape,
        io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    );
    try std.testing.expect(value.ok);
    try std.testing.expectEqual(3, server.recordedRequests().len);

    try server.enqueue(.{
        .status = .bad_request,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"bad\"}}" },
    });
    context.url = try makeUrl(arena, server, "/v1/no-retry");
    const before = server.recordedRequests().len;
    try std.testing.expectError(error.APICallError, retry_api.retry(
        Shape,
        io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(before + 1, server.recordedRequests().len);
    try std.testing.expect(diagnostics.payload == .api_call);
    try std.testing.expect(!diagnostics.payload.api_call.is_retryable);
}

const RewriteTransport = struct {
    inner: provider_utils.HttpTransport,
    target_url: []const u8,

    fn transport(self: *RewriteTransport) provider_utils.HttpTransport {
        return .{ .ctx = self, .vtable = &.{ .request = request } };
    }

    fn request(
        raw: *anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        spec: provider_utils.RequestSpec,
        diag: ?*provider.Diagnostics,
    ) provider_utils.http_transport.RequestError!provider_utils.Response {
        const self: *RewriteTransport = @ptrCast(@alignCast(raw));
        var rewritten = spec;
        rewritten.url = self.target_url;
        return self.inner.request(io, arena, rewritten, diag);
    }
};

test "integration download decodes data URLs and rejects oversized canned body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/octet-stream",
        .body = .{ .text = "0123456789" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inline_result = try provider_utils.download(
        io,
        arena,
        client.transport(),
        "data:text/plain;base64,aGVsbG8=",
        .{},
        null,
    );
    try std.testing.expectEqualStrings("hello", inline_result.data);
    try std.testing.expectEqualStrings("text/plain", inline_result.media_type.?);

    var rewrite: RewriteTransport = .{
        .inner = client.transport(),
        .target_url = try makeUrl(arena, server, "/oversized"),
    };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.DownloadError, provider_utils.download(
        io,
        arena,
        rewrite.transport(),
        "https://example.com/oversized",
        .{ .max_size = 5 },
        &diagnostics,
    ));
    try std.testing.expect(diagnostics.payload == .download);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.payload.download.message,
        "exceeded maximum size",
    ) != null);
}
