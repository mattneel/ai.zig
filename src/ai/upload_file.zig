//! File-upload orchestration and conservative text detection.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const media_data = @import("media_data.zig");

const Allocator = std.mem.Allocator;

pub const FilesApi = union(enum) {
    files: provider.Files,
    provider: provider.Provider,
};

pub const UploadData = union(enum) {
    bytes: []const u8,
    base64: []const u8,
    text: []const u8,
    tagged: provider.UploadFileData,
};

pub const UploadFileOptions = struct {
    api: FilesApi,
    data: UploadData,
    media_type: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    provider_options: ?provider.ProviderOptions = null,
    diag: ?*provider.Diagnostics = null,
};

pub const UploadFileResult = struct {
    arena_state: std.heap.ArenaAllocator,
    provider_reference: provider.ProviderReference,
    media_type: ?[]const u8,
    filename: ?[]const u8,
    provider_metadata: ?provider.ProviderMetadata,
    warnings: []const provider.Warning,

    pub fn deinit(self: *UploadFileResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn uploadFile(
    io: std.Io,
    gpa: Allocator,
    options: UploadFileOptions,
) anyerror!UploadFileResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const data: provider.UploadFileData = switch (options.data) {
        .bytes => |bytes| .{ .data = .{ .data = .{ .bytes = bytes } } },
        .base64 => |encoded| .{ .data = .{ .data = .{ .base64 = encoded } } },
        .text => |text| .{ .text = .{ .text = text } },
        .tagged => |tagged| tagged,
    };
    const media_type = options.media_type orelse try inferMediaType(arena, data, options.diag);
    const files_api = switch (options.api) {
        .files => |files| files,
        .provider => |selected| try selected.files(options.diag),
    };
    const model_result = try files_api.uploadFile(io, arena, &.{
        .data = data,
        .media_type = media_type,
        .filename = options.filename,
        .provider_options = options.provider_options,
    }, options.diag);

    const warnings = try arena.alloc(provider.Warning, model_result.warnings.len);
    for (model_result.warnings, warnings) |warning, *destination| {
        destination.* = try media_data.cloneWarning(arena, warning);
    }
    return .{
        .arena_state = arena_state,
        .provider_reference = try provider_utils.cloneJsonValue(arena, model_result.provider_reference),
        .media_type = if (model_result.media_type) |value| try arena.dupe(u8, value) else null,
        .filename = if (model_result.filename) |value| try arena.dupe(u8, value) else null,
        .provider_metadata = if (model_result.provider_metadata) |value|
            try provider_utils.cloneJsonValue(arena, value)
        else
            null,
        .warnings = warnings,
    };
}

fn inferMediaType(
    arena: Allocator,
    data: provider.UploadFileData,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)![]const u8 {
    return switch (data) {
        .text => "text/plain",
        .data => |value| (provider_utils.detectMediaType(
            arena,
            switch (value.data) {
                .bytes => |bytes| .{ .bytes = bytes },
                .base64 => |encoded| .{ .base64 = encoded },
            },
            null,
        ) catch null) orelse if (try isLikelyText(arena, value.data, diag))
            "text/plain"
        else
            "application/octet-stream",
    };
}

/// Scans at most 512 decoded bytes. NUL and C0 control characters other than
/// tab/newline/carriage-return classify the payload as binary.
pub fn isLikelyText(
    arena: Allocator,
    data: provider.BinaryData,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!bool {
    const check_length = 512;
    const base64_check_length = ((check_length + 4 + 2) / 3) * 4;
    const bytes = switch (data) {
        .bytes => |value| value,
        .base64 => |encoded| blk: {
            const prefix = encoded[0..@min(encoded.len, base64_check_length)];
            break :blk media_data.binaryBytes(arena, .{ .base64 = prefix }, diag) catch |err| return err;
        },
    };
    const length = @min(bytes.len, check_length);
    if (length == 0) return false;
    for (bytes[0..length]) |byte| {
        if (byte == 0 or (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r')) {
            return false;
        }
    }
    return true;
}

test "isLikelyText handles bytes, base64, NUL, and disallowed controls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(try isLikelyText(arena, .{ .bytes = "hello\nworld\t" }, null));
    try std.testing.expect(!try isLikelyText(arena, .{ .bytes = &.{ 0xff, 0, 0x80 } }, null));
    try std.testing.expect(try isLikelyText(arena, .{ .base64 = "aGVsbG8gd29ybGQ=" }, null));
    try std.testing.expect(!try isLikelyText(arena, .{ .bytes = "hello\x01world" }, null));
    try std.testing.expect(!try isLikelyText(arena, .{ .bytes = &.{} }, null));
}

test "uploadFile resolves provider files capability and reports absence" {
    const MockProvider = struct {
        fn language(_: *anyopaque, _: []const u8, _: ?*provider.Diagnostics) provider.Error!provider.LanguageModel {
            return error.NoSuchModelError;
        }
        fn embedding(_: *anyopaque, _: []const u8, _: ?*provider.Diagnostics) provider.Error!provider.EmbeddingModel {
            return error.NoSuchModelError;
        }
        fn image(_: *anyopaque, _: []const u8, _: ?*provider.Diagnostics) provider.Error!provider.ImageModel {
            return error.NoSuchModelError;
        }
    };
    var marker: u8 = 0;
    const selected: provider.Provider = .{ .ctx = &marker, .vtable = &.{
        .languageModel = MockProvider.language,
        .embeddingModel = MockProvider.embedding,
        .imageModel = MockProvider.image,
    } };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.UnsupportedFunctionalityError, uploadFile(
        std.testing.io,
        std.testing.allocator,
        .{
            .api = .{ .provider = selected },
            .data = .{ .bytes = "plain text" },
            .diag = &diagnostics,
        },
    ));
    try std.testing.expect(diagnostics.payload == .unsupported_functionality);
    try std.testing.expectEqualStrings("files", diagnostics.payload.unsupported_functionality.functionality);
}
