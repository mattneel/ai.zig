const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const otlp = @import("otlp.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    endpoint: []const u8 = "http://localhost:4318/v1/traces",
    headers: []const provider.Header = &.{},
    service_name: []const u8 = "ai.zig",
    max_batch_size: usize = 64,
    transport: ?provider_utils.HttpTransport = null,
};

pub const InitError = Allocator.Error || error{InvalidBatchSize};
pub const FlushError = provider_utils.RequestError || error{OtlpExportFailed};

const Settings = struct {
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?i64 = null,
};

const OwnedSpan = struct {
    trace_id: otlp.TraceId,
    span_id: otlp.SpanId,
    parent_span_id: ?otlp.SpanId,
    name: []u8,
    kind: otlp.SpanKind,
    start_time_unix_nano: u64,
    end_time_unix_nano: u64,
    hook_started: bool = false,
    event_ended: bool = false,
    attributes: std.ArrayList(otlp.Attribute) = .empty,
    status_code: ?otlp.StatusCode = null,
    status_message: ?[]u8 = null,

    fn init(
        gpa: Allocator,
        trace_id: otlp.TraceId,
        parent_span_id: ?otlp.SpanId,
        span_id: otlp.SpanId,
        name: []const u8,
        kind: otlp.SpanKind,
        started: u64,
    ) Allocator.Error!*OwnedSpan {
        const self = try gpa.create(OwnedSpan);
        errdefer gpa.destroy(self);
        self.* = .{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = parent_span_id,
            .name = try gpa.dupe(u8, name),
            .kind = kind,
            .start_time_unix_nano = started,
            .end_time_unix_nano = started,
        };
        return self;
    }

    fn deinit(self: *OwnedSpan, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.attributes.items) |attribute| deinitAttributeValue(gpa, attribute.value);
        self.attributes.deinit(gpa);
        if (self.status_message) |message| gpa.free(message);
        gpa.destroy(self);
    }

    fn view(self: *const OwnedSpan) otlp.Span {
        return .{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .parent_span_id = self.parent_span_id,
            .name = self.name,
            .kind = self.kind,
            .start_time_unix_nano = self.start_time_unix_nano,
            .end_time_unix_nano = self.end_time_unix_nano,
            .attributes = self.attributes.items,
            .status = if (self.status_code) |code| .{
                .code = code,
                .message = self.status_message,
            } else null,
        };
    }

    fn finish(self: *OwnedSpan, ended: u64) void {
        self.end_time_unix_nano = @max(self.start_time_unix_nano, ended);
    }

    fn setString(self: *OwnedSpan, gpa: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, value);
        errdefer gpa.free(owned);
        try self.setValue(gpa, key, .{ .string = owned });
    }

    fn setInt(self: *OwnedSpan, gpa: Allocator, key: []const u8, value: i64) Allocator.Error!void {
        try self.setValue(gpa, key, .{ .int = value });
    }

    fn setDouble(self: *OwnedSpan, gpa: Allocator, key: []const u8, value: f64) Allocator.Error!void {
        try self.setValue(gpa, key, .{ .double = value });
    }

    fn setStringArray(
        self: *OwnedSpan,
        gpa: Allocator,
        key: []const u8,
        values: []const []const u8,
    ) Allocator.Error!void {
        const owned = try gpa.alloc([]const u8, values.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |item| gpa.free(item);
            gpa.free(owned);
        }
        for (values, owned) |value, *item| {
            item.* = try gpa.dupe(u8, value);
            initialized += 1;
        }
        try self.setValue(gpa, key, .{ .string_array = owned });
    }

    fn setError(self: *OwnedSpan, gpa: Allocator, err: anyerror) Allocator.Error!void {
        try self.setString(gpa, "error.type", @errorName(err));
        if (self.status_message) |message| gpa.free(message);
        self.status_message = null;
        const message = try gpa.dupe(u8, @errorName(err));
        self.status_message = message;
        self.status_code = .error_status;
    }

    fn setValue(
        self: *OwnedSpan,
        gpa: Allocator,
        key: []const u8,
        value: otlp.AttributeValue,
    ) Allocator.Error!void {
        for (self.attributes.items) |*attribute| {
            if (!std.mem.eql(u8, attribute.key, key)) continue;
            deinitAttributeValue(gpa, attribute.value);
            attribute.value = value;
            return;
        }
        try self.attributes.append(gpa, .{ .key = key, .value = value });
    }
};

fn deinitAttributeValue(gpa: Allocator, value: otlp.AttributeValue) void {
    switch (value) {
        .string => |item| gpa.free(item),
        .string_array => |items| {
            for (items) |item| gpa.free(item);
            gpa.free(items);
        },
        .int, .double, .boolean => {},
    }
}

const ToolEntry = struct {
    tool_call_id: []u8,
    span: *OwnedSpan,
    hook: ?*HookToken = null,
};

const CallState = struct {
    trace_id: otlp.TraceId,
    root: ?*OwnedSpan,
    step: ?*OwnedSpan = null,
    model: ?*OwnedSpan = null,
    last_model_span_id: ?otlp.SpanId = null,
    tools: std.ArrayList(ToolEntry) = .empty,
    pending_tool_hooks: std.ArrayList(*HookToken) = .empty,
    settings: Settings,

    fn deinit(self: *CallState, gpa: Allocator) void {
        if (self.root) |span| span.deinit(gpa);
        if (self.step) |span| span.deinit(gpa);
        if (self.model) |span| span.deinit(gpa);
        for (self.tools.items) |entry| {
            gpa.free(entry.tool_call_id);
            entry.span.deinit(gpa);
        }
        self.tools.deinit(gpa);
        self.pending_tool_hooks.deinit(gpa);
        gpa.destroy(self);
    }
};

const EmbedEntry = struct {
    call_id: []u8,
    embed_call_id: []u8,
    span: *OwnedSpan,
};

const RerankEntry = struct {
    call_id: []u8,
    span: *OwnedSpan,
};

const HookKind = enum { model, tool };

const HookToken = struct {
    exporter: *Exporter,
    kind: HookKind,
    call_id: []u8,
    span_id: ?otlp.SpanId = null,
    started: u64,

    fn deinit(self: *HookToken) void {
        const gpa = self.exporter.gpa;
        gpa.free(self.call_id);
        gpa.destroy(self);
    }
};

/// Stateful, thread-safe telemetry integration and OTLP batch exporter.
///
/// `deinit` flushes pending spans. When the exporter is globally registered,
/// call `ai.clearTelemetryRegistry()` before destroying it: the core registry
/// stores borrowed integration handles and has no per-registration removal.
pub const Exporter = struct {
    gpa: Allocator,
    io: std.Io,
    endpoint: []u8,
    headers: []provider.Header,
    service_name: []u8,
    max_batch_size: usize,
    custom_transport: ?provider_utils.HttpTransport,
    owned_client: ?provider_utils.HttpClientTransport,
    state_mutex: std.Io.Mutex = .init,
    flush_mutex: std.Io.Mutex = .init,
    calls: std.StringHashMapUnmanaged(*CallState) = .empty,
    embeds: std.ArrayList(EmbedEntry) = .empty,
    reranks: std.ArrayList(RerankEntry) = .empty,
    batch: std.ArrayList(*OwnedSpan) = .empty,

    pub fn init(gpa: Allocator, io: std.Io, config: Config) InitError!Exporter {
        if (config.max_batch_size == 0) return error.InvalidBatchSize;
        const endpoint = try gpa.dupe(u8, config.endpoint);
        errdefer gpa.free(endpoint);
        const service_name = try gpa.dupe(u8, config.service_name);
        errdefer gpa.free(service_name);
        const headers = try cloneHeaders(gpa, config.headers);
        errdefer deinitHeaders(gpa, headers);

        return .{
            .gpa = gpa,
            .io = io,
            .endpoint = endpoint,
            .headers = headers,
            .service_name = service_name,
            .max_batch_size = config.max_batch_size,
            .custom_transport = config.transport,
            .owned_client = if (config.transport == null)
                provider_utils.HttpClientTransport.init(gpa, io)
            else
                null,
        };
    }

    pub fn telemetry(self: *Exporter) ai.Telemetry {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn pendingSpanCount(self: *Exporter) usize {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.batch.items.len;
    }

    /// Exports the complete current batch as one OTLP/HTTP JSON request.
    /// Failed requests leave the batch intact for a later retry.
    pub fn flush(self: *Exporter) FlushError!void {
        try self.flush_mutex.lock(self.io);
        defer self.flush_mutex.unlock(self.io);
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);

        if (self.batch.items.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const spans = try arena.alloc(otlp.Span, self.batch.items.len);
        for (self.batch.items, spans) |span, *view| view.* = span.view();
        const body = try otlp.encode(arena, .{
            .service_name = self.service_name,
            .spans = spans,
        });
        const headers = try requestHeaders(arena, self.headers);
        const transport = if (self.custom_transport) |custom|
            custom
        else
            self.owned_client.?.transport();
        var response = try transport.request(self.io, arena, .{
            .method = .POST,
            .url = self.endpoint,
            .headers = headers,
            .body = body,
            .redirect_behavior = .not_allowed,
        }, null);
        defer response.body.deinit(self.io);
        if (response.status < 200 or response.status >= 300) return error.OtlpExportFailed;

        for (self.batch.items) |span| span.deinit(self.gpa);
        self.batch.clearRetainingCapacity();
    }

    /// Flushes, releases exporter-owned memory, and returns any flush error
    /// after cleanup. No callbacks or hook scopes may still be active.
    pub fn deinit(self: *Exporter) FlushError!void {
        var flush_error: ?FlushError = null;
        self.flush() catch |err| {
            flush_error = err;
        };

        self.state_mutex.lockUncancelable(self.io);
        var iterator = self.calls.iterator();
        while (iterator.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.gpa);
        }
        self.calls.deinit(self.gpa);
        for (self.embeds.items) |entry| {
            self.gpa.free(entry.call_id);
            self.gpa.free(entry.embed_call_id);
            entry.span.deinit(self.gpa);
        }
        self.embeds.deinit(self.gpa);
        for (self.reranks.items) |entry| {
            self.gpa.free(entry.call_id);
            entry.span.deinit(self.gpa);
        }
        self.reranks.deinit(self.gpa);
        for (self.batch.items) |span| span.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        self.state_mutex.unlock(self.io);

        if (self.owned_client) |*client| client.deinit();
        deinitHeaders(self.gpa, self.headers);
        self.gpa.free(self.endpoint);
        self.gpa.free(self.service_name);
        self.* = undefined;
        if (flush_error) |err| return err;
    }

    fn onGenerateStart(
        self: *Exporter,
        event: *const ai.events.GenerateTextStartEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.calls.contains(event.call_id)) return;

        const trace_id = self.newTraceId();
        const name = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{
            operationName(event.operation_id),
            event.model_id,
        });
        defer self.gpa.free(name);
        const root = try self.newSpan(trace_id, null, name, .internal);
        errdefer root.deinit(self.gpa);
        try addIdentity(root, self.gpa, operationName(event.operation_id), event.provider_name, event.model_id);
        try addSettings(root, self.gpa, .{
            .max_output_tokens = event.max_output_tokens,
            .temperature = event.temperature,
            .top_p = event.top_p,
            .top_k = event.top_k,
            .presence_penalty = event.presence_penalty,
            .frequency_penalty = event.frequency_penalty,
            .stop_sequences = event.stop_sequences,
            .seed = event.seed,
        });
        if (meta.function_id) |function_id| try root.setString(self.gpa, "gen_ai.agent.name", function_id);
        if (meta.record_inputs) if (event.instructions) |instructions|
            try addSystemInstructions(root, self.gpa, instructions);

        const state = try self.gpa.create(CallState);
        errdefer self.gpa.destroy(state);
        state.* = .{
            .trace_id = trace_id,
            .root = root,
            .settings = .{
                .max_output_tokens = event.max_output_tokens,
                .temperature = event.temperature,
                .top_p = event.top_p,
                .top_k = event.top_k,
                .presence_penalty = event.presence_penalty,
                .frequency_penalty = event.frequency_penalty,
                .stop_sequences = event.stop_sequences,
                .seed = event.seed,
            },
        };
        const key = try self.gpa.dupe(u8, event.call_id);
        errdefer self.gpa.free(key);
        try self.calls.put(self.gpa, key, state);
    }

    fn onStepStart(self: *Exporter, event: *const ai.events.StepStartEvent) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const state = self.calls.get(event.call_id) orelse return;
        if (state.step != null) return;
        const name = try std.fmt.allocPrint(self.gpa, "step {d}", .{event.step_number + 1});
        defer self.gpa.free(name);
        const parent = if (state.root) |root| root.span_id else null;
        const span = try self.newSpan(state.trace_id, parent, name, .internal);
        errdefer span.deinit(self.gpa);
        try span.setString(self.gpa, "gen_ai.operation.name", "agent_step");
        state.step = span;
    }

    fn onModelStart(
        self: *Exporter,
        event: *const ai.events.LanguageModelCallStartEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const state = self.calls.get(event.call_id) orelse return;
        if (state.model != null) return;
        const name = try std.fmt.allocPrint(self.gpa, "chat {s}", .{event.model_id});
        defer self.gpa.free(name);
        const parent = if (state.step) |step|
            step.span_id
        else if (state.root) |root|
            root.span_id
        else
            null;
        const span = try self.newSpan(state.trace_id, parent, name, .client);
        errdefer span.deinit(self.gpa);
        try addIdentity(span, self.gpa, "chat", event.provider_name, event.model_id);
        try addSettings(span, self.gpa, state.settings);
        if (meta.record_inputs) if (event.instructions) |instructions|
            try addSystemInstructions(span, self.gpa, instructions);
        state.model = span;
    }

    fn onModelEnd(
        self: *Exporter,
        event: *const ai.events.LanguageModelCallEndEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const state = self.calls.get(event.call_id) orelse break :blk;
            const span = state.model orelse break :blk;
            try addModelResponse(span, self.gpa, event.model_id, event.response_id, event.finish_reason, event.usage);
            try span.setDouble(self.gpa, "gen_ai.client.operation.duration", event.performance.response_time_ms / 1000.0);
            if (event.performance.time_to_first_output_ms) |duration|
                try span.setDouble(self.gpa, "gen_ai.client.operation.time_to_first_chunk", duration / 1000.0);
            if (meta.record_outputs) try addContentOutput(span, self.gpa, event.content, event.finish_reason);
            if (span.end_time_unix_nano == span.start_time_unix_nano) span.finish(self.nowUnixNano());
            state.last_model_span_id = span.span_id;
            should_flush = try self.queueSpanLocked(span);
            state.model = null;
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onToolStart(
        self: *Exporter,
        event: *const ai.events.ToolExecutionStartEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const state = self.calls.get(event.call_id) orelse return;
        const name = try std.fmt.allocPrint(self.gpa, "execute_tool {s}", .{event.tool_call.tool_name});
        defer self.gpa.free(name);
        const parent = state.last_model_span_id orelse if (state.step) |step|
            step.span_id
        else if (state.root) |root|
            root.span_id
        else
            null;
        const span = try self.newSpan(state.trace_id, parent, name, .internal);
        errdefer span.deinit(self.gpa);
        try span.setString(self.gpa, "gen_ai.operation.name", "execute_tool");
        try span.setString(self.gpa, "gen_ai.tool.name", event.tool_call.tool_name);
        try span.setString(self.gpa, "gen_ai.tool.call.id", event.tool_call.tool_call_id);
        try span.setString(self.gpa, "gen_ai.tool.type", "function");
        if (meta.record_inputs) {
            const arguments = try provider_utils.stringifyJsonValueAlloc(self.gpa, event.tool_call.input);
            defer self.gpa.free(arguments);
            try span.setString(self.gpa, "gen_ai.tool.call.arguments", arguments);
        }

        const tool_call_id = try self.gpa.dupe(u8, event.tool_call.tool_call_id);
        errdefer self.gpa.free(tool_call_id);
        var hook: ?*HookToken = null;
        for (state.pending_tool_hooks.items) |candidate| {
            if (candidate.span_id != null) continue;
            candidate.span_id = span.span_id;
            span.start_time_unix_nano = candidate.started;
            span.end_time_unix_nano = candidate.started;
            span.hook_started = true;
            hook = candidate;
            break;
        }
        try state.tools.append(self.gpa, .{
            .tool_call_id = tool_call_id,
            .span = span,
            .hook = hook,
        });
    }

    fn onToolEnd(
        self: *Exporter,
        event: *const ai.events.ToolExecutionEndEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const state = self.calls.get(event.call_id) orelse break :blk;
            const index = findToolIndex(state, event.tool_call.tool_call_id) orelse break :blk;
            const entry = &state.tools.items[index];
            try entry.span.setDouble(
                self.gpa,
                "gen_ai.execute_tool.duration",
                event.tool_execution_ms / 1000.0,
            );
            switch (event.tool_output) {
                .result => |value| if (meta.record_outputs) {
                    const encoded = try provider_utils.stringifyJsonValueAlloc(self.gpa, value);
                    defer self.gpa.free(encoded);
                    try entry.span.setString(self.gpa, "gen_ai.tool.call.result", encoded);
                },
                .err => |err| try entry.span.setError(self.gpa, err),
            }
            entry.span.event_ended = true;
            if (entry.hook != null) break :blk;
            entry.span.finish(self.nowUnixNano());
            const removed = state.tools.orderedRemove(index);
            should_flush = try self.queueSpanLocked(removed.span);
            self.gpa.free(removed.tool_call_id);
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onStepEnd(self: *Exporter, event: *const ai.events.StepEndEvent) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const state = self.calls.get(event.call_id) orelse break :blk;
            const span = state.step orelse break :blk;
            span.finish(self.nowUnixNano());
            should_flush = try self.queueSpanLocked(span);
            state.step = null;
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onGenerateEnd(
        self: *Exporter,
        event: *const ai.events.EndEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const state = self.calls.get(event.call_id) orelse break :blk;
            const root = state.root orelse break :blk;
            try addModelResponse(root, self.gpa, event.model.modelId(), null, event.finish_reason, event.usage);
            if (meta.record_outputs) try addTextOutput(root, self.gpa, event.text, event.finish_reason);
            root.finish(self.nowUnixNano());
            should_flush = try self.queueSpanLocked(root);
            state.root = null;
            self.removeCallLocked(event.call_id);
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onObjectStart(
        self: *Exporter,
        event: *const ai.events.GenerateObjectStartEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.calls.contains(event.call_id)) return;
        const trace_id = self.newTraceId();
        const name = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{
            operationName(event.operation_id),
            event.model_id,
        });
        defer self.gpa.free(name);
        const root = try self.newSpan(trace_id, null, name, .internal);
        errdefer root.deinit(self.gpa);
        try addIdentity(root, self.gpa, operationName(event.operation_id), event.provider_name, event.model_id);
        try root.setString(self.gpa, "gen_ai.output.type", "json");
        const settings: Settings = .{
            .max_output_tokens = event.max_output_tokens,
            .temperature = event.temperature,
            .top_p = event.top_p,
            .top_k = event.top_k,
            .presence_penalty = event.presence_penalty,
            .frequency_penalty = event.frequency_penalty,
            .seed = event.seed,
        };
        try addSettings(root, self.gpa, settings);
        if (meta.function_id) |function_id| try root.setString(self.gpa, "gen_ai.agent.name", function_id);
        if (meta.record_inputs) if (event.instructions) |instructions|
            try addSystemInstructions(root, self.gpa, instructions);

        const state = try self.gpa.create(CallState);
        errdefer self.gpa.destroy(state);
        state.* = .{
            .trace_id = trace_id,
            .root = root,
            .settings = settings,
        };
        const key = try self.gpa.dupe(u8, event.call_id);
        errdefer self.gpa.free(key);
        try self.calls.put(self.gpa, key, state);
    }

    fn onObjectStepStart(self: *Exporter, event: *const ai.events.ObjectStepStartEvent) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const state = self.calls.get(event.call_id) orelse return;
        if (state.model != null) return;
        const name = try std.fmt.allocPrint(self.gpa, "chat {s}", .{event.model_id});
        defer self.gpa.free(name);
        const parent = if (state.root) |root| root.span_id else null;
        const span = try self.newSpan(state.trace_id, parent, name, .client);
        errdefer span.deinit(self.gpa);
        try addIdentity(span, self.gpa, "chat", event.provider_name, event.model_id);
        try span.setString(self.gpa, "gen_ai.output.type", "json");
        try addSettings(span, self.gpa, state.settings);
        state.model = span;
    }

    fn onObjectStepEnd(
        self: *Exporter,
        event: *const ai.events.ObjectStepEndEvent,
        meta: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const state = self.calls.get(event.call_id) orelse break :blk;
            const span = state.model orelse break :blk;
            try addModelResponse(span, self.gpa, event.model_id, event.response.id, event.finish_reason, event.usage);
            if (meta.record_outputs) try addTextOutput(span, self.gpa, event.object_text, event.finish_reason);
            span.finish(self.nowUnixNano());
            state.last_model_span_id = span.span_id;
            should_flush = try self.queueSpanLocked(span);
            state.model = null;
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onObjectEnd(
        self: *Exporter,
        event: *const ai.events.GenerateObjectEndEvent,
        _: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const state = self.calls.get(event.call_id) orelse break :blk;
            const root = state.root orelse break :blk;
            try addModelResponse(root, self.gpa, event.response.model_id, event.response.id, event.finish_reason, event.usage);
            if (event.err) |err| try root.setError(self.gpa, err);
            root.finish(self.nowUnixNano());
            should_flush = try self.queueSpanLocked(root);
            state.root = null;
            self.removeCallLocked(event.call_id);
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onEmbedStart(
        self: *Exporter,
        event: *const ai.events.EmbedStartEvent,
        _: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const trace_id = self.newTraceId();
        const name = try std.fmt.allocPrint(self.gpa, "embeddings {s}", .{event.model_id});
        defer self.gpa.free(name);
        const span = try self.newSpan(trace_id, null, name, .client);
        errdefer span.deinit(self.gpa);
        try addIdentity(span, self.gpa, "embeddings", event.provider_name, event.model_id);
        const call_id = try self.gpa.dupe(u8, event.call_id);
        errdefer self.gpa.free(call_id);
        const embed_call_id = try self.gpa.dupe(u8, event.embed_call_id);
        errdefer self.gpa.free(embed_call_id);
        try self.embeds.append(self.gpa, .{
            .call_id = call_id,
            .embed_call_id = embed_call_id,
            .span = span,
        });
    }

    fn onEmbedEnd(
        self: *Exporter,
        event: *const ai.events.EmbedEndEvent,
        _: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const index = findEmbedIndex(self, event.call_id, event.embed_call_id) orelse break :blk;
            var entry = self.embeds.orderedRemove(index);
            if (event.usage.tokens) |tokens| try setTokenCount(entry.span, self.gpa, "gen_ai.usage.input_tokens", tokens);
            try entry.span.setString(self.gpa, "gen_ai.response.model", event.model_id);
            entry.span.finish(self.nowUnixNano());
            should_flush = try self.queueSpanLocked(entry.span);
            self.gpa.free(entry.call_id);
            self.gpa.free(entry.embed_call_id);
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onRerankStart(
        self: *Exporter,
        event: *const ai.events.RerankStartEvent,
        _: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        const trace_id = self.newTraceId();
        const name = try std.fmt.allocPrint(self.gpa, "rerank {s}", .{event.model_id});
        defer self.gpa.free(name);
        const span = try self.newSpan(trace_id, null, name, .client);
        errdefer span.deinit(self.gpa);
        try addIdentity(span, self.gpa, "rerank", event.provider_name, event.model_id);
        const call_id = try self.gpa.dupe(u8, event.call_id);
        errdefer self.gpa.free(call_id);
        try self.reranks.append(self.gpa, .{ .call_id = call_id, .span = span });
    }

    fn onRerankEnd(
        self: *Exporter,
        event: *const ai.events.RerankEndEvent,
        _: *const ai.telemetry.Meta,
    ) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        const result = blk: {
            defer self.state_mutex.unlock(self.io);
            const index = findRerankIndex(self, event.call_id) orelse break :blk;
            const entry = self.reranks.orderedRemove(index);
            try entry.span.setString(self.gpa, "gen_ai.response.model", event.model_id);
            entry.span.finish(self.nowUnixNano());
            should_flush = try self.queueSpanLocked(entry.span);
            self.gpa.free(entry.call_id);
        };
        _ = result;
        if (should_flush) try self.flush();
    }

    fn onAbort(self: *Exporter, event: *const ai.events.AbortEvent) anyerror!void {
        try self.finishCallWithError(event.call_id, error.Canceled);
    }

    fn onError(self: *Exporter, event: *const ai.events.ErrorEvent) anyerror!void {
        try self.finishCallWithError(event.call_id, event.err);
    }

    fn finishCallWithError(self: *Exporter, call_id: []const u8, err: anyerror) anyerror!void {
        try self.state_mutex.lock(self.io);
        var should_flush = false;
        {
            defer self.state_mutex.unlock(self.io);
            if (self.calls.get(call_id)) |state| {
                if (state.model) |span| {
                    try span.setError(self.gpa, err);
                    span.finish(self.nowUnixNano());
                    should_flush = (try self.queueSpanLocked(span)) or should_flush;
                    state.model = null;
                }
                for (state.tools.items) |entry| {
                    try entry.span.setError(self.gpa, err);
                    entry.span.finish(self.nowUnixNano());
                    should_flush = (try self.queueSpanLocked(entry.span)) or should_flush;
                    self.gpa.free(entry.tool_call_id);
                }
                state.tools.clearRetainingCapacity();
                if (state.step) |span| {
                    try span.setError(self.gpa, err);
                    span.finish(self.nowUnixNano());
                    should_flush = (try self.queueSpanLocked(span)) or should_flush;
                    state.step = null;
                }
                if (state.root) |span| {
                    try span.setError(self.gpa, err);
                    span.finish(self.nowUnixNano());
                    should_flush = (try self.queueSpanLocked(span)) or should_flush;
                    state.root = null;
                }
                self.removeCallLocked(call_id);
            }

            var embed_index = self.embeds.items.len;
            while (embed_index != 0) {
                embed_index -= 1;
                if (!std.mem.eql(u8, self.embeds.items[embed_index].call_id, call_id)) continue;
                const entry = self.embeds.orderedRemove(embed_index);
                try entry.span.setError(self.gpa, err);
                entry.span.finish(self.nowUnixNano());
                should_flush = (try self.queueSpanLocked(entry.span)) or should_flush;
                self.gpa.free(entry.call_id);
                self.gpa.free(entry.embed_call_id);
            }
            var rerank_index = self.reranks.items.len;
            while (rerank_index != 0) {
                rerank_index -= 1;
                if (!std.mem.eql(u8, self.reranks.items[rerank_index].call_id, call_id)) continue;
                const entry = self.reranks.orderedRemove(rerank_index);
                try entry.span.setError(self.gpa, err);
                entry.span.finish(self.nowUnixNano());
                should_flush = (try self.queueSpanLocked(entry.span)) or should_flush;
                self.gpa.free(entry.call_id);
            }
        }
        if (should_flush) try self.flush();
    }

    fn enterModelCall(self: *Exporter, call_id: []const u8) ?*anyopaque {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const token = self.newHookToken(.model, call_id) orelse return null;
        const state = self.calls.get(call_id) orelse {
            token.deinit();
            return null;
        };
        const span = state.model orelse {
            token.deinit();
            return null;
        };
        if (!span.hook_started) {
            span.start_time_unix_nano = token.started;
            span.end_time_unix_nano = token.started;
            span.hook_started = true;
        }
        token.span_id = span.span_id;
        return token;
    }

    fn enterToolExecution(self: *Exporter, call_id: []const u8) ?*anyopaque {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const token = self.newHookToken(.tool, call_id) orelse return null;
        const state = self.calls.get(call_id) orelse {
            token.deinit();
            return null;
        };
        state.pending_tool_hooks.append(self.gpa, token) catch {
            token.deinit();
            return null;
        };
        return token;
    }

    fn exitHook(self: *Exporter, raw_token: ?*anyopaque, expected: HookKind) void {
        const token: *HookToken = @ptrCast(@alignCast(raw_token orelse return));
        if (token.exporter != self or token.kind != expected) return;
        var should_flush = false;
        self.state_mutex.lockUncancelable(self.io);
        if (self.calls.get(token.call_id)) |state| {
            if (expected == .model) {
                if (state.model) |span| if (token.span_id != null and idsEqual(span.span_id, token.span_id.?))
                    span.finish(self.nowUnixNano());
            } else {
                removePendingHook(state, token);
                if (token.span_id) |span_id| {
                    if (findToolBySpanId(state, span_id)) |index| {
                        const entry = &state.tools.items[index];
                        entry.span.finish(self.nowUnixNano());
                        entry.hook = null;
                        if (entry.span.event_ended) {
                            const removed = state.tools.orderedRemove(index);
                            should_flush = self.queueSpanLocked(removed.span) catch blk: {
                                removed.span.deinit(self.gpa);
                                break :blk false;
                            };
                            self.gpa.free(removed.tool_call_id);
                        }
                    }
                }
            }
        }
        token.deinit();
        self.state_mutex.unlock(self.io);
        if (should_flush) self.flush() catch {};
    }

    fn newHookToken(self: *Exporter, kind: HookKind, call_id: []const u8) ?*HookToken {
        const token = self.gpa.create(HookToken) catch return null;
        const owned_call_id = self.gpa.dupe(u8, call_id) catch {
            self.gpa.destroy(token);
            return null;
        };
        token.* = .{
            .exporter = self,
            .kind = kind,
            .call_id = owned_call_id,
            .started = self.nowUnixNano(),
        };
        return token;
    }

    fn newSpan(
        self: *Exporter,
        trace_id: otlp.TraceId,
        parent_span_id: ?otlp.SpanId,
        name: []const u8,
        kind: otlp.SpanKind,
    ) Allocator.Error!*OwnedSpan {
        return OwnedSpan.init(
            self.gpa,
            trace_id,
            parent_span_id,
            self.newSpanId(),
            name,
            kind,
            self.nowUnixNano(),
        );
    }

    fn newTraceId(self: *Exporter) otlp.TraceId {
        var id: otlp.TraceId = undefined;
        self.io.random(&id);
        if (allZero(&id)) id[id.len - 1] = 1;
        return id;
    }

    fn newSpanId(self: *Exporter) otlp.SpanId {
        var id: otlp.SpanId = undefined;
        self.io.random(&id);
        if (allZero(&id)) id[id.len - 1] = 1;
        return id;
    }

    fn nowUnixNano(self: *Exporter) u64 {
        const value = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return std.math.cast(u64, value) orelse if (value < 0) 0 else std.math.maxInt(u64);
    }

    fn queueSpanLocked(self: *Exporter, span: *OwnedSpan) Allocator.Error!bool {
        try self.batch.append(self.gpa, span);
        return self.batch.items.len >= self.max_batch_size;
    }

    fn removeCallLocked(self: *Exporter, call_id: []const u8) void {
        const removed = self.calls.fetchRemove(call_id) orelse return;
        self.gpa.free(removed.key);
        removed.value.deinit(self.gpa);
    }
};

/// Handle for the borrowed core registration. `deinit` flushes; it does not
/// clear unrelated global integrations. Clear the ai telemetry registry before
/// destroying the exporter itself.
pub const Registration = struct {
    exporter: *Exporter,
    active: bool = true,

    pub fn deinit(self: *Registration) FlushError!void {
        if (!self.active) return;
        self.active = false;
        try self.exporter.flush();
    }
};

pub fn register(exporter: *Exporter) Allocator.Error!Registration {
    try ai.registerTelemetry(exporter.gpa, &.{exporter.telemetry()});
    return .{ .exporter = exporter };
}

const vtable: ai.Telemetry.VTable = .{
    .onStart = onStartCallback,
    .onStepStart = onStepStartCallback,
    .onLanguageModelCallStart = onModelStartCallback,
    .onLanguageModelCallEnd = onModelEndCallback,
    .onToolExecutionStart = onToolStartCallback,
    .onToolExecutionEnd = onToolEndCallback,
    .onStepEnd = onStepEndCallback,
    .onEnd = onEndCallback,
    .onAbort = onAbortCallback,
    .onError = onErrorCallback,
    .onObjectStart = onObjectStartCallback,
    .onObjectStepStart = onObjectStepStartCallback,
    .onObjectStepEnd = onObjectStepEndCallback,
    .onObjectEnd = onObjectEndCallback,
    .onEmbedStart = onEmbedStartCallback,
    .onEmbedEnd = onEmbedEndCallback,
    .onRerankStart = onRerankStartCallback,
    .onRerankEnd = onRerankEndCallback,
    .enterModelCall = enterModelCallback,
    .exitModelCall = exitModelCallback,
    .enterToolExecution = enterToolCallback,
    .exitToolExecution = exitToolCallback,
};

fn fromContext(raw: ?*anyopaque) *Exporter {
    return @ptrCast(@alignCast(raw.?));
}

fn onStartCallback(raw: ?*anyopaque, event: *const ai.events.GenerateTextStartEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onGenerateStart(event, meta);
}

fn onStepStartCallback(raw: ?*anyopaque, event: *const ai.events.StepStartEvent, _: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onStepStart(event);
}

fn onModelStartCallback(raw: ?*anyopaque, event: *const ai.events.LanguageModelCallStartEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onModelStart(event, meta);
}

fn onModelEndCallback(raw: ?*anyopaque, event: *const ai.events.LanguageModelCallEndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onModelEnd(event, meta);
}

fn onToolStartCallback(raw: ?*anyopaque, event: *const ai.events.ToolExecutionStartEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onToolStart(event, meta);
}

fn onToolEndCallback(raw: ?*anyopaque, event: *const ai.events.ToolExecutionEndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onToolEnd(event, meta);
}

fn onStepEndCallback(raw: ?*anyopaque, event: *const ai.events.StepEndEvent, _: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onStepEnd(event);
}

fn onEndCallback(raw: ?*anyopaque, event: *const ai.events.EndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onGenerateEnd(event, meta);
}

fn onAbortCallback(raw: ?*anyopaque, event: *const ai.events.AbortEvent, _: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onAbort(event);
}

fn onErrorCallback(raw: ?*anyopaque, event: *const ai.events.ErrorEvent, _: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onError(event);
}

fn onObjectStartCallback(raw: ?*anyopaque, event: *const ai.events.GenerateObjectStartEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onObjectStart(event, meta);
}

fn onObjectStepStartCallback(raw: ?*anyopaque, event: *const ai.events.ObjectStepStartEvent, _: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onObjectStepStart(event);
}

fn onObjectStepEndCallback(raw: ?*anyopaque, event: *const ai.events.ObjectStepEndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onObjectStepEnd(event, meta);
}

fn onObjectEndCallback(raw: ?*anyopaque, event: *const ai.events.GenerateObjectEndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onObjectEnd(event, meta);
}

fn onEmbedStartCallback(raw: ?*anyopaque, event: *const ai.events.EmbedStartEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onEmbedStart(event, meta);
}

fn onEmbedEndCallback(raw: ?*anyopaque, event: *const ai.events.EmbedEndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onEmbedEnd(event, meta);
}

fn onRerankStartCallback(raw: ?*anyopaque, event: *const ai.events.RerankStartEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onRerankStart(event, meta);
}

fn onRerankEndCallback(raw: ?*anyopaque, event: *const ai.events.RerankEndEvent, meta: *const ai.telemetry.Meta) anyerror!void {
    try fromContext(raw).onRerankEnd(event, meta);
}

fn enterModelCallback(raw: ?*anyopaque, call_id: []const u8) ?*anyopaque {
    return fromContext(raw).enterModelCall(call_id);
}

fn exitModelCallback(raw: ?*anyopaque, token: ?*anyopaque) void {
    fromContext(raw).exitHook(token, .model);
}

fn enterToolCallback(raw: ?*anyopaque, call_id: []const u8) ?*anyopaque {
    return fromContext(raw).enterToolExecution(call_id);
}

fn exitToolCallback(raw: ?*anyopaque, token: ?*anyopaque) void {
    fromContext(raw).exitHook(token, .tool);
}

fn cloneHeaders(gpa: Allocator, source: []const provider.Header) Allocator.Error![]provider.Header {
    const headers = try gpa.alloc(provider.Header, source.len);
    var initialized: usize = 0;
    errdefer {
        for (headers[0..initialized]) |header| {
            gpa.free(header.name);
            gpa.free(header.value);
        }
        gpa.free(headers);
    }
    for (source, headers) |header, *owned| {
        owned.* = .{
            .name = try gpa.dupe(u8, header.name),
            .value = try gpa.dupe(u8, header.value),
        };
        initialized += 1;
    }
    return headers;
}

fn deinitHeaders(gpa: Allocator, headers: []provider.Header) void {
    for (headers) |header| {
        gpa.free(header.name);
        gpa.free(header.value);
    }
    gpa.free(headers);
}

fn requestHeaders(arena: Allocator, configured: []const provider.Header) Allocator.Error![]const provider.Header {
    var has_content_type = false;
    for (configured) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) has_content_type = true;
    }
    const headers = try arena.alloc(provider.Header, configured.len + @intFromBool(!has_content_type));
    @memcpy(headers[0..configured.len], configured);
    if (!has_content_type) headers[configured.len] = .{ .name = "content-type", .value = "application/json" };
    return headers;
}

fn addIdentity(
    span: *OwnedSpan,
    gpa: Allocator,
    operation: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
) Allocator.Error!void {
    try span.setString(gpa, "gen_ai.operation.name", operation);
    try span.setString(gpa, "gen_ai.system", mapProviderName(provider_name));
    try span.setString(gpa, "gen_ai.request.model", model_id);
}

fn addSettings(span: *OwnedSpan, gpa: Allocator, settings: Settings) Allocator.Error!void {
    if (settings.max_output_tokens) |value| try setTokenCount(span, gpa, "gen_ai.request.max_tokens", value);
    if (settings.temperature) |value| try span.setDouble(gpa, "gen_ai.request.temperature", value);
    if (settings.top_p) |value| try span.setDouble(gpa, "gen_ai.request.top_p", value);
    if (settings.top_k) |value| try span.setDouble(gpa, "gen_ai.request.top_k", value);
    if (settings.presence_penalty) |value| try span.setDouble(gpa, "gen_ai.request.presence_penalty", value);
    if (settings.frequency_penalty) |value| try span.setDouble(gpa, "gen_ai.request.frequency_penalty", value);
    if (settings.stop_sequences) |value| try span.setStringArray(gpa, "gen_ai.request.stop_sequences", value);
    if (settings.seed) |value| try span.setInt(gpa, "gen_ai.request.seed", value);
}

fn addModelResponse(
    span: *OwnedSpan,
    gpa: Allocator,
    model_id: ?[]const u8,
    response_id: ?[]const u8,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
) Allocator.Error!void {
    if (model_id) |value| try span.setString(gpa, "gen_ai.response.model", value);
    if (response_id) |value| try span.setString(gpa, "gen_ai.response.id", value);
    try span.setStringArray(gpa, "gen_ai.response.finish_reasons", &.{finishReasonName(finish_reason)});
    if (usage.input_tokens.total) |value| try setTokenCount(span, gpa, "gen_ai.usage.input_tokens", value);
    if (usage.output_tokens.total) |value| try setTokenCount(span, gpa, "gen_ai.usage.output_tokens", value);
    if (usage.input_tokens.cache_read) |value| try setTokenCount(span, gpa, "gen_ai.usage.cache_read.input_tokens", value);
    if (usage.input_tokens.cache_write) |value| try setTokenCount(span, gpa, "gen_ai.usage.cache_creation.input_tokens", value);
}

fn setTokenCount(span: *OwnedSpan, gpa: Allocator, key: []const u8, value: u64) Allocator.Error!void {
    const signed = std.math.cast(i64, value) orelse std.math.maxInt(i64);
    try span.setInt(gpa, key, signed);
}

fn addSystemInstructions(span: *OwnedSpan, gpa: Allocator, instructions: []const u8) Allocator.Error!void {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    json.beginArray() catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("type") catch return error.OutOfMemory;
    json.write("text") catch return error.OutOfMemory;
    json.objectField("content") catch return error.OutOfMemory;
    json.write(instructions) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    try span.setString(gpa, "gen_ai.system_instructions", output.written());
}

fn addContentOutput(
    span: *OwnedSpan,
    gpa: Allocator,
    content: []const ai.ContentPart,
    finish_reason: provider.FinishReason,
) Allocator.Error!void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (content) |part| switch (part) {
        .text => |item| try text.appendSlice(gpa, item.text),
        else => {},
    };
    if (text.items.len != 0) try addTextOutput(span, gpa, text.items, finish_reason);
}

fn addTextOutput(
    span: *OwnedSpan,
    gpa: Allocator,
    text: []const u8,
    finish_reason: provider.FinishReason,
) Allocator.Error!void {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    json.beginArray() catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("role") catch return error.OutOfMemory;
    json.write("assistant") catch return error.OutOfMemory;
    json.objectField("parts") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("type") catch return error.OutOfMemory;
    json.write("text") catch return error.OutOfMemory;
    json.objectField("content") catch return error.OutOfMemory;
    json.write(text) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.objectField("finish_reason") catch return error.OutOfMemory;
    json.write(finishReasonName(finish_reason)) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    try span.setString(gpa, "gen_ai.output.messages", output.written());
}

fn operationName(operation_id: []const u8) []const u8 {
    if (std.mem.eql(u8, operation_id, "ai.generateText") or
        std.mem.eql(u8, operation_id, "ai.streamText") or
        std.mem.eql(u8, operation_id, "ai.generateObject") or
        std.mem.eql(u8, operation_id, "ai.streamObject")) return "invoke_agent";
    if (std.mem.eql(u8, operation_id, "ai.embed") or
        std.mem.eql(u8, operation_id, "ai.embedMany") or
        std.mem.indexOf(u8, operation_id, "embed") != null) return "embeddings";
    if (std.mem.indexOf(u8, operation_id, "rerank") != null) return "rerank";
    return operation_id;
}

fn mapProviderName(name: []const u8) []const u8 {
    const mappings = [_]struct { prefix: []const u8, value: []const u8 }{
        .{ .prefix = "google.vertex", .value = "gcp.vertex_ai" },
        .{ .prefix = "google.generative-ai", .value = "gcp.gemini" },
        .{ .prefix = "google-vertex", .value = "gcp.vertex_ai" },
        .{ .prefix = "amazon-bedrock", .value = "aws.bedrock" },
        .{ .prefix = "azure-openai", .value = "azure.ai.openai" },
        .{ .prefix = "anthropic", .value = "anthropic" },
        .{ .prefix = "openai", .value = "openai" },
        .{ .prefix = "azure", .value = "azure.ai.inference" },
        .{ .prefix = "google", .value = "gcp.gemini" },
        .{ .prefix = "mistral", .value = "mistral_ai" },
        .{ .prefix = "cohere", .value = "cohere" },
        .{ .prefix = "bedrock", .value = "aws.bedrock" },
        .{ .prefix = "groq", .value = "groq" },
        .{ .prefix = "deepseek", .value = "deepseek" },
        .{ .prefix = "perplexity", .value = "perplexity" },
        .{ .prefix = "xai", .value = "x_ai" },
    };
    for (mappings) |mapping| if (providerPrefix(name, mapping.prefix)) return mapping.value;
    return name;
}

fn providerPrefix(name: []const u8, prefix: []const u8) bool {
    if (name.len < prefix.len or !std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) return false;
    return name.len == prefix.len or name[prefix.len] == '.' or name[prefix.len] == '-';
}

fn finishReasonName(reason: provider.FinishReason) []const u8 {
    return switch (reason.unified) {
        .stop => "stop",
        .length => "length",
        .content_filter => "content-filter",
        .tool_calls => "tool-calls",
        .@"error" => "error",
        .other => reason.raw orelse "other",
    };
}

fn findToolIndex(state: *CallState, tool_call_id: []const u8) ?usize {
    for (state.tools.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) return index;
    }
    return null;
}

fn findToolBySpanId(state: *CallState, span_id: otlp.SpanId) ?usize {
    for (state.tools.items, 0..) |entry, index| {
        if (idsEqual(entry.span.span_id, span_id)) return index;
    }
    return null;
}

fn removePendingHook(state: *CallState, token: *HookToken) void {
    for (state.pending_tool_hooks.items, 0..) |candidate, index| {
        if (candidate != token) continue;
        _ = state.pending_tool_hooks.orderedRemove(index);
        return;
    }
}

fn findEmbedIndex(self: *Exporter, call_id: []const u8, embed_call_id: []const u8) ?usize {
    for (self.embeds.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.call_id, call_id) and
            std.mem.eql(u8, entry.embed_call_id, embed_call_id)) return index;
    }
    return null;
}

fn findRerankIndex(self: *Exporter, call_id: []const u8) ?usize {
    for (self.reranks.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.call_id, call_id)) return index;
    }
    return null;
}

fn idsEqual(a: otlp.SpanId, b: otlp.SpanId) bool {
    return std.mem.eql(u8, &a, &b);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
