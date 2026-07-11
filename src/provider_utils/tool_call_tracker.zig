//! Tracks OpenAI-chat-style indexed streaming tool-call deltas.
//!
//! Tool inputs are deliberately finalized only by `flush`: a currently
//! parsable JSON buffer may still be a prefix of a longer argument string.

const std = @import("std");
const provider = @import("provider");
const id_api = @import("id.zig");

const Allocator = std.mem.Allocator;

pub const TypeValidation = enum {
    none,
    if_present,
    required,
};

pub const FunctionDelta = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

/// Minimal OpenAI-compatible streaming tool-call delta shape.
pub const Delta = struct {
    index: ?usize = null,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?FunctionDelta = null,
    /// Optional already-assembled provider metadata copied onto the final
    /// `tool_call` part. The value must outlive the tracker.
    provider_metadata: ?provider.ProviderMetadata = null,
};

const TrackedToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8),
    has_finished: bool,
    provider_metadata: ?provider.ProviderMetadata,

    fn deinit(self: *TrackedToolCall, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }
};

pub const StreamingToolCallTracker = struct {
    gpa: Allocator,
    id_generator: *id_api.IdGenerator,
    type_validation: TypeValidation,
    calls: std.AutoHashMapUnmanaged(usize, TrackedToolCall) = .empty,
    order: std.ArrayList(usize) = .empty,
    output: std.ArrayList(provider.StreamPart) = .empty,
    next_implicit_index: usize = 0,

    pub fn init(gpa: Allocator, id_generator: *id_api.IdGenerator) StreamingToolCallTracker {
        return initWithOptions(gpa, id_generator, .none);
    }

    pub fn initWithOptions(
        gpa: Allocator,
        id_generator: *id_api.IdGenerator,
        type_validation: TypeValidation,
    ) StreamingToolCallTracker {
        return .{
            .gpa = gpa,
            .id_generator = id_generator,
            .type_validation = type_validation,
        };
    }

    pub fn deinit(self: *StreamingToolCallTracker) void {
        var iterator = self.calls.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.calls.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.output.deinit(self.gpa);
        self.* = undefined;
    }

    /// Processes one delta. Returned parts remain valid until the next
    /// `handleDelta`, `flush`, or `deinit` call.
    pub fn handleDelta(
        self: *StreamingToolCallTracker,
        delta: Delta,
        diag: ?*provider.Diagnostics,
    ) (provider.Error || Allocator.Error)![]const provider.StreamPart {
        self.output.clearRetainingCapacity();
        const index = delta.index orelse self.next_implicit_index;

        if (self.calls.getPtr(index)) |tool_call| {
            if (tool_call.has_finished) return self.output.items;
            if (delta.function) |function| {
                if (function.arguments) |arguments| {
                    if (arguments.len == 0) return self.output.items;
                    try tool_call.arguments.appendSlice(self.gpa, arguments);
                    try self.output.append(self.gpa, .{ .tool_input_delta = .{
                        .id = tool_call.id,
                        .delta = tool_call.arguments.items[tool_call.arguments.items.len - arguments.len ..],
                    } });
                }
            }
            return self.output.items;
        }

        try self.validateType(delta, diag);
        const function = delta.function orelse
            return self.invalid(diag, "Expected 'function.name' to be a string.");
        const name = function.name orelse
            return self.invalid(diag, "Expected 'function.name' to be a string.");

        const id = if (delta.id) |value|
            try self.gpa.dupe(u8, value)
        else
            try self.id_generator.nextAlloc(self.gpa);
        errdefer self.gpa.free(id);

        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);

        var arguments: std.ArrayList(u8) = .empty;
        errdefer arguments.deinit(self.gpa);
        if (function.arguments) |initial| try arguments.appendSlice(self.gpa, initial);

        try self.calls.put(self.gpa, index, .{
            .id = id,
            .name = owned_name,
            .arguments = arguments,
            .has_finished = false,
            .provider_metadata = delta.provider_metadata,
        });
        errdefer {
            var removed = self.calls.fetchRemove(index).?.value;
            removed.deinit(self.gpa);
        }
        try self.order.append(self.gpa, index);
        if (index < std.math.maxInt(usize)) {
            self.next_implicit_index = @max(self.next_implicit_index, index + 1);
        }

        const tool_call = self.calls.getPtr(index).?;
        try self.output.append(self.gpa, .{ .tool_input_start = .{
            .id = tool_call.id,
            .tool_name = tool_call.name,
        } });
        if (tool_call.arguments.items.len != 0) {
            try self.output.append(self.gpa, .{ .tool_input_delta = .{
                .id = tool_call.id,
                .delta = tool_call.arguments.items,
            } });
        }
        return self.output.items;
    }

    /// Finalizes every unfinished call in deterministic creation order.
    /// Returned parts remain valid until the next tracker call or `deinit`.
    pub fn flush(self: *StreamingToolCallTracker) Allocator.Error![]const provider.StreamPart {
        self.output.clearRetainingCapacity();
        for (self.order.items) |index| {
            const tool_call = self.calls.getPtr(index).?;
            if (tool_call.has_finished) continue;
            try self.output.append(self.gpa, .{ .tool_input_end = .{
                .id = tool_call.id,
            } });
            try self.output.append(self.gpa, .{ .tool_call = .{
                .tool_call_id = tool_call.id,
                .tool_name = tool_call.name,
                .input = tool_call.arguments.items,
                .provider_metadata = tool_call.provider_metadata,
            } });
            tool_call.has_finished = true;
        }
        return self.output.items;
    }

    fn validateType(
        self: *StreamingToolCallTracker,
        delta: Delta,
        diag: ?*provider.Diagnostics,
    ) provider.Error!void {
        switch (self.type_validation) {
            .none => {},
            .if_present => if (delta.type) |value| {
                if (!std.mem.eql(u8, value, "function"))
                    return self.invalid(diag, "Expected 'function' type.");
            },
            .required => if (delta.type) |value| {
                if (!std.mem.eql(u8, value, "function"))
                    return self.invalid(diag, "Expected 'function' type.");
            } else return self.invalid(diag, "Expected 'function' type."),
        }
    }

    fn invalid(
        self: *StreamingToolCallTracker,
        diag: ?*provider.Diagnostics,
        message: []const u8,
    ) provider.Error {
        provider.Diagnostics.set(diag, if (diag) |value| value.allocator else self.gpa, .{
            .invalid_response_data = .{ .message = message },
        });
        return error.InvalidResponseDataError;
    }
};

fn expectStart(part: provider.StreamPart, id: []const u8, name: []const u8) !void {
    switch (part) {
        .tool_input_start => |value| {
            try std.testing.expectEqualStrings(id, value.id);
            try std.testing.expectEqualStrings(name, value.tool_name);
        },
        else => return error.UnexpectedPart,
    }
}

fn expectDelta(part: provider.StreamPart, id: []const u8, delta: []const u8) !void {
    switch (part) {
        .tool_input_delta => |value| {
            try std.testing.expectEqualStrings(id, value.id);
            try std.testing.expectEqualStrings(delta, value.delta);
        },
        else => return error.UnexpectedPart,
    }
}

fn expectFinished(
    parts: []const provider.StreamPart,
    id: []const u8,
    name: []const u8,
    input: []const u8,
) !void {
    try std.testing.expectEqual(2, parts.len);
    switch (parts[0]) {
        .tool_input_end => |value| try std.testing.expectEqualStrings(id, value.id),
        else => return error.UnexpectedPart,
    }
    switch (parts[1]) {
        .tool_call => |value| {
            try std.testing.expectEqualStrings(id, value.tool_call_id);
            try std.testing.expectEqualStrings(name, value.tool_name);
            try std.testing.expectEqualStrings(input, value.input);
        },
        else => return error.UnexpectedPart,
    }
}

test "tool call tracker accumulates deltas and defers finalization to flush" {
    var generator = try id_api.IdGenerator.init(1, .{ .prefix = "call", .size = 8 }, null);
    var tracker = StreamingToolCallTracker.init(std.testing.allocator, &generator);
    defer tracker.deinit();

    var parts = try tracker.handleDelta(.{
        .index = 0,
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "get_weather", .arguments = "{\"ci" },
    }, null);
    try std.testing.expectEqual(2, parts.len);
    try expectStart(parts[0], "call_1", "get_weather");
    try expectDelta(parts[1], "call_1", "{\"ci");

    parts = try tracker.handleDelta(.{
        .index = 0,
        .function = .{ .arguments = "ty\": \"San" },
    }, null);
    try std.testing.expectEqual(1, parts.len);
    try expectDelta(parts[0], "call_1", "ty\": \"San");

    parts = try tracker.handleDelta(.{
        .index = 0,
        .function = .{ .arguments = " Francisco\"}" },
    }, null);
    try std.testing.expectEqual(1, parts.len);
    try expectDelta(parts[0], "call_1", " Francisco\"}");
    try expectFinished(try tracker.flush(), "call_1", "get_weather", "{\"city\": \"San Francisco\"}");
}

test "tool call tracker does not finalize a parsable prefix" {
    var generator = try id_api.IdGenerator.init(2, .{}, null);
    var tracker = StreamingToolCallTracker.init(std.testing.allocator, &generator);
    defer tracker.deinit();

    const parts = try tracker.handleDelta(.{
        .id = "call_1",
        .function = .{ .name = "search", .arguments = "{\"query\":\"test\"}" },
    }, null);
    try std.testing.expectEqual(2, parts.len);
    _ = try tracker.handleDelta(.{
        .index = 0,
        .function = .{ .arguments = ",\"limit\":10}" },
    }, null);
    try expectFinished(
        try tracker.flush(),
        "call_1",
        "search",
        "{\"query\":\"test\"},\"limit\":10}",
    );
}

test "tool call tracker supports concurrent calls and deterministic flush order" {
    var generator = try id_api.IdGenerator.init(3, .{}, null);
    var tracker = StreamingToolCallTracker.init(std.testing.allocator, &generator);
    defer tracker.deinit();

    _ = try tracker.handleDelta(.{
        .index = 4,
        .id = "call_4",
        .function = .{ .name = "four" },
    }, null);
    _ = try tracker.handleDelta(.{
        .index = 1,
        .id = "call_1",
        .function = .{ .name = "one" },
    }, null);
    const parts = try tracker.flush();
    try std.testing.expectEqual(4, parts.len);
    try std.testing.expectEqualStrings("call_4", parts[0].tool_input_end.id);
    try std.testing.expectEqualStrings("call_1", parts[2].tool_input_end.id);
}

test "tool call tracker assigns implicit indexes after sparse explicit indexes" {
    var generator = try id_api.IdGenerator.init(31, .{ .prefix = "generated" }, null);
    var tracker = StreamingToolCallTracker.init(std.testing.allocator, &generator);
    defer tracker.deinit();

    _ = try tracker.handleDelta(.{
        .index = 4,
        .id = "explicit",
        .function = .{ .name = "first" },
    }, null);
    const implicit = try tracker.handleDelta(.{
        .id = "implicit",
        .function = .{ .name = "second" },
    }, null);
    try std.testing.expectEqual(1, implicit.len);
    try expectStart(implicit[0], "implicit", "second");

    const finished = try tracker.flush();
    try std.testing.expectEqual(4, finished.len);
    try std.testing.expectEqualStrings("explicit", finished[0].tool_input_end.id);
    try std.testing.expectEqualStrings("implicit", finished[2].tool_input_end.id);
}

test "tool call tracker generates an id when the provider omits one" {
    var generator = try id_api.IdGenerator.init(4, .{ .prefix = "generated", .size = 6 }, null);
    var tracker = StreamingToolCallTracker.init(std.testing.allocator, &generator);
    defer tracker.deinit();

    const parts = try tracker.handleDelta(.{
        .function = .{ .name = "fn", .arguments = "{}" },
    }, null);
    try std.testing.expectEqual(2, parts.len);
    const generated = parts[0].tool_input_start.id;
    try std.testing.expect(std.mem.startsWith(u8, generated, "generated-"));
    try expectFinished(try tracker.flush(), generated, "fn", "{}");
}

test "tool call tracker validates name and configured type policy with diagnostics" {
    var generator = try id_api.IdGenerator.init(5, .{}, null);
    var tracker = StreamingToolCallTracker.initWithOptions(
        std.testing.allocator,
        &generator,
        .required,
    );
    defer tracker.deinit();
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(error.InvalidResponseDataError, tracker.handleDelta(.{
        .id = "call_1",
        .function = .{ .name = "fn" },
    }, &diagnostics));
    try std.testing.expectEqualStrings(
        "Expected 'function' type.",
        diagnostics.payload.invalid_response_data.message,
    );

    tracker.type_validation = .none;
    try std.testing.expectError(error.InvalidResponseDataError, tracker.handleDelta(.{
        .id = "call_1",
        .function = .{},
    }, &diagnostics));
    try std.testing.expectEqualStrings(
        "Expected 'function.name' to be a string.",
        diagnostics.payload.invalid_response_data.message,
    );
}

test "tool call tracker ignores null, empty, and late deltas" {
    var generator = try id_api.IdGenerator.init(6, .{}, null);
    var tracker = StreamingToolCallTracker.init(std.testing.allocator, &generator);
    defer tracker.deinit();

    _ = try tracker.handleDelta(.{
        .index = 0,
        .id = "call_1",
        .function = .{ .name = "fn", .arguments = "{}" },
    }, null);
    try std.testing.expectEqual(0, (try tracker.handleDelta(.{
        .index = 0,
        .function = .{ .arguments = null },
    }, null)).len);
    _ = try tracker.flush();
    try std.testing.expectEqual(0, (try tracker.handleDelta(.{
        .index = 0,
        .function = .{ .arguments = "late" },
    }, null)).len);
    try std.testing.expectEqual(0, (try tracker.flush()).len);
}
