//! Skills V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for skills-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors skills-v4-upload-skill-call-options.ts file.
pub const SkillFile = struct {
    path: []const u8,
    data: shared.UploadFileData,
};

/// Mirrors skills-v4-upload-skill-call-options.ts.
pub const UploadSkillCallOptions = struct {
    files: []const SkillFile,
    display_title: ?[]const u8 = null,
    provider_options: ?shared.ProviderOptions = null,
};

/// Mirrors skills-v4-upload-skill-result.ts.
pub const UploadSkillResult = struct {
    provider_reference: shared.ProviderReference,
    display_title: ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    latest_version: ?[]const u8 = null,
    provider_metadata: ?shared.ProviderMetadata = null,
    warnings: []const shared.Warning,
};

/// Mirrors skills-v4.ts as a Zig fat-pointer interface.
pub const Skills = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors skills-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        uploadSkill: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const UploadSkillCallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!UploadSkillResult,
    };

    pub fn provider(self: Skills) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn uploadSkill(
        self: Skills,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const UploadSkillCallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!UploadSkillResult {
        return self.vtable.uploadSkill(self.ctx, io, arena, options, diag);
    }
};
