//! Finished UI stream facade over raw TextStreamPart mapping.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const tool_api = @import("../tool.zig");
const stream_text = @import("../stream_text.zig");
const messages = @import("ui_messages.zig");
const process = @import("process_ui_stream.zig");
const raw = @import("to_ui_chunks.zig");
const finish = @import("handle_ui_stream_finish.zig");
const stream_api = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    tools: tool_api.ToolSet = &.{},
    send_reasoning: bool = true,
    send_sources: bool = false,
    send_start: bool = true,
    send_finish: bool = true,
    on_error: raw.OnError = .masked,
    message_metadata: ?raw.MessageMetadata = null,
    response_message_id: ?[]const u8 = null,
    original_messages: ?[]const messages.UIMessage = null,
    on_step_end: ?finish.OnStepEnd = null,
    on_end: ?finish.OnEnd = null,
    on_callback_error: ?process.OnError = null,
    diag: ?*provider.Diagnostics = null,
};

pub fn toUIMessageStream(
    io: std.Io,
    gpa: Allocator,
    source: raw.TextPartStream,
    options: Options,
) !stream_api.ChunkStream {
    var generated_buffer: [64]u8 = undefined;
    const candidate_id = if (options.response_message_id) |id| id else blk: {
        if (options.original_messages == null) break :blk null;
        var generator = try provider_utils.IdGenerator.initFromIo(io, .{}, options.diag);
        break :blk generator.next(&generated_buffer);
    };
    const response_id = if (candidate_id) |candidate|
        finish.getResponseUIMessageId(options.original_messages, candidate)
    else
        null;
    const mapped = try raw.toUIMessageStream(gpa, source, .{
        .tools = options.tools,
        .send_reasoning = options.send_reasoning,
        .send_sources = options.send_sources,
        .send_start = options.send_start,
        .send_finish = options.send_finish,
        .on_error = options.on_error,
        .message_metadata = options.message_metadata,
        .response_message_id = response_id,
    });
    errdefer mapped.deinit(io);
    return finish.handleUIMessageStreamFinish(gpa, mapped, .{
        .message_id = response_id orelse candidate_id,
        .original_messages = options.original_messages,
        .on_step_end = options.on_step_end,
        .on_end = options.on_end,
        .on_error = options.on_callback_error,
        .diag = options.diag,
    });
}

pub fn fromStreamTextResult(
    io: std.Io,
    gpa: Allocator,
    result: stream_text.StreamTextResult,
    options: Options,
) !stream_api.ChunkStream {
    var generated_buffer: [64]u8 = undefined;
    const candidate_id = if (options.response_message_id) |id| id else blk: {
        if (options.original_messages == null) break :blk null;
        var generator = try provider_utils.IdGenerator.initFromIo(io, .{}, options.diag);
        break :blk generator.next(&generated_buffer);
    };
    const response_id = if (candidate_id) |candidate|
        finish.getResponseUIMessageId(options.original_messages, candidate)
    else
        null;
    const mapped = try raw.fromStreamTextResult(gpa, io, result, .{
        .tools = options.tools,
        .send_reasoning = options.send_reasoning,
        .send_sources = options.send_sources,
        .send_start = options.send_start,
        .send_finish = options.send_finish,
        .on_error = options.on_error,
        .message_metadata = options.message_metadata,
        .response_message_id = response_id,
    });
    errdefer mapped.deinit(io);
    return finish.handleUIMessageStreamFinish(gpa, mapped, .{
        .message_id = response_id orelse candidate_id,
        .original_messages = options.original_messages,
        .on_step_end = options.on_step_end,
        .on_end = options.on_end,
        .on_error = options.on_callback_error,
        .diag = options.diag,
    });
}
