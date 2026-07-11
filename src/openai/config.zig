const std = @import("std");
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
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    headers: HeaderSource = .{ .static = &.{} },
    transport: provider_utils.HttpTransport,
    websocket_factory: provider_utils.WebSocketFactory = provider_utils.defaultWebSocketFactory,
    name: []const u8 = "openai",
};

pub const Config = struct {
    allocator: Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    organization: ?[]const u8,
    project: ?[]const u8,
    env: provider_utils.EnvLookup,
    headers: HeaderSource,
    transport: provider_utils.HttpTransport,
    websocket_factory: provider_utils.WebSocketFactory = provider_utils.defaultWebSocketFactory,
    provider_name: []const u8,
    provider_options_name: []const u8,
};
