//! Data-driven presets for vendors exposing OpenAI-compatible endpoints.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const test_support = @import("test_support");
const openai_compatible = @import("root.zig");

/// Compatibility-layer behavior selected by a vendor preset.
pub const VendorQuirks = struct {
    include_usage: bool = false,
    supports_structured_outputs: bool = false,
    strict_json_schema_default: bool = true,
    max_embeddings_per_call: ?u32 = null,
    supports_parallel_embedding_calls: ?bool = null,
    error_hooks: openai_compatible.ErrorHooks = .{},
};

/// One row in the OpenAI-compatible vendor configuration table.
///
/// `default_headers` contains only vendor-specific static headers. Bearer
/// authorization and the compatibility-layer user agent are shared behavior
/// assembled at request time.
pub const VendorPreset = struct {
    provider_name: []const u8,
    embedding_provider_name: ?[]const u8,
    default_base_url: []const u8,
    api_key_env_var: []const u8,
    base_url_env_var: []const u8,
    user_agent_suffix: []const u8,
    default_headers: []const provider_utils.HeaderEntry = &.{},
    quirks: VendorQuirks = .{},
    factory: *const fn (VendorSettings) VendorProvider,
};

/// Runtime settings shared by all vendor factories.
pub const VendorSettings = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    headers: openai_compatible.HeaderSource = .{ .static = &.{} },
    transport: provider_utils.HttpTransport,
};

/// Thin vendor facade that creates chat and, when advertised by the table,
/// embedding models through the generic OpenAI-compatible implementation.
pub const VendorProvider = struct {
    preset: *const VendorPreset,
    settings: VendorSettings,
    base_url: []const u8,

    fn init(preset: *const VendorPreset, settings: VendorSettings) VendorProvider {
        const configured = settings.base_url orelse
            settings.env.get(preset.base_url_env_var) orelse
            preset.default_base_url;
        return .{
            .preset = preset,
            .settings = settings,
            .base_url = std.mem.trimEnd(u8, configured, "/"),
        };
    }

    pub fn chatModel(
        self: *const VendorProvider,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.ChatLanguageModel {
        const compatible_provider = self.makeCompatible(self.preset.provider_name);
        return compatible_provider.chatModel(model_id, diag);
    }

    pub fn languageModel(
        self: *const VendorProvider,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.ChatLanguageModel {
        return self.chatModel(model_id, diag);
    }

    pub fn embeddingModel(
        self: *const VendorProvider,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.EmbeddingModel {
        const provider_name = self.preset.embedding_provider_name orelse
            return noSuchEmbeddingModel(diag, model_id, self.preset.provider_name);
        const compatible_provider = self.makeCompatible(provider_name);
        return compatible_provider.embeddingModel(model_id, diag);
    }

    fn makeCompatible(
        self: *const VendorProvider,
        provider_name: []const u8,
    ) openai_compatible.OpenAiCompatible {
        return openai_compatible.createOpenAiCompatible(.{
            .provider_name = provider_name,
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .api_key_env_var = self.preset.api_key_env_var,
            .env = self.settings.env,
            .default_headers = self.preset.default_headers,
            .headers = self.settings.headers,
            .user_agent_suffix = self.preset.user_agent_suffix,
            .transport = self.settings.transport,
            .include_usage = self.preset.quirks.include_usage,
            .supports_structured_outputs = self.preset.quirks.supports_structured_outputs,
            .strict_json_schema_default = self.preset.quirks.strict_json_schema_default,
            .max_embeddings_per_call = self.preset.quirks.max_embeddings_per_call,
            .supports_parallel_embedding_calls = self.preset.quirks.supports_parallel_embedding_calls,
            .error_hooks = self.preset.quirks.error_hooks,
        });
    }
};

/// The authoritative vendor table. Adding a row automatically opts the
/// preset into the shared conformance fixtures below.
pub const table = [_]VendorPreset{
    .{
        .provider_name = "groq.chat",
        .embedding_provider_name = null,
        .default_base_url = "https://api.groq.com/openai/v1",
        .api_key_env_var = "GROQ_API_KEY",
        .base_url_env_var = "GROQ_BASE_URL",
        .user_agent_suffix = "ai-sdk-zig/groq/" ++ provider_utils.version,
        .quirks = .{ .supports_structured_outputs = true },
        .factory = createGroq,
    },
    .{
        .provider_name = "deepseek.chat",
        .embedding_provider_name = null,
        .default_base_url = "https://api.deepseek.com",
        .api_key_env_var = "DEEPSEEK_API_KEY",
        .base_url_env_var = "DEEPSEEK_BASE_URL",
        .user_agent_suffix = "ai-sdk-zig/deepseek/" ++ provider_utils.version,
        .quirks = .{ .include_usage = true },
        .factory = createDeepSeek,
    },
    .{
        .provider_name = "mistral.chat",
        .embedding_provider_name = "mistral.embedding",
        .default_base_url = "https://api.mistral.ai/v1",
        .api_key_env_var = "MISTRAL_API_KEY",
        .base_url_env_var = "MISTRAL_BASE_URL",
        .user_agent_suffix = "ai-sdk-zig/mistral/" ++ provider_utils.version,
        .quirks = .{
            .supports_structured_outputs = true,
            .strict_json_schema_default = false,
            .max_embeddings_per_call = 32,
            .supports_parallel_embedding_calls = false,
        },
        .factory = createMistral,
    },
    .{
        .provider_name = "togetherai.chat",
        .embedding_provider_name = "togetherai.embedding",
        .default_base_url = "https://api.together.xyz/v1",
        .api_key_env_var = "TOGETHER_API_KEY",
        .base_url_env_var = "TOGETHER_BASE_URL",
        .user_agent_suffix = "ai-sdk-zig/togetherai/" ++ provider_utils.version,
        .factory = createTogetherAi,
    },
    .{
        .provider_name = "fireworks.chat",
        .embedding_provider_name = "fireworks.embedding",
        .default_base_url = "https://api.fireworks.ai/inference/v1",
        .api_key_env_var = "FIREWORKS_API_KEY",
        .base_url_env_var = "FIREWORKS_BASE_URL",
        .user_agent_suffix = "ai-sdk-zig/fireworks/" ++ provider_utils.version,
        .quirks = .{
            .include_usage = true,
            .error_hooks = .{ .message_fn = fireworksErrorMessage },
        },
        .factory = createFireworks,
    },
};

pub fn createGroq(settings: VendorSettings) VendorProvider {
    return .init(&table[0], settings);
}

pub fn createDeepSeek(settings: VendorSettings) VendorProvider {
    return .init(&table[1], settings);
}

pub fn createMistral(settings: VendorSettings) VendorProvider {
    return .init(&table[2], settings);
}

pub fn createTogetherAi(settings: VendorSettings) VendorProvider {
    return .init(&table[3], settings);
}

/// Alias matching the upstream package's capitalization.
pub const createTogetherAI = createTogetherAi;

pub fn createFireworks(settings: VendorSettings) VendorProvider {
    return .init(&table[4], settings);
}

fn fireworksErrorMessage(_: ?*anyopaque, value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const error_value = value.object.get("error") orelse return null;
    return if (error_value == .string) error_value.string else null;
}

fn noSuchEmbeddingModel(
    diag: ?*provider.Diagnostics,
    model_id: []const u8,
    _: []const u8,
) provider.Error {
    if (diag) |diagnostics| {
        provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_such_model = .{
            .message = "This vendor does not expose an embedding model through this preset.",
            .model_id = model_id,
            .model_type = .embedding_model,
        } });
    }
    return error.NoSuchModelError;
}

const FixtureEnv = struct {
    preset: *const VendorPreset,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,

    fn lookup(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (std.mem.eql(u8, name, self.preset.base_url_env_var)) return self.base_url;
        if (std.mem.eql(u8, name, self.preset.api_key_env_var)) return self.api_key;
        return null;
    }

    fn env(self: *@This()) provider_utils.EnvLookup {
        return .{ .ctx = self, .get_fn = lookup };
    }
};

const DummyTransport = struct {
    fn transport(self: *@This()) provider_utils.HttpTransport {
        return .{ .ctx = self, .vtable = &.{ .request = request } };
    }

    fn request(
        raw: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: provider_utils.RequestSpec,
        _: ?*provider.Diagnostics,
    ) provider_utils.RequestError!provider_utils.Response {
        _ = raw;
        return error.APICallError;
    }
};

fn headerValue(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "vendor table shares factory conformance fixtures" {
    var transport: DummyTransport = .{};
    const custom_headers = [_]provider_utils.HeaderEntry{
        .{ .name = "x-conformance", .value = "factory" },
    };

    for (&table) |*preset| {
        const default_factory = preset.factory(.{ .transport = transport.transport() });
        try std.testing.expectEqualStrings(preset.default_base_url, default_factory.base_url);
        try std.testing.expect(default_factory.preset == preset);

        var env_context: FixtureEnv = .{
            .preset = preset,
            .base_url = "https://env.example/v1///",
            .api_key = "env-key",
        };
        const env_factory = preset.factory(.{
            .env = env_context.env(),
            .headers = .{ .static = &custom_headers },
            .transport = transport.transport(),
        });
        try std.testing.expectEqualStrings("https://env.example/v1", env_factory.base_url);

        const explicit_factory = preset.factory(.{
            .base_url = "https://explicit.example/v2///",
            .env = env_context.env(),
            .transport = transport.transport(),
        });
        try std.testing.expectEqualStrings("https://explicit.example/v2", explicit_factory.base_url);

        const chat = try env_factory.chatModel("fixture-chat", null);
        try std.testing.expectEqualStrings(preset.provider_name, chat.config.provider);
        try std.testing.expectEqualStrings(preset.api_key_env_var, chat.config.api_key_env_var.?);
        try std.testing.expectEqualStrings(preset.user_agent_suffix, chat.config.user_agent_suffix);
        try std.testing.expectEqualSlices(
            provider_utils.HeaderEntry,
            preset.default_headers,
            chat.config.default_headers,
        );
        try std.testing.expectEqualStrings(
            "factory",
            chat.config.headers.resolve()[0].value.?,
        );
        try std.testing.expectEqual(
            preset.quirks.include_usage,
            chat.config.include_usage,
        );
        try std.testing.expectEqual(
            preset.quirks.supports_structured_outputs,
            chat.config.supports_structured_outputs,
        );
        try std.testing.expectEqual(
            preset.quirks.strict_json_schema_default,
            chat.config.strict_json_schema_default,
        );

        if (preset.embedding_provider_name) |embedding_provider_name| {
            const embedding = try env_factory.embeddingModel("fixture-embedding", null);
            try std.testing.expectEqualStrings(embedding_provider_name, embedding.config.provider);
            try std.testing.expectEqual(
                preset.quirks.max_embeddings_per_call,
                embedding.config.max_embeddings_per_call,
            );
            try std.testing.expectEqual(
                preset.quirks.supports_parallel_embedding_calls,
                embedding.config.supports_parallel_embedding_calls,
            );
        } else {
            try std.testing.expectError(
                error.NoSuchModelError,
                env_factory.embeddingModel("fixture-embedding", null),
            );
        }
    }
}

test "vendor table shares MockServer chat round-trip conformance fixtures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const response =
        \\{"id":"chatcmpl-vendor","created":1711115037,"model":"fixture-response-model","choices":[{"message":{"role":"assistant","content":"shared fixture reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":3}}
    ;
    const custom_headers = [_]provider_utils.HeaderEntry{
        .{ .name = "x-conformance", .value = "round-trip" },
    };
    var server_base_buffer: [64]u8 = undefined;
    var configured_base_buffer: [96]u8 = undefined;
    const configured_base_url = try std.fmt.bufPrint(
        &configured_base_buffer,
        "{s}///",
        .{server.baseUrl(&server_base_buffer)},
    );

    for (&table, 0..) |*preset, request_index| {
        try server.enqueue(.{
            .content_type = "application/json",
            .body = .{ .text = response },
        });
        var env_context: FixtureEnv = .{
            .preset = preset,
            .base_url = configured_base_url,
            .api_key = "fixture-api-key",
        };
        const factory = preset.factory(.{
            .env = env_context.env(),
            .headers = .{ .static = &custom_headers },
            .transport = client.transport(),
        });
        var model = try factory.chatModel("fixture-model", null);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const prompt = [_]provider.Message{.{ .user = .{
            .content = &.{.{ .text = .{ .text = "Hello" } }},
        } }};

        const result = try model.languageModel().doGenerate(io, arena, &.{
            .prompt = &prompt,
        }, null);

        try std.testing.expectEqualStrings(preset.provider_name, model.config.provider);
        try std.testing.expectEqual(1, result.content.len);
        try std.testing.expectEqualStrings("shared fixture reply", result.content[0].text.text);
        try std.testing.expectEqual(provider.FinishReasonUnified.stop, result.finish_reason.unified);
        try std.testing.expectEqual(4, result.usage.input_tokens.total.?);
        try std.testing.expectEqual(3, result.usage.output_tokens.total.?);
        try std.testing.expectEqualStrings("chatcmpl-vendor", result.response.?.id.?);
        try std.testing.expectEqualStrings("fixture-response-model", result.response.?.model_id.?);

        const requests = server.recordedRequests();
        try std.testing.expectEqual(request_index + 1, requests.len);
        const request = requests[request_index];
        try std.testing.expectEqual(.POST, request.method);
        try std.testing.expectEqualStrings("/chat/completions", request.target);
        try std.testing.expectEqualStrings(
            "Bearer fixture-api-key",
            headerValue(request.headers, "authorization").?,
        );
        try std.testing.expectEqualStrings(
            "round-trip",
            headerValue(request.headers, "x-conformance").?,
        );
        try std.testing.expect(std.mem.indexOf(
            u8,
            headerValue(request.headers, "user-agent").?,
            preset.user_agent_suffix,
        ) != null);
        for (preset.default_headers) |header| {
            if (header.value) |value| {
                try std.testing.expectEqualStrings(value, headerValue(request.headers, header.name).?);
            }
        }
    }
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
