const std = @import("std");
const anthropic = @import("anthropic");
const openai = @import("openai");
const openai_compatible = @import("openai_compatible");
const openrouter = @import("openrouter");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");
const xai = @import("xai");

const Allocator = std.mem.Allocator;

const ProviderKind = enum {
    anthropic,
    openrouter,
    openai_compatible,
    openai,
    xai,
};

const NativeOpenAi = struct {
    factory: openai.OpenAi,
    language_api: types.OpenAiLanguageApi,
};

const ProviderStorage = union(ProviderKind) {
    anthropic: anthropic.Anthropic,
    openrouter: openrouter.OpenRouter,
    openai_compatible: openai_compatible.OpenAiCompatible,
    openai: NativeOpenAi,
    xai: xai.Xai,
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
    openai_chat: openai.ChatLanguageModel,
    openai_responses: openai.ResponsesLanguageModel,
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

fn OwnedModel(comptime Interface: type) type {
    return struct {
        owner: *Provider,
        refs: std.atomic.Value(usize),
        arena_state: std.heap.ArenaAllocator,
        interface: Interface,

        const Self = @This();

        pub fn retain(self: *Self) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *Self) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            const owner = self.owner;
            const allocator = owner.runtime.allocator();
            self.arena_state.deinit();
            allocator.destroy(self);
            owner.release();
        }
    };
}

pub const EmbeddingModel = OwnedModel(provider.EmbeddingModel);
pub const ImageModel = OwnedModel(provider.ImageModel);
pub const SpeechModel = OwnedModel(provider.SpeechModel);
pub const TranscriptionModel = OwnedModel(provider.TranscriptionModel);

pub fn providerFromHandle(handle: *types.ai_provider) *Provider {
    return @ptrCast(@alignCast(handle));
}

pub fn modelFromHandle(handle: *types.ai_model) *Model {
    return @ptrCast(@alignCast(handle));
}

pub fn embeddingModelFromHandle(handle: *types.ai_embedding_model) *EmbeddingModel {
    return @ptrCast(@alignCast(handle));
}

pub fn imageModelFromHandle(handle: *types.ai_image_model) *ImageModel {
    return @ptrCast(@alignCast(handle));
}

pub fn speechModelFromHandle(handle: *types.ai_speech_model) *SpeechModel {
    return @ptrCast(@alignCast(handle));
}

pub fn transcriptionModelFromHandle(handle: *types.ai_transcription_model) *TranscriptionModel {
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
    const value = types.readStruct(types.ai_anthropic_config, config) catch
        return runtime.invalid("Anthropic config struct_size is too small", "config.structSize");

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
    const value = types.readStruct(types.ai_openrouter_config, config) catch
        return runtime.invalid("OpenRouter config struct_size is too small", "config.structSize");

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
    const value = types.readStruct(types.ai_openai_compatible_config, config) catch
        return runtime.invalid("OpenAI-compatible config struct_size is too small", "config.structSize");

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

pub export fn ai_provider_openai(
    runtime_handle: ?*types.ai_runtime,
    config: [*c]const types.ai_openai_config,
    out: [*c]?*types.ai_provider,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    if (config == null) return runtime.invalid("OpenAI config is required", "config");
    const value = types.readStruct(types.ai_openai_config, config) catch
        return runtime.invalid("OpenAI config struct_size is too small", "config.structSize");
    if (value.language_api != .responses and value.language_api != .chat) {
        return runtime.invalid("OpenAI languageApi is unknown", "languageApi");
    }

    const handle = Provider.allocate(runtime) catch |err| return runtime.fail(err, null);
    const arena = handle.arena_state.allocator();
    const api_key = requiredOwned(arena, value.api_key_ptr, value.api_key_len) catch {
        const status = runtime.invalid("OpenAI apiKey is required", "apiKey");
        handle.release();
        return status;
    };
    const base_url = optionalOwned(arena, value.base_url_ptr, value.base_url_len) catch {
        const status = runtime.invalid("OpenAI baseURL pointer is invalid", "baseURL");
        handle.release();
        return status;
    };
    const organization = optionalOwned(arena, value.organization_ptr, value.organization_len) catch {
        const status = runtime.invalid("OpenAI organization pointer is invalid", "organization");
        handle.release();
        return status;
    };
    const project = optionalOwned(arena, value.project_ptr, value.project_len) catch {
        const status = runtime.invalid("OpenAI project pointer is invalid", "project");
        handle.release();
        return status;
    };

    handle.storage = .{ .openai = .{
        .factory = openai.createOpenAi(.{
            .allocator = runtime.allocator(),
            .api_key = api_key,
            .base_url = base_url,
            .organization = organization,
            .project = project,
            .transport = handle.transport.transport(),
        }),
        .language_api = value.language_api,
    } };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn ai_provider_xai(
    runtime_handle: ?*types.ai_runtime,
    config: [*c]const types.ai_xai_config,
    out: [*c]?*types.ai_provider,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    if (config == null) return runtime.invalid("xAI config is required", "config");
    const value = types.readStruct(types.ai_xai_config, config) catch
        return runtime.invalid("xAI config struct_size is too small", "config.structSize");

    const handle = Provider.allocate(runtime) catch |err| return runtime.fail(err, null);
    const arena = handle.arena_state.allocator();
    const api_key = requiredOwned(arena, value.api_key_ptr, value.api_key_len) catch {
        const status = runtime.invalid("xAI apiKey is required", "apiKey");
        handle.release();
        return status;
    };
    const base_url = optionalOwned(arena, value.base_url_ptr, value.base_url_len) catch {
        const status = runtime.invalid("xAI baseURL pointer is invalid", "baseURL");
        handle.release();
        return status;
    };

    handle.storage = .{ .xai = xai.createXai(.{
        .allocator = runtime.allocator(),
        .api_key = api_key,
        .base_url = base_url,
        .transport = handle.transport.transport(),
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
        .openai => |*native| switch (native.language_api) {
            .chat => .{ .openai_chat = native.factory.chat(owned_id, &diagnostics) catch |err| {
                const status = runtime.fail(err, &diagnostics);
                cleanupModelInit(self);
                return status;
            } },
            .responses => .{ .openai_responses = native.factory.responses(owned_id, &diagnostics) catch |err| {
                const status = runtime.fail(err, &diagnostics);
                cleanupModelInit(self);
                return status;
            } },
            .unknown, _ => unreachable,
        },
        .xai => |*factory| .{ .compatible = factory.languageModel(owned_id, &diagnostics) catch |err| {
            const status = runtime.fail(err, &diagnostics);
            cleanupModelInit(self);
            return status;
        } },
    };
    self.interface = switch (self.storage) {
        .anthropic => |*model| model.languageModel(),
        .compatible => |*model| model.languageModel(),
        .openai_chat => |*model| model.languageModel(),
        .openai_responses => |*model| model.languageModel(),
    };
    out.* = @ptrCast(self);
    return .ok;
}

pub export fn ai_model_destroy(handle: ?*types.ai_model) void {
    const value = handle orelse return;
    modelFromHandle(value).release();
}

pub export fn ai_provider_embedding_model(
    provider_handle: ?*types.ai_provider,
    model_id_ptr: [*c]const u8,
    model_id_len: usize,
    out: [*c]?*types.ai_embedding_model,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const owner = if (provider_handle) |value| providerFromHandle(value) else return .invalid_argument;
    const runtime = owner.runtime;
    const model_id = requiredSlice(model_id_ptr, model_id_len) catch
        return runtime.invalid("modelId is required", "modelId");
    const self = allocateOwnedModel(EmbeddingModel, owner) catch |err| return runtime.fail(err, null);
    const arena = self.arena_state.allocator();
    const owned_id = arena.dupe(u8, model_id) catch |err| {
        const status = runtime.fail(err, null);
        cleanupOwnedModel(EmbeddingModel, self);
        return status;
    };
    var diagnostics = provider.Diagnostics.init(runtime.allocator());
    defer diagnostics.deinit();

    self.interface = switch (owner.storage) {
        .openrouter => |*factory| blk: {
            const concrete = arena.create(openai_compatible.EmbeddingModel) catch |err| {
                const status = runtime.fail(err, null);
                cleanupOwnedModel(EmbeddingModel, self);
                return status;
            };
            concrete.* = factory.embeddingModel(owned_id, &diagnostics) catch |err| {
                const status = runtime.fail(err, &diagnostics);
                cleanupOwnedModel(EmbeddingModel, self);
                return status;
            };
            break :blk concrete.embeddingModel();
        },
        .openai_compatible => |*factory| blk: {
            const concrete = arena.create(openai_compatible.EmbeddingModel) catch |err| {
                const status = runtime.fail(err, null);
                cleanupOwnedModel(EmbeddingModel, self);
                return status;
            };
            concrete.* = factory.embeddingModel(owned_id, &diagnostics) catch |err| {
                const status = runtime.fail(err, &diagnostics);
                cleanupOwnedModel(EmbeddingModel, self);
                return status;
            };
            break :blk concrete.embeddingModel();
        },
        .openai => |*native| blk: {
            const concrete = arena.create(openai.EmbeddingModel) catch |err| {
                const status = runtime.fail(err, null);
                cleanupOwnedModel(EmbeddingModel, self);
                return status;
            };
            concrete.* = native.factory.embeddingModel(owned_id, &diagnostics) catch |err| {
                const status = runtime.fail(err, &diagnostics);
                cleanupOwnedModel(EmbeddingModel, self);
                return status;
            };
            break :blk concrete.embeddingModel();
        },
        else => {
            const status = noSuchModel(runtime, &diagnostics, owned_id, .embedding_model);
            cleanupOwnedModel(EmbeddingModel, self);
            return status;
        },
    };
    out.* = @ptrCast(self);
    return .ok;
}

pub export fn ai_embedding_model_destroy(handle: ?*types.ai_embedding_model) void {
    const value = handle orelse return;
    embeddingModelFromHandle(value).release();
}

pub export fn ai_provider_image_model(
    provider_handle: ?*types.ai_provider,
    model_id_ptr: [*c]const u8,
    model_id_len: usize,
    out: [*c]?*types.ai_image_model,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const owner = if (provider_handle) |value| providerFromHandle(value) else return .invalid_argument;
    const runtime = owner.runtime;
    const model_id = requiredSlice(model_id_ptr, model_id_len) catch
        return runtime.invalid("modelId is required", "modelId");
    const self = allocateOwnedModel(ImageModel, owner) catch |err| return runtime.fail(err, null);
    const arena = self.arena_state.allocator();
    const owned_id = arena.dupe(u8, model_id) catch |err| {
        const status = runtime.fail(err, null);
        cleanupOwnedModel(ImageModel, self);
        return status;
    };
    var diagnostics = provider.Diagnostics.init(runtime.allocator());
    defer diagnostics.deinit();
    self.interface = switch (owner.storage) {
        .openai => |*native| blk: {
            const concrete = arena.create(openai.ImageModel) catch |err| {
                const status = runtime.fail(err, null);
                cleanupOwnedModel(ImageModel, self);
                return status;
            };
            concrete.* = native.factory.imageModel(owned_id, &diagnostics) catch |err| {
                const status = runtime.fail(err, &diagnostics);
                cleanupOwnedModel(ImageModel, self);
                return status;
            };
            break :blk concrete.imageModel();
        },
        else => {
            const status = noSuchModel(runtime, &diagnostics, owned_id, .image_model);
            cleanupOwnedModel(ImageModel, self);
            return status;
        },
    };
    out.* = @ptrCast(self);
    return .ok;
}

pub export fn ai_image_model_destroy(handle: ?*types.ai_image_model) void {
    const value = handle orelse return;
    imageModelFromHandle(value).release();
}

pub export fn ai_provider_speech_model(
    provider_handle: ?*types.ai_provider,
    model_id_ptr: [*c]const u8,
    model_id_len: usize,
    out: [*c]?*types.ai_speech_model,
) types.Status {
    return createOpenAiMediaModel(
        SpeechModel,
        types.ai_speech_model,
        provider.SpeechModel,
        provider_handle,
        model_id_ptr,
        model_id_len,
        out,
        .speech_model,
        openai.SpeechModel,
        struct {
            fn create(factory: *openai.OpenAi, id: []const u8, diag: *provider.Diagnostics) provider.Error!openai.SpeechModel {
                return factory.speechModel(id, diag);
            }
            fn interface(model: *openai.SpeechModel) provider.SpeechModel {
                return model.speechModel();
            }
        },
    );
}

pub export fn ai_speech_model_destroy(handle: ?*types.ai_speech_model) void {
    const value = handle orelse return;
    speechModelFromHandle(value).release();
}

pub export fn ai_provider_transcription_model(
    provider_handle: ?*types.ai_provider,
    model_id_ptr: [*c]const u8,
    model_id_len: usize,
    out: [*c]?*types.ai_transcription_model,
) types.Status {
    return createOpenAiMediaModel(
        TranscriptionModel,
        types.ai_transcription_model,
        provider.TranscriptionModel,
        provider_handle,
        model_id_ptr,
        model_id_len,
        out,
        .transcription_model,
        openai.TranscriptionModel,
        struct {
            fn create(factory: *openai.OpenAi, id: []const u8, diag: *provider.Diagnostics) provider.Error!openai.TranscriptionModel {
                return factory.transcriptionModel(id, diag);
            }
            fn interface(model: *openai.TranscriptionModel) provider.TranscriptionModel {
                return model.transcriptionModel();
            }
        },
    );
}

pub export fn ai_transcription_model_destroy(handle: ?*types.ai_transcription_model) void {
    const value = handle orelse return;
    transcriptionModelFromHandle(value).release();
}

fn cleanupModelInit(self: *Model) void {
    const owner = self.owner;
    const allocator = owner.runtime.allocator();
    self.arena_state.deinit();
    allocator.destroy(self);
    owner.release();
}

fn allocateOwnedModel(comptime Handle: type, owner: *Provider) Allocator.Error!*Handle {
    const allocator = owner.runtime.allocator();
    const self = try allocator.create(Handle);
    owner.retain();
    self.owner = owner;
    self.refs = .init(1);
    self.arena_state = .init(allocator);
    return self;
}

fn cleanupOwnedModel(comptime Handle: type, self: *Handle) void {
    const owner = self.owner;
    const allocator = owner.runtime.allocator();
    self.arena_state.deinit();
    allocator.destroy(self);
    owner.release();
}

fn createOpenAiMediaModel(
    comptime Handle: type,
    comptime Opaque: type,
    comptime Interface: type,
    provider_handle: ?*types.ai_provider,
    model_id_ptr: [*c]const u8,
    model_id_len: usize,
    out: [*c]?*Opaque,
    model_type: provider.ModelType,
    comptime Concrete: type,
    comptime Operations: type,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const owner = if (provider_handle) |value| providerFromHandle(value) else return .invalid_argument;
    const runtime = owner.runtime;
    const model_id = requiredSlice(model_id_ptr, model_id_len) catch
        return runtime.invalid("modelId is required", "modelId");
    const self = allocateOwnedModel(Handle, owner) catch |err| return runtime.fail(err, null);
    const arena = self.arena_state.allocator();
    const owned_id = arena.dupe(u8, model_id) catch |err| {
        const status = runtime.fail(err, null);
        cleanupOwnedModel(Handle, self);
        return status;
    };
    var diagnostics = provider.Diagnostics.init(runtime.allocator());
    defer diagnostics.deinit();
    const native = switch (owner.storage) {
        .openai => |*value| value,
        else => {
            const status = noSuchModel(runtime, &diagnostics, owned_id, model_type);
            cleanupOwnedModel(Handle, self);
            return status;
        },
    };
    const concrete = arena.create(Concrete) catch |err| {
        const status = runtime.fail(err, null);
        cleanupOwnedModel(Handle, self);
        return status;
    };
    concrete.* = Operations.create(&native.factory, owned_id, &diagnostics) catch |err| {
        const status = runtime.fail(err, &diagnostics);
        cleanupOwnedModel(Handle, self);
        return status;
    };
    self.interface = @as(Interface, Operations.interface(concrete));
    out.* = @ptrCast(self);
    return .ok;
}

fn noSuchModel(
    runtime: *runtime_api.Runtime,
    diagnostics: *provider.Diagnostics,
    model_id: []const u8,
    model_type: provider.ModelType,
) types.Status {
    provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .no_such_model = .{
        .message = "provider does not expose this model type",
        .model_id = model_id,
        .model_type = model_type,
    } });
    return runtime.fail(error.NoSuchModelError, diagnostics);
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
        .struct_size = @sizeOf(types.ai_openai_compatible_config),
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
