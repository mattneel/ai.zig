//! Provider registries, custom providers, and language-model resolution.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const openrouter = @import("openrouter");
const build_options = @import("ai_build_options");
const middleware = @import("middleware.zig");

const Allocator = std.mem.Allocator;

pub const ProviderEntry = struct {
    id: []const u8,
    provider: provider.Provider,
};

pub const ProviderRegistryOptions = struct {
    providers: []const ProviderEntry,
    separator: []const u8 = ":",
    language_model_middleware: ?[]const middleware.LanguageModelMiddleware = null,
};

pub const ProviderRegistry = struct {
    arena: Allocator,
    providers: []const ProviderEntry,
    separator: []const u8,
    language_model_middleware: ?[]const middleware.LanguageModelMiddleware,

    pub fn languageModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) anyerror!provider.LanguageModel {
        const split = try self.splitId(id, .language_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .language_model, diag);
        var model = selected.languageModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => return noSuchModel(self.arena, diag, id, .language_model, null),
            else => |other| return other,
        };
        if (self.language_model_middleware) |middlewares| {
            model = try middleware.wrapLanguageModel(self.arena, model, middlewares);
        }
        return model;
    }

    pub fn embeddingModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.EmbeddingModel {
        const split = try self.splitId(id, .embedding_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .embedding_model, diag);
        return selected.embeddingModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => noSuchModel(self.arena, diag, id, .embedding_model, null),
            else => |other| other,
        };
    }

    pub fn imageModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.ImageModel {
        const split = try self.splitId(id, .image_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .image_model, diag);
        return selected.imageModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => noSuchModel(self.arena, diag, id, .image_model, null),
            else => |other| other,
        };
    }

    pub fn transcriptionModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.TranscriptionModel {
        const split = try self.splitId(id, .transcription_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .transcription_model, diag);
        return selected.transcriptionModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => noSuchModel(self.arena, diag, id, .transcription_model, null),
            else => |other| other,
        };
    }

    pub fn speechModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.SpeechModel {
        const split = try self.splitId(id, .speech_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .speech_model, diag);
        return selected.speechModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => noSuchModel(self.arena, diag, id, .speech_model, null),
            else => |other| other,
        };
    }

    pub fn rerankingModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.RerankingModel {
        const split = try self.splitId(id, .reranking_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .reranking_model, diag);
        return selected.rerankingModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => noSuchModel(self.arena, diag, id, .reranking_model, null),
            else => |other| other,
        };
    }

    pub fn videoModel(
        self: *ProviderRegistry,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.VideoModel {
        const split = try self.splitId(id, .video_model, diag);
        const selected = try self.getProvider(split.provider_id, id, .video_model, diag);
        return selected.videoModel(split.model_id, diag) catch |err| switch (err) {
            error.NoSuchModelError => noSuchModel(self.arena, diag, id, .video_model, null),
            else => |other| other,
        };
    }

    pub fn files(
        self: *ProviderRegistry,
        provider_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.Files {
        const selected = try self.getProvider(provider_id, provider_id, .language_model, diag);
        return selected.files(diag);
    }

    pub fn skills(
        self: *ProviderRegistry,
        provider_id: []const u8,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.Skills {
        const selected = try self.getProvider(provider_id, provider_id, .language_model, diag);
        return selected.skills(diag);
    }

    pub fn asProvider(self: *ProviderRegistry) provider.Provider {
        return .{ .ctx = self, .vtable = &provider_vtable };
    }

    const Split = struct { provider_id: []const u8, model_id: []const u8 };

    fn splitId(
        self: *const ProviderRegistry,
        id: []const u8,
        model_type: provider.ModelType,
        diag: ?*provider.Diagnostics,
    ) provider.Error!Split {
        const index = std.mem.indexOf(u8, id, self.separator) orelse
            return noSuchModel(self.arena, diag, id, model_type, self.separator);
        return .{
            .provider_id = id[0..index],
            .model_id = id[index + self.separator.len ..],
        };
    }

    fn getProvider(
        self: *const ProviderRegistry,
        provider_id: []const u8,
        model_id: []const u8,
        model_type: provider.ModelType,
        diag: ?*provider.Diagnostics,
    ) provider.Error!provider.Provider {
        for (self.providers) |entry| {
            if (std.mem.eql(u8, entry.id, provider_id)) return entry.provider;
        }
        return noSuchProvider(self.arena, diag, model_id, model_type, provider_id, self.providers);
    }

    const provider_vtable: provider.Provider.VTable = .{
        .languageModel = vLanguageModel,
        .embeddingModel = vEmbeddingModel,
        .imageModel = vImageModel,
        .transcriptionModel = vTranscriptionModel,
        .speechModel = vSpeechModel,
        .rerankingModel = vRerankingModel,
        .videoModel = vVideoModel,
    };

    fn fromRaw(raw: *anyopaque) *ProviderRegistry {
        return @ptrCast(@alignCast(raw));
    }
    fn vLanguageModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.LanguageModel {
        return fromRaw(raw).languageModel(id, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.InvalidArgumentError,
            else => |other| return other,
        };
    }
    fn vEmbeddingModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.EmbeddingModel {
        return fromRaw(raw).embeddingModel(id, diag);
    }
    fn vImageModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.ImageModel {
        return fromRaw(raw).imageModel(id, diag);
    }
    fn vTranscriptionModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.TranscriptionModel {
        return fromRaw(raw).transcriptionModel(id, diag);
    }
    fn vSpeechModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.SpeechModel {
        return fromRaw(raw).speechModel(id, diag);
    }
    fn vRerankingModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.RerankingModel {
        return fromRaw(raw).rerankingModel(id, diag);
    }
    fn vVideoModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.VideoModel {
        return fromRaw(raw).videoModel(id, diag);
    }
};

pub fn createProviderRegistry(arena: Allocator, options: ProviderRegistryOptions) ProviderRegistry {
    return .{
        .arena = arena,
        .providers = options.providers,
        .separator = options.separator,
        .language_model_middleware = options.language_model_middleware,
    };
}

pub const LanguageModelRef = union(enum) {
    id: []const u8,
    model: provider.LanguageModel,
};

pub const EmbeddingModelRef = union(enum) {
    id: []const u8,
    model: provider.EmbeddingModel,
};

pub const RerankingModelRef = union(enum) {
    id: []const u8,
    model: provider.RerankingModel,
};

pub const ImageModelRef = union(enum) {
    id: []const u8,
    model: provider.ImageModel,
};

pub const SpeechModelRef = union(enum) {
    id: []const u8,
    model: provider.SpeechModel,
};

pub const TranscriptionModelRef = union(enum) {
    id: []const u8,
    model: provider.TranscriptionModel,
};

pub const VideoModelRef = union(enum) {
    id: []const u8,
    model: provider.VideoModel,
};

pub const LanguageModelEntry = struct { id: []const u8, model: LanguageModelRef };
pub const EmbeddingModelEntry = struct { id: []const u8, model: provider.EmbeddingModel };
pub const ImageModelEntry = struct { id: []const u8, model: provider.ImageModel };
pub const TranscriptionModelEntry = struct { id: []const u8, model: provider.TranscriptionModel };
pub const SpeechModelEntry = struct { id: []const u8, model: provider.SpeechModel };
pub const RerankingModelEntry = struct { id: []const u8, model: provider.RerankingModel };
pub const VideoModelEntry = struct { id: []const u8, model: provider.VideoModel };

pub const CustomProviderOptions = struct {
    language_models: []const LanguageModelEntry = &.{},
    embedding_models: []const EmbeddingModelEntry = &.{},
    image_models: []const ImageModelEntry = &.{},
    transcription_models: []const TranscriptionModelEntry = &.{},
    speech_models: []const SpeechModelEntry = &.{},
    reranking_models: []const RerankingModelEntry = &.{},
    video_models: []const VideoModelEntry = &.{},
    files_api: ?provider.Files = null,
    skills_api: ?provider.Skills = null,
    fallback_provider: ?provider.Provider = null,
};

pub const CustomProvider = struct {
    options: CustomProviderOptions,

    pub fn asProvider(self: *CustomProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .languageModel = languageModel,
        .embeddingModel = embeddingModel,
        .imageModel = imageModel,
        .transcriptionModel = transcriptionModel,
        .speechModel = speechModel,
        .rerankingModel = rerankingModel,
        .videoModel = videoModel,
        .files = files,
        .skills = skills,
    };

    fn fromRaw(raw: *anyopaque) *CustomProvider {
        return @ptrCast(@alignCast(raw));
    }

    fn languageModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.LanguageModel {
        const self = fromRaw(raw);
        for (self.options.language_models) |entry| if (std.mem.eql(u8, entry.id, id)) {
            return resolveLanguageModel(entry.model, diag) catch |err| switch (err) {
                error.OutOfMemory => return error.InvalidArgumentError,
                else => |other| return other,
            };
        };
        if (self.options.fallback_provider) |fallback| return fallback.languageModel(id, diag);
        return noSuchModelFromDiag(diag, id, .language_model);
    }

    fn embeddingModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.EmbeddingModel {
        const self = fromRaw(raw);
        for (self.options.embedding_models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.model;
        if (self.options.fallback_provider) |fallback| return fallback.embeddingModel(id, diag);
        return noSuchModelFromDiag(diag, id, .embedding_model);
    }

    fn imageModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.ImageModel {
        const self = fromRaw(raw);
        for (self.options.image_models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.model;
        if (self.options.fallback_provider) |fallback| return fallback.imageModel(id, diag);
        return noSuchModelFromDiag(diag, id, .image_model);
    }

    fn transcriptionModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.TranscriptionModel {
        const self = fromRaw(raw);
        for (self.options.transcription_models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.model;
        if (self.options.fallback_provider) |fallback| return fallback.transcriptionModel(id, diag);
        return noSuchModelFromDiag(diag, id, .transcription_model);
    }

    fn speechModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.SpeechModel {
        const self = fromRaw(raw);
        for (self.options.speech_models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.model;
        if (self.options.fallback_provider) |fallback| return fallback.speechModel(id, diag);
        return noSuchModelFromDiag(diag, id, .speech_model);
    }

    fn rerankingModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.RerankingModel {
        const self = fromRaw(raw);
        for (self.options.reranking_models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.model;
        if (self.options.fallback_provider) |fallback| return fallback.rerankingModel(id, diag);
        return noSuchModelFromDiag(diag, id, .reranking_model);
    }

    fn videoModel(raw: *anyopaque, id: []const u8, diag: ?*provider.Diagnostics) provider.Error!provider.VideoModel {
        const self = fromRaw(raw);
        for (self.options.video_models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.model;
        if (self.options.fallback_provider) |fallback| return fallback.videoModel(id, diag);
        return noSuchModelFromDiag(diag, id, .video_model);
    }

    fn files(raw: *anyopaque, diag: ?*provider.Diagnostics) provider.Error!provider.Files {
        const self = fromRaw(raw);
        if (self.options.files_api) |files_api| return files_api;
        if (self.options.fallback_provider) |fallback| return fallback.files(diag);
        return error.UnsupportedFunctionalityError;
    }

    fn skills(raw: *anyopaque, diag: ?*provider.Diagnostics) provider.Error!provider.Skills {
        const self = fromRaw(raw);
        if (self.options.skills_api) |skills_api| return skills_api;
        if (self.options.fallback_provider) |fallback| return fallback.skills(diag);
        return error.UnsupportedFunctionalityError;
    }
};

pub fn customProvider(options: CustomProviderOptions) CustomProvider {
    return .{ .options = options };
}

const DefaultRuntime = struct {
    gpa: Allocator,
    io: std.Io,
};

const BuiltinOpenRouter = struct {
    arena: std.heap.ArenaAllocator,
    transport: provider_utils.HttpClientTransport,
    factory: openrouter.OpenRouter,

    fn init(runtime: DefaultRuntime, env: provider_utils.EnvLookup) Allocator.Error!*BuiltinOpenRouter {
        const self = try runtime.gpa.create(BuiltinOpenRouter);
        self.arena = .init(runtime.gpa);
        self.transport = provider_utils.HttpClientTransport.init(runtime.gpa, runtime.io);
        self.factory = openrouter.createOpenRouter(.{
            .env = env,
            .transport = self.transport.transport(),
        });
        return self;
    }

    fn deinit(self: *BuiltinOpenRouter, gpa: Allocator) void {
        self.transport.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn languageModel(
        self: *BuiltinOpenRouter,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) (provider.Error || Allocator.Error)!provider.LanguageModel {
        const model = try self.factory.languageModel(id, diag);
        const stored = try self.arena.allocator().create(@TypeOf(model));
        stored.* = model;
        return stored.languageModel();
    }

    fn embeddingModel(
        self: *BuiltinOpenRouter,
        id: []const u8,
        diag: ?*provider.Diagnostics,
    ) (provider.Error || Allocator.Error)!provider.EmbeddingModel {
        const model = try self.factory.embeddingModel(id, diag);
        const stored = try self.arena.allocator().create(@TypeOf(model));
        stored.* = model;
        return stored.embeddingModel();
    }
};

const DefaultProviderState = struct {
    provider_value: ?provider.Provider = null,
    runtime: ?DefaultRuntime = null,
    env: provider_utils.EnvLookup = .empty,
    builtin: ?*BuiltinOpenRouter = null,
};

var default_mutex: std.atomic.Mutex = .unlocked;
var default_state: DefaultProviderState = .{};

fn lockDefault() void {
    while (!default_mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn setDefaultProvider(value: ?provider.Provider) void {
    lockDefault();
    defer default_mutex.unlock();
    default_state.provider_value = value;
}

pub fn setDefaultEnv(env: provider_utils.EnvLookup) void {
    lockDefault();
    defer default_mutex.unlock();
    deinitBuiltinLocked();
    default_state.env = env;
}

pub fn setDefaultRuntime(gpa: Allocator, io: std.Io) void {
    lockDefault();
    defer default_mutex.unlock();
    deinitBuiltinLocked();
    default_state.runtime = .{ .gpa = gpa, .io = io };
}

pub fn useOpenRouterDefault(gpa: Allocator, io: std.Io, env: provider_utils.EnvLookup) void {
    lockDefault();
    defer default_mutex.unlock();
    deinitBuiltinLocked();
    default_state.provider_value = null;
    default_state.runtime = .{ .gpa = gpa, .io = io };
    default_state.env = env;
}

/// Test/application teardown hook. Call only after all models returned by the
/// built-in default have quiesced.
pub fn clearDefaultProviderState() void {
    lockDefault();
    defer default_mutex.unlock();
    deinitBuiltinLocked();
    default_state = .{};
}

fn deinitBuiltinLocked() void {
    if (default_state.builtin) |builtin| {
        builtin.deinit(default_state.runtime.?.gpa);
        default_state.builtin = null;
    }
}

pub fn resolveLanguageModel(
    model: LanguageModelRef,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.LanguageModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| resolveLanguageModelId(id, diag),
    };
}

pub fn resolveEmbeddingModel(
    model: EmbeddingModelRef,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.EmbeddingModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| resolveEmbeddingModelId(id, diag),
    };
}

fn resolveEmbeddingModelId(
    id: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.EmbeddingModel {
    lockDefault();
    if (default_state.provider_value) |selected| {
        default_mutex.unlock();
        return selected.embeddingModel(id, diag);
    }
    if (!build_options.default_openrouter) {
        default_mutex.unlock();
        return noDefaultModel(diag, id, .embedding_model);
    }
    if (default_state.env.get("OPENROUTER_API_KEY") == null) {
        default_mutex.unlock();
        return missingOpenRouterKey(diag);
    }
    const runtime = default_state.runtime orelse {
        default_mutex.unlock();
        return noDefaultRuntime(diag);
    };
    if (default_state.builtin == null) {
        default_state.builtin = BuiltinOpenRouter.init(runtime, default_state.env) catch |err| {
            default_mutex.unlock();
            return err;
        };
    }
    const result = default_state.builtin.?.embeddingModel(id, diag) catch |err| {
        default_mutex.unlock();
        return err;
    };
    default_mutex.unlock();
    return result;
}

pub fn resolveRerankingModel(
    model: RerankingModelRef,
    diag: ?*provider.Diagnostics,
) provider.Error!provider.RerankingModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| blk: {
            lockDefault();
            defer default_mutex.unlock();
            const selected = default_state.provider_value orelse
                break :blk noDefaultModel(diag, id, .reranking_model);
            break :blk selected.rerankingModel(id, diag);
        },
    };
}

pub fn resolveImageModel(
    model: ImageModelRef,
    diag: ?*provider.Diagnostics,
) provider.Error!provider.ImageModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| resolveDefaultModel(provider.ImageModel, id, .image_model, diag, "imageModel"),
    };
}

pub fn resolveSpeechModel(
    model: SpeechModelRef,
    diag: ?*provider.Diagnostics,
) provider.Error!provider.SpeechModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| resolveDefaultModel(provider.SpeechModel, id, .speech_model, diag, "speechModel"),
    };
}

pub fn resolveTranscriptionModel(
    model: TranscriptionModelRef,
    diag: ?*provider.Diagnostics,
) provider.Error!provider.TranscriptionModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| resolveDefaultModel(provider.TranscriptionModel, id, .transcription_model, diag, "transcriptionModel"),
    };
}

pub fn resolveVideoModel(
    model: VideoModelRef,
    diag: ?*provider.Diagnostics,
) provider.Error!provider.VideoModel {
    return switch (model) {
        .model => |value| value,
        .id => |id| resolveDefaultModel(provider.VideoModel, id, .video_model, diag, "videoModel"),
    };
}

fn resolveDefaultModel(
    comptime T: type,
    id: []const u8,
    model_type: provider.ModelType,
    diag: ?*provider.Diagnostics,
    comptime method_name: []const u8,
) provider.Error!T {
    lockDefault();
    const selected = default_state.provider_value orelse {
        default_mutex.unlock();
        return noDefaultModel(diag, id, model_type);
    };
    default_mutex.unlock();
    const resolved: provider.Error!T = if (comptime T == provider.ImageModel)
        selected.imageModel(id, diag)
    else if (comptime T == provider.SpeechModel)
        selected.speechModel(id, diag)
    else if (comptime T == provider.TranscriptionModel)
        selected.transcriptionModel(id, diag)
    else if (comptime T == provider.VideoModel)
        selected.videoModel(id, diag)
    else
        @compileError("unsupported default media model type for " ++ method_name);
    return resolved catch |err| switch (err) {
        error.NoSuchModelError => noSuchModelFromDiag(diag, id, model_type),
        else => |other| other,
    };
}

fn resolveLanguageModelId(
    id: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.LanguageModel {
    lockDefault();
    if (default_state.provider_value) |selected| {
        default_mutex.unlock();
        return selected.languageModel(id, diag);
    }
    if (!build_options.default_openrouter) {
        default_mutex.unlock();
        return noDefaultProvider(diag, id);
    }
    if (default_state.env.get("OPENROUTER_API_KEY") == null) {
        default_mutex.unlock();
        return missingOpenRouterKey(diag);
    }
    const runtime = default_state.runtime orelse {
        default_mutex.unlock();
        return noDefaultRuntime(diag);
    };
    if (default_state.builtin == null) {
        default_state.builtin = BuiltinOpenRouter.init(runtime, default_state.env) catch |err| {
            default_mutex.unlock();
            return err;
        };
    }
    const builtin = default_state.builtin.?;
    const result = builtin.languageModel(id, diag) catch |err| {
        default_mutex.unlock();
        return err;
    };
    default_mutex.unlock();
    return result;
}

fn missingOpenRouterKey(diag: ?*provider.Diagnostics) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .load_api_key = .{
        .message = "OpenRouter API key is missing. Set OPENROUTER_API_KEY and install it with ai.setDefaultEnv(...), or register a provider with ai.setDefaultProvider(...).",
    } });
    return error.LoadAPIKeyError;
}

fn noDefaultRuntime(diag: ?*provider.Diagnostics) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .invalid_argument = .{
        .message = "The built-in OpenRouter default requires ai.setDefaultRuntime(gpa, io).",
        .parameter = "defaultRuntime",
    } });
    return error.InvalidArgumentError;
}

fn noDefaultProvider(diag: ?*provider.Diagnostics, id: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_such_provider = .{
        .message = "No default provider is configured",
        .model_id = id,
        .model_type = .language_model,
        .provider_id = "default",
        .available_providers = &.{},
    } });
    return error.NoSuchProviderError;
}

fn noDefaultModel(
    diag: ?*provider.Diagnostics,
    id: []const u8,
    model_type: provider.ModelType,
) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_such_provider = .{
        .message = "No default provider is configured",
        .model_id = id,
        .model_type = model_type,
        .provider_id = "default",
        .available_providers = &.{},
    } });
    return error.NoSuchProviderError;
}

fn noSuchModelFromDiag(
    diag: ?*provider.Diagnostics,
    id: []const u8,
    model_type: provider.ModelType,
) provider.Error {
    if (diag) |diagnostics| {
        const text = std.fmt.allocPrint(
            diagnostics.allocator,
            "No such {s}: {s}",
            .{ modelTypeName(model_type), id },
        ) catch "No such model";
        defer if (!std.mem.eql(u8, text, "No such model")) diagnostics.allocator.free(text);
        provider.Diagnostics.set(diag, diagnostics.allocator, .{ .no_such_model = .{
            .message = text,
            .model_id = id,
            .model_type = model_type,
        } });
    }
    return error.NoSuchModelError;
}

fn noSuchModel(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    id: []const u8,
    model_type: provider.ModelType,
    separator: ?[]const u8,
) provider.Error {
    const text = if (separator) |value|
        std.fmt.allocPrint(
            arena,
            "Invalid {s} id for registry: {s} (must be in the format \"providerId{s}modelId\")",
            .{ modelTypeName(model_type), id, value },
        ) catch "Invalid model id for registry"
    else
        std.fmt.allocPrint(arena, "No such {s}: {s}", .{ modelTypeName(model_type), id }) catch
            "No such model";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .no_such_model = .{
        .message = text,
        .model_id = id,
        .model_type = model_type,
    } });
    return error.NoSuchModelError;
}

fn noSuchProvider(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    model_id: []const u8,
    model_type: provider.ModelType,
    provider_id: []const u8,
    entries: []const ProviderEntry,
) provider.Error {
    const available = arena.alloc([]const u8, entries.len) catch {
        provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .no_such_provider = .{
            .message = "No such provider",
            .model_id = model_id,
            .model_type = model_type,
            .provider_id = provider_id,
            .available_providers = &.{},
        } });
        return error.NoSuchProviderError;
    };
    for (entries, available) |entry, *id| id.* = entry.id;
    const joined = std.mem.join(arena, ",", available) catch "";
    const text = std.fmt.allocPrint(
        arena,
        "No such provider: {s} (available providers: {s})",
        .{ provider_id, joined },
    ) catch "No such provider";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .no_such_provider = .{
        .message = text,
        .model_id = model_id,
        .model_type = model_type,
        .provider_id = provider_id,
        .available_providers = available,
    } });
    return error.NoSuchProviderError;
}

fn modelTypeName(value: provider.ModelType) []const u8 {
    return switch (value) {
        .language_model => "languageModel",
        .embedding_model => "embeddingModel",
        .image_model => "imageModel",
        .transcription_model => "transcriptionModel",
        .speech_model => "speechModel",
        .reranking_model => "rerankingModel",
        .video_model => "videoModel",
    };
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

const TestLanguageModel = struct {
    provider_name: []const u8 = "fake",
    model_id: []const u8,

    fn languageModel(self: *TestLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = modelProvider,
        .modelId = modelId,
        .urlIsSupported = supported,
        .doGenerate = generate,
        .doStream = stream,
    };

    fn fromRaw(raw: *anyopaque) *TestLanguageModel {
        return @ptrCast(@alignCast(raw));
    }
    fn modelProvider(raw: *anyopaque) []const u8 {
        return fromRaw(raw).provider_name;
    }
    fn modelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }
    fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }
    fn generate(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return error.UnsupportedFunctionalityError;
    }
    fn stream(
        _: *anyopaque,
        _: std.Io,
        _: Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return error.UnsupportedFunctionalityError;
    }
};

const TestProvider = struct {
    model: *TestLanguageModel,
    last_id: ?[]const u8 = null,
    clear_default_on_image: bool = false,

    fn asProvider(self: *TestProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .languageModel = languageModel,
        .embeddingModel = embeddingModel,
        .imageModel = imageModel,
    };

    fn fromRaw(raw: *anyopaque) *TestProvider {
        return @ptrCast(@alignCast(raw));
    }
    fn languageModel(raw: *anyopaque, id: []const u8, _: ?*provider.Diagnostics) provider.Error!provider.LanguageModel {
        const self = fromRaw(raw);
        self.last_id = id;
        return self.model.languageModel();
    }
    fn embeddingModel(_: *anyopaque, _: []const u8, _: ?*provider.Diagnostics) provider.Error!provider.EmbeddingModel {
        return error.NoSuchModelError;
    }
    fn imageModel(raw: *anyopaque, _: []const u8, _: ?*provider.Diagnostics) provider.Error!provider.ImageModel {
        if (fromRaw(raw).clear_default_on_image) clearDefaultProviderState();
        return error.NoSuchModelError;
    }
};

test "registry splits at first separator, applies middleware, and reports exact diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: TestLanguageModel = .{ .model_id = "actual" };
    var fake_provider: TestProvider = .{ .model = &model };
    const entries = [_]ProviderEntry{.{ .id = "p", .provider = fake_provider.asProvider() }};
    const Override = struct {
        fn modelId(_: ?*anyopaque, _: provider.LanguageModel) []const u8 {
            return "wrapped";
        }
    };
    const middlewares = [_]middleware.LanguageModelMiddleware{.{ .override_model_id = Override.modelId }};
    var registry_value = createProviderRegistry(arena, .{
        .providers = &entries,
        .language_model_middleware = &middlewares,
    });
    const resolved = try registry_value.languageModel("p:model:part", null);
    try std.testing.expectEqualStrings("model:part", fake_provider.last_id.?);
    try std.testing.expectEqualStrings("wrapped", resolved.modelId());

    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.NoSuchModelError,
        registry_value.languageModel("model", &diagnostics),
    );
    try std.testing.expectEqualStrings(
        "Invalid languageModel id for registry: model (must be in the format \"providerId:modelId\")",
        diagnostics.payload.no_such_model.message,
    );
    try std.testing.expectError(
        error.NoSuchProviderError,
        registry_value.languageModel("missing:model", &diagnostics),
    );
    try std.testing.expectEqualStrings(
        "No such provider: missing (available providers: p)",
        diagnostics.payload.no_such_provider.message,
    );
    try std.testing.expectEqualStrings("p", diagnostics.payload.no_such_provider.available_providers[0]);
}

test "customProvider map lookup and fallback provider" {
    var direct_model: TestLanguageModel = .{ .provider_name = "direct", .model_id = "direct-model" };
    var fallback_model: TestLanguageModel = .{ .provider_name = "fallback", .model_id = "fallback-model" };
    var fallback: TestProvider = .{ .model = &fallback_model };
    const direct_entries = [_]LanguageModelEntry{.{
        .id = "known",
        .model = .{ .model = direct_model.languageModel() },
    }};
    var custom = customProvider(.{
        .language_models = &direct_entries,
        .fallback_provider = fallback.asProvider(),
    });
    const custom_provider = custom.asProvider();
    try std.testing.expectEqualStrings("direct", (try custom_provider.languageModel("known", null)).provider());
    try std.testing.expectEqualStrings("fallback", (try custom_provider.languageModel("other", null)).provider());
    try std.testing.expectEqualStrings("other", fallback.last_id.?);
}

test "resolveLanguageModel uses a registered default provider" {
    clearDefaultProviderState();
    defer clearDefaultProviderState();
    var model: TestLanguageModel = .{ .provider_name = "registered", .model_id = "resolved" };
    var fake_provider: TestProvider = .{ .model = &model };
    setDefaultProvider(fake_provider.asProvider());
    const resolved = try resolveLanguageModel(.{ .id = "alias" }, null);
    try std.testing.expectEqualStrings("registered", resolved.provider());
    try std.testing.expectEqualStrings("alias", fake_provider.last_id.?);
}

test "media model resolver invokes provider callbacks after releasing the default lock" {
    clearDefaultProviderState();
    defer clearDefaultProviderState();
    var model: TestLanguageModel = .{ .provider_name = "registered", .model_id = "resolved" };
    var fake_provider: TestProvider = .{
        .model = &model,
        .clear_default_on_image = true,
    };
    setDefaultProvider(fake_provider.asProvider());
    try std.testing.expectError(
        error.NoSuchModelError,
        resolveImageModel(.{ .id = "reentrant" }, null),
    );
}

test "media model resolvers report the exact missing model type" {
    clearDefaultProviderState();
    defer clearDefaultProviderState();
    var model: TestLanguageModel = .{ .provider_name = "registered", .model_id = "resolved" };
    var fake_provider: TestProvider = .{ .model = &model };
    setDefaultProvider(fake_provider.asProvider());
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.NoSuchModelError,
        resolveImageModel(.{ .id = "missing-image" }, &diagnostics),
    );
    try std.testing.expectEqual(provider.ModelType.image_model, diagnostics.payload.no_such_model.model_type);
    try std.testing.expectError(
        error.NoSuchModelError,
        resolveSpeechModel(.{ .id = "missing-speech" }, &diagnostics),
    );
    try std.testing.expectEqual(provider.ModelType.speech_model, diagnostics.payload.no_such_model.model_type);
    try std.testing.expectError(
        error.NoSuchModelError,
        resolveTranscriptionModel(.{ .id = "missing-transcription" }, &diagnostics),
    );
    try std.testing.expectEqual(provider.ModelType.transcription_model, diagnostics.payload.no_such_model.model_type);
    try std.testing.expectError(
        error.NoSuchModelError,
        resolveVideoModel(.{ .id = "missing-video" }, &diagnostics),
    );
    try std.testing.expectEqual(provider.ModelType.video_model, diagnostics.payload.no_such_model.model_type);
}

test "built-in OpenRouter default constructs from installed env and missing env has key hint" {
    if (!build_options.default_openrouter) return error.SkipZigTest;
    clearDefaultProviderState();
    defer clearDefaultProviderState();
    const Env = struct {
        key: ?[]const u8,
        fn get(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!std.mem.eql(u8, name, "OPENROUTER_API_KEY")) return null;
            return self.key;
        }
    };
    var env_context: Env = .{ .key = "unit-test-key" };
    useOpenRouterDefault(std.testing.allocator, std.testing.io, .{
        .ctx = &env_context,
        .get_fn = Env.get,
    });
    const resolved = try resolveLanguageModel(.{ .id = "vendor/model" }, null);
    try std.testing.expectEqualStrings("openrouter", resolved.provider());
    try std.testing.expectEqualStrings("vendor/model", resolved.modelId());

    clearDefaultProviderState();
    env_context.key = null;
    setDefaultRuntime(std.testing.allocator, std.testing.io);
    setDefaultEnv(.{ .ctx = &env_context, .get_fn = Env.get });
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.LoadAPIKeyError,
        resolveLanguageModel(.{ .id = "vendor/model" }, &diagnostics),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.payload.load_api_key.message,
        "OPENROUTER_API_KEY",
    ) != null);
}
