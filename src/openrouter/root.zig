//! Thin OpenRouter wrapper over the OpenAI-compatible chat provider.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const openai_compatible = @import("openai_compatible");

pub const Settings = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    env: provider_utils.EnvLookup = .empty,
    transport: provider_utils.HttpTransport,
    http_referer: ?[]const u8 = null,
    x_title: ?[]const u8 = null,
    include_usage: bool = false,
};

pub const OpenRouter = struct {
    settings: Settings,
    base_url: []const u8,
    attribution: [2]provider_utils.HeaderEntry = undefined,
    attribution_len: usize = 0,

    pub fn chatModel(
        self: *OpenRouter,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.ChatLanguageModel {
        const compatible = openai_compatible.createOpenAiCompatible(.{
            .provider_name = "openrouter",
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .api_key_env_var = "OPENROUTER_API_KEY",
            .env = self.settings.env,
            .headers = .{ .dynamic = .{ .ctx = self, .resolve_fn = resolveHeaders } },
            .transport = self.settings.transport,
            .include_usage = self.settings.include_usage,
            .supports_structured_outputs = true,
        });
        return compatible.chatModel(model_id, diag);
    }

    pub fn languageModel(
        self: *OpenRouter,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.ChatLanguageModel {
        return self.chatModel(model_id, diag);
    }

    pub fn embeddingModel(
        self: *OpenRouter,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!openai_compatible.EmbeddingModel {
        const compatible = openai_compatible.createOpenAiCompatible(.{
            .provider_name = "openrouter",
            .base_url = self.base_url,
            .api_key = self.settings.api_key,
            .api_key_env_var = "OPENROUTER_API_KEY",
            .env = self.settings.env,
            .headers = .{ .dynamic = .{ .ctx = self, .resolve_fn = resolveHeaders } },
            .transport = self.settings.transport,
            .include_usage = self.settings.include_usage,
            .supports_structured_outputs = true,
        });
        return compatible.embeddingModel(model_id, diag);
    }

    fn resolveHeaders(raw: ?*anyopaque) []const provider_utils.HeaderEntry {
        const self: *OpenRouter = @ptrCast(@alignCast(raw.?));
        return self.attribution[0..self.attribution_len];
    }
};

pub fn createOpenRouter(settings: Settings) OpenRouter {
    const configured = settings.base_url orelse settings.env.get("OPENROUTER_BASE_URL") orelse
        "https://openrouter.ai/api/v1";
    var result: OpenRouter = .{
        .settings = settings,
        .base_url = std.mem.trimEnd(u8, configured, "/"),
    };
    if (settings.http_referer) |value| {
        result.attribution[result.attribution_len] = .{ .name = "HTTP-Referer", .value = value };
        result.attribution_len += 1;
    }
    if (settings.x_title) |value| {
        result.attribution[result.attribution_len] = .{ .name = "X-Title", .value = value };
        result.attribution_len += 1;
    }
    return result;
}

test "factory uses defaults and preserves model ids verbatim" {
    const Dummy = struct {
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
    var marker: u8 = 0;
    const transport: provider_utils.HttpTransport = .{
        .ctx = &marker,
        .vtable = &.{ .request = Dummy.request },
    };
    var factory = createOpenRouter(.{
        .transport = transport,
        .http_referer = "https://example.com",
        .x_title = "Example",
    });
    const model = try factory.chatModel("vendor/model", null);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", factory.base_url);
    try std.testing.expectEqualStrings("vendor/model", model.model_id);
    try std.testing.expectEqualStrings("openrouter", model.config.provider_name);
    try std.testing.expectEqual(2, factory.attribution_len);
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
