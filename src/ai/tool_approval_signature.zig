//! HMAC-SHA256 signing for replayed tool approvals.
//!
//! Upstream does not create or retain a process-global secret. Signing is
//! enabled only when the caller supplies `tool_approval_secret`; omitting it
//! preserves the unsigned approval flow.

const std = @import("std");

const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn sign(
    arena: Allocator,
    secret: []const u8,
    approval_id: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: std.json.Value,
) Allocator.Error![]const u8 {
    const digest = try canonicalDigestBase64Url(arena, input);
    const payload = try std.fmt.allocPrint(
        arena,
        "{s}\n{s}\n{s}\n{s}",
        .{ approval_id, tool_call_id, tool_name, digest },
    );
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload, secret);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(mac.len));
    return encoder.encode(encoded, &mac);
}

pub fn verify(
    arena: Allocator,
    secret: []const u8,
    signature: []const u8,
    approval_id: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    input: std.json.Value,
) Allocator.Error!bool {
    const expected = try sign(
        arena,
        secret,
        approval_id,
        tool_call_id,
        tool_name,
        input,
    );
    if (expected.len != signature.len) return false;
    var expected_array: [43]u8 = undefined;
    var actual_array: [43]u8 = undefined;
    if (expected.len != expected_array.len) return false;
    @memcpy(&expected_array, expected);
    @memcpy(&actual_array, signature);
    return std.crypto.timing_safe.eql([43]u8, expected_array, actual_array);
}

fn canonicalDigestBase64Url(arena: Allocator, value: std.json.Value) Allocator.Error![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    writeCanonical(arena, &output.writer, value) catch return error.OutOfMemory;
    const canonical = try output.toOwnedSlice();
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(canonical, &digest, .{});
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(digest.len));
    return encoder.encode(encoded, &digest);
}

fn writeCanonical(
    arena: Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
) std.Io.Writer.Error!void {
    switch (value) {
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonical(arena, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            const keys = arena.alloc([]const u8, object.count()) catch return error.WriteFailed;
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            try writer.writeByte('{');
            for (keys, 0..) |key, key_index| {
                if (key_index != 0) try writer.writeByte(',');
                try std.json.Stringify.value(std.json.Value{ .string = key }, .{}, writer);
                try writer.writeByte(':');
                try writeCanonical(arena, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

test "approval signatures verify and canonicalize object key order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var first_object: std.json.ObjectMap = .empty;
    try first_object.put(arena, "path", .{ .string = "/tmp/cache" });
    try first_object.put(arena, "mode", .{ .string = "delete" });
    var second_object: std.json.ObjectMap = .empty;
    try second_object.put(arena, "mode", .{ .string = "delete" });
    try second_object.put(arena, "path", .{ .string = "/tmp/cache" });

    const first = try sign(
        arena,
        "test-secret-key-for-hmac-signing",
        "approval-1",
        "call-1",
        "deleteFile",
        .{ .object = first_object },
    );
    const second = try sign(
        arena,
        "test-secret-key-for-hmac-signing",
        "approval-1",
        "call-1",
        "deleteFile",
        .{ .object = second_object },
    );
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(try verify(
        arena,
        "test-secret-key-for-hmac-signing",
        first,
        "approval-1",
        "call-1",
        "deleteFile",
        .{ .object = first_object },
    ));
    try std.testing.expect(!try verify(
        arena,
        "different-secret",
        first,
        "approval-1",
        "call-1",
        "deleteFile",
        .{ .object = first_object },
    ));
}
