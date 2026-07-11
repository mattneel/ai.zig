//! Shared V4 provider specification types.

const std = @import("std");
const errors = @import("errors.zig");

pub const iso8601 = @import("iso8601.zig");

/// Mirrors json-value/json-value.ts.
pub const JsonValue = std.json.Value;
/// Mirrors shared-v4-provider-options.ts. Fields using this type are optional.
pub const ProviderOptions = JsonValue;
/// Mirrors shared-v4-provider-metadata.ts. Fields using this type are optional.
pub const ProviderMetadata = JsonValue;
/// Mirrors shared-v4-provider-reference.ts. The value must be a JSON object
/// whose values are strings; preserving it as `JsonValue` keeps provider keys
/// and insertion order verbatim.
pub const ProviderReference = JsonValue;
/// Mirrors shared-v4-headers.ts.
pub const Header = errors.Header;
/// Mirrors shared-v4-headers.ts as ordered name/value pairs.
pub const Headers = []const Header;

/// Mirrors the `Uint8Array | string` payload in shared-v4-file-data.ts.
/// JSON strings are base64. The canonical wire codec also base64-encodes byte
/// slices, matching the gateway's `Uint8Array` normalization; JSON octet arrays
/// are accepted on parse as a tolerant lossless input form.
pub const BinaryData = union(enum) {
    bytes: []const u8,
    base64: []const u8,
};

/// Mirrors shared-v4-file-data.ts.
pub const FileData = union(enum) {
    data: Data,
    url: Url,
    reference: Reference,
    text: Text,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .data, "data" },
        .{ .url, "url" },
        .{ .reference, "reference" },
        .{ .text, "text" },
    };

    /// Mirrors shared-v4-file-data.ts data payload.
    pub const Data = struct { data: BinaryData };
    /// Mirrors shared-v4-file-data.ts URL payload.
    pub const Url = struct { url: []const u8 };
    /// Mirrors shared-v4-file-data.ts reference payload.
    pub const Reference = struct { reference: ProviderReference };
    /// Mirrors shared-v4-file-data.ts text payload.
    pub const Text = struct { text: []const u8 };
};

/// Mirrors the data|url restriction in language-model-v4-file.ts and
/// language-model-v4-reasoning-file.ts.
pub const GeneratedFileData = union(enum) {
    data: Data,
    url: Url,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .data, "data" },
        .{ .url, "url" },
    };

    /// Mirrors shared-v4-file-data.ts generated data payload.
    pub const Data = struct { data: BinaryData };
    /// Mirrors shared-v4-file-data.ts generated URL payload.
    pub const Url = struct { url: []const u8 };
};

/// Mirrors the data|text upload restriction in files-v4 and skills-v4.
pub const UploadFileData = union(enum) {
    data: Data,
    text: Text,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .data, "data" },
        .{ .text, "text" },
    };

    /// Mirrors shared-v4-file-data.ts upload data payload.
    pub const Data = struct { data: BinaryData };
    /// Mirrors shared-v4-file-data.ts upload text payload.
    pub const Text = struct { text: []const u8 };
};

/// Mirrors shared-v4-warning.ts.
pub const Warning = union(enum) {
    unsupported: Feature,
    compatibility: Feature,
    deprecated: Deprecated,
    other: Other,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .unsupported, "unsupported" },
        .{ .compatibility, "compatibility" },
        .{ .deprecated, "deprecated" },
        .{ .other, "other" },
    };

    /// Mirrors shared-v4-warning.ts unsupported/compatibility payloads.
    pub const Feature = struct {
        feature: []const u8,
        details: ?[]const u8 = null,
    };
    /// Mirrors shared-v4-warning.ts deprecated payload.
    pub const Deprecated = struct {
        setting: []const u8,
        message: []const u8,
    };
    /// Mirrors shared-v4-warning.ts other payload.
    pub const Other = struct { message: []const u8 };
};

/// Validates V4 custom/provider-tool kinds (`provider.type`).
pub fn isValidKind(kind: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, kind, '.') orelse return false;
    return separator > 0 and separator + 1 < kind.len;
}

/// Mirrors the parsed components of image-model-v4-call-options.ts and
/// video-model-v4-call-options.ts template-literal dimensions.
pub const Dimensions = struct { w: u32, h: u32 };

/// Parses image/video sizes in `{w}x{h}` form.
pub fn parseSize(value: []const u8) ?Dimensions {
    return parseDimensions(value, 'x');
}

/// Parses image/video aspect ratios in `{w}:{h}` form.
pub fn parseAspectRatio(value: []const u8) ?Dimensions {
    return parseDimensions(value, ':');
}

fn parseDimensions(value: []const u8, separator: u8) ?Dimensions {
    const index = std.mem.indexOfScalar(u8, value, separator) orelse return null;
    if (index == 0 or index + 1 == value.len) return null;
    if (std.mem.indexOfScalarPos(u8, value, index + 1, separator) != null) return null;
    const width = std.fmt.parseInt(u32, value[0..index], 10) catch return null;
    const height = std.fmt.parseInt(u32, value[index + 1 ..], 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ .w = width, .h = height };
}

test "wire shared validation helpers" {
    try std.testing.expect(isValidKind("openai.file-search"));
    try std.testing.expect(isValidKind("provider.family.block"));
    try std.testing.expect(!isValidKind("openai"));
    try std.testing.expect(!isValidKind(".tool"));
    try std.testing.expectEqual(Dimensions{ .w = 1024, .h = 768 }, parseSize("1024x768").?);
    try std.testing.expectEqual(Dimensions{ .w = 16, .h = 9 }, parseAspectRatio("16:9").?);
    try std.testing.expect(parseSize("0x2") == null);
}
