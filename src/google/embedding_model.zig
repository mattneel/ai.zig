const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");
const options_api = @import("options.zig");

const Allocator = std.mem.Allocator;

pub const GoogleEmbeddingModel = struct {
    model_id: []const u8,
    config: config_api.Config,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!GoogleEmbeddingModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "Google embedding model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "Google provider name is required");
        return .{ .model_id = model_id, .config = config };
    }

    pub fn embeddingModel(self: *GoogleEmbeddingModel) provider.EmbeddingModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.EmbeddingModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .maxEmbeddingsPerCall = vMaxEmbeddingsPerCall,
        .supportsParallelCalls = vSupportsParallelCalls,
        .doEmbed = vDoEmbed,
    };

    fn fromRaw(raw: *anyopaque) *GoogleEmbeddingModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        return fromRaw(raw).config.provider_name;
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vMaxEmbeddingsPerCall(_: *anyopaque, _: std.Io) ?u32 {
        return 100;
    }

    fn vSupportsParallelCalls(_: *anyopaque, _: std.Io) bool {
        return true;
    }

    fn vDoEmbed(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.EmbeddingCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError!provider.EmbeddingResult {
        return fromRaw(raw).doEmbed(io, arena, call_options, diag);
    }

    fn doEmbed(
        self: *GoogleEmbeddingModel,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.EmbeddingCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError!provider.EmbeddingResult {
        if (call_options.values.len > 100) return tooManyValues(arena, self, call_options.values, diag);
        const google_options = try options_api.parseEmbedding(arena, call_options.provider_options, diag);
        const multimodal = if (google_options.content) |value| value.array.items else null;
        if (multimodal) |entries| if (entries.len != call_options.values.len) {
            const message = try std.fmt.allocPrint(
                arena,
                "The number of multimodal content entries ({d}) must match the number of values ({d}).",
                .{ entries.len, call_options.values.len },
            );
            return invalidArgument(diag, "providerOptions.google.content", message);
        };

        const model_name = try std.fmt.allocPrint(arena, "models/{s}", .{self.model_id});
        var body: std.json.ObjectMap = .empty;
        const single = call_options.values.len == 1;
        if (single) {
            try putString(&body, arena, "model", model_name);
            try body.put(arena, "content", try embeddingContent(
                arena,
                call_options.values[0],
                if (multimodal) |entries| entries[0] else null,
                false,
            ));
            try addEmbeddingOptions(arena, &body, google_options);
        } else {
            var requests = std.json.Array.init(arena);
            for (call_options.values, 0..) |value, index| {
                var request: std.json.ObjectMap = .empty;
                try putString(&request, arena, "model", model_name);
                try request.put(arena, "content", try embeddingContent(
                    arena,
                    value,
                    if (multimodal) |entries| entries[index] else null,
                    true,
                ));
                try addEmbeddingOptions(arena, &request, google_options);
                try requests.append(.{ .object = request });
            }
            try body.put(arena, "requests", .{ .array = requests });
        }

        const body_value: std.json.Value = .{ .object = body };
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, body_value);
        const operation = if (single) "embedContent" else "batchEmbedContents";
        const url = try std.fmt.allocPrint(arena, "{s}/models/{s}:{s}", .{ self.config.base_url, self.model_id, operation });
        const headers = try config_api.resolveHeaders(self.config, arena, call_options.headers, diag);
        const result = try provider_utils.postJsonToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );
        return mapResponse(arena, result.value, result.response_headers, single, diag);
    }
};

fn embeddingContent(
    arena: Allocator,
    value: []const u8,
    multimodal: ?std.json.Value,
    include_role: bool,
) Allocator.Error!std.json.Value {
    var parts = std.json.Array.init(arena);
    const has_multimodal = multimodal != null and multimodal.? != .null;
    if (value.len != 0 or !has_multimodal) {
        var text: std.json.ObjectMap = .empty;
        try putString(&text, arena, "text", value);
        try parts.append(.{ .object = text });
    }
    if (has_multimodal) for (multimodal.?.array.items) |part| {
        try parts.append(try provider_utils.cloneJsonValue(arena, part));
    };
    var content: std.json.ObjectMap = .empty;
    if (include_role) try putString(&content, arena, "role", "user");
    try content.put(arena, "parts", .{ .array = parts });
    return .{ .object = content };
}

fn addEmbeddingOptions(
    arena: Allocator,
    body: *std.json.ObjectMap,
    options: options_api.EmbeddingOptions,
) Allocator.Error!void {
    if (options.output_dimensionality) |value| try body.put(arena, "outputDimensionality", try provider_utils.cloneJsonValue(arena, value));
    if (options.task_type) |value| try putString(body, arena, "taskType", value);
}

fn mapResponse(
    arena: Allocator,
    response: std.json.Value,
    response_headers: []const provider.Header,
    single: bool,
    diag: ?*provider.Diagnostics,
) provider.embedding_model.CallError!provider.EmbeddingResult {
    if (response != .object) return invalidResponse(arena, diag, "Google embedding response must be an object");
    const items = if (single) blk: {
        const embedding = response.object.get("embedding") orelse return invalidResponse(arena, diag, "Google embedding response is missing embedding");
        var array = std.json.Array.init(arena);
        try array.append(embedding);
        break :blk array;
    } else blk: {
        const embeddings = response.object.get("embeddings") orelse return invalidResponse(arena, diag, "Google embedding response is missing embeddings");
        if (embeddings != .array) return invalidResponse(arena, diag, "Google embeddings must be an array");
        break :blk embeddings.array;
    };

    const output = try arena.alloc([]const f64, items.items.len);
    for (items.items, output) |item, *destination| {
        if (item != .object) return invalidResponse(arena, diag, "Google embedding item must be an object");
        const values = item.object.get("values") orelse return invalidResponse(arena, diag, "Google embedding values are missing");
        if (values != .array) return invalidResponse(arena, diag, "Google embedding values must be an array");
        const vector = try arena.alloc(f64, values.array.items.len);
        for (values.array.items, vector) |coordinate, *number| number.* = switch (coordinate) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => return invalidResponse(arena, diag, "Google embedding coordinate must be numeric"),
        };
        destination.* = vector;
    }
    return .{
        .embeddings = output,
        .response = .{ .headers = response_headers, .body = response },
        .warnings = &.{},
    };
}

fn tooManyValues(
    arena: Allocator,
    self: *const GoogleEmbeddingModel,
    values: []const []const u8,
    diag: ?*provider.Diagnostics,
) provider.embedding_model.CallError {
    var json_values = std.json.Array.init(arena);
    for (values) |value| json_values.append(.{ .string = value }) catch return error.OutOfMemory;
    const values_json = provider_utils.stringifyJsonValueAlloc(arena, .{ .array = json_values }) catch return error.OutOfMemory;
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .too_many_embedding_values_for_call = .{
            .message = "Too many values for a single Google embedding call",
            .provider = self.config.provider_name,
            .model_id = self.model_id,
            .max_embeddings_per_call = 100,
            .values_json = values_json,
        },
    });
    return error.TooManyEmbeddingValuesForCallError;
}

fn invalidResponse(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
}

fn invalidArgument(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

fn testConfig(allocator: Allocator, base_url: []const u8, transport: provider_utils.HttpTransport) config_api.Config {
    return .{
        .allocator = allocator,
        .base_url = base_url,
        .api_key = "test-api-key",
        .env = .empty,
        .headers = .{ .static = &.{.{ .name = "x-provider", .value = "provider-value" }} },
        .transport = transport,
        .provider_name = "google.generative-ai",
        .provider_options_name = "google",
    };
}

test "Google embeddings use single embedContent and expose raw response" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "test-header", .value = "test-value" }},
        .body = .{ .text = "{\"embedding\":{\"values\":[0.1,0.2,0.3]}}" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleEmbeddingModel.init("gemini-embedding-001", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"google\":{\"outputDimensionality\":64,\"taskType\":\"SEMANTIC_SIMILARITY\"}}", .{});
    const call_headers = [_]provider.Header{.{ .name = "x-request", .value = "request-value" }};
    const result = try model.embeddingModel().doEmbed(io, arena, &.{
        .values = &.{"sunny day"},
        .provider_options = options,
        .headers = &call_headers,
    }, null);
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.2, 0.3 }, result.embeddings[0]);
    try std.testing.expectEqualStrings("test-value", recordedHeader(result.response.?.headers.?, "test-header").?);
    const request = server.recordedRequests()[0];
    try std.testing.expectEqualStrings("/models/gemini-embedding-001:embedContent", request.target);
    try std.testing.expectEqualStrings("test-api-key", recordedHeader(request.headers, "x-goog-api-key").?);
    try std.testing.expectEqualStrings("provider-value", recordedHeader(request.headers, "x-provider").?);
    try std.testing.expectEqualStrings("request-value", recordedHeader(request.headers, "x-request").?);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, request.body, .{});
    try std.testing.expectEqual(64, body.object.get("outputDimensionality").?.integer);
    try std.testing.expectEqualStrings("SEMANTIC_SIMILARITY", body.object.get("taskType").?.string);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google embeddings use batchEmbedContents with per-value requests and native limit" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"embeddings\":[{\"values\":[0.1,0.2]},{\"values\":[0.3,0.4]}]}" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleEmbeddingModel.init("gemini-embedding-001", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    const erased = model.embeddingModel();
    try std.testing.expectEqual(100, erased.maxEmbeddingsPerCall(io).?);
    try std.testing.expect(erased.supportsParallelCalls(io));
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try erased.doEmbed(io, arena_state.allocator(), &.{ .values = &.{ "sunny", "rainy" } }, null);
    try std.testing.expectEqual(2, result.embeddings.len);
    const request = server.recordedRequests()[0];
    try std.testing.expectEqualStrings("/models/gemini-embedding-001:batchEmbedContents", request.target);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), request.body, .{});
    try std.testing.expectEqual(2, body.object.get("requests").?.array.items.len);
    try std.testing.expectEqualStrings("user", body.object.get("requests").?.array.items[0].object.get("content").?.object.get("role").?.string);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google embeddings merge multimodal content and enforce content cardinality" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = "{\"embeddings\":[{\"values\":[0.1]},{\"values\":[0.2]}]}" },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try GoogleEmbeddingModel.init("gemini-embedding-2-preview", testConfig(allocator, server.baseUrl(&base_buffer), client.transport()), null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"google":{"content":[[{"inlineData":{"mimeType":"image/png","data":"img1"}}],[{"fileData":{"fileUri":"gs://bucket/video.mp4","mimeType":"video/mp4"}}]]}}
    , .{});
    _ = try model.embeddingModel().doEmbed(io, arena, &.{ .values = &.{ "sunny", "rainy" }, .provider_options = options }, null);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, server.recordedRequests()[0].body, .{});
    const requests = body.object.get("requests").?.array.items;
    try std.testing.expect(requests[0].object.get("content").?.object.get("parts").?.array.items[1].object.get("inlineData") != null);
    try std.testing.expect(requests[1].object.get("content").?.object.get("parts").?.array.items[1].object.get("fileData") != null);

    const mismatch = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"google":{"content":[[{"text":"extra"}]]}}
    , .{});
    try std.testing.expectError(error.InvalidArgumentError, model.embeddingModel().doEmbed(io, arena, &.{ .values = &.{ "one", "two" }, .provider_options = mismatch }, null));
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "Google embeddings reject more than 100 values with diagnostics" {
    var marker: u8 = 0;
    const Dummy = struct {
        fn request(_: *anyopaque, _: std.Io, _: Allocator, _: provider_utils.RequestSpec, _: ?*provider.Diagnostics) provider_utils.RequestError!provider_utils.Response {
            return error.APICallError;
        }
    };
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var model = try GoogleEmbeddingModel.init("gemini-embedding-001", testConfig(std.testing.allocator, "https://example.test", transport), null);
    var values: [101][]const u8 = @splat("test");
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.TooManyEmbeddingValuesForCallError, model.embeddingModel().doEmbed(std.testing.io, arena_state.allocator(), &.{ .values = &values }, &diagnostics));
    try std.testing.expectEqual(100, diagnostics.payload.too_many_embedding_values_for_call.max_embeddings_per_call);
}
