const std = @import("std");
const provider = @import("provider");
const middleware = @import("middleware.zig");

const Model = struct {
    generate_result: ?provider.GenerateResult = null,
    stream_parts: []const provider.StreamPart = &.{},
    stream_state: StreamState = .{},
    generate_calls: usize = 0,

    const StreamState = struct {
        parts: []const provider.StreamPart = &.{},
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
            const self: *StreamState = @ptrCast(@alignCast(raw));
            if (self.index == self.parts.len) return null;
            defer self.index += 1;
            return self.parts[self.index];
        }
        fn deinit(_: *anyopaque, _: std.Io) void {}
        const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };
    };

    fn languageModel(self: *Model) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn p(_: *anyopaque) []const u8 {
        return "test";
    }
    fn m(_: *anyopaque) []const u8 {
        return "test-model";
    }
    fn u(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }
    fn g(raw: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
        const self: *Model = @ptrCast(@alignCast(raw));
        self.generate_calls += 1;
        return self.generate_result.?;
    }
    fn s(raw: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
        const self: *Model = @ptrCast(@alignCast(raw));
        self.stream_state = .{ .parts = self.stream_parts };
        return .{ .stream = .{ .ctx = &self.stream_state, .vtable = &StreamState.vtable } };
    }
    const vtable: provider.LanguageModel.VTable = .{
        .provider = p,
        .modelId = m,
        .urlIsSupported = u,
        .doGenerate = g,
        .doStream = s,
    };
};

const empty_prompt = [_]provider.Message{.{ .user = .{
    .content = &.{.{ .text = .{ .text = "test" } }},
} }};

fn callOptions() provider.CallOptions {
    return .{ .prompt = &empty_prompt };
}

test "extractReasoning stream handles tags split across chunk boundaries" {
    const input = [_]provider.StreamPart{
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "<thi" } },
        .{ .text_delta = .{ .id = "t", .delta = "nk>ana" } },
        .{ .text_delta = .{ .id = "t", .delta = "lysis</think>answer" } },
        .{ .text_end = .{ .id = "t" } },
    };
    var model: Model = .{ .stream_parts = &input };
    const options: middleware.ExtractReasoningOptions = .{ .tag_name = "think" };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.extractReasoningMiddleware(&options)};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);

    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(std.testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    while (try result.stream.next(std.testing.io)) |part| {
        try tags.append(std.testing.allocator, std.meta.activeTag(part));
        switch (part) {
            .reasoning_delta => |value| try reasoning.appendSlice(std.testing.allocator, value.delta),
            .text_delta => |value| try text.appendSlice(std.testing.allocator, value.delta),
            else => {},
        }
    }
    try std.testing.expectEqualStrings("analysis", reasoning.items);
    try std.testing.expectEqualStrings("answer", text.items);
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{ .reasoning_start, .reasoning_delta, .reasoning_delta, .reasoning_end, .text_start, .text_delta, .text_end },
        tags.items,
    );
}

test "extractReasoning generate extracts multiple blocks without regex" {
    const content = [_]provider.Content{.{ .text = .{
        .text = "<think>one</think>answer<think>two</think>more",
    } }};
    var model: Model = .{ .generate_result = .{
        .content = &content,
        .finish_reason = .{ .unified = .stop },
        .usage = .{ .input_tokens = .{}, .output_tokens = .{} },
        .warnings = &.{},
    } };
    const options: middleware.ExtractReasoningOptions = .{ .tag_name = "think" };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.extractReasoningMiddleware(&options)};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doGenerate(std.testing.io, arena, &params, null);
    try std.testing.expectEqualStrings("one\ntwo", result.content[0].reasoning.text);
    try std.testing.expectEqualStrings("answer\nmore", result.content[1].text.text);
}

test "extractReasoning starts in reasoning mode and separates repeated sections" {
    const input = [_]provider.StreamPart{
        .{ .text_start = .{ .id = "t" } },
        .{ .text_delta = .{ .id = "t", .delta = "first" } },
        .{ .text_delta = .{ .id = "t", .delta = "</think>answer" } },
        .{ .text_delta = .{ .id = "t", .delta = "<think>second</think>end" } },
        .{ .text_end = .{ .id = "t" } },
    };
    var model: Model = .{ .stream_parts = &input };
    const options: middleware.ExtractReasoningOptions = .{
        .tag_name = "think",
        .separator = "|",
        .starts_with_reasoning = true,
    };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.extractReasoningMiddleware(&options)};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);

    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(std.testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var reasoning_starts: usize = 0;
    var reasoning_ends: usize = 0;
    while (try result.stream.next(std.testing.io)) |part| switch (part) {
        .reasoning_start => reasoning_starts += 1,
        .reasoning_delta => |value| try reasoning.appendSlice(std.testing.allocator, value.delta),
        .reasoning_end => reasoning_ends += 1,
        .text_delta => |value| try text.appendSlice(std.testing.allocator, value.delta),
        else => {},
    };
    try std.testing.expectEqualStrings("first|second", reasoning.items);
    try std.testing.expectEqualStrings("answer|end", text.items);
    try std.testing.expectEqual(2, reasoning_starts);
    try std.testing.expectEqual(2, reasoning_ends);
}

test "extractReasoning keeps delayed text starts isolated by text id" {
    const input = [_]provider.StreamPart{
        .{ .text_start = .{ .id = "a" } },
        .{ .text_start = .{ .id = "b" } },
        .{ .text_delta = .{ .id = "a", .delta = "<think>A</think>a" } },
        .{ .text_delta = .{ .id = "b", .delta = "b" } },
        .{ .text_end = .{ .id = "a" } },
        .{ .text_end = .{ .id = "b" } },
    };
    var model: Model = .{ .stream_parts = &input };
    const options: middleware.ExtractReasoningOptions = .{ .tag_name = "think" };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.extractReasoningMiddleware(&options)};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);

    var starts_a: usize = 0;
    var starts_b: usize = 0;
    var text_a: std.ArrayList(u8) = .empty;
    defer text_a.deinit(std.testing.allocator);
    var text_b: std.ArrayList(u8) = .empty;
    defer text_b.deinit(std.testing.allocator);
    while (try result.stream.next(std.testing.io)) |part| switch (part) {
        .text_start => |value| if (std.mem.eql(u8, value.id, "a")) {
            starts_a += 1;
        } else if (std.mem.eql(u8, value.id, "b")) {
            starts_b += 1;
        },
        .text_delta => |value| if (std.mem.eql(u8, value.id, "a")) {
            try text_a.appendSlice(std.testing.allocator, value.delta);
        } else if (std.mem.eql(u8, value.id, "b")) {
            try text_b.appendSlice(std.testing.allocator, value.delta);
        },
        else => {},
    };
    try std.testing.expectEqual(1, starts_a);
    try std.testing.expectEqual(1, starts_b);
    try std.testing.expectEqualStrings("a", text_a.items);
    try std.testing.expectEqualStrings("b", text_b.items);
}

test "extractJson stream strips split fences with suffix holdback" {
    const input = [_]provider.StreamPart{
        .{ .text_start = .{ .id = "json" } },
        .{ .text_delta = .{ .id = "json", .delta = "`" } },
        .{ .text_delta = .{ .id = "json", .delta = "``json\n{\"value\":" } },
        .{ .text_delta = .{ .id = "json", .delta = "\"test\"}\n`" } },
        .{ .text_delta = .{ .id = "json", .delta = "``" } },
        .{ .text_end = .{ .id = "json" } },
    };
    var model: Model = .{ .stream_parts = &input };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.extractJsonMiddleware(null)};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    while (try result.stream.next(std.testing.io)) |part| switch (part) {
        .text_delta => |value| try text.appendSlice(std.testing.allocator, value.delta),
        else => {},
    };
    try std.testing.expectEqualStrings("{\"value\":\"test\"}", text.items);
}

test "extractJson custom transform buffers the complete text block" {
    const input = [_]provider.StreamPart{
        .{ .text_start = .{ .id = "json" } },
        .{ .text_delta = .{ .id = "json", .delta = "prefix:" } },
        .{ .text_delta = .{ .id = "json", .delta = "{\"ok\":true}" } },
        .{ .text_end = .{ .id = "json" } },
    };
    var model: Model = .{ .stream_parts = &input };
    const transform: middleware.JsonTransform = .{ .transform_fn = struct {
        fn apply(_: ?*anyopaque, arena: std.mem.Allocator, value: []const u8) provider.CallError![]const u8 {
            return arena.dupe(u8, value["prefix:".len..]);
        }
    }.apply };
    const options: middleware.ExtractJsonOptions = .{ .transform = transform };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.extractJsonMiddleware(&options)};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);

    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    while (try result.stream.next(std.testing.io)) |part| {
        try tags.append(std.testing.allocator, std.meta.activeTag(part));
        if (part == .text_delta) try text.appendSlice(std.testing.allocator, part.text_delta.delta);
    }
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{ .text_start, .text_delta, .text_end },
        tags.items,
    );
    try std.testing.expectEqualStrings("{\"ok\":true}", text.items);
}

test "simulateStreaming calls generate once and emits canonical content" {
    const content = [_]provider.Content{
        .{ .text = .{ .text = "answer" } },
        .{ .reasoning = .{ .text = "thought" } },
    };
    var model: Model = .{ .generate_result = .{
        .content = &content,
        .finish_reason = .{ .unified = .stop, .raw = "stop" },
        .usage = .{ .input_tokens = .{ .total = 1 }, .output_tokens = .{ .total = 2 } },
        .warnings = &.{},
        .response = .{ .id = "response", .model_id = "test-model", .timestamp_ms = 10 },
    } };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.simulateStreamingMiddleware()};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);
    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    while (try result.stream.next(std.testing.io)) |part| try tags.append(std.testing.allocator, std.meta.activeTag(part));
    try std.testing.expectEqual(1, model.generate_calls);
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{ .stream_start, .response_metadata, .text_start, .text_delta, .text_end, .reasoning_start, .reasoning_delta, .reasoning_end, .finish },
        tags.items,
    );
}

test "simulateStreaming omits empty text while preserving non-text content" {
    const content = [_]provider.Content{
        .{ .text = .{ .text = "" } },
        .{ .custom = .{ .kind = "test.custom" } },
        .{ .text = .{ .text = "visible" } },
    };
    var model: Model = .{ .generate_result = .{
        .content = &content,
        .finish_reason = .{ .unified = .stop },
        .usage = .{ .input_tokens = .{}, .output_tokens = .{} },
        .warnings = &.{},
    } };
    const middlewares = [_]middleware.LanguageModelMiddleware{middleware.simulateStreamingMiddleware()};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try middleware.wrapLanguageModel(arena, model.languageModel(), &middlewares);
    const params = callOptions();
    const result = try wrapped.doStream(std.testing.io, arena, &params, null);
    defer result.stream.deinit(std.testing.io);
    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(std.testing.allocator);
    while (try result.stream.next(std.testing.io)) |part| try tags.append(
        std.testing.allocator,
        std.meta.activeTag(part),
    );
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{ .stream_start, .response_metadata, .custom, .text_start, .text_delta, .text_end, .finish },
        tags.items,
    );
}
