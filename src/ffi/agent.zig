const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const options_api = @import("options.zig");
const providers = @import("providers.zig");
const result_api = @import("result.zig");
const runtime_api = @import("runtime.zig");
const stream_api = @import("stream.zig");
const types = @import("types.zig");

const Agent = struct {
    runtime: *runtime_api.Runtime,
    model: *providers.Model,
    refs: std.atomic.Value(usize),
    arena_state: std.heap.ArenaAllocator,
    core: ai.ToolLoopAgent,

    fn retain(self: *Agent) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *Agent) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const runtime = self.runtime;
        const allocator = runtime.allocator();
        self.arena_state.deinit();
        allocator.destroy(self);
        self.model.release();
        runtime.release();
    }
};

fn fromHandle(handle: *types.ai_agent) *Agent {
    return @ptrCast(@alignCast(handle));
}

pub export fn ai_agent_create(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    config: [*c]const types.ai_agent_config,
    out: [*c]?*types.ai_agent,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.modelFromHandle(value) else return runtime.invalid("model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    const value = types.readStruct(types.ai_agent_config, config) catch
        return runtime.invalid("agent config is required and struct_size is below the ABI-v1 prefix", "config.structSize");
    if (value.max_steps == 0) return runtime.invalid("maxSteps must be at least 1", "maxSteps");

    const allocator = runtime.allocator();
    const self = allocator.create(Agent) catch |err| return runtime.fail(err, null);
    self.runtime = runtime;
    self.model = model;
    self.refs = .init(1);
    self.arena_state = .init(allocator);
    runtime.retain();
    model.retain();
    errdefer {
        self.arena_state.deinit();
        allocator.destroy(self);
        model.release();
        runtime.release();
    }

    const arena = self.arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tools = options_api.parseTools(arena, value.tools, value.tools_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    const system = providers.optionalSlice(value.system_ptr, value.system_len) catch
        return runtime.invalid("system pointer is invalid", "system");
    const stop_when = arena.alloc(ai.StopCondition, 1) catch |err| return runtime.fail(err, null);
    stop_when[0] = ai.stepCount(value.max_steps);
    self.core = ai.ToolLoopAgent.init(.{
        .model = .{ .model = model.interface },
        .instructions = if (system.len == 0) null else .{ .text = tryDupe(arena, system) catch |err| return runtime.fail(err, null) },
        .tools = tools,
        .stop_when = stop_when,
    });
    out.* = @ptrCast(self);
    return .ok;
}

pub export fn ai_agent_destroy(handle: ?*types.ai_agent) void {
    const value = handle orelse return;
    fromHandle(value).release();
}

pub export fn ai_agent_run(
    handle: ?*types.ai_agent,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const self = if (handle) |value| fromHandle(value) else return .invalid_argument;
    self.retain();
    defer self.release();
    const runtime = self.runtime;
    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const parsed = options_api.parse(arena_state.allocator(), options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    var agent = configuredAgent(self, parsed, &diagnostics);
    var generated = agent.generate(runtime.io(), allocator, callParameters(parsed)) catch |err|
        return runtime.fail(err, &diagnostics);
    defer generated.deinit();
    const result = result_api.createFromGenerateText(runtime, &generated) catch |err|
        return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

pub export fn ai_agent_stream(
    handle: ?*types.ai_agent,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_stream,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const self = if (handle) |value| fromHandle(value) else return .invalid_argument;
    self.retain();
    const stream = stream_api.allocateForOwner(self.runtime, self, releaseAgent) catch |err| {
        self.release();
        return self.runtime.fail(err, null);
    };
    const parsed = options_api.parse(
        stream.request_arena_state.allocator(),
        options_json,
        options_json_len,
        &stream.diagnostics,
    ) catch |err| {
        const status = self.runtime.fail(err, &stream.diagnostics);
        stream_api.discardBeforeStart(stream);
        return status;
    };
    var agent = configuredAgent(self, parsed, &stream.diagnostics);
    const result = agent.stream(
        self.runtime.io(),
        self.runtime.allocator(),
        callParameters(parsed),
    ) catch |err| {
        const status = self.runtime.fail(err, &stream.diagnostics);
        stream_api.discardBeforeStart(stream);
        return status;
    };
    return stream_api.startTextPrepared(stream, result, out);
}

fn configuredAgent(
    self: *Agent,
    parsed: options_api.ParsedOptions,
    diagnostics: *provider.Diagnostics,
) ai.ToolLoopAgent {
    var result = self.core;
    result.settings.diag = diagnostics;
    if (parsed.wire.instructions) |value| result.settings.instructions = .{ .text = value };
    result.settings.allow_system_in_messages = parsed.wire.allow_system_in_messages;
    result.settings.tool_choice = parsed.tool_choice;
    result.settings.max_output_tokens = parsed.wire.max_output_tokens;
    result.settings.temperature = parsed.wire.temperature;
    result.settings.top_p = parsed.wire.top_p;
    result.settings.top_k = parsed.wire.top_k;
    result.settings.presence_penalty = parsed.wire.presence_penalty;
    result.settings.frequency_penalty = parsed.wire.frequency_penalty;
    result.settings.stop_sequences = parsed.wire.stop_sequences;
    result.settings.seed = parsed.wire.seed;
    result.settings.reasoning = parsed.wire.reasoning;
    result.settings.headers = parsed.wire.headers;
    result.settings.provider_options = parsed.wire.provider_options;
    result.settings.max_retries = parsed.wire.max_retries;
    result.settings.timeout = parsed.timeout;
    result.settings.tools_context = parsed.wire.tools_context;
    result.settings.runtime_context = parsed.wire.runtime_context;
    return result;
}

fn callParameters(parsed: options_api.ParsedOptions) ai.AgentCallParameters {
    return .{
        .prompt = if (parsed.wire.prompt) |value| .{ .text = value } else null,
        .messages = parsed.wire.messages,
        .timeout = parsed.timeout,
    };
}

fn releaseAgent(raw: *anyopaque) void {
    const self: *Agent = @ptrCast(@alignCast(raw));
    self.release();
}

fn tryDupe(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, value);
}
