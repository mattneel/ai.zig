//! Agent to UI-stream helpers and std.http.Server response writer.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const agent_api = @import("../agent.zig");
const messages = @import("ui_messages.zig");
const conversion = @import("convert_ui_messages.zig");
const ui_stream = @import("ui_stream.zig");
const chunks = @import("ui_chunks.zig");
const chunk_stream = @import("chunk_stream.zig");
const sse = @import("ui_sse.zig");
const transports = @import("transports.zig");

const Allocator = std.mem.Allocator;

pub const CreateOptions = struct {
    parameters: agent_api.AgentCallParameters = .{},
    stream: ui_stream.Options = .{},
};

pub fn createAgentUIStream(
    io: std.Io,
    gpa: Allocator,
    agent: agent_api.Agent,
    ui_messages: []const messages.UIMessage,
    options: CreateOptions,
) anyerror!chunk_stream.ChunkStream {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const validated = try conversion.validateUIMessages(arena, ui_messages, .{
        .tools = agent.tools,
        .diag = options.stream.diag,
    });
    const model_messages = try conversion.convertToModelMessages(arena, validated, .{
        .tools = agent.tools,
        .diag = options.stream.diag,
    });
    var parameters = options.parameters;
    parameters.prompt = null;
    parameters.messages = model_messages;
    const result = try agent.stream(io, gpa, parameters);
    var stream_options = options.stream;
    stream_options.tools = agent.tools;
    if (stream_options.original_messages == null) stream_options.original_messages = ui_messages;
    return ui_stream.fromStreamTextResult(io, gpa, result, stream_options);
}

pub const DirectChatTransport = struct {
    agent: agent_api.Agent,
    options: CreateOptions = .{},

    pub fn asTransport(self: *DirectChatTransport) transports.ChatTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: transports.ChatTransport.VTable = .{
        .send_messages = sendMessages,
        .reconnect_to_stream = reconnect,
    };

    fn sendMessages(
        raw: *anyopaque,
        io: std.Io,
        gpa: Allocator,
        options: transports.SendMessagesOptions,
    ) anyerror!chunk_stream.ChunkStream {
        const self: *DirectChatTransport = @ptrCast(@alignCast(raw));
        var create_options = self.options;
        create_options.stream.original_messages = options.messages;
        return createAgentUIStream(io, gpa, self.agent, options.messages, create_options);
    }

    fn reconnect(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: transports.ReconnectOptions,
    ) anyerror!?chunk_stream.ChunkStream {
        return null;
    }
};

pub const ResponseOptions = struct {
    status: std.http.Status = .ok,
    reason: ?[]const u8 = null,
    headers: []const provider.Header = &.{},
    response_buffer_size: usize = 16 * 1024,
};

pub fn writeUIMessageStreamResponse(
    io: std.Io,
    gpa: Allocator,
    request: *std.http.Server.Request,
    stream_value: chunk_stream.ChunkStream,
    options: ResponseOptions,
) anyerror!void {
    var stream = stream_value;
    defer stream.deinit(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const headers = try responseHeaders(arena, options.headers);
    const http_headers = try arena.alloc(std.http.Header, headers.len);
    for (headers, http_headers) |header, *http_header| http_header.* = .{
        .name = header.name,
        .value = header.value,
    };
    const response_buffer = try gpa.alloc(u8, options.response_buffer_size);
    defer gpa.free(response_buffer);
    var response = try request.respondStreaming(response_buffer, .{
        .respond_options = .{
            .status = options.status,
            .reason = options.reason,
            .keep_alive = true,
            .extra_headers = http_headers,
        },
    });
    errdefer response.end() catch {};
    while (try stream.next(io)) |chunk| {
        try sse.writeEvent(chunk, &response.writer);
        try response.flush();
    }
    try sse.writeDone(&response.writer);
    try response.flush();
    try response.end();
}

pub fn writeAgentUIStreamResponse(
    io: std.Io,
    gpa: Allocator,
    request: *std.http.Server.Request,
    agent: agent_api.Agent,
    ui_messages: []const messages.UIMessage,
    create_options: CreateOptions,
    response_options: ResponseOptions,
) anyerror!void {
    const stream = try createAgentUIStream(io, gpa, agent, ui_messages, create_options);
    return writeUIMessageStreamResponse(io, gpa, request, stream, response_options);
}

fn responseHeaders(arena: Allocator, user: []const provider.Header) ![]const provider.Header {
    const defaults = try arena.alloc(provider_utils.HeaderEntry, sse.UI_MESSAGE_STREAM_HEADERS.len);
    for (sse.UI_MESSAGE_STREAM_HEADERS, defaults) |header, *entry| entry.* = .{
        .name = header.name,
        .value = header.value,
    };
    const user_entries = try arena.alloc(provider_utils.HeaderEntry, user.len);
    for (user, user_entries) |header, *entry| entry.* = .{
        .name = header.name,
        .value = header.value,
    };
    const lists = [_][]const provider_utils.HeaderEntry{ defaults, user_entries };
    return provider_utils.combineHeaders(arena, &lists);
}

test "DirectChatTransport reconnect is unsupported" {
    const Dummy = struct {
        fn generate(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: agent_api.AgentCallParameters,
        ) provider.CallError!@import("../generate_text.zig").GenerateTextResult {
            return error.UnsupportedFunctionalityError;
        }
        fn stream(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: agent_api.AgentCallParameters,
        ) anyerror!@import("../stream_text.zig").StreamTextResult {
            return error.UnsupportedFunctionalityError;
        }
    };
    var dummy: u8 = 0;
    var direct: DirectChatTransport = .{ .agent = .{
        .ctx = &dummy,
        .generate_fn = Dummy.generate,
        .stream_fn = Dummy.stream,
    } };
    try std.testing.expectEqual(
        null,
        try direct.asTransport().reconnectToStream(std.testing.io, std.testing.allocator, .{ .chat_id = "x" }),
    );
}
