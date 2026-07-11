const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DecodeError = Allocator.Error || std.base64.Error;

/// Decodes padded or unpadded standard/base64url input.
pub fn decode(arena: Allocator, encoded: []const u8) DecodeError![]u8 {
    if (encoded.len % 4 == 1) return error.InvalidPadding;

    const padding = (4 - encoded.len % 4) % 4;
    const normalized = try arena.alloc(u8, encoded.len + padding);
    for (encoded, normalized[0..encoded.len]) |source, *destination| {
        destination.* = switch (source) {
            '-' => '+',
            '_' => '/',
            else => source,
        };
    }
    @memset(normalized[encoded.len..], '=');

    const size = try std.base64.standard.Decoder.calcSizeForSlice(normalized);
    const result = try arena.alloc(u8, size);
    try std.base64.standard.Decoder.decode(result, normalized);
    return result;
}

pub fn encode(arena: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const result = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(result, bytes);
    return result;
}

test "base64 standard and url-safe round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("hello?", try decode(arena, "aGVsbG8/"));
    try std.testing.expectEqualStrings("hello?", try decode(arena, "aGVsbG8_"));
    try std.testing.expectEqualStrings("hello", try decode(arena, "aGVsbG8"));
    try std.testing.expectEqualStrings("aGVsbG8/", try encode(arena, "hello?"));
}
