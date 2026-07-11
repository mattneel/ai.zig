//! Experimental video model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for video-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors video-model-v4-file.ts.
pub const VideoFile = union(enum) {
    file: File,
    url: Url,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .file, "file" },
        .{ .url, "url" },
    };

    /// Mirrors video-model-v4-file.ts binary file payload.
    pub const File = struct {
        media_type: []const u8,
        data: shared.BinaryData,
        provider_options: ?shared.ProviderOptions = null,
    };
    /// Mirrors video-model-v4-file.ts URL payload.
    pub const Url = struct {
        url: []const u8,
        media_type: ?[]const u8 = null,
        provider_options: ?shared.ProviderOptions = null,
    };
};

/// Mirrors video-model-v4-frame-image.ts frame type values.
pub const FrameType = enum {
    first_frame,
    last_frame,

    pub const wire_values = .{
        .{ .first_frame, "first_frame" },
        .{ .last_frame, "last_frame" },
    };
};

/// Mirrors video-model-v4-frame-image.ts.
pub const FrameImage = struct {
    image: VideoFile,
    frame_type: FrameType,
};

/// Mirrors video-model-v4-call-options.ts. `duration_seconds` deliberately
/// names the unit in Zig and maps to upstream's wire field `duration`.
pub const CallOptions = struct {
    prompt: ?[]const u8 = null,
    n: u32,
    aspect_ratio: ?[]const u8 = null,
    resolution: ?[]const u8 = null,
    duration_seconds: ?f64 = null,
    fps: ?f64 = null,
    seed: ?i64 = null,
    image: ?VideoFile = null,
    frame_images: ?[]const FrameImage = null,
    input_references: ?[]const VideoFile = null,
    generate_audio: ?bool = null,
    provider_options: shared.ProviderOptions,
    headers: ?shared.Headers = null,

    pub const wire_field_names = .{
        .{ "duration_seconds", "duration" },
    };
};

/// Mirrors video-model-v4-result.ts VideoData.
pub const VideoData = union(enum) {
    url: Url,
    base64: Base64,
    bytes: Bytes,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .url, "url" },
        .{ .base64, "base64" },
        .{ .bytes, "binary" },
    };

    /// Mirrors video-model-v4-result.ts URL video payload.
    pub const Url = struct {
        url: []const u8,
        media_type: []const u8,
    };
    /// Mirrors video-model-v4-result.ts base64 video payload.
    pub const Base64 = struct {
        data: []const u8,
        media_type: []const u8,
    };
    /// Mirrors video-model-v4-result.ts binary video payload.
    pub const Bytes = struct {
        data: []const u8,
        media_type: []const u8,
    };
};

/// Mirrors video-model-v4-result.ts response information.
pub const ResponseInfo = struct {
    timestamp_ms: i64,
    model_id: []const u8,
    headers: ?shared.Headers = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors video-model-v4-result.ts.
pub const Result = struct {
    videos: []const VideoData,
    warnings: []const shared.Warning,
    provider_metadata: ?shared.ProviderMetadata = null,
    response: ResponseInfo,
};

/// Mirrors video-model-v4.ts as a Zig fat-pointer interface.
pub const VideoModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors video-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        maxVideosPerCall: *const fn (ctx: *anyopaque, io: std.Io) ?u32,
        doGenerate: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!Result,
    };

    pub fn provider(self: VideoModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: VideoModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn maxVideosPerCall(self: VideoModel, io: std.Io) ?u32 {
        return self.vtable.maxVideosPerCall(self.ctx, io);
    }

    pub fn doGenerate(
        self: VideoModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!Result {
        return self.vtable.doGenerate(self.ctx, io, arena, options, diag);
    }
};
