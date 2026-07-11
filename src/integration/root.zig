const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const test_support = @import("test_support");
const openai_compatible = @import("openai_compatible");
const anthropic = @import("anthropic");
const openrouter = @import("openrouter");
const ai = @import("ai");
const build_options = @import("build_options");

const api = provider_utils.api;
const retry_api = provider_utils.retry_api;

fn makeUrl(arena: std.mem.Allocator, server: *test_support.MockServer, path: []const u8) ![]const u8 {
    var base_buffer: [64]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ server.baseUrl(&base_buffer), path });
}

fn recordedHeader(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and
            std.mem.indexOf(u8, header.value, "ai-sdk-zig") != null)
        {
            return header.value;
        }
    }
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn exportEnvValue(contents: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equals], " \t"), name)) continue;
        var value = std.mem.trim(u8, line[equals + 1 ..], " \t\r");
        if (value.len >= 2 and
            ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }
        return if (value.len == 0) null else value;
    }
    return null;
}

const ErrorShape = struct {
    @"error": struct { message: []const u8 },
};

const LoopWeatherTool = struct {
    calls: usize = 0,
    saw_city: bool = false,

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.saw_city = input == .object and input.object.get("city") != null;
        var output: std.json.ObjectMap = .empty;
        try output.put(arena, "condition", .{ .string = "sunny" });
        try output.put(arena, "temperature", .{ .integer = 21 });
        return .{ .value = .{ .object = output } };
    }
};

fn loopWeatherTools(recorder: *LoopWeatherTool) [1]ai.NamedTool {
    return .{.{
        .name = "weather",
        .tool = .{
            .description = .{ .text = "Get the weather for a city" },
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = recorder, .execute_fn = LoopWeatherTool.execute },
        },
    }};
}

fn errorMessage(value: ErrorShape) []const u8 {
    return value.@"error".message;
}

test "integration ai prompt downloads unsupported URL file and sniffs media type" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    const png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1 };
    try server.enqueue(.{
        .content_type = "application/octet-stream",
        .body = .{ .text = &png },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try makeUrl(arena, server, "/asset/image");

    const FakeModel = struct {
        fn providerName(_: *anyopaque) []const u8 {
            return "fake";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "download-test";
        }
        fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn generate(
            _: *anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: *const provider.CallOptions,
            _: ?*provider.Diagnostics,
        ) provider.CallError!provider.GenerateResult {
            return error.UnsupportedFunctionalityError;
        }
        fn stream(
            _: *anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: *const provider.CallOptions,
            _: ?*provider.Diagnostics,
        ) provider.CallError!provider.StreamResult {
            return error.UnsupportedFunctionalityError;
        }
    };
    var marker: u8 = 0;
    const model: provider.LanguageModel = .{ .ctx = &marker, .vtable = &.{
        .provider = FakeModel.providerName,
        .modelId = FakeModel.modelId,
        .urlIsSupported = FakeModel.supported,
        .doGenerate = FakeModel.generate,
        .doStream = FakeModel.stream,
    } };
    const parts = [_]ai.message.UserContentPart{.{ .file = .{
        .data = .{ .url = url },
        .media_type = "image",
    } }};
    const messages = [_]ai.ModelMessage{.{ .user = .{
        .content = .{ .parts = &parts },
    } }};
    const converted = try ai.convertToLanguageModelPrompt(
        io,
        allocator,
        arena,
        .{
            .prompt = .{ .instructions = null, .messages = &messages },
            .model = model,
            .transport = client.transport(),
            .download_options = .{ .allow_private_networks = true },
        },
        null,
    );
    const file = converted[0].user.content[0].file;
    try std.testing.expectEqualStrings("image/png", file.media_type);
    try std.testing.expectEqualSlices(u8, &png, file.data.data.data.bytes);
    try std.testing.expectEqual(1, server.recordedRequests().len);
    try std.testing.expectEqual(.GET, server.recordedRequests()[0].method);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration postJsonToApi 200 JSON records combined headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"ok\":true,\"ignored\":1}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try makeUrl(arena, server, "/v1/json");
    const Shape = struct { ok: bool };
    const result = try api.postJsonToApi(
        Shape,
        io,
        arena,
        client.transport(),
        .{
            .url = url,
            .headers = &.{.{ .name = "x-test", .value = "present" }},
            .body_json = "{\"prompt\":\"hello\"}",
        },
        .{
            .success = api.jsonResponseHandler(Shape),
            .failure = api.statusCodeErrorResponseHandler(),
        },
        null,
    );
    try std.testing.expect(result.value.ok);
    try std.testing.expectEqualStrings("{\"ok\":true,\"ignored\":1}", result.raw_body.?);
    try std.testing.expectEqualStrings(
        "application/json",
        provider_utils.getHeader(result.response_headers, "content-type").?,
    );

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqual(.POST, requests[0].method);
    try std.testing.expectEqualStrings("{\"prompt\":\"hello\"}", requests[0].body);
    try std.testing.expectEqualStrings(
        "application/json",
        recordedHeader(requests[0].headers, "content-type").?,
    );
    const user_agent = recordedHeader(requests[0].headers, "user-agent").?;
    try std.testing.expect(std.mem.indexOf(
        u8,
        user_agent,
        "ai-sdk-zig/provider-utils/0.0.0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, user_agent, "runtime/zig/0.16.0") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration postJsonToApi 429 JSON error populates retryable diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .status = .too_many_requests,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"rate limited\"}}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try makeUrl(arena, server, "/v1/rate-limit");
    const Shape = struct { ok: bool };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.APICallError, api.postJsonToApi(
        Shape,
        io,
        arena,
        client.transport(),
        .{ .url = url, .body_json = "{}" },
        .{
            .success = api.jsonResponseHandler(Shape),
            .failure = api.jsonErrorResponseHandler(ErrorShape, errorMessage),
        },
        &diagnostics,
    ));
    const payload = diagnostics.payload.api_call;
    try std.testing.expectEqual(429, payload.status_code.?);
    try std.testing.expect(payload.is_retryable);
    try std.testing.expectEqualStrings("rate limited", payload.message);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"message\":\"rate limited\"}}",
        payload.data_json.?,
    );
}

test "integration eventSourceResponseHandler streams parse results and stops at DONE" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"index\":1}" },
            .{ .data = "malformed" },
            .{ .data = "{\"index\":2}" },
            .{ .data = "[DONE]" },
            .{ .data = "{\"index\":3}" },
        } },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var request_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer request_arena_state.deinit();
    const request_arena = request_arena_state.allocator();
    const url = try makeUrl(request_arena, server, "/v1/stream");
    const Chunk = struct { index: u32 };
    const Stream = provider_utils.JsonEventStream(Chunk);
    const result = try api.postJsonToApi(
        Stream,
        io,
        request_arena,
        client.transport(),
        .{ .url = url, .body_json = "{}" },
        .{
            .success = api.eventSourceResponseHandler(Chunk),
            .failure = api.statusCodeErrorResponseHandler(),
        },
        null,
    );
    var stream = result.value;
    defer stream.deinit();
    var event_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer event_arena_state.deinit();
    const event_arena = event_arena_state.allocator();

    switch ((try stream.next(event_arena)).?) {
        .success => |success| try std.testing.expectEqual(1, success.value.index),
        .failure => return error.UnexpectedParseFailure,
    }
    switch ((try stream.next(event_arena)).?) {
        .failure => |failure| try std.testing.expectEqualStrings("malformed", failure.raw),
        .success => return error.UnexpectedParseSuccess,
    }
    switch ((try stream.next(event_arena)).?) {
        .success => |success| try std.testing.expectEqual(2, success.value.index),
        .failure => return error.UnexpectedParseFailure,
    }
    try std.testing.expectEqual(null, try stream.next(event_arena));
    try std.testing.expectEqual(null, try stream.next(event_arena));
}

test "integration retry uses two 500 responses then succeeds and leaves first 400 raw" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .status = .internal_server_error,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"first\"}}" },
    });
    try server.enqueue(.{
        .status = .internal_server_error,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"second\"}}" },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"ok\":true}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Shape = struct { ok: bool };
    const Context = struct {
        arena: std.mem.Allocator,
        transport: provider_utils.HttpTransport,
        url: []const u8,

        fn op(
            self: *@This(),
            task_io: std.Io,
            _: u32,
            diag: ?*provider.Diagnostics,
        ) anyerror!Shape {
            const result = try api.postJsonToApi(
                Shape,
                task_io,
                self.arena,
                self.transport,
                .{ .url = self.url, .body_json = "{}" },
                .{
                    .success = api.jsonResponseHandler(Shape),
                    .failure = api.jsonErrorResponseHandler(ErrorShape, errorMessage),
                },
                diag,
            );
            return result.value;
        }
    };
    var context: Context = .{
        .arena = arena,
        .transport = client.transport(),
        .url = try makeUrl(arena, server, "/v1/retry"),
    };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const value = try retry_api.retry(
        Shape,
        io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    );
    try std.testing.expect(value.ok);
    try std.testing.expectEqual(3, server.recordedRequests().len);

    try server.enqueue(.{
        .status = .bad_request,
        .content_type = "application/json",
        .body = .{ .text = "{\"error\":{\"message\":\"bad\"}}" },
    });
    context.url = try makeUrl(arena, server, "/v1/no-retry");
    const before = server.recordedRequests().len;
    try std.testing.expectError(error.APICallError, retry_api.retry(
        Shape,
        io,
        .{ .max_retries = 2, .initial_delay_ms = 1 },
        &context,
        Context.op,
        &diagnostics,
    ));
    try std.testing.expectEqual(before + 1, server.recordedRequests().len);
    try std.testing.expect(diagnostics.payload == .api_call);
    try std.testing.expect(!diagnostics.payload.api_call.is_retryable);
}

const RewriteTransport = struct {
    inner: provider_utils.HttpTransport,
    target_url: []const u8,

    fn transport(self: *RewriteTransport) provider_utils.HttpTransport {
        return .{ .ctx = self, .vtable = &.{ .request = request } };
    }

    fn request(
        raw: *anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        spec: provider_utils.RequestSpec,
        diag: ?*provider.Diagnostics,
    ) provider_utils.http_transport.RequestError!provider_utils.Response {
        const self: *RewriteTransport = @ptrCast(@alignCast(raw));
        var rewritten = spec;
        rewritten.url = self.target_url;
        return self.inner.request(io, arena, rewritten, diag);
    }
};

test "integration download decodes data URLs and rejects oversized canned body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/octet-stream",
        .body = .{ .text = "0123456789" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inline_result = try provider_utils.download(
        io,
        arena,
        client.transport(),
        "data:text/plain;base64,aGVsbG8=",
        .{},
        null,
    );
    try std.testing.expectEqualStrings("hello", inline_result.data);
    try std.testing.expectEqualStrings("text/plain", inline_result.media_type.?);

    var rewrite: RewriteTransport = .{
        .inner = client.transport(),
        .target_url = try makeUrl(arena, server, "/oversized"),
    };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.DownloadError, provider_utils.download(
        io,
        arena,
        rewrite.transport(),
        "https://example.com/oversized",
        .{ .max_size = 5 },
        &diagnostics,
    ));
    try std.testing.expect(diagnostics.payload == .download);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.payload.download.message,
        "exceeded maximum size",
    ) != null);
}

test "integration openai-compatible generate maps response and records request shape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-1","created":1700000000,"model":"vendor/model","choices":[{"message":{"role":"assistant","content":"Hello","reasoning_content":"Thought","tool_calls":[{"id":"call-1","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":12,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":2},"completion_tokens_details":{"reasoning_tokens":3}}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var request_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer request_arena_state.deinit();
    const arena = request_arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "test-provider",
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .query_params = &.{.{ .name = "region", .value = "us east" }},
        .transport = client.transport(),
    });
    var chat = try factory.chatModel("vendor/model", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doGenerate(io, arena, &options, null);

    try std.testing.expectEqual(3, result.content.len);
    try std.testing.expectEqualStrings("Hello", result.content[0].text.text);
    try std.testing.expectEqualStrings("Thought", result.content[1].reasoning.text);
    try std.testing.expectEqualStrings("call-1", result.content[2].tool_call.tool_call_id);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, result.finish_reason.unified);
    try std.testing.expectEqual(12, result.usage.input_tokens.total.?);
    try std.testing.expectEqual(10, result.usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(4, result.usage.output_tokens.text.?);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqualStrings("/chat/completions?region=us%20east", requests[0].target);
    try std.testing.expectEqualStrings(
        "Bearer test-key",
        recordedHeader(requests[0].headers, "authorization").?,
    );
    const request_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, requests[0].body, .{});
    try std.testing.expectEqualStrings("vendor/model", request_json.object.get("model").?.string);
    try std.testing.expectEqualStrings(
        "Hello",
        request_json.object.get("messages").?.array.items[0].object.get("content").?.string,
    );
}

test "openai-compatible request merges four option namespaces and structured output" {
    const allocator = std.testing.allocator;
    var client = provider_utils.HttpClientTransport.init(allocator, std.testing.io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "my-provider.chat",
        .base_url = "https://example.invalid/v1",
        .transport = client.transport(),
        .supports_structured_outputs = true,
    });
    var chat = try factory.chatModel("vendor/model", null);
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        \\{"openai-compatible":{"legacyOption":1,"user":"legacy"},"openaiCompatible":{"genericOption":2,"user":"generic"},"my-provider":{"rawOption":3,"user":"raw"},"myProvider":{"camelOption":{"enabled":true},"user":"camel","strictJsonSchema":false}}
    ,
        .{},
    );
    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}}}",
        .{},
    );
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{
        .prompt = &prompt,
        .provider_options = provider_options,
        .response_format = .{ .json = .{ .schema = schema, .name = "answer" } },
    };
    const prepared = try chat.prepareRequest(arena, &options, false, null);
    const body = prepared.body.object;
    try std.testing.expectEqualStrings("camel", body.get("user").?.string);
    try std.testing.expectEqual(1, body.get("legacyOption").?.integer);
    try std.testing.expectEqual(2, body.get("genericOption").?.integer);
    try std.testing.expectEqual(3, body.get("rawOption").?.integer);
    try std.testing.expect(body.get("camelOption").?.object.get("enabled").?.bool);
    const response_format = body.get("response_format").?.object;
    try std.testing.expectEqualStrings("json_schema", response_format.get("type").?.string);
    const json_schema = response_format.get("json_schema").?.object;
    try std.testing.expect(!json_schema.get("strict").?.bool);
    try std.testing.expectEqualStrings("answer", json_schema.get("name").?.string);
    try std.testing.expectEqualStrings("myProvider", prepared.metadata_key);
    try std.testing.expectEqual(2, prepared.warnings.len);
}

test "integration openai-compatible stream orders reasoning text and buffered tool deltas" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    // Payload shapes are copied from openai-compatible-chat-language-model.test.ts.
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"chat-1\",\"created\":1711357598,\"model\":\"vendor/model\",\"choices\":[{\"delta\":{\"reasoning_content\":\"Think\"}}]}" },
            .{ .data = "{\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"function\":{\"arguments\":\"{\\\"city\\\"\"}}]}}]}" },
            .{ .data = "{\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"weather\",\"arguments\":\":\\\"Paris\\\"}\"}}]}}]}" },
            .{ .data = "{\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\"Done\"}}]}" },
            .{ .data = "{\"id\":\"chat-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":3}}" },
            .{ .data = "[DONE]" },
        } },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "test-provider",
        .base_url = server.baseUrl(&base_buffer),
        .transport = client.transport(),
        .include_usage = true,
    });
    var chat = try factory.chatModel("vendor/model", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doStream(io, arena, &options, null);
    defer result.stream.deinit(io);

    var kinds: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer kinds.deinit(allocator);
    var tool_input: ?[]const u8 = null;
    while (try result.stream.next(io)) |part| {
        try kinds.append(allocator, std.meta.activeTag(part));
        switch (part) {
            .tool_call => |call| tool_input = try allocator.dupe(u8, call.input),
            else => {},
        }
    }
    defer if (tool_input) |value| allocator.free(value);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", tool_input.?);
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{
            .stream_start,
            .response_metadata,
            .reasoning_start,
            .reasoning_delta,
            .reasoning_end,
            .tool_input_start,
            .tool_input_delta,
            .text_start,
            .text_delta,
            .text_end,
            .tool_input_end,
            .tool_call,
            .finish,
        },
        kinds.items,
    );
}

test "integration anthropic generate maps native content and thinking request shape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"msg-1","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[{"type":"thinking","thinking":"Reason","signature":"sig-1"},{"type":"text","text":"Hello"},{"type":"tool_use","id":"tool-1","name":"weather","input":{"city":"Paris"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-sonnet-4-5-20250929", null);
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"anthropic\":{\"thinking\":{\"type\":\"enabled\",\"budgetTokens\":1024}}}",
        .{},
    );
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{
        .prompt = &prompt,
        .temperature = 0.5,
        .top_p = 0.8,
        .top_k = 20,
        .provider_options = provider_options,
    };
    const result = try chat.languageModel().doGenerate(io, arena, &options, null);
    try std.testing.expectEqual(3, result.content.len);
    try std.testing.expectEqualStrings("Reason", result.content[0].reasoning.text);
    try std.testing.expectEqualStrings("sig-1", result.content[0].reasoning.provider_metadata.?.object.get("anthropic").?.object.get("signature").?.string);
    try std.testing.expectEqualStrings("Hello", result.content[1].text.text);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", result.content[2].tool_call.input);
    try std.testing.expectEqual(15, result.usage.input_tokens.total.?);
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, result.finish_reason.unified);

    const request = server.recordedRequests()[0];
    try std.testing.expectEqualStrings("/messages", request.target);
    try std.testing.expectEqualStrings("test-key", recordedHeader(request.headers, "x-api-key").?);
    try std.testing.expectEqualStrings("2023-06-01", recordedHeader(request.headers, "anthropic-version").?);
    const request_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, request.body, .{});
    try std.testing.expect(request_json.object.get("temperature") == null);
    try std.testing.expect(request_json.object.get("top_p") == null);
    try std.testing.expect(request_json.object.get("top_k") == null);
    try std.testing.expectEqualStrings("enabled", request_json.object.get("thinking").?.object.get("type").?.string);
}

test "integration generateText anthropic two-step tool round trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"msg-loop-1","type":"message","role":"assistant","model":"claude-haiku","content":[{"type":"tool_use","id":"toolu-weather-1","name":"weather","input":{"city":"Paris"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":3}}
        },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"msg-loop-2","type":"message","role":"assistant","model":"claude-haiku","content":[{"type":"text","text":"Paris is sunny and 21 C."}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":9,"output_tokens":6}}
        },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-haiku", null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var result = try ai.generateText(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.loopFinished()},
    });
    defer result.deinit();

    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", result.text());
    try std.testing.expectEqual(14, result.usage().input_tokens.total.?);
    try std.testing.expectEqual(9, result.usage().output_tokens.total.?);
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"tool_use_id\":\"toolu-weather-1\"") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration generateText openai-compatible two-step tool round trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-loop-1","created":1700000000,"model":"vendor/model","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-weather-1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}
        },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-loop-2","created":1700000001,"model":"vendor/model","choices":[{"message":{"role":"assistant","content":"Paris is sunny and 21 C."},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":5}}
        },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "test-provider",
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.chatModel("vendor/model", null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var result = try ai.generateText(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.loopFinished()},
    });
    defer result.deinit();

    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", result.text());
    try std.testing.expectEqual(12, result.usage().input_tokens.total.?);
    try std.testing.expectEqual(7, result.usage().output_tokens.total.?);
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"tool_call_id\":\"call-weather-1\"") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "anthropic request uses JSON-tool fallback and clamps temperature" {
    const allocator = std.testing.allocator;
    var client = provider_utils.HttpClientTransport.init(allocator, std.testing.io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const factory = try anthropic.createAnthropic(.{
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"anthropic\":{\"structuredOutputMode\":\"jsonTool\"}}",
        .{},
    );
    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"]}",
        .{},
    );
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{
        .prompt = &prompt,
        .temperature = 2,
        .provider_options = provider_options,
        .response_format = .{ .json = .{ .schema = schema } },
    };
    const prepared = try chat.prepareRequest(arena, &options, false, null);
    try std.testing.expect(prepared.uses_json_response_tool);
    const body = prepared.body.object;
    try std.testing.expectEqual(1, body.get("temperature").?.float);
    try std.testing.expect(body.get("output_config") == null);
    const tools = body.get("tools").?.array.items;
    try std.testing.expectEqual(1, tools.len);
    try std.testing.expectEqualStrings("json", tools[0].object.get("name").?.string);
    const choice = body.get("tool_choice").?.object;
    try std.testing.expectEqualStrings("any", choice.get("type").?.string);
    try std.testing.expect(choice.get("disable_parallel_tool_use").?.bool);
    try std.testing.expectEqual(1, prepared.warnings.len);
    try std.testing.expectEqualStrings("temperature", prepared.warnings[0].unsupported.feature);
}

test "anthropic request maps advanced native options and feature betas" {
    const allocator = std.testing.allocator;
    var client = provider_utils.HttpClientTransport.init(allocator, std.testing.io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const factory = try anthropic.createAnthropic(.{
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-sonnet-4-5-20250929", null);
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        \\{"anthropic":{"mcpServers":[{"type":"url","name":"remote","url":"https://mcp.example","authorizationToken":"token","toolConfiguration":{"enabled":true,"allowedTools":["search"]}}],"container":{"id":"container-1","skills":[{"type":"anthropic","skillId":"pdf","version":"latest"},{"type":"custom","providerReference":{"anthropic":"skill-custom"}}]},"taskBudget":{"type":"tokens","total":20000,"remaining":10000},"fallbacks":[{"model":"claude-haiku-4-5","max_tokens":16}],"contextManagement":{"edits":[{"type":"clear_tool_uses_20250919","clearAtLeast":{"type":"input_tokens","value":1000},"clearToolInputs":true,"excludeTools":["slow"]},{"type":"compact_20260112","pauseAfterCompaction":true,"instructions":"Keep decisions"}]}}}
    ,
        .{},
    );
    const empty_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const tools = [_]provider.Tool{.{ .provider = .{
        .id = "anthropic.code_execution_20250825",
        .name = "code",
        .args = empty_args,
    } }};
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{
        .prompt = &prompt,
        .provider_options = provider_options,
        .tools = &tools,
    };
    const prepared = try chat.prepareRequest(arena, &options, false, null);
    const body = prepared.body.object;
    try std.testing.expectEqual(
        20_000,
        body.get("output_config").?.object.get("task_budget").?.object.get("total").?.integer,
    );
    const mcp = body.get("mcp_servers").?.array.items[0].object;
    try std.testing.expectEqualStrings("token", mcp.get("authorization_token").?.string);
    try std.testing.expect(mcp.get("tool_configuration").?.object.get("enabled").?.bool);
    const container = body.get("container").?.object;
    try std.testing.expectEqualStrings(
        "skill-custom",
        container.get("skills").?.array.items[1].object.get("skill_id").?.string,
    );
    try std.testing.expectEqualStrings(
        "claude-haiku-4-5",
        body.get("fallbacks").?.array.items[0].object.get("model").?.string,
    );
    const edits = body.get("context_management").?.object.get("edits").?.array.items;
    try std.testing.expect(edits[0].object.get("clear_tool_inputs").?.bool);
    try std.testing.expect(edits[1].object.get("pause_after_compaction").?.bool);

    const expected_betas = [_][]const u8{
        "mcp-client-2025-04-04",
        "skills-2025-10-02",
        "task-budgets-2026-03-13",
        "server-side-fallback-2026-06-01",
        "context-management-2025-06-27",
        "compact-2026-01-12",
    };
    for (expected_betas) |expected| {
        var found = false;
        for (prepared.betas.order.items) |beta| {
            if (std.mem.eql(u8, beta, expected)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "integration anthropic text stream maps exact part order and cache usage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    // Fixture payloads are verbatim from anthropic-language-model.test.ts.
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_01KfpJoAEabmH2iHRRFjQMAG\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-haiku-20240307\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":17,\"cache_creation_input_tokens\":4,\"cache_read_input_tokens\":5,\"output_tokens\":1}}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\", World!\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":7}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doStream(io, arena, &options, null);
    defer result.stream.deinit(io);

    var tags: std.ArrayList(std.meta.Tag(provider.StreamPart)) = .empty;
    defer tags.deinit(allocator);
    var input_total: ?u64 = null;
    while (try result.stream.next(io)) |part| {
        try tags.append(allocator, std.meta.activeTag(part));
        if (part == .finish) input_total = part.finish.usage.input_tokens.total;
    }
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{ .stream_start, .response_metadata, .text_start, .text_delta, .text_delta, .text_end, .finish },
        tags.items,
    );
    try std.testing.expectEqual(26, input_total.?);
}

test "integration anthropic HTTP 200 overload fails doStream as retryable 529" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{.{ .data = "{\"type\":\"error\",\"error\":{\"details\":null,\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", .event = "error" }} },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.APICallError,
        chat.languageModel().doStream(io, arena, &options, &diagnostics),
    );
    try std.testing.expectEqual(529, diagnostics.payload.api_call.status_code.?);
    try std.testing.expect(diagnostics.payload.api_call.is_retryable);
    try std.testing.expectEqualStrings("Overloaded", diagnostics.payload.api_call.message);
}

test "integration OpenRouter wrapper sends attribution headers and verbatim model id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-1","model":"anthropic/claude-haiku","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}
        },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    var factory = openrouter.createOpenRouter(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "router-key",
        .transport = client.transport(),
        .http_referer = "https://app.example",
        .x_title = "Example App",
    });
    var chat = try factory.chatModel("anthropic/claude-haiku", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "hi" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doGenerate(io, arena, &options, null);
    try std.testing.expectEqualStrings("ok", result.content[0].text.text);
    const request = server.recordedRequests()[0];
    try std.testing.expectEqualStrings("/chat/completions", request.target);
    try std.testing.expectEqualStrings("https://app.example", recordedHeader(request.headers, "HTTP-Referer").?);
    try std.testing.expectEqualStrings("Example App", recordedHeader(request.headers, "X-Title").?);
    try std.testing.expectEqualStrings("Bearer router-key", recordedHeader(request.headers, "authorization").?);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, request.body, .{});
    try std.testing.expectEqualStrings("anthropic/claude-haiku", body.object.get("model").?.string);
}

test "integration anthropic tool stream accumulates input_json_delta and normalizes empty input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    // Verbatim fixture payloads from anthropic-language-model.test.ts
    // "should stream tool deltas".
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-tool\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-3-haiku-20240307\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":441,\"output_tokens\":2},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01DBsB4vvYLnBDzZ5rBSxSLs\",\"name\":\"test-tool\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"value\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\":\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Sparkle Day\\\"}\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":1}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-empty\",\"name\":\"empty-tool\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":2}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":65}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doStream(io, arena, &options, null);
    defer result.stream.deinit(io);
    var calls: std.ArrayList([]const u8) = .empty;
    defer {
        for (calls.items) |input| allocator.free(input);
        calls.deinit(allocator);
    }
    var delta_count: usize = 0;
    while (try result.stream.next(io)) |part| switch (part) {
        .tool_input_delta => delta_count += 1,
        .tool_call => |call| try calls.append(allocator, try allocator.dupe(u8, call.input)),
        else => {},
    };
    try std.testing.expectEqual(3, delta_count);
    try std.testing.expectEqualStrings("{\"value\":\"Sparkle Day\"}", calls.items[0]);
    try std.testing.expectEqualStrings("{}", calls.items[1]);
}

test "integration anthropic thinking stream carries signature provider metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    // Verbatim fixture payload shapes from anthropic-language-model.test.ts
    // "should stream reasoning deltas".
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-think\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-haiku-20240307\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":17,\"output_tokens\":1}}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"I am\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"1234567890\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":7}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doStream(io, arena, &options, null);
    defer result.stream.deinit(io);
    var signature: ?[]const u8 = null;
    while (try result.stream.next(io)) |part| switch (part) {
        .reasoning_delta => |delta| if (delta.provider_metadata) |metadata| {
            signature = metadata.object.get("anthropic").?.object.get("signature").?.string;
        },
        else => {},
    };
    try std.testing.expectEqualStrings("1234567890", signature.?);
}

test "integration openai-compatible early error frame becomes error part then finish" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    // From openai-compatible-chat-language-model.test.ts "should handle error stream parts".
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"error\":{\"message\":\"Incorrect API key\",\"code\":\"invalid_argument\"}}" },
            .{ .data = "[DONE]" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_buffer: [64]u8 = undefined;
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "test-provider",
        .base_url = server.baseUrl(&base_buffer),
        .transport = client.transport(),
    });
    var chat = try factory.chatModel("vendor/model", null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Hello" } }},
    } }};
    const options: provider.CallOptions = .{ .prompt = &prompt };
    const result = try chat.languageModel().doStream(io, arena, &options, null);
    defer result.stream.deinit(io);
    var tags: [3]std.meta.Tag(provider.StreamPart) = undefined;
    var count: usize = 0;
    while (try result.stream.next(io)) |part| {
        tags[count] = std.meta.activeTag(part);
        count += 1;
    }
    try std.testing.expectEqual(3, count);
    try std.testing.expectEqualSlices(
        std.meta.Tag(provider.StreamPart),
        &.{ .stream_start, .err, .finish },
        tags[0..count],
    );
}

test "live Anthropic generate and stream smoke" {
    if (!build_options.live) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const env_path = "/home/autark/src/rctr/.env";
    const env_file = std.Io.Dir.cwd().readFileAlloc(
        io,
        env_path,
        allocator,
        .limited(1024 * 1024),
    ) catch {
        std.debug.print("live Anthropic smoke skipped: {s} is unavailable\n", .{env_path});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "ANTHROPIC_API_KEY") orelse {
        std.debug.print("live Anthropic smoke skipped: ANTHROPIC_API_KEY is absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key,
        .transport = client.transport(),
    });
    const model_id = "claude-haiku-4-5-20251001";
    var chat = try factory.messages(model_id, null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Reply with one short greeting." } }},
    } }};
    const options: provider.CallOptions = .{
        .prompt = &prompt,
        .max_output_tokens = 32,
    };

    var generate_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer generate_arena_state.deinit();
    const generated = try chat.languageModel().doGenerate(
        io,
        generate_arena_state.allocator(),
        &options,
        null,
    );
    var generated_text_bytes: usize = 0;
    for (generated.content) |content| switch (content) {
        .text => |part| generated_text_bytes += part.text.len,
        else => {},
    };
    try std.testing.expect(generated_text_bytes > 0);
    try std.testing.expect(
        generated.finish_reason.unified == .stop or
            generated.finish_reason.unified == .length,
    );

    var stream_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer stream_arena_state.deinit();
    const streamed = try chat.languageModel().doStream(
        io,
        stream_arena_state.allocator(),
        &options,
        null,
    );
    defer streamed.stream.deinit(io);
    var part_count: usize = 0;
    var text_delta_count: usize = 0;
    var streamed_text_bytes: usize = 0;
    var saw_finish = false;
    while (try streamed.stream.next(io)) |part| {
        part_count += 1;
        switch (part) {
            .text_delta => |delta| {
                text_delta_count += 1;
                streamed_text_bytes += delta.delta.len;
            },
            .finish => saw_finish = true,
            .err => return error.LiveProviderStreamError,
            else => {},
        }
    }
    try std.testing.expect(text_delta_count > 0);
    try std.testing.expect(streamed_text_bytes > 0);
    try std.testing.expect(saw_finish);
    std.debug.print(
        "live Anthropic smoke: model={s} generate_text_bytes={d} stream_parts={d} text_deltas={d} streamed_text_bytes={d}\n",
        .{ model_id, generated_text_bytes, part_count, text_delta_count, streamed_text_bytes },
    );
}

test "live Anthropic generateText two-step tool loop" {
    if (!build_options.live) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const env_path = "/home/autark/src/rctr/.env";
    const env_file = std.Io.Dir.cwd().readFileAlloc(
        io,
        env_path,
        allocator,
        .limited(1024 * 1024),
    ) catch {
        std.debug.print("live Anthropic tool loop skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "ANTHROPIC_API_KEY") orelse {
        std.debug.print("live Anthropic tool loop skipped: API key absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key,
        .transport = client.transport(),
    });
    const model_id = "claude-haiku-4-5-20251001";
    var chat = try factory.messages(model_id, null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var result = try ai.generateText(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .instructions = .{ .text = "Call the weather tool exactly once for the requested city. After the tool result, answer in one short sentence and do not call any more tools." },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.loopFinished()},
        .max_output_tokens = 200,
    });
    defer result.deinit();

    const total_tokens = (result.usage().input_tokens.total orelse 0) +
        (result.usage().output_tokens.total orelse 0);
    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqual(1, result.toolCalls().len);
    try std.testing.expect(result.text().len > 0);
    try std.testing.expect(total_tokens > 0);
    std.debug.print(
        "live Anthropic tool loop: steps={d} tool_calls={d} executions={d} final_text_bytes={d} total_tokens={d}\n",
        .{ result.steps.len, result.toolCalls().len, weather.calls, result.text().len, total_tokens },
    );
}
