//! Reranking model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for reranking-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors reranking-model-v4-call-options.ts documents.
pub const Documents = union(enum) {
    text: Text,
    object: Object,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .object, "object" },
    };

    /// Mirrors reranking-model-v4-call-options.ts text documents.
    pub const Text = struct { values: []const []const u8 };
    /// Mirrors reranking-model-v4-call-options.ts object documents.
    pub const Object = struct { values: []const shared.JsonValue };
};

/// Mirrors reranking-model-v4-call-options.ts.
pub const CallOptions = struct {
    documents: Documents,
    query: []const u8,
    top_n: ?u32 = null,
    provider_options: ?shared.ProviderOptions = null,
    headers: ?shared.Headers = null,
};

/// Mirrors reranking-model-v4-result.ts ranking item.
pub const Ranking = struct {
    index: u64,
    relevance_score: f64,
};

/// Mirrors reranking-model-v4-result.ts response information.
pub const ResponseInfo = struct {
    id: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,
    headers: ?shared.Headers = null,
    body: ?shared.JsonValue = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors reranking-model-v4-result.ts.
pub const Result = struct {
    ranking: []const Ranking,
    provider_metadata: ?shared.ProviderMetadata = null,
    warnings: ?[]const shared.Warning = null,
    response: ?ResponseInfo = null,
};

/// Mirrors reranking-model-v4.ts as a Zig fat-pointer interface.
pub const RerankingModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors reranking-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        doRerank: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!Result,
    };

    pub fn provider(self: RerankingModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: RerankingModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn doRerank(
        self: RerankingModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!Result {
        return self.vtable.doRerank(self.ctx, io, arena, options, diag);
    }
};
