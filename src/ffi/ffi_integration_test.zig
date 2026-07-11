const std = @import("std");
const provider = @import("provider");
const test_support = @import("test_support");
const providers = @import("providers.zig");
const result_api = @import("result.zig");
const runtime_api = @import("runtime.zig");
const stream_api = @import("stream.zig");
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
        out[0] = .{ .ptr = ptr, .len = output.len };
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
    var part: types.ai_part = undefined;
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
