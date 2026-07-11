//! Framework-neutral Chat transports.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const chunks = @import("ui_chunks.zig");
const messages = @import("ui_messages.zig");
const sse = @import("ui_sse.zig");
const stream_api = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const Trigger = enum {
    submit_message,
    regenerate_message,
    resume_stream,

    pub fn wireName(self: Trigger) []const u8 {
        return switch (self) {
            .submit_message => "submit-message",
            .regenerate_message => "regenerate-message",
            .resume_stream => "resume-stream",
        };
    }
};

pub const RequestOptions = struct {
    headers: []const provider.Header = &.{},
    body: ?JsonValue = null,
    metadata: ?JsonValue = null,
};

pub const SendMessagesOptions = struct {
    chat_id: []const u8,
    messages: []const messages.UIMessage,
    trigger: Trigger,
    message_id: ?[]const u8 = null,
    request: RequestOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const ReconnectOptions = struct {
    chat_id: []const u8,
    request: RequestOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const ChatTransport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send_messages: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            gpa: Allocator,
            options: SendMessagesOptions,
        ) anyerror!stream_api.ChunkStream,
        reconnect_to_stream: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            gpa: Allocator,
            options: ReconnectOptions,
        ) anyerror!?stream_api.ChunkStream,
    };

    pub fn sendMessages(
        self: ChatTransport,
        io: std.Io,
        gpa: Allocator,
        options: SendMessagesOptions,
    ) anyerror!stream_api.ChunkStream {
        return self.vtable.send_messages(self.ctx, io, gpa, options);
    }

    pub fn reconnectToStream(
        self: ChatTransport,
        io: std.Io,
        gpa: Allocator,
        options: ReconnectOptions,
    ) anyerror!?stream_api.ChunkStream {
        return self.vtable.reconnect_to_stream(self.ctx, io, gpa, options);
    }
};

pub const PreparedSendRequest = struct {
    api: []const u8,
    headers: []const provider.Header,
    body: JsonValue,
};

pub const PrepareSendMessagesRequest = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        options: SendMessagesOptions,
        prepared: *PreparedSendRequest,
    ) anyerror!void,

    pub fn call(
        self: PrepareSendMessagesRequest,
        arena: Allocator,
        options: SendMessagesOptions,
        prepared: *PreparedSendRequest,
    ) anyerror!void {
        return self.call_fn(self.ctx, arena, options, prepared);
    }
};

pub const PreparedReconnectRequest = struct {
    api: []const u8,
    headers: []const provider.Header,
};

pub const PrepareReconnectRequest = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        options: ReconnectOptions,
        prepared: *PreparedReconnectRequest,
    ) anyerror!void,

    pub fn call(
        self: PrepareReconnectRequest,
        arena: Allocator,
        options: ReconnectOptions,
        prepared: *PreparedReconnectRequest,
    ) anyerror!void {
        return self.call_fn(self.ctx, arena, options, prepared);
    }
};

pub const ResponseMode = enum { ui_sse, text };

pub const HttpChatTransport = struct {
    transport: provider_utils.HttpTransport,
    api: []const u8 = "/api/chat",
    headers: []const provider.Header = &.{},
    body: ?JsonValue = null,
    prepare_send_messages_request: ?PrepareSendMessagesRequest = null,
    prepare_reconnect_request: ?PrepareReconnectRequest = null,
    response_mode: ResponseMode = .ui_sse,

    pub fn asTransport(self: *HttpChatTransport) ChatTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ChatTransport.VTable = .{
        .send_messages = sendMessages,
        .reconnect_to_stream = reconnectToStream,
    };

    fn sendMessages(
        raw: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        options: SendMessagesOptions,
    ) anyerror!stream_api.ChunkStream {
        const self: *HttpChatTransport = @ptrCast(@alignCast(raw));
        const owner = try ResponseOwner.create(gpa);
        errdefer owner.destroy(io);
        const arena = owner.arena_state.allocator();

        var body = try buildSendBody(arena, self.body, options);
        var prepared: PreparedSendRequest = .{
            .api = try arena.dupe(u8, self.api),
            .headers = try mergeHeaders(arena, self.headers, options.request.headers, true),
            .body = body,
        };
        if (self.prepare_send_messages_request) |hook| try hook.call(arena, options, &prepared);
        body = prepared.body;
        const body_text = try provider_utils.stringifyJsonValueAlloc(arena, body);
        owner.response = try self.transport.request(io, arena, .{
            .method = .POST,
            .url = prepared.api,
            .headers = prepared.headers,
            .body = body_text,
        }, options.diag);
        owner.has_response = true;
        try validateResponse(io, owner, prepared.api, options.diag);
        return try processResponse(io, gpa, owner, self.response_mode, options.diag);
    }

    fn reconnectToStream(
        raw: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        options: ReconnectOptions,
    ) anyerror!?stream_api.ChunkStream {
        const self: *HttpChatTransport = @ptrCast(@alignCast(raw));
        const owner = try ResponseOwner.create(gpa);
        errdefer owner.destroy(io);
        const arena = owner.arena_state.allocator();
        var prepared: PreparedReconnectRequest = .{
            .api = try std.fmt.allocPrint(arena, "{s}/{s}/stream", .{ self.api, options.chat_id }),
            .headers = try mergeHeaders(arena, self.headers, options.request.headers, false),
        };
        if (self.prepare_reconnect_request) |hook| try hook.call(arena, options, &prepared);
        owner.response = try self.transport.request(io, arena, .{
            .method = .GET,
            .url = prepared.api,
            .headers = prepared.headers,
        }, options.diag);
        owner.has_response = true;
        if (owner.response.status == 204) {
            owner.destroy(io);
            return null;
        }
        try validateResponse(io, owner, prepared.api, options.diag);
        return try processResponse(io, gpa, owner, self.response_mode, options.diag);
    }
};

pub const DefaultChatTransport = struct {
    http: HttpChatTransport,

    pub fn init(options: HttpChatTransport) DefaultChatTransport {
        var configured = options;
        configured.response_mode = .ui_sse;
        return .{ .http = configured };
    }

    pub fn asTransport(self: *DefaultChatTransport) ChatTransport {
        return self.http.asTransport();
    }
};

pub const TextStreamChatTransport = struct {
    http: HttpChatTransport,

    pub fn init(options: HttpChatTransport) TextStreamChatTransport {
        var configured = options;
        configured.response_mode = .text;
        return .{ .http = configured };
    }

    pub fn asTransport(self: *TextStreamChatTransport) ChatTransport {
        return self.http.asTransport();
    }
};

fn buildSendBody(
    arena: Allocator,
    base_body: ?JsonValue,
    options: SendMessagesOptions,
) !JsonValue {
    var object: std.json.ObjectMap = .empty;
    try mergeBody(arena, &object, base_body);
    try mergeBody(arena, &object, options.request.body);
    try object.put(arena, "id", .{ .string = try arena.dupe(u8, options.chat_id) });

    const messages_text = try provider.wire.stringifyAlloc(arena, options.messages);
    const messages_value = try std.json.parseFromSliceLeaky(JsonValue, arena, messages_text, .{ .allocate = .alloc_always });
    try object.put(arena, "messages", messages_value);
    try object.put(arena, "trigger", .{ .string = options.trigger.wireName() });
    if (options.message_id) |message_id| {
        try object.put(arena, "messageId", .{ .string = try arena.dupe(u8, message_id) });
    }
    return .{ .object = object };
}

fn mergeBody(arena: Allocator, target: *std.json.ObjectMap, value: ?JsonValue) !void {
    const source = value orelse return;
    if (source != .object) return error.TypeValidationError;
    var iterator = source.object.iterator();
    while (iterator.next()) |entry| try target.put(
        arena,
        try arena.dupe(u8, entry.key_ptr.*),
        try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
    );
}

fn mergeHeaders(
    arena: Allocator,
    base: []const provider.Header,
    request: []const provider.Header,
    json_content: bool,
) ![]const provider.Header {
    const defaults = if (json_content)
        &[_]provider_utils.HeaderEntry{.{ .name = "content-type", .value = "application/json" }}
    else
        &[_]provider_utils.HeaderEntry{};
    const base_entries = try arena.alloc(provider_utils.HeaderEntry, base.len);
    for (base, base_entries) |header, *entry| entry.* = .{ .name = header.name, .value = header.value };
    const request_entries = try arena.alloc(provider_utils.HeaderEntry, request.len);
    for (request, request_entries) |header, *entry| entry.* = .{ .name = header.name, .value = header.value };
    const lists = [_][]const provider_utils.HeaderEntry{ defaults, base_entries, request_entries };
    return provider_utils.combineHeaders(arena, &lists);
}

const ResponseOwner = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    response: provider_utils.Response = undefined,
    has_response: bool = false,
    destroyed: bool = false,

    fn create(gpa: Allocator) !*ResponseOwner {
        const self = try gpa.create(ResponseOwner);
        self.* = .{ .gpa = gpa, .arena_state = std.heap.ArenaAllocator.init(gpa) };
        return self;
    }

    fn cleanup(self: *ResponseOwner) stream_api.Cleanup {
        return .{ .ctx = self, .deinit_fn = cleanupErased };
    }

    fn cleanupErased(raw: *anyopaque, io: std.Io) void {
        const self: *ResponseOwner = @ptrCast(@alignCast(raw));
        self.destroy(io);
    }

    fn destroy(self: *ResponseOwner, io: std.Io) void {
        if (self.destroyed) return;
        self.destroyed = true;
        if (self.has_response) self.response.body.deinit(io);
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

fn validateResponse(
    io: std.Io,
    owner: *ResponseOwner,
    api: []const u8,
    diag: ?*provider.Diagnostics,
) !void {
    const response = &owner.response;
    if (response.status < 200 or response.status >= 300) {
        const body = provider_utils.http_transport.readBodyWithLimit(
            owner.arena_state.allocator(),
            &response.body,
            1 << 20,
        ) catch "Failed to read chat error response";
        provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else owner.arena_state.allocator(), .{ .api_call = .{
            .message = body,
            .url = api,
            .status_code = response.status,
            .response_headers = response.headers,
            .response_body = body,
            .is_retryable = provider.isRetryableStatus(response.status),
        } });
        _ = io;
        return error.APICallError;
    }
    if (!response.has_body) {
        provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else owner.arena_state.allocator(), .{ .empty_response_body = .{
            .message = "The chat response body is empty.",
        } });
        return error.EmptyResponseBodyError;
    }
}

fn processResponse(
    io: std.Io,
    gpa: Allocator,
    owner: *ResponseOwner,
    mode: ResponseMode,
    diag: ?*provider.Diagnostics,
) !stream_api.ChunkStream {
    return switch (mode) {
        .ui_sse => sse.decode(gpa, owner.response.body.reader(), .{
            .diag = diag,
            .cleanup = owner.cleanup(),
        }) catch |err| {
            owner.destroy(io);
            return err;
        },
        .text => TextResponseStream.create(gpa, owner),
    };
}

const TextResponseStream = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    owner: *ResponseOwner,
    phase: enum { start, start_step, text_start, body, text_end, finish_step, finish, done } = .start,
    buffer: [4096]u8 = undefined,

    fn create(gpa: Allocator, owner: *ResponseOwner) !stream_api.ChunkStream {
        const self = try gpa.create(TextResponseStream);
        self.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .owner = owner,
        };
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: stream_api.ChunkStream.VTable = .{
        .next = next,
        .deinit = deinit,
        .cancel = cancel,
    };

    fn next(raw: *anyopaque, _: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *TextResponseStream = @ptrCast(@alignCast(raw));
        while (true) switch (self.phase) {
            .start => {
                self.phase = .start_step;
                return .{ .start = .{} };
            },
            .start_step => {
                self.phase = .text_start;
                return .{ .start_step = .{} };
            },
            .text_start => {
                self.phase = .body;
                return .{ .text_start = .{ .id = "text-1" } };
            },
            .body => {
                const count = try self.owner.response.body.reader().readSliceShort(&self.buffer);
                if (count == 0) {
                    self.phase = .text_end;
                    continue;
                }
                return .{ .text_delta = .{
                    .id = "text-1",
                    .delta = try self.arena_state.allocator().dupe(u8, self.buffer[0..count]),
                } };
            },
            .text_end => {
                self.phase = .finish_step;
                return .{ .text_end = .{ .id = "text-1" } };
            },
            .finish_step => {
                self.phase = .finish;
                return .{ .finish_step = .{} };
            },
            .finish => {
                self.phase = .done;
                return .{ .finish = .{} };
            },
            .done => return null,
        };
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *TextResponseStream = @ptrCast(@alignCast(raw));
        self.phase = .done;
        self.owner.destroy(io);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *TextResponseStream = @ptrCast(@alignCast(raw));
        self.owner.destroy(io);
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

test "DefaultChatTransport posts canonical request JSON and parses strict SSE" {
    const Fake = struct {
        request_body: []const u8 = "",
        reader: std.Io.Reader,

        fn request(
            raw: *anyopaque,
            _: std.Io,
            arena: Allocator,
            spec: provider_utils.RequestSpec,
            _: ?*provider.Diagnostics,
        ) provider_utils.RequestError!provider_utils.Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.request_body = arena.dupe(u8, spec.body orelse "") catch return error.OutOfMemory;
            return .{
                .status = 200,
                .status_text = "OK",
                .headers = &.{},
                .body = .{ .ctx = self, .reader_ptr = &self.reader, .deinit_fn = deinitBody },
            };
        }

        fn deinitBody(_: *anyopaque, _: std.Io) void {}
    };
    const fixed = std.Io.Reader.fixed(
        "data: {\"type\":\"start\",\"messageId\":\"a\"}\n\n" ++
            "data: [DONE]\n\n",
    );
    var fake: Fake = .{ .reader = fixed };
    var default = DefaultChatTransport.init(.{
        .transport = .{ .ctx = &fake, .vtable = &.{ .request = Fake.request } },
        .api = "https://example.test/chat",
    });
    const user_parts = [_]messages.UIMessagePart{.{ .text = .{ .text = "hello" } }};
    const request_messages = [_]messages.UIMessage{.{ .id = "u", .role = .user, .parts = &user_parts }};
    const stream = try default.asTransport().sendMessages(std.testing.io, std.testing.allocator, .{
        .chat_id = "chat-1",
        .messages = &request_messages,
        .trigger = .submit_message,
    });
    defer stream.deinit(std.testing.io);
    const first = (try stream.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("a", first.start.message_id.?);
    try std.testing.expectEqual(null, try stream.next(std.testing.io));
    try std.testing.expect(std.mem.indexOf(u8, fake.request_body, "\"id\":\"chat-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.request_body, "\"trigger\":\"submit-message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.request_body, "\"messages\":[") != null);
}
