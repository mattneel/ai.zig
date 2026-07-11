//! Telemetry integration registry and awaited fan-out dispatcher.

const std = @import("std");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;

pub const Meta = struct {
    record_inputs: bool = true,
    record_outputs: bool = true,
    function_id: ?[]const u8 = null,
};

fn Callback(comptime Event: type) type {
    return *const fn (
        ctx: ?*anyopaque,
        event: *const Event,
        meta: *const Meta,
    ) anyerror!void;
}

pub const Telemetry = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        onStart: ?Callback(events.GenerateTextStartEvent) = null,
        onStepStart: ?Callback(events.StepStartEvent) = null,
        onLanguageModelCallStart: ?Callback(events.LanguageModelCallStartEvent) = null,
        onLanguageModelCallEnd: ?Callback(events.LanguageModelCallEndEvent) = null,
        onToolExecutionStart: ?Callback(events.ToolExecutionStartEvent) = null,
        onToolExecutionEnd: ?Callback(events.ToolExecutionEndEvent) = null,
        onStepEnd: ?Callback(events.StepEndEvent) = null,
        onEnd: ?Callback(events.EndEvent) = null,
        onAbort: ?Callback(events.AbortEvent) = null,
        onError: ?Callback(events.ErrorEvent) = null,

        // Reserved now so later object/embed/rerank phases do not churn this
        // vtable or downstream FFI layouts.
        onObjectStepStart: ?Callback(events.ObjectStepStartEvent) = null,
        onObjectStepEnd: ?Callback(events.ObjectStepEndEvent) = null,
        onEmbedStart: ?Callback(events.EmbedStartEvent) = null,
        onEmbedEnd: ?Callback(events.EmbedEndEvent) = null,
        onRerankStart: ?Callback(events.RerankStartEvent) = null,
        onRerankEnd: ?Callback(events.RerankEndEvent) = null,

        enterModelCall: ?*const fn (ctx: ?*anyopaque, call_id: []const u8) ?*anyopaque = null,
        exitModelCall: ?*const fn (ctx: ?*anyopaque, token: ?*anyopaque) void = null,
        enterToolExecution: ?*const fn (ctx: ?*anyopaque, call_id: []const u8) ?*anyopaque = null,
        exitToolExecution: ?*const fn (ctx: ?*anyopaque, token: ?*anyopaque) void = null,
    };
};

pub const TelemetryOptions = struct {
    enabled: ?bool = null,
    record_inputs: bool = true,
    record_outputs: bool = true,
    function_id: ?[]const u8 = null,
    /// Non-null (including an empty slice) replaces the global registry.
    integrations: ?[]const Telemetry = null,
};

const Registry = struct {
    allocator: ?Allocator = null,
    integrations: std.ArrayList(Telemetry) = .empty,
};

var registry_mutex: std.atomic.Mutex = .unlocked;
var registry: Registry = .{};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Registers borrowed integration handles in registration order. The vtables
/// and contexts must remain valid until `clearTelemetryRegistry`.
pub fn registerTelemetry(gpa: Allocator, integrations: []const Telemetry) Allocator.Error!void {
    if (integrations.len == 0) return;
    lock(&registry_mutex);
    defer registry_mutex.unlock();

    if (registry.allocator == null) registry.allocator = gpa;
    try registry.integrations.appendSlice(registry.allocator.?, integrations);
}

pub fn getGlobalTelemetryIntegrations(arena: Allocator) Allocator.Error![]const Telemetry {
    lock(&registry_mutex);
    defer registry_mutex.unlock();
    return arena.dupe(Telemetry, registry.integrations.items);
}

/// Test/application teardown hook. Registered telemetry handles are borrowed;
/// clearing releases only the registry's handle array.
pub fn clearTelemetryRegistry() void {
    lock(&registry_mutex);
    defer registry_mutex.unlock();
    if (registry.allocator) |allocator| registry.integrations.deinit(allocator);
    registry = .{};
}

pub const Dispatcher = struct {
    io: std.Io,
    arena: Allocator,
    integrations: []const Telemetry,
    meta: Meta,
    enabled: bool,

    pub fn onStart(self: Dispatcher, event: *const events.GenerateTextStartEvent) std.Io.Cancelable!void {
        return dispatch(events.GenerateTextStartEvent, "onStart", self, event);
    }

    pub fn onStepStart(self: Dispatcher, event: *const events.StepStartEvent) std.Io.Cancelable!void {
        return dispatch(events.StepStartEvent, "onStepStart", self, event);
    }

    pub fn onLanguageModelCallStart(self: Dispatcher, event: *const events.LanguageModelCallStartEvent) std.Io.Cancelable!void {
        return dispatch(events.LanguageModelCallStartEvent, "onLanguageModelCallStart", self, event);
    }

    pub fn onLanguageModelCallEnd(self: Dispatcher, event: *const events.LanguageModelCallEndEvent) std.Io.Cancelable!void {
        return dispatch(events.LanguageModelCallEndEvent, "onLanguageModelCallEnd", self, event);
    }

    pub fn onToolExecutionStart(self: Dispatcher, event: *const events.ToolExecutionStartEvent) std.Io.Cancelable!void {
        return dispatch(events.ToolExecutionStartEvent, "onToolExecutionStart", self, event);
    }

    pub fn onToolExecutionEnd(self: Dispatcher, event: *const events.ToolExecutionEndEvent) std.Io.Cancelable!void {
        return dispatch(events.ToolExecutionEndEvent, "onToolExecutionEnd", self, event);
    }

    pub fn onStepEnd(self: Dispatcher, event: *const events.StepEndEvent) std.Io.Cancelable!void {
        return dispatch(events.StepEndEvent, "onStepEnd", self, event);
    }

    pub fn onEnd(self: Dispatcher, event: *const events.EndEvent) std.Io.Cancelable!void {
        return dispatch(events.EndEvent, "onEnd", self, event);
    }

    pub fn onAbort(self: Dispatcher, event: *const events.AbortEvent) std.Io.Cancelable!void {
        return dispatch(events.AbortEvent, "onAbort", self, event);
    }

    pub fn onError(self: Dispatcher, event: *const events.ErrorEvent) std.Io.Cancelable!void {
        return dispatch(events.ErrorEvent, "onError", self, event);
    }

    pub fn onObjectStepStart(self: Dispatcher, event: *const events.ObjectStepStartEvent) std.Io.Cancelable!void {
        return dispatch(events.ObjectStepStartEvent, "onObjectStepStart", self, event);
    }

    pub fn onObjectStepEnd(self: Dispatcher, event: *const events.ObjectStepEndEvent) std.Io.Cancelable!void {
        return dispatch(events.ObjectStepEndEvent, "onObjectStepEnd", self, event);
    }

    pub fn onEmbedStart(self: Dispatcher, event: *const events.EmbedStartEvent) std.Io.Cancelable!void {
        return dispatch(events.EmbedStartEvent, "onEmbedStart", self, event);
    }

    pub fn onEmbedEnd(self: Dispatcher, event: *const events.EmbedEndEvent) std.Io.Cancelable!void {
        return dispatch(events.EmbedEndEvent, "onEmbedEnd", self, event);
    }

    pub fn onRerankStart(self: Dispatcher, event: *const events.RerankStartEvent) std.Io.Cancelable!void {
        return dispatch(events.RerankStartEvent, "onRerankStart", self, event);
    }

    pub fn onRerankEnd(self: Dispatcher, event: *const events.RerankEndEvent) std.Io.Cancelable!void {
        return dispatch(events.RerankEndEvent, "onRerankEnd", self, event);
    }

    pub fn enterModelCall(self: Dispatcher, call_id: []const u8) Allocator.Error!HookScope {
        return self.enter(.model_call, call_id);
    }

    pub fn enterToolExecution(self: Dispatcher, call_id: []const u8) Allocator.Error!HookScope {
        return self.enter(.tool_execution, call_id);
    }

    fn enter(self: Dispatcher, kind: HookKind, call_id: []const u8) Allocator.Error!HookScope {
        if (!self.enabled) return .{ .kind = kind, .entries = &.{} };
        const entries = try self.arena.alloc(HookEntry, self.integrations.len);
        var count: usize = 0;
        for (self.integrations) |integration| {
            const has_hook = switch (kind) {
                .model_call => integration.vtable.enterModelCall != null or integration.vtable.exitModelCall != null,
                .tool_execution => integration.vtable.enterToolExecution != null or integration.vtable.exitToolExecution != null,
            };
            if (!has_hook) continue;
            const token = switch (kind) {
                .model_call => if (integration.vtable.enterModelCall) |enter_fn|
                    enter_fn(integration.ctx, call_id)
                else
                    null,
                .tool_execution => if (integration.vtable.enterToolExecution) |enter_fn|
                    enter_fn(integration.ctx, call_id)
                else
                    null,
            };
            entries[count] = .{ .integration = integration, .token = token };
            count += 1;
        }
        return .{ .kind = kind, .entries = entries[0..count] };
    }
};

pub fn createTelemetryDispatcher(
    io: std.Io,
    arena: Allocator,
    options: TelemetryOptions,
) Allocator.Error!Dispatcher {
    const enabled = options.enabled != false;
    const integrations: []const Telemetry = if (!enabled)
        &.{}
    else if (options.integrations) |local|
        local
    else
        try getGlobalTelemetryIntegrations(arena);
    return .{
        .io = io,
        .arena = arena,
        .integrations = integrations,
        .meta = .{
            .record_inputs = options.record_inputs,
            .record_outputs = options.record_outputs,
            .function_id = options.function_id,
        },
        .enabled = enabled,
    };
}

fn Runner(comptime Event: type, comptime field_name: []const u8) type {
    return struct {
        fn run(integration: Telemetry, event: *const Event, meta: *const Meta) void {
            const callback = @field(integration.vtable, field_name) orelse return;
            callback(integration.ctx, event, meta) catch {};
        }
    };
}

fn dispatch(
    comptime Event: type,
    comptime field_name: []const u8,
    self: Dispatcher,
    event: *const Event,
) std.Io.Cancelable!void {
    if (!self.enabled or self.integrations.len == 0) return;

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);
    for (self.integrations) |integration| {
        if (@field(integration.vtable, field_name) == null) continue;
        group.async(self.io, Runner(Event, field_name).run, .{ integration, event, &self.meta });
    }
    try group.await(self.io);
}

const HookKind = enum { model_call, tool_execution };

const HookEntry = struct {
    integration: Telemetry,
    token: ?*anyopaque,
};

pub const HookScope = struct {
    kind: HookKind,
    entries: []const HookEntry,

    /// Exits are deliberately un-failable and run in reverse integration
    /// order, matching nested execute-wrapper unwinding.
    pub fn exit(self: HookScope) void {
        var index = self.entries.len;
        while (index != 0) {
            index -= 1;
            const entry = self.entries[index];
            switch (self.kind) {
                .model_call => if (entry.integration.vtable.exitModelCall) |exit_fn|
                    exit_fn(entry.integration.ctx, entry.token),
                .tool_execution => if (entry.integration.vtable.exitToolExecution) |exit_fn|
                    exit_fn(entry.integration.ctx, entry.token),
            }
        }
    }
};

test "dispatcher is a no-op without integrations" {
    clearTelemetryRegistry();
    defer clearTelemetryRegistry();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const dispatcher = try createTelemetryDispatcher(std.testing.io, arena_state.allocator(), .{});
    const event: events.GenerateTextStartEvent = .{
        .call_id = "call",
        .provider_name = "p",
        .model_id = "m",
    };
    try dispatcher.onStart(&event);
    const scope = try dispatcher.enterToolExecution("call");
    scope.exit();
}

test "dispatcher broadcasts, skips missing callbacks, swallows errors, and passes meta" {
    const Context = struct {
        calls: std.atomic.Value(usize) = .init(0),
        saw_meta: std.atomic.Value(bool) = .init(false),
        fail: bool,

        fn onStart(raw: ?*anyopaque, event: *const events.GenerateTextStartEvent, meta: *const Meta) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqualStrings("call-1", event.call_id);
            if (!meta.record_inputs and meta.record_outputs and
                std.mem.eql(u8, meta.function_id.?, "fn-1"))
            {
                self.saw_meta.store(true, .release);
            }
            _ = self.calls.fetchAdd(1, .monotonic);
            if (self.fail) return error.IntegrationFailed;
        }
    };

    var failing: Context = .{ .fail = true };
    var succeeding: Context = .{ .fail = false };
    const integrations = [_]Telemetry{
        .{ .ctx = &failing, .vtable = &.{ .onStart = Context.onStart } },
        .{ .ctx = &succeeding, .vtable = &.{ .onStart = Context.onStart } },
        .{ .vtable = &.{} },
    };
    const dispatcher = try createTelemetryDispatcher(std.testing.io, std.testing.allocator, .{
        .integrations = &integrations,
        .record_inputs = false,
        .function_id = "fn-1",
    });
    const event: events.GenerateTextStartEvent = .{
        .call_id = "call-1",
        .provider_name = "test",
        .model_id = "model",
    };
    try dispatcher.onStart(&event);
    try std.testing.expectEqual(1, failing.calls.load(.monotonic));
    try std.testing.expectEqual(1, succeeding.calls.load(.monotonic));
    try std.testing.expect(succeeding.saw_meta.load(.acquire));
}

test "disabled ignores globals and local integrations shadow globals" {
    clearTelemetryRegistry();
    defer clearTelemetryRegistry();

    const Context = struct {
        calls: std.atomic.Value(usize) = .init(0),
        fn onStart(raw: ?*anyopaque, _: *const events.GenerateTextStartEvent, _: *const Meta) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.calls.fetchAdd(1, .monotonic);
        }
    };
    var global: Context = .{};
    var local: Context = .{};
    try registerTelemetry(std.testing.allocator, &.{.{
        .ctx = &global,
        .vtable = &.{ .onStart = Context.onStart },
    }});
    const event: events.GenerateTextStartEvent = .{
        .call_id = "call",
        .provider_name = "p",
        .model_id = "m",
    };

    const disabled = try createTelemetryDispatcher(std.testing.io, std.testing.allocator, .{ .enabled = false });
    try disabled.onStart(&event);
    try std.testing.expectEqual(0, global.calls.load(.monotonic));

    var global_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer global_arena_state.deinit();
    const using_global = try createTelemetryDispatcher(
        std.testing.io,
        global_arena_state.allocator(),
        .{},
    );
    try using_global.onStart(&event);
    try std.testing.expectEqual(1, global.calls.load(.monotonic));

    const local_integration = [_]Telemetry{.{
        .ctx = &local,
        .vtable = &.{ .onStart = Context.onStart },
    }};
    const shadowing = try createTelemetryDispatcher(std.testing.io, std.testing.allocator, .{
        .integrations = &local_integration,
    });
    try shadowing.onStart(&event);
    try std.testing.expectEqual(1, global.calls.load(.monotonic));
    try std.testing.expectEqual(1, local.calls.load(.monotonic));
}

test "enter hooks compose and exits unwind in reverse order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const Context = struct {
        order: *[8]u8,
        index: *usize,
        enter_value: u8,
        exit_value: u8,

        fn enter(raw: ?*anyopaque, call_id: []const u8) ?*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(std.mem.eql(u8, call_id, "call-1"));
            self.order[self.index.*] = self.enter_value;
            self.index.* += 1;
            return raw;
        }

        fn exit(raw: ?*anyopaque, token: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(token == raw);
            self.order[self.index.*] = self.exit_value;
            self.index.* += 1;
        }
    };

    var order: [8]u8 = undefined;
    var index: usize = 0;
    var first: Context = .{ .order = &order, .index = &index, .enter_value = 1, .exit_value = 4 };
    var second: Context = .{ .order = &order, .index = &index, .enter_value = 2, .exit_value = 3 };
    const integrations = [_]Telemetry{
        .{ .ctx = &first, .vtable = &.{ .enterModelCall = Context.enter, .exitModelCall = Context.exit } },
        .{ .ctx = &second, .vtable = &.{ .enterModelCall = Context.enter, .exitModelCall = Context.exit } },
    };
    const dispatcher = try createTelemetryDispatcher(std.testing.io, arena_state.allocator(), .{
        .integrations = &integrations,
    });
    const scope = try dispatcher.enterModelCall("call-1");
    scope.exit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, order[0..4]);
}
