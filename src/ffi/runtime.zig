const std = @import("std");
const builtin = @import("builtin");
const provider = @import("provider");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator(.{});
const use_debug_allocator = builtin.mode == .Debug;

const unavailable_error = "{\"message\":\"error details unavailable\"}";

pub const ErrorStore = struct {
    mutex: std.atomic.Mutex = .unlocked,
    value: ?[]u8 = null,
    failed: bool = false,

    pub fn deinit(self: *ErrorStore, allocator: Allocator) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.value) |value| allocator.free(value);
        self.value = null;
        self.failed = false;
    }

    pub fn set(
        self: *ErrorStore,
        allocator: Allocator,
        status: types.Status,
        err: anyerror,
        diagnostics: ?*const provider.Diagnostics,
    ) void {
        const rendered = renderError(allocator, status, err, diagnostics) catch null;

        self.lock();
        defer self.mutex.unlock();
        if (self.value) |value| allocator.free(value);
        self.value = rendered;
        self.failed = true;
    }

    pub fn get(self: *ErrorStore) types.ai_string {
        self.lock();
        defer self.mutex.unlock();
        if (self.value) |value| return types.string(value);
        if (self.failed) return types.string(unavailable_error);
        return types.empty_string;
    }

    fn lock(self: *ErrorStore) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

pub const Runtime = struct {
    allocator_state: if (use_debug_allocator) DebugAllocator else void,
    threaded: std.Io.Threaded,
    refs: std.atomic.Value(usize) = .init(1),
    last_error: ErrorStore = .{},

    pub fn create(config: types.ai_runtime_config) Allocator.Error!*Runtime {
        const self = try std.heap.c_allocator.create(Runtime);
        errdefer std.heap.c_allocator.destroy(self);

        if (comptime use_debug_allocator) self.allocator_state = .{};
        self.threaded = .init(self.allocator(), .{
            .async_limit = if (config.async_limit == 0)
                null
            else
                .limited(config.async_limit),
            .concurrent_limit = if (config.concurrent_limit == 0)
                .unlimited
            else
                .limited(config.concurrent_limit),
        });
        self.refs = .init(1);
        self.last_error = .{};
        return self;
    }

    pub fn allocator(self: *Runtime) Allocator {
        return if (comptime use_debug_allocator)
            self.allocator_state.allocator()
        else
            std.heap.smp_allocator;
    }

    pub fn io(self: *Runtime) std.Io {
        return self.threaded.io();
    }

    pub fn retain(self: *Runtime) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Runtime) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;

        self.threaded.deinit();
        self.last_error.deinit(self.allocator());
        const clean = if (comptime use_debug_allocator)
            self.allocator_state.deinit() == .ok
        else
            true;
        last_runtime_deinit_clean.store(clean, .release);
        std.heap.c_allocator.destroy(self);
    }

    pub fn fail(
        self: *Runtime,
        err: anyerror,
        diagnostics: ?*const provider.Diagnostics,
    ) types.Status {
        const status = types.statusFromError(err);
        self.last_error.set(self.allocator(), status, err, diagnostics);
        return status;
    }

    pub fn invalid(self: *Runtime, message: []const u8, parameter: []const u8) types.Status {
        var diagnostics = provider.Diagnostics.fromPayload(self.allocator(), .{
            .invalid_argument = .{ .message = message, .parameter = parameter },
        });
        defer diagnostics.deinit();
        return self.fail(error.InvalidArgumentError, &diagnostics);
    }
};

pub var last_runtime_deinit_clean: std.atomic.Value(bool) = .init(true);

pub fn fromHandle(handle: *types.ai_runtime) *Runtime {
    return @ptrCast(@alignCast(handle));
}

pub fn optionalFromHandle(handle: ?*types.ai_runtime) ?*Runtime {
    return if (handle) |value| fromHandle(value) else null;
}

pub export fn ai_status_name(status: types.Status) [*c]const u8 {
    return statusName(status).ptr;
}

pub export fn ai_abi_version() u32 {
    return types.abi_version;
}

pub export fn ai_abi_version_string() types.ai_string {
    return types.string(types.abi_version_string);
}

pub export fn ai_alloc(len: usize) [*c]u8 {
    if (len == 0) return null;
    const value = std.heap.c_allocator.alloc(u8, len) catch return null;
    return value.ptr;
}

pub export fn ai_buf_free(ptr: [*c]const u8, len: usize) void {
    if (ptr == null) return;
    std.heap.c_allocator.free(@constCast(ptr[0..len]));
}

pub export fn ai_runtime_create(
    config: [*c]const types.ai_runtime_config,
    out: [*c]?*types.ai_runtime,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const value = if (config != null)
        types.readStruct(types.ai_runtime_config, config) catch return .invalid_argument
    else
        types.ai_runtime_config{
            .struct_size = @sizeOf(types.ai_runtime_config),
            .async_limit = 0,
            .concurrent_limit = 0,
        };
    const runtime = Runtime.create(value) catch return .out_of_memory;
    out.* = @ptrCast(runtime);
    return .ok;
}

pub export fn ai_runtime_destroy(handle: ?*types.ai_runtime) void {
    const runtime = optionalFromHandle(handle) orelse return;
    runtime.release();
}

pub export fn ai_runtime_last_error(handle: ?*const types.ai_runtime) types.ai_string {
    const value = handle orelse return types.empty_string;
    const runtime: *Runtime = @ptrCast(@alignCast(@constCast(value)));
    return runtime.last_error.get();
}

pub fn statusName(status: types.Status) [:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .stream_done => "stream_done",
        .invalid_argument => "invalid_argument",
        .api_call => "api_call",
        .no_such_model => "no_such_model",
        .no_such_provider => "no_such_provider",
        .load_api_key => "load_api_key",
        .load_setting => "load_setting",
        .retry => "retry",
        .canceled => "canceled",
        .timeout => "timeout",
        .out_of_memory => "out_of_memory",
        .invalid_json => "invalid_json",
        .invalid_prompt => "invalid_prompt",
        .invalid_response => "invalid_response",
        .no_such_tool => "no_such_tool",
        .tool_error => "tool_error",
        .unsupported => "unsupported",
        .unknown => "unknown",
        _ => "unknown",
    };
}

fn renderError(
    allocator: Allocator,
    status: types.Status,
    err: anyerror,
    diagnostics: ?*const provider.Diagnostics,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = if (diagnostics) |value|
        try value.message(arena)
    else
        @errorName(err);
    const document = .{
        .status = statusName(status),
        .message = message,
        .diagnostics = if (diagnostics) |value|
            try diagnosticsValue(arena, value)
        else
            null,
    };
    const temporary = try provider.wire.stringifyAlloc(arena, document);
    return allocator.dupe(u8, temporary);
}

fn diagnosticsValue(arena: Allocator, diagnostics: *const provider.Diagnostics) !?std.json.Value {
    if (!diagnostics.available) return null;
    const payload_text = switch (diagnostics.payload) {
        inline else => |payload| try provider.wire.stringifyAlloc(arena, payload),
    };
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload_text, .{});
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "type", .{ .string = @tagName(diagnostics.payload) });
    if (parsed == .object) {
        var iterator = parsed.object.iterator();
        while (iterator.next()) |entry| {
            try object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return .{ .object = object };
}

test "runtime debug allocator reports a clean standalone teardown" {
    last_runtime_deinit_clean.store(false, .release);
    const runtime = try Runtime.create(.{
        .struct_size = @sizeOf(types.ai_runtime_config),
        .async_limit = 0,
        .concurrent_limit = 0,
    });
    runtime.release();
    try std.testing.expect(last_runtime_deinit_clean.load(.acquire));
}
