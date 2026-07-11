const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const ThinkingType = enum { adaptive, enabled, disabled };
pub const Thinking = struct {
    type: ThinkingType,
    budgetTokens: ?u64 = null,
    display: ?enum { omitted, summarized } = null,
};

pub const CacheControl = struct {
    type: enum { ephemeral },
    ttl: ?enum { @"5m", @"1h" } = null,
};

pub const Options = struct {
    sendReasoning: ?bool = null,
    structuredOutputMode: ?enum { outputFormat, jsonTool, auto } = null,
    thinking: ?Thinking = null,
    disableParallelToolUse: ?bool = null,
    cacheControl: ?CacheControl = null,
    metadata: ?struct { userId: ?[]const u8 = null } = null,
    mcpServers: ?std.json.Value = null,
    container: ?std.json.Value = null,
    anthropicBeta: ?[]const []const u8 = null,
    toolStreaming: ?bool = null,
    effort: ?enum { low, medium, high, xhigh, max } = null,
    taskBudget: ?std.json.Value = null,
    speed: ?enum { fast, standard } = null,
    inferenceGeo: ?enum { us, global } = null,
    fallbacks: ?std.json.Value = null,
    contextManagement: ?std.json.Value = null,
};

pub const Parsed = struct {
    value: Options,
    used_custom_key: bool,
};

pub fn parse(
    allocator: Allocator,
    provider_options: ?provider.ProviderOptions,
    custom_name: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!Parsed {
    const root_value = provider_options orelse return .{ .value = .{}, .used_custom_key = false };
    if (root_value == .null) return .{ .value = .{}, .used_custom_key = false };
    if (root_value != .object) return invalid(diag, allocator, "providerOptions must be an object");

    var result: Options = .{};
    if (root_value.object.get("anthropic")) |canonical| {
        if (canonical != .null) result = try parseOne(allocator, canonical, diag);
    }
    var used_custom = false;
    if (!std.mem.eql(u8, custom_name, "anthropic")) {
        if (root_value.object.get(custom_name)) |custom| {
            if (custom != .null) {
                result = overlay(result, try parseOne(allocator, custom, diag));
                used_custom = true;
            }
        }
    }
    return .{ .value = result, .used_custom_key = used_custom };
}

fn parseOne(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!Options {
    if (value != .object) return invalid(diag, allocator, "Anthropic provider options must be an object");
    return std.json.parseFromValueLeaky(Options, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid(diag, allocator, @errorName(err)),
    };
}

fn overlay(base: Options, override: Options) Options {
    var result = base;
    inline for (std.meta.fields(Options)) |field| {
        if (@field(override, field.name) != null) @field(result, field.name) = @field(override, field.name);
    }
    return result;
}

fn invalid(
    diag: ?*provider.Diagnostics,
    allocator: Allocator,
    message: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else allocator, .{
        .type_validation = .{ .message = message },
    });
    return error.TypeValidationError;
}

test "options merge canonical and custom namespaces with custom precedence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"anthropic\":{\"sendReasoning\":false,\"effort\":\"low\"},\"custom\":{\"effort\":\"high\",\"toolStreaming\":false}}",
        .{},
    );
    const parsed = try parse(arena, value, "custom", null);
    try std.testing.expect(parsed.used_custom_key);
    try std.testing.expectEqual(false, parsed.value.sendReasoning.?);
    try std.testing.expectEqual(.high, parsed.value.effort.?);
    try std.testing.expectEqual(false, parsed.value.toolStreaming.?);
}
