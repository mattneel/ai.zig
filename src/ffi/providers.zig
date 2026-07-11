const std = @import("std");
const anthropic = @import("anthropic");
const openai_compatible = @import("openai_compatible");
const openrouter = @import("openrouter");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const ProviderKind = enum {
    anthropic,
    openrouter,
    openai_compatible,
};

const ProviderStorage = union(ProviderKind) {
    anthropic: anthropic.Anthropic,
    openrouter: openrouter.OpenRouter,
    openai_compatible: openai_compatible.OpenAiCompatible,
};

pub const Provider = struct {
    runtime: *runtime_api.Runtime,
    refs: std.atomic.Value(usize),
    arena_state: std.heap.ArenaAllocator,
    transport: provider_utils.HttpClientTransport,
    storage: ProviderStorage,

    fn allocate(runtime: *runtime_api.Runtime) Allocator.Error!*Provider {
        const allocator = runtime.allocator();
        const self = try allocator.create(Provider);
        runtime.retain();
        self.runtime = runtime;
        self.refs = .init(1);
        self.arena_state = .init(allocator);
        self.transport = .init(allocator, runtime.io());
        return self;
    }

    pub fn retain(self: *Provider) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Provider) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const runtime = self.runtime;
        const allocator = runtime.allocator();
        self.transport.deinit();
        self.arena_state.deinit();
        allocator.destroy(self);
        runtime.release();
    }
};

const ModelStorage = union(enum) {
    anthropic: anthropic.AnthropicLanguageModel,
    compatible: openai_compatible.ChatLanguageModel,
};

pub const Model = struct {
    owner: *Provider,
    refs: std.atomic.Value(usize),
    arena_state: std.heap.ArenaAllocator,
    storage: ModelStorage,
    interface: provider.LanguageModel,

    pub fn retain(self: *Model) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Model) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const owner = self.owner;
        const allocator = owner.runtime.allocator();
        self.arena_state.deinit();
        allocator.destroy(self);
        owner.release();
    }
};

pub fn providerFromHandle(handle: *types.ai_provider) *Provider {
    return @ptrCast(@alignCast(handle));
}

pub fn modelFromHandle(handle: *types.ai_model) *Model {
    return @ptrCast(@alignCast(handle));
}

pub export fn ai_provider_anthropic(
    runtime_handle: ?*types.ai_runtime,
    config: [*c]const types.ai_anthropic_config,
    out: [*c]?*types.ai_provider,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    if (config == null) return runtime.invalid("Anthropic config is required", "config");
    const value = config[0];

    const handle = Provider.allocate(runtime) catch |err| return runtime.fail(err, null);
    const arena = handle.arena_state.allocator();
    const api_key = requiredOwned(arena, value.api_key_ptr, value.api_key_len) catch {
        const status = runtime.invalid("Anthropic apiKey is required", "apiKey");
        handle.release();
        return status;
    };
    const base_url = optionalOwned(arena, value.base_url_ptr, value.base_url_len) catch {
        const status = runtime.invalid("Anthropic baseURL pointer is invalid", "baseURL");
        handle.release();
        return status;
    };

    handle.storage = .{ .anthropic = anthropic.createAnthropic(.{
        .api_key = api_key,
        .base_url = base_url,
        .transport = handle.transport.transport(),
    }) catch |err| {
        const status = runtime.fail(err, null);
        handle.release();
        return status;
    } };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn ai_provider_openrouter(
    runtime_handle: ?*types.ai_runtime,
    config: [*c]const types.ai_openrouter_config,
    out: [*c]?*types.ai_provider,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    if (config == null) return runtime.invalid("OpenRouter config is required", "config");
    const value = config[0];

    const handle = Provider.allocate(runtime) catch |err| return runtime.fail(err, null);
    const arena = handle.arena_state.allocator();
    const api_key = requiredOwned(arena, value.api_key_ptr, value.api_key_len) catch {
        const status = runtime.invalid("OpenRouter apiKey is required", "apiKey");
        handle.release();
        return status;
    };
    const base_url = optionalOwned(arena, value.base_url_ptr, value.base_url_len) catch {
        const status = runtime.invalid("OpenRouter baseURL pointer is invalid", "baseURL");
        handle.release();
        return status;
    };
    const referer = optionalOwned(arena, value.referer_ptr, value.referer_len) catch {
        const status = runtime.invalid("OpenRouter referer pointer is invalid", "referer");
        handle.release();
        return status;
    };
    const title = optionalOwned(arena, value.title_ptr, value.title_len) catch {
        const status = runtime.invalid("OpenRouter title pointer is invalid", "title");
        handle.release();
        return status;
    };

    handle.storage = .{ .openrouter = openrouter.createOpenRouter(.{
        .api_key = api_key,
        .base_url = base_url,
        .http_referer = referer,
        .x_title = title,
        .transport = handle.transport.transport(),
        .include_usage = true,
    }) };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn ai_provider_openai_compatible(
    runtime_handle: ?*types.ai_runtime,
    config: [*c]const types.ai_openai_compatible_config,
    out: [*c]?*types.ai_provider,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    if (config == null) return runtime.invalid("OpenAI-compatible config is required", "config");
    const value = config[0];

    const handle = Provider.allocate(runtime) catch |err| return runtime.fail(err, null);
    const arena = handle.arena_state.allocator();
    const name = requiredOwned(arena, value.name_ptr, value.name_len) catch {
        const status = runtime.invalid("OpenAI-compatible name is required", "name");
        handle.release();
        return status;
    };
    const base_url = requiredOwned(arena, value.base_url_ptr, value.base_url_len) catch {
        const status = runtime.invalid("OpenAI-compatible baseURL is required", "baseURL");
        handle.release();
        return status;
    };
    const api_key = optionalOwned(arena, value.api_key_ptr, value.api_key_len) catch {
        const status = runtime.invalid("OpenAI-compatible apiKey pointer is invalid", "apiKey");
        handle.release();
        return status;
    };

    handle.storage = .{ .openai_compatible = openai_compatible.createOpenAiCompatible(.{
        .provider_name = name,
        .base_url = base_url,
        .api_key = api_key,
        .transport = handle.transport.transport(),
        .include_usage = true,
    }) };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn ai_provider_destroy(handle: ?*types.ai_provider) void {
    const value = handle orelse return;
    providerFromHandle(value).release();
}

pub export fn ai_provider_language_model(
    provider_handle: ?*types.ai_provider,
    model_id_ptr: [*c]const u8,
    model_id_len: usize,
    out: [*c]?*types.ai_model,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const owner = if (provider_handle) |value| providerFromHandle(value) else return .invalid_argument;
    const runtime = owner.runtime;
    const model_id = requiredSlice(model_id_ptr, model_id_len) catch
        return runtime.invalid("modelId is required", "modelId");

    const allocator = runtime.allocator();
    const self = allocator.create(Model) catch |err| return runtime.fail(err, null);
    owner.retain();
    self.owner = owner;
    self.refs = .init(1);
    self.arena_state = .init(allocator);
    const owned_id = self.arena_state.allocator().dupe(u8, model_id) catch |err| {
        const status = runtime.fail(err, null);
        cleanupModelInit(self);
        return status;
    };
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();

    self.storage = switch (owner.storage) {
        .anthropic => |*factory| .{ .anthropic = factory.languageModel(owned_id, &diagnostics) catch |err| {
            const status = runtime.fail(err, &diagnostics);
            cleanupModelInit(self);
            return status;
        } },
        .openrouter => |*factory| .{ .compatible = factory.languageModel(owned_id, &diagnostics) catch |err| {
            const status = runtime.fail(err, &diagnostics);
            cleanupModelInit(self);
            return status;
        } },
        .openai_compatible => |*factory| .{ .compatible = factory.languageModel(owned_id, &diagnostics) catch |err| {
            const status = runtime.fail(err, &diagnostics);
            cleanupModelInit(self);
            return status;
        } },
    };
    self.interface = switch (self.storage) {
        .anthropic => |*model| model.languageModel(),
        .compatible => |*model| model.languageModel(),
    };
    out.* = @ptrCast(self);
    return .ok;
}

pub export fn ai_model_destroy(handle: ?*types.ai_model) void {
    const value = handle orelse return;
    modelFromHandle(value).release();
}

fn cleanupModelInit(self: *Model) void {
    const owner = self.owner;
    const allocator = owner.runtime.allocator();
    self.arena_state.deinit();
    allocator.destroy(self);
    owner.release();
}

fn requiredOwned(arena: Allocator, ptr: [*c]const u8, len: usize) ![]const u8 {
    const value = try requiredSlice(ptr, len);
    return arena.dupe(u8, value);
}

fn optionalOwned(arena: Allocator, ptr: [*c]const u8, len: usize) !?[]const u8 {
    if (len == 0) return null;
    if (ptr == null) return error.InvalidArgumentError;
    return @as(?[]const u8, try arena.dupe(u8, ptr[0..len]));
}

pub fn requiredSlice(ptr: [*c]const u8, len: usize) ![]const u8 {
    if (ptr == null or len == 0) return error.InvalidArgumentError;
    return ptr[0..len];
}

pub fn optionalSlice(ptr: [*c]const u8, len: usize) ![]const u8 {
    if (len == 0) return "";
    if (ptr == null) return error.InvalidArgumentError;
    return ptr[0..len];
}

test "provider validation failure releases its partial runtime allocation" {
    runtime_api.last_runtime_deinit_clean.store(false, .release);
    var runtime_handle: ?*types.ai_runtime = null;
    try std.testing.expectEqual(
        types.Status.ok,
        runtime_api.ai_runtime_create(null, &runtime_handle),
    );
    const config: types.ai_openai_compatible_config = .{
        .name_ptr = null,
        .name_len = 0,
        .base_url_ptr = "http://127.0.0.1".ptr,
        .base_url_len = "http://127.0.0.1".len,
        .api_key_ptr = null,
        .api_key_len = 0,
    };
    var provider_handle: ?*types.ai_provider = null;
    try std.testing.expectEqual(
        types.Status.invalid_argument,
        ai_provider_openai_compatible(runtime_handle, &config, &provider_handle),
    );
    try std.testing.expect(provider_handle == null);
    runtime_api.ai_runtime_destroy(runtime_handle);
    try std.testing.expect(runtime_api.last_runtime_deinit_clean.load(.acquire));
}
