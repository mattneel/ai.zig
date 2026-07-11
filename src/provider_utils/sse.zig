const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const SseDecoder = struct {
    pub const Options = struct {
        max_event_size: usize = 1 << 20,
        diag: ?*provider.Diagnostics = null,
    };

    pub const Event = struct {
        data: []const u8,
        event: ?[]const u8 = null,
        id: ?[]const u8 = null,
    };

    pub const NextError = provider.Error || Allocator.Error || std.Io.Reader.Error || std.Io.Cancelable;

    gpa: Allocator,
    reader: *std.Io.Reader,
    max_event_size: usize,
    diag: ?*provider.Diagnostics,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event_type: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    output_data: std.ArrayList(u8) = .empty,
    output_event: std.ArrayList(u8) = .empty,
    output_id: std.ArrayList(u8) = .empty,
    data_lines: usize = 0,
    has_event_type: bool = false,
    has_id: bool = false,
    event_bytes: usize = 0,
    retry_ms: ?u64 = null,
    start_checked: bool = false,
    prefix: [3]u8 = undefined,
    prefix_index: u2 = 0,
    prefix_len: u2 = 0,
    unread: ?u8 = null,
    terminated: bool = false,

    pub fn init(gpa: Allocator, reader: *std.Io.Reader, options: Options) SseDecoder {
        return .{
            .gpa = gpa,
            .reader = reader,
            .max_event_size = options.max_event_size,
            .diag = options.diag,
        };
    }

    pub fn deinit(self: *SseDecoder) void {
        self.line.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.event_type.deinit(self.gpa);
        self.id.deinit(self.gpa);
        self.output_data.deinit(self.gpa);
        self.output_event.deinit(self.gpa);
        self.output_id.deinit(self.gpa);
        self.* = undefined;
    }

    /// Returned slices remain valid until the next call to next or deinit.
    pub fn next(self: *SseDecoder) NextError!?Event {
        if (self.terminated) return null;
        self.output_data.clearRetainingCapacity();
        self.output_event.clearRetainingCapacity();
        self.output_id.clearRetainingCapacity();

        while (try self.nextLine()) |line| {
            if (line.len == 0) {
                if (self.data_lines != 0) {
                    try self.output_data.appendSlice(self.gpa, self.data.items);
                    if (self.has_event_type) {
                        try self.output_event.appendSlice(self.gpa, self.event_type.items);
                    }
                    if (self.has_id) {
                        try self.output_id.appendSlice(self.gpa, self.id.items);
                    }
                    const event: Event = .{
                        .data = self.output_data.items,
                        .event = if (self.has_event_type) self.output_event.items else null,
                        .id = if (self.has_id) self.output_id.items else null,
                    };
                    self.resetEvent();
                    return event;
                }
                self.resetEvent();
                continue;
            }
            try self.processLine(line);
        }

        // eventsource-parser reset({consume:false}) semantics: an unterminated
        // event at EOF is discarded rather than dispatched.
        self.resetEvent();
        self.terminated = true;
        return null;
    }

    fn resetEvent(self: *SseDecoder) void {
        self.data.clearRetainingCapacity();
        self.event_type.clearRetainingCapacity();
        self.data_lines = 0;
        self.has_event_type = false;
        self.event_bytes = 0;
    }

    fn nextLine(self: *SseDecoder) NextError!?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            const byte = (try self.readByte()) orelse return null;
            switch (byte) {
                '\n' => return self.line.items,
                '\r' => {
                    if (try self.readByte()) |after_cr| {
                        if (after_cr != '\n') self.unread = after_cr;
                    }
                    return self.line.items;
                },
                else => {
                    if (self.line.items.len >= self.max_event_size) return self.eventTooLarge();
                    try self.line.append(self.gpa, byte);
                },
            }
        }
    }

    fn processLine(self: *SseDecoder, line: []const u8) NextError!void {
        const next_size = std.math.add(usize, self.event_bytes, line.len) catch
            return self.eventTooLarge();
        if (next_size > self.max_event_size) return self.eventTooLarge();
        self.event_bytes = next_size;

        if (line[0] == ':') return;
        const colon = std.mem.findScalar(u8, line, ':');
        const field = if (colon) |index| line[0..index] else line;
        var value = if (colon) |index| line[index + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "data")) {
            if (self.data_lines != 0) try self.data.append(self.gpa, '\n');
            try self.data.appendSlice(self.gpa, value);
            self.data_lines += 1;
            return;
        }
        if (std.mem.eql(u8, field, "event")) {
            self.event_type.clearRetainingCapacity();
            self.has_event_type = value.len != 0;
            if (self.has_event_type) try self.event_type.appendSlice(self.gpa, value);
            return;
        }
        if (std.mem.eql(u8, field, "id")) {
            if (std.mem.findScalar(u8, value, 0) != null) return;
            self.id.clearRetainingCapacity();
            try self.id.appendSlice(self.gpa, value);
            self.has_id = true;
            return;
        }
        if (std.mem.eql(u8, field, "retry")) {
            if (value.len == 0) return;
            for (value) |byte| if (byte < '0' or byte > '9') return;
            self.retry_ms = std.fmt.parseInt(u64, value, 10) catch return;
        }
        // Unknown fields are ignored, matching EventSource consumers that do
        // not install an onError hook.
    }

    fn readByte(self: *SseDecoder) NextError!?u8 {
        if (self.unread) |byte| {
            self.unread = null;
            return byte;
        }
        if (!self.start_checked) try self.checkStart();
        if (self.prefix_index < self.prefix_len) {
            defer self.prefix_index += 1;
            return self.prefix[self.prefix_index];
        }
        return self.readRawByte();
    }

    fn checkStart(self: *SseDecoder) NextError!void {
        self.start_checked = true;
        const first = (try self.readRawByte()) orelse return;
        if (first != 0xef) {
            self.prefix[0] = first;
            self.prefix_len = 1;
            return;
        }

        const second = (try self.readRawByte()) orelse {
            self.prefix[0] = first;
            self.prefix_len = 1;
            return;
        };
        if (second != 0xbb) {
            self.prefix[0] = first;
            self.prefix[1] = second;
            self.prefix_len = 2;
            return;
        }

        const third = (try self.readRawByte()) orelse {
            self.prefix[0] = first;
            self.prefix[1] = second;
            self.prefix_len = 2;
            return;
        };
        if (third != 0xbf) {
            self.prefix = .{ first, second, third };
            self.prefix_len = 3;
        }
    }

    fn readRawByte(self: *SseDecoder) NextError!?u8 {
        return self.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => null,
            else => |read_error| return read_error,
        };
    }

    fn eventTooLarge(self: *SseDecoder) error{InvalidResponseDataError} {
        self.terminated = true;
        provider.Diagnostics.set(self.diag, diagnosticAllocator(self.diag, self.gpa), .{ .invalid_response_data = .{
            .message = "SSE event exceeded maximum size",
        } });
        return error.InvalidResponseDataError;
    }
};

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

pub const Cleanup = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,

    pub fn run(self: Cleanup) void {
        self.func(self.ctx);
    }
};

pub fn ParseResult(comptime T: type) type {
    return union(enum) {
        success: struct {
            value: T,
            raw: []const u8,
        },
        failure: struct {
            raw: []const u8,
            message: []const u8,
        },
    };
}

pub fn JsonEventStream(comptime T: type) type {
    return struct {
        const Self = @This();

        decoder: SseDecoder,
        cleanup: ?Cleanup = null,
        done: bool = false,

        pub fn init(gpa: Allocator, reader: *std.Io.Reader, options: SseDecoder.Options) Self {
            return .{ .decoder = .init(gpa, reader, options) };
        }

        pub fn deinit(self: *Self) void {
            self.decoder.deinit();
            if (self.cleanup) |cleanup| cleanup.run();
            self.* = undefined;
        }

        pub fn next(self: *Self, arena: Allocator) anyerror!?ParseResult(T) {
            if (self.done) return null;
            const event = (try self.decoder.next()) orelse {
                self.done = true;
                return null;
            };
            if (std.mem.eql(u8, event.data, "[DONE]")) {
                self.done = true;
                return null;
            }

            const raw = try arena.dupe(u8, event.data);
            const value = std.json.parseFromSliceLeaky(T, arena, raw, .{
                .ignore_unknown_fields = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failure = .{
                    .raw = raw,
                    .message = @errorName(err),
                } },
            };
            return .{ .success = .{ .value = value, .raw = raw } };
        }
    };
}

pub const JsonValueEventStream = JsonEventStream(std.json.Value);

const ExpectedEvent = struct {
    data: []const u8,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

const SseCase = struct {
    input: []const u8,
    events: []const ExpectedEvent,
    retry_ms: ?u64 = null,
};

const sse_cases = [_]SseCase{
    .{
        .input = "\xef\xbb\xbfdata: bom\n\n",
        .events = &.{.{ .data = "bom" }},
    },
    .{
        .input = "data: first\n\n\xef\xbb\xbfdata: hidden\n\ndata: last\n\n",
        .events = &.{ .{ .data = "first" }, .{ .data = "last" } },
    },
    .{
        .input = "data: lf\n\ndata: crlf\r\n\r\ndata: cr\r\r",
        .events = &.{ .{ .data = "lf" }, .{ .data = "crlf" }, .{ .data = "cr" } },
    },
    .{
        .input = "data: held\r\n\r\n",
        .events = &.{.{ .data = "held" }},
    },
    .{
        .input = "data: one\ndata: two\n\n",
        .events = &.{.{ .data = "one\ntwo" }},
    },
    .{
        .input = "data:x\n\ndata: x\n\ndata\n\ndata:  x\n\n",
        .events = &.{ .{ .data = "x" }, .{ .data = "x" }, .{ .data = "" }, .{ .data = " x" } },
    },
    .{
        .input = ": comment\ndata: visible\n\n",
        .events = &.{.{ .data = "visible" }},
    },
    .{
        .input = "event: custom\ndata: one\n\ndata: two\n\nevent: ignored\n\ndata: three\n\n",
        .events = &.{
            .{ .data = "one", .event = "custom" },
            .{ .data = "two" },
            .{ .data = "three" },
        },
    },
    .{
        .input = "event:\ndata: empty-type\n\n",
        .events = &.{.{ .data = "empty-type" }},
    },
    .{
        .input = "id: one\ndata: a\n\nid: bad\x00id\ndata: b\n\nid:\ndata: c\n\n",
        .events = &.{
            .{ .data = "a", .id = "one" },
            .{ .data = "b", .id = "one" },
            .{ .data = "c", .id = "" },
        },
    },
    .{
        .input = "retry: 125\nretry: 12x\ndata: retry\n\n",
        .events = &.{.{ .data = "retry" }},
        .retry_ms = 125,
    },
    .{
        .input = "unknown: ignored\nunknown-bare\ndata: known\n\n",
        .events = &.{.{ .data = "known" }},
    },
    .{
        .input = "data: [DONE]\n\n",
        .events = &.{.{ .data = "[DONE]" }},
    },
    .{
        .input = "data: unterminated",
        .events = &.{},
    },
};

const chunk_sizes = [_]?usize{ 1, 2, 3, 7, null };

fn expectSseCase(case: SseCase, chunk_size: ?usize) !void {
    var reader_buffer: [32]u8 = undefined;
    const calls = [_]std.testing.Reader.Call{.{ .buffer = case.input }};
    var source = std.testing.Reader.init(&reader_buffer, &calls);
    source.artificial_limit = if (chunk_size) |size| .limited(size) else .unlimited;

    var decoder = SseDecoder.init(std.testing.allocator, &source.interface, .{});
    defer decoder.deinit();
    for (case.events) |expected| {
        const actual = (try decoder.next()) orelse return error.MissingEvent;
        try std.testing.expectEqualStrings(expected.data, actual.data);
        if (expected.event) |event| {
            try std.testing.expectEqualStrings(event, actual.event orelse return error.MissingEventType);
        } else {
            try std.testing.expectEqual(null, actual.event);
        }
        if (expected.id) |id| {
            try std.testing.expectEqualStrings(id, actual.id orelse return error.MissingEventId);
        } else {
            try std.testing.expectEqual(null, actual.id);
        }
    }
    try std.testing.expectEqual(null, try decoder.next());
    try std.testing.expectEqual(case.retry_ms, decoder.retry_ms);
}

test "sse corpus is chunk-boundary invariant (14 cases x 5 fill sizes)" {
    try std.testing.expectEqual(14, sse_cases.len);
    for (sse_cases) |case| {
        for (chunk_sizes) |chunk_size| try expectSseCase(case, chunk_size);
    }
}

test "sse max_event_size reports InvalidResponseDataError diagnostics across chunks" {
    for (chunk_sizes) |chunk_size| {
        var reader_buffer: [8]u8 = undefined;
        const calls = [_]std.testing.Reader.Call{.{ .buffer = "data: this-is-too-large\n\n" }};
        var source = std.testing.Reader.init(&reader_buffer, &calls);
        source.artificial_limit = if (chunk_size) |size| .limited(size) else .unlimited;
        var diagnostics = provider.Diagnostics.init(std.testing.allocator);
        defer diagnostics.deinit();
        var decoder = SseDecoder.init(std.testing.allocator, &source.interface, .{
            .max_event_size = 8,
            .diag = &diagnostics,
        });
        defer decoder.deinit();
        try std.testing.expectError(error.InvalidResponseDataError, decoder.next());
        try std.testing.expect(diagnostics.available);
        try std.testing.expectEqualStrings(
            "SSE event exceeded maximum size",
            diagnostics.payload.invalid_response_data.message,
        );
    }
}

test "sse JsonEventStream stops at DONE and keeps malformed JSON as data" {
    const Chunk = struct { index: u32 };
    var reader = std.Io.Reader.fixed(
        "data: {\"index\":1}\n\n" ++
            "data: malformed\n\n" ++
            "data: {\"index\":2}\n\n" ++
            "data: [DONE]\n\n" ++
            "data: {\"index\":3}\n\n",
    );
    var stream = JsonEventStream(Chunk).init(std.testing.allocator, &reader, .{});
    defer stream.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch ((try stream.next(arena)).?) {
        .success => |success| try std.testing.expectEqual(1, success.value.index),
        .failure => return error.UnexpectedParseFailure,
    }
    switch ((try stream.next(arena)).?) {
        .failure => |failure| try std.testing.expectEqualStrings("malformed", failure.raw),
        .success => return error.UnexpectedParseSuccess,
    }
    switch ((try stream.next(arena)).?) {
        .success => |success| try std.testing.expectEqual(2, success.value.index),
        .failure => return error.UnexpectedParseFailure,
    }
    try std.testing.expectEqual(null, try stream.next(arena));
    try std.testing.expectEqual(null, try stream.next(arena));
}
