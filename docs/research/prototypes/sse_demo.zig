//! Worked example: POST JSON, stream an SSE response, parse JSON events.
//! Validates the full Zig 0.16 std.http + std.json streaming path end-to-end.
const std = @import("std");
const http = std.http;
const Io = std.Io;

const RequestBody = struct {
    model: []const u8,
    stream: bool,
    messages: []const struct { role: []const u8, content: []const u8 },
};

const Chunk = struct {
    delta: struct { content: []const u8 = "" } = .{},
    done: bool = false,
};

fn runServer(io: Io, server: *Io.net.Server) !void {
    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var stream = try server.accept(io);
    defer stream.close(io);
    var br = stream.reader(io, &recv_buffer);
    var bw = stream.writer(io, &send_buffer);
    var s = http.Server.init(&br.interface, &bw.interface);

    var request = try s.receiveHead();

    // read the JSON request body
    var body_buf: [1024]u8 = undefined;
    const req_reader = try request.readerExpectContinue(&body_buf);
    var body_alloc: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&body_alloc);
    _ = try req_reader.streamRemaining(&w);
    std.debug.print("server got body: {s}\n", .{w.buffered()});

    // stream SSE response, chunked
    var response = try request.respondStreaming(&.{}, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
            },
        },
    });
    const out = &response.writer;
    const events = [_][]const u8{
        "data: {\"delta\":{\"content\":\"Hel\"}}\n\n",
        "data: {\"delta\":{\"content\":\"lo!\"}}\n\n",
        "data: {\"done\":true}\n\n",
        "data: [DONE]\n\n",
    };
    for (events) |e| {
        try out.writeAll(e);
        try response.flush(); // each event is its own chunk on the wire
        try io.sleep(.fromMilliseconds(300), .awake);
    }
    try response.end();
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // local test server
    const addr: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    // Server on its own OS thread (same pattern as stdlib http tests).
    const server_thread = try std.Thread.spawn(.{}, runServer, .{ io, &server });
    defer server_thread.join();

    // ---- CLIENT: the part that matters for ai.zig ----
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat", .{port});
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    // serialize request body with std.json.Stringify
    const payload = try std.json.Stringify.valueAlloc(gpa, RequestBody{
        .model = "gpt-x",
        .stream = true,
        .messages = &.{.{ .role = "user", .content = "hi" }},
    }, .{});
    defer gpa.free(payload);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = "Bearer sk-test" },
            .{ .name = "accept", .value = "text/event-stream" },
        },
    });
    defer req.deinit();

    // known-length body:
    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try req.sendBody(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    std.debug.print("status={d} content-type={s}\n", .{
        @intFromEnum(response.head.status),
        response.head.content_type orelse "?",
    });

    // stream the body: transfer_buffer is the Reader's buffer; SSE lines must fit in it.
    var transfer_buffer: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer); // *Io.Reader; de-chunks transparently

    const start_ms = Io.Clock.awake.now(io).toMilliseconds();
    // Minimal SSE parse loop over Io.Reader line primitives.
    // takeDelimiter advances PAST the '\n' and returns null at end of stream.
    while (true) {
        const line = (body_reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.SseLineTooLong,
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        }) orelse break;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue; // event boundary
        if (std.mem.startsWith(u8, trimmed, "data: ")) {
            const data = trimmed["data: ".len..];
            if (std.mem.eql(u8, data, "[DONE]")) break;
            const parsed = try std.json.parseFromSlice(Chunk, gpa, data, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            std.debug.print("[t={d}ms] event: content={s} done={}\n", .{
                Io.Clock.awake.now(io).toMilliseconds() - start_ms,
                parsed.value.delta.content,
                parsed.value.done,
            });
        }
    }
    std.debug.print("stream complete\n", .{});
}
