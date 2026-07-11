//! Mirrors the Vercel AI SDK `ai` core package.

const std = @import("std");

pub const message = @import("message.zig");
pub const tool = @import("tool.zig");
pub const events = @import("events.zig");
pub const telemetry = @import("telemetry.zig");
pub const logger = @import("logger.zig");
pub const prompt = @import("prompt.zig");
pub const middleware = @import("middleware.zig");
pub const registry = @import("registry.zig");

pub const ModelMessage = message.ModelMessage;
pub const Tool = tool.Tool;
pub const NamedTool = tool.NamedTool;
pub const ToolSet = tool.ToolSet;
pub const Telemetry = telemetry.Telemetry;
pub const TelemetryOptions = telemetry.TelemetryOptions;
pub const TelemetryDispatcher = telemetry.Dispatcher;
pub const registerTelemetry = telemetry.registerTelemetry;
pub const clearTelemetryRegistry = telemetry.clearTelemetryRegistry;
pub const createTelemetryDispatcher = telemetry.createTelemetryDispatcher;
pub const logWarnings = logger.logWarnings;
pub const standardizePrompt = prompt.standardizePrompt;
pub const convertToLanguageModelPrompt = prompt.convertToLanguageModelPrompt;
pub const LanguageModelMiddleware = middleware.LanguageModelMiddleware;
pub const wrapLanguageModel = middleware.wrapLanguageModel;
pub const ProviderRegistry = registry.ProviderRegistry;
pub const createProviderRegistry = registry.createProviderRegistry;
pub const customProvider = registry.customProvider;
pub const LanguageModelRef = registry.LanguageModelRef;
pub const resolveLanguageModel = registry.resolveLanguageModel;
pub const setDefaultProvider = registry.setDefaultProvider;
pub const setDefaultEnv = registry.setDefaultEnv;
pub const setDefaultRuntime = registry.setDefaultRuntime;
pub const useOpenRouterDefault = registry.useOpenRouterDefault;

test "module declarations" {
    std.testing.refAllDecls(@This());
}
