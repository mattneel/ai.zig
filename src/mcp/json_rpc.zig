//! Strict JSON-RPC 2.0 envelope parsing for MCP.
//!
//! MCP payloads are intentionally parsed loosely in `types.zig`; only the
//! protocol envelope rejects unknown top-level fields, matching upstream's
//! `.strict()` JSON-RPC schemas.

const std = @import("std");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const version = "2.0";

pub const Id = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .string => |value| b == .string and std.mem.eql(u8, value, b.string),
            .integer => |value| b == .integer and value == b.integer,
        };
    }

    pub fn asInteger(self: Id) ?i64 {
        return switch (self) {
            .integer => |value| value,
            .string => null,
        };
    }
};

pub const Request = struct {
    id: Id,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Notification = struct {
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Response = struct {
    id: Id,
    result: std.json.Value,
};

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const ErrorResponse = struct {
    id: Id,
    error_object: ErrorObject,
};

pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    error_response: ErrorResponse,

    pub fn hasId(self: Message) bool {
        return self != .notification;
    }

    pub fn id(self: Message) ?Id {
        return switch (self) {
            .request => |value| value.id,
            .notification => null,
            .response => |value| value.id,
            .error_response => |value| value.id,
        };
    }
};

pub const ParseError = Allocator.Error || error{
    InvalidJson,
    InvalidMessage,
    UnknownField,
};

pub fn parse(arena: Allocator, text: []const u8) ParseError!Message {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return validate(value);
}

pub fn validate(value: std.json.Value) ParseError!Message {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidMessage,
    };

    const jsonrpc = object.get("jsonrpc") orelse return error.InvalidMessage;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, version)) {
        return error.InvalidMessage;
    }

    const method_value = object.get("method");
    const id_value = object.get("id");
    const result_value = object.get("result");
    const error_value = object.get("error");

    if (method_value) |method_json| {
        if (result_value != null or error_value != null) return error.InvalidMessage;
        if (method_json != .string) return error.InvalidMessage;
        const params = object.get("params");
        if (params) |item| if (item != .object) return error.InvalidMessage;

        if (id_value) |id_json| {
            try rejectUnknownFields(object, &.{ "jsonrpc", "id", "method", "params" });
            return .{ .request = .{
                .id = try parseId(id_json),
                .method = method_json.string,
                .params = params,
            } };
        }

        try rejectUnknownFields(object, &.{ "jsonrpc", "method", "params" });
        return .{ .notification = .{
            .method = method_json.string,
            .params = params,
        } };
    }

    const id_json = id_value orelse return error.InvalidMessage;
    const id = try parseId(id_json);
    if (result_value) |result| {
        if (error_value != null) return error.InvalidMessage;
        try rejectUnknownFields(object, &.{ "jsonrpc", "id", "result" });
        return .{ .response = .{ .id = id, .result = result } };
    }

    const error_json = error_value orelse return error.InvalidMessage;
    try rejectUnknownFields(object, &.{ "jsonrpc", "id", "error" });
    const error_object = switch (error_json) {
        .object => |item| item,
        else => return error.InvalidMessage,
    };
    const code = error_object.get("code") orelse return error.InvalidMessage;
    const message = error_object.get("message") orelse return error.InvalidMessage;
    if (code != .integer or message != .string) return error.InvalidMessage;
    return .{ .error_response = .{
        .id = id,
        .error_object = .{
            .code = code.integer,
            .message = message.string,
            .data = error_object.get("data"),
        },
    } };
}

pub fn serialize(arena: Allocator, message: Message) Allocator.Error![]u8 {
    return provider_utils.stringifyJsonValueAlloc(arena, try toValue(arena, message));
}

pub fn toValue(arena: Allocator, message: Message) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "jsonrpc", .{ .string = version });
    switch (message) {
        .request => |request| {
            try object.put(arena, "id", idValue(request.id));
            try object.put(arena, "method", .{ .string = request.method });
            if (request.params) |params| {
                try object.put(arena, "params", try provider_utils.cloneJsonValue(arena, params));
            }
        },
        .notification => |notification| {
            try object.put(arena, "method", .{ .string = notification.method });
            if (notification.params) |params| {
                try object.put(arena, "params", try provider_utils.cloneJsonValue(arena, params));
            }
        },
        .response => |response| {
            try object.put(arena, "id", idValue(response.id));
            try object.put(arena, "result", try provider_utils.cloneJsonValue(arena, response.result));
        },
        .error_response => |response| {
            try object.put(arena, "id", idValue(response.id));
            var error_object: std.json.ObjectMap = .empty;
            try error_object.put(arena, "code", .{ .integer = response.error_object.code });
            try error_object.put(arena, "message", .{ .string = response.error_object.message });
            if (response.error_object.data) |data| {
                try error_object.put(arena, "data", try provider_utils.cloneJsonValue(arena, data));
            }
            try object.put(arena, "error", .{ .object = error_object });
        },
    }
    return .{ .object = object };
}

fn parseId(value: std.json.Value) error{InvalidMessage}!Id {
    return switch (value) {
        .string => |item| .{ .string = item },
        .integer => |item| .{ .integer = item },
        else => error.InvalidMessage,
    };
}

fn idValue(id: Id) std.json.Value {
    return switch (id) {
        .string => |value| .{ .string = value },
        .integer => |value| .{ .integer = value },
    };
}

fn rejectUnknownFields(object: std.json.ObjectMap, allowed: []const []const u8) error{UnknownField}!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.UnknownField;
    }
}

test "strict JSON-RPC request, notification, response, and error parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = try parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}");
    try std.testing.expect(request == .request);
    try std.testing.expectEqual(1, request.request.id.integer);
    try std.testing.expectEqualStrings("tools/list", request.request.method);

    const notification = try parse(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try std.testing.expect(notification == .notification);

    const response = try parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{\"tools\":[]}}");
    try std.testing.expect(response == .response);
    try std.testing.expectEqualStrings("a", response.response.id.string);

    const rpc_error = try parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"missing\",\"data\":{\"x\":1}}}");
    try std.testing.expect(rpc_error == .error_response);
    try std.testing.expectEqual(-32601, rpc_error.error_response.error_object.code);
}

test "strict JSON-RPC envelope rejects invalid versions, ids, mixtures, and extra fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidMessage, parse(arena, "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}"));
    try std.testing.expectError(error.InvalidMessage, parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":{}}"));
    try std.testing.expectError(error.InvalidMessage, parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"result\":{}}"));
    try std.testing.expectError(error.UnknownField, parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"extra\":true}"));
    try std.testing.expectError(error.InvalidMessage, parse(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":[]}"));
}

test "JSON-RPC serialization round trips every envelope variant" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]Message{
        .{ .request = .{ .id = .{ .integer = 7 }, .method = "ping" } },
        .{ .notification = .{ .method = "notifications/initialized" } },
        .{ .response = .{ .id = .{ .string = "x" }, .result = .{ .object = .empty } } },
        .{ .error_response = .{ .id = .{ .integer = 8 }, .error_object = .{ .code = -32601, .message = "missing" } } },
    };
    for (messages) |message| {
        const reparsed = try parse(arena, try serialize(arena, message));
        try std.testing.expectEqual(std.meta.activeTag(message), std.meta.activeTag(reparsed));
    }
}
