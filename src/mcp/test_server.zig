//! Real child-process MCP echo server used by ungated stdio integration tests.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var read_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &read_buffer);
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();

    while (true) {
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };
        const delimiter_found = if (reader.interface.takeByte()) |byte| blk: {
            std.debug.assert(byte == '\n');
            break :blk true;
        } else |err| switch (err) {
            error.EndOfStream => false,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!delimiter_found) return;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const input = std.json.parseFromSliceLeaky(std.json.Value, arena, line.written(), .{}) catch continue;
        if (input != .object) continue;
        const method_value = input.object.get("method") orelse continue;
        if (method_value != .string) continue;
        const id = input.object.get("id");
        if (id == null) continue;
        const method = method_value.string;

        if (std.mem.eql(u8, method, "initialize")) {
            try writeResult(io, arena, id.?, try initializeResult(arena));
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try writeResult(io, arena, id.?, try toolsResult(arena));
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const params = input.object.get("params") orelse continue;
            if (params != .object) continue;
            const name_value = params.object.get("name") orelse continue;
            if (name_value != .string) continue;
            if (std.mem.eql(u8, name_value.string, "hang")) continue;
            const arguments = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
            try writeResult(io, arena, id.?, try callToolResult(arena, arguments));
        } else if (std.mem.eql(u8, method, "ping")) {
            try writeResult(io, arena, id.?, .{ .object = .empty });
        } else {
            try writeError(io, arena, id.?, -32601, "method not found");
        }
    }
}

fn initializeResult(arena: std.mem.Allocator) !std.json.Value {
    var capabilities: std.json.ObjectMap = .empty;
    try capabilities.put(arena, "tools", .{ .object = .empty });
    var server_info: std.json.ObjectMap = .empty;
    try server_info.put(arena, "name", .{ .string = "ai.zig-test-mcp-echo" });
    try server_info.put(arena, "version", .{ .string = "1.0.0" });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "protocolVersion", .{ .string = "2025-11-25" });
    try result.put(arena, "capabilities", .{ .object = capabilities });
    try result.put(arena, "serverInfo", .{ .object = server_info });
    try result.put(arena, "instructions", .{ .string = "Echo tool test server" });
    return .{ .object = result };
}

fn toolsResult(arena: std.mem.Allocator) !std.json.Value {
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "value", .{ .object = .empty });
    var input_schema: std.json.ObjectMap = .empty;
    try input_schema.put(arena, "type", .{ .string = "object" });
    try input_schema.put(arena, "properties", .{ .object = properties });

    var meta: std.json.ObjectMap = .empty;
    try meta.put(arena, "test/server", .{ .bool = true });
    var tool: std.json.ObjectMap = .empty;
    try tool.put(arena, "name", .{ .string = "echo" });
    try tool.put(arena, "title", .{ .string = "Echo" });
    try tool.put(arena, "description", .{ .string = "Returns its arguments" });
    try tool.put(arena, "inputSchema", .{ .object = input_schema });
    try tool.put(arena, "_meta", .{ .object = meta });
    var tools = std.json.Array.init(arena);
    try tools.append(.{ .object = tool });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "tools", .{ .array = tools });
    return .{ .object = result };
}

fn callToolResult(arena: std.mem.Allocator, arguments: std.json.Value) !std.json.Value {
    const text = try stringify(arena, arguments);
    var part: std.json.ObjectMap = .empty;
    try part.put(arena, "type", .{ .string = "text" });
    try part.put(arena, "text", .{ .string = text });
    var content = std.json.Array.init(arena);
    try content.append(.{ .object = part });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "content", .{ .array = content });
    try result.put(arena, "structuredContent", arguments);
    try result.put(arena, "isError", .{ .bool = false });
    return .{ .object = result };
}

fn writeResult(io: std.Io, arena: std.mem.Allocator, id: std.json.Value, result: std.json.Value) !void {
    var envelope: std.json.ObjectMap = .empty;
    try envelope.put(arena, "jsonrpc", .{ .string = "2.0" });
    try envelope.put(arena, "id", id);
    try envelope.put(arena, "result", result);
    try writeValue(io, arena, .{ .object = envelope });
}

fn writeError(io: std.Io, arena: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) !void {
    var rpc_error: std.json.ObjectMap = .empty;
    try rpc_error.put(arena, "code", .{ .integer = code });
    try rpc_error.put(arena, "message", .{ .string = message });
    var envelope: std.json.ObjectMap = .empty;
    try envelope.put(arena, "jsonrpc", .{ .string = "2.0" });
    try envelope.put(arena, "id", id);
    try envelope.put(arena, "error", .{ .object = rpc_error });
    try writeValue(io, arena, .{ .object = envelope });
}

fn writeValue(io: std.Io, arena: std.mem.Allocator, value: std.json.Value) !void {
    const encoded = try stringify(arena, value);
    try std.Io.File.stdout().writeStreamingAll(io, encoded);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn stringify(arena: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}
