//! Native Anthropic Messages provider.

const std = @import("std");
const provider = @import("provider");

pub const config = @import("config.zig");
pub const Settings = config.Settings;
pub const HeaderSource = config.HeaderSource;
pub const capabilities = @import("capabilities.zig");
pub const options = @import("options.zig");
pub const ModelCapabilities = capabilities.ModelCapabilities;
pub const getModelCapabilities = capabilities.getModelCapabilities;
pub const prompt = @import("prompt.zig");
pub const tools = @import("tools.zig");
pub const AnthropicLanguageModel = @import("language_model.zig").AnthropicLanguageModel;

pub const Anthropic = struct {
    settings: Settings,
    base_url: []const u8,

    pub fn messages(
        self: *const Anthropic,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!AnthropicLanguageModel {
        if (model_id.len == 0) return invalid(diag, "modelId", "Anthropic model id is required");
        if (self.settings.provider_name.len == 0) return invalid(diag, "name", "Anthropic provider name is required");
        return .{
            .model_id = model_id,
            .config = .{
                .base_url = self.base_url,
                .api_key = self.settings.api_key,
                .auth_token = self.settings.auth_token,
                .env = self.settings.env,
                .headers = self.settings.headers,
                .transport = self.settings.transport,
                .provider = self.settings.provider_name,
                .provider_options_name = providerOptionsName(self.settings.provider_name),
            },
        };
    }

    pub fn chat(
        self: *const Anthropic,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!AnthropicLanguageModel {
        return self.messages(model_id, diag);
    }

    pub fn languageModel(
        self: *const Anthropic,
        model_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!AnthropicLanguageModel {
        return self.messages(model_id, diag);
    }
};

pub fn createAnthropic(settings: Settings) error{InvalidArgumentError}!Anthropic {
    if (settings.api_key != null and settings.auth_token != null) return error.InvalidArgumentError;
    const configured = settings.base_url orelse settings.env.get("ANTHROPIC_BASE_URL") orelse
        "https://api.anthropic.com/v1";
    var base_url = std.mem.trimEnd(u8, configured, "/");
    if (std.mem.eql(u8, base_url, "https://api.anthropic.com")) {
        base_url = "https://api.anthropic.com/v1";
    }
    return .{ .settings = settings, .base_url = base_url };
}

fn providerOptionsName(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

fn invalid(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

test "factory normalizes official base URL and rejects explicit dual auth" {
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
    const factory = try createAnthropic(.{
        .base_url = "https://api.anthropic.com/",
        .transport = transport,
    });
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1", factory.base_url);
    try std.testing.expectError(error.InvalidArgumentError, createAnthropic(.{
        .api_key = "key",
        .auth_token = "token",
        .transport = transport,
    }));
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
