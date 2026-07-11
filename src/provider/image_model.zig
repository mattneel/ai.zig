//! Image model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for image-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors image-model-v4-file.ts.
pub const ImageFile = union(enum) {
    file: File,
    url: Url,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .file, "file" },
        .{ .url, "url" },
    };

    /// Mirrors image-model-v4-file.ts binary file payload.
    pub const File = struct {
        media_type: []const u8,
        data: shared.BinaryData,
        provider_options: ?shared.ProviderOptions = null,
    };
    /// Mirrors image-model-v4-file.ts URL payload.
    pub const Url = struct {
        url: []const u8,
        provider_options: ?shared.ProviderOptions = null,
    };
};

/// Mirrors image-model-v4-call-options.ts. Upstream required-but-undefined
/// fields are Zig optionals; AbortSignal is replaced by `std.Io` cancelation.
pub const CallOptions = struct {
    prompt: ?[]const u8 = null,
    n: u32,
    size: ?[]const u8 = null,
    aspect_ratio: ?[]const u8 = null,
    seed: ?i64 = null,
    files: ?[]const ImageFile = null,
    mask: ?ImageFile = null,
    provider_options: shared.ProviderOptions,
    headers: ?shared.Headers = null,
};

/// Mirrors image-model-v4-usage.ts.
pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
};

/// Mirrors image-model-v4-result.ts response information.
pub const ResponseInfo = struct {
    timestamp_ms: i64,
    model_id: []const u8,
    headers: ?shared.Headers = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors image-model-v4-result.ts image data.
pub const ImageData = shared.BinaryData;

/// Mirrors image-model-v4-result.ts.
pub const Result = struct {
    images: []const ImageData,
    warnings: []const shared.Warning,
    provider_metadata: ?shared.ProviderMetadata = null,
    response: ResponseInfo,
    usage: ?Usage = null,
};

/// Mirrors image-model-v4.ts as a Zig fat-pointer interface.
pub const ImageModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors image-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        maxImagesPerCall: *const fn (ctx: *anyopaque, io: std.Io) ?u32,
        doGenerate: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!Result,
    };

    pub fn provider(self: ImageModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: ImageModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn maxImagesPerCall(self: ImageModel, io: std.Io) ?u32 {
        return self.vtable.maxImagesPerCall(self.ctx, io);
    }

    pub fn doGenerate(
        self: ImageModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!Result {
        return self.vtable.doGenerate(self.ctx, io, arena, options, diag);
    }
};
