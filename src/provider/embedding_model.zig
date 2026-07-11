//! Embedding model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for embedding-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors embedding-model-v4-call-options.ts. AbortSignal is replaced by
/// cancelation through the `std.Io` passed to `doEmbed`.
pub const CallOptions = struct {
    values: []const []const u8,
    provider_options: ?shared.ProviderOptions = null,
    headers: ?shared.Headers = null,
};

/// Mirrors embedding-model-v4-result.ts usage.
pub const Usage = struct { tokens: ?u64 = null };

/// Mirrors embedding-model-v4-result.ts response information.
pub const ResponseInfo = struct {
    headers: ?shared.Headers = null,
    body: ?shared.JsonValue = null,
};

/// Mirrors embedding-model-v4-result.ts. Embedding coordinates use `f64` to
/// preserve JavaScript-number precision at the provider boundary.
pub const Result = struct {
    embeddings: []const []const f64,
    usage: ?Usage = null,
    provider_metadata: ?shared.ProviderMetadata = null,
    response: ?ResponseInfo = null,
    warnings: []const shared.Warning,
};

/// Mirrors embedding-model-v4.ts as a Zig fat-pointer interface.
pub const EmbeddingModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors embedding-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        maxEmbeddingsPerCall: *const fn (ctx: *anyopaque, io: std.Io) ?u32,
        supportsParallelCalls: *const fn (ctx: *anyopaque, io: std.Io) bool,
        doEmbed: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!Result,
    };

    pub fn provider(self: EmbeddingModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: EmbeddingModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn maxEmbeddingsPerCall(self: EmbeddingModel, io: std.Io) ?u32 {
        return self.vtable.maxEmbeddingsPerCall(self.ctx, io);
    }

    pub fn supportsParallelCalls(self: EmbeddingModel, io: std.Io) bool {
        return self.vtable.supportsParallelCalls(self.ctx, io);
    }

    pub fn doEmbed(
        self: EmbeddingModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!Result {
        return self.vtable.doEmbed(self.ctx, io, arena, options, diag);
    }
};
