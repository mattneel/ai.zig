//! OpenAI-compatible `/embeddings` model.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const config_api = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const PreparedRequest = struct {
    url: []const u8,
    body: std.json.Value,
};

pub const EmbeddingModel = struct {
    model_id: []const u8,
    config: config_api.Config,

    pub fn embeddingModel(self: *EmbeddingModel) provider.EmbeddingModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn model(self: *EmbeddingModel) provider.EmbeddingModel {
        return self.embeddingModel();
    }

    pub fn prepareRequest(
        self: *EmbeddingModel,
        arena: Allocator,
        values: []const []const u8,
        diag: ?*provider.Diagnostics,
    ) (provider.Error || Allocator.Error)!PreparedRequest {
        try self.enforceLimit(values, diag);
        return .{
            .url = try buildUrl(arena, self.config.base_url, self.config.query_params),
            .body = try requestBody(arena, self.model_id, values),
        };
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
        return fromRaw(raw).config.provider;
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vMaxEmbeddingsPerCall(raw: *anyopaque, _: std.Io) ?u32 {
        return fromRaw(raw).config.max_embeddings_per_call orelse 2048;
    }

    fn vSupportsParallelCalls(raw: *anyopaque, _: std.Io) bool {
        return fromRaw(raw).config.supports_parallel_embedding_calls orelse true;
    }

    fn vDoEmbed(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.EmbeddingCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError!provider.EmbeddingResult {
        return fromRaw(raw).doEmbed(io, arena, options, diag);
    }

    fn doEmbed(
        self: *EmbeddingModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.EmbeddingCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError!provider.EmbeddingResult {
        const prepared = try self.prepareRequest(arena, options.values, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const headers = try self.resolveHeaders(arena, options.headers);
        const api_result = try provider_utils.postJsonToApi(
            Response,
            io,
            arena,
            self.config.transport,
            .{ .url = prepared.url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(Response),
                .failure = provider_utils.jsonErrorResponseHandler(ErrorResponse, errorMessage),
            },
            diag,
        );

        const embeddings = try arena.alloc([]const f64, api_result.value.data.len);
        for (api_result.value.data, embeddings) |item, *destination| {
            destination.* = item.embedding;
        }
        const response_body = if (api_result.raw_body) |raw| switch (provider_utils.safeParseJson(
            std.json.Value,
            arena,
            raw,
        )) {
            .success => |parsed| parsed.value,
            .failure => null,
        } else null;
        return .{
            .embeddings = embeddings,
            .usage = if (api_result.value.usage) |usage| .{ .tokens = usage.prompt_tokens } else null,
            .provider_metadata = api_result.value.providerMetadata,
            .response = .{ .headers = api_result.response_headers, .body = response_body },
            .warnings = &.{},
        };
    }

    fn enforceLimit(
        self: *EmbeddingModel,
        values: []const []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!void {
        const limit = self.config.max_embeddings_per_call orelse 2048;
        if (values.len <= limit) return;
        if (diag) |diagnostics| {
            const values_json = provider.wire.stringifyAlloc(diagnostics.allocator, values) catch null;
            defer if (values_json) |json| diagnostics.allocator.free(json);
            provider.Diagnostics.set(diag, diagnostics.allocator, .{
                .too_many_embedding_values_for_call = .{
                    .message = "Too many embedding values for a single call.",
                    .provider = self.config.provider,
                    .model_id = self.model_id,
                    .max_embeddings_per_call = limit,
                    .values_json = values_json orelse "[]",
                },
            });
        }
        return error.TooManyEmbeddingValuesForCallError;
    }

    fn resolveHeaders(
        self: *const EmbeddingModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
    ) Allocator.Error![]const provider.Header {
        var auth_entries: [1]provider_utils.HeaderEntry = undefined;
        var auth: []const provider_utils.HeaderEntry = &.{};
        if (try resolveApiKey(self.config, arena)) |api_key| {
            auth_entries[0] = .{
                .name = "authorization",
                .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}),
            };
            auth = &auth_entries;
        }
        const resolved = self.config.headers.resolve();
        const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |headers| headers.len else 0);
        if (call_headers) |source| for (source, call_entries) |header, *entry| {
            entry.* = .{ .name = header.name, .value = header.value };
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            auth,
            self.config.default_headers,
            resolved,
            call_entries,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(arena, combined, &.{self.config.user_agent_suffix});
    }
};

const Response = struct {
    data: []const Item,
    usage: ?Usage = null,
    providerMetadata: ?std.json.Value = null,

    const Item = struct { embedding: []const f64 };
    const Usage = struct { prompt_tokens: u64 };
};

const ErrorResponse = struct {
    @"error": ?struct { message: ?[]const u8 = null } = null,
    message: ?[]const u8 = null,
};

fn errorMessage(value: ErrorResponse) []const u8 {
    if (value.@"error") |error_value| if (error_value.message) |message| return message;
    return value.message orelse "OpenAI-compatible embeddings request failed";
}

fn requestBody(arena: Allocator, model_id: []const u8, values: []const []const u8) Allocator.Error!std.json.Value {
    var input = std.json.Array.init(arena);
    for (values) |value| try input.append(.{ .string = try arena.dupe(u8, value) });
    var body: std.json.ObjectMap = .empty;
    try body.put(arena, "model", .{ .string = try arena.dupe(u8, model_id) });
    try body.put(arena, "input", .{ .array = input });
    try body.put(arena, "encoding_format", .{ .string = "float" });
    return .{ .object = body };
}

fn resolveApiKey(config: config_api.Config, arena: Allocator) Allocator.Error!?[]const u8 {
    if (config.api_key) |value| return try arena.dupe(u8, value);
    const env_name = config.api_key_env_var orelse try derivedApiKeyEnv(arena, config.provider_name);
    return provider_utils.loadOptionalSetting(.{
        .explicit = null,
        .env_var = env_name,
        .description = "OpenAI-compatible",
        .setting_name = "apiKey",
        .env = config.env,
    }, arena);
}

fn derivedApiKeyEnv(arena: Allocator, provider_name: []const u8) Allocator.Error![]const u8 {
    const output = try arena.alloc(u8, provider_name.len + "_API_KEY".len);
    for (provider_name, output[0..provider_name.len]) |source, *destination| {
        destination.* = if (std.ascii.isAlphanumeric(source)) std.ascii.toUpper(source) else '_';
    }
    @memcpy(output[provider_name.len..], "_API_KEY");
    return output;
}

fn buildUrl(
    arena: Allocator,
    base_url: []const u8,
    query_params: []const config_api.QueryParam,
) Allocator.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    try output.appendSlice(arena, base_url);
    try output.appendSlice(arena, "/embeddings");
    for (query_params, 0..) |query, index| {
        try output.append(arena, if (index == 0) '?' else '&');
        try appendPercentEncoded(arena, &output, query.name);
        try output.append(arena, '=');
        try appendPercentEncoded(arena, &output, query.value);
    }
    return output.toOwnedSlice(arena);
}

fn appendPercentEncoded(arena: Allocator, output: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(arena, byte);
        } else {
            try output.appendSlice(arena, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

test "embedding request uses OpenAI-compatible wire shape and defaults" {
    const Dummy = struct {
        fn request(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: provider_utils.RequestSpec,
            _: ?*provider.Diagnostics,
        ) provider_utils.RequestError!provider_utils.Response {
            return error.APICallError;
        }
    };
    var marker: u8 = 0;
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var model: EmbeddingModel = .{
        .model_id = "text-embedding-3-small",
        .config = .{
            .provider = "test",
            .provider_name = "test",
            .base_url = "https://example.test/v1",
            .api_key = null,
            .api_key_env_var = null,
            .env = .empty,
            .headers = .{ .static = &.{} },
            .query_params = &.{},
            .transport = transport,
            .include_usage = false,
            .supports_structured_outputs = false,
            .error_hooks = .{},
        },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prepared = try model.prepareRequest(arena_state.allocator(), &.{ "a", "b" }, null);
    try std.testing.expectEqualStrings("https://example.test/v1/embeddings", prepared.url);
    try std.testing.expectEqualStrings("float", prepared.body.object.get("encoding_format").?.string);
    try std.testing.expectEqual(2, prepared.body.object.get("input").?.array.items.len);
    try std.testing.expectEqual(2048, model.embeddingModel().maxEmbeddingsPerCall(std.testing.io).?);
    try std.testing.expect(model.embeddingModel().supportsParallelCalls(std.testing.io));
}
