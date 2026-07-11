const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const EnvLookup = struct {
    ctx: ?*anyopaque,
    get_fn: *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8,

    pub const empty: EnvLookup = .{ .ctx = null, .get_fn = emptyGet };

    pub fn get(self: EnvLookup, name: []const u8) ?[]const u8 {
        return self.get_fn(self.ctx, name);
    }

    pub fn fromMap(map: *const std.process.Environ.Map) EnvLookup {
        return .{
            .ctx = @ptrCast(@constCast(map)),
            .get_fn = mapGet,
        };
    }

    fn emptyGet(_: ?*anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }

    fn mapGet(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
        const map: *const std.process.Environ.Map = @ptrCast(@alignCast(raw.?));
        return map.get(name);
    }
};

pub const LoadApiKeyOptions = struct {
    explicit: ?[]const u8,
    env_var: []const u8,
    description: []const u8,
    env: EnvLookup = .empty,
    parameter_name: []const u8 = "apiKey",
};

pub const LoadSettingOptions = struct {
    explicit: ?[]const u8,
    env_var: []const u8,
    description: []const u8,
    setting_name: []const u8,
    env: EnvLookup = .empty,
};

pub fn loadApiKey(
    options: LoadApiKeyOptions,
    arena: Allocator,
    diag: ?*provider.Diagnostics,
) error{ LoadAPIKeyError, OutOfMemory }![]const u8 {
    if (options.explicit) |value| return arena.dupe(u8, value);
    if (options.env.get(options.env_var)) |value| return arena.dupe(u8, value);

    const message = std.fmt.allocPrint(
        arena,
        "{s} API key is missing. Pass it using the '{s}' parameter or the {s} environment variable.",
        .{ options.description, options.parameter_name, options.env_var },
    ) catch return error.OutOfMemory;
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .load_api_key = .{ .message = message } });
    return error.LoadAPIKeyError;
}

pub fn loadSetting(
    options: LoadSettingOptions,
    arena: Allocator,
    diag: ?*provider.Diagnostics,
) error{ LoadSettingError, OutOfMemory }![]const u8 {
    if (options.explicit) |value| return arena.dupe(u8, value);
    if (options.env.get(options.env_var)) |value| return arena.dupe(u8, value);

    const message = std.fmt.allocPrint(
        arena,
        "{s} setting is missing. Pass it using the '{s}' parameter or the {s} environment variable.",
        .{ options.description, options.setting_name, options.env_var },
    ) catch return error.OutOfMemory;
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .load_setting = .{ .message = message } });
    return error.LoadSettingError;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

pub fn loadOptionalSetting(
    options: LoadSettingOptions,
    arena: Allocator,
) Allocator.Error!?[]const u8 {
    if (options.explicit) |value| return try arena.dupe(u8, value);
    if (options.env.get(options.env_var)) |value| return try arena.dupe(u8, value);
    return null;
}

test "config lookup happens at call time and explicit wins" {
    const Context = struct {
        value: ?[]const u8,

        fn get(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!std.mem.eql(u8, name, "API_KEY")) return null;
            return self.value;
        }
    };

    var context: Context = .{ .value = null };
    const env: EnvLookup = .{ .ctx = &context, .get_fn = Context.get };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.LoadAPIKeyError, loadApiKey(.{
        .explicit = null,
        .env_var = "API_KEY",
        .description = "Example",
        .env = env,
    }, arena, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.payload.load_api_key.message, "API_KEY") != null);

    context.value = "from-env";
    try std.testing.expectEqualStrings("from-env", try loadApiKey(.{
        .explicit = null,
        .env_var = "API_KEY",
        .description = "Example",
        .env = env,
    }, arena, null));
    try std.testing.expectEqualStrings("explicit", try loadApiKey(.{
        .explicit = "explicit",
        .env_var = "API_KEY",
        .description = "Example",
        .env = env,
    }, arena, null));

    try std.testing.expectEqualStrings("configured", try loadSetting(.{
        .explicit = "configured",
        .env_var = "SETTING",
        .description = "Example",
        .setting_name = "setting",
        .env = env,
    }, arena, null));
    try std.testing.expectEqual(null, try loadOptionalSetting(.{
        .explicit = null,
        .env_var = "SETTING",
        .description = "Example",
        .setting_name = "setting",
        .env = env,
    }, arena));
}

test "config diagnostics outlive the request arena" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try std.testing.expectError(error.LoadAPIKeyError, loadApiKey(.{
            .explicit = null,
            .env_var = "DURABLE_KEY",
            .description = "Durable",
        }, arena_state.allocator(), &diagnostics));
    }
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.payload.load_api_key.message,
        "DURABLE_KEY",
    ) != null);
}
