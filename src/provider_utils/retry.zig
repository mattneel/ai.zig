const std = @import("std");
const provider = @import("provider");

pub const RetryPolicy = struct {
    max_retries: u32 = 2,
    initial_delay_ms: u64 = 2000,
    backoff_factor: u64 = 2,
};

pub const ShouldRetry = *const fn (err: anyerror, diag: ?*const provider.Diagnostics) bool;
pub const DelayProvider = *const fn (
    err: anyerror,
    diag: ?*const provider.Diagnostics,
    exponential_delay_ms: u64,
) u64;

pub const Options = struct {
    policy: RetryPolicy = .{},
    should_retry: ShouldRetry = defaultShouldRetry,
    get_delay_ms: DelayProvider = defaultDelay,
};

pub fn retry(
    comptime T: type,
    io: std.Io,
    policy: RetryPolicy,
    context: anytype,
    comptime op: anytype,
    diag: ?*provider.Diagnostics,
) anyerror!T {
    return retryWithOptions(T, io, .{ .policy = policy }, context, op, diag);
}

pub fn retryWithOptions(
    comptime T: type,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime op: anytype,
    diag: ?*provider.Diagnostics,
) anyerror!T {
    var captured: std.ArrayList([]u8) = .empty;
    const capture_allocator: ?std.mem.Allocator = if (diag) |diagnostics|
        diagnostics.allocator
    else
        null;
    defer {
        if (capture_allocator) |allocator| {
            for (captured.items) |message| allocator.free(message);
            captured.deinit(allocator);
        }
    }

    var attempt: u32 = 0;
    var exponential_delay = options.policy.initial_delay_ms;
    while (true) {
        if (diag) |diagnostics| diagnostics.available = false;
        return op(context, io, attempt, diag) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (options.policy.max_retries == 0) return err;

            const message = currentErrorMessage(err, diag);
            captureMessage(&captured, capture_allocator, message);
            const attempts = attempt + 1;

            if (attempt >= options.policy.max_retries) {
                setRetryDiagnostics(
                    diag,
                    .max_retries_exceeded,
                    attempts,
                    message,
                    captured.items,
                );
                return error.RetryError;
            }

            if (!options.should_retry(err, diag)) {
                if (attempt == 0) return err;
                setRetryDiagnostics(
                    diag,
                    .error_not_retryable,
                    attempts,
                    message,
                    captured.items,
                );
                return error.RetryError;
            }

            const delay_ms = options.get_delay_ms(err, diag, exponential_delay);
            if (delay_ms != 0) {
                const duration_ms: i64 = @intCast(@min(delay_ms, @as(u64, std.math.maxInt(i64))));
                try io.sleep(.fromMilliseconds(duration_ms), .awake);
            }
            exponential_delay = std.math.mul(
                u64,
                exponential_delay,
                options.policy.backoff_factor,
            ) catch std.math.maxInt(u64);
            attempt += 1;
            continue;
        };
    }
}

pub fn defaultShouldRetry(_: anyerror, diag: ?*const provider.Diagnostics) bool {
    const diagnostics = diag orelse return false;
    if (!diagnostics.available) return false;
    return switch (diagnostics.payload) {
        .api_call => |payload| payload.is_retryable,
        else => false,
    };
}

fn defaultDelay(_: anyerror, _: ?*const provider.Diagnostics, delay_ms: u64) u64 {
    return delay_ms;
}

fn currentErrorMessage(err: anyerror, diag: ?*const provider.Diagnostics) []const u8 {
    const diagnostics = diag orelse return @errorName(err);
    if (!diagnostics.available) return @errorName(err);
    return switch (diagnostics.payload) {
        inline else => |payload| payload.message,
    };
}

fn captureMessage(
    captured: *std.ArrayList([]u8),
    allocator: ?std.mem.Allocator,
    message: []const u8,
) void {
    const gpa = allocator orelse return;
    const copy = gpa.dupe(u8, message) catch return;
    captured.append(gpa, copy) catch {
        gpa.free(copy);
    };
}

fn setRetryDiagnostics(
    diag: ?*provider.Diagnostics,
    reason: provider.RetryReason,
    attempts: u32,
    last_message: []const u8,
    errors: []const []u8,
) void {
    const diagnostics = diag orelse return;
    // Only captured messages are owned independently of the current diagnostics
    // arena. `last_message` may point into that arena, which `Diagnostics.set`
    // resets, so use it only while formatting the replacement payload.
    const retained_last_message: ?[]const u8 = if (errors.len != 0) errors[errors.len - 1] else null;
    const display_last_message = retained_last_message orelse last_message;
    var message_buffer: [768]u8 = undefined;
    const message = switch (reason) {
        .max_retries_exceeded => std.fmt.bufPrint(
            &message_buffer,
            "Failed after {d} attempts. Last error: {s}",
            .{ attempts, display_last_message },
        ) catch "Retries exhausted",
        .error_not_retryable => std.fmt.bufPrint(
            &message_buffer,
            "Failed after {d} attempts with non-retryable error: '{s}'",
            .{ attempts, display_last_message },
        ) catch "Retry stopped by a non-retryable error",
        .abort => "Retry aborted",
    };
    provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .retry = .{
        .message = message,
        .reason = reason,
        .last_error_message = retained_last_message,
        .errors = errors,
    } });
}

test "retry diagnostics do not retain arena-backed fallback message" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    provider.Diagnostics.set(&diagnostics, diagnostics.allocator, .{ .api_call = .{
        .message = "arena-backed failure",
        .url = "https://example.com",
        .is_retryable = true,
    } });
    const arena_backed_message = diagnostics.payload.api_call.message;

    setRetryDiagnostics(
        &diagnostics,
        .max_retries_exceeded,
        1,
        arena_backed_message,
        &.{},
    );

    try std.testing.expect(diagnostics.payload == .retry);
    try std.testing.expect(diagnostics.payload.retry.last_error_message == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.payload.retry.message,
        "arena-backed failure",
    ) != null);
}

test "retry succeeds on third attempt and records zero-based attempts" {
    const Context = struct {
        calls: u32 = 0,
        seen: [3]u32 = undefined,

        fn op(
            self: *@This(),
            _: std.Io,
            attempt: u32,
            diag: ?*provider.Diagnostics,
        ) anyerror!u32 {
            self.seen[self.calls] = attempt;
            self.calls += 1;
            if (self.calls < 3) {
                provider.Diagnostics.set(diag, diag.?.allocator, .{ .api_call = .{
                    .message = "temporary",
                    .url = "https://example.com",
                    .is_retryable = true,
                } });
                return error.APICallError;
            }
            return 42;
        }
    };
    var context: Context = .{};
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectEqual(42, try retry(
        u32,
        std.testing.io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(3, context.calls);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, &context.seen);
}

test "retry leaves first non-retryable error unwrapped" {
    const Context = struct {
        calls: u32 = 0,

        fn op(
            self: *@This(),
            _: std.Io,
            _: u32,
            diag: ?*provider.Diagnostics,
        ) anyerror!void {
            self.calls += 1;
            provider.Diagnostics.set(diag, diag.?.allocator, .{ .api_call = .{
                .message = "bad request",
                .url = "https://example.com",
                .status_code = 400,
                .is_retryable = false,
            } });
            return error.APICallError;
        }
    };
    var context: Context = .{};
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.APICallError, retry(
        void,
        std.testing.io,
        .{ .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(1, context.calls);
    try std.testing.expect(diagnostics.payload == .api_call);
}

test "retry wraps later non-retryable error with accumulated messages" {
    const Context = struct {
        calls: u32 = 0,

        fn op(
            self: *@This(),
            _: std.Io,
            _: u32,
            diag: ?*provider.Diagnostics,
        ) anyerror!void {
            self.calls += 1;
            const retryable = self.calls == 1;
            provider.Diagnostics.set(diag, diag.?.allocator, .{ .api_call = .{
                .message = if (retryable) "temporary" else "permanent",
                .url = "https://example.com",
                .is_retryable = retryable,
            } });
            return error.APICallError;
        }
    };
    var context: Context = .{};
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.RetryError, retry(
        void,
        std.testing.io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(provider.RetryReason.error_not_retryable, diagnostics.payload.retry.reason);
    try std.testing.expectEqual(2, diagnostics.payload.retry.errors.len);
    try std.testing.expectEqualStrings("temporary", diagnostics.payload.retry.errors[0]);
    try std.testing.expectEqualStrings("permanent", diagnostics.payload.retry.errors[1]);
}

test "retry exhaustion and disabled retries preserve upstream wrapping rules" {
    const Context = struct {
        calls: u32 = 0,

        fn op(
            self: *@This(),
            _: std.Io,
            _: u32,
            diag: ?*provider.Diagnostics,
        ) anyerror!void {
            self.calls += 1;
            provider.Diagnostics.set(diag, diag.?.allocator, .{ .api_call = .{
                .message = "still failing",
                .url = "https://example.com",
                .is_retryable = true,
            } });
            return error.APICallError;
        }
    };

    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var exhausted: Context = .{};
    try std.testing.expectError(error.RetryError, retry(
        void,
        std.testing.io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &exhausted,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(3, exhausted.calls);
    try std.testing.expectEqual(provider.RetryReason.max_retries_exceeded, diagnostics.payload.retry.reason);
    try std.testing.expectEqual(3, diagnostics.payload.retry.errors.len);

    var disabled: Context = .{};
    try std.testing.expectError(error.APICallError, retry(
        void,
        std.testing.io,
        .{ .max_retries = 0 },
        &disabled,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(1, disabled.calls);
}

test "retry propagates Canceled immediately" {
    const Op = struct {
        fn run(_: void, _: std.Io, _: u32, _: ?*provider.Diagnostics) anyerror!void {
            return error.Canceled;
        }
    };
    try std.testing.expectError(
        error.Canceled,
        retry(void, std.testing.io, .{}, {}, Op.run, null),
    );
}
