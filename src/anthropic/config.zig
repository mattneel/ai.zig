const provider_utils = @import("provider_utils");

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
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    headers: HeaderSource = .{ .static = &.{} },
    transport: provider_utils.HttpTransport,
    provider_name: []const u8 = "anthropic.messages",
};

pub const Config = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    auth_token: ?[]const u8,
    env: provider_utils.EnvLookup,
    headers: HeaderSource,
    transport: provider_utils.HttpTransport,
    provider: []const u8,
    provider_options_name: []const u8,
};
