//! `TextStreamPart` to UI message chunk conversion.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const tool_api = @import("../tool.zig");
const stream_text = @import("../stream_text.zig");
const part_stream = @import("../stream/part_stream.zig");
const parts = @import("../stream/parts.zig");
const chunks = @import("ui_chunks.zig");
const chunk_stream = @import("chunk_stream.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const OnError = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        value: JsonValue,
        code: ?anyerror,
    ) anyerror![]const u8,

    pub fn call(
        self: OnError,
        arena: Allocator,
        value: JsonValue,
        code: ?anyerror,
    ) anyerror![]const u8 {
        return self.call_fn(self.ctx, arena, value, code);
    }

    pub const masked: OnError = .{ .call_fn = maskedError };
};

pub const MessageMetadata = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        part: *const parts.TextStreamPart,
    ) anyerror!?JsonValue,

    pub fn call(
        self: MessageMetadata,
        arena: Allocator,
        part: *const parts.TextStreamPart,
    ) anyerror!?JsonValue {
        return self.call_fn(self.ctx, arena, part);
    }
};

pub const Options = struct {
    tools: tool_api.ToolSet = &.{},
    send_reasoning: bool = true,
    send_sources: bool = false,
    send_start: bool = true,
    send_finish: bool = true,
    on_error: OnError = .masked,
    message_metadata: ?MessageMetadata = null,
    response_message_id: ?[]const u8 = null,
};

pub fn toUIMessageChunk(
    arena: Allocator,
    part: parts.TextStreamPart,
    options: Options,
) anyerror!?chunks.UIMessageChunk {
    return switch (part) {
        .text_start => |value| .{ .text_start = .{
            .id = value.id,
            .provider_metadata = value.provider_metadata,
        } },
        .text_delta => |value| .{ .text_delta = .{
            .id = value.id,
            .delta = value.text,
            .provider_metadata = value.provider_metadata,
        } },
        .text_end => |value| .{ .text_end = .{
            .id = value.id,
            .provider_metadata = value.provider_metadata,
        } },
        .reasoning_start => |value| if (options.send_reasoning) .{ .reasoning_start = .{
            .id = value.id,
            .provider_metadata = value.provider_metadata,
        } } else null,
        .reasoning_delta => |value| if (options.send_reasoning) .{ .reasoning_delta = .{
            .id = value.id,
            .delta = value.text,
            .provider_metadata = value.provider_metadata,
        } } else null,
        .reasoning_end => |value| if (options.send_reasoning) .{ .reasoning_end = .{
            .id = value.id,
            .provider_metadata = value.provider_metadata,
        } } else null,
        .custom => |value| .{ .custom = .{
            .kind = value.kind,
            .provider_metadata = value.provider_metadata,
        } },
        .tool_input_start => |value| .{ .tool_input_start = .{
            .tool_call_id = value.id,
            .tool_name = value.tool_name,
            .provider_executed = value.provider_executed,
            .provider_metadata = value.provider_metadata,
            .tool_metadata = value.tool_metadata,
            .dynamic = dynamicFlag(options.tools, value.tool_name, value.dynamic),
            .title = value.title,
        } },
        .tool_input_delta => |value| .{ .tool_input_delta = .{
            .tool_call_id = value.id,
            .input_text_delta = value.delta,
        } },
        .tool_input_end => null,
        .source => |value| if (!options.send_sources) null else switch (value) {
            .url => |source| .{ .source_url = .{
                .source_id = source.id,
                .url = source.url,
                .title = source.title,
                .provider_metadata = source.provider_metadata,
            } },
            .document => |source| .{ .source_document = .{
                .source_id = source.id,
                .media_type = source.media_type,
                .title = source.title,
                .filename = source.filename,
                .provider_metadata = source.provider_metadata,
            } },
        },
        .file => |value| .{ .file = .{
            .url = try generatedFileUrl(arena, value.data, value.media_type),
            .media_type = value.media_type,
            .provider_metadata = value.provider_metadata,
        } },
        .reasoning_file => |value| if (!options.send_reasoning) null else .{ .reasoning_file = .{
            .url = try generatedFileUrl(arena, value.data, value.media_type),
            .media_type = value.media_type,
            .provider_metadata = value.provider_metadata,
        } },
        .tool_call => |value| blk: {
            const dynamic = dynamicFlag(options.tools, value.tool_name, value.dynamic);
            if (value.invalid) {
                const raw_error: JsonValue = .{ .string = if (value.err) |tool_error| tool_error.message else "Invalid tool input" };
                break :blk .{ .tool_input_error = .{
                    .tool_call_id = value.tool_call_id,
                    .tool_name = value.tool_name,
                    .input = value.input,
                    .provider_executed = value.provider_executed,
                    .provider_metadata = value.provider_metadata,
                    .tool_metadata = value.tool_metadata,
                    .dynamic = dynamic,
                    .error_text = try options.on_error.call(arena, raw_error, if (value.err) |tool_error| tool_error.err else null),
                } };
            }
            break :blk .{ .tool_input_available = .{
                .tool_call_id = value.tool_call_id,
                .tool_name = value.tool_name,
                .input = value.input,
                .provider_executed = value.provider_executed,
                .provider_metadata = value.provider_metadata,
                .tool_metadata = value.tool_metadata,
                .dynamic = dynamic,
            } };
        },
        .tool_result => |value| .{ .tool_output_available = .{
            .tool_call_id = value.tool_call_id,
            .output = value.output,
            .provider_executed = value.provider_executed,
            .provider_metadata = value.provider_metadata,
            .tool_metadata = value.tool_metadata,
            .dynamic = dynamicFlag(options.tools, value.tool_name, value.dynamic),
            .preliminary = if (value.preliminary) true else null,
        } },
        .tool_error => |value| .{ .tool_output_error = .{
            .tool_call_id = value.tool_call_id,
            .error_text = if (value.provider_executed)
                try unmaskedError(arena, value.error_value)
            else
                try options.on_error.call(arena, value.error_value, value.error_code),
            .provider_executed = value.provider_executed,
            .provider_metadata = value.provider_metadata,
            .tool_metadata = value.tool_metadata,
            .dynamic = dynamicFlag(options.tools, value.tool_name, value.dynamic),
        } },
        .tool_output_denied => |value| .{ .tool_output_denied = .{
            .tool_call_id = value.tool_call_id,
        } },
        .tool_approval_request => |value| .{ .tool_approval_request = .{
            .approval_id = value.approval_id,
            .tool_call_id = value.tool_call.tool_call_id,
            .is_automatic = if (value.is_automatic) true else null,
            .signature = value.signature,
        } },
        .tool_approval_response => |value| .{ .tool_approval_response = .{
            .approval_id = value.approval_id,
            .approved = value.approved,
            .reason = value.reason,
            .provider_executed = value.provider_executed,
        } },
        .start_step => .{ .start_step = .{} },
        .finish_step => .{ .finish_step = .{} },
        .start => if (options.send_start) .{ .start = .{
            .message_id = options.response_message_id,
        } } else null,
        .finish => |value| if (options.send_finish) .{ .finish = .{
            .finish_reason = value.finish_reason.unified,
        } } else null,
        .abort => |value| .{ .abort = .{ .reason = value.reason } },
        .err => |value| .{ .err = .{
            .error_text = try options.on_error.call(arena, value.error_value, value.error_code),
        } },
        .raw => null,
    };
}

pub const TextPartStream = part_stream.PartStream(parts.TextStreamPart);

pub fn toUIMessageStream(
    gpa: Allocator,
    source: TextPartStream,
    options: Options,
) Allocator.Error!chunk_stream.ChunkStream {
    const state = try gpa.create(MappingStream);
    state.* = .{
        .gpa = gpa,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .source = source,
        .options = options,
    };
    errdefer {
        state.arena_state.deinit();
        gpa.destroy(state);
    }
    if (options.response_message_id) |id| {
        state.options.response_message_id = try state.arena_state.allocator().dupe(u8, id);
    }
    return .{ .ctx = state, .vtable = &MappingStream.vtable };
}

pub fn fromStreamTextResult(
    gpa: Allocator,
    io: std.Io,
    result: stream_text.StreamTextResult,
    options: Options,
) Allocator.Error!chunk_stream.ChunkStream {
    const source_state = try gpa.create(ResultSource);
    source_state.* = .{ .gpa = gpa, .result = result };
    errdefer {
        var owned_result = source_state.result;
        owned_result.deinit(io);
        gpa.destroy(source_state);
    }
    const source: TextPartStream = .{ .ctx = source_state, .vtable = &ResultSource.vtable };
    return toUIMessageStream(gpa, source, options);
}

const MappingStream = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    source: TextPartStream,
    options: Options,
    pending_metadata: ?JsonValue = null,
    done: bool = false,
    source_deinitialized: bool = false,

    const vtable: chunk_stream.ChunkStream.VTable = .{
        .next = next,
        .deinit = deinit,
        .cancel = cancel,
    };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?chunks.UIMessageChunk {
        const self: *MappingStream = @ptrCast(@alignCast(raw));
        if (self.pending_metadata) |metadata| {
            self.pending_metadata = null;
            return .{ .message_metadata = .{ .message_metadata = metadata } };
        }
        if (self.done) return null;

        while (try self.source.next(io)) |part| {
            const metadata = if (self.options.message_metadata) |hook|
                try hook.call(self.arena_state.allocator(), &part)
            else
                null;
            var converted = try toUIMessageChunk(self.arena_state.allocator(), part, self.options);
            if (metadata) |value| switch (part) {
                .start => if (converted) |*chunk| {
                    chunk.start.message_metadata = value;
                },
                .finish => if (converted) |*chunk| {
                    chunk.finish.message_metadata = value;
                },
                else => self.pending_metadata = value,
            };
            if (converted) |chunk| return chunk;
            if (self.pending_metadata) |value| {
                self.pending_metadata = null;
                return .{ .message_metadata = .{ .message_metadata = value } };
            }
        }
        self.done = true;
        return null;
    }

    fn cancel(raw: *anyopaque, io: std.Io) void {
        const self: *MappingStream = @ptrCast(@alignCast(raw));
        self.done = true;
        if (!self.source_deinitialized) {
            self.source.deinit(io);
            self.source_deinitialized = true;
        }
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *MappingStream = @ptrCast(@alignCast(raw));
        if (!self.source_deinitialized) self.source.deinit(io);
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

const ResultSource = struct {
    gpa: Allocator,
    result: stream_text.StreamTextResult,
    deinitialized: bool = false,

    const vtable: TextPartStream.VTable = .{
        .next = next,
        .deinit = deinit,
    };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?parts.TextStreamPart {
        const self: *ResultSource = @ptrCast(@alignCast(raw));
        return self.result.next(io);
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *ResultSource = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.result.deinit(io);
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

fn maskedError(
    _: ?*anyopaque,
    _: Allocator,
    _: JsonValue,
    _: ?anyerror,
) anyerror![]const u8 {
    return "An error occurred.";
}

fn unmaskedError(arena: Allocator, value: JsonValue) Allocator.Error![]const u8 {
    return switch (value) {
        .string => |text| arena.dupe(u8, text),
        else => provider_utils.stringifyJsonValueAlloc(arena, value),
    };
}

fn dynamicFlag(tools: tool_api.ToolSet, name: []const u8, fallback: ?bool) ?bool {
    for (tools) |named| {
        if (!std.mem.eql(u8, named.name, name)) continue;
        return if (named.tool.kind == .dynamic) true else null;
    }
    return if (fallback orelse false) true else null;
}

fn generatedFileUrl(
    arena: Allocator,
    data: provider.GeneratedFileData,
    media_type: []const u8,
) Allocator.Error![]const u8 {
    return switch (data) {
        .url => |url| arena.dupe(u8, url.url),
        .data => |payload| switch (payload.data) {
            .base64 => |base64| std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ media_type, base64 }),
            .bytes => |bytes| blk: {
                const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
                const prefix = try std.fmt.allocPrint(arena, "data:{s};base64,", .{media_type});
                const result = try arena.alloc(u8, prefix.len + encoded_len);
                @memcpy(result[0..prefix.len], prefix);
                _ = std.base64.standard.Encoder.encode(result[prefix.len..], bytes);
                break :blk result;
            },
        },
    };
}

test "toUIMessageChunk applies send flags, dynamic tools, data URLs, and masking" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(null, try toUIMessageChunk(arena, .{ .reasoning_delta = .{ .id = "r", .text = "secret" } }, .{ .send_reasoning = false }));
    try std.testing.expectEqual(null, try toUIMessageChunk(arena, .{ .source = .{ .url = .{ .id = "s", .url = "https://example.test" } } }, .{}));

    const step_start = (try toUIMessageChunk(arena, .{ .start_step = .{
        .request = .{},
        .warnings = &.{},
    } }, .{})).?;
    try std.testing.expect(step_start == .start_step);

    const file = (try toUIMessageChunk(arena, .{ .file = .{
        .media_type = "text/plain",
        .data = .{ .data = .{ .data = .{ .bytes = "hi" } } },
    } }, .{})).?;
    try std.testing.expectEqualStrings("data:text/plain;base64,aGk=", file.file.url);

    const dynamic_tool = tool_api.NamedTool{ .name = "runtime", .tool = .{
        .kind = .dynamic,
        .input_schema = provider_utils.schemaFromType(JsonValue),
    } };
    const call = (try toUIMessageChunk(arena, .{ .tool_call = .{
        .tool_call_id = "c",
        .tool_name = "runtime",
        .input = .null,
    } }, .{ .tools = &.{dynamic_tool} })).?;
    try std.testing.expectEqual(true, call.tool_input_available.dynamic.?);

    const client_error = (try toUIMessageChunk(arena, .{ .tool_error = .{
        .tool_call_id = "c",
        .tool_name = "runtime",
        .input = null,
        .error_value = .{ .string = "private" },
    } }, .{})).?;
    try std.testing.expectEqualStrings("An error occurred.", client_error.tool_output_error.error_text);

    const provider_error = (try toUIMessageChunk(arena, .{ .tool_error = .{
        .tool_call_id = "p",
        .tool_name = "provider",
        .input = null,
        .error_value = .{ .string = "provider detail" },
        .provider_executed = true,
    } }, .{})).?;
    try std.testing.expectEqualStrings("provider detail", provider_error.tool_output_error.error_text);

    const Source = struct {
        emitted: bool = false,

        fn next(raw: *anyopaque, _: std.Io) anyerror!?parts.TextStreamPart {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.emitted) return null;
            self.emitted = true;
            return .{ .start = {} };
        }
    };
    var source_state: Source = .{};
    var response_id = "stable-id".*;
    const stream = try toUIMessageStream(std.testing.allocator, .{
        .ctx = &source_state,
        .vtable = &.{ .next = Source.next },
    }, .{ .response_message_id = &response_id });
    defer stream.deinit(std.testing.io);
    @memset(&response_id, 'x');
    const start = (try stream.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("stable-id", start.start.message_id.?);
}
