const std = @import("std");
const base64 = @import("base64.zig");

const Allocator = std.mem.Allocator;

pub const Data = union(enum) {
    bytes: []const u8,
    base64: []const u8,
};

const Signature = struct {
    media_type: []const u8,
    prefix: []const ?u8,
};

const image_signatures = [_]Signature{
    .{ .media_type = "image/gif", .prefix = &.{ 0x47, 0x49, 0x46 } },
    .{ .media_type = "image/png", .prefix = &.{ 0x89, 0x50, 0x4e, 0x47 } },
    .{ .media_type = "image/jpeg", .prefix = &.{ 0xff, 0xd8 } },
    .{ .media_type = "image/webp", .prefix = &.{ 0x52, 0x49, 0x46, 0x46, null, null, null, null, 0x57, 0x45, 0x42, 0x50 } },
    .{ .media_type = "image/bmp", .prefix = &.{ 0x42, 0x4d } },
    .{ .media_type = "image/tiff", .prefix = &.{ 0x49, 0x49, 0x2a, 0x00 } },
    .{ .media_type = "image/tiff", .prefix = &.{ 0x4d, 0x4d, 0x00, 0x2a } },
    .{ .media_type = "image/avif", .prefix = &.{ 0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66 } },
    .{ .media_type = "image/heic", .prefix = &.{ 0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63 } },
};

const document_signatures = [_]Signature{
    .{ .media_type = "application/pdf", .prefix = &.{ 0x25, 0x50, 0x44, 0x46 } },
};

const audio_signatures = [_]Signature{
    .{ .media_type = "audio/mpeg", .prefix = &.{ 0xff, 0xfb } },
    .{ .media_type = "audio/mpeg", .prefix = &.{ 0xff, 0xfa } },
    .{ .media_type = "audio/mpeg", .prefix = &.{ 0xff, 0xf3 } },
    .{ .media_type = "audio/mpeg", .prefix = &.{ 0xff, 0xf2 } },
    .{ .media_type = "audio/mpeg", .prefix = &.{ 0xff, 0xe3 } },
    .{ .media_type = "audio/mpeg", .prefix = &.{ 0xff, 0xe2 } },
    .{ .media_type = "audio/wav", .prefix = &.{ 0x52, 0x49, 0x46, 0x46, null, null, null, null, 0x57, 0x41, 0x56, 0x45 } },
    .{ .media_type = "audio/ogg", .prefix = &.{ 0x4f, 0x67, 0x67, 0x53 } },
    .{ .media_type = "audio/flac", .prefix = &.{ 0x66, 0x4c, 0x61, 0x43 } },
    .{ .media_type = "audio/aac", .prefix = &.{ 0x40, 0x15, 0x00, 0x00 } },
    .{ .media_type = "audio/mp4", .prefix = &.{ 0x66, 0x74, 0x79, 0x70 } },
    .{ .media_type = "audio/webm", .prefix = &.{ 0x1a, 0x45, 0xdf, 0xa3 } },
};

const video_signatures = [_]Signature{
    .{ .media_type = "video/mp4", .prefix = &.{ 0x00, 0x00, 0x00, null, 0x66, 0x74, 0x79, 0x70 } },
    .{ .media_type = "video/webm", .prefix = &.{ 0x1a, 0x45, 0xdf, 0xa3 } },
    .{ .media_type = "video/quicktime", .prefix = &.{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74 } },
    .{ .media_type = "video/x-msvideo", .prefix = &.{ 0x52, 0x49, 0x46, 0x46 } },
};

pub fn detectMediaType(
    arena: Allocator,
    data: Data,
    top_level_type: ?[]const u8,
) (Allocator.Error || std.base64.Error)!?[]const u8 {
    var bytes = switch (data) {
        .bytes => |value| value,
        .base64 => |value| blk: {
            const encoded = if (std.mem.startsWith(u8, value, "SUQz"))
                value
            else
                value[0..@min(value.len, 24)];
            break :blk base64.decode(arena, encoded) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
    };
    bytes = stripId3(bytes);

    if (top_level_type) |top_level| {
        if (std.mem.eql(u8, top_level, "image")) return detect(bytes, &image_signatures);
        if (std.mem.eql(u8, top_level, "audio")) return detect(bytes, &audio_signatures);
        if (std.mem.eql(u8, top_level, "video")) return detect(bytes, &video_signatures);
        if (std.mem.eql(u8, top_level, "application")) return detect(bytes, &document_signatures);
        return null;
    }

    return detect(bytes, &image_signatures) orelse
        detect(bytes, &document_signatures) orelse
        detect(bytes, &audio_signatures) orelse
        detect(bytes, &video_signatures);
}

pub fn getTopLevelMediaType(media_type: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, media_type, '/') orelse return media_type;
    return media_type[0..slash];
}

pub fn isFullMediaType(media_type: []const u8) bool {
    const slash = std.mem.findScalar(u8, media_type, '/') orelse return false;
    const subtype = media_type[slash + 1 ..];
    return subtype.len != 0 and !std.mem.eql(u8, subtype, "*");
}

fn detect(bytes: []const u8, signatures: []const Signature) ?[]const u8 {
    for (signatures) |signature| {
        if (bytes.len < signature.prefix.len) continue;
        var matches = true;
        for (signature.prefix, 0..) |expected, index| {
            if (expected) |value| {
                if (bytes[index] != value) {
                    matches = false;
                    break;
                }
            }
        }
        if (matches) return signature.media_type;
    }
    return null;
}

fn stripId3(bytes: []const u8) []const u8 {
    if (bytes.len <= 10 or !std.mem.eql(u8, bytes[0..3], "ID3")) return bytes;
    const size = (@as(usize, bytes[6] & 0x7f) << 21) |
        (@as(usize, bytes[7] & 0x7f) << 14) |
        (@as(usize, bytes[8] & 0x7f) << 7) |
        @as(usize, bytes[9] & 0x7f);
    const start = std.math.add(usize, size, 10) catch return &.{};
    if (start > bytes.len) return &.{};
    return bytes[start..];
}

test "media type representative signature table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        bytes: []const u8,
        top: []const u8,
        expected: []const u8,
    }{
        .{ .bytes = "GIF89", .top = "image", .expected = "image/gif" },
        .{ .bytes = &.{ 0x89, 0x50, 0x4e, 0x47 }, .top = "image", .expected = "image/png" },
        .{ .bytes = &.{ 0xff, 0xd8 }, .top = "image", .expected = "image/jpeg" },
        .{ .bytes = &.{ 0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50 }, .top = "image", .expected = "image/webp" },
        .{ .bytes = "BM", .top = "image", .expected = "image/bmp" },
        .{ .bytes = &.{ 0x49, 0x49, 0x2a, 0x00 }, .top = "image", .expected = "image/tiff" },
        .{ .bytes = &.{ 0x4d, 0x4d, 0x00, 0x2a }, .top = "image", .expected = "image/tiff" },
        .{ .bytes = &.{ 0xff, 0xfb }, .top = "audio", .expected = "audio/mpeg" },
        .{ .bytes = "OggS", .top = "audio", .expected = "audio/ogg" },
        .{ .bytes = "fLaC", .top = "audio", .expected = "audio/flac" },
        .{ .bytes = &.{ 0x1a, 0x45, 0xdf, 0xa3 }, .top = "video", .expected = "video/webm" },
        .{ .bytes = "%PDF", .top = "application", .expected = "application/pdf" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(
            case.expected,
            (try detectMediaType(arena, .{ .bytes = case.bytes }, case.top)).?,
        );
    }

    try std.testing.expectEqualStrings(
        "image/png",
        (try detectMediaType(arena, .{ .base64 = "iVBORw==" }, "image")).?,
    );
    try std.testing.expectEqual(null, try detectMediaType(arena, .{ .bytes = "GIF89" }, "audio"));
}

test "media type strips ID3v2 syncsafe length" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const tagged = [_]u8{
        'I', 'D', '3',  3,    0, 0, 0, 0, 0, 2,
        0,   0,   0xff, 0xfb,
    };
    try std.testing.expectEqualStrings(
        "audio/mpeg",
        (try detectMediaType(arena_state.allocator(), .{ .bytes = &tagged }, "audio")).?,
    );
}
