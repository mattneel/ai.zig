const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");
const options_api = @import("options.zig");

const Allocator = std.mem.Allocator;
const max_provider_id_len = 1024;

pub const EmbeddingModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!EmbeddingModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI embedding model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");
        var result: EmbeddingModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.embedding", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn embeddingModel(self: *EmbeddingModel) provider.EmbeddingModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.EmbeddingModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .maxEmbeddingsPerCall = vMaxEmbeddingsPerCall,
        .supportsParallelCalls = vSupportsParallelCalls,
        .doEmbed = vDoEmbed,
    };

    fn fromRaw(raw: *anyopaque) *EmbeddingModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        return self.provider_id_buffer[0..self.provider_id_len];
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vMaxEmbeddingsPerCall(_: *anyopaque, _: std.Io) ?u32 {
        return 2048;
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
        self: *EmbeddingModel,
        io: std.Io,
        arena: Allocator,
        call_options: *const provider.EmbeddingCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError!provider.EmbeddingResult {
        if (call_options.values.len > 2048) return tooManyValues(arena, self, call_options.values, diag);
        const openai_options = try options_api.parseEmbeddingOptions(
            arena,
            call_options.provider_options,
            self.config.provider_options_name,
            diag,
        );
        var body: std.json.ObjectMap = .empty;
        try putString(&body, arena, "model", self.model_id);
        var input = std.json.Array.init(arena);
        for (call_options.values) |value| try input.append(.{ .string = try arena.dupe(u8, value) });
        try body.put(arena, "input", .{ .array = input });
        try putString(&body, arena, "encoding_format", openai_options.encoding_format);
        if (openai_options.dimensions) |dimensions| {
            if (dimensions > std.math.maxInt(i64)) return invalidArgument(diag, "dimensions", "OpenAI embedding dimensions are too large");
            try body.put(arena, "dimensions", .{ .integer = @intCast(dimensions) });
        }
        if (openai_options.user) |user| try putString(&body, arena, "user", user);
        const body_value: std.json.Value = .{ .object = body };
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, body_value);
        const url = try std.fmt.allocPrint(arena, "{s}/embeddings", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, call_options.headers, diag);
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
        return mapResponse(arena, result.value, result.response_headers, diag);
    }

    fn resolveHeaders(
        self: *const EmbeddingModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
        diag: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError![]const provider.Header {
        const api_key = try provider_utils.loadApiKey(.{
            .explicit = self.config.api_key,
            .env_var = "OPENAI_API_KEY",
            .description = "OpenAI",
            .env = self.config.env,
        }, arena, diag);
        var configured_storage: [3]provider_utils.HeaderEntry = undefined;
        var configured_len: usize = 0;
        configured_storage[configured_len] = .{
            .name = "authorization",
            .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}),
        };
        configured_len += 1;
        if (self.config.organization) |organization| {
            configured_storage[configured_len] = .{ .name = "OpenAI-Organization", .value = organization };
            configured_len += 1;
        }
        if (self.config.project) |project| {
            configured_storage[configured_len] = .{ .name = "OpenAI-Project", .value = project };
            configured_len += 1;
        }
        const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |value| value.len else 0);
        if (call_headers) |values| for (values, call_entries) |header, *entry| {
            entry.* = .{ .name = header.name, .value = header.value };
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            configured_storage[0..configured_len],
            self.config.headers.resolve(),
            call_entries,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(
            arena,
            combined,
            &.{"ai-sdk-zig/openai/" ++ provider_utils.version},
        );
    }
};

fn mapResponse(
    arena: Allocator,
    response: std.json.Value,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.embedding_model.CallError!provider.EmbeddingResult {
    if (response != .object) return invalidResponse(arena, diag, "OpenAI embedding response must be an object");
    const data = response.object.get("data") orelse return invalidResponse(arena, diag, "OpenAI embedding response data is missing");
    if (data != .array) return invalidResponse(arena, diag, "OpenAI embedding response data must be an array");
    const embeddings = try arena.alloc([]const f64, data.array.items.len);
    for (data.array.items, embeddings) |item, *destination| {
        if (item != .object) return invalidResponse(arena, diag, "OpenAI embedding item must be an object");
        const embedding = item.object.get("embedding") orelse return invalidResponse(arena, diag, "OpenAI embedding vector is missing");
        destination.* = switch (embedding) {
            .array => |values| blk: {
                const vector = try arena.alloc(f64, values.items.len);
                for (values.items, vector) |coordinate, *output| output.* = switch (coordinate) {
                    .float => |number| number,
                    .integer => |number| @floatFromInt(number),
                    else => return invalidResponse(arena, diag, "OpenAI embedding coordinate must be numeric"),
                };
                break :blk vector;
            },
            .string => |encoded| try decodeBase64Embedding(arena, encoded, diag),
            else => return invalidResponse(arena, diag, "OpenAI embedding vector must be an array or base64 string"),
        };
    }
    const usage = if (response.object.get("usage")) |usage_value|
        if (usage_value == .object) provider.EmbeddingUsage{
            .tokens = optionalU64(usage_value.object.get("prompt_tokens")),
        } else null
    else
        null;
    return .{
        .embeddings = embeddings,
        .usage = usage,
        .response = .{ .headers = response_headers, .body = response },
        .warnings = &.{},
    };
}

fn decodeBase64Embedding(
    arena: Allocator,
    encoded: []const u8,
    diag: ?*provider.Diagnostics,
) provider.embedding_model.CallError![]const f64 {
    const bytes = provider_utils.decodeBase64(arena, encoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalidResponse(arena, diag, "OpenAI base64 embedding is invalid"),
    };
    if (bytes.len % 4 != 0) return invalidResponse(arena, diag, "OpenAI base64 embedding byte length is invalid");
    const vector = try arena.alloc(f64, bytes.len / 4);
    for (vector, 0..) |*coordinate, index| {
        const start = index * 4;
        const bits = std.mem.readInt(u32, bytes[start..][0..4], .little);
        const value: f32 = @bitCast(bits);
        coordinate.* = value;
    }
    return vector;
}

fn tooManyValues(
    arena: Allocator,
    self: *const EmbeddingModel,
    values: []const []const u8,
    diag: ?*provider.Diagnostics,
) provider.embedding_model.CallError {
    var json_values = std.json.Array.init(arena);
    for (values) |value| json_values.append(.{ .string = value }) catch return error.OutOfMemory;
    const values_json = provider_utils.stringifyJsonValueAlloc(arena, .{ .array = json_values }) catch return error.OutOfMemory;
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .too_many_embedding_values_for_call = .{
            .message = "Too many embedding values for one OpenAI call",
            .provider = self.provider_id_buffer[0..self.provider_id_len],
            .model_id = self.model_id,
            .max_embeddings_per_call = 2048,
            .values_json = values_json,
        },
    });
    return error.TooManyEmbeddingValuesForCallError;
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        else => null,
    };
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
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "OpenAI embeddings round-trip float and base64 encodings with native limits" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "embedding-1" }},
        .body = .{ .text =
        \\{"object":"list","data":[{"object":"embedding","embedding":[0.0057293195,-0.012727811],"index":0},{"object":"embedding","embedding":[-0.037104916,-0.05178114],"index":1}],"model":"text-embedding-3-large","usage":{"prompt_tokens":12,"total_tokens":12}}
        },
    });

    var float_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, float_bytes[0..4], @bitCast(@as(f32, 1.5)), .little);
    std.mem.writeInt(u32, float_bytes[4..8], @bitCast(@as(f32, -2.25)), .little);
    const encoded = try provider_utils.encodeBase64(allocator, &float_bytes);
    defer allocator.free(encoded);
    const base64_response = try std.fmt.allocPrint(
        allocator,
        "{{\"object\":\"list\",\"data\":[{{\"object\":\"embedding\",\"embedding\":\"{s}\",\"index\":0}}],\"usage\":{{\"prompt_tokens\":3}}}}",
        .{encoded},
    );
    defer allocator.free(base64_response);
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text = base64_response },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try EmbeddingModel.init("text-embedding-3-large", .{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .organization = "org-1",
        .project = "project-1",
        .env = .empty,
        .headers = .{ .static = &.{.{ .name = "x-static", .value = "static" }} },
        .transport = client.transport(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
    const erased = model.embeddingModel();
    try std.testing.expectEqual(2048, erased.maxEmbeddingsPerCall(io).?);
    try std.testing.expect(erased.supportsParallelCalls(io));

    var first_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer first_arena_state.deinit();
    const first_arena = first_arena_state.allocator();
    const options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        first_arena,
        "{\"openai\":{\"dimensions\":64,\"user\":\"user-1\"}}",
        .{},
    );
    const call_headers = [_]provider.Header{.{ .name = "x-call", .value = "call" }};
    const first = try erased.doEmbed(io, first_arena, &.{
        .values = &.{ "sunny day at the beach", "rainy day in the city" },
        .provider_options = options,
        .headers = &call_headers,
    }, null);
    try std.testing.expectEqual(2, first.embeddings.len);
    try std.testing.expectEqualSlices(f64, &.{ 0.0057293195, -0.012727811 }, first.embeddings[0]);
    try std.testing.expectEqualSlices(f64, &.{ -0.037104916, -0.05178114 }, first.embeddings[1]);
    try std.testing.expectEqual(12, first.usage.?.tokens.?);
    try std.testing.expectEqualStrings("embedding-1", recordedHeader(first.response.?.headers.?, "x-request-id").?);

    const first_request = server.recordedRequests()[0];
    try std.testing.expectEqualStrings("/embeddings", first_request.target);
    try std.testing.expectEqualStrings("Bearer test-key", recordedHeader(first_request.headers, "authorization").?);
    try std.testing.expectEqualStrings("org-1", recordedHeader(first_request.headers, "OpenAI-Organization").?);
    try std.testing.expectEqualStrings("project-1", recordedHeader(first_request.headers, "OpenAI-Project").?);
    try std.testing.expectEqualStrings("static", recordedHeader(first_request.headers, "x-static").?);
    try std.testing.expectEqualStrings("call", recordedHeader(first_request.headers, "x-call").?);
    try std.testing.expect(std.mem.indexOf(u8, recordedHeader(first_request.headers, "user-agent").?, "ai-sdk-zig/openai/") != null);
    const first_body = try std.json.parseFromSliceLeaky(std.json.Value, first_arena, first_request.body, .{});
    try std.testing.expectEqualStrings("text-embedding-3-large", first_body.object.get("model").?.string);
    try std.testing.expectEqualStrings("float", first_body.object.get("encoding_format").?.string);
    try std.testing.expectEqual(64, first_body.object.get("dimensions").?.integer);
    try std.testing.expectEqualStrings("user-1", first_body.object.get("user").?.string);
    try std.testing.expectEqual(2, first_body.object.get("input").?.array.items.len);

    var second_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer second_arena_state.deinit();
    const second_arena = second_arena_state.allocator();
    const base64_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        second_arena,
        "{\"openai\":{\"encodingFormat\":\"base64\"}}",
        .{},
    );
    const second = try erased.doEmbed(io, second_arena, &.{
        .values = &.{"encoded vector"},
        .provider_options = base64_options,
    }, null);
    try std.testing.expectEqual(1, second.embeddings.len);
    try std.testing.expectEqualSlices(f64, &.{ 1.5, -2.25 }, second.embeddings[0]);
    try std.testing.expectEqual(3, second.usage.?.tokens.?);
    const second_body = try std.json.parseFromSliceLeaky(
        std.json.Value,
        second_arena,
        server.recordedRequests()[1].body,
        .{},
    );
    try std.testing.expectEqualStrings("base64", second_body.object.get("encoding_format").?.string);
    try std.testing.expectEqual(0, server.serveErrorCount());
}
