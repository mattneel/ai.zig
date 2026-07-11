const std = @import("std");
const client_api = @import("client.zig");
const json_rpc = @import("json_rpc.zig");
const transport_api = @import("transport.zig");

const ScriptTransport = struct {
    callbacks: transport_api.Callbacks = .{},
    protocol_version: ?[]const u8 = null,
    tool_call_attempts: usize = 0,
    transient_failures: usize = 0,
    saw_ping_response: bool = false,
    saw_missing_elicitation_error: bool = false,
    saw_elicitation_accept: bool = false,
    closed: bool = false,

    fn transport(self: *ScriptTransport) transport_api.MCPTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn start(_: *anyopaque, _: std.Io) anyerror!void {}

    fn send(raw: *anyopaque, _: std.Io, message: json_rpc.Message) anyerror!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(raw));
        switch (message) {
            .notification => return,
            .response => |response| {
                if (response.id.asInteger() == 90) self.saw_ping_response = true;
                if (response.id.asInteger() == 92 and response.result == .object) {
                    const action = response.result.object.get("action");
                    self.saw_elicitation_accept = action != null and action.? == .string and
                        std.mem.eql(u8, action.?.string, "accept");
                }
                return;
            },
            .error_response => |response| {
                if (response.id.asInteger() == 91 and response.error_object.code == -32601) {
                    self.saw_missing_elicitation_error = true;
                }
                return;
            },
            .request => |request| {
                if (std.mem.eql(u8, request.method, "tools/call")) {
                    self.tool_call_attempts += 1;
                    if (self.transient_failures != 0) {
                        self.transient_failures -= 1;
                        return error.RetryableTransportError;
                    }
                    if (request.params) |params| {
                        if (params == .object) {
                            const name = params.object.get("name");
                            if (name != null and name.? == .string and std.mem.eql(u8, name.?.string, "bad")) {
                                var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
                                defer arena_state.deinit();
                                const arena = arena_state.allocator();
                                var data: std.json.ObjectMap = .empty;
                                try data.put(arena, "field", .{ .string = "value" });
                                self.callbacks.message(.{ .error_response = .{
                                    .id = request.id,
                                    .error_object = .{ .code = -32602, .message = "invalid arguments", .data = .{ .object = data } },
                                } });
                                return;
                            }
                        }
                    }
                }
                return self.respond(request);
            },
        }
    }

    fn respond(self: *ScriptTransport, request: json_rpc.Request) anyerror!void {
        const literal = if (std.mem.eql(u8, request.method, "initialize"))
            "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{},\"resources\":{},\"prompts\":{},\"completions\":{}},\"serverInfo\":{\"name\":\"script\",\"version\":\"1\"}}"
        else if (std.mem.eql(u8, request.method, "tools/list")) blk: {
            const cursor = if (request.params) |params|
                if (params == .object) params.object.get("cursor") else null
            else
                null;
            break :blk if (cursor == null)
                "{\"tools\":[{\"name\":\"first\",\"inputSchema\":{\"type\":\"object\"}}],\"nextCursor\":\"page-2\"}"
            else
                "{\"tools\":[{\"name\":\"second\",\"inputSchema\":{\"type\":\"object\"}}]}";
        } else if (std.mem.eql(u8, request.method, "tools/call"))
            "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"structuredContent\":{\"ok\":true}}"
        else if (std.mem.eql(u8, request.method, "resources/list"))
            "{\"resources\":[{\"uri\":\"file:///one\",\"name\":\"one\"}]}"
        else if (std.mem.eql(u8, request.method, "resources/read"))
            "{\"contents\":[{\"uri\":\"file:///one\",\"text\":\"body\"}]}"
        else if (std.mem.eql(u8, request.method, "resources/templates/list"))
            "{\"resourceTemplates\":[{\"uriTemplate\":\"file:///{name}\",\"name\":\"file\"}]}"
        else if (std.mem.eql(u8, request.method, "prompts/list"))
            "{\"prompts\":[{\"name\":\"hello\"}]}"
        else if (std.mem.eql(u8, request.method, "prompts/get"))
            "{\"description\":\"hello\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}]}"
        else if (std.mem.eql(u8, request.method, "completion/complete"))
            "{\"completion\":{\"values\":[\"alpha\",\"beta\"],\"total\":2,\"hasMore\":false}}"
        else
            return error.UnsupportedMethod;

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), literal, .{});
        self.callbacks.message(.{ .response = .{ .id = request.id, .result = value } });
    }

    fn close(raw: *anyopaque, _: std.Io) anyerror!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(raw));
        self.closed = true;
        self.callbacks.closed();
    }

    fn setCallbacks(raw: *anyopaque, callbacks: transport_api.Callbacks) void {
        const self: *ScriptTransport = @ptrCast(@alignCast(raw));
        self.callbacks = callbacks;
    }

    fn getVersion(raw: *anyopaque) ?[]const u8 {
        const self: *ScriptTransport = @ptrCast(@alignCast(raw));
        return self.protocol_version;
    }

    fn setVersion(raw: *anyopaque, version: []const u8) anyerror!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(raw));
        self.protocol_version = version;
    }

    fn emitRequest(self: *ScriptTransport, request: json_rpc.Request) void {
        self.callbacks.message(.{ .request = request });
    }

    const vtable: transport_api.VTable = .{
        .start = start,
        .send = send,
        .close = close,
        .set_callbacks = setCallbacks,
        .get_protocol_version = getVersion,
        .set_protocol_version = setVersion,
    };
};

test "client paginates tools and exposes resources prompts and completions" {
    const io = std.testing.io;
    var scripted: ScriptTransport = .{};
    const client = try client_api.createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .ready = scripted.transport() },
    });
    defer client.deinit(io);
    try std.testing.expectEqualStrings("2025-11-25", scripted.protocol_version.?);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = try client.listTools(io, arena, null);
    try std.testing.expectEqual(2, tools.tools.len);
    try std.testing.expectEqualStrings("first", tools.tools[0].name);
    try std.testing.expectEqualStrings("second", tools.tools[1].name);
    try std.testing.expectEqual(1, (try client.listResources(io, arena, null)).resources.len);
    try std.testing.expectEqualStrings("body", (try client.readResource(io, arena, "file:///one")).contents[0].text.?);
    try std.testing.expectEqual(1, (try client.listResourceTemplates(io, arena)).resourceTemplates.len);
    try std.testing.expectEqual(1, (try client.listPrompts(io, arena, null)).prompts.len);
    try std.testing.expectEqualStrings("hello", (try client.getPrompt(io, arena, "hello", null)).description.?);
    const complete_params = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    try std.testing.expectEqual(2, (try client.complete(io, arena, complete_params)).completion.values.len);
}

test "client retries only transient tool transport errors and retains JSON-RPC error data" {
    const io = std.testing.io;
    var scripted: ScriptTransport = .{ .transient_failures = 2 };
    const client = try client_api.createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .ready = scripted.transport() },
        .max_retries = 2,
    });
    defer client.deinit(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try client.callTool(io, arena, "ok", null);
    try std.testing.expectEqual(3, scripted.tool_call_attempts);
    try std.testing.expect(result.structuredContent().?.object.get("ok").?.bool);

    try std.testing.expectError(error.JSONRPCError, client.callTool(io, arena, "bad", null));
    try std.testing.expectEqual(4, scripted.tool_call_attempts);
    const detail = client.lastError().?;
    try std.testing.expectEqual(-32602, detail.code.?);
    try std.testing.expectEqualStrings("invalid arguments", detail.message);
    try std.testing.expectEqualStrings("value", detail.data.?.object.get("field").?.string);
}

test "client answers ping and routes elicitation requests" {
    const io = std.testing.io;
    var scripted: ScriptTransport = .{};
    const client = try client_api.createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .ready = scripted.transport() },
    });
    defer client.deinit(io);

    scripted.emitRequest(.{ .id = .{ .integer = 90 }, .method = "ping" });
    try std.testing.expect(scripted.saw_ping_response);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var params: std.json.ObjectMap = .empty;
    try params.put(arena, "message", .{ .string = "Proceed?" });
    try params.put(arena, "requestedSchema", .{ .object = .empty });
    scripted.emitRequest(.{ .id = .{ .integer = 91 }, .method = "elicitation/create", .params = .{ .object = params } });
    try std.testing.expect(scripted.saw_missing_elicitation_error);

    const Handler = struct {
        fn handle(_: ?*anyopaque, _: std.Io, result_arena: std.mem.Allocator, _: std.json.Value) anyerror!std.json.Value {
            var result: std.json.ObjectMap = .empty;
            try result.put(result_arena, "action", .{ .string = "accept" });
            return .{ .object = result };
        }
    };
    client.onElicitationRequest(.{ .handle_fn = Handler.handle });
    scripted.emitRequest(.{ .id = .{ .integer = 92 }, .method = "elicitation/create", .params = .{ .object = params } });
    try std.testing.expect(scripted.saw_elicitation_accept);
}
