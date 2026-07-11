const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const test_support = @import("test_support");
const openai = @import("openai");
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

test "integration postFormDataToApi records exact boundary header and wire body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"ok\":true}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try makeUrl(arena, server, "/v1/form");
    var form = try provider_utils.FormData.initFromSeed(arena, 0x10);
    try form.appendText("model", "whisper-1");
    try form.appendFile("file", "audio.mp3", "audio/mpeg", &.{ 0xff, 0xfb, 0x01 });
    const Shape = struct { ok: bool };
    const result = try api.postFormDataToApi(
        Shape,
        io,
        arena,
        client.transport(),
        .{ .url = url, .form_data = &form },
        .{
            .success = api.jsonResponseHandler(Shape),
            .failure = api.statusCodeErrorResponseHandler(),
        },
        null,
    );
    try std.testing.expect(result.value.ok);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{form.boundary}),
        recordedHeader(requests[0].headers, "content-type").?,
    );
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(
            arena,
            "--{s}\r\n" ++
                "Content-Disposition: form-data; name=\"model\"\r\n\r\n" ++
                "whisper-1\r\n" ++
                "--{s}\r\n" ++
                "Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\n" ++
                "Content-Type: audio/mpeg\r\n\r\n" ++
                "\xff\xfb\x01\r\n" ++
                "--{s}--\r\n",
            .{ form.boundary, form.boundary, form.boundary },
        ),
        requests[0].body,
    );
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

test "integration streamText anthropic two-step streaming tool round trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-stream-loop-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":5,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu-stream-weather-1\",\"name\":\"weather\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":3}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-stream-loop-2\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":9,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Paris is sunny and 21 C.\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":6}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
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
    var result = try ai.streamText(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.loopFinished()},
    });
    defer result.deinit(io);

    var tags: std.ArrayList(std.meta.Tag(ai.TextStreamPart)) = .empty;
    defer tags.deinit(allocator);
    while (try result.next(io)) |part| try tags.append(allocator, std.meta.activeTag(part));
    try std.testing.expectEqualSlices(
        std.meta.Tag(ai.TextStreamPart),
        &.{
            .start,
            .start_step,
            .tool_input_start,
            .tool_input_delta,
            .tool_input_end,
            .tool_call,
            .tool_result,
            .finish_step,
            .start_step,
            .text_start,
            .text_delta,
            .text_end,
            .finish_step,
            .finish,
        },
        tags.items,
    );
    try std.testing.expectEqual(2, (try result.steps(io)).len);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", try result.text(io));
    try std.testing.expectEqual(14, (try result.totalUsage(io)).input_tokens.total.?);
    try std.testing.expectEqual(9, (try result.totalUsage(io)).output_tokens.total.?);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"tool_use_id\":\"toolu-stream-weather-1\"") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration streamText anthropic chunk timeout emits abort" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-timeout\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}", .delay_ms = 50 },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"late\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":2}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
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
    var result = try ai.streamText(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "timeout" },
        .timeout = .{ .granular = .{ .chunk_ms = 5 } },
    });
    defer result.deinit(io);

    var tags: std.ArrayList(std.meta.Tag(ai.TextStreamPart)) = .empty;
    defer tags.deinit(allocator);
    var reason: ?[]const u8 = null;
    while (try result.next(io)) |part| {
        try tags.append(allocator, std.meta.activeTag(part));
        if (part == .abort) reason = part.abort.reason;
    }
    try std.testing.expectEqualSlices(
        std.meta.Tag(ai.TextStreamPart),
        &.{ .start, .start_step, .abort },
        tags.items,
    );
    try std.testing.expectEqualStrings("Chunk timeout after 5ms", reason.?);
    try std.testing.expectError(error.Canceled, result.text(io));
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

test "integration anthropic tool SSE flows through model callbacks and execution stages" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-tool-stage\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-3-haiku-20240307\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":12,\"output_tokens\":2},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-stage-1\",\"name\":\"test-tool\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"value\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\":\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Sparkle Day\\\"}\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":1}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":15}}" },
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

    const Executor = struct {
        calls: usize = 0,
        fn run(
            raw: ?*anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            input: std.json.Value,
            _: ai.tool.ToolExecutionOptions,
        ) anyerror!ai.tool.ToolOutput {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try std.testing.expectEqualStrings("Sparkle Day", input.object.get("value").?.string);
            return .{ .value = .{ .string = "executed" } };
        }
    };
    var executor: Executor = .{};
    const tools = [_]ai.NamedTool{.{ .name = "test-tool", .tool = .{
        .input_schema = provider_utils.schemaFromType(struct { value: []const u8 }),
        .execute = .{ .ctx = &executor, .execute_fn = Executor.run },
    } }};
    const app_messages = [_]ai.ModelMessage{.{ .user = .{ .content = .{ .text = "Hello" } } }};
    const stage1 = try ai.stream.model_call.streamLanguageModelCall(io, allocator, arena, .{
        .model = .{ .model = chat.languageModel() },
        .messages = &app_messages,
        .tools = &tools,
        .transport = client.transport(),
    });
    const stage2 = try ai.stream.tool_callbacks.invokeToolCallbacksFromStream(arena, .{
        .upstream = stage1.stage,
        .tools = &tools,
        .messages = &app_messages,
    });
    var output_buffer: [4]ai.LanguageModelStreamPart = undefined;
    const stage3 = try ai.stream.tool_execution.executeToolsFromStream(io, allocator, arena, .{
        .upstream = stage2,
        .output_buffer = &output_buffer,
        .tools = &tools,
        .call_id = "integration-call",
        .messages = &app_messages,
    });
    defer stage3.deinit(io);

    var tags: std.ArrayList(std.meta.Tag(ai.LanguageModelStreamPart)) = .empty;
    defer tags.deinit(allocator);
    var final_output: ?[]const u8 = null;
    while (try stage3.next(io)) |part| {
        try tags.append(allocator, std.meta.activeTag(part));
        if (part == .tool_result and !part.tool_result.preliminary) final_output = part.tool_result.output.string;
    }
    try std.testing.expectEqualSlices(
        std.meta.Tag(ai.LanguageModelStreamPart),
        &.{
            .model_call_start,
            .model_call_response_metadata,
            .tool_input_start,
            .tool_input_delta,
            .tool_input_delta,
            .tool_input_delta,
            .tool_input_end,
            .tool_call,
            .model_call_end,
            .tool_execution_end,
            .tool_result,
        },
        tags.items,
    );
    try std.testing.expectEqual(1, executor.calls);
    try std.testing.expectEqualStrings("executed", final_output.?);
    try std.testing.expectEqual(0, server.serveErrorCount());
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

test "integration generateObject uses OpenAI json_schema response format" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"object-1","created":1700000000,"model":"vendor/object","choices":[{"message":{"role":"assistant","content":"{\"name\":\"Ada\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":3}}
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
        .supports_structured_outputs = true,
    });
    var chat = try factory.chatModel("vendor/object", null);
    const Shape = struct { name: []const u8 };
    var result = try ai.generateObject(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "Return a name." },
        .schema = provider_utils.schemaFromType(Shape),
        .schema_name = "person",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Ada", result.object.object.get("name").?.string);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const request = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), requests[0].body, .{});
    const response_format = request.object.get("response_format").?.object;
    try std.testing.expectEqualStrings("json_schema", response_format.get("type").?.string);
    try std.testing.expectEqualStrings("person", response_format.get("json_schema").?.object.get("name").?.string);
}

test "integration generateObject uses Anthropic JSON-tool fallback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"msg-object","type":"message","role":"assistant","model":"claude-3-haiku-20240307","content":[{"type":"tool_use","id":"tool-json","name":"json","input":{"name":"Ada"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":4}}
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
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const Shape = struct { name: []const u8 };
    var result = try ai.generateObject(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "Return a name." },
        .schema = provider_utils.schemaFromType(Shape),
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Ada", result.object.object.get("name").?.string);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const request = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_state.allocator(),
        server.recordedRequests()[0].body,
        .{},
    );
    try std.testing.expect(request.object.get("output_config") == null);
    try std.testing.expectEqualStrings(
        "json",
        request.object.get("tools").?.array.items[0].object.get("name").?.string,
    );
}

test "integration streamObject parses OpenAI SSE partials" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"id\":\"stream-object\",\"created\":1700000000,\"model\":\"vendor/object\",\"choices\":[{\"delta\":{\"content\":\"{\\\"name\\\":\"}}]}" },
            .{ .data = "{\"id\":\"stream-object\",\"choices\":[{\"delta\":{\"content\":\"\\\"Ada\\\"}\"}}]}" },
            .{ .data = "{\"id\":\"stream-object\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":3}}" },
            .{ .data = "[DONE]" },
        } },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "test-provider",
        .base_url = server.baseUrl(&base_buffer),
        .transport = client.transport(),
        .include_usage = true,
        .supports_structured_outputs = true,
    });
    var chat = try factory.chatModel("vendor/object", null);
    const Shape = struct { name: []const u8 };
    var result = try ai.streamObject(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "Return a name." },
        .schema = provider_utils.schemaFromType(Shape),
    });
    defer result.deinit(io);
    var partials = result.partialObjectStream();
    var partial_count: usize = 0;
    while (try partials.next(io)) |_| partial_count += 1;
    try std.testing.expect(partial_count > 0);
    try std.testing.expectEqualStrings("Ada", (try result.object(io)).object.get("name").?.string);
}

test "integration streamObject parses Anthropic JSON-tool SSE fallback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-object\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-3-haiku-20240307\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":5,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-json\",\"name\":\"json\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Ada\\\"}\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":4}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.messages("claude-3-haiku-20240307", null);
    const Shape = struct { name: []const u8 };
    var result = try ai.streamObject(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "Return a name." },
        .schema = provider_utils.schemaFromType(Shape),
    });
    defer result.deinit(io);
    try std.testing.expectEqualStrings("Ada", (try result.object(io)).object.get("name").?.string);

    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();
    const request = try std.json.parseFromSliceLeaky(
        std.json.Value,
        request_arena.allocator(),
        server.recordedRequests()[0].body,
        .{},
    );
    try std.testing.expectEqualStrings(
        "json",
        request.object.get("tools").?.array.items[0].object.get("name").?.string,
    );
}

test "integration embedMany uses OpenAI-compatible embeddings endpoint and chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"data\":[{\"embedding\":[0.1,0.2]},{\"embedding\":[0.3,0.4]}],\"usage\":{\"prompt_tokens\":4}}" },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"data\":[{\"embedding\":[0.5,0.6]}],\"usage\":{\"prompt_tokens\":2}}" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var url_arena = std.heap.ArenaAllocator.init(allocator);
    defer url_arena.deinit();
    const base_url = try makeUrl(url_arena.allocator(), server, "/v1");
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "test-provider",
        .base_url = base_url,
        .api_key = "test-key",
        .transport = client.transport(),
        .max_embeddings_per_call = 2,
    });
    var embedding_model = try factory.embeddingModel("text-embedding", null);
    const values = [_][]const u8{ "one", "two", "three" };
    var result = try ai.embedMany(io, allocator, .{
        .model = .{ .model = embedding_model.embeddingModel() },
        .values = &values,
        .max_parallel_calls = 1,
    });
    defer result.deinit();
    try std.testing.expectEqual(3, result.embeddings.len);
    try std.testing.expectEqual(@as(f64, 0.5), result.embeddings[2][0]);
    try std.testing.expectEqual(6, result.usage.tokens.?);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expectEqualStrings("/v1/embeddings", requests[0].target);
    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();
    const first = try std.json.parseFromSliceLeaky(std.json.Value, request_arena.allocator(), requests[0].body, .{});
    try std.testing.expectEqualStrings("float", first.object.get("encoding_format").?.string);
    try std.testing.expectEqual(2, first.object.get("input").?.array.items.len);
}

test "integration Anthropic rejects embedding model lookup" {
    var client = provider_utils.HttpClientTransport.init(std.testing.allocator, std.testing.io);
    defer client.deinit();
    const factory = try anthropic.createAnthropic(.{ .transport = client.transport() });
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.NoSuchModelError, factory.embeddingModel("anything", &diagnostics));
    try std.testing.expectEqual(.embedding_model, diagnostics.payload.no_such_model.model_type);
}

test "integration ToolLoopAgent drives native OpenAI Chat through a two-step tool loop" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-agent-1","created":1700000000,"model":"gpt-4o-mini","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-weather-1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}
        },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-agent-2","created":1700000001,"model":"gpt-4o-mini","choices":[{"message":{"role":"assistant","content":"Paris is sunny and 21 C."},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":5}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    const factory = openai.createOpenAi(.{
        .allocator = allocator,
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var chat = try factory.chat("gpt-4o-mini", null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = chat.languageModel() },
        .instructions = .{ .text = "Call weather once, then answer." },
        .tools = &tools,
    });
    var result = try agent.generate(io, allocator, .{
        .prompt = .{ .text = "What is the weather in Paris?" },
    });
    defer result.deinit();

    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", result.text());
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"tool_call_id\":\"call-weather-1\"") != null);
    for (requests) |request| {
        const user_agent = recordedHeader(request.headers, "user-agent").?;
        try std.testing.expect(std.mem.indexOf(u8, user_agent, "ai-sdk-zig-agent/tool-loop") != null);
        try std.testing.expect(std.mem.indexOf(u8, user_agent, "ai-sdk-zig/openai/") != null);
    }
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration ToolLoopAgent drives the default OpenAI Responses model through a two-step tool loop" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"resp-agent-1","created_at":1700000000,"model":"gpt-4o-mini","output":[{"type":"function_call","id":"fc-weather-1","call_id":"call-weather-1","name":"weather","arguments":"{\"city\":\"Paris\"}"}],"incomplete_details":null,"usage":{"input_tokens":4,"output_tokens":2}}
        },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"resp-agent-2","created_at":1700000001,"model":"gpt-4o-mini","output":[{"type":"message","role":"assistant","id":"msg-agent-2","content":[{"type":"output_text","text":"Paris is sunny and 21 C.","annotations":[]}]}],"incomplete_details":null,"usage":{"input_tokens":8,"output_tokens":5}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var factory = openai.createOpenAi(.{
        .allocator = allocator,
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var responses = try factory.languageModel("gpt-4o-mini", null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = responses.languageModel() },
        .instructions = .{ .text = "Call weather once, then answer." },
        .tools = &tools,
    });
    var result = try agent.generate(io, allocator, .{
        .prompt = .{ .text = "What is the weather in Paris?" },
    });
    defer result.deinit();

    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", result.text());
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expectEqualStrings("/responses", requests[0].target);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"call_id\":\"call-weather-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"id\":\"fc-weather-1\",\"type\":\"item_reference\"") == null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration OpenAI Responses store=false round-trips encrypted reasoning through an agent step" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"resp-reasoning-1","created_at":1700000000,"model":"gpt-5-mini","output":[{"type":"reasoning","id":"rs-roundtrip","encrypted_content":"encrypted-roundtrip-payload","summary":[{"type":"summary_text","text":"Checking the weather tool."}]},{"type":"function_call","id":"fc-roundtrip","call_id":"call-roundtrip","name":"weather","arguments":"{\"city\":\"Paris\"}"}],"incomplete_details":null,"usage":{"input_tokens":6,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":2}}}
        },
    });
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"resp-reasoning-2","created_at":1700000001,"model":"gpt-5-mini","output":[{"type":"message","role":"assistant","id":"msg-roundtrip","content":[{"type":"output_text","text":"It is sunny.","annotations":[]}]}],"incomplete_details":null,"usage":{"input_tokens":12,"output_tokens":3}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var factory = openai.createOpenAi(.{
        .allocator = allocator,
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .transport = client.transport(),
    });
    var responses = try factory.responses("gpt-5-mini", null);
    var options_arena = std.heap.ArenaAllocator.init(allocator);
    defer options_arena.deinit();
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        options_arena.allocator(),
        "{\"openai\":{\"store\":false}}",
        .{},
    );
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = responses.languageModel() },
        .tools = &tools,
        .provider_options = provider_options,
    });
    var result = try agent.generate(io, allocator, .{ .prompt = .{ .text = "Weather?" } });
    defer result.deinit();
    try std.testing.expectEqual(2, result.steps.len);
    try std.testing.expectEqual(1, weather.calls);
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"reasoning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"encrypted_content\":\"encrypted-roundtrip-payload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1].body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "integration ToolLoopAgent remains provider-agnostic through Anthropic streaming" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-agent-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":5,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu-agent-weather-1\",\"name\":\"weather\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":3}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });
    try server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-agent-2\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":9,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Paris is sunny and 21 C.\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":6}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
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
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = chat.languageModel() },
        .instructions = .{ .text = "Call weather once, then answer." },
        .tools = &tools,
    });
    var result = try agent.stream(io, allocator, .{
        .prompt = .{ .text = "What is the weather in Paris?" },
    });
    defer result.deinit(io);

    var finish_steps: usize = 0;
    var tool_calls: usize = 0;
    while (try result.next(io)) |part| switch (part) {
        .finish_step => finish_steps += 1,
        .tool_call => tool_calls += 1,
        .abort => return error.AgentStreamAborted,
        .err => return error.AgentProviderStreamError,
        else => {},
    };
    try std.testing.expectEqual(2, finish_steps);
    try std.testing.expectEqual(1, tool_calls);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", try result.text(io));
    const requests = server.recordedRequests();
    try std.testing.expectEqual(2, requests.len);
    for (requests) |request| {
        const user_agent = recordedHeader(request.headers, "user-agent").?;
        try std.testing.expect(std.mem.indexOf(u8, user_agent, "ai-sdk-zig-agent/tool-loop") != null);
        try std.testing.expect(std.mem.indexOf(u8, user_agent, "ai-sdk-zig/anthropic/") != null);
    }
    try std.testing.expectEqual(0, server.serveErrorCount());
}

const AgentUiTestServer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    agent: ai.Agent,
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    serve_error: ?anyerror = null,

    fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        agent: ai.Agent,
    ) !*AgentUiTestServer {
        var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{
            .reuse_address = true,
        });
        const self = try gpa.create(AgentUiTestServer);
        self.* = .{ .gpa = gpa, .io = io, .agent = agent, .listener = listener };
        errdefer {
            listener.deinit(io);
            gpa.destroy(self);
        }
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    fn port(self: *const AgentUiTestServer) u16 {
        return switch (self.listener.socket.address) {
            .ip4 => |address| address.port,
            .ip6 => |address| address.port,
        };
    }

    fn url(self: *const AgentUiTestServer, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/api/chat", .{self.port()});
    }

    fn stop(self: *AgentUiTestServer) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        if (self.thread) |thread| {
            var wake = self.listener.socket.address.connect(self.io, .{ .mode = .stream }) catch null;
            if (wake) |*stream| stream.close(self.io);
            thread.join();
            self.thread = null;
        }
    }

    fn deinit(self: *AgentUiTestServer) void {
        self.stop();
        self.listener.deinit(self.io);
        self.gpa.destroy(self);
    }

    fn serve(self: *AgentUiTestServer) !void {
        const connection = try self.listener.accept(self.io);
        defer connection.close(self.io);
        var receive_buffer: [32 * 1024]u8 = undefined;
        var send_buffer: [16 * 1024]u8 = undefined;
        var reader = connection.reader(self.io, &receive_buffer);
        var writer = connection.writer(self.io, &send_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        if (request.head.method != .POST) return error.UnexpectedHttpMethod;

        var body_buffer: [16 * 1024]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body_text = try body_reader.allocRemaining(arena, .limited(1 << 20));
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, body_text, .{
            .allocate = .alloc_always,
        });
        const ui_messages = try ai.ui.convert_ui_messages.parseAndValidateUIMessages(
            arena,
            body.object.get("messages") orelse return error.MissingMessages,
            .{ .tools = self.agent.tools },
        );
        try ai.ui.writeAgentUIStreamResponse(
            self.io,
            self.gpa,
            &request,
            self.agent,
            ui_messages,
            .{},
            .{},
        );
    }

    fn threadMain(self: *AgentUiTestServer) void {
        self.serve() catch |err| {
            if (!self.stopping.load(.acquire)) self.serve_error = err;
        };
    }
};

test "integration UI HTTP round trip streams Anthropic agent tool lifecycle into Chat" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const provider_server = try test_support.MockServer.start(allocator, io);
    defer provider_server.deinit();
    try provider_server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-ui-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":5,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu-ui-weather-1\",\"name\":\"weather\",\"input\":{}}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":3}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });
    try provider_server.enqueue(.{
        .content_type = "text/event-stream",
        .body = .{ .sse = &.{
            .{ .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-ui-2\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":9,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}" },
            .{ .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" },
            .{ .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Paris is sunny and 21 C.\"}}" },
            .{ .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
            .{ .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":6}}" },
            .{ .data = "{\"type\":\"message_stop\"}" },
        } },
    });

    var provider_client = provider_utils.HttpClientTransport.init(allocator, io);
    defer provider_client.deinit();
    var provider_base: [64]u8 = undefined;
    const factory = try anthropic.createAnthropic(.{
        .base_url = provider_server.baseUrl(&provider_base),
        .api_key = "test-key",
        .transport = provider_client.transport(),
    });
    var model = try factory.messages("claude-haiku", null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = model.languageModel() },
        .instructions = .{ .text = "Call weather once, then answer." },
        .tools = &tools,
    });

    const ui_server = try AgentUiTestServer.start(allocator, io, agent.asAgent());
    defer ui_server.deinit();
    var url_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer url_arena_state.deinit();
    const api_url = try ui_server.url(url_arena_state.allocator());

    var chat_http_client = provider_utils.HttpClientTransport.init(allocator, io);
    defer chat_http_client.deinit();
    var default_transport = ai.ui.DefaultChatTransport.init(.{
        .transport = chat_http_client.transport(),
        .api = api_url,
    });
    const chat_state = try ai.ui.MemoryChatState.create(allocator, &.{});
    defer chat_state.deinit();
    const chat = try ai.ui.Chat.create(io, allocator, .{
        .id = "ui-chat",
        .state = chat_state.asState(),
        .transport = default_transport.asTransport(),
    });
    defer chat.deinit();

    try chat.sendMessage(.{ .text = "What is the weather in Paris?" }, .{});
    ui_server.stop();
    if (ui_server.serve_error) |err| return err;

    try std.testing.expectEqual(ai.ui.ChatStatus.ready, chat.status());
    try std.testing.expectEqual(2, chat_state.message_list.items.len);
    const assistant = chat_state.message_list.items[1];
    try std.testing.expectEqual(ai.ui.messages.Role.assistant, assistant.role);
    try std.testing.expectEqual(4, assistant.parts.len);
    try std.testing.expect(assistant.parts[0] == .step_start);
    try std.testing.expect(assistant.parts[1] == .tool);
    try std.testing.expect(assistant.parts[1].tool.state == .output_available);
    try std.testing.expectEqualStrings(
        "Paris",
        assistant.parts[1].tool.state.output_available.input.object.get("city").?.string,
    );
    try std.testing.expectEqualStrings(
        "sunny",
        assistant.parts[1].tool.state.output_available.output.object.get("condition").?.string,
    );
    try std.testing.expect(assistant.parts[2] == .step_start);
    try std.testing.expect(assistant.parts[3] == .text);
    try std.testing.expectEqual(ai.ui.messages.PartState.done, assistant.parts[3].text.state.?);
    try std.testing.expectEqualStrings("Paris is sunny and 21 C.", assistant.parts[3].text.text);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expectEqual(2, provider_server.recordedRequests().len);
    try std.testing.expectEqual(0, provider_server.serveErrorCount());
}

test "live Phase 7 Anthropic generateObject and streamObject smoke" {
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
        std.debug.print("live Phase 7 object smoke skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "ANTHROPIC_API_KEY") orelse {
        std.debug.print("live Phase 7 object smoke skipped: API key absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key,
        .transport = client.transport(),
    });
    const model_id = "claude-haiku-4-5-20251001";
    var generate_model = try factory.messages(model_id, null);
    const Shape = struct { answer: []const u8 };
    var generated = try ai.generateObject(io, allocator, .{
        .model = .{ .model = generate_model.languageModel() },
        .prompt = .{ .text = "Return an object whose answer is exactly ok." },
        .schema = provider_utils.schemaFromType(Shape),
        .max_output_tokens = 64,
    });
    defer generated.deinit();
    try std.testing.expectEqualStrings("ok", generated.object.object.get("answer").?.string);

    var stream_model = try factory.messages(model_id, null);
    var streamed = try ai.streamObject(io, allocator, .{
        .model = .{ .model = stream_model.languageModel() },
        .prompt = .{ .text = "Return an object whose answer is exactly ok." },
        .schema = provider_utils.schemaFromType(Shape),
        .max_output_tokens = 64,
    });
    defer streamed.deinit(io);
    var partials = streamed.partialObjectStream();
    var partial_count: usize = 0;
    while (try partials.next(io)) |_| partial_count += 1;
    const final_object = try streamed.object(io);
    try std.testing.expectEqualStrings("ok", final_object.object.get("answer").?.string);
    try std.testing.expect(partial_count > 0);
    std.debug.print(
        "live Phase 7 objects: model={s} generate=ok stream=ok partials={d}\n",
        .{ model_id, partial_count },
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

test "live Anthropic streamText two-step tool loop" {
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
        std.debug.print("live Anthropic streamText tool loop skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "ANTHROPIC_API_KEY") orelse {
        std.debug.print("live Anthropic streamText tool loop skipped: API key absent\n", .{});
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
    var result = try ai.streamText(io, allocator, .{
        .model = .{ .model = chat.languageModel() },
        .instructions = .{ .text = "Call the weather tool exactly once for the requested city. After the tool result, answer in one short sentence and do not call any more tools." },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.loopFinished()},
        .max_output_tokens = 200,
    });
    defer result.deinit(io);

    var part_count: usize = 0;
    var text_delta_count: usize = 0;
    var tool_call_count: usize = 0;
    var tool_result_count: usize = 0;
    var finish_step_count: usize = 0;
    var finish_count: usize = 0;
    var saw_start = false;
    var saw_finish = false;
    while (try result.next(io)) |part| {
        if (part_count == 0) try std.testing.expect(part == .start);
        try std.testing.expect(!saw_finish);
        part_count += 1;
        switch (part) {
            .start => {
                try std.testing.expect(!saw_start);
                saw_start = true;
            },
            .text_delta => |value| {
                if (value.text.len != 0) text_delta_count += 1;
            },
            .tool_call => tool_call_count += 1,
            .tool_result => |value| if (!value.preliminary) {
                tool_result_count += 1;
            },
            .finish_step => finish_step_count += 1,
            .finish => {
                finish_count += 1;
                saw_finish = true;
            },
            .abort => return error.LiveStreamAborted,
            .err => return error.LiveProviderStreamError,
            else => {},
        }
    }
    const steps = try result.steps(io);
    const final_text = try result.text(io);
    const total_usage = try result.totalUsage(io);
    const total_tokens = (total_usage.input_tokens.total orelse 0) +
        (total_usage.output_tokens.total orelse 0);
    try std.testing.expect(saw_start);
    try std.testing.expect(saw_finish);
    try std.testing.expect(text_delta_count >= 1);
    try std.testing.expect(tool_call_count >= 1);
    try std.testing.expect(tool_result_count >= 1);
    try std.testing.expectEqual(2, finish_step_count);
    try std.testing.expectEqual(1, finish_count);
    try std.testing.expectEqual(2, steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expect(final_text.len > 0);
    try std.testing.expect(total_tokens > 0);
    std.debug.print(
        "live Anthropic streamText tool loop: parts={d} text_deltas={d} tool_calls={d} tool_results={d} finish_steps={d} finishes={d} executions={d} final_text_bytes={d} total_tokens={d}\n",
        .{
            part_count,
            text_delta_count,
            tool_call_count,
            tool_result_count,
            finish_step_count,
            finish_count,
            weather.calls,
            final_text.len,
            total_tokens,
        },
    );
}

test "live native OpenAI Chat generate and stream smoke" {
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
        std.debug.print("live native OpenAI smoke skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "OPENAI_API_KEY") orelse {
        std.debug.print("live native OpenAI smoke skipped: OPENAI_API_KEY is absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = openai.createOpenAi(.{
        .allocator = allocator,
        .api_key = api_key,
        .transport = client.transport(),
    });
    const model_id = "gpt-4o-mini";
    var chat = try factory.chat(model_id, null);
    const prompt = [_]provider.Message{.{ .user = .{
        .content = &.{.{ .text = .{ .text = "Reply with exactly: hello" } }},
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
    var stream_parts: usize = 0;
    var text_deltas: usize = 0;
    var streamed_text_bytes: usize = 0;
    var saw_finish = false;
    while (try streamed.stream.next(io)) |part| {
        stream_parts += 1;
        switch (part) {
            .text_delta => |delta| {
                text_deltas += 1;
                streamed_text_bytes += delta.delta.len;
            },
            .finish => saw_finish = true,
            .err => return error.LiveOpenAiProviderStreamError,
            else => {},
        }
    }
    try std.testing.expect(text_deltas > 0);
    try std.testing.expect(streamed_text_bytes > 0);
    try std.testing.expect(saw_finish);
    std.debug.print(
        "live native OpenAI Chat: model={s} generate_text_bytes={d} stream_parts={d} text_deltas={d} streamed_text_bytes={d}\n",
        .{ model_id, generated_text_bytes, stream_parts, text_deltas, streamed_text_bytes },
    );
}

test "live Phase 10 OpenAI speech to transcription round trip" {
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
        std.debug.print("live Phase 10 OpenAI media round trip skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "OPENAI_API_KEY") orelse {
        std.debug.print("live Phase 10 OpenAI media round trip skipped: OPENAI_API_KEY is absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = openai.createOpenAi(.{
        .allocator = allocator,
        .api_key = api_key,
        .transport = client.transport(),
    });
    const speech_model_id = "gpt-4o-mini-tts";
    const transcription_model_id = "gpt-4o-mini-transcribe";
    var speech_model = try factory.speechModel(speech_model_id, null);
    var speech = try ai.generateSpeech(io, allocator, .{
        .model = .{ .model = speech_model.speechModel() },
        .text = "Phase ten media round trip.",
        .voice = "alloy",
        .output_format = "mp3",
    });
    defer speech.deinit();
    const audio_bytes = try speech.audio.bytes(speech.arena_state.allocator());
    try std.testing.expect(audio_bytes.len > 0);

    var transcription_model = try factory.transcriptionModel(transcription_model_id, null);
    var transcript = try ai.transcribe(io, allocator, .{
        .model = .{ .model = transcription_model.transcriptionModel() },
        .audio = .{ .data = .{ .bytes = audio_bytes } },
    });
    defer transcript.deinit();
    try std.testing.expect(transcript.text.len > 0);
    std.debug.print(
        "live Phase 10 OpenAI media: speech_model={s} transcription_model={s} audio_bytes={d} transcript_bytes={d}\n",
        .{ speech_model_id, transcription_model_id, audio_bytes.len, transcript.text.len },
    );
}

test "live Phase 10 image and video generation skipped for cost" {
    if (!build_options.live) return error.SkipZigTest;
    std.debug.print("live Phase 10 image/video skipped: cost-gated\n", .{});
    return error.SkipZigTest;
}

test "live native OpenAI Responses generate and stream smoke" {
    if (!build_options.live) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const env_path = "/home/autark/src/rctr/.env";
    const env_file = std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, .limited(1024 * 1024)) catch {
        std.debug.print("live OpenAI Responses smoke skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "OPENAI_API_KEY") orelse {
        std.debug.print("live OpenAI Responses smoke skipped: OPENAI_API_KEY is absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var factory = openai.createOpenAi(.{ .allocator = allocator, .api_key = api_key, .transport = client.transport() });
    const model_id = "gpt-4o-mini";
    var responses = try factory.responses(model_id, null);
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "Reply with exactly: hello" } }} } }};
    const options: provider.CallOptions = .{ .prompt = &prompt, .max_output_tokens = 32 };

    var generate_arena = std.heap.ArenaAllocator.init(allocator);
    defer generate_arena.deinit();
    const generated = try responses.languageModel().doGenerate(io, generate_arena.allocator(), &options, null);
    var generated_bytes: usize = 0;
    for (generated.content) |content| switch (content) {
        .text => |part| generated_bytes += part.text.len,
        else => {},
    };
    try std.testing.expect(generated_bytes > 0);

    var stream_arena = std.heap.ArenaAllocator.init(allocator);
    defer stream_arena.deinit();
    const streamed = try responses.languageModel().doStream(io, stream_arena.allocator(), &options, null);
    defer streamed.stream.deinit(io);
    var parts: usize = 0;
    var deltas: usize = 0;
    var streamed_bytes: usize = 0;
    var saw_finish = false;
    while (try streamed.stream.next(io)) |part| {
        parts += 1;
        switch (part) {
            .text_delta => |delta| {
                deltas += 1;
                streamed_bytes += delta.delta.len;
            },
            .finish => saw_finish = true,
            .err => return error.LiveOpenAiResponsesStreamError,
            else => {},
        }
    }
    try std.testing.expect(deltas > 0);
    try std.testing.expect(streamed_bytes > 0);
    try std.testing.expect(saw_finish);
    std.debug.print(
        "live OpenAI Responses: model={s} generate_text_bytes={d} stream_parts={d} text_deltas={d} streamed_text_bytes={d}\n",
        .{ model_id, generated_bytes, parts, deltas, streamed_bytes },
    );
}

test "live ToolLoopAgent executes one OpenAI Responses tool step" {
    if (!build_options.live) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const env_path = "/home/autark/src/rctr/.env";
    const env_file = std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, .limited(1024 * 1024)) catch {
        std.debug.print("live OpenAI Responses agent skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "OPENAI_API_KEY") orelse {
        std.debug.print("live OpenAI Responses agent skipped: OPENAI_API_KEY is absent\n", .{});
        return error.SkipZigTest;
    };

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var factory = openai.createOpenAi(.{ .allocator = allocator, .api_key = api_key, .transport = client.transport() });
    const model_id = "gpt-4o-mini";
    var responses = try factory.responses(model_id, null);
    var weather: LoopWeatherTool = .{};
    const tools = loopWeatherTools(&weather);
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = responses.languageModel() },
        .instructions = .{ .text = "You must call weather exactly once for Paris, then answer briefly using its result." },
        .tools = &tools,
        .max_output_tokens = 96,
    });
    var result = try agent.generate(io, allocator, .{ .prompt = .{ .text = "What is the weather in Paris?" } });
    defer result.deinit();
    try std.testing.expect(result.steps.len >= 2);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(result.text().len > 0);
    std.debug.print(
        "live OpenAI Responses agent: model={s} steps={d} tool_calls={d} final_text_bytes={d}\n",
        .{ model_id, result.steps.len, weather.calls, result.text().len },
    );
}

test "live ToolLoopAgent streams an Anthropic two-step weather loop" {
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
        std.debug.print("live ToolLoopAgent smoke skipped: env file unavailable\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "ANTHROPIC_API_KEY") orelse {
        std.debug.print("live ToolLoopAgent smoke skipped: ANTHROPIC_API_KEY is absent\n", .{});
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
    var agent = ai.ToolLoopAgent.init(.{
        .model = .{ .model = chat.languageModel() },
        .instructions = .{ .text = "Call the weather tool exactly once for the requested city. After the tool result, answer in one short sentence and do not call any more tools." },
        .tools = &tools,
        .max_output_tokens = 200,
    });
    var result = try agent.stream(io, allocator, .{
        .prompt = .{ .text = "What is the weather in Paris?" },
    });
    defer result.deinit(io);

    var parts: usize = 0;
    var text_deltas: usize = 0;
    var tool_calls: usize = 0;
    var tool_results: usize = 0;
    var finish_steps: usize = 0;
    var finishes: usize = 0;
    while (try result.next(io)) |part| {
        parts += 1;
        switch (part) {
            .text_delta => |value| if (value.text.len != 0) {
                text_deltas += 1;
            },
            .tool_call => tool_calls += 1,
            .tool_result => |value| if (!value.preliminary) {
                tool_results += 1;
            },
            .finish_step => finish_steps += 1,
            .finish => finishes += 1,
            .abort => return error.LiveAgentStreamAborted,
            .err => return error.LiveAgentProviderStreamError,
            else => {},
        }
    }
    const steps = try result.steps(io);
    const final_text = try result.text(io);
    const usage = try result.totalUsage(io);
    const total_tokens = (usage.input_tokens.total orelse 0) +
        (usage.output_tokens.total orelse 0);
    try std.testing.expectEqual(2, steps.len);
    try std.testing.expectEqual(1, weather.calls);
    try std.testing.expect(weather.saw_city);
    try std.testing.expect(tool_calls >= 1);
    try std.testing.expect(tool_results >= 1);
    try std.testing.expect(text_deltas >= 1);
    try std.testing.expectEqual(2, finish_steps);
    try std.testing.expectEqual(1, finishes);
    try std.testing.expect(final_text.len > 0);
    try std.testing.expect(total_tokens > 0);
    std.debug.print(
        "live ToolLoopAgent Anthropic: model={s} parts={d} text_deltas={d} tool_calls={d} tool_results={d} finish_steps={d} executions={d} final_text_bytes={d} total_tokens={d}\n",
        .{
            model_id,
            parts,
            text_deltas,
            tool_calls,
            tool_results,
            finish_steps,
            weather.calls,
            final_text.len,
            total_tokens,
        },
    );
}

const RealtimeDummyHttp = struct {
    fn request(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: provider_utils.RequestSpec,
        _: ?*provider.Diagnostics,
    ) provider_utils.RequestError!provider_utils.Response {
        return error.APICallError;
    }
};

fn dummyHttpTransport(marker: *u8) provider_utils.HttpTransport {
    return .{ .ctx = marker, .vtable = &.{ .request = RealtimeDummyHttp.request } };
}

const ScriptRealtimeModel = struct {
    inner: provider.RealtimeModel,
    url: []const u8,

    fn model(self: *ScriptRealtimeModel) provider.RealtimeModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.RealtimeModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .doCreateClientSecret = createSecret,
        .getWebSocketConfig = websocketConfig,
        .parseServerEvent = parseServerEvent,
        .serializeClientEvent = serializeClientEvent,
        .buildSessionConfig = buildSessionConfig,
        .getHealthCheckResponse = healthCheck,
    };
    fn fromRaw(raw: *anyopaque) *ScriptRealtimeModel {
        return @ptrCast(@alignCast(raw));
    }
    fn providerName(raw: *anyopaque) []const u8 {
        return fromRaw(raw).inner.provider();
    }
    fn modelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).inner.modelId();
    }
    fn createSecret(
        raw: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: *const provider.ClientSecretOptions,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.ClientSecretResult {
        return .{ .token = "script-token", .url = fromRaw(raw).url };
    }
    fn websocketConfig(
        _: *anyopaque,
        _: std.mem.Allocator,
        options: *const provider.WebSocketOptions,
        _: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!provider.WebSocketConfig {
        return .{ .url = options.url, .protocols = &.{"realtime"} };
    }
    fn parseServerEvent(
        raw: *anyopaque,
        arena: std.mem.Allocator,
        value: *const std.json.Value,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError![]const provider.ServerEvent {
        return fromRaw(raw).inner.parseServerEvent(arena, value, diag);
    }
    fn serializeClientEvent(
        raw: *anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        event: *const provider.ClientEvent,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!std.json.Value {
        return fromRaw(raw).inner.serializeClientEvent(io, arena, event, diag);
    }
    fn buildSessionConfig(
        raw: *anyopaque,
        arena: std.mem.Allocator,
        config: *const provider.SessionConfig,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!std.json.Value {
        return fromRaw(raw).inner.buildSessionConfig(arena, config, diag);
    }
    fn healthCheck(
        raw: *anyopaque,
        arena: std.mem.Allocator,
        value: *const std.json.Value,
        diag: ?*provider.Diagnostics,
    ) provider.realtime_model.CallError!?std.json.Value {
        return fromRaw(raw).inner.getHealthCheckResponse(arena, value, diag);
    }
};

const RealtimeScript = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    saw_session_update: bool = false,
    saw_text_item: bool = false,
    saw_tool_output: bool = false,
    saw_followup_response: bool = false,

    fn run(
        raw: ?*anyopaque,
        _: std.Io,
        socket: *std.http.Server.WebSocket,
        _: *std.http.Server.Request,
    ) anyerror!void {
        const self: *RealtimeScript = @ptrCast(@alignCast(raw.?));
        const first = try test_support.websocket_server.readText(socket);
        self.record(&self.saw_session_update, std.mem.indexOf(u8, first, "\"type\":\"session.update\"") != null);
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"session.created\",\"session\":{\"id\":\"session-1\"}}");

        const item = try test_support.websocket_server.readText(socket);
        self.record(&self.saw_text_item, std.mem.indexOf(u8, item, "conversation.item.create") != null and std.mem.indexOf(u8, item, "hello realtime") != null);
        const response = try test_support.websocket_server.readText(socket);
        if (std.mem.indexOf(u8, response, "response.create") == null) return error.MissingResponseCreate;

        try test_support.websocket_server.sendJson(socket, "{\"type\":\"response.output_text.delta\",\"response_id\":\"r1\",\"item_id\":\"i1\",\"delta\":\"Hello\"}");
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"response.output_text.done\",\"response_id\":\"r1\",\"item_id\":\"i1\",\"text\":\"Hello realtime\"}");
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"response.function_call_arguments.delta\",\"response_id\":\"r1\",\"item_id\":\"tool-item\",\"call_id\":\"call-1\",\"delta\":\"{}\"}");
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"response.function_call_arguments.done\",\"response_id\":\"r1\",\"item_id\":\"tool-item\",\"call_id\":\"call-1\",\"name\":\"echo\",\"arguments\":\"{}\"}");
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"response.done\",\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}");

        const output = try test_support.websocket_server.readText(socket);
        self.record(&self.saw_tool_output, std.mem.indexOf(u8, output, "function_call_output") != null and std.mem.indexOf(u8, output, "call-1") != null);
        const followup = try test_support.websocket_server.readText(socket);
        self.record(&self.saw_followup_response, std.mem.indexOf(u8, followup, "response.create") != null);
        try test_support.websocket_server.closeNormallyAndAwaitEcho(socket);
    }

    fn record(self: *RealtimeScript, field: *bool, value: bool) void {
        self.mutex.lockUncancelable(self.io);
        field.* = value;
        self.mutex.unlock(self.io);
    }
};

const RealtimeUiRecorder = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    connected: bool = false,
    text: [128]u8 = undefined,
    text_len: usize = 0,
    tool_calls: usize = 0,

    fn callbacks(self: *RealtimeUiRecorder) ai.realtime.session.StateCallbacks {
        return .{
            .ctx = self,
            .on_status = status,
            .on_messages = messages,
        };
    }
    fn status(raw: ?*anyopaque, value: ai.realtime.RealtimeStatus) void {
        const self: *RealtimeUiRecorder = @ptrCast(@alignCast(raw.?));
        self.mutex.lockUncancelable(self.io);
        self.connected = value == .connected;
        self.mutex.unlock(self.io);
    }
    fn messages(raw: ?*anyopaque, values: []const ai.UIMessage) void {
        const self: *RealtimeUiRecorder = @ptrCast(@alignCast(raw.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (values) |message| for (message.parts) |part| switch (part) {
            .text => |text| {
                self.text_len = @min(text.text.len, self.text.len);
                @memcpy(self.text[0..self.text_len], text.text[0..self.text_len]);
            },
            .dynamic_tool => self.tool_calls += 1,
            else => {},
        };
    }
};

fn autoRealtimeTool(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    _: ai.realtime.session.ToolCall,
) anyerror!?std.json.Value {
    return .{ .string = "tool-ok" };
}

test "integration realtime session speaks OpenAI JSON over std WebSocket" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script: RealtimeScript = .{ .io = io };
    const server = try test_support.WebSocketScriptServer.start(allocator, io, .{
        .ctx = &script,
        .run_fn = RealtimeScript.run,
    });
    defer server.deinit();
    var url_buffer: [128]u8 = undefined;
    const url = server.url(&url_buffer, "/v1/realtime?model=gpt-realtime");

    var http_marker: u8 = 0;
    var factory = openai.createOpenAi(.{
        .allocator = allocator,
        .api_key = "unused",
        .transport = dummyHttpTransport(&http_marker),
    });
    var concrete = try factory.realtimeModel("gpt-realtime", null);
    var scripted_model: ScriptRealtimeModel = .{ .inner = concrete.realtimeModel(), .url = url };
    var recorder: RealtimeUiRecorder = .{ .io = io };
    const session = try ai.RealtimeSession.init(allocator, io, .{
        .model = scripted_model.model(),
        .session_config = .{ .output_modalities = &.{.text} },
        .state_callbacks = recorder.callbacks(),
        .on_tool_call = .{ .call = autoRealtimeTool },
    });
    defer session.dispose();

    try session.connect();
    try session.sendTextMessage("hello realtime");
    try server.wait();

    script.mutex.lockUncancelable(io);
    defer script.mutex.unlock(io);
    try std.testing.expect(script.saw_session_update);
    try std.testing.expect(script.saw_text_item);
    try std.testing.expect(script.saw_tool_output);
    try std.testing.expect(script.saw_followup_response);
    recorder.mutex.lockUncancelable(io);
    defer recorder.mutex.unlock(io);
    try std.testing.expectEqualStrings("Hello realtime", recorder.text[0..recorder.text_len]);
    try std.testing.expect(recorder.tool_calls >= 1);
}

const TranscriptionScript = struct {
    append_count: usize = 0,
    saw_session: bool = false,

    fn run(
        raw: ?*anyopaque,
        _: std.Io,
        socket: *std.http.Server.WebSocket,
        _: *std.http.Server.Request,
    ) anyerror!void {
        const self: *TranscriptionScript = @ptrCast(@alignCast(raw.?));
        const session = try test_support.websocket_server.readText(socket);
        self.saw_session = std.mem.indexOf(u8, session, "\"type\":\"session.update\"") != null and
            std.mem.indexOf(u8, session, "gpt-realtime-whisper") != null;
        while (true) {
            const message = try test_support.websocket_server.readText(socket);
            if (std.mem.indexOf(u8, message, "input_audio_buffer.append") != null) {
                self.append_count += 1;
                continue;
            }
            if (std.mem.indexOf(u8, message, "input_audio_buffer.commit") != null) break;
        }
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"item_id\":\"item-1\",\"delta\":\"Hel\"}");
        try test_support.websocket_server.sendJson(socket, "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-1\",\"transcript\":\"Hello\"}");
        _ = socket.readSmallMessage() catch |err| {
            if (err != error.ConnectionClose) return err;
        };
        try test_support.websocket_server.closeNormally(socket);
    }
};

const IntegrationAudioStream = struct {
    chunks: []const provider.BinaryData,
    index: usize = 0,
    deinitialized: bool = false,

    fn stream(self: *IntegrationAudioStream) provider.transcription_model.AudioStream {
        return .{ .ctx = self, .vtable = &.{ .next = next, .deinit = deinit } };
    }
    fn next(raw: *anyopaque, _: std.Io) provider.transcription_model.NextError!?provider.BinaryData {
        const self: *IntegrationAudioStream = @ptrCast(@alignCast(raw));
        if (self.index == self.chunks.len) return null;
        defer self.index += 1;
        return self.chunks[self.index];
    }
    fn deinit(raw: *anyopaque, _: std.Io) void {
        const self: *IntegrationAudioStream = @ptrCast(@alignCast(raw));
        self.deinitialized = true;
    }
};

test "integration streamTranscribe uses OpenAI realtime WebSocket" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script: TranscriptionScript = .{};
    const server = try test_support.WebSocketScriptServer.start(allocator, io, .{
        .ctx = &script,
        .run_fn = TranscriptionScript.run,
    });
    defer server.deinit();
    var base_buffer: [96]u8 = undefined;
    const ws_url = server.url(&base_buffer, "");
    const http_base = try std.fmt.allocPrint(allocator, "http://{s}", .{ws_url["ws://".len..]});
    defer allocator.free(http_base);

    var http_marker: u8 = 0;
    var factory = openai.createOpenAi(.{
        .allocator = allocator,
        .base_url = http_base,
        .api_key = "test-api-key",
        .transport = dummyHttpTransport(&http_marker),
    });
    var concrete = try factory.transcriptionModel("gpt-realtime-whisper", null);
    const chunks = [_]provider.BinaryData{
        .{ .bytes = &.{ 1, 2, 3 } },
        .{ .base64 = "BAUG" },
    };
    var audio_stream: IntegrationAudioStream = .{ .chunks = &chunks };
    var result = try ai.streamTranscribe(io, allocator, .{
        .model = .{ .model = concrete.transcriptionModel() },
        .audio = audio_stream.stream(),
        .input_audio_format = .{ .type = "audio/pcm", .rate = 24_000 },
    });
    defer result.deinit(io);
    var full = result.fullStream();
    try std.testing.expectEqualStrings("Hel", (try full.next(io)).?.transcript_delta.delta);
    try std.testing.expectEqualStrings("Hello", (try full.next(io)).?.transcript_final.text);
    try std.testing.expectEqual(null, try full.next(io));
    try std.testing.expectEqualStrings("Hello", try result.text(io));
    try server.wait();
    try std.testing.expect(script.saw_session);
    try std.testing.expectEqual(2, script.append_count);
}

const LiveRealtimeRecorder = struct {
    io: std.Io,
    connected: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    text_deltas: std.atomic.Value(usize) = .init(0),
    response_done: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    last_error: ?anyerror = null,

    fn stateCallbacks(self: *LiveRealtimeRecorder) ai.realtime.session.StateCallbacks {
        return .{ .ctx = self, .on_status = status };
    }
    fn status(raw: ?*anyopaque, value: ai.realtime.RealtimeStatus) void {
        const self: *LiveRealtimeRecorder = @ptrCast(@alignCast(raw.?));
        if (value == .connected) self.connected.set(self.io);
    }
    fn event(raw: ?*anyopaque, value: provider.ServerEvent) void {
        const self: *LiveRealtimeRecorder = @ptrCast(@alignCast(raw.?));
        switch (value) {
            .text_delta => _ = self.text_deltas.fetchAdd(1, .monotonic),
            .response_done => {
                self.response_done.store(true, .release);
                self.done.set(self.io);
            },
            .err => {
                self.setError(error.APICallError);
                self.done.set(self.io);
            },
            else => {},
        }
    }
    fn onError(raw: ?*anyopaque, info: ai.realtime.session.ErrorInfo) void {
        const self: *LiveRealtimeRecorder = @ptrCast(@alignCast(raw.?));
        self.setError(info.err);
        self.done.set(self.io);
    }
    fn setError(self: *LiveRealtimeRecorder, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        self.last_error = err;
        self.mutex.unlock(self.io);
    }
    fn getError(self: *LiveRealtimeRecorder) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.last_error;
    }
};

test "live OpenAI realtime text smoke" {
    if (!build_options.live) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const env_file = std.Io.Dir.cwd().readFileAlloc(
        io,
        "/home/autark/src/rctr/.env",
        allocator,
        .limited(1024 * 1024),
    ) catch return error.SkipZigTest;
    defer allocator.free(env_file);
    const api_key = exportEnvValue(env_file, "OPENAI_API_KEY") orelse return error.SkipZigTest;

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var factory = openai.createOpenAi(.{
        .allocator = allocator,
        .api_key = api_key,
        .transport = client.transport(),
    });
    const model_id = "gpt-realtime";
    var model = try factory.realtimeModel(model_id, null);
    var recorder: LiveRealtimeRecorder = .{ .io = io };
    const session = try ai.RealtimeSession.init(allocator, io, .{
        .model = model.realtimeModel(),
        .session_config = .{ .output_modalities = &.{.text} },
        .state_callbacks = recorder.stateCallbacks(),
        .on_event = .{ .ctx = &recorder, .call = LiveRealtimeRecorder.event },
        .on_error = .{ .ctx = &recorder, .call = LiveRealtimeRecorder.onError },
    });
    defer session.dispose();
    try session.connect();
    try recorder.connected.waitTimeout(io, .{ .duration = .{
        .raw = .fromSeconds(30),
        .clock = .awake,
    } });
    try session.sendTextMessage("Reply with exactly: hello");
    try recorder.done.waitTimeout(io, .{ .duration = .{
        .raw = .fromSeconds(45),
        .clock = .awake,
    } });
    if (recorder.getError()) |err| return err;
    try std.testing.expect(recorder.text_deltas.load(.acquire) >= 1);
    try std.testing.expect(recorder.response_done.load(.acquire));
    std.debug.print("live OpenAI realtime: model={s} text_deltas={d} response_done=true\n", .{
        model_id,
        recorder.text_deltas.load(.acquire),
    });
}
