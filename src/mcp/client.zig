//! MCP client handshake, request correlation, capabilities, and public APIs.

const std = @import("std");
const provider_utils = @import("provider_utils");
const http_transport = @import("http_transport.zig");
const json_rpc = @import("json_rpc.zig");
const sse_transport = @import("sse_transport.zig");
const stdio_transport = @import("stdio_transport.zig");
const transport_api = @import("transport.zig");
const types = @import("types.zig");
const tools_api = @import("tools.zig");

const Allocator = std.mem.Allocator;

pub const Transport = union(enum) {
    ready: transport_api.MCPTransport,
    stdio: stdio_transport.Config,
    sse: sse_transport.Config,
    http: http_transport.Config,
};

pub const ErrorCallback = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (ctx: ?*anyopaque, info: transport_api.ErrorInfo) void,
};

pub const Options = struct {
    transport: Transport,
    on_uncaught_error: ?ErrorCallback = null,
    max_retries: u32 = 0,
    client_name: []const u8 = "ai-sdk-zig-mcp-client",
    version: []const u8 = "1.0.0",
    capabilities: ?std.json.Value = null,
};

pub const ElicitationHandler = struct {
    ctx: ?*anyopaque = null,
    handle_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        params: std.json.Value,
    ) anyerror!std.json.Value,
};

pub const ErrorDetail = struct {
    code: ?i64 = null,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    transport_value: transport_api.MCPTransport,
    owned_transport: OwnedTransport,
    on_uncaught_error: ?ErrorCallback,
    max_retries: u32,
    client_name: []const u8,
    client_version: []const u8,
    advertised_capabilities: ?std.json.Value,
    state_arena: std.heap.ArenaAllocator,
    initialize_result_value: types.InitializeResult = undefined,
    request_id: std.atomic.Value(i64) = .init(0),
    pending_mutex: std.Io.Mutex = .init,
    pending: std.AutoHashMapUnmanaged(i64, *Pending) = .empty,
    closed: std.atomic.Value(bool) = .init(true),
    elicitation_handler: ?ElicitationHandler = null,
    error_store: ErrorStore,

    const OwnedTransport = union(enum) {
        none,
        stdio: *stdio_transport.StdioTransport,
        sse: *sse_transport.SseTransport,
        http: *http_transport.HttpTransport,
    };

    const Completion = union(enum) {
        response: std.json.Value,
        rpc_error: struct {
            code: i64,
            message: []const u8,
            data: ?std.json.Value,
        },
        connection_closed,
    };

    const Pending = struct {
        arena: std.heap.ArenaAllocator,
        cell: provider_utils.OneShot(Completion) = .{},

        fn create(gpa: Allocator) Allocator.Error!*Pending {
            const self = try gpa.create(Pending);
            self.* = .{ .arena = .init(gpa) };
            return self;
        }

        fn destroy(self: *Pending, gpa: Allocator) void {
            self.arena.deinit();
            gpa.destroy(self);
        }
    };

    const ErrorStore = struct {
        mutex: std.atomic.Mutex = .unlocked,
        arena: std.heap.ArenaAllocator,
        detail: ?ErrorDetail = null,

        fn init(gpa: Allocator) ErrorStore {
            return .{ .arena = .init(gpa) };
        }

        fn deinit(self: *ErrorStore) void {
            self.arena.deinit();
            self.* = undefined;
        }

        fn set(self: *ErrorStore, code: ?i64, message: []const u8, data: ?std.json.Value) void {
            lockAtomic(&self.mutex);
            defer self.mutex.unlock();
            _ = self.arena.reset(.free_all);
            const arena = self.arena.allocator();
            self.detail = .{
                .code = code,
                .message = arena.dupe(u8, message) catch "MCP error",
                .data = if (data) |value| provider_utils.cloneJsonValue(arena, value) catch null else null,
            };
        }

        fn get(self: *ErrorStore) ?ErrorDetail {
            lockAtomic(&self.mutex);
            defer self.mutex.unlock();
            return self.detail;
        }
    };

    pub fn deinit(self: *Client, io: std.Io) void {
        self.close(io) catch {};
        self.pending.deinit(self.gpa);
        self.releaseOwnedTransport();
        self.error_store.deinit();
        self.state_arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn close(self: *Client, io: std.Io) anyerror!void {
        if (self.closed.load(.acquire)) return;
        self.transport_value.close(io) catch |err| {
            self.onClose();
            return err;
        };
        self.onClose();
    }

    pub fn initializeResult(self: *const Client) types.InitializeResult {
        return self.initialize_result_value;
    }

    pub fn serverInfo(self: *const Client) types.Implementation {
        return self.initialize_result_value.serverInfo;
    }

    pub fn instructions(self: *const Client) ?[]const u8 {
        return self.initialize_result_value.instructions;
    }

    pub fn lastError(self: *Client) ?ErrorDetail {
        return self.error_store.get();
    }

    pub fn onElicitationRequest(self: *Client, handler: ElicitationHandler) void {
        self.elicitation_handler = handler;
    }

    /// Fetches every tools/list page, preserving server order.
    pub fn listTools(self: *Client, io: std.Io, arena: Allocator, initial_cursor: ?[]const u8) anyerror!types.ListToolsResult {
        var all: std.ArrayList(types.Tool) = .empty;
        var cursor = initial_cursor;
        while (true) {
            var request_arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer request_arena_state.deinit();
            const request_arena = request_arena_state.allocator();
            const params = if (cursor) |value| try objectValue(request_arena, &.{.{ "cursor", .{ .string = value } }}) else null;
            const result_value = try self.requestValue(io, arena, "tools/list", params, true);
            const page = try types.parseListToolsResult(arena, result_value);
            try all.appendSlice(arena, page.tools);
            cursor = page.nextCursor;
            if (cursor == null) return .{ .tools = try all.toOwnedSlice(arena), .nextCursor = null };
        }
    }

    pub fn callTool(
        self: *Client,
        io: std.Io,
        arena: Allocator,
        name: []const u8,
        arguments: ?std.json.Value,
    ) anyerror!types.CallToolResult {
        if (arguments) |value| if (value != .object) return error.InvalidParams;
        const Context = struct {
            client: *Client,
            arena: Allocator,
            name: []const u8,
            arguments: ?std.json.Value,

            fn run(context: *@This(), task_io: std.Io, _: u32, _: ?*@import("provider").Diagnostics) anyerror!std.json.Value {
                var request_arena_state = std.heap.ArenaAllocator.init(context.client.gpa);
                defer request_arena_state.deinit();
                const request_arena = request_arena_state.allocator();
                var params_object: std.json.ObjectMap = .empty;
                try params_object.put(request_arena, "name", .{ .string = context.name });
                try params_object.put(
                    request_arena,
                    "arguments",
                    if (context.arguments) |value| try provider_utils.cloneJsonValue(request_arena, value) else .{ .object = .empty },
                );
                return context.client.requestValue(
                    task_io,
                    context.arena,
                    "tools/call",
                    .{ .object = params_object },
                    true,
                );
            }
        };
        var context: Context = .{ .client = self, .arena = arena, .name = name, .arguments = arguments };
        const value = if (self.max_retries == 0)
            try Context.run(&context, io, 0, null)
        else
            try provider_utils.retryWithOptions(
                std.json.Value,
                io,
                .{
                    .policy = .{ .max_retries = self.max_retries, .initial_delay_ms = 200 },
                    .should_retry = shouldRetryToolCall,
                },
                &context,
                Context.run,
                null,
            );
        return types.parseCallToolResult(arena, value);
    }

    pub fn tools(self: *Client, io: std.Io, arena: Allocator, options: tools_api.Options) anyerror![]const @import("ai").NamedTool {
        const definitions = try self.listTools(io, arena, null);
        return self.toolsFromDefinitions(arena, definitions, options);
    }

    pub fn toolsFromDefinitions(
        self: *Client,
        arena: Allocator,
        definitions: types.ListToolsResult,
        options: tools_api.Options,
    ) anyerror![]const @import("ai").NamedTool {
        var resolved = options;
        if (std.mem.eql(u8, resolved.client_name, "ai-sdk-zig-mcp-client")) {
            resolved.client_name = self.client_name;
        }
        return tools_api.fromDefinitions(.{ .ctx = self, .call_fn = callForTool }, arena, definitions, resolved);
    }

    pub fn listResources(self: *Client, io: std.Io, arena: Allocator, cursor: ?[]const u8) anyerror!types.ListResourcesResult {
        var request_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer request_arena_state.deinit();
        const params = if (cursor) |value| try objectValue(request_arena_state.allocator(), &.{.{ "cursor", .{ .string = value } }}) else null;
        return types.parseListResourcesResult(arena, try self.requestValue(io, arena, "resources/list", params, true));
    }

    pub fn readResource(self: *Client, io: std.Io, arena: Allocator, uri: []const u8) anyerror!types.ReadResourceResult {
        var request_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer request_arena_state.deinit();
        const params = try objectValue(request_arena_state.allocator(), &.{.{ "uri", .{ .string = uri } }});
        return types.parseReadResourceResult(arena, try self.requestValue(io, arena, "resources/read", params, true));
    }

    pub fn listResourceTemplates(self: *Client, io: std.Io, arena: Allocator) anyerror!types.ListResourceTemplatesResult {
        return types.parseListResourceTemplatesResult(
            arena,
            try self.requestValue(io, arena, "resources/templates/list", null, true),
        );
    }

    pub fn listPrompts(self: *Client, io: std.Io, arena: Allocator, cursor: ?[]const u8) anyerror!types.ListPromptsResult {
        var request_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer request_arena_state.deinit();
        const params = if (cursor) |value| try objectValue(request_arena_state.allocator(), &.{.{ "cursor", .{ .string = value } }}) else null;
        return types.parseListPromptsResult(arena, try self.requestValue(io, arena, "prompts/list", params, true));
    }

    pub fn getPrompt(
        self: *Client,
        io: std.Io,
        arena: Allocator,
        name: []const u8,
        arguments: ?std.json.Value,
    ) anyerror!types.GetPromptResult {
        if (arguments) |value| if (value != .object) return error.InvalidParams;
        var request_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer request_arena_state.deinit();
        const request_arena = request_arena_state.allocator();
        var params: std.json.ObjectMap = .empty;
        try params.put(request_arena, "name", .{ .string = name });
        if (arguments) |value| try params.put(request_arena, "arguments", try provider_utils.cloneJsonValue(request_arena, value));
        return types.parseGetPromptResult(arena, try self.requestValue(io, arena, "prompts/get", .{ .object = params }, true));
    }

    pub fn complete(self: *Client, io: std.Io, arena: Allocator, params: std.json.Value) anyerror!types.CompleteResult {
        if (params != .object) return error.InvalidParams;
        return types.parseCompleteResult(arena, try self.requestValue(io, arena, "completion/complete", params, true));
    }

    pub fn requestRaw(
        self: *Client,
        io: std.Io,
        arena: Allocator,
        method: []const u8,
        params: ?std.json.Value,
    ) anyerror!std.json.Value {
        return self.requestValue(io, arena, method, params, true);
    }

    fn requestValue(
        self: *Client,
        io: std.Io,
        arena: Allocator,
        method: []const u8,
        params: ?std.json.Value,
        check_capability: bool,
    ) anyerror!std.json.Value {
        if (self.closed.load(.acquire)) return error.ConnectionClosed;
        if (params) |value| if (value != .object) return error.InvalidParams;
        if (check_capability) try self.assertCapability(method);

        const id = self.request_id.fetchAdd(1, .monotonic);
        const pending = try Pending.create(self.gpa);
        var inserted = false;
        defer if (!inserted) pending.destroy(self.gpa);

        try self.pending_mutex.lock(io);
        self.pending.put(self.gpa, id, pending) catch |err| {
            self.pending_mutex.unlock(io);
            return err;
        };
        self.pending_mutex.unlock(io);
        inserted = true;

        self.transport_value.send(io, .{ .request = .{
            .id = .{ .integer = id },
            .method = method,
            .params = params,
        } }) catch |err| {
            self.removePending(io, id, pending);
            pending.destroy(self.gpa);
            return err;
        };

        const completion = pending.cell.wait(io) catch |err| {
            self.pending_mutex.lockUncancelable(io);
            const removed = self.pending.fetchRemove(id);
            self.pending_mutex.unlock(io);
            if (removed == null) pending.cell.event.waitUncancelable(io);
            pending.destroy(self.gpa);
            return err;
        };
        defer pending.destroy(self.gpa);
        return switch (completion) {
            .response => |value| provider_utils.cloneJsonValue(arena, value),
            .rpc_error => |rpc_error| {
                self.error_store.set(rpc_error.code, rpc_error.message, rpc_error.data);
                return error.JSONRPCError;
            },
            .connection_closed => error.ConnectionClosed,
        };
    }

    fn removePending(self: *Client, io: std.Io, id: i64, expected: *Pending) void {
        self.pending_mutex.lockUncancelable(io);
        const removed = self.pending.fetchRemove(id);
        self.pending_mutex.unlock(io);
        if (removed) |entry| std.debug.assert(entry.value == expected);
    }

    fn notification(self: *Client, io: std.Io, method: []const u8, params: ?std.json.Value) anyerror!void {
        if (self.closed.load(.acquire)) return error.ConnectionClosed;
        if (params) |value| if (value != .object) return error.InvalidParams;
        return self.transport_value.send(io, .{ .notification = .{ .method = method, .params = params } });
    }

    fn assertCapability(self: *const Client, method: []const u8) anyerror!void {
        if (std.mem.eql(u8, method, "initialize")) return;
        const capabilities = self.initialize_result_value.capabilities;
        if (std.mem.eql(u8, method, "tools/list") or std.mem.eql(u8, method, "tools/call")) {
            if (capabilities.tools == null) return error.UnsupportedCapability;
            return;
        }
        if (std.mem.eql(u8, method, "resources/list") or
            std.mem.eql(u8, method, "resources/read") or
            std.mem.eql(u8, method, "resources/templates/list"))
        {
            if (capabilities.resources == null) return error.UnsupportedCapability;
            return;
        }
        if (std.mem.eql(u8, method, "prompts/list") or std.mem.eql(u8, method, "prompts/get")) {
            if (capabilities.prompts == null) return error.UnsupportedCapability;
            return;
        }
        if (std.mem.eql(u8, method, "completion/complete")) {
            if (capabilities.completions == null) return error.UnsupportedCapability;
            return;
        }
        return error.UnsupportedMethod;
    }

    fn onTransportMessage(raw: ?*anyopaque, message: json_rpc.Message) void {
        const self: *Client = @ptrCast(@alignCast(raw.?));
        switch (message) {
            .request => |request| self.handleServerRequest(request),
            .notification => self.reportUncaught(.{ .err = error.UnsupportedMessage, .message = "server notifications are not supported" }),
            .response => |response| self.resolveResponse(response.id, .{ .response = response.result }),
            .error_response => |response| self.resolveRpcError(response),
        }
    }

    fn onTransportError(raw: ?*anyopaque, info: transport_api.ErrorInfo) void {
        const self: *Client = @ptrCast(@alignCast(raw.?));
        self.reportUncaught(info);
    }

    fn onTransportClose(raw: ?*anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(raw.?));
        self.onClose();
    }

    fn resolveResponse(self: *Client, id: json_rpc.Id, completion: Completion) void {
        const integer_id = responseRequestId(id) orelse {
            self.reportUncaught(.{ .err = error.UnknownResponseId, .message = "MCP response used an invalid id" });
            return;
        };
        self.pending_mutex.lockUncancelable(self.io);
        const entry = self.pending.fetchRemove(integer_id);
        if (entry == null) {
            self.pending_mutex.unlock(self.io);
            self.reportUncaught(.{ .err = error.UnknownResponseId, .message = "MCP response used an unknown id" });
            return;
        }
        const pending = entry.?.value;
        const owned = switch (completion) {
            .response => |value| Completion{ .response = provider_utils.cloneJsonValue(pending.arena.allocator(), value) catch {
                self.pending_mutex.unlock(self.io);
                pending.cell.resolve(self.io, .connection_closed);
                return;
            } },
            else => completion,
        };
        pending.cell.resolve(self.io, owned);
        self.pending_mutex.unlock(self.io);
    }

    fn resolveRpcError(self: *Client, response: json_rpc.ErrorResponse) void {
        const integer_id = responseRequestId(response.id) orelse {
            self.reportUncaught(.{ .err = error.UnknownResponseId, .message = "MCP error response used an invalid id" });
            return;
        };
        self.pending_mutex.lockUncancelable(self.io);
        const entry = self.pending.fetchRemove(integer_id);
        if (entry == null) {
            self.pending_mutex.unlock(self.io);
            self.reportUncaught(.{ .err = error.UnknownResponseId, .message = "MCP error response used an unknown id" });
            return;
        }
        const pending = entry.?.value;
        const arena = pending.arena.allocator();
        const message = arena.dupe(u8, response.error_object.message) catch "MCP JSON-RPC error";
        const data = if (response.error_object.data) |value| provider_utils.cloneJsonValue(arena, value) catch null else null;
        pending.cell.resolve(self.io, .{ .rpc_error = .{
            .code = response.error_object.code,
            .message = message,
            .data = data,
        } });
        self.pending_mutex.unlock(self.io);
    }

    fn handleServerRequest(self: *Client, request: json_rpc.Request) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (std.mem.eql(u8, request.method, "ping")) {
            self.transport_value.send(self.io, .{ .response = .{ .id = request.id, .result = .{ .object = .empty } } }) catch |err| {
                self.reportUncaught(.{ .err = err, .message = "failed to reply to MCP ping" });
            };
            return;
        }
        if (!std.mem.eql(u8, request.method, "elicitation/create")) {
            self.sendServerError(request.id, -32601, "unsupported request method", null);
            return;
        }
        const handler = self.elicitation_handler orelse {
            self.sendServerError(request.id, -32601, "no elicitation handler registered", null);
            return;
        };
        const params = request.params orelse {
            self.sendServerError(request.id, -32602, "invalid elicitation request", null);
            return;
        };
        if (params != .object or params.object.get("message") == null or params.object.get("requestedSchema") == null) {
            self.sendServerError(request.id, -32602, "invalid elicitation request", null);
            return;
        }
        const result = handler.handle_fn(handler.ctx, self.io, arena, params) catch |err| {
            self.sendServerError(request.id, -32603, @errorName(err), null);
            self.reportUncaught(.{ .err = err, .message = "elicitation handler failed" });
            return;
        };
        _ = types.parseElicitResult(arena, result) catch {
            self.sendServerError(request.id, -32603, "invalid elicitation handler result", null);
            return;
        };
        self.transport_value.send(self.io, .{ .response = .{ .id = request.id, .result = result } }) catch |err| {
            self.reportUncaught(.{ .err = err, .message = "failed to send elicitation result" });
        };
    }

    fn sendServerError(self: *Client, id: json_rpc.Id, code: i64, message: []const u8, data: ?std.json.Value) void {
        self.transport_value.send(self.io, .{ .error_response = .{
            .id = id,
            .error_object = .{ .code = code, .message = message, .data = data },
        } }) catch |err| self.reportUncaught(.{ .err = err, .message = "failed to send MCP error response" });
    }

    fn onClose(self: *Client) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.pending_mutex.lockUncancelable(self.io);
        var iterator = self.pending.valueIterator();
        while (iterator.next()) |pending| pending.*.cell.resolve(self.io, .connection_closed);
        self.pending.clearRetainingCapacity();
        self.pending_mutex.unlock(self.io);
    }

    fn reportUncaught(self: *Client, info: transport_api.ErrorInfo) void {
        self.error_store.set(null, if (info.message.len != 0) info.message else @errorName(info.err), null);
        if (self.on_uncaught_error) |callback| callback.callback(callback.ctx, info);
    }

    fn releaseOwnedTransport(self: *Client) void {
        switch (self.owned_transport) {
            .none => {},
            .stdio => |value| {
                value.deinit();
                self.gpa.destroy(value);
            },
            .sse => |value| {
                value.deinit();
                self.gpa.destroy(value);
            },
            .http => |value| {
                value.deinit();
                self.gpa.destroy(value);
            },
        }
        self.owned_transport = .none;
    }

    fn callForTool(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        name: []const u8,
        arguments: std.json.Value,
    ) anyerror!std.json.Value {
        const self: *Client = @ptrCast(@alignCast(raw));
        return (try self.callTool(io, arena, name, arguments)).rawValue();
    }
};

pub fn createMcpClient(gpa: Allocator, io: std.Io, options: Options) anyerror!*Client {
    const self = try gpa.create(Client);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .transport_value = undefined,
        .owned_transport = .none,
        .on_uncaught_error = options.on_uncaught_error,
        .max_retries = options.max_retries,
        .client_name = undefined,
        .client_version = undefined,
        .advertised_capabilities = null,
        .state_arena = .init(gpa),
        .error_store = .init(gpa),
    };
    errdefer {
        self.pending.deinit(gpa);
        self.releaseOwnedTransport();
        self.error_store.deinit();
        self.state_arena.deinit();
        gpa.destroy(self);
    }
    const state = self.state_arena.allocator();
    self.client_name = try state.dupe(u8, options.client_name);
    self.client_version = try state.dupe(u8, options.version);
    self.advertised_capabilities = if (options.capabilities) |value| try provider_utils.cloneJsonValue(state, value) else null;

    switch (options.transport) {
        .ready => |value| self.transport_value = value,
        .stdio => |config| {
            const value = try gpa.create(stdio_transport.StdioTransport);
            errdefer gpa.destroy(value);
            value.* = try stdio_transport.StdioTransport.init(gpa, config);
            self.owned_transport = .{ .stdio = value };
            self.transport_value = value.transport();
        },
        .sse => |config| {
            const value = try gpa.create(sse_transport.SseTransport);
            errdefer gpa.destroy(value);
            value.* = try sse_transport.SseTransport.init(gpa, config);
            self.owned_transport = .{ .sse = value };
            self.transport_value = value.transport();
        },
        .http => |config| {
            const value = try gpa.create(http_transport.HttpTransport);
            errdefer gpa.destroy(value);
            value.* = try http_transport.HttpTransport.init(gpa, config);
            self.owned_transport = .{ .http = value };
            self.transport_value = value.transport();
        },
    }

    self.transport_value.setCallbacks(.{
        .ctx = self,
        .on_message = Client.onTransportMessage,
        .on_error = Client.onTransportError,
        .on_close = Client.onTransportClose,
    });
    self.transport_value.start(io) catch |err| {
        self.transport_value.close(io) catch {};
        return err;
    };
    self.closed.store(false, .release);
    errdefer self.close(io) catch {};

    var init_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer init_arena_state.deinit();
    const init_arena = init_arena_state.allocator();
    var client_info: std.json.ObjectMap = .empty;
    try client_info.put(init_arena, "name", .{ .string = self.client_name });
    try client_info.put(init_arena, "version", .{ .string = self.client_version });
    var params: std.json.ObjectMap = .empty;
    try params.put(init_arena, "protocolVersion", .{ .string = types.LATEST_PROTOCOL_VERSION });
    try params.put(
        init_arena,
        "capabilities",
        if (self.advertised_capabilities) |value| try provider_utils.cloneJsonValue(init_arena, value) else .{ .object = .empty },
    );
    try params.put(init_arena, "clientInfo", .{ .object = client_info });
    const raw_result = self.requestValue(io, state, "initialize", .{ .object = params }, false) catch |err| {
        self.close(io) catch {};
        return err;
    };
    const result = types.parseInitializeResult(state, raw_result) catch |err| {
        self.close(io) catch {};
        return err;
    };
    if (!types.isSupportedProtocolVersion(result.protocolVersion)) {
        self.close(io) catch {};
        return error.UnsupportedProtocolVersion;
    }
    self.initialize_result_value = result;
    try self.transport_value.setProtocolVersion(result.protocolVersion);
    try self.notification(io, "notifications/initialized", null);
    return self;
}

fn shouldRetryToolCall(err: anyerror, _: ?*const @import("provider").Diagnostics) bool {
    return err == error.RetryableTransportError;
}

fn responseRequestId(id: json_rpc.Id) ?i64 {
    return switch (id) {
        .integer => |value| value,
        .string => |value| std.fmt.parseInt(i64, value, 10) catch null,
    };
}

const ObjectField = struct { []const u8, std.json.Value };

fn objectValue(arena: Allocator, fields: []const ObjectField) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    for (fields) |field| try object.put(arena, field[0], field[1]);
    return .{ .object = object };
}

fn lockAtomic(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

test "stdio client performs real initialize, tools/list, and tools/call round trip" {
    const test_options = @import("mcp_test_options");
    const io = std.testing.io;
    const client = try createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .stdio = .{ .command = test_options.test_server_path } },
    });
    defer client.deinit(io);

    try std.testing.expectEqualStrings("ai.zig-test-mcp-echo", client.serverInfo().name);
    try std.testing.expectEqualStrings("Echo tool test server", client.instructions().?);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const definitions = try client.listTools(io, arena, null);
    try std.testing.expectEqual(1, definitions.tools.len);
    try std.testing.expectEqualStrings("echo", definitions.tools[0].name);

    var arguments: std.json.ObjectMap = .empty;
    try arguments.put(arena, "value", .{ .string = "hello" });
    const result = try client.callTool(io, arena, "echo", .{ .object = arguments });
    try std.testing.expectEqualStrings("{\"value\":\"hello\"}", result.contentParts().?[0].text.?);
    try std.testing.expectEqualStrings("hello", result.structuredContent().?.object.get("value").?.string);

    const long_text = try arena.alloc(u8, 20 * 1024);
    @memset(long_text, 'x');
    var long_arguments: std.json.ObjectMap = .empty;
    try long_arguments.put(arena, "value", .{ .string = long_text });
    const long_result = try client.callTool(io, arena, "echo", .{ .object = long_arguments });
    try std.testing.expectEqual(long_text.len, long_result.structuredContent().?.object.get("value").?.string.len);
}

test "stdio client correlates concurrent calls and flushes a pending request on close" {
    const test_options = @import("mcp_test_options");
    const io = std.testing.io;
    const client = try createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .stdio = .{ .command = test_options.test_server_path } },
    });
    defer client.deinit(io);

    const Runner = struct {
        fn run(value: *Client, task_io: std.Io, index: usize, output: *i64) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var arguments: std.json.ObjectMap = .empty;
            try arguments.put(arena, "value", .{ .integer = @intCast(index) });
            const result = try value.callTool(task_io, arena, "echo", .{ .object = arguments });
            output.* = result.structuredContent().?.object.get("value").?.integer;
        }
    };
    var outputs = [_]i64{0} ** 8;
    var futures: [8]std.Io.Future(anyerror!void) = undefined;
    for (&futures, 0..) |*future, index| {
        future.* = try io.concurrent(Runner.run, .{ client, io, index, &outputs[index] });
    }
    for (&futures) |*future| try future.await(io);
    for (outputs, 0..) |output, index| try std.testing.expectEqual(@as(i64, @intCast(index)), output);

    const Hanging = struct {
        fn run(value: *Client, task_io: std.Io) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            _ = try value.callTool(task_io, arena_state.allocator(), "hang", null);
        }
    };
    var hanging = try io.concurrent(Hanging.run, .{ client, io });
    try io.sleep(.fromMilliseconds(10), .awake);
    try client.close(io);
    try std.testing.expectError(error.ConnectionClosed, hanging.await(io));
}

test "client enforces negotiated capabilities" {
    const test_options = @import("mcp_test_options");
    const io = std.testing.io;
    const client = try createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .stdio = .{ .command = test_options.test_server_path } },
    });
    defer client.deinit(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.UnsupportedCapability, client.listResources(io, arena_state.allocator(), null));
}

test "client rejects unsupported protocol negotiation" {
    const Fake = struct {
        callbacks: transport_api.Callbacks = .{},
        fn transport(self: *@This()) transport_api.MCPTransport {
            return .{ .ctx = self, .vtable = &vtable };
        }
        fn start(_: *anyopaque, _: std.Io) anyerror!void {}
        fn send(raw: *anyopaque, _: std.Io, message: json_rpc.Message) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (message != .request) return;
            var result: std.json.ObjectMap = .empty;
            try result.put(std.testing.allocator, "protocolVersion", .{ .string = "1900-01-01" });
            defer result.deinit(std.testing.allocator);
            try result.put(std.testing.allocator, "capabilities", .{ .object = .empty });
            var info: std.json.ObjectMap = .empty;
            defer info.deinit(std.testing.allocator);
            try info.put(std.testing.allocator, "name", .{ .string = "bad" });
            try info.put(std.testing.allocator, "version", .{ .string = "1" });
            try result.put(std.testing.allocator, "serverInfo", .{ .object = info });
            self.callbacks.message(.{ .response = .{ .id = message.request.id, .result = .{ .object = result } } });
        }
        fn close(raw: *anyopaque, _: std.Io) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callbacks.closed();
        }
        fn setCallbacks(raw: *anyopaque, callbacks: transport_api.Callbacks) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callbacks = callbacks;
        }
        fn getVersion(_: *anyopaque) ?[]const u8 {
            return null;
        }
        fn setVersion(_: *anyopaque, _: []const u8) anyerror!void {}
        const vtable: transport_api.VTable = .{
            .start = start,
            .send = send,
            .close = close,
            .set_callbacks = setCallbacks,
            .get_protocol_version = getVersion,
            .set_protocol_version = setVersion,
        };
    };
    var fake: Fake = .{};
    try std.testing.expectError(error.UnsupportedProtocolVersion, createMcpClient(std.testing.allocator, std.testing.io, .{
        .transport = .{ .ready = fake.transport() },
    }));
}
