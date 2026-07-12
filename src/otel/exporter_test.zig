const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const test_support = @import("test_support");
const exporter_api = @import("exporter.zig");

const Allocator = std.mem.Allocator;

const ScriptedModel = struct {
    actions: []const provider.GenerateResult,
    call_count: usize = 0,

    fn model(self: *ScriptedModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn providerName(_: *anyopaque) []const u8 {
        return "openai.chat";
    }

    fn modelId(_: *anyopaque) []const u8 {
        return "gpt-test";
    }

    fn urlSupported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn doGenerate(
        raw: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const self: *ScriptedModel = @ptrCast(@alignCast(raw));
        const index = self.call_count;
        self.call_count += 1;
        return self.actions[@min(index, self.actions.len - 1)];
    }

    fn doStream(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return error.UnsupportedFunctionalityError;
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .urlIsSupported = urlSupported,
        .doGenerate = doGenerate,
        .doStream = doStream,
    };
};

const WeatherTool = struct {
    calls: usize = 0,

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        arena: Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        const self: *WeatherTool = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqualStrings("Paris", input.object.get("city").?.string);
        var result: std.json.ObjectMap = .empty;
        try result.put(arena, "temperature", .{ .integer = 21 });
        return .{ .value = .{ .object = result } };
    }
};

fn generated(
    content: []const provider.Content,
    finish_reason: provider.FinishReasonUnified,
    input_tokens: u64,
    output_tokens: u64,
) provider.GenerateResult {
    return .{
        .content = content,
        .finish_reason = .{ .unified = finish_reason, .raw = @tagName(finish_reason) },
        .usage = .{
            .input_tokens = .{ .total = input_tokens },
            .output_tokens = .{ .total = output_tokens },
        },
        .warnings = &.{},
    };
}

fn runToolLoop(model: provider.LanguageModel, weather: *WeatherTool) !void {
    const tools = [_]ai.NamedTool{.{
        .name = "weather",
        .tool = .{
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = weather, .execute_fn = WeatherTool.execute },
        },
    }};
    var result = try ai.generateText(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model },
        .prompt = .{ .text = "What is the weather?" },
        .tools = &tools,
        .stop_when = &.{ai.loopFinished()},
        .telemetry = .{ .function_id = "weather-agent" },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("It is 21 C.", result.text());
}

test "registered exporter batches two tool loops into one OTLP request" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    ai.clearTelemetryRegistry();

    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{}" },
    });

    var base_buffer: [64]u8 = undefined;
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(
        &endpoint_buffer,
        "{s}/custom/otel/v1/traces",
        .{server.baseUrl(&base_buffer)},
    );
    var http = provider_utils.HttpClientTransport.init(allocator, io);
    defer http.deinit();
    var exporter = try exporter_api.Exporter.init(allocator, io, .{
        .endpoint = endpoint,
        .headers = &.{.{ .name = "x-otel-test", .value = "passthrough" }},
        .service_name = "ai-zig-tests",
        .max_batch_size = 64,
        .transport = http.transport(),
    });
    defer exporter.deinit() catch unreachable;
    defer ai.clearTelemetryRegistry();
    var registration = try exporter_api.register(&exporter);
    defer registration.deinit() catch unreachable;

    const first_tool_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "weather-1",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const first_text_content = [_]provider.Content{.{ .text = .{ .text = "It is 21 C." } }};
    const second_tool_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "weather-2",
        .tool_name = "weather",
        .input = "{\"city\":\"Paris\"}",
    } }};
    const second_text_content = [_]provider.Content{.{ .text = .{ .text = "It is 21 C." } }};
    const actions = [_]provider.GenerateResult{
        generated(&first_tool_content, .tool_calls, 5, 2),
        generated(&first_text_content, .stop, 7, 3),
        generated(&second_tool_content, .tool_calls, 6, 2),
        generated(&second_text_content, .stop, 8, 4),
    };
    var scripted: ScriptedModel = .{ .actions = &actions };
    var weather: WeatherTool = .{};
    try runToolLoop(scripted.model(), &weather);
    try runToolLoop(scripted.model(), &weather);
    try std.testing.expectEqual(2, weather.calls);
    try std.testing.expect(exporter.pendingSpanCount() > 0);

    try exporter.flush();
    try std.testing.expectEqual(0, exporter.pendingSpanCount());
    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqual(.POST, requests[0].method);
    try std.testing.expectEqualStrings("/custom/otel/v1/traces", requests[0].target);
    try std.testing.expectEqualStrings("passthrough", headerValue(requests[0].headers, "x-otel-test").?);
    try std.testing.expectEqualStrings("application/json", headerValue(requests[0].headers, "content-type").?);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, requests[0].body, .{});
    defer parsed.deinit();
    const resource_span = parsed.value.object.get("resourceSpans").?.array.items[0].object;
    const resource_attributes = resource_span.get("resource").?.object.get("attributes").?.array.items;
    try std.testing.expectEqualStrings("ai-zig-tests", attributeValue(resource_attributes, "service.name").?.string);
    const spans = resource_span.get("scopeSpans").?.array.items[0].object.get("spans").?.array.items;
    try std.testing.expectEqual(12, spans.len);
    try std.testing.expectEqual(2, countNamed(spans, "invoke_agent gpt-test"));
    try std.testing.expectEqual(4, countNamed(spans, "chat gpt-test"));
    try std.testing.expectEqual(2, countNamed(spans, "step 1"));
    try std.testing.expectEqual(2, countNamed(spans, "step 2"));
    try std.testing.expectEqual(2, countNamed(spans, "execute_tool weather"));

    const model_span = findNamed(spans, "chat gpt-test").?;
    const model_attributes = model_span.object.get("attributes").?.array.items;
    try std.testing.expectEqualStrings("openai", attributeValue(model_attributes, "gen_ai.system").?.string);
    try std.testing.expectEqualStrings("gpt-test", attributeValue(model_attributes, "gen_ai.request.model").?.string);
    try std.testing.expectEqualStrings("gpt-test", attributeValue(model_attributes, "gen_ai.response.model").?.string);
    try std.testing.expect(attributeValue(model_attributes, "gen_ai.usage.input_tokens") != null);
    try std.testing.expect(attributeValue(model_attributes, "gen_ai.usage.output_tokens") != null);
    const finish_reasons = attributeValue(model_attributes, "gen_ai.response.finish_reasons").?.object
        .get("values").?.array.items;
    try std.testing.expectEqualStrings("tool-calls", finish_reasons[0].object.get("stringValue").?.string);

    for (spans) |span_value| {
        const span = span_value.object;
        const started = try std.fmt.parseInt(u64, span.get("startTimeUnixNano").?.string, 10);
        const ended = try std.fmt.parseInt(u64, span.get("endTimeUnixNano").?.string, 10);
        try std.testing.expect(ended >= started);
        try std.testing.expect(span.get("traceId").?.string.len == 32);
        try std.testing.expect(span.get("spanId").?.string.len == 16);
    }

    for (spans) |span_value| {
        const span = span_value.object;
        const name = span.get("name").?.string;
        const trace_id = span.get("traceId").?.string;
        if (std.mem.eql(u8, name, "invoke_agent gpt-test")) {
            try std.testing.expect(span.get("parentSpanId") == null);
            continue;
        }
        if (std.mem.startsWith(u8, name, "step ")) {
            try std.testing.expect(hasNamedSpanId(
                spans,
                "invoke_agent gpt-test",
                trace_id,
                span.get("parentSpanId").?.string,
            ));
            continue;
        }
        if (std.mem.eql(u8, name, "chat gpt-test")) {
            try std.testing.expect(hasSpanIdWithNamePrefix(
                spans,
                "step ",
                trace_id,
                span.get("parentSpanId").?.string,
            ));
            continue;
        }
        if (!std.mem.eql(u8, name, "execute_tool weather")) continue;
        const parent_id = span.get("parentSpanId").?.string;
        try std.testing.expect(hasNamedSpanId(spans, "chat gpt-test", trace_id, parent_id));
        const attributes = span.get("attributes").?.array.items;
        try std.testing.expectEqualStrings("weather", attributeValue(attributes, "gen_ai.tool.name").?.string);
        try std.testing.expect(attributeValue(attributes, "gen_ai.execute_tool.duration") != null);
    }
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "batch size threshold flushes completed spans without a timer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    ai.clearTelemetryRegistry();

    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    for (0..3) |_| try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{}" },
    });
    var base_buffer: [64]u8 = undefined;
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/v1/traces", .{server.baseUrl(&base_buffer)});
    var http = provider_utils.HttpClientTransport.init(allocator, io);
    defer http.deinit();
    var exporter = try exporter_api.Exporter.init(allocator, io, .{
        .endpoint = endpoint,
        .max_batch_size = 1,
        .transport = http.transport(),
    });
    defer exporter.deinit() catch unreachable;
    defer ai.clearTelemetryRegistry();
    _ = try exporter_api.register(&exporter);

    const content = [_]provider.Content{.{ .text = .{ .text = "done" } }};
    const actions = [_]provider.GenerateResult{generated(&content, .stop, 3, 1)};
    var scripted: ScriptedModel = .{ .actions = &actions };
    var result = try ai.generateText(io, allocator, .{
        .model = .{ .model = scripted.model() },
        .prompt = .{ .text = "go" },
    });
    result.deinit();

    try std.testing.expectEqual(0, exporter.pendingSpanCount());
    try std.testing.expectEqual(3, server.recordedRequests().len);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

fn countNamed(spans: []const std.json.Value, name: []const u8) usize {
    var count: usize = 0;
    for (spans) |span| {
        if (std.mem.eql(u8, span.object.get("name").?.string, name)) count += 1;
    }
    return count;
}

fn findNamed(spans: []const std.json.Value, name: []const u8) ?std.json.Value {
    for (spans) |span| if (std.mem.eql(u8, span.object.get("name").?.string, name)) return span;
    return null;
}

fn hasNamedSpanId(
    spans: []const std.json.Value,
    name: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
) bool {
    for (spans) |span_value| {
        const span = span_value.object;
        if (!std.mem.eql(u8, span.get("name").?.string, name)) continue;
        if (!std.mem.eql(u8, span.get("traceId").?.string, trace_id)) continue;
        if (std.mem.eql(u8, span.get("spanId").?.string, span_id)) return true;
    }
    return false;
}

fn hasSpanIdWithNamePrefix(
    spans: []const std.json.Value,
    name_prefix: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
) bool {
    for (spans) |span_value| {
        const span = span_value.object;
        if (!std.mem.startsWith(u8, span.get("name").?.string, name_prefix)) continue;
        if (!std.mem.eql(u8, span.get("traceId").?.string, trace_id)) continue;
        if (std.mem.eql(u8, span.get("spanId").?.string, span_id)) return true;
    }
    return false;
}

fn attributeValue(attributes: []const std.json.Value, key: []const u8) ?std.json.Value {
    for (attributes) |attribute_value| {
        const attribute = attribute_value.object;
        if (!std.mem.eql(u8, attribute.get("key").?.string, key)) continue;
        const value = attribute.get("value").?.object;
        if (value.get("stringValue")) |item| return item;
        if (value.get("intValue")) |item| return item;
        if (value.get("doubleValue")) |item| return item;
        if (value.get("boolValue")) |item| return item;
        if (value.get("arrayValue")) |item| return item;
    }
    return null;
}
