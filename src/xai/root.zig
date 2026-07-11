//! Thin xAI provider over OpenAI-compatible chat plus native video polling.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const openai_compatible = @import("openai_compatible");

pub const video_model = @import("video_model.zig");
pub const VideoModel = video_model.VideoModel;

const Allocator = std.mem.Allocator;

pub const Settings = struct {
    allocator: Allocator,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    headers: openai_compatible.HeaderSource = .{ .static = &.{} },
    transport: provider_utils.HttpTransport,
};

pub const Xai = struct {
    settings: Settings,
    base_url: []const u8,

    pub fn chatModel(
        self: *const Xai,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.ChatLanguageModel {
        const compatible = openai_compatible.createOpenAiCompatible(.{
            .provider_name = "xai.chat",
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .api_key_env_var = "XAI_API_KEY",
            .env = self.settings.env,
            .headers = self.settings.headers,
            .transport = self.settings.transport,
            .supports_structured_outputs = true,
        });
        return compatible.chatModel(model_id, diag);
    }

    pub fn languageModel(
        self: *const Xai,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.ChatLanguageModel {
        return self.chatModel(model_id, diag);
    }

    pub fn videoModel(
        self: *const Xai,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!VideoModel {
        return VideoModel.init(model_id, .{
            .allocator = self.settings.allocator,
            .provider = "xai.video",
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .env = self.settings.env,
            .headers = self.settings.headers,
            .transport = self.settings.transport,
        }, diag);
    }

    pub fn providerAdapter(self: *const Xai, arena: Allocator) ProviderAdapter {
        return .{ .factory = self, .arena = arena };
    }
};

pub const ProviderAdapter = struct {
    factory: *const Xai,
    arena: Allocator,

    pub fn asProvider(self: *ProviderAdapter) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .languageModel = vLanguageModel,
        .embeddingModel = vEmbeddingModel,
        .imageModel = vImageModel,
        .videoModel = vVideoModel,
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
        const model = self.arena.create(openai_compatible.ChatLanguageModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.languageModel(model_id, diag);
        return model.languageModel();
    }

    fn vEmbeddingModel(
        _: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.EmbeddingModel {
        return noSuchModel(diag, model_id, .embedding_model, "xAI does not expose an embedding model through this provider.");
    }

    fn vImageModel(
        _: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.ImageModel {
        return noSuchModel(diag, model_id, .image_model, "xAI image models are not part of the minimal Phase 10 provider.");
    }

    fn vVideoModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.VideoModel {
        const self = fromRaw(raw);
        const model = self.arena.create(VideoModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.videoModel(model_id, diag);
        return model.videoModel();
    }
};

pub fn createXai(settings: Settings) Xai {
    const configured = settings.base_url orelse settings.env.get("XAI_BASE_URL") orelse
        "https://api.x.ai/v1";
    return .{
        .settings = settings,
        .base_url = std.mem.trimEnd(u8, configured, "/"),
    };
}

fn noSuchModel(
    diag: ?*provider.Diagnostics,
    model_id: []const u8,
    model_type: provider.ModelType,
    message: []const u8,
) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_such_model = .{
        .message = message,
        .model_id = model_id,
        .model_type = model_type,
    } });
    return error.NoSuchModelError;
}

test "xAI factory wraps OpenAI-compatible chat and native video" {
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
    var factory = createXai(.{
        .allocator = std.testing.allocator,
        .base_url = "https://proxy.example/v1///",
        .api_key = "test-key",
        .transport = transport,
    });
    var chat = try factory.chatModel("grok-4", null);
    var video = try factory.videoModel("grok-imagine-video", null);
    try std.testing.expectEqualStrings("https://proxy.example/v1", factory.base_url);
    try std.testing.expectEqualStrings("xai.chat", chat.languageModel().provider());
    try std.testing.expectEqualStrings("xai.video", video.videoModel().provider());
    try std.testing.expectEqualStrings("grok-imagine-video", video.videoModel().modelId());
    try std.testing.expectEqual(1, video.videoModel().maxVideosPerCall(std.testing.io).?);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var adapter = factory.providerAdapter(arena_state.allocator());
    const erased_video = try adapter.asProvider().videoModel("grok-imagine-video", null);
    try std.testing.expectEqualStrings("xai.video", erased_video.provider());
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
