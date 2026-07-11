//! Shared media input normalization and result metadata helpers.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

/// Zig spelling of provider-utils `DataContent`: string values are either an
/// HTTP/data URL or base64, while byte slices are already decoded media.
pub const DataContent = union(enum) {
    string: []const u8,
    bytes: []const u8,
};

pub fn normalizeImageFile(
    arena: Allocator,
    content: DataContent,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.ImageFile {
    return switch (content) {
        .bytes => |bytes| imageBytes(arena, bytes, null),
        .string => |value| blk: {
            if (std.mem.startsWith(u8, value, "http")) {
                break :blk .{ .url = .{ .url = try arena.dupe(u8, value) } };
            }
            const parsed = if (std.mem.startsWith(u8, value, "data:"))
                try decodeDataUrl(arena, value, diag)
            else
                Decoded{ .bytes = try decodeBase64(arena, value, diag) };
            break :blk imageBytes(arena, parsed.bytes, parsed.media_type);
        },
    };
}

pub fn normalizeVideoFile(
    arena: Allocator,
    content: DataContent,
    restrict_to_images: bool,
    media_type_override: ?[]const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.VideoFile {
    return switch (content) {
        .bytes => |bytes| videoBytes(
            arena,
            bytes,
            restrict_to_images,
            media_type_override,
        ),
        .string => |value| blk: {
            if (std.mem.startsWith(u8, value, "http://") or
                std.mem.startsWith(u8, value, "https://"))
            {
                break :blk .{ .url = .{
                    .url = try arena.dupe(u8, value),
                    .media_type = if (media_type_override) |media_type|
                        try arena.dupe(u8, media_type)
                    else
                        null,
                } };
            }
            const parsed = if (std.mem.startsWith(u8, value, "data:"))
                try decodeDataUrl(arena, value, diag)
            else
                Decoded{ .bytes = try decodeBase64(arena, value, diag) };
            break :blk videoBytes(
                arena,
                parsed.bytes,
                restrict_to_images,
                media_type_override orelse parsed.media_type,
            );
        },
    };
}

pub fn binaryBytes(
    arena: Allocator,
    data: provider.BinaryData,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)![]const u8 {
    return switch (data) {
        .bytes => |bytes| try arena.dupe(u8, bytes),
        .base64 => |encoded| try decodeBase64(arena, encoded, diag),
    };
}

pub fn cloneWarning(arena: Allocator, warning: provider.Warning) Allocator.Error!provider.Warning {
    return switch (warning) {
        .unsupported => |value| .{ .unsupported = .{
            .feature = try arena.dupe(u8, value.feature),
            .details = if (value.details) |details| try arena.dupe(u8, details) else null,
        } },
        .compatibility => |value| .{ .compatibility = .{
            .feature = try arena.dupe(u8, value.feature),
            .details = if (value.details) |details| try arena.dupe(u8, details) else null,
        } },
        .deprecated => |value| .{ .deprecated = .{
            .setting = try arena.dupe(u8, value.setting),
            .message = try arena.dupe(u8, value.message),
        } },
        .other => |value| .{ .other = .{ .message = try arena.dupe(u8, value.message) } },
    };
}

pub fn cloneHeaders(arena: Allocator, headers: ?provider.Headers) Allocator.Error!?provider.Headers {
    const values = headers orelse return null;
    const copy = try arena.alloc(provider.Header, values.len);
    for (values, copy) |source, *destination| destination.* = .{
        .name = try arena.dupe(u8, source.name),
        .value = try arena.dupe(u8, source.value),
    };
    return copy;
}

/// Merges per-provider metadata and concatenates the named media array. Other
/// fields retain their first value unless a later call provides the same key,
/// in which case the later value wins, matching object spread semantics.
pub fn mergeProviderMetadata(
    arena: Allocator,
    destination: *std.json.Value,
    incoming: ?provider.ProviderMetadata,
    media_array_key: []const u8,
) Allocator.Error!void {
    const source = incoming orelse return;
    if (source != .object) {
        destination.* = try provider_utils.cloneJsonValue(arena, source);
        return;
    }
    if (destination.* != .object) destination.* = .{ .object = .empty };

    var providers = source.object.iterator();
    while (providers.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const metadata = entry.value_ptr.*;
        const current = destination.object.getPtr(provider_name) orelse {
            try destination.object.put(
                arena,
                try arena.dupe(u8, provider_name),
                try provider_utils.cloneJsonValue(arena, metadata),
            );
            continue;
        };
        if (current.* != .object or metadata != .object) {
            current.* = try provider_utils.cloneJsonValue(arena, metadata);
            continue;
        }

        var fields = metadata.object.iterator();
        while (fields.next()) |field| {
            const name = field.key_ptr.*;
            const value = field.value_ptr.*;
            if (std.mem.eql(u8, name, media_array_key) and value == .array) {
                if (current.object.getPtr(name)) |existing| {
                    if (existing.* == .array) {
                        for (value.array.items) |item| {
                            try existing.array.append(try provider_utils.cloneJsonValue(arena, item));
                        }
                        continue;
                    }
                }
            }
            try current.object.put(
                arena,
                try arena.dupe(u8, name),
                try provider_utils.cloneJsonValue(arena, value),
            );
        }
    }
}

/// ImageModel V4 metadata has the stricter `{ provider: { images: [...] } }`
/// shape. With the gateway package intentionally absent, every provider uses
/// the same append-only images merge and non-image sibling fields are ignored.
pub fn mergeImageProviderMetadata(
    arena: Allocator,
    destination: *std.json.Value,
    incoming: ?provider.ProviderMetadata,
) Allocator.Error!void {
    const source = incoming orelse return;
    if (source != .object) return;
    if (destination.* != .object) destination.* = .{ .object = .empty };

    var providers = source.object.iterator();
    while (providers.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const metadata = entry.value_ptr.*;
        const current = destination.object.getPtr(provider_name) orelse blk: {
            const images = std.json.Array.init(arena);
            var provider_value: std.json.ObjectMap = .empty;
            try provider_value.put(arena, "images", .{ .array = images });
            try destination.object.put(
                arena,
                try arena.dupe(u8, provider_name),
                .{ .object = provider_value },
            );
            break :blk destination.object.getPtr(provider_name).?;
        };
        if (current.* != .object) continue;
        const source_images = if (metadata == .object) metadata.object.get("images") else null;
        if (source_images == null or source_images.? != .array) continue;
        const current_images = current.object.getPtr("images").?;
        for (source_images.?.array.items) |item| {
            try current_images.array.append(try provider_utils.cloneJsonValue(arena, item));
        }
    }
}

pub fn copyDiagnostics(destination: ?*provider.Diagnostics, source: *const provider.Diagnostics) void {
    if (destination == null or !source.available) return;
    provider.Diagnostics.set(destination, destination.?.allocator, source.payload);
}

fn imageBytes(arena: Allocator, bytes: []const u8, explicit_media_type: ?[]const u8) Allocator.Error!provider.ImageFile {
    const media_type = explicit_media_type orelse
        (provider_utils.detectMediaType(arena, .{ .bytes = bytes }, "image") catch null) orelse
        "image/png";
    return .{ .file = .{
        .media_type = try arena.dupe(u8, media_type),
        .data = .{ .bytes = try arena.dupe(u8, bytes) },
    } };
}

fn videoBytes(
    arena: Allocator,
    bytes: []const u8,
    restrict_to_images: bool,
    explicit_media_type: ?[]const u8,
) Allocator.Error!provider.VideoFile {
    const media_type = explicit_media_type orelse
        (provider_utils.detectMediaType(
            arena,
            .{ .bytes = bytes },
            if (restrict_to_images) "image" else null,
        ) catch null) orelse
        "image/png";
    return .{ .file = .{
        .media_type = try arena.dupe(u8, media_type),
        .data = .{ .bytes = try arena.dupe(u8, bytes) },
    } };
}

const Decoded = struct {
    bytes: []const u8,
    media_type: ?[]const u8 = null,
};

fn decodeDataUrl(
    arena: Allocator,
    value: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!Decoded {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse
        return invalidData(arena, diag, value, "Invalid data URL media content");
    const header = value["data:".len..comma];
    const semicolon = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    const media_type = if (semicolon == 0)
        null
    else
        try arena.dupe(u8, header[0..semicolon]);
    return .{
        .bytes = try decodeBase64(arena, value[comma + 1 ..], diag),
        .media_type = media_type,
    };
}

fn decodeBase64(
    arena: Allocator,
    value: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)![]const u8 {
    return provider_utils.decodeBase64(arena, value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalidData(
            arena,
            diag,
            value,
            "Invalid data content. Content string is not a base64-encoded media.",
        ),
    };
}

fn invalidData(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    content: []const u8,
    message: []const u8,
) provider.Error {
    const content_json = provider.wire.stringifyAlloc(arena, content) catch null;
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .invalid_data_content = .{
            .message = message,
            .content_json = content_json,
        },
    });
    return error.InvalidDataContentError;
}

test "media data normalizes URLs, data URLs, and unrestricted video references" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try normalizeImageFile(arena, .{ .string = "https://example.test/image.png" }, null);
    try std.testing.expectEqualStrings("https://example.test/image.png", url.url.url);

    const data_url = try normalizeImageFile(arena, .{ .string = "data:image/jpeg;base64,/9g=" }, null);
    try std.testing.expectEqualStrings("image/jpeg", data_url.file.media_type);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd8 }, data_url.file.data.bytes);

    const video = try normalizeVideoFile(
        arena,
        .{ .bytes = &.{ 0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p' } },
        false,
        null,
        null,
    );
    try std.testing.expectEqualStrings("video/mp4", video.file.media_type);
}
