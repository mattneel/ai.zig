const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const default_user_agent_suffix =
    "ai-sdk-zig/openai-compatible/" ++ provider_utils.version;

/// Headers can be static or resolved again for every model call. The dynamic
/// form intentionally returns borrowed entries; request assembly normalizes
/// and copies them into the call arena.
pub const HeaderSource = union(enum) {
    static: []const provider_utils.HeaderEntry,
    dynamic: Dynamic,

    pub const Dynamic = struct {
        ctx: ?*anyopaque = null,
        resolve_fn: *const fn (ctx: ?*anyopaque) []const provider_utils.HeaderEntry,
    };

    pub fn resolve(self: HeaderSource) []const provider_utils.HeaderEntry {
        return switch (self) {
            .static => |entries| entries,
            .dynamic => |resolver| resolver.resolve_fn(resolver.ctx),
        };
    }
};

/// Pluggable OpenAI-compatible error shape hooks. `message_fn` receives the
/// parsed error document and may return null to use the default
/// `{error:{message}}` extractor.
pub const ErrorHooks = struct {
    ctx: ?*anyopaque = null,
    message_fn: ?*const fn (ctx: ?*anyopaque, value: std.json.Value) ?[]const u8 = null,
    retryable_fn: ?*const fn (
        ctx: ?*anyopaque,
        status: u16,
        value: ?std.json.Value,
    ) bool = null,
};

pub const Settings = struct {
    provider_name: []const u8,
    base_url: []const u8,
    api_key: ?[]const u8 = null,
    /// When absent, `<PROVIDER_NAME>_API_KEY` is derived at call time.
    api_key_env_var: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    /// Provider-owned headers applied before caller-configured headers.
    default_headers: []const provider_utils.HeaderEntry = &.{},
    headers: HeaderSource = .{ .static = &.{} },
    user_agent_suffix: []const u8 = default_user_agent_suffix,
    query_params: []const QueryParam = &.{},
    transport: provider_utils.HttpTransport,
    include_usage: bool = false,
    supports_structured_outputs: bool = false,
    strict_json_schema_default: bool = true,
    max_embeddings_per_call: ?u32 = null,
    supports_parallel_embedding_calls: ?bool = null,
    error_hooks: ErrorHooks = .{},
};

pub const Config = struct {
    provider: []const u8,
    provider_name: []const u8,
    base_url: []const u8,
    api_key: ?[]const u8,
    api_key_env_var: ?[]const u8,
    env: provider_utils.EnvLookup,
    default_headers: []const provider_utils.HeaderEntry = &.{},
    headers: HeaderSource,
    user_agent_suffix: []const u8 = default_user_agent_suffix,
    query_params: []const QueryParam,
    transport: provider_utils.HttpTransport,
    include_usage: bool,
    supports_structured_outputs: bool,
    strict_json_schema_default: bool = true,
    max_embeddings_per_call: ?u32 = null,
    supports_parallel_embedding_calls: ?bool = null,
    error_hooks: ErrorHooks,
};

pub fn invalidSettings(
    diag: ?*provider.Diagnostics,
    parameter: []const u8,
    message: []const u8,
) provider.Error {
    if (diag) |diagnostics| {
        provider.Diagnostics.set(diag, diagnostics.allocator, .{ .invalid_argument = .{
            .message = message,
            .parameter = parameter,
        } });
    }
    return error.InvalidArgumentError;
}
