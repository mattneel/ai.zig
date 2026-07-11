//! Speech model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for speech-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors speech-model-v4-call-options.ts.
pub const CallOptions = struct {
    text: []const u8,
    voice: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    speed: ?f64 = null,
    language: ?[]const u8 = null,
    provider_options: ?shared.ProviderOptions = null,
    headers: ?shared.Headers = null,
};

/// Mirrors speech-model-v4-result.ts request information.
pub const RequestInfo = struct { body: ?shared.JsonValue = null };

/// Mirrors speech-model-v4-result.ts response information.
pub const ResponseInfo = struct {
    timestamp_ms: i64,
    model_id: []const u8,
    headers: ?shared.Headers = null,
    body: ?shared.JsonValue = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors speech-model-v4-result.ts.
pub const Result = struct {
    audio: shared.BinaryData,
    warnings: []const shared.Warning,
    request: ?RequestInfo = null,
    response: ResponseInfo,
    provider_metadata: ?shared.ProviderMetadata = null,
};

/// Mirrors speech-model-v4.ts as a Zig fat-pointer interface.
pub const SpeechModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors speech-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        doGenerate: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!Result,
    };

    pub fn provider(self: SpeechModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: SpeechModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn doGenerate(
        self: SpeechModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!Result {
        return self.vtable.doGenerate(self.ctx, io, arena, options, diag);
    }
};
