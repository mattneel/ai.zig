//! Stage 3: approval-aware concurrent client tool execution.
//!
//! Incoming parts are returned before approval or execution work begins.
//! Approved calls are held until `model_call_end`, then one job per tool runs
//! in an `Io.Group`. Each job owns an arena retained until stage deinit, so
//! queued preliminary/final payload slices stay valid while downstream records
//! them. `ConcurrencyUnavailable` jobs run inline into an arena-backed side
//! list, avoiding the `io.async` queue-pump deadlock.

const std = @import("std");
const provider = @import("provider");
const events = @import("../events.zig");
const generate_text = @import("../generate_text.zig");
const message = @import("../message.zig");
const telemetry = @import("../telemetry.zig");
const tool_api = @import("../tool.zig");
const approval_signature = @import("../tool_approval_signature.zig");
const tool_common = @import("../tool_execution_common.zig");
const types = @import("../generate_text_types.zig");
const model_call = @import("model_call.zig");
const part_stream = @import("part_stream.zig");
const parts = @import("parts.zig");

const Allocator = std.mem.Allocator;
const Part = parts.LanguageModelStreamPart;

pub const Options = struct {
    upstream: part_stream.PartStream(Part),
    output_buffer: []Part,
    tools: tool_api.ToolSet = &.{},
    call_id: []const u8,
    messages: []const message.ModelMessage = &.{},
    tools_context: ?std.json.Value = null,
    approval_policy: []const tool_common.ApprovalPolicyEntry = &.{},
    approval_secret: ?[]const u8 = null,
    timeout: ?generate_text.TimeoutConfiguration = null,
    telemetry_options: telemetry.TelemetryOptions = .{},
    on_tool_execution_start: ?model_call.Callback(events.ToolExecutionStartEvent) = null,
    on_tool_execution_end: ?model_call.Callback(events.ToolExecutionEndEvent) = null,
    diag: ?*provider.Diagnostics = null,
};

pub fn executeToolsFromStream(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    options: Options,
) anyerror!part_stream.PartStream(Part) {
    const state = try arena.create(State);
    state.* = .{
        .gpa = gpa,
        .arena = arena,
        .upstream = options.upstream,
        .output = .init(options.output_buffer),
        .tools = options.tools,
        .call_id = try arena.dupe(u8, options.call_id),
        .messages = options.messages,
        .tools_context = options.tools_context,
        .approval_policy = options.approval_policy,
        .approval_secret = options.approval_secret,
        .timeout = options.timeout,
        .dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry_options),
        .on_start = options.on_tool_execution_start,
        .on_end = options.on_tool_execution_end,
        .id_generator = try @import("provider_utils").IdGenerator.initFromIo(io, .{}, options.diag),
        .diag = options.diag,
    };
    return .{ .ctx = state, .vtable = &State.vtable };
}

const State = struct {
    gpa: Allocator,
    arena: Allocator,
    upstream: part_stream.PartStream(Part),
    output: std.Io.Queue(Part),
    tools: tool_api.ToolSet,
    call_id: []const u8,
    messages: []const message.ModelMessage,
    tools_context: ?std.json.Value,
    approval_policy: []const tool_common.ApprovalPolicyEntry,
    approval_secret: ?[]const u8,
    timeout: ?generate_text.TimeoutConfiguration,
    dispatcher: telemetry.Dispatcher,
    on_start: ?model_call.Callback(events.ToolExecutionStartEvent),
    on_end: ?model_call.Callback(events.ToolExecutionEndEvent),
    id_generator: @import("provider_utils").IdGenerator,
    diag: ?*provider.Diagnostics,

    queued_calls: std.ArrayList(types.TypedToolCall) = .empty,
    blocked_ids: std.StringHashMapUnmanaged(void) = .empty,
    pending_call: ?types.TypedToolCall = null,
    pending_parts: [2]Part = undefined,
    pending_len: usize = 0,
    pending_index: usize = 0,
    execution_pending: bool = false,
    execution_started: bool = false,
    execution_finished: bool = false,
    inline_parts: std.ArrayList(Part) = .empty,
    inline_index: usize = 0,
    jobs: []Job = &.{},
    jobs_initialized: usize = 0,
    group: std.Io.Group = .init,
    remaining: std.atomic.Value(usize) = .init(0),
    fatal_mutex: std.Io.Mutex = .init,
    fatal_error: ?anyerror = null,
    deinitialized: bool = false,

    const vtable: part_stream.PartStream(Part).VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, io: std.Io) anyerror!?Part {
        const self: *State = @ptrCast(@alignCast(raw));
        while (true) {
            if (self.pending_index < self.pending_len) {
                defer self.pending_index += 1;
                return self.pending_parts[self.pending_index];
            }
            self.pending_index = 0;
            self.pending_len = 0;

            if (self.pending_call) |call| {
                self.pending_call = null;
                try self.resolveApproval(io, call);
                continue;
            }

            if (self.execution_pending and !self.execution_started) {
                self.execution_pending = false;
                try self.startExecutions(io);
            }
            if (self.execution_started and !self.execution_finished) {
                if (self.inline_index < self.inline_parts.items.len) {
                    defer self.inline_index += 1;
                    return self.inline_parts.items[self.inline_index];
                }
                return self.output.getOne(io) catch |err| switch (err) {
                    error.Canceled => |canceled| return canceled,
                    error.Closed => {
                        try self.group.await(io);
                        self.execution_finished = true;
                        if (self.takeFatalError(io)) |fatal| return fatal;
                        continue;
                    },
                };
            }

            const part = (try self.upstream.next(io)) orelse return null;
            switch (part) {
                .tool_call => |call| if (!call.invalid and tool_common.findTool(self.tools, call.tool_name) != null) {
                    // Return the call now; approval callbacks/parts happen on
                    // the next pull, preserving forward-immediately behavior.
                    self.pending_call = call;
                },
                .model_call_end => self.execution_pending = true,
                else => {},
            }
            return part;
        }
    }

    fn resolveApproval(self: *State, io: std.Io, call: types.TypedToolCall) anyerror!void {
        const named = tool_common.findTool(self.tools, call.tool_name) orelse return;
        const decision = try tool_common.resolveToolApproval(.{
            .arena = self.arena,
            .named = named,
            .tool_call = call,
            .messages = self.messages,
            .tools_context = self.tools_context,
            .policy = self.approval_policy,
            .diag = self.diag,
        });

        switch (decision) {
            .not_applicable => try self.queueExecutable(call, named),
            .user_approval => {
                const approval_id = try self.nextApprovalId();
                self.pending_parts[0] = .{ .tool_approval_request = .{
                    .approval_id = approval_id,
                    .tool_call = call,
                    .signature = try self.signApproval(approval_id, call),
                } };
                self.pending_len = 1;
                try self.blocked_ids.put(self.arena, call.tool_call_id, {});
            },
            .denied => |reason| {
                const approval_id = try self.nextApprovalId();
                self.pending_parts[0] = .{ .tool_approval_request = .{
                    .approval_id = approval_id,
                    .tool_call = call,
                    .is_automatic = true,
                    .signature = try self.signApproval(approval_id, call),
                } };
                self.pending_parts[1] = .{ .tool_approval_response = .{
                    .approval_id = approval_id,
                    .tool_call = call,
                    .approved = false,
                    .reason = if (reason) |value| try self.arena.dupe(u8, value) else null,
                    .provider_executed = call.provider_executed,
                } };
                self.pending_len = 2;
                try self.blocked_ids.put(self.arena, call.tool_call_id, {});
            },
            .approved => |reason| {
                const approval_id = try self.nextApprovalId();
                self.pending_parts[0] = .{ .tool_approval_request = .{
                    .approval_id = approval_id,
                    .tool_call = call,
                    .is_automatic = true,
                    .signature = try self.signApproval(approval_id, call),
                } };
                self.pending_parts[1] = .{ .tool_approval_response = .{
                    .approval_id = approval_id,
                    .tool_call = call,
                    .approved = true,
                    .reason = if (reason) |value| try self.arena.dupe(u8, value) else null,
                    .provider_executed = call.provider_executed,
                } };
                self.pending_len = 2;
                try self.queueExecutable(call, named);
            },
        }
        _ = io;
    }

    fn queueExecutable(self: *State, call: types.TypedToolCall, named: *const tool_api.NamedTool) Allocator.Error!void {
        if (!call.provider_executed and named.tool.execute != null) try self.queued_calls.append(self.arena, call);
    }

    fn nextApprovalId(self: *State) Allocator.Error![]const u8 {
        return self.id_generator.nextAlloc(self.arena);
    }

    fn signApproval(self: *State, approval_id: []const u8, call: types.TypedToolCall) Allocator.Error!?[]const u8 {
        const secret = self.approval_secret orelse return null;
        return @as(?[]const u8, try approval_signature.sign(
            self.arena,
            secret,
            approval_id,
            call.tool_call_id,
            call.tool_name,
            call.input,
        ));
    }

    fn startExecutions(self: *State, io: std.Io) anyerror!void {
        self.execution_started = true;
        if (self.queued_calls.items.len == 0) {
            self.output.close(io);
            return;
        }

        self.jobs = try self.arena.alloc(Job, self.queued_calls.items.len);
        var count: usize = 0;
        for (self.queued_calls.items) |call| {
            const named = tool_common.findTool(self.tools, call.tool_name) orelse continue;
            if (named.tool.execute == null) continue;
            self.jobs[count] = .{
                .state = self,
                .call = call,
                .named = named,
                .tool_context = try tool_common.validatedToolContext(self.arena, named, self.tools_context, self.diag),
                .arena_state = .init(self.gpa),
                .sink = .{ .queue = &self.output },
                .timeout_ms = if (self.timeout) |timeout| timeout.toolMs(call.tool_name) else null,
            };
            count += 1;
        }
        self.jobs = self.jobs[0..count];
        self.jobs_initialized = count;
        self.remaining.store(count, .release);
        if (count == 0) {
            self.output.close(io);
            return;
        }

        for (self.jobs) |*job| job.hook_scope = try self.dispatcher.enterToolExecution(self.call_id);
        for (self.jobs) |*job| {
            self.group.concurrent(io, Job.run, .{job}) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    job.sink = .{ .inline_list = &self.inline_parts };
                    job.run() catch {};
                },
            };
        }
    }

    fn storeFatalError(self: *State, io: std.Io, err: anyerror) void {
        self.fatal_mutex.lockUncancelable(io);
        defer self.fatal_mutex.unlock(io);
        if (self.fatal_error == null) self.fatal_error = err;
    }

    fn takeFatalError(self: *State, io: std.Io) ?anyerror {
        self.fatal_mutex.lockUncancelable(io);
        defer self.fatal_mutex.unlock(io);
        const err = self.fatal_error;
        self.fatal_error = null;
        return err;
    }

    fn deinit(raw: *anyopaque, io: std.Io) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.upstream.deinit(io);
        self.output.close(io);
        self.group.cancel(io);
        for (self.jobs[0..self.jobs_initialized]) |*job| {
            job.exitScope();
            job.arena_state.deinit();
        }
    }
};

const Sink = union(enum) {
    queue: *std.Io.Queue(Part),
    inline_list: *std.ArrayList(Part),

    fn emit(self: Sink, io: std.Io, arena: Allocator, part: Part) tool_common.PreliminaryError!void {
        return switch (self) {
            .queue => |queue| queue.putOne(io, part),
            .inline_list => |list| list.append(arena, part),
        };
    }
};

const Job = struct {
    state: *State,
    call: types.TypedToolCall,
    named: *const tool_api.NamedTool,
    tool_context: ?std.json.Value,
    arena_state: std.heap.ArenaAllocator,
    sink: Sink,
    timeout_ms: ?u64,
    timed_out: std.atomic.Value(bool) = .init(false),
    hook_scope: ?telemetry.HookScope = null,
    scope_exited: std.atomic.Value(bool) = .init(false),

    fn run(self: *Job) std.Io.Cancelable!void {
        defer self.finished();
        defer self.exitScope();
        self.runInner() catch |err| {
            self.state.storeFatalError(self.state.dispatcher.io, err);
            if (err == error.Canceled) return error.Canceled;
        };
    }

    fn runInner(self: *Job) anyerror!void {
        const io = self.state.dispatcher.io;
        const start_event: events.ToolExecutionStartEvent = .{
            .call_id = self.state.call_id,
            .tool_call = eventToolCall(self.call),
            .messages = self.state.messages,
            .tool_context = self.tool_context,
        };
        if (self.state.on_start) |callback| callback.callback(callback.ctx, &start_event) catch {};
        try self.state.dispatcher.onToolExecutionStart(&start_event);

        const started = std.Io.Timestamp.now(io, .awake);
        const maybe_result = tool_common.runWithTimeout(
            ?tool_common.ExecutionResult,
            io,
            self.timeout_ms,
            self,
            execute,
            &self.timed_out,
        ) catch |err| {
            if (err != error.Canceled or !self.timed_out.load(.acquire)) return err;
            const duration = tool_common.elapsedMilliseconds(started, std.Io.Timestamp.now(io, .awake));
            const text = try self.arena_state.allocator().dupe(u8, "ToolTimeout");
            const timeout_output: tool_common.ClientToolOutput = .{ .tool_error = .{
                .tool_call_id = self.call.tool_call_id,
                .tool_name = self.call.tool_name,
                .input = self.call.input,
                .error_value = .{ .string = text },
                .error_code = error.ToolTimeout,
                .provider_metadata = self.call.provider_metadata,
                .tool_metadata = self.call.tool_metadata,
                .dynamic = self.call.dynamic,
            } };
            try self.emitResult(timeout_output, duration);
            return;
        };
        const result = maybe_result orelse return;
        try self.emitResult(result.output, result.tool_execution_ms);
    }

    fn execute(self: *Job) tool_common.PreliminaryError!?tool_common.ExecutionResult {
        return tool_common.executeToolCall(.{
            .io = self.state.dispatcher.io,
            .arena = self.arena_state.allocator(),
            .call = self.call,
            .named = self.named,
            .messages = self.state.messages,
            .tool_context = self.tool_context,
            .on_preliminary = .{ .ctx = self, .callback = emitPreliminary },
        });
    }

    fn emitPreliminary(raw: ?*anyopaque, io: std.Io, result: types.TypedToolResult) tool_common.PreliminaryError!void {
        const self: *Job = @ptrCast(@alignCast(raw.?));
        try self.sink.emit(io, self.state.arena, .{ .tool_result = result });
    }

    fn emitResult(self: *Job, output: tool_common.ClientToolOutput, duration: f64) anyerror!void {
        const io = self.state.dispatcher.io;
        const end_event: events.ToolExecutionEndEvent = .{
            .call_id = self.state.call_id,
            .tool_call = eventToolCall(self.call),
            .messages = self.state.messages,
            .tool_context = self.tool_context,
            .tool_output = switch (output) {
                .result => |value| .{ .result = value.output },
                .tool_error => |value| .{ .err = value.error_code orelse error.InvalidToolInputError },
            },
            .tool_execution_ms = duration,
        };
        if (self.state.on_end) |callback| callback.callback(callback.ctx, &end_event) catch {};
        try self.state.dispatcher.onToolExecutionEnd(&end_event);
        try self.sink.emit(io, self.state.arena, .{ .tool_execution_end = .{
            .tool_call_id = output.toolCallId(),
            .tool_execution_ms = duration,
        } });
        try self.sink.emit(io, self.state.arena, switch (output) {
            .result => |value| .{ .tool_result = value },
            .tool_error => |value| .{ .tool_error = value },
        });
    }

    fn finished(self: *Job) void {
        if (self.state.remaining.fetchSub(1, .acq_rel) == 1) self.state.output.close(self.state.dispatcher.io);
    }

    fn exitScope(self: *Job) void {
        const scope = self.hook_scope orelse return;
        if (self.scope_exited.swap(true, .acq_rel)) return;
        scope.exit();
    }
};

fn eventToolCall(call: types.TypedToolCall) events.ToolCall {
    return .{
        .tool_call_id = call.tool_call_id,
        .tool_name = call.tool_name,
        .input = call.input,
        .provider_executed = call.provider_executed,
        .dynamic = call.dynamic,
    };
}

fn finishPart() Part {
    return .{ .model_call_end = .{
        .finish_reason = .{ .unified = .stop, .raw = "stop" },
        .raw_finish_reason = "stop",
        .usage = .{ .input_tokens = .{ .total = 1 }, .output_tokens = .{ .total = 2 } },
        .performance = .{
            .response_time_ms = 1,
            .effective_output_tokens_per_second = 2,
            .effective_total_tokens_per_second = 3,
        },
    } };
}

test "tool execution stage forwards immediately and executes only after model-call-end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Input = struct {
        values: []const Part,
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?Part {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == self.values.len) return null;
            defer self.index += 1;
            return self.values[self.index];
        }
    };
    const Executor = struct {
        called: bool = false,
        fn run(
            raw: ?*anyopaque,
            _: std.Io,
            _: Allocator,
            _: std.json.Value,
            _: tool_api.ToolExecutionOptions,
        ) anyerror!tool_api.ToolOutput {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.called = true;
            return .{ .value = .{ .string = "sunny" } };
        }
    };

    const input_parts = [_]Part{
        .{ .tool_call = .{ .tool_call_id = "c", .tool_name = "weather", .input = .null } },
        .{ .text_delta = .{ .id = "t", .text = "before finish" } },
        finishPart(),
    };
    var input: Input = .{ .values = &input_parts };
    var executor: Executor = .{};
    const tools = [_]tool_api.NamedTool{.{ .name = "weather", .tool = .{
        .input_schema = @import("provider_utils").rawSchema("{}", null),
        .execute = .{ .ctx = &executor, .execute_fn = Executor.run },
    } }};
    var output_buffer: [4]Part = undefined;
    const upstream: part_stream.PartStream(Part) = .{ .ctx = &input, .vtable = &.{ .next = Input.next } };
    const stage = try executeToolsFromStream(std.testing.io, std.testing.allocator, arena, .{
        .upstream = upstream,
        .output_buffer = &output_buffer,
        .tools = &tools,
        .call_id = "call",
    });
    defer stage.deinit(std.testing.io);

    try std.testing.expect((try stage.next(std.testing.io)).? == .tool_call);
    try std.testing.expect(!executor.called);
    try std.testing.expect((try stage.next(std.testing.io)).? == .text_delta);
    try std.testing.expect(!executor.called);
    try std.testing.expect((try stage.next(std.testing.io)).? == .model_call_end);
    try std.testing.expect(!executor.called);
    try std.testing.expect((try stage.next(std.testing.io)).? == .tool_execution_end);
    const result = (try stage.next(std.testing.io)).?.tool_result;
    try std.testing.expect(executor.called);
    try std.testing.expectEqualStrings("sunny", result.output.string);
    try std.testing.expectEqual(null, try stage.next(std.testing.io));
}

test "tool execution stage forwards preliminary values before final result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Progress = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .integer = 1 },
                1 => .{ .integer = 2 },
                2 => .{ .integer = 3 },
                else => null,
            };
        }
    };
    const Executor = struct {
        progress: *Progress,
        fn run(
            raw: ?*anyopaque,
            _: std.Io,
            _: Allocator,
            _: std.json.Value,
            _: tool_api.ToolExecutionOptions,
        ) anyerror!tool_api.ToolOutput {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .stream = .{ .ctx = self.progress, .vtable = &.{ .next = Progress.next } } };
        }
    };
    const Input = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?Part {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .tool_call = .{ .tool_call_id = "p", .tool_name = "progress", .input = .null } },
                1 => finishPart(),
                else => null,
            };
        }
    };

    var progress: Progress = .{};
    var executor: Executor = .{ .progress = &progress };
    var input: Input = .{};
    const tools = [_]tool_api.NamedTool{.{ .name = "progress", .tool = .{
        .input_schema = @import("provider_utils").rawSchema("{}", null),
        .execute = .{ .ctx = &executor, .execute_fn = Executor.run },
    } }};
    var output_buffer: [2]Part = undefined;
    const stage = try executeToolsFromStream(std.testing.io, std.testing.allocator, arena, .{
        .upstream = .{ .ctx = &input, .vtable = &.{ .next = Input.next } },
        .output_buffer = &output_buffer,
        .tools = &tools,
        .call_id = "call",
    });
    defer stage.deinit(std.testing.io);
    _ = try stage.next(std.testing.io); // tool call
    _ = try stage.next(std.testing.io); // model end
    const first = (try stage.next(std.testing.io)).?.tool_result;
    const second = (try stage.next(std.testing.io)).?.tool_result;
    try std.testing.expect(first.preliminary and second.preliminary);
    try std.testing.expectEqual(1, first.output.integer);
    try std.testing.expectEqual(2, second.output.integer);
    try std.testing.expect((try stage.next(std.testing.io)).? == .tool_execution_end);
    const final = (try stage.next(std.testing.io)).?.tool_result;
    try std.testing.expect(!final.preliminary);
    try std.testing.expectEqual(3, final.output.integer);
}

test "tool execution stage emits denied approval parts and does not execute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Input = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?Part {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .tool_call = .{ .tool_call_id = "d", .tool_name = "danger", .input = .null } },
                1 => finishPart(),
                else => null,
            };
        }
    };
    const Executor = struct {
        called: bool = false,
        fn run(raw: ?*anyopaque, _: std.Io, _: Allocator, _: std.json.Value, _: tool_api.ToolExecutionOptions) anyerror!tool_api.ToolOutput {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.called = true;
            return .{ .value = .null };
        }
    };
    var input: Input = .{};
    var executor: Executor = .{};
    const tools = [_]tool_api.NamedTool{.{ .name = "danger", .tool = .{
        .input_schema = @import("provider_utils").rawSchema("{}", null),
        .execute = .{ .ctx = &executor, .execute_fn = Executor.run },
    } }};
    const policy = [_]tool_common.ApprovalPolicyEntry{.{
        .tool_name = "danger",
        .decision = .{ .denied = "policy" },
    }};
    var output_buffer: [2]Part = undefined;
    const stage = try executeToolsFromStream(std.testing.io, std.testing.allocator, arena, .{
        .upstream = .{ .ctx = &input, .vtable = &.{ .next = Input.next } },
        .output_buffer = &output_buffer,
        .tools = &tools,
        .call_id = "call",
        .approval_policy = &policy,
    });
    defer stage.deinit(std.testing.io);
    try std.testing.expect((try stage.next(std.testing.io)).? == .tool_call);
    try std.testing.expect((try stage.next(std.testing.io)).? == .tool_approval_request);
    const response = (try stage.next(std.testing.io)).?.tool_approval_response;
    try std.testing.expect(!response.approved);
    try std.testing.expect((try stage.next(std.testing.io)).? == .model_call_end);
    try std.testing.expectEqual(null, try stage.next(std.testing.io));
    try std.testing.expect(!executor.called);
}

test "tool execution failure is a part with execution timing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Input = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?Part {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .tool_call = .{ .tool_call_id = "e", .tool_name = "fail", .input = .null } },
                1 => finishPart(),
                else => null,
            };
        }
    };
    const Executor = struct {
        fn run(_: ?*anyopaque, _: std.Io, _: Allocator, _: std.json.Value, _: tool_api.ToolExecutionOptions) anyerror!tool_api.ToolOutput {
            return error.ExpectedToolFailure;
        }
    };
    var input: Input = .{};
    const tools = [_]tool_api.NamedTool{.{ .name = "fail", .tool = .{
        .input_schema = @import("provider_utils").rawSchema("{}", null),
        .execute = .{ .execute_fn = Executor.run },
    } }};
    var output_buffer: [2]Part = undefined;
    const stage = try executeToolsFromStream(std.testing.io, std.testing.allocator, arena, .{
        .upstream = .{ .ctx = &input, .vtable = &.{ .next = Input.next } },
        .output_buffer = &output_buffer,
        .tools = &tools,
        .call_id = "call",
    });
    defer stage.deinit(std.testing.io);
    _ = try stage.next(std.testing.io);
    _ = try stage.next(std.testing.io);
    const timing = (try stage.next(std.testing.io)).?.tool_execution_end;
    try std.testing.expect(timing.tool_execution_ms >= 0);
    const failure = (try stage.next(std.testing.io)).?.tool_error;
    try std.testing.expectEqual(error.ExpectedToolFailure, failure.error_code.?);
}
