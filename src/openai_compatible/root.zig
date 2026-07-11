//! OpenAI-compatible Chat Completions provider template.

const std = @import("std");
const provider = @import("provider");

pub const config = @import("config.zig");
pub const Settings = config.Settings;
pub const Config = config.Config;
pub const HeaderSource = config.HeaderSource;
pub const QueryParam = config.QueryParam;
pub const ErrorHooks = config.ErrorHooks;
pub const ChatLanguageModel = @import("chat_language_model.zig").ChatLanguageModel;
pub const EmbeddingModel = @import("embedding_model.zig").EmbeddingModel;

pub const OpenAiCompatible = struct {
    settings: Settings,

    pub fn chatModel(
        self: *const OpenAiCompatible,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ChatLanguageModel {
        if (self.settings.provider_name.len == 0) {
            return config.invalidSettings(diag, "name", "OpenAI-compatible provider name is required");
        }
        if (self.settings.base_url.len == 0) {
            return config.invalidSettings(diag, "baseURL", "OpenAI-compatible base URL is required");
        }
        if (model_id.len == 0) {
            return config.invalidSettings(diag, "modelId", "Model id is required");
        }

        const base_url = std.mem.trimEnd(u8, self.settings.base_url, "/");
        return .{
            .model_id = model_id,
            .config = .{
                .provider = self.settings.provider_name,
                .provider_name = providerOptionsName(self.settings.provider_name),
                .base_url = base_url,
                .api_key = self.settings.api_key,
                .api_key_env_var = self.settings.api_key_env_var,
                .env = self.settings.env,
                .headers = self.settings.headers,
                .query_params = self.settings.query_params,
                .transport = self.settings.transport,
                .include_usage = self.settings.include_usage,
                .supports_structured_outputs = self.settings.supports_structured_outputs,
                .error_hooks = self.settings.error_hooks,
            },
        };
    }

    pub fn languageModel(
        self: *const OpenAiCompatible,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ChatLanguageModel {
        return self.chatModel(model_id, diag);
    }

    pub fn embeddingModel(
        self: *const OpenAiCompatible,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!EmbeddingModel {
        if (self.settings.provider_name.len == 0) {
            return config.invalidSettings(diag, "name", "OpenAI-compatible provider name is required");
        }
        if (self.settings.base_url.len == 0) {
            return config.invalidSettings(diag, "baseURL", "OpenAI-compatible base URL is required");
        }
        if (model_id.len == 0) {
            return config.invalidSettings(diag, "modelId", "Model id is required");
        }
        return .{
            .model_id = model_id,
            .config = .{
                .provider = self.settings.provider_name,
                .provider_name = providerOptionsName(self.settings.provider_name),
                .base_url = std.mem.trimEnd(u8, self.settings.base_url, "/"),
                .api_key = self.settings.api_key,
                .api_key_env_var = self.settings.api_key_env_var,
                .env = self.settings.env,
                .headers = self.settings.headers,
                .query_params = self.settings.query_params,
                .transport = self.settings.transport,
                .include_usage = self.settings.include_usage,
                .supports_structured_outputs = self.settings.supports_structured_outputs,
                .max_embeddings_per_call = self.settings.max_embeddings_per_call,
                .supports_parallel_embedding_calls = self.settings.supports_parallel_embedding_calls,
                .error_hooks = self.settings.error_hooks,
            },
        };
    }
};

pub fn createOpenAiCompatible(settings: Settings) OpenAiCompatible {
    return .{ .settings = settings };
}

/// Alias matching the upstream package's capitalization.
pub const createOpenAICompatible = createOpenAiCompatible;

fn providerOptionsName(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return std.mem.trim(u8, name, " \t\r\n");
    return std.mem.trim(u8, name[0..dot], " \t\r\n");
}

test "factory normalizes the provider namespace and trailing slash" {
    const Dummy = struct {
        fn request(
            _: *anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: @import("provider_utils").RequestSpec,
            _: ?*provider.Diagnostics,
        ) @import("provider_utils").RequestError!@import("provider_utils").Response {
            return error.APICallError;
        }
    };
    var marker: u8 = 0;
    const transport: @import("provider_utils").HttpTransport = .{
        .ctx = &marker,
        .vtable = &.{ .request = Dummy.request },
    };
    const factory = createOpenAiCompatible(.{
        .provider_name = "vendor.chat.custom",
        .base_url = "https://example.test/v1///",
        .transport = transport,
    });
    const model = try factory.chatModel("vendor/model", null);
    try std.testing.expectEqualStrings("vendor", model.config.provider_name);
    try std.testing.expectEqualStrings("https://example.test/v1", model.config.base_url);
    try std.testing.expectEqualStrings("vendor/model", model.model_id);
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
