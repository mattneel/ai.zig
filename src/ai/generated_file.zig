//! Lazy dual-representation generated media files.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const GeneratedFile = struct {
    media_type: []const u8,
    base64_data: ?[]const u8,
    bytes_data: ?[]const u8,

    pub fn init(data: provider.BinaryData, media_type: []const u8) GeneratedFile {
        return switch (data) {
            .bytes => |value| initBytes(value, media_type),
            .base64 => |value| initBase64(value, media_type),
        };
    }

    pub fn initBytes(value: []const u8, media_type: []const u8) GeneratedFile {
        return .{
            .media_type = media_type,
            .base64_data = null,
            .bytes_data = value,
        };
    }

    pub fn initBase64(value: []const u8, media_type: []const u8) GeneratedFile {
        return .{
            .media_type = media_type,
            .base64_data = value,
            .bytes_data = null,
        };
    }

    /// Returns bytes, decoding and caching them in the owning result arena on
    /// first access when this file arrived as base64.
    pub fn bytes(
        self: *GeneratedFile,
        arena: Allocator,
    ) provider_utils.base64.DecodeError![]const u8 {
        if (self.bytes_data == null) {
            self.bytes_data = try provider_utils.decodeBase64(arena, self.base64_data.?);
        }
        return self.bytes_data.?;
    }

    /// Returns base64, encoding and caching it in the owning result arena on
    /// first access when this file arrived as bytes.
    pub fn base64(self: *GeneratedFile, arena: Allocator) Allocator.Error![]const u8 {
        if (self.base64_data == null) {
            self.base64_data = try provider_utils.encodeBase64(arena, self.bytes_data.?);
        }
        return self.base64_data.?;
    }
};

pub const GeneratedAudioFile = struct {
    file: GeneratedFile,
    media_type: []const u8,
    format: []const u8,

    pub fn init(data: provider.BinaryData, media_type: []const u8) GeneratedAudioFile {
        return .{
            .file = GeneratedFile.init(data, media_type),
            .media_type = media_type,
            .format = formatFromMediaType(media_type),
        };
    }

    pub fn initBytes(value: []const u8, media_type: []const u8) GeneratedAudioFile {
        return init(.{ .bytes = value }, media_type);
    }

    pub fn initBase64(value: []const u8, media_type: []const u8) GeneratedAudioFile {
        return init(.{ .base64 = value }, media_type);
    }

    pub fn bytes(
        self: *GeneratedAudioFile,
        arena: Allocator,
    ) provider_utils.base64.DecodeError![]const u8 {
        return self.file.bytes(arena);
    }

    pub fn base64(self: *GeneratedAudioFile, arena: Allocator) Allocator.Error![]const u8 {
        return self.file.base64(arena);
    }
};

fn formatFromMediaType(media_type: []const u8) []const u8 {
    if (std.mem.eql(u8, media_type, "audio/mpeg")) return "mp3";
    const slash = std.mem.indexOfScalar(u8, media_type, '/') orelse return "mp3";
    const subtype = media_type[slash + 1 ..];
    return if (subtype.len == 0) "mp3" else subtype;
}

test "GeneratedFile lazily decodes base64 once into the result arena" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file = GeneratedFile.initBase64("AAFB/w==", "application/octet-stream");
    try std.testing.expect(file.bytes_data == null);
    try std.testing.expectEqualStrings("AAFB/w==", file.base64_data.?);

    const first = try file.bytes(arena);
    const second = try file.bytes(arena);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x41, 0xff }, first);
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqual(first.ptr, file.bytes_data.?.ptr);
}

test "GeneratedFile lazily encodes bytes once into the result arena" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file = GeneratedFile.init(.{ .bytes = "hello" }, "text/plain");
    try std.testing.expect(file.base64_data == null);
    try std.testing.expectEqualStrings("hello", file.bytes_data.?);

    const first = try file.base64(arena);
    const second = try file.base64(arena);
    try std.testing.expectEqualStrings("aGVsbG8=", first);
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqual(first.ptr, file.base64_data.?.ptr);
}

test "GeneratedAudioFile derives format and delegates lazy representations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var mp3 = GeneratedAudioFile.initBase64("aGk=", "audio/mpeg");
    try std.testing.expectEqualStrings("mp3", mp3.format);
    try std.testing.expectEqualStrings("audio/mpeg", mp3.media_type);
    try std.testing.expectEqualStrings("hi", try mp3.bytes(arena));

    var wav = GeneratedAudioFile.initBytes("RIFF", "audio/x-wav");
    try std.testing.expectEqualStrings("x-wav", wav.format);
    try std.testing.expectEqualStrings("UklGRg==", try wav.base64(arena));
}
