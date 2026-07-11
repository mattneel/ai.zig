const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const HeaderSource = union(enum) {
    static: []const provider_utils.HeaderEntry,
    dynamic: Dynamic,

    pub const Dynamic = struct {
        ctx: ?*anyopaque = null,
        resolve_fn: *const fn (ctx: ?*anyopaque) []const provider_utils.HeaderEntry,
    };

    pub fn resolve(self: HeaderSource) []const provider_utils.HeaderEntry {
        return switch (self) {
            .static => |headers| headers,
            .dynamic => |resolver| resolver.resolve_fn(resolver.ctx),
        };
    }
};

pub const Settings = struct {
    allocator: Allocator,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    headers: HeaderSource = .{ .static = &.{} },
    transport: provider_utils.HttpTransport,
    name: []const u8 = "google.generative-ai",
};

pub const Config = struct {
    allocator: Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    env: provider_utils.EnvLookup,
    headers: HeaderSource,
    transport: provider_utils.HttpTransport,
    provider_name: []const u8,
    provider_options_name: []const u8,
};

/// Resolves authentication at request time. The canonical upstream variable
/// wins; GOOGLE_API_KEY is an ai.zig compatibility fallback.
pub fn loadApiKey(
    config: Config,
    arena: Allocator,
    diag: ?*provider.Diagnostics,
) error{ LoadAPIKeyError, OutOfMemory }![]const u8 {
    if (config.api_key) |value| return arena.dupe(u8, value);
    if (config.env.get("GOOGLE_GENERATIVE_AI_API_KEY")) |value| return arena.dupe(u8, value);
    if (config.env.get("GOOGLE_API_KEY")) |value| return arena.dupe(u8, value);

    const message = try std.fmt.allocPrint(
        arena,
        "Google Generative AI API key is missing. Pass it using the 'apiKey' parameter or the GOOGLE_GENERATIVE_AI_API_KEY environment variable (GOOGLE_API_KEY is also accepted by ai.zig).",
        .{},
    );
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .load_api_key = .{ .message = message },
    });
    return error.LoadAPIKeyError;
}

pub fn resolveHeaders(
    config: Config,
    arena: Allocator,
    call_headers: ?provider.Headers,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)![]const provider.Header {
    const api_key = try loadApiKey(config, arena, diag);
    const authentication = [_]provider_utils.HeaderEntry{.{
        .name = "x-goog-api-key",
        .value = api_key,
    }};
    const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |value| value.len else 0);
    if (call_headers) |values| for (values, call_entries) |header, *entry| {
        entry.* = .{ .name = header.name, .value = header.value };
    };
    const lists = [_][]const provider_utils.HeaderEntry{
        &authentication,
        config.headers.resolve(),
        call_entries,
    };
    const combined = try provider_utils.combineHeaders(arena, &lists);
    return provider_utils.withUserAgentSuffix(
        arena,
        combined,
        &.{"ai-sdk-zig/google/" ++ provider_utils.version},
    );
}
