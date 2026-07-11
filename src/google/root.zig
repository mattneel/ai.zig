//! Native Google Generative AI (Gemini) provider.

const std = @import("std");
const provider = @import("provider");

pub const config = @import("config.zig");
pub const Settings = config.Settings;
pub const HeaderSource = config.HeaderSource;
pub const options = @import("options.zig");
pub const schema = @import("schema.zig");
pub const prompt = @import("prompt.zig");
pub const tools = @import("tools.zig");
pub const GoogleLanguageModel = @import("language_model.zig").GoogleLanguageModel;
pub const GoogleEmbeddingModel = @import("embedding_model.zig").GoogleEmbeddingModel;

const Allocator = std.mem.Allocator;

pub const GoogleGenerativeAi = struct {
    settings: Settings,
    base_url: []const u8,

    pub fn chat(
        self: *const GoogleGenerativeAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!GoogleLanguageModel {
        return GoogleLanguageModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn languageModel(
        self: *const GoogleGenerativeAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!GoogleLanguageModel {
        return self.chat(model_id, diag);
    }

    pub fn embedding(
        self: *const GoogleGenerativeAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!GoogleEmbeddingModel {
        return GoogleEmbeddingModel.init(model_id, self.modelConfig(), diag);
    }

    pub fn embeddingModel(
        self: *const GoogleGenerativeAi,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!GoogleEmbeddingModel {
        return self.embedding(model_id, diag);
    }

    pub fn providerAdapter(self: *const GoogleGenerativeAi, arena: Allocator) ProviderAdapter {
        return .{ .factory = self, .arena = arena };
    }

    fn modelConfig(self: *const GoogleGenerativeAi) config.Config {
        return .{
            .allocator = self.settings.allocator,
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .env = self.settings.env,
            .headers = self.settings.headers,
            .transport = self.settings.transport,
            .provider_name = self.settings.name,
            .provider_options_name = "google",
        };
    }
};

pub const ProviderAdapter = struct {
    factory: *const GoogleGenerativeAi,
    arena: Allocator,

    pub fn asProvider(self: *ProviderAdapter) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .languageModel = vLanguageModel,
        .embeddingModel = vEmbeddingModel,
        .imageModel = vImageModel,
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
        const model = self.arena.create(GoogleLanguageModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.languageModel(model_id, diag);
        return model.languageModel();
    }

    fn vEmbeddingModel(
        raw: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.EmbeddingModel {
        const self = fromRaw(raw);
        const model = self.arena.create(GoogleEmbeddingModel) catch return error.InvalidArgumentError;
        model.* = try self.factory.embeddingModel(model_id, diag);
        return model.embeddingModel();
    }

    fn vImageModel(
        _: *anyopaque,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.ImageModel {
        if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_such_model = .{
            .message = "The Phase 12 Google provider does not expose image models.",
            .model_id = model_id,
            .model_type = .image_model,
        } });
        return error.NoSuchModelError;
    }
};

pub fn createGoogleGenerativeAi(settings: Settings) GoogleGenerativeAi {
    const configured = settings.base_url orelse "https://generativelanguage.googleapis.com/v1beta";
    return .{
        .settings = settings,
        .base_url = std.mem.trimEnd(u8, configured, "/"),
    };
}

test "Google factory normalizes base URL and routes native language and embedding models" {
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
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var factory = createGoogleGenerativeAi(.{
        .allocator = std.testing.allocator,
        .base_url = "https://proxy.example/v1beta///",
        .api_key = "key",
        .transport = transport,
    });
    var language = try factory.chat("gemini-2.5-flash", null);
    var embedding_model = try factory.embedding("gemini-embedding-001", null);
    try std.testing.expectEqualStrings("https://proxy.example/v1beta", factory.base_url);
    try std.testing.expectEqualStrings("google.generative-ai", language.languageModel().provider());
    try std.testing.expectEqualStrings("google.generative-ai", embedding_model.embeddingModel().provider());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var adapter = factory.providerAdapter(arena_state.allocator());
    const erased = adapter.asProvider();
    try std.testing.expectEqualStrings("gemini-2.5-flash", (try erased.languageModel("gemini-2.5-flash", null)).modelId());
    try std.testing.expectEqualStrings("gemini-embedding-001", (try erased.embeddingModel("gemini-embedding-001", null)).modelId());
}

test "Google API key resolution prefers canonical env and accepts GOOGLE_API_KEY fallback" {
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
    const Env = struct {
        canonical: ?[]const u8,
        fallback: ?[]const u8,

        fn get(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, name, "GOOGLE_GENERATIVE_AI_API_KEY")) return self.canonical;
            if (std.mem.eql(u8, name, "GOOGLE_API_KEY")) return self.fallback;
            return null;
        }
    };
    var marker: u8 = 0;
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    var env_context: Env = .{ .canonical = "canonical", .fallback = "fallback" };
    const factory = createGoogleGenerativeAi(.{
        .allocator = std.testing.allocator,
        .env = .{ .ctx = &env_context, .get_fn = Env.get },
        .transport = transport,
    });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("canonical", try config.loadApiKey(factory.modelConfig(), arena_state.allocator(), null));
    env_context.canonical = null;
    try std.testing.expectEqualStrings("fallback", try config.loadApiKey(factory.modelConfig(), arena_state.allocator(), null));
}

test "Google factory rejects empty model and provider names with diagnostics" {
    const provider_utils = @import("provider_utils");
    const Dummy = struct {
        fn request(_: *anyopaque, _: std.Io, _: Allocator, _: provider_utils.RequestSpec, _: ?*provider.Diagnostics) provider_utils.RequestError!provider_utils.Response {
            return error.APICallError;
        }
    };
    var marker: u8 = 0;
    const transport: provider_utils.HttpTransport = .{ .ctx = &marker, .vtable = &.{ .request = Dummy.request } };
    const empty_name = createGoogleGenerativeAi(.{ .allocator = std.testing.allocator, .name = "", .transport = transport });
    try std.testing.expectError(error.InvalidArgumentError, empty_name.chat("gemini", null));
    const factory = createGoogleGenerativeAi(.{ .allocator = std.testing.allocator, .transport = transport });
    try std.testing.expectError(error.InvalidArgumentError, factory.embedding("", null));
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
