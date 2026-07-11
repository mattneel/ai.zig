//! Files V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for files-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors files-v4-upload-file-call-options.ts.
pub const UploadFileCallOptions = struct {
    data: shared.UploadFileData,
    media_type: []const u8,
    filename: ?[]const u8 = null,
    provider_options: ?shared.ProviderOptions = null,
};

/// Mirrors files-v4-upload-file-result.ts.
pub const UploadFileResult = struct {
    provider_reference: shared.ProviderReference,
    media_type: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    provider_metadata: ?shared.ProviderMetadata = null,
    warnings: []const shared.Warning,
};

/// Mirrors files-v4.ts as a Zig fat-pointer interface.
pub const Files = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors files-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        uploadFile: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const UploadFileCallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!UploadFileResult,
    };

    pub fn provider(self: Files) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn uploadFile(
        self: Files,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const UploadFileCallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!UploadFileResult {
        return self.vtable.uploadFile(self.ctx, io, arena, options, diag);
    }
};
