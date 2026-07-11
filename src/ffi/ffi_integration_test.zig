const std = @import("std");
const provider = @import("provider");
const test_support = @import("test_support");
const agent_api = @import("agent.zig");
const embeddings_api = @import("embeddings.zig");
const media_api = @import("media.zig");
const objects_api = @import("objects.zig");
const providers = @import("providers.zig");
const result_api = @import("result.zig");
const runtime_api = @import("runtime.zig");
const stream_api = @import("stream.zig");
const telemetry_api = @import("telemetry.zig");
const types = @import("types.zig");

const ToolRecorder = struct {
    calls: std.atomic.Value(usize) = .init(0),
    saw_city: std.atomic.Value(bool) = .init(false),

    fn execute(
        raw: ?*anyopaque,
        input_ptr: [*c]const u8,
        input_len: usize,
        out: [*c]types.ai_tool_result,
    ) callconv(.c) types.Status {
        if (raw == null or input_ptr == null or out == null) return .invalid_argument;
        const self: *ToolRecorder = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        self.saw_city.store(std.mem.indexOf(u8, input_ptr[0..input_len], "Paris") != null, .release);
        const output = "{\"condition\":\"sunny\",\"temperature\":21}";
        const ptr = runtime_api.ai_alloc(output.len);
        if (ptr == null) return .out_of_memory;
        @memcpy(ptr[0..output.len], output);
        out[0] = .{
            .struct_size = @sizeOf(types.ai_tool_result),
            .ptr = ptr,
            .len = output.len,
        };
        return .ok;
    }
};

const CancelContext = struct {
    stream: *types.ai_stream,
    runtime: *runtime_api.Runtime,
    status: types.Status = .unknown,
    elapsed_ns: i64 = 0,

    fn run(self: *CancelContext) void {
        const started = std.Io.Timestamp.now(self.runtime.io(), .awake);
        self.status = stream_api.ai_stream_cancel(self.stream);
        const finished = std.Io.Timestamp.now(self.runtime.io(), .awake);
        self.elapsed_ns = @intCast(finished.nanoseconds - started.nanoseconds);
    }
};

const TelemetryRecorder = struct {
    calls: std.atomic.Value(usize) = .init(0),
    saw_json: std.atomic.Value(bool) = .init(false),
    enters: std.atomic.Value(usize) = .init(0),
    exits: std.atomic.Value(usize) = .init(0),

    fn event(
        raw: ?*anyopaque,
        _: [*c]const u8,
        _: usize,
        json_ptr: [*c]const u8,
        json_len: usize,
    ) callconv(.c) void {
        const self: *TelemetryRecorder = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (json_ptr != null and std.mem.indexOf(u8, json_ptr[0..json_len], "\"callId\"") != null) {
            self.saw_json.store(true, .release);
        }
    }

    fn enter(
        raw: ?*anyopaque,
        _: [*c]const u8,
        _: usize,
        _: [*c]const u8,
        _: usize,
    ) callconv(.c) ?*anyopaque {
        const self: *TelemetryRecorder = @ptrCast(@alignCast(raw.?));
        _ = self.enters.fetchAdd(1, .monotonic);
        return raw;
    }

    fn exit(
        raw: ?*anyopaque,
        _: [*c]const u8,
        _: usize,
        token: ?*anyopaque,
    ) callconv(.c) void {
        const self: *TelemetryRecorder = @ptrCast(@alignCast(raw.?));
        if (token == raw) _ = self.exits.fetchAdd(1, .monotonic);
    }
};

test "C ABI drives real two-step generate and stream plus foreign-thread cancel" {
    const allocator = std.testing.allocator;
    const server = try test_support.MockServer.start(allocator, std.testing.io);
    defer server.deinit();

    var runtime_handle: ?*types.ai_runtime = null;
    try std.testing.expectEqual(
        types.Status.ok,
        runtime_api.ai_runtime_create(null, &runtime_handle),
    );
    defer if (runtime_handle) |handle| runtime_api.ai_runtime_destroy(handle);
    const runtime = runtime_api.fromHandle(runtime_handle.?);

    var base_buffer: [64]u8 = undefined;
    const base_url = server.baseUrl(&base_buffer);
    const provider_config: types.ai_openai_compatible_config = .{
        .struct_size = @sizeOf(types.ai_openai_compatible_config),
        .name_ptr = "ffi-test".ptr,
        .name_len = "ffi-test".len,
        .base_url_ptr = base_url.ptr,
        .base_url_len = base_url.len,
        .api_key_ptr = "test-key".ptr,
        .api_key_len = "test-key".len,
    };
    var provider_handle: ?*types.ai_provider = null;
    try std.testing.expectEqual(
        types.Status.ok,
        providers.ai_provider_openai_compatible(runtime_handle, &provider_config, &provider_handle),
    );
    defer if (provider_handle) |handle| providers.ai_provider_destroy(handle);
    var model_handle: ?*types.ai_model = null;
    try std.testing.expectEqual(
        types.Status.ok,
        providers.ai_provider_language_model(
            provider_handle,
            "vendor/model".ptr,
            "vendor/model".len,
            &model_handle,
        ),
    );
    defer if (model_handle) |handle| providers.ai_model_destroy(handle);

    var recorder: ToolRecorder = .{};
    const tool: types.ai_tool = .{
        .struct_size = @sizeOf(types.ai_tool),
        .name_ptr = "weather".ptr,
        .name_len = "weather".len,
        .description_ptr = "Get weather".ptr,
        .description_len = "Get weather".len,
        .input_schema_json_ptr = "{\"type\":\"object\"}".ptr,
        .input_schema_json_len = "{\"type\":\"object\"}".len,
        .execute = ToolRecorder.execute,
        .user_data = &recorder,
    };
    const options_json =
        "{\"prompt\":\"What is the weather in Paris?\",\"maxSteps\":2,\"maxRetries\":0}";

    try enqueueGenerateLoop(server);
    var result_handle: ?*types.ai_result = null;
    try std.testing.expectEqual(
        types.Status.ok,
        result_api.ai_generate_text(
            runtime_handle,
            model_handle,
            options_json.ptr,
            options_json.len,
            &tool,
            1,
            &result_handle,
        ),
    );
    const result = result_handle.?;
    try std.testing.expectEqualStrings(
        "Paris is sunny and 21 C.",
        stringSlice(result_api.ai_result_text(result)),
    );
    try std.testing.expectEqualStrings("stop", stringSlice(result_api.ai_result_finish_reason(result)));
    try std.testing.expectEqual(19, result_api.ai_result_total_tokens(result));
    const result_json = stringSlice(result_api.ai_result_json(result));
    var result_arena = std.heap.ArenaAllocator.init(allocator);
    defer result_arena.deinit();
    const result_value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        result_arena.allocator(),
        result_json,
        .{},
    );
    try std.testing.expectEqual(2, result_value.object.get("steps").?.array.items.len);
    try std.testing.expectEqualStrings(
        "Paris is sunny and 21 C.",
        result_value.object.get("text").?.string,
    );
    result_api.ai_result_destroy(result);
    result_handle = null;
    try std.testing.expectEqual(1, recorder.calls.load(.acquire));
    try std.testing.expect(recorder.saw_city.load(.acquire));

    var bad_result: ?*types.ai_result = null;
    try std.testing.expectEqual(
        types.Status.invalid_argument,
        result_api.ai_generate_text(
            runtime_handle,
            model_handle,
            "{".ptr,
            1,
            null,
            0,
            &bad_result,
        ),
    );
    try std.testing.expect(bad_result == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stringSlice(runtime_api.ai_runtime_last_error(runtime_handle)),
        "optionsJson",
    ) != null);

    try enqueueStreamLoop(server);
    var stream_handle: ?*types.ai_stream = null;
    try std.testing.expectEqual(
        types.Status.ok,
        stream_api.ai_stream_text(
            runtime_handle,
            model_handle,
            options_json.ptr,
            options_json.len,
            &tool,
            1,
            &stream_handle,
        ),
    );
    var part = types.initialized(types.ai_part);
    var part_count: usize = 0;
    var text_delta_count: usize = 0;
    var finish_count: usize = 0;
    while (true) {
        const status = stream_api.ai_stream_next(stream_handle, &part);
        if (status == .stream_done) break;
        try std.testing.expectEqual(types.Status.ok, status);
        if (part_count == 0) try std.testing.expectEqual(types.PartType.start, part.type);
        part_count += 1;
        switch (part.type) {
            .text_delta => {
                text_delta_count += 1;
                try std.testing.expect(part.text_len > 0);
            },
            .finish => finish_count += 1,
            else => {},
        }
    }
    try std.testing.expect(part_count > 0);
    try std.testing.expect(text_delta_count > 0);
    try std.testing.expectEqual(1, finish_count);
    try std.testing.expectEqual(2, recorder.calls.load(.acquire));
    stream_api.ai_stream_destroy(stream_handle);
    stream_handle = null;
    try std.testing.expectEqual(0, server.serveErrorCount());

    try enqueueSlowStream(server);
    try std.testing.expectEqual(
        types.Status.ok,
        stream_api.ai_stream_text(
            runtime_handle,
            model_handle,
            "{\"prompt\":\"cancel\",\"maxRetries\":0}".ptr,
            "{\"prompt\":\"cancel\",\"maxRetries\":0}".len,
            null,
            0,
            &stream_handle,
        ),
    );
    while (true) {
        try std.testing.expectEqual(types.Status.ok, stream_api.ai_stream_next(stream_handle, &part));
        if (part.type == .text_delta) break;
    }
    var cancel_context: CancelContext = .{
        .stream = stream_handle.?,
        .runtime = runtime,
    };
    const cancel_thread = try std.Thread.spawn(.{}, CancelContext.run, .{&cancel_context});
    cancel_thread.join();
    try std.testing.expectEqual(types.Status.ok, cancel_context.status);
    try std.testing.expect(cancel_context.elapsed_ns < 100 * std.time.ns_per_ms);
    stream_api.ai_stream_destroy(stream_handle);
    stream_handle = null;

    providers.ai_model_destroy(model_handle);
    model_handle = null;
    providers.ai_provider_destroy(provider_handle);
    provider_handle = null;
    runtime_api.ai_runtime_destroy(runtime_handle);
    runtime_handle = null;
    try std.testing.expect(runtime_api.last_runtime_deinit_clean.load(.acquire));
}

fn enqueueGenerateLoop(server: *test_support.MockServer) !void {
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-g-1","created":1700000000,"model":"vendor/model","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-g-1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}
        },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-g-2","created":1700000001,"model":"vendor/model","choices":[{"message":{"role":"assistant","content":"Paris is sunny and 21 C."},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":5}}
        },
    });
}

fn enqueueStreamLoop(server: *test_support.MockServer) !void {
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"chat-s-1\",\"created\":1700000000,\"model\":\"vendor/model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-s-1\",\"type\":\"function\",\"function\":{\"name\":\"weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}]}}]}" },
            .{ .data = "{\"id\":\"chat-s-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}" },
            .{ .data = "[DONE]" },
        } },
    });
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"chat-s-2\",\"created\":1700000001,\"model\":\"vendor/model\",\"choices\":[{\"delta\":{\"content\":\"Paris is sunny and 21 C.\"}}]}" },
            .{ .data = "{\"id\":\"chat-s-2\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":5}}" },
            .{ .data = "[DONE]" },
        } },
    });
}

fn enqueueSlowStream(server: *test_support.MockServer) !void {
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"chat-cancel\",\"created\":1700000002,\"model\":\"vendor/model\",\"choices\":[{\"delta\":{\"content\":\"A\"}}]}", .delay_ms = 250 },
            .{ .data = "{\"id\":\"chat-cancel\",\"choices\":[{\"delta\":{\"content\":\"B\"}}]}" },
            .{ .data = "{\"id\":\"chat-cancel\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}" },
            .{ .data = "[DONE]" },
        } },
    });
}

fn stringSlice(value: types.ai_string) []const u8 {
    if (value.ptr == null) return "";
    return value.ptr[0..value.len];
}

test "part clone returns an independently owned C buffer" {
    const source = "{\"type\":\"start\"}";
    const part: types.ai_part = .{
        .struct_size = @sizeOf(types.ai_part),
        .type = .start,
        .json_ptr = source.ptr,
        .json_len = source.len,
        .text_ptr = null,
        .text_len = 0,
    };
    var cloned: types.ai_string = types.empty_string;
    try std.testing.expectEqual(types.Status.ok, stream_api.ai_part_clone(&part, &cloned));
    defer runtime_api.ai_buf_free(cloned.ptr, cloned.len);
    try std.testing.expectEqualStrings(source, stringSlice(cloned));
}

test "ABI v1 exposes native OpenAI objects embeddings agent UI and telemetry" {
    telemetry_api.ai_telemetry_clear();
    defer telemetry_api.ai_telemetry_clear();
    const allocator = std.testing.allocator;
    const server = try test_support.MockServer.start(allocator, std.testing.io);
    defer server.deinit();

    try std.testing.expectEqual(types.abi_version, runtime_api.ai_abi_version());
    try std.testing.expectEqualStrings("1.0.0", stringSlice(runtime_api.ai_abi_version_string()));

    var short_config: types.ai_runtime_config = .{
        .struct_size = @sizeOf(types.ai_runtime_config) - 1,
        .async_limit = 0,
        .concurrent_limit = 0,
    };
    var rejected_runtime: ?*types.ai_runtime = null;
    try std.testing.expectEqual(
        types.Status.invalid_argument,
        runtime_api.ai_runtime_create(&short_config, &rejected_runtime),
    );
    try std.testing.expect(rejected_runtime == null);

    var runtime_handle: ?*types.ai_runtime = null;
    try std.testing.expectEqual(.ok, runtime_api.ai_runtime_create(null, &runtime_handle));
    defer runtime_api.ai_runtime_destroy(runtime_handle);

    var base_buffer: [64]u8 = undefined;
    const base_url = server.baseUrl(&base_buffer);
    const openai_config: types.ai_openai_config = .{
        .struct_size = @sizeOf(types.ai_openai_config),
        .api_key_ptr = "test-key".ptr,
        .api_key_len = "test-key".len,
        .base_url_ptr = base_url.ptr,
        .base_url_len = base_url.len,
        .organization_ptr = null,
        .organization_len = 0,
        .project_ptr = null,
        .project_len = 0,
        .language_api = .chat,
    };
    var provider_handle: ?*types.ai_provider = null;
    try std.testing.expectEqual(
        .ok,
        providers.ai_provider_openai(runtime_handle, &openai_config, &provider_handle),
    );
    defer providers.ai_provider_destroy(provider_handle);
    var model_handle: ?*types.ai_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_language_model(
        provider_handle,
        "gpt-test".ptr,
        "gpt-test".len,
        &model_handle,
    ));
    defer providers.ai_model_destroy(model_handle);

    var recorder: TelemetryRecorder = .{};
    const telemetry_config: types.ai_telemetry_vtable = .{
        .struct_size = @sizeOf(types.ai_telemetry_vtable),
        .user_data = &recorder,
        .on_event = TelemetryRecorder.event,
        .enter = TelemetryRecorder.enter,
        .exit = TelemetryRecorder.exit,
    };
    var telemetry_handle: ?*types.ai_telemetry_registration = null;
    try std.testing.expectEqual(.ok, telemetry_api.ai_telemetry_register(
        runtime_handle,
        &telemetry_config,
        &telemetry_handle,
    ));

    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"obj-1","created":1700000000,"model":"gpt-test","choices":[{"message":{"role":"assistant","content":"{\"city\":\"Paris\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4}}
        },
    });
    const schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}";
    const object_options = "{\"prompt\":\"return a city\",\"maxRetries\":0}";
    var result_handle: ?*types.ai_result = null;
    try std.testing.expectEqual(.ok, objects_api.ai_generate_object(
        runtime_handle,
        model_handle,
        object_options.ptr,
        object_options.len,
        schema.ptr,
        schema.len,
        &result_handle,
    ));
    var json_arena = std.heap.ArenaAllocator.init(allocator);
    defer json_arena.deinit();
    const object_document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        json_arena.allocator(),
        stringSlice(result_api.ai_result_json(result_handle)),
        .{},
    );
    try std.testing.expectEqualStrings("Paris", object_document.object.get("object").?.object.get("city").?.string);
    result_api.ai_result_destroy(result_handle);
    result_handle = null;

    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"obj-s\",\"created\":1700000001,\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"{\\\"city\\\":\"}}]}" },
            .{ .data = "{\"id\":\"obj-s\",\"choices\":[{\"delta\":{\"content\":\"\\\"Paris\\\"}\"}}]}" },
            .{ .data = "{\"id\":\"obj-s\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4}}" },
            .{ .data = "[DONE]" },
        } },
    });
    var stream_handle: ?*types.ai_stream = null;
    try std.testing.expectEqual(.ok, objects_api.ai_stream_object(
        runtime_handle,
        model_handle,
        object_options.ptr,
        object_options.len,
        schema.ptr,
        schema.len,
        &stream_handle,
    ));
    var part = types.initialized(types.ai_part);
    var saw_object = false;
    while (true) {
        const status = stream_api.ai_stream_next(stream_handle, &part);
        if (status == .stream_done) break;
        try std.testing.expectEqual(types.Status.ok, status);
        saw_object = saw_object or part.type == .object;
    }
    try std.testing.expect(saw_object);
    stream_api.ai_stream_destroy(stream_handle);
    stream_handle = null;

    var embedding_model: ?*types.ai_embedding_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_embedding_model(
        provider_handle,
        "text-embedding-test".ptr,
        "text-embedding-test".len,
        &embedding_model,
    ));
    defer providers.ai_embedding_model_destroy(embedding_model);
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[0.25,0.75],\"index\":0}],\"model\":\"text-embedding-test\",\"usage\":{\"prompt_tokens\":2,\"total_tokens\":2}}" },
    });
    try std.testing.expectEqual(.ok, embeddings_api.ai_embed(
        runtime_handle,
        embedding_model,
        "hello".ptr,
        "hello".len,
        null,
        0,
        &result_handle,
    ));
    try std.testing.expectEqual(2, result_api.ai_result_total_tokens(result_handle));
    result_api.ai_result_destroy(result_handle);
    result_handle = null;

    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[1,0],\"index\":0},{\"object\":\"embedding\",\"embedding\":[0,1],\"index\":1}],\"model\":\"text-embedding-test\",\"usage\":{\"prompt_tokens\":4,\"total_tokens\":4}}" },
    });
    const values = [_]types.ai_string{ types.string("one"), types.string("two") };
    try std.testing.expectEqual(.ok, embeddings_api.ai_embed_many(
        runtime_handle,
        embedding_model,
        &values,
        values.len,
        null,
        0,
        &result_handle,
    ));
    try std.testing.expectEqual(4, result_api.ai_result_total_tokens(result_handle));
    result_api.ai_result_destroy(result_handle);
    result_handle = null;

    const agent_config: types.ai_agent_config = .{
        .struct_size = @sizeOf(types.ai_agent_config),
        .tools = null,
        .tools_len = 0,
        .system_ptr = "Be concise.".ptr,
        .system_len = "Be concise.".len,
        .max_steps = 2,
    };
    var agent_handle: ?*types.ai_agent = null;
    try std.testing.expectEqual(.ok, agent_api.ai_agent_create(
        runtime_handle,
        model_handle,
        &agent_config,
        &agent_handle,
    ));
    defer agent_api.ai_agent_destroy(agent_handle);
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"id\":\"agent-1\",\"created\":1700000002,\"model\":\"gpt-test\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"agent answer\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":2}}" },
    });
    const agent_options = "{\"prompt\":\"answer\",\"maxRetries\":0}";
    try std.testing.expectEqual(.ok, agent_api.ai_agent_run(
        agent_handle,
        agent_options.ptr,
        agent_options.len,
        &result_handle,
    ));
    try std.testing.expectEqualStrings("agent answer", stringSlice(result_api.ai_result_text(result_handle)));
    result_api.ai_result_destroy(result_handle);
    result_handle = null;

    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"agent-s\",\"created\":1700000003,\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"streamed\"}}]}" },
            .{ .data = "{\"id\":\"agent-s\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}" },
            .{ .data = "[DONE]" },
        } },
    });
    try std.testing.expectEqual(.ok, agent_api.ai_agent_stream(
        agent_handle,
        agent_options.ptr,
        agent_options.len,
        &stream_handle,
    ));
    var saw_agent_text = false;
    while (true) {
        const status = stream_api.ai_stream_next(stream_handle, &part);
        if (status == .stream_done) break;
        try std.testing.expectEqual(types.Status.ok, status);
        saw_agent_text = saw_agent_text or part.type == .text_delta;
    }
    try std.testing.expect(saw_agent_text);
    stream_api.ai_stream_destroy(stream_handle);
    stream_handle = null;

    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"ui-s\",\"created\":1700000004,\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"UI\"}}]}" },
            .{ .data = "{\"id\":\"ui-s\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}" },
            .{ .data = "[DONE]" },
        } },
    });
    try std.testing.expectEqual(.ok, stream_api.ai_stream_text_ui(
        runtime_handle,
        model_handle,
        "{\"prompt\":\"ui\",\"maxRetries\":0}".ptr,
        "{\"prompt\":\"ui\",\"maxRetries\":0}".len,
        null,
        0,
        &stream_handle,
    ));
    var saw_ui = false;
    while (true) {
        const status = stream_api.ai_stream_next(stream_handle, &part);
        if (status == .stream_done) break;
        try std.testing.expectEqual(types.Status.ok, status);
        saw_ui = saw_ui or part.type == .ui_message;
    }
    try std.testing.expect(saw_ui);
    stream_api.ai_stream_destroy(stream_handle);
    stream_handle = null;

    try std.testing.expect(recorder.calls.load(.acquire) > 0);
    try std.testing.expect(recorder.saw_json.load(.acquire));
    try std.testing.expect(recorder.enters.load(.acquire) > 0);
    try std.testing.expectEqual(recorder.enters.load(.acquire), recorder.exits.load(.acquire));
    telemetry_api.ai_telemetry_unregister(telemetry_handle);

    const xai_config: types.ai_xai_config = .{
        .struct_size = @sizeOf(types.ai_xai_config),
        .api_key_ptr = "xai-key".ptr,
        .api_key_len = "xai-key".len,
        .base_url_ptr = base_url.ptr,
        .base_url_len = base_url.len,
    };
    var xai_provider: ?*types.ai_provider = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_xai(runtime_handle, &xai_config, &xai_provider));
    var xai_model: ?*types.ai_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_language_model(
        xai_provider,
        "grok-test".ptr,
        "grok-test".len,
        &xai_model,
    ));
    providers.ai_model_destroy(xai_model);
    providers.ai_provider_destroy(xai_provider);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "ABI v1 media entry points return owned blobs and transcription JSON" {
    const allocator = std.testing.allocator;
    const server = try test_support.MockServer.start(allocator, std.testing.io);
    defer server.deinit();
    var runtime_handle: ?*types.ai_runtime = null;
    try std.testing.expectEqual(.ok, runtime_api.ai_runtime_create(null, &runtime_handle));
    defer runtime_api.ai_runtime_destroy(runtime_handle);
    var base_buffer: [64]u8 = undefined;
    const base_url = server.baseUrl(&base_buffer);
    const config: types.ai_openai_config = .{
        .struct_size = @sizeOf(types.ai_openai_config),
        .api_key_ptr = "test-key".ptr,
        .api_key_len = "test-key".len,
        .base_url_ptr = base_url.ptr,
        .base_url_len = base_url.len,
        .organization_ptr = null,
        .organization_len = 0,
        .project_ptr = null,
        .project_len = 0,
        .language_api = .responses,
    };
    var provider_handle: ?*types.ai_provider = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_openai(runtime_handle, &config, &provider_handle));
    defer providers.ai_provider_destroy(provider_handle);
    var responses_model: ?*types.ai_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_language_model(
        provider_handle,
        "gpt-responses-test".ptr,
        "gpt-responses-test".len,
        &responses_model,
    ));
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"resp-ffi-1","created_at":1700000000,"model":"gpt-responses-test","output":[{"type":"message","role":"assistant","id":"msg-ffi-1","content":[{"type":"output_text","text":"responses answer","annotations":[]}]}],"incomplete_details":null,"usage":{"input_tokens":2,"output_tokens":2}}
        },
    });
    var responses_result: ?*types.ai_result = null;
    const responses_options = "{\"prompt\":\"answer\",\"maxRetries\":0}";
    try std.testing.expectEqual(.ok, result_api.ai_generate_text(
        runtime_handle,
        responses_model,
        responses_options.ptr,
        responses_options.len,
        null,
        0,
        &responses_result,
    ));
    try std.testing.expectEqualStrings(
        "responses answer",
        stringSlice(result_api.ai_result_text(responses_result)),
    );
    result_api.ai_result_destroy(responses_result);
    try std.testing.expectEqualStrings("/responses", server.recordedRequests()[0].target);
    providers.ai_model_destroy(responses_model);

    var image_model: ?*types.ai_image_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_image_model(
        provider_handle,
        "gpt-image-1".ptr,
        "gpt-image-1".len,
        &image_model,
    ));
    defer providers.ai_image_model_destroy(image_model);
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"created\":1733837122,\"data\":[{\"b64_json\":\"aGk=\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}" },
    });
    var result_handle: ?*types.ai_result = null;
    const image_options = "{\"prompt\":\"draw\",\"n\":1,\"maxRetries\":0}";
    try std.testing.expectEqual(.ok, media_api.ai_generate_image(
        runtime_handle,
        image_model,
        image_options.ptr,
        image_options.len,
        &result_handle,
    ));
    try std.testing.expectEqual(1, result_api.ai_result_blob_count(result_handle));
    var buffer = types.initialized(types.ai_buffer);
    try std.testing.expectEqual(.ok, result_api.ai_result_blob(result_handle, 0, &buffer));
    try std.testing.expectEqualStrings("hi", buffer.ptr[0..buffer.len]);
    runtime_api.ai_buf_free(buffer.ptr, buffer.len);
    result_api.ai_result_destroy(result_handle);
    result_handle = null;

    var speech_model: ?*types.ai_speech_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_speech_model(
        provider_handle,
        "gpt-4o-mini-tts".ptr,
        "gpt-4o-mini-tts".len,
        &speech_model,
    ));
    defer providers.ai_speech_model_destroy(speech_model);
    try server.enqueue(.{
        .content_type = "audio/mpeg",
        .body = .{ .text = "ID3audio" },
    });
    const speech_options = "{\"text\":\"hello\",\"voice\":\"alloy\",\"maxRetries\":0}";
    try std.testing.expectEqual(.ok, media_api.ai_generate_speech(
        runtime_handle,
        speech_model,
        speech_options.ptr,
        speech_options.len,
        &result_handle,
    ));
    try std.testing.expectEqual(1, result_api.ai_result_blob_count(result_handle));
    buffer = types.initialized(types.ai_buffer);
    try std.testing.expectEqual(.ok, result_api.ai_result_blob(result_handle, 0, &buffer));
    try std.testing.expectEqualStrings("ID3audio", buffer.ptr[0..buffer.len]);
    runtime_api.ai_buf_free(buffer.ptr, buffer.len);
    result_api.ai_result_destroy(result_handle);
    result_handle = null;

    var transcription_model: ?*types.ai_transcription_model = null;
    try std.testing.expectEqual(.ok, providers.ai_provider_transcription_model(
        provider_handle,
        "whisper-1".ptr,
        "whisper-1".len,
        &transcription_model,
    ));
    defer providers.ai_transcription_model_destroy(transcription_model);
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"text\":\"hello world\",\"language\":\"english\",\"duration\":1.5,\"segments\":[{\"start\":0,\"end\":1.5,\"text\":\"hello world\"}]}" },
    });
    const audio = "RIFFtiny";
    try std.testing.expectEqual(.ok, media_api.ai_transcribe(
        runtime_handle,
        transcription_model,
        audio.ptr,
        audio.len,
        "{\"maxRetries\":0}".ptr,
        "{\"maxRetries\":0}".len,
        &result_handle,
    ));
    try std.testing.expectEqualStrings("hello world", stringSlice(result_api.ai_result_text(result_handle)));
    result_api.ai_result_destroy(result_handle);
    try std.testing.expectEqual(0, server.serveErrorCount());
}
