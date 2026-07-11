//! Native OpenAI provider. The default language-model factory uses the
//! Responses API, matching upstream; explicit `chat` remains available for
//! Chat Completions-compatible endpoints.

const std = @import("std");
const provider = @import("provider");

pub const config = @import("config.zig");
pub const Settings = config.Settings;
pub const HeaderSource = config.HeaderSource;
pub const capabilities = @import("capabilities.zig");
pub const LanguageModelCapabilities = capabilities.LanguageModelCapabilities;
pub const getLanguageModelCapabilities = capabilities.getLanguageModelCapabilities;
pub const options = @import("options.zig");
pub const chat_messages = @import("chat_messages.zig");
pub const chat_tools = @import("chat_tools.zig");
pub const responses_input = @import("responses_input.zig");
pub const responses_api = @import("responses_api.zig");
pub const responses_tools = @import("responses_tools.zig");
pub const api = @import("api.zig");
pub const ChatLanguageModel = @import("chat_language_model.zig").ChatLanguageModel;
pub const ResponsesLanguageModel = @import("responses_language_model.zig").ResponsesLanguageModel;
pub const EmbeddingModel = @import("embedding_model.zig").EmbeddingModel;
pub const ImageModel = @import("image_model.zig").ImageModel;
pub const SpeechModel = @import("speech_model.zig").SpeechModel;
pub const TranscriptionModel = @import("transcription_model.zig").TranscriptionModel;
pub const RealtimeModel = @import("realtime_model.zig").RealtimeModel;

const Allocator = std.mem.Allocator;

pub const OpenAi = struct {
    settings: Settings,
    base_url: []const u8,

    pub fn chat(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ChatLanguageModel {
        return ChatLanguageModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn languageModel(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ResponsesLanguageModel {
        return self.responses(model_id, diag);
    }

    pub fn responses(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ResponsesLanguageModel {
        return ResponsesLanguageModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn embeddingModel(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!EmbeddingModel {
        return EmbeddingModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn imageModel(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ImageModel {
        return ImageModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn speechModel(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!SpeechModel {
        return SpeechModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn transcriptionModel(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!TranscriptionModel {
        return TranscriptionModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn realtimeModel(
        self: *const OpenAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!RealtimeModel {
        return RealtimeModel.init(model_id, self.modelConfig(), diag);
    }

    /// Builds a Provider V4 adapter whose model objects live in `arena`.
    /// The adapter itself must remain at a stable address while its fat pointer
    /// is in use, matching every other provider context in this repository.
    pub fn providerAdapter(self: *const OpenAi, arena: Allocator) ProviderAdapter {
        return .{ .factory = self, .arena = arena };
    }

    fn modelConfig(self: *const OpenAi) config.Config {
        return .{
            .allocator = self.settings.allocator,
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .organization = self.settings.organization,
            .project = self.settings.project,
            .env = self.settings.env,
            .headers = self.settings.headers,
            .transport = self.settings.transport,
            .websocket_factory = self.settings.websocket_factory,
            .provider_name = self.settings.name,
            .provider_options_name = providerOptionsName(self.settings.name),
        };
    }
};

pub const ProviderAdapter = struct {
    factory: *const OpenAi,
    arena: Allocator,

    pub fn asProvider(self: *ProviderAdapter) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .languageModel = vLanguageModel,
        .embeddingModel = vEmbeddingModel,
        .imageModel = vImageModel,
        .speechModel = vSpeechModel,
        .transcriptionModel = vTranscriptionModel,
    };

    fn fromRaw(raw: *anyopaque) *ProviderAdapter {
        return @ptrCast(@alignCast(raw));
    }

    fn vLanguageModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.LanguageModel {
        const self = fromRaw(raw);
        const model = self.arena.create(ResponsesLanguageModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.languageModel(model_id, diag);
        return model.languageModel();
    }

    fn vEmbeddingModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.EmbeddingModel {
        const self = fromRaw(raw);
        const model = self.arena.create(EmbeddingModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.embeddingModel(model_id, diag);
        return model.embeddingModel();
    }

    fn vImageModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.ImageModel {
        const self = fromRaw(raw);
        const model = self.arena.create(ImageModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.imageModel(model_id, diag);
        return model.imageModel();
    }

    fn vSpeechModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.SpeechModel {
        const self = fromRaw(raw);
        const model = self.arena.create(SpeechModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.speechModel(model_id, diag);
        return model.speechModel();
    }

    fn vTranscriptionModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.TranscriptionModel {
        const self = fromRaw(raw);
        const model = self.arena.create(TranscriptionModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.transcriptionModel(model_id, diag);
        return model.transcriptionModel();
    }
};

pub fn createOpenAi(settings: Settings) OpenAi {
    const configured = settings.base_url orelse settings.env.get("OPENAI_BASE_URL") orelse
        "https://api.openai.com/v1";
    return .{
        .settings = settings,
        .base_url = std.mem.trimEnd(u8, configured, "/"),
    };
}

fn providerOptionsName(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

test "OpenAI factory normalizes base URL, provider ids, namespaces, and Provider V4 routing" {
    const provider_utils = @import("provider_utils");
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
    const transport: provider_utils.HttpTransport = .{
        .ctx = &marker,
        .vtable = &.{ .request = Dummy.request },
    };
    var factory = createOpenAi(.{
        .allocator = std.testing.allocator,
        .base_url = "https://proxy.example/v1///",
        .name = "custom.openai",
        .transport = transport,
    });
    var responses = try factory.languageModel("gpt-4o-mini", null);
    var chat = try factory.chat("gpt-4o-mini", null);
    var embedding = try factory.embeddingModel("text-embedding-3-small", null);
    var realtime = try factory.realtimeModel("gpt-realtime", null);
    try std.testing.expectEqualStrings("https://proxy.example/v1", factory.base_url);
    try std.testing.expectEqualStrings("custom.openai.responses", responses.languageModel().provider());
    try std.testing.expectEqualStrings("custom.openai.chat", chat.languageModel().provider());
    try std.testing.expectEqualStrings("custom.openai.embedding", embedding.embeddingModel().provider());
    try std.testing.expectEqualStrings("custom.openai.realtime", realtime.realtimeModel().provider());
    try std.testing.expectEqualStrings("custom", responses.config.provider_options_name);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var adapter = factory.providerAdapter(arena_state.allocator());
    const erased = adapter.asProvider();
    try std.testing.expectEqualStrings("custom.openai.responses", (try erased.languageModel("gpt-4o-mini", null)).provider());
    try std.testing.expectEqualStrings("custom.openai.embedding", (try erased.embeddingModel("text-embedding-3-small", null)).provider());
    try std.testing.expectEqualStrings("custom.openai.image", (try erased.imageModel("gpt-image-1", null)).provider());
    try std.testing.expectEqualStrings("custom.openai.speech", (try erased.speechModel("gpt-4o-mini-tts", null)).provider());
    try std.testing.expectEqualStrings("custom.openai.transcription", (try erased.transcriptionModel("gpt-4o-mini-transcribe", null)).provider());
}

test "OpenAI factory reads the base URL at creation and the API key at call time" {
    const provider_utils = @import("provider_utils");
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"id":"chat-env","created":1700000000,"model":"gpt-4o-mini","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        },
    });

    const Env = struct {
        base_url: ?[]const u8,
        api_key: ?[]const u8,

        fn get(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, name, "OPENAI_BASE_URL")) return self.base_url;
            if (std.mem.eql(u8, name, "OPENAI_API_KEY")) return self.api_key;
            return null;
        }
    };
    var base_buffer: [64]u8 = undefined;
    var env_context: Env = .{
        .base_url = server.baseUrl(&base_buffer),
        .api_key = null,
    };
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = createOpenAi(.{
        .allocator = allocator,
        .env = .{ .ctx = &env_context, .get_fn = Env.get },
        .transport = client.transport(),
    });
    try std.testing.expectEqualStrings(env_context.base_url.?, factory.base_url);

    // Mutation after factory creation proves authentication is resolved per
    // request rather than cached alongside the base URL.
    env_context.api_key = "late-env-key";
    var model = try factory.chat("gpt-4o-mini", null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const prompt = [_]provider.Message{.{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } }};
    _ = try model.languageModel().doGenerate(io, arena_state.allocator(), &.{ .prompt = &prompt }, null);
    const request = server.recordedRequests()[0];
    var authorization: ?[]const u8 = null;
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) authorization = header.value;
    }
    try std.testing.expectEqualStrings("Bearer late-env-key", authorization.?);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
