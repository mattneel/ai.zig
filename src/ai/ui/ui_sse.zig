//! UI message chunk SSE encoder/strict decoder.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const chunks = @import("ui_chunks.zig");
const stream_api = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;

pub const UI_MESSAGE_STREAM_HEADERS = [_]provider.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "connection", .value = "keep-alive" },
    .{ .name = "x-vercel-ai-ui-message-stream", .value = "v1" },
    .{ .name = "x-accel-buffering", .value = "no" },
};

pub fn writeEvent(chunk: chunks.UIMessageChunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("data: ");
    try chunks.writeChunk(chunk, writer);
    try writer.writeAll("\n\n");
}

pub fn writeDone(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("data: [DONE]\n\n");
}

pub const DecodeOptions = struct {
    max_event_size: usize = 1 << 20,
    diag: ?*provider.Diagnostics = null,
    cleanup: ?stream_api.Cleanup = null,
};

pub fn decode(
    gpa: Allocator,
    reader: *std.Io.Reader,
    options: DecodeOptions,
) Allocator.Error!stream_api.ChunkStream {
    const state = try gpa.create(DecoderStream);
    state.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .decoder = provider_utils.SseDecoder.init(gpa, reader, .{
            .max_event_size = options.max_event_size,
            .diag = options.diag,
        }),
        .diag = options.diag,
        .cleanup = options.cleanup,
    };
    return .{ .ctx = state, .vtable = &DecoderStream.vtable };
}

const DecoderStream = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    decoder: provider_utils.SseDecoder,
    diag: ?*provider.Diagnostics,
    cleanup: ?stream_api.Cleanup,
    done: bool = false,
    deinitialized: bool = false,

    const vtable: stream_api.ChunkStream.VTable = .{
        .next = next,
        .deinit = deinit,
        .cancel = cancel,
    };

    fn next(raw: *anyopaque, _: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *DecoderStream = @ptrCast(@alignCast(raw));
        if (self.done) return null;
        const event = (try self.decoder.next()) orelse {
            self.done = true;
            return null;
        };
        if (std.mem.eql(u8, event.data, "[DONE]")) {
            self.done = true;
            return null;
        }
        return try chunks.parseChunk(self.arena_state.allocator(), event.data, self.diag);
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *DecoderStream = @ptrCast(@alignCast(raw));
        self.done = true;
        if (self.cleanup) |cleanup| {
            cleanup.deinit(io);
            self.cleanup = null;
        }
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *DecoderStream = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.decoder.deinit();
        if (self.cleanup) |cleanup| cleanup.deinit(io);
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

test "UI SSE encodes chunks, emits DONE, and decodes strictly" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeEvent(.{ .text_delta = .{ .id = "t", .delta = "hello" } }, &output.writer);
    try writeDone(&output.writer);
    try std.testing.expectEqualStrings(
        "data: {\"type\":\"text-delta\",\"id\":\"t\",\"delta\":\"hello\"}\n\ndata: [DONE]\n\n",
        output.writer.buffered(),
    );

    var reader = std.Io.Reader.fixed(output.writer.buffered());
    const stream = try decode(std.testing.allocator, &reader, .{});
    defer stream.deinit(std.testing.io);
    const chunk = (try stream.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("hello", chunk.text_delta.delta);
    try std.testing.expectEqual(null, try stream.next(std.testing.io));
}

test "UI SSE decoder rejects unknown chunk type" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var reader = std.Io.Reader.fixed("data: {\"type\":\"unknown\",\"id\":\"x\"}\n\n");
    const stream = try decode(std.testing.allocator, &reader, .{ .diag = &diagnostics });
    defer stream.deinit(std.testing.io);
    try std.testing.expectError(error.UIMessageStreamError, stream.next(std.testing.io));
    try std.testing.expectEqualStrings("unknown", diagnostics.payload.ui_message_stream.chunk_type);
}
