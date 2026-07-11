//! Shared tool-call parsing, approval resolution, and execution core.
//!
//! Both `generateText` and the Phase 5 streaming stages call these functions;
//! differences in buffering and event delivery live in their callers.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const message = @import("message.zig");
const prompt_api = @import("prompt.zig");
const tool_api = @import("tool.zig");
const types = @import("generate_text_types.zig");

const Allocator = std.mem.Allocator;

pub const TypedToolCall = types.TypedToolCall;
pub const TypedToolResult = types.TypedToolResult;
pub const TypedToolError = types.TypedToolError;

pub const RepairToolCallOptions = struct {
    tool_call: provider.GeneratedToolCall,
    tools: tool_api.ToolSet,
    instructions: ?prompt_api.Instructions,
    messages: []const message.ModelMessage,
    err: types.ToolCallError,
};

pub const RepairToolCall = struct {
    ctx: ?*anyopaque = null,
    repair_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const RepairToolCallOptions,
    ) anyerror!?provider.GeneratedToolCall,
};

pub const RefineToolInput = struct {
    tool_name: []const u8,
    ctx: ?*anyopaque = null,
    refine_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        input: std.json.Value,
    ) anyerror!std.json.Value,
};

pub const ParseToolCallOptions = struct {
    io: std.Io,
    arena: Allocator,
    tools: tool_api.ToolSet,
    repair_tool_call: ?RepairToolCall = null,
    refine_tool_input: ?[]const RefineToolInput = null,
    instructions: ?prompt_api.Instructions = null,
    messages: []const message.ModelMessage = &.{},
};

const ParseAttempt = union(enum) {
    success: TypedToolCall,
    failure: types.ToolCallError,
};

/// Parses, validates, optionally repairs/refines, and always returns a typed
/// tool-call value. Invalid model output is represented by `invalid=true`
/// rather than escaping as an error.
pub fn parseToolCall(options: ParseToolCallOptions, original: provider.GeneratedToolCall) provider.CallError!TypedToolCall {
    var attempt = try doParseToolCall(options, original);
    if (attempt == .failure and options.repair_tool_call != null) {
        const original_error = attempt.failure;
        if (original_error.kind == .no_such_tool or original_error.kind == .invalid_input) {
            const repair = options.repair_tool_call.?;
            const repaired = repair.repair_fn(repair.ctx, options.io, options.arena, &.{
                .tool_call = original,
                .tools = options.tools,
                .instructions = options.instructions,
                .messages = options.messages,
                .err = original_error,
            }) catch |repair_error| {
                return invalidToolCall(options, original, .{
                    .kind = .repair_failed,
                    .err = error.ToolCallRepairError,
                    .message = try std.fmt.allocPrint(
                        options.arena,
                        "Tool call repair failed: {s}; original error: {s}",
                        .{ @errorName(repair_error), original_error.message },
                    ),
                    .original_kind = original_error.kind,
                });
            };
            if (repaired) |repaired_call| attempt = try doParseToolCall(options, repaired_call);
        }
    }

    return switch (attempt) {
        .success => |call| refineToolCall(options, call) catch |err| invalidToolCall(options, original, .{
            .kind = .other,
            .err = err,
            .message = try std.fmt.allocPrint(options.arena, "Tool input refinement failed: {s}", .{@errorName(err)}),
        }),
        .failure => |failure| invalidToolCall(options, original, failure),
    };
}

fn doParseToolCall(options: ParseToolCallOptions, call: provider.GeneratedToolCall) provider.CallError!ParseAttempt {
    const selected = findTool(options.tools, call.tool_name);
    if (selected == null and !(call.provider_executed == true and call.dynamic == true)) {
        return .{ .failure = .{
            .kind = .no_such_tool,
            .err = error.NoSuchToolError,
            .message = try std.fmt.allocPrint(options.arena, "No such tool: {s}", .{call.tool_name}),
        } };
    }

    const parsed_input = if (std.mem.trim(u8, call.input, " \t\r\n").len == 0)
        emptyJsonObject()
    else switch (provider_utils.safeParseJson(std.json.Value, options.arena, call.input)) {
        .success => |success| success.value,
        .failure => |failure| return .{ .failure = .{
            .kind = .invalid_input,
            .err = error.InvalidToolInputError,
            .message = try std.fmt.allocPrint(
                options.arena,
                "Invalid input for tool {s}: {s}",
                .{ call.tool_name, failure.message },
            ),
        } },
    };

    if (selected) |named| if (named.tool.input_schema.validator) |validator| {
        validator.validate(options.arena, parsed_input, null) catch {
            return .{ .failure = .{
                .kind = .invalid_input,
                .err = error.InvalidToolInputError,
                .message = try std.fmt.allocPrint(
                    options.arena,
                    "Invalid input for tool {s}: schema validation failed",
                    .{call.tool_name},
                ),
            } };
        };
    };

    return .{ .success = .{
        .tool_call_id = try options.arena.dupe(u8, call.tool_call_id),
        .tool_name = try options.arena.dupe(u8, call.tool_name),
        .input = try provider_utils.cloneJsonValue(options.arena, parsed_input),
        .provider_executed = call.provider_executed == true,
        .provider_metadata = try cloneOptionalJson(options.arena, call.provider_metadata),
        .tool_metadata = if (selected) |named| try cloneOptionalJson(options.arena, named.tool.metadata) else null,
        .dynamic = call.dynamic == true or (if (selected) |named| named.tool.kind == .dynamic else true),
    } };
}

fn refineToolCall(options: ParseToolCallOptions, call: TypedToolCall) anyerror!TypedToolCall {
    const refinements = options.refine_tool_input orelse return call;
    for (refinements) |refinement| {
        if (!std.mem.eql(u8, refinement.tool_name, call.tool_name)) continue;
        var refined = call;
        refined.input = try provider_utils.cloneJsonValue(
            options.arena,
            try refinement.refine_fn(refinement.ctx, options.io, options.arena, call.input),
        );
        return refined;
    }
    return call;
}

fn invalidToolCall(
    options: ParseToolCallOptions,
    original: provider.GeneratedToolCall,
    retained_error: types.ToolCallError,
) provider.CallError!TypedToolCall {
    const input: std.json.Value = switch (provider_utils.safeParseJson(std.json.Value, options.arena, original.input)) {
        .success => |success| try provider_utils.cloneJsonValue(options.arena, success.value),
        .failure => .{ .string = try options.arena.dupe(u8, original.input) },
    };
    const selected = findTool(options.tools, original.tool_name);
    return .{
        .tool_call_id = try options.arena.dupe(u8, original.tool_call_id),
        .tool_name = try options.arena.dupe(u8, original.tool_name),
        .input = input,
        .provider_executed = original.provider_executed == true,
        .provider_metadata = try cloneOptionalJson(options.arena, original.provider_metadata),
        .tool_metadata = if (selected) |named| try cloneOptionalJson(options.arena, named.tool.metadata) else null,
        .dynamic = true,
        .invalid = true,
        .err = retained_error,
    };
}

pub fn findTool(tools: tool_api.ToolSet, name: []const u8) ?*const tool_api.NamedTool {
    for (tools) |*named| if (std.mem.eql(u8, named.name, name)) return named;
    return null;
}

pub fn validatedToolContext(
    arena: Allocator,
    named: *const tool_api.NamedTool,
    tools_context: ?std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.CallError!?std.json.Value {
    const context: ?std.json.Value = if (tools_context) |all|
        if (all == .object) all.object.get(named.name) else null
    else
        null;
    if (named.tool.context_schema) |schema| {
        const value = context orelse std.json.Value.null;
        if (schema.validator) |validator| {
            validator.validate(arena, value, diag) catch return error.TypeValidationError;
        }
    }
    return cloneOptionalJson(arena, context);
}

pub const ApprovalPolicyEntry = struct {
    tool_name: []const u8,
    decision: Decision,

    pub const Decision = union(enum) {
        approved: ?[]const u8,
        denied: ?[]const u8,
        user_approval,
    };
};

pub const ApprovalDecision = union(enum) {
    not_applicable,
    user_approval,
    approved: ?[]const u8,
    denied: ?[]const u8,
};

pub const ResolveApprovalOptions = struct {
    arena: Allocator,
    named: *const tool_api.NamedTool,
    tool_call: TypedToolCall,
    messages: []const message.ModelMessage,
    tools_context: ?std.json.Value = null,
    policy: []const ApprovalPolicyEntry = &.{},
    diag: ?*provider.Diagnostics = null,
};

/// Resolves explicit auto-approval policy first, then the tool's intrinsic
/// `needs_approval` setting. Context validation happens before either callback.
pub fn resolveToolApproval(options: ResolveApprovalOptions) anyerror!ApprovalDecision {
    const context = try validatedToolContext(options.arena, options.named, options.tools_context, options.diag);
    for (options.policy) |entry| {
        if (!std.mem.eql(u8, entry.tool_name, options.tool_call.tool_name)) continue;
        return switch (entry.decision) {
            .approved => |reason| .{ .approved = reason },
            .denied => |reason| .{ .denied = reason },
            .user_approval => .user_approval,
        };
    }

    const needed = switch (options.named.tool.needs_approval) {
        .no => false,
        .yes => true,
        .resolver => |resolver| resolver.resolve(options.tool_call.input, .{
            .tool_call_id = options.tool_call.tool_call_id,
            .messages = options.messages,
            .context = context,
        }) catch |err| return err,
    };
    return if (needed) .user_approval else .not_applicable;
}

pub const ClientToolOutput = union(enum) {
    result: TypedToolResult,
    tool_error: TypedToolError,

    pub fn toolCallId(self: ClientToolOutput) []const u8 {
        return switch (self) {
            .result => |value| value.tool_call_id,
            .tool_error => |value| value.tool_call_id,
        };
    }
};

pub const PreliminaryError = Allocator.Error || std.Io.Cancelable || std.Io.QueueClosedError;

pub const PreliminaryCallback = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        result: TypedToolResult,
    ) PreliminaryError!void,
};

pub const ExecuteToolCallOptions = struct {
    io: std.Io,
    arena: Allocator,
    call: TypedToolCall,
    named: *const tool_api.NamedTool,
    messages: []const message.ModelMessage,
    tool_context: ?std.json.Value = null,
    on_preliminary: ?PreliminaryCallback = null,
};

pub const ExecutionResult = struct {
    output: ClientToolOutput,
    tool_execution_ms: f64,
};

/// Executes one tool. Tool failures become `tool_error` values; only
/// cancellation, allocation, or output-channel closure escape as errors.
/// Async-iterable values use one-item lookahead so each non-final yield is
/// emitted as `preliminary=true` and the last yield becomes the final output.
pub fn executeToolCall(options: ExecuteToolCallOptions) PreliminaryError!?ExecutionResult {
    const execute = options.named.tool.execute orelse return null;
    const started = std.Io.Timestamp.now(options.io, .awake);
    const raw_output = execute.execute(options.io, options.arena, options.call.input, .{
        .tool_call_id = options.call.tool_call_id,
        .messages = options.messages,
        .context = options.tool_context,
    }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return @as(?ExecutionResult, try executionError(options, err, started));
    };

    const final_value: std.json.Value = switch (raw_output) {
        .value => |value| try provider_utils.cloneJsonValue(options.arena, value),
        .stream => |stream| blk: {
            defer stream.deinit(options.io);
            var pending: ?std.json.Value = null;
            while (stream.next(options.io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return @as(?ExecutionResult, try executionError(options, err, started));
            }) |value| {
                const retained = try provider_utils.cloneJsonValue(options.arena, value);
                if (pending) |preliminary| if (options.on_preliminary) |callback| {
                    try callback.callback(callback.ctx, options.io, resultValue(options.call, preliminary, true));
                };
                pending = retained;
            }
            break :blk pending orelse .null;
        },
    };

    return .{
        .output = .{ .result = resultValue(options.call, final_value, false) },
        .tool_execution_ms = elapsedMilliseconds(started, std.Io.Timestamp.now(options.io, .awake)),
    };
}

fn executionError(options: ExecuteToolCallOptions, err: anyerror, started: std.Io.Timestamp) Allocator.Error!ExecutionResult {
    const error_text = try options.arena.dupe(u8, @errorName(err));
    return .{
        .output = .{ .tool_error = .{
            .tool_call_id = options.call.tool_call_id,
            .tool_name = options.call.tool_name,
            .input = options.call.input,
            .error_value = .{ .string = error_text },
            .error_code = err,
            .provider_metadata = options.call.provider_metadata,
            .tool_metadata = options.call.tool_metadata,
            .dynamic = options.call.dynamic,
        } },
        .tool_execution_ms = elapsedMilliseconds(started, std.Io.Timestamp.now(options.io, .awake)),
    };
}

fn resultValue(call: TypedToolCall, output: std.json.Value, preliminary: bool) TypedToolResult {
    return .{
        .tool_call_id = call.tool_call_id,
        .tool_name = call.tool_name,
        .input = call.input,
        .output = output,
        .provider_metadata = call.provider_metadata,
        .tool_metadata = call.tool_metadata,
        .dynamic = call.dynamic,
        .preliminary = preliminary,
    };
}

pub fn cloneClientOutput(arena: Allocator, output: ClientToolOutput) Allocator.Error!ClientToolOutput {
    return switch (output) {
        .result => |value| .{ .result = .{
            .tool_call_id = try arena.dupe(u8, value.tool_call_id),
            .tool_name = try arena.dupe(u8, value.tool_name),
            .input = if (value.input) |input| try provider_utils.cloneJsonValue(arena, input) else null,
            .output = try provider_utils.cloneJsonValue(arena, value.output),
            .provider_executed = value.provider_executed,
            .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
            .tool_metadata = try cloneOptionalJson(arena, value.tool_metadata),
            .dynamic = value.dynamic,
            .preliminary = value.preliminary,
        } },
        .tool_error => |value| .{ .tool_error = .{
            .tool_call_id = try arena.dupe(u8, value.tool_call_id),
            .tool_name = try arena.dupe(u8, value.tool_name),
            .input = if (value.input) |input| try provider_utils.cloneJsonValue(arena, input) else null,
            .error_value = try provider_utils.cloneJsonValue(arena, value.error_value),
            .error_code = value.error_code,
            .provider_executed = value.provider_executed,
            .provider_metadata = try cloneOptionalJson(arena, value.provider_metadata),
            .tool_metadata = try cloneOptionalJson(arena, value.tool_metadata),
            .dynamic = value.dynamic,
        } },
    };
}

pub fn elapsedMilliseconds(start: std.Io.Timestamp, finish: std.Io.Timestamp) f64 {
    const nanoseconds = finish.nanoseconds - start.nanoseconds;
    return @as(f64, @floatFromInt(nanoseconds)) / @as(f64, std.time.ns_per_ms);
}

/// Races an operation against a per-tool deadline. When true concurrency is
/// unavailable, execution degrades inline and the timeout is not enforced.
pub fn runWithTimeout(
    comptime T: type,
    io: std.Io,
    timeout_ms: ?u64,
    context: anytype,
    comptime operation: anytype,
    timed_out: *std.atomic.Value(bool),
) anyerror!T {
    const milliseconds = timeout_ms orelse return operation(context);
    const Context = @TypeOf(context);
    const Runner = struct {
        fn run(inner: Context) anyerror!T {
            return operation(inner);
        }
    };
    const Race = union(enum) {
        operation: anyerror!T,
        deadline: std.Io.Cancelable!void,
    };
    var buffer: [2]Race = undefined;
    var select: std.Io.Select(Race) = .init(io, &buffer);
    select.concurrent(.deadline, sleepMilliseconds, .{ io, milliseconds }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return operation(context),
    };
    defer select.cancelDiscard();
    select.async(.operation, Runner.run, .{context});
    return switch (try select.await()) {
        .operation => |result| try result,
        .deadline => |result| {
            try result;
            timed_out.store(true, .release);
            return error.Canceled;
        },
    };
}

fn sleepMilliseconds(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    const value: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
    return io.sleep(.fromMilliseconds(value), .awake);
}

fn emptyJsonObject() std.json.Value {
    return .{ .object = .empty };
}

fn cloneOptionalJson(arena: Allocator, input: ?std.json.Value) Allocator.Error!?std.json.Value {
    return if (input) |value| try provider_utils.cloneJsonValue(arena, value) else null;
}

test "shared parseToolCall returns invalid data instead of throwing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = try parseToolCall(.{
        .io = std.testing.io,
        .arena = arena,
        .tools = &.{},
    }, .{ .tool_call_id = "c", .tool_name = "missing", .input = "{bad" });
    try std.testing.expect(call.invalid);
    try std.testing.expect(call.dynamic);
    try std.testing.expectEqual(error.NoSuchToolError, call.err.?.err);
}

test "shared executeToolCall forwards non-final stream values as preliminary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const StreamState = struct {
        index: usize = 0,
        fn next(raw: *anyopaque, _: std.Io) anyerror!?std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.index += 1;
            return switch (self.index) {
                0 => .{ .integer = 1 },
                1 => .{ .integer = 2 },
                else => null,
            };
        }
    };
    const Recorder = struct {
        values: [2]i64 = .{ 0, 0 },
        len: usize = 0,
        all_preliminary: bool = true,
        fn record(raw: ?*anyopaque, _: std.Io, result: TypedToolResult) PreliminaryError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.values[self.len] = result.output.integer;
            self.len += 1;
            self.all_preliminary = self.all_preliminary and result.preliminary;
        }
    };
    const Executor = struct {
        state: *StreamState,
        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            _: Allocator,
            _: std.json.Value,
            _: tool_api.ToolExecutionOptions,
        ) anyerror!tool_api.ToolOutput {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .stream = .{ .ctx = self.state, .vtable = &.{ .next = StreamState.next } } };
        }
    };

    var stream_state: StreamState = .{};
    var executor: Executor = .{ .state = &stream_state };
    var recorder: Recorder = .{};
    const named: tool_api.NamedTool = .{ .name = "progress", .tool = .{
        .input_schema = provider_utils.rawSchema("{}", null),
        .execute = .{ .ctx = &executor, .execute_fn = Executor.execute },
    } };
    const result = (try executeToolCall(.{
        .io = std.testing.io,
        .arena = arena,
        .call = .{ .tool_call_id = "c", .tool_name = "progress", .input = .null },
        .named = &named,
        .messages = &.{},
        .on_preliminary = .{ .ctx = &recorder, .callback = Recorder.record },
    })).?;
    try std.testing.expectEqual(1, recorder.len);
    try std.testing.expect(recorder.all_preliminary);
    try std.testing.expectEqual(1, recorder.values[0]);
    try std.testing.expectEqual(2, result.output.result.output.integer);
}
