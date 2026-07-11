//! Process-global warning logger matching the AI SDK warning contract.

const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const FIRST_WARNING_INFO_MESSAGE =
    "AI SDK Warning System: To turn off warning logging, set the AI_SDK_LOG_WARNINGS global to false.";

pub const Options = struct {
    warnings: []const provider.Warning,
    provider_name: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const CustomLogger = struct {
    ctx: ?*anyopaque = null,
    log_fn: *const fn (ctx: ?*anyopaque, options: *const Options) void,
};

pub const WarningLogger = union(enum) {
    default,
    disabled,
    custom: CustomLogger,
};

pub const SinkKind = enum { info, warning, deprecation_warning };

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    write_fn: *const fn (ctx: ?*anyopaque, kind: SinkKind, message: []const u8) void,
};

var logger_mutex: std.atomic.Mutex = .unlocked;
var logger: WarningLogger = .default;
var has_logged_before = false;
var test_sink: ?Sink = null;

fn lock() void {
    while (!logger_mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn setWarningLogger(value: WarningLogger) void {
    lock();
    defer logger_mutex.unlock();
    logger = value;
}

pub fn resetLogWarningsState() void {
    lock();
    defer logger_mutex.unlock();
    has_logged_before = false;
}

/// Internal capture hook used by the contract tests. Passing null restores the
/// stderr sink.
pub fn setDefaultWarningSinkForTests(value: ?Sink) void {
    lock();
    defer logger_mutex.unlock();
    test_sink = value;
}

pub fn logWarnings(arena: Allocator, options: Options) void {
    if (options.warnings.len == 0) return;

    lock();
    const configured = logger;
    var emit_note = false;
    const sink = test_sink orelse Sink{ .write_fn = stderrSink };
    switch (configured) {
        .disabled, .custom => {},
        .default => if (!has_logged_before) {
            has_logged_before = true;
            emit_note = true;
        },
    }
    logger_mutex.unlock();

    switch (configured) {
        .disabled => return,
        .custom => |custom| {
            custom.log_fn(custom.ctx, &options);
            return;
        },
        .default => {},
    }

    if (emit_note) sink.write_fn(sink.ctx, .info, FIRST_WARNING_INFO_MESSAGE);
    for (options.warnings) |warning| {
        const message = formatWarningAlloc(arena, warning, options.provider_name, options.model) catch
            continue;
        const kind: SinkKind = switch (warning) {
            .deprecated => .deprecation_warning,
            else => .warning,
        };
        sink.write_fn(sink.ctx, kind, message);
    }
}

pub fn formatWarningAlloc(
    arena: Allocator,
    warning: provider.Warning,
    provider_name: ?[]const u8,
    model: ?[]const u8,
) Allocator.Error![]const u8 {
    const prefix = if (provider_name != null and model != null)
        try std.fmt.allocPrint(
            arena,
            "AI SDK Warning ({s} / {s}):",
            .{ provider_name.?, model.? },
        )
    else
        "AI SDK Warning:";

    return switch (warning) {
        .unsupported => |value| if (value.details) |details|
            std.fmt.allocPrint(
                arena,
                "{s} The feature \"{s}\" is not supported. {s}",
                .{ prefix, value.feature, details },
            )
        else
            std.fmt.allocPrint(
                arena,
                "{s} The feature \"{s}\" is not supported.",
                .{ prefix, value.feature },
            ),
        .compatibility => |value| if (value.details) |details|
            std.fmt.allocPrint(
                arena,
                "{s} The feature \"{s}\" is used in a compatibility mode. {s}",
                .{ prefix, value.feature, details },
            )
        else
            std.fmt.allocPrint(
                arena,
                "{s} The feature \"{s}\" is used in a compatibility mode.",
                .{ prefix, value.feature },
            ),
        .deprecated => |value| std.fmt.allocPrint(
            arena,
            "{s} Deprecated: \"{s}\". {s}",
            .{ prefix, value.setting, value.message },
        ),
        .other => |value| std.fmt.allocPrint(arena, "{s} {s}", .{ prefix, value.message }),
    };
}

fn stderrSink(_: ?*anyopaque, _: SinkKind, message: []const u8) void {
    std.debug.print("{s}\n", .{message});
}

test "logWarnings suppression, custom logger, once-only note, and empty calls" {
    const Capture = struct {
        kinds: std.ArrayList(SinkKind) = .empty,
        messages: std.ArrayList([]const u8) = .empty,

        fn sink(raw: ?*anyopaque, kind: SinkKind, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.kinds.append(std.testing.allocator, kind) catch @panic("OOM");
            self.messages.append(std.testing.allocator, message) catch @panic("OOM");
        }
    };
    var capture: Capture = .{};
    defer capture.kinds.deinit(std.testing.allocator);
    defer capture.messages.deinit(std.testing.allocator);
    setDefaultWarningSinkForTests(.{ .ctx = &capture, .write_fn = Capture.sink });
    defer setDefaultWarningSinkForTests(null);
    defer setWarningLogger(.default);
    resetLogWarningsState();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const warnings = [_]provider.Warning{.{ .other = .{ .message = "first" } }};

    logWarnings(arena, .{ .warnings = &.{} });
    try std.testing.expectEqual(0, capture.messages.items.len);

    setWarningLogger(.disabled);
    logWarnings(arena, .{ .warnings = &warnings });
    try std.testing.expectEqual(0, capture.messages.items.len);

    const Custom = struct {
        calls: usize = 0,
        fn log(raw: ?*anyopaque, options: *const Options) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            std.debug.assert(options.warnings.len == 1);
            std.debug.assert(std.mem.eql(u8, options.provider_name.?, "p"));
            std.debug.assert(std.mem.eql(u8, options.model.?, "m"));
        }
    };
    var custom: Custom = .{};
    setWarningLogger(.{ .custom = .{ .ctx = &custom, .log_fn = Custom.log } });
    logWarnings(arena, .{
        .warnings = &warnings,
        .provider_name = "p",
        .model = "m",
    });
    try std.testing.expectEqual(1, custom.calls);
    try std.testing.expectEqual(0, capture.messages.items.len);

    setWarningLogger(.default);
    logWarnings(arena, .{ .warnings = &warnings, .provider_name = "p", .model = "m" });
    logWarnings(arena, .{ .warnings = &warnings, .provider_name = "p", .model = "m" });
    try std.testing.expectEqual(3, capture.messages.items.len);
    try std.testing.expectEqual(.info, capture.kinds.items[0]);
    try std.testing.expectEqualStrings(FIRST_WARNING_INFO_MESSAGE, capture.messages.items[0]);
    try std.testing.expectEqualStrings("AI SDK Warning (p / m): first", capture.messages.items[1]);
    try std.testing.expectEqualStrings("AI SDK Warning (p / m): first", capture.messages.items[2]);
}

test "warning variants use exact upstream strings and deprecated sink mapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "AI SDK Warning (zzz / MMM): The feature \"mediaType\" is not supported. detail",
        try formatWarningAlloc(arena, .{ .unsupported = .{
            .feature = "mediaType",
            .details = "detail",
        } }, "zzz", "MMM"),
    );
    try std.testing.expectEqualStrings(
        "AI SDK Warning: The feature \"strict\" is used in a compatibility mode.",
        try formatWarningAlloc(arena, .{ .compatibility = .{ .feature = "strict" } }, null, null),
    );
    try std.testing.expectEqualStrings(
        "AI SDK Warning (zzz / MMM): Deprecated: \"providerOptions key 'old-key'\". Use 'oldKey' instead.",
        try formatWarningAlloc(arena, .{ .deprecated = .{
            .setting = "providerOptions key 'old-key'",
            .message = "Use 'oldKey' instead.",
        } }, "zzz", "MMM"),
    );

    const Capture = struct {
        kind: ?SinkKind = null,
        fn sink(raw: ?*anyopaque, kind: SinkKind, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (kind != .info) self.kind = kind;
        }
    };
    var capture: Capture = .{};
    setWarningLogger(.default);
    resetLogWarningsState();
    setDefaultWarningSinkForTests(.{ .ctx = &capture, .write_fn = Capture.sink });
    defer setDefaultWarningSinkForTests(null);
    const deprecated = [_]provider.Warning{.{ .deprecated = .{
        .setting = "old",
        .message = "new",
    } }};
    logWarnings(arena, .{ .warnings = &deprecated });
    try std.testing.expectEqual(.deprecation_warning, capture.kind.?);
}
