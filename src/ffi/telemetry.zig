const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");

const Wrapper = struct {
    runtime: *runtime_api.Runtime,
    callbacks: types.ai_telemetry_vtable,
    active: std.atomic.Value(bool),

    fn integration(self: *Wrapper) ai.Telemetry {
        return .{ .ctx = self, .vtable = &core_vtable };
    }

    fn emit(self: *Wrapper, name: []const u8, event: anytype, meta: *const ai.telemetry.Meta) void {
        if (!self.active.load(.acquire)) return;
        const callback = self.callbacks.on_event orelse return;
        const allocator = self.runtime.allocator();
        const json = renderEvent(@TypeOf(event.*), allocator, name, event, meta) catch return;
        defer allocator.free(json);
        callback(self.callbacks.user_data, name.ptr, name.len, json.ptr, json.len);
    }

    fn enter(self: *Wrapper, scope: []const u8, call_id: []const u8) ?*anyopaque {
        if (!self.active.load(.acquire)) return null;
        if (self.callbacks.enter == null and self.callbacks.exit == null) return null;
        const token = std.heap.c_allocator.create(HookToken) catch return null;
        token.* = .{
            .wrapper = self,
            .user_token = if (self.callbacks.enter) |callback| callback(
                self.callbacks.user_data,
                scope.ptr,
                scope.len,
                call_id.ptr,
                call_id.len,
            ) else null,
        };
        return token;
    }

    fn exit(self: *Wrapper, scope: []const u8, token: ?*anyopaque) void {
        const raw_token = token orelse return;
        const hook_token: *HookToken = @ptrCast(@alignCast(raw_token));
        defer std.heap.c_allocator.destroy(hook_token);
        if (hook_token.wrapper != self) return;
        const callback = self.callbacks.exit orelse return;
        callback(self.callbacks.user_data, scope.ptr, scope.len, hook_token.user_token);
    }
};

const HookToken = struct {
    wrapper: *Wrapper,
    user_token: ?*anyopaque,
};

fn renderEvent(
    comptime Event: type,
    allocator: std.mem.Allocator,
    name: []const u8,
    event: *const Event,
    meta: *const ai.telemetry.Meta,
) ![]u8 {
    if (Event == ai.events.GenerateTextStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .operation_id = event.operation_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .instructions = event.instructions,
        .messages = event.messages,
        .tool_count = event.tools.len,
        .max_retries = event.max_retries,
        .timeout_ms = event.timeout_ms,
        .max_output_tokens = event.max_output_tokens,
        .temperature = event.temperature,
        .top_p = event.top_p,
        .top_k = event.top_k,
        .presence_penalty = event.presence_penalty,
        .frequency_penalty = event.frequency_penalty,
        .stop_sequences = event.stop_sequences,
        .seed = event.seed,
        .reasoning = event.reasoning,
        .provider_options = event.provider_options,
        .runtime_context = event.runtime_context,
        .tools_context = event.tools_context,
        .meta = meta.*,
    });
    if (Event == ai.events.StepStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .step_number = event.step_number,
        .instructions = event.instructions,
        .message_count = event.messages.len,
        .tool_count = event.tools.len,
        .previous_step_count = event.previous_steps.len,
        .provider_options = event.provider_options,
        .runtime_context = event.runtime_context,
        .tools_context = event.tools_context,
        .meta = meta.*,
    });
    if (Event == ai.events.LanguageModelCallStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .instructions = event.instructions,
        .message_count = event.messages.len,
        .tool_count = if (event.tools) |tools| tools.len else 0,
        .meta = meta.*,
    });
    if (Event == ai.events.LanguageModelCallEndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .finish_reason = event.finish_reason,
        .usage = event.usage,
        .content_count = event.content.len,
        .response_id = event.response_id,
        .performance = event.performance,
        .meta = meta.*,
    });
    if (Event == ai.events.ToolExecutionStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .tool_call = event.tool_call,
        .message_count = event.messages.len,
        .tool_context = event.tool_context,
        .meta = meta.*,
    });
    if (Event == ai.events.ToolExecutionEndEvent) {
        const output: std.json.Value = switch (event.tool_output) {
            .result => |value| value,
            .err => |err| .{ .string = @errorName(err) },
        };
        return provider.wire.stringifyAlloc(allocator, .{
            .type = name,
            .call_id = event.call_id,
            .tool_call = event.tool_call,
            .message_count = event.messages.len,
            .tool_context = event.tool_context,
            .tool_output = output,
            .tool_execution_ms = event.tool_execution_ms,
            .meta = meta.*,
        });
    }
    if (Event == ai.events.StepEndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .step_number = event.step_number,
        .text = event.step_result.text(),
        .finish_reason = event.step_result.finish_reason,
        .usage = event.step_result.usage,
        .warnings = event.step_result.warnings,
        .provider_metadata = event.step_result.provider_metadata,
        .meta = meta.*,
    });
    if (Event == ai.events.EndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .step_number = event.step_number,
        .text = event.text,
        .finish_reason = event.finish_reason,
        .usage = event.usage,
        .warnings = event.warnings,
        .response_message_count = event.response_messages.len,
        .step_count = event.steps.len,
        .runtime_context = event.runtime_context,
        .tools_context = event.tools_context,
        .meta = meta.*,
    });
    if (Event == ai.events.AbortEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .reason = event.reason,
        .step_count = event.steps.len,
        .meta = meta.*,
    });
    if (Event == ai.events.ErrorEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .error_code = @errorName(event.err),
        .meta = meta.*,
    });
    if (Event == ai.events.GenerateObjectStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .operation_id = event.operation_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .instructions = event.instructions,
        .messages = event.messages,
        .max_output_tokens = event.max_output_tokens,
        .temperature = event.temperature,
        .top_p = event.top_p,
        .top_k = event.top_k,
        .presence_penalty = event.presence_penalty,
        .frequency_penalty = event.frequency_penalty,
        .seed = event.seed,
        .max_retries = event.max_retries,
        .provider_options = event.provider_options,
        .output = event.output,
        .schema = event.schema,
        .schema_name = event.schema_name,
        .schema_description = event.schema_description,
        .meta = meta.*,
    });
    if (Event == ai.events.ObjectStepStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .step_number = event.step_number,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .provider_options = event.provider_options,
        .headers = event.headers,
        .meta = meta.*,
    });
    if (Event == ai.events.ObjectStepEndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .step_number = event.step_number,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .finish_reason = event.finish_reason,
        .usage = event.usage,
        .object_text = event.object_text,
        .reasoning = event.reasoning,
        .warnings = event.warnings,
        .request = event.request,
        .response = event.response,
        .provider_metadata = event.provider_metadata,
        .ms_to_first_chunk = event.ms_to_first_chunk,
        .meta = meta.*,
    });
    if (Event == ai.events.GenerateObjectEndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .object = event.object,
        .error_code = if (event.err) |err| @errorName(err) else null,
        .reasoning = event.reasoning,
        .finish_reason = event.finish_reason,
        .usage = event.usage,
        .warnings = event.warnings,
        .request = event.request,
        .response = event.response,
        .provider_metadata = event.provider_metadata,
        .meta = meta.*,
    });
    if (Event == ai.events.EmbedStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .embed_call_id = event.embed_call_id,
        .operation_id = event.operation_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .values = event.values,
        .meta = meta.*,
    });
    if (Event == ai.events.EmbedEndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .embed_call_id = event.embed_call_id,
        .operation_id = event.operation_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .values = event.values,
        .embeddings = event.embeddings,
        .usage = event.usage,
        .warnings = event.warnings,
        .meta = meta.*,
    });
    if (Event == ai.events.RerankStartEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .operation_id = event.operation_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .documents_type = @tagName(event.documents),
        .query = event.query,
        .top_n = event.top_n,
        .meta = meta.*,
    });
    if (Event == ai.events.RerankEndEvent) return provider.wire.stringifyAlloc(allocator, .{
        .type = name,
        .call_id = event.call_id,
        .operation_id = event.operation_id,
        .provider_name = event.provider_name,
        .model_id = event.model_id,
        .documents_type = event.documents_type,
        .ranking = event.ranking,
        .meta = meta.*,
    });
    @compileError("unhandled telemetry event type " ++ @typeName(Event));
}

var registrations_mutex: std.atomic.Mutex = .unlocked;
var registrations: std.ArrayList(*Wrapper) = .empty;

pub export fn ai_telemetry_register(
    runtime_handle: ?*types.ai_runtime,
    callbacks: [*c]const types.ai_telemetry_vtable,
    out: [*c]?*types.ai_telemetry_registration,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const value = types.readStruct(types.ai_telemetry_vtable, callbacks) catch
        return runtime.invalid("telemetry vtable is required and struct_size is below the ABI-v1 prefix", "callbacks.structSize");
    if (value.on_event == null and value.enter == null and value.exit == null) {
        return runtime.invalid("telemetry vtable has no callbacks", "callbacks");
    }

    const wrapper = std.heap.c_allocator.create(Wrapper) catch return runtime.fail(error.OutOfMemory, null);
    wrapper.* = .{ .runtime = runtime, .callbacks = value, .active = .init(true) };
    runtime.retain();
    lock(&registrations_mutex);
    registrations.append(std.heap.c_allocator, wrapper) catch |err| {
        registrations_mutex.unlock();
        runtime.release();
        std.heap.c_allocator.destroy(wrapper);
        return runtime.fail(err, null);
    };
    registrations_mutex.unlock();
    const integration = [_]ai.Telemetry{wrapper.integration()};
    // The registry is process-global, so its backing allocator must outlive
    // every individual runtime that can register an integration.
    ai.registerTelemetry(std.heap.c_allocator, &integration) catch |err| {
        lock(&registrations_mutex);
        for (registrations.items, 0..) |item, index| if (item == wrapper) {
            _ = registrations.orderedRemove(index);
            break;
        };
        registrations_mutex.unlock();
        runtime.release();
        std.heap.c_allocator.destroy(wrapper);
        return runtime.fail(err, null);
    };
    out.* = @ptrCast(wrapper);
    return .ok;
}

pub export fn ai_telemetry_unregister(handle: ?*types.ai_telemetry_registration) void {
    const value = handle orelse return;
    const wrapper: *Wrapper = @ptrCast(@alignCast(value));
    wrapper.active.store(false, .release);
}

/// Requires application operations that may hold a copied dispatcher to be
/// quiescent. This mirrors the core registry's teardown contract.
pub export fn ai_telemetry_clear() void {
    ai.clearTelemetryRegistry();
    lock(&registrations_mutex);
    defer registrations_mutex.unlock();
    for (registrations.items) |wrapper| {
        wrapper.active.store(false, .release);
        const runtime = wrapper.runtime;
        std.heap.c_allocator.destroy(wrapper);
        runtime.release();
    }
    registrations.deinit(std.heap.c_allocator);
    registrations = .empty;
}

const core_vtable: ai.Telemetry.VTable = .{
    .onStart = EventBridge(ai.events.GenerateTextStartEvent, "generate-text-start").call,
    .onStepStart = EventBridge(ai.events.StepStartEvent, "step-start").call,
    .onLanguageModelCallStart = EventBridge(ai.events.LanguageModelCallStartEvent, "language-model-call-start").call,
    .onLanguageModelCallEnd = EventBridge(ai.events.LanguageModelCallEndEvent, "language-model-call-end").call,
    .onToolExecutionStart = EventBridge(ai.events.ToolExecutionStartEvent, "tool-execution-start").call,
    .onToolExecutionEnd = EventBridge(ai.events.ToolExecutionEndEvent, "tool-execution-end").call,
    .onStepEnd = EventBridge(ai.events.StepEndEvent, "step-end").call,
    .onEnd = EventBridge(ai.events.EndEvent, "generate-text-end").call,
    .onAbort = EventBridge(ai.events.AbortEvent, "abort").call,
    .onError = EventBridge(ai.events.ErrorEvent, "error").call,
    .onObjectStepStart = EventBridge(ai.events.ObjectStepStartEvent, "object-step-start").call,
    .onObjectStepEnd = EventBridge(ai.events.ObjectStepEndEvent, "object-step-end").call,
    .onEmbedStart = EventBridge(ai.events.EmbedStartEvent, "embed-start").call,
    .onEmbedEnd = EventBridge(ai.events.EmbedEndEvent, "embed-end").call,
    .onRerankStart = EventBridge(ai.events.RerankStartEvent, "rerank-start").call,
    .onRerankEnd = EventBridge(ai.events.RerankEndEvent, "rerank-end").call,
    .onObjectStart = EventBridge(ai.events.GenerateObjectStartEvent, "generate-object-start").call,
    .onObjectEnd = EventBridge(ai.events.GenerateObjectEndEvent, "generate-object-end").call,
    .enterModelCall = enterModelCall,
    .exitModelCall = exitModelCall,
    .enterToolExecution = enterToolExecution,
    .exitToolExecution = exitToolExecution,
};

fn EventBridge(comptime Event: type, comptime name: []const u8) type {
    return struct {
        fn call(raw: ?*anyopaque, event: *const Event, meta: *const ai.telemetry.Meta) anyerror!void {
            const wrapper: *Wrapper = @ptrCast(@alignCast(raw.?));
            wrapper.emit(name, event, meta);
        }
    };
}

fn enterModelCall(raw: ?*anyopaque, call_id: []const u8) ?*anyopaque {
    const wrapper: *Wrapper = @ptrCast(@alignCast(raw.?));
    return wrapper.enter("model-call", call_id);
}

fn exitModelCall(raw: ?*anyopaque, token: ?*anyopaque) void {
    const wrapper: *Wrapper = @ptrCast(@alignCast(raw.?));
    wrapper.exit("model-call", token);
}

fn enterToolExecution(raw: ?*anyopaque, call_id: []const u8) ?*anyopaque {
    const wrapper: *Wrapper = @ptrCast(@alignCast(raw.?));
    return wrapper.enter("tool-execution", call_id);
}

fn exitToolExecution(raw: ?*anyopaque, token: ?*anyopaque) void {
    const wrapper: *Wrapper = @ptrCast(@alignCast(raw.?));
    wrapper.exit("tool-execution", token);
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

test "telemetry clear is idempotent without registrations" {
    ai_telemetry_clear();
    ai_telemetry_clear();
}
