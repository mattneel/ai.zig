//! Text embedding and wave-batched `embedMany`.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const logger = @import("logger.zig");
const registry = @import("registry.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;

pub const OperationStartEvent = struct {
    call_id: []const u8,
    operation_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    values: []const []const u8,
    max_retries: u32,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
};

pub const OperationEndEvent = struct {
    call_id: []const u8,
    operation_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    values: []const []const u8,
    embeddings: []const []const f64,
    usage: provider.EmbeddingUsage,
    warnings: []const provider.Warning,
    provider_metadata: ?provider.ProviderMetadata = null,
    responses: []const ?provider.EmbeddingResponseInfo = &.{},
};

pub const Callbacks = struct {
    on_start: ?provider_utils.Callback(OperationStartEvent) = null,
    on_end: ?provider_utils.Callback(OperationEndEvent) = null,
    on_error: ?provider_utils.Callback(events.ErrorEvent) = null,
};

pub const EmbedOptions = struct {
    model: registry.EmbeddingModelRef,
    value: []const u8,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const EmbedManyOptions = struct {
    model: registry.EmbeddingModelRef,
    values: []const []const u8,
    max_parallel_calls: ?usize = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const EmbedResult = struct {
    arena_state: std.heap.ArenaAllocator,
    value: []const u8,
    embedding: []const f64,
    usage: provider.EmbeddingUsage,
    warnings: []const provider.Warning,
    provider_metadata: ?provider.ProviderMetadata,
    response: ?provider.EmbeddingResponseInfo,

    pub fn deinit(self: *EmbedResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub const EmbedManyResult = struct {
    arena_state: std.heap.ArenaAllocator,
    values: []const []const u8,
    embeddings: []const []const f64,
    usage: provider.EmbeddingUsage,
    warnings: []const provider.Warning,
    provider_metadata: ?provider.ProviderMetadata,
    responses: []const ?provider.EmbeddingResponseInfo,

    pub fn deinit(self: *EmbedManyResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn embed(io: std.Io, gpa: Allocator, options: EmbedOptions) anyerror!EmbedResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveEmbeddingModel(options.model, options.diag);
    var id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call", .size = 24 }, options.diag);
    const call_id = try id_generator.nextAlloc(arena);
    const headers = try provider_utils.withUserAgentSuffix(arena, options.headers orelse &.{}, &.{"ai/0.0.0"});
    const dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry);
    const values = [_][]const u8{options.value};
    const start_event: OperationStartEvent = .{
        .call_id = call_id,
        .operation_id = "ai.embed",
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .values = &values,
        .max_retries = options.max_retries,
        .headers = headers,
        .provider_options = options.provider_options,
    };
    try provider_utils.notify(io, start_event, &.{options.callbacks.on_start});

    var attempt: EmbedAttempt = .{
        .model = model,
        .arena = arena,
        .values = &values,
        .headers = headers,
        .provider_options = options.provider_options,
        .call_id = call_id,
        .id_generator = &id_generator,
        .dispatcher = &dispatcher,
    };
    const model_result = provider_utils.retry(
        provider.EmbeddingResult,
        io,
        .{ .max_retries = options.max_retries },
        &attempt,
        EmbedAttempt.call,
        options.diag,
    ) catch |err| {
        try notifyError(io, call_id, err, options.diag, options.callbacks.on_error, &dispatcher);
        return err;
    };
    if (model_result.embeddings.len == 0) {
        setInvalidResponse(options.diag, "Embedding model returned no embeddings.");
        return error.InvalidResponseDataError;
    }
    const owned = try cloneModelResult(arena, model_result);
    logger.logWarnings(arena, .{
        .warnings = owned.warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });
    const usage = owned.usage orelse provider.EmbeddingUsage{};
    const end_event: OperationEndEvent = .{
        .call_id = call_id,
        .operation_id = "ai.embed",
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .values = &values,
        .embeddings = owned.embeddings,
        .usage = usage,
        .warnings = owned.warnings,
        .provider_metadata = owned.provider_metadata,
        .responses = &.{owned.response},
    };
    try provider_utils.notify(io, end_event, &.{options.callbacks.on_end});

    return .{
        .arena_state = arena_state,
        .value = try arena.dupe(u8, options.value),
        .embedding = owned.embeddings[0],
        .usage = usage,
        .warnings = owned.warnings,
        .provider_metadata = owned.provider_metadata,
        .response = owned.response,
    };
}

pub fn embedMany(io: std.Io, gpa: Allocator, options: EmbedManyOptions) anyerror!EmbedManyResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveEmbeddingModel(options.model, options.diag);
    if (options.max_parallel_calls == 0) return invalidArgument(options.diag, "maxParallelCalls", "maxParallelCalls must be greater than zero.");

    var id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call", .size = 24 }, options.diag);
    const call_id = try id_generator.nextAlloc(arena);
    const headers = try provider_utils.withUserAgentSuffix(arena, options.headers orelse &.{}, &.{"ai/0.0.0"});
    const dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry);
    const start_event: OperationStartEvent = .{
        .call_id = call_id,
        .operation_id = "ai.embedMany",
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .values = options.values,
        .max_retries = options.max_retries,
        .headers = headers,
        .provider_options = options.provider_options,
    };
    try provider_utils.notify(io, start_event, &.{options.callbacks.on_start});

    const max_per_call = model.maxEmbeddingsPerCall(io);
    const supports_parallel = model.supportsParallelCalls(io);
    const chunk_size: usize = if (max_per_call) |limit| @intCast(limit) else @max(options.values.len, 1);
    if (max_per_call != null and chunk_size == 0 and options.values.len != 0) {
        return tooMany(options.diag, model, 0, options.values);
    }
    const chunk_count = if (max_per_call == null)
        1
    else if (options.values.len == 0)
        0
    else
        (options.values.len + chunk_size - 1) / chunk_size;

    var embeddings: std.ArrayList([]const f64) = .empty;
    defer embeddings.deinit(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var responses: std.ArrayList(?provider.EmbeddingResponseInfo) = .empty;
    defer responses.deinit(arena);
    var merged_metadata: ?provider.ProviderMetadata = null;
    var token_total: u64 = 0;
    var saw_tokens = false;

    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) {
        const remaining = chunk_count - chunk_index;
        const configured_parallel = if (supports_parallel) options.max_parallel_calls orelse remaining else 1;
        const wave_size = @min(configured_parallel, remaining);
        const jobs = try gpa.alloc(Job, wave_size);
        defer gpa.free(jobs);
        var initialized: usize = 0;
        defer for (jobs[0..initialized]) |*job| job.deinit();

        for (jobs, 0..) |*job, wave_offset| {
            const absolute = chunk_index + wave_offset;
            const start = absolute * chunk_size;
            const end = @min(start + chunk_size, options.values.len);
            job.* = Job.init(gpa, .{
                .model = model,
                .values = options.values[start..end],
                .headers = headers,
                .provider_options = options.provider_options,
                .max_retries = options.max_retries,
                .call_id = call_id,
                .dispatcher = &dispatcher,
            });
            initialized += 1;
        }

        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (jobs) |*job| {
            group.concurrent(io, Job.run, .{ job, io }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => group.async(io, Job.run, .{ job, io }),
            };
        }
        try group.await(io);

        for (jobs) |*job| {
            if (job.err) |err| {
                copyDiagnostics(options.diag, &job.diagnostics);
                try notifyError(io, call_id, err, options.diag, options.callbacks.on_error, &dispatcher);
                return err;
            }
            const model_result = job.result.?;
            if (model_result.embeddings.len != job.options.values.len) {
                setInvalidResponse(options.diag, "Embedding model returned a different number of embeddings than values.");
                return error.InvalidResponseDataError;
            }
            for (model_result.embeddings) |embedding_value| {
                try embeddings.append(arena, try arena.dupe(f64, embedding_value));
            }
            for (model_result.warnings) |warning| try warnings.append(arena, try cloneWarning(arena, warning));
            try responses.append(arena, try cloneResponse(arena, model_result.response));
            if (model_result.usage) |usage| if (usage.tokens) |tokens| {
                saw_tokens = true;
                token_total +|= tokens;
            };
            try mergeMetadata(arena, &merged_metadata, model_result.provider_metadata);
        }
        chunk_index += wave_size;
    }

    const owned_values = try cloneStrings(arena, options.values);
    const owned_embeddings = try embeddings.toOwnedSlice(arena);
    const owned_warnings = try warnings.toOwnedSlice(arena);
    const owned_responses = try responses.toOwnedSlice(arena);
    // Zig deviation from upstream's NaN sentinel: add every reported token
    // count, but preserve null when every chunk omitted usage.
    const usage: provider.EmbeddingUsage = .{ .tokens = if (saw_tokens) token_total else null };
    logger.logWarnings(arena, .{
        .warnings = owned_warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });
    const end_event: OperationEndEvent = .{
        .call_id = call_id,
        .operation_id = "ai.embedMany",
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .values = owned_values,
        .embeddings = owned_embeddings,
        .usage = usage,
        .warnings = owned_warnings,
        .provider_metadata = merged_metadata,
        .responses = owned_responses,
    };
    try provider_utils.notify(io, end_event, &.{options.callbacks.on_end});

    return .{
        .arena_state = arena_state,
        .values = owned_values,
        .embeddings = owned_embeddings,
        .usage = usage,
        .warnings = owned_warnings,
        .provider_metadata = merged_metadata,
        .responses = owned_responses,
    };
}

const EmbedAttempt = struct {
    model: provider.EmbeddingModel,
    arena: Allocator,
    values: []const []const u8,
    headers: provider.Headers,
    provider_options: ?provider.ProviderOptions,
    call_id: []const u8,
    id_generator: *provider_utils.IdGenerator,
    dispatcher: *const telemetry.Dispatcher,

    fn call(self: *EmbedAttempt, io: std.Io, _: u32, diag: ?*provider.Diagnostics) provider.embedding_model.CallError!provider.EmbeddingResult {
        const embed_call_id = try self.id_generator.nextAlloc(self.arena);
        const start_event: events.EmbedStartEvent = .{
            .call_id = self.call_id,
            .embed_call_id = embed_call_id,
            .operation_id = "ai.embed.doEmbed",
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .values = self.values,
        };
        try self.dispatcher.onEmbedStart(&start_event);
        try enforceLimit(self.model, io, self.values, diag);
        const result = try self.model.doEmbed(io, self.arena, &.{
            .values = self.values,
            .headers = self.headers,
            .provider_options = self.provider_options,
        }, diag);
        const end_event: events.EmbedEndEvent = .{
            .call_id = self.call_id,
            .embed_call_id = embed_call_id,
            .operation_id = "ai.embed.doEmbed",
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .values = self.values,
            .embeddings = result.embeddings,
            .usage = result.usage orelse provider.EmbeddingUsage{},
            .warnings = result.warnings,
        };
        try self.dispatcher.onEmbedEnd(&end_event);
        return result;
    }
};

const JobOptions = struct {
    model: provider.EmbeddingModel,
    values: []const []const u8,
    headers: provider.Headers,
    provider_options: ?provider.ProviderOptions,
    max_retries: u32,
    call_id: []const u8,
    dispatcher: *const telemetry.Dispatcher,
};

const Job = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    options: JobOptions,
    result: ?provider.EmbeddingResult = null,
    err: ?anyerror = null,

    fn init(gpa: Allocator, options: JobOptions) Job {
        return .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .diagnostics = provider.Diagnostics.init(gpa),
            .options = options,
        };
    }

    fn deinit(self: *Job) void {
        self.diagnostics.deinit();
        self.arena_state.deinit();
    }

    fn run(self: *Job, io: std.Io) void {
        var attempt: JobAttempt = .{ .job = self };
        self.result = provider_utils.retry(
            provider.EmbeddingResult,
            io,
            .{ .max_retries = self.options.max_retries },
            &attempt,
            JobAttempt.call,
            &self.diagnostics,
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

const JobAttempt = struct {
    job: *Job,

    fn call(self: *JobAttempt, io: std.Io, _: u32, diag: ?*provider.Diagnostics) provider.embedding_model.CallError!provider.EmbeddingResult {
        const job = self.job;
        const job_arena = job.arena_state.allocator();
        var id_generator = try provider_utils.IdGenerator.initFromIo(
            io,
            .{ .prefix = "call", .size = 24 },
            diag,
        );
        const embed_call_id = try id_generator.nextAlloc(job_arena);
        var dispatcher = job.options.dispatcher.*;
        dispatcher.arena = job_arena;
        const start_event: events.EmbedStartEvent = .{
            .call_id = job.options.call_id,
            .embed_call_id = embed_call_id,
            .operation_id = "ai.embedMany.doEmbed",
            .provider_name = job.options.model.provider(),
            .model_id = job.options.model.modelId(),
            .values = job.options.values,
        };
        try dispatcher.onEmbedStart(&start_event);
        try enforceLimit(job.options.model, io, job.options.values, diag);
        const result = try job.options.model.doEmbed(io, job.arena_state.allocator(), &.{
            .values = job.options.values,
            .headers = job.options.headers,
            .provider_options = job.options.provider_options,
        }, diag);
        const end_event: events.EmbedEndEvent = .{
            .call_id = job.options.call_id,
            .embed_call_id = embed_call_id,
            .operation_id = "ai.embedMany.doEmbed",
            .provider_name = job.options.model.provider(),
            .model_id = job.options.model.modelId(),
            .values = job.options.values,
            .embeddings = result.embeddings,
            .usage = result.usage orelse provider.EmbeddingUsage{},
            .warnings = result.warnings,
        };
        try dispatcher.onEmbedEnd(&end_event);
        return result;
    }
};

fn enforceLimit(
    model: provider.EmbeddingModel,
    io: std.Io,
    values: []const []const u8,
    diag: ?*provider.Diagnostics,
) provider.Error!void {
    if (model.maxEmbeddingsPerCall(io)) |limit| {
        if (values.len > limit) return tooMany(diag, model, limit, values);
    }
}

fn tooMany(
    diag: ?*provider.Diagnostics,
    model: provider.EmbeddingModel,
    limit: usize,
    values: []const []const u8,
) provider.Error {
    if (diag) |diagnostics| {
        const allocated_json = provider.wire.stringifyAlloc(diagnostics.allocator, values) catch null;
        defer if (allocated_json) |json| diagnostics.allocator.free(json);
        provider.Diagnostics.set(diag, diagnostics.allocator, .{ .too_many_embedding_values_for_call = .{
            .message = "Too many embedding values for a single call.",
            .provider = model.provider(),
            .model_id = model.modelId(),
            .max_embeddings_per_call = limit,
            .values_json = allocated_json orelse "[]",
        } });
    }
    return error.TooManyEmbeddingValuesForCallError;
}

fn cloneModelResult(arena: Allocator, value: provider.EmbeddingResult) Allocator.Error!provider.EmbeddingResult {
    const embeddings = try arena.alloc([]const f64, value.embeddings.len);
    for (value.embeddings, embeddings) |embedding_value, *destination| destination.* = try arena.dupe(f64, embedding_value);
    const warnings = try arena.alloc(provider.Warning, value.warnings.len);
    for (value.warnings, warnings) |warning, *destination| destination.* = try cloneWarning(arena, warning);
    return .{
        .embeddings = embeddings,
        .usage = value.usage,
        .provider_metadata = if (value.provider_metadata) |metadata| try provider_utils.cloneJsonValue(arena, metadata) else null,
        .response = try cloneResponse(arena, value.response),
        .warnings = warnings,
    };
}

fn cloneResponse(arena: Allocator, response: ?provider.EmbeddingResponseInfo) Allocator.Error!?provider.EmbeddingResponseInfo {
    const value = response orelse return null;
    const headers = if (value.headers) |source| blk: {
        const result = try arena.alloc(provider.Header, source.len);
        for (source, result) |header, *destination| destination.* = .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        };
        break :blk result;
    } else null;
    return .{
        .headers = headers,
        .body = if (value.body) |body| try provider_utils.cloneJsonValue(arena, body) else null,
    };
}

fn cloneWarning(arena: Allocator, warning: provider.Warning) Allocator.Error!provider.Warning {
    return switch (warning) {
        .unsupported => |value| .{ .unsupported = .{
            .feature = try arena.dupe(u8, value.feature),
            .details = if (value.details) |details| try arena.dupe(u8, details) else null,
        } },
        .compatibility => |value| .{ .compatibility = .{
            .feature = try arena.dupe(u8, value.feature),
            .details = if (value.details) |details| try arena.dupe(u8, details) else null,
        } },
        .deprecated => |value| .{ .deprecated = .{
            .setting = try arena.dupe(u8, value.setting),
            .message = try arena.dupe(u8, value.message),
        } },
        .other => |value| .{ .other = .{ .message = try arena.dupe(u8, value.message) } },
    };
}

fn cloneStrings(arena: Allocator, values: []const []const u8) Allocator.Error![]const []const u8 {
    const result = try arena.alloc([]const u8, values.len);
    for (values, result) |value, *destination| destination.* = try arena.dupe(u8, value);
    return result;
}

fn mergeMetadata(
    arena: Allocator,
    destination: *?provider.ProviderMetadata,
    source: ?provider.ProviderMetadata,
) Allocator.Error!void {
    const value = source orelse return;
    if (value != .object) {
        destination.* = try provider_utils.cloneJsonValue(arena, value);
        return;
    }
    if (destination.* == null or destination.*.? != .object) destination.* = .{ .object = .empty };
    var root = &destination.*.?.object;
    var providers = value.object.iterator();
    while (providers.next()) |provider_entry| {
        if (provider_entry.value_ptr.* != .object) {
            try root.put(arena, try arena.dupe(u8, provider_entry.key_ptr.*), try provider_utils.cloneJsonValue(arena, provider_entry.value_ptr.*));
            continue;
        }
        var merged: std.json.ObjectMap = if (root.get(provider_entry.key_ptr.*)) |existing|
            if (existing == .object) existing.object else .empty
        else
            .empty;
        var fields = provider_entry.value_ptr.object.iterator();
        while (fields.next()) |field| {
            try merged.put(arena, try arena.dupe(u8, field.key_ptr.*), try provider_utils.cloneJsonValue(arena, field.value_ptr.*));
        }
        try root.put(arena, try arena.dupe(u8, provider_entry.key_ptr.*), .{ .object = merged });
    }
}

fn copyDiagnostics(destination: ?*provider.Diagnostics, source: *const provider.Diagnostics) void {
    const target = destination orelse return;
    if (source.available) provider.Diagnostics.set(target, target.allocator, source.payload);
}

fn invalidArgument(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn setInvalidResponse(diag: ?*provider.Diagnostics, message: []const u8) void {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_response_data = .{ .message = message },
    });
}

fn notifyError(
    io: std.Io,
    call_id: []const u8,
    err: anyerror,
    diag: ?*provider.Diagnostics,
    callback: ?provider_utils.Callback(events.ErrorEvent),
    dispatcher: *const telemetry.Dispatcher,
) anyerror!void {
    const event: events.ErrorEvent = .{ .call_id = call_id, .err = err, .diag = diag };
    try provider_utils.notify(io, event, &.{callback});
    try dispatcher.onError(&event);
}

test "embed and embedMany preserve order, chunking, and optional usage" {
    const Model = struct {
        calls: std.ArrayList(usize) = .empty,
        max_per_call: ?u32 = 2,

        fn embeddingModel(self: *@This()) provider.EmbeddingModel {
            return .{ .ctx = self, .vtable = &vtable };
        }
        const vtable: provider.EmbeddingModel.VTable = .{
            .provider = vProvider,
            .modelId = vModelId,
            .maxEmbeddingsPerCall = maxPerCall,
            .supportsParallelCalls = parallel,
            .doEmbed = doEmbed,
        };
        fn fromRaw(raw: *anyopaque) *@This() {
            return @ptrCast(@alignCast(raw));
        }
        fn vProvider(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn vModelId(_: *anyopaque) []const u8 {
            return "embed";
        }
        fn maxPerCall(raw: *anyopaque, _: std.Io) ?u32 {
            return fromRaw(raw).max_per_call;
        }
        fn parallel(_: *anyopaque, _: std.Io) bool {
            return true;
        }
        fn doEmbed(raw: *anyopaque, _: std.Io, arena: Allocator, options: *const provider.EmbeddingCallOptions, _: ?*provider.Diagnostics) provider.embedding_model.CallError!provider.EmbeddingResult {
            const self = fromRaw(raw);
            try self.calls.append(std.testing.allocator, options.values.len);
            const result = try arena.alloc([]const f64, options.values.len);
            for (options.values, result) |value, *embedding_value| {
                const coordinates = try arena.alloc(f64, 1);
                coordinates[0] = @floatFromInt(value[0]);
                embedding_value.* = coordinates;
            }
            return .{ .embeddings = result, .warnings = &.{} };
        }
    };
    var model: Model = .{};
    defer model.calls.deinit(std.testing.allocator);
    var single = try embed(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.embeddingModel() },
        .value = "a",
    });
    defer single.deinit();
    try std.testing.expectEqual(@as(f64, 'a'), single.embedding[0]);
    try std.testing.expectEqual(null, single.usage.tokens);

    const values = [_][]const u8{ "a", "b", "c", "d", "e" };
    var many = try embedMany(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.embeddingModel() },
        .values = &values,
        .max_parallel_calls = 1,
    });
    defer many.deinit();
    try std.testing.expectEqual(5, many.embeddings.len);
    try std.testing.expectEqual(@as(f64, 'e'), many.embeddings[4][0]);
    try std.testing.expectEqual(null, many.usage.tokens);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 2, 1 }, model.calls.items);

    model.max_per_call = null;
    var empty = try embedMany(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.embeddingModel() },
        .values = &.{},
    });
    defer empty.deinit();
    try std.testing.expectEqual(0, empty.embeddings.len);
    try std.testing.expectEqual(1, empty.responses.len);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 2, 1, 0 }, model.calls.items);
}

const WaveEmbeddingModel = struct {
    supports_parallel: bool,
    call_index: std.atomic.Value(usize) = .init(0),
    sequence: std.atomic.Value(usize) = .init(0),
    started: [3]std.Io.Event = .{ .unset, .unset, .unset },
    release: [3]std.Io.Event = .{ .unset, .unset, .unset },
    ended: [3]std.Io.Event = .{ .unset, .unset, .unset },
    start_order: [3]usize = undefined,
    end_order: [3]usize = undefined,

    fn embeddingModel(self: *WaveEmbeddingModel) provider.EmbeddingModel {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: provider.EmbeddingModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .maxEmbeddingsPerCall = maxPerCall,
        .supportsParallelCalls = parallel,
        .doEmbed = doEmbed,
    };
    fn fromRaw(raw: *anyopaque) *WaveEmbeddingModel {
        return @ptrCast(@alignCast(raw));
    }
    fn vProvider(_: *anyopaque) []const u8 {
        return "wave";
    }
    fn vModelId(_: *anyopaque) []const u8 {
        return "wave-model";
    }
    fn maxPerCall(_: *anyopaque, _: std.Io) ?u32 {
        return 1;
    }
    fn parallel(raw: *anyopaque, _: std.Io) bool {
        return fromRaw(raw).supports_parallel;
    }
    fn doEmbed(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.EmbeddingCallOptions,
        _: ?*provider.Diagnostics,
    ) provider.embedding_model.CallError!provider.EmbeddingResult {
        const self = fromRaw(raw);
        const index = self.call_index.fetchAdd(1, .acq_rel);
        self.start_order[index] = self.sequence.fetchAdd(1, .acq_rel);
        self.started[index].set(io);
        try self.release[index].wait(io);
        self.end_order[index] = self.sequence.fetchAdd(1, .acq_rel);
        self.ended[index].set(io);
        const coordinates = try arena.alloc(f64, 1);
        coordinates[0] = @floatFromInt(options.values[0][0]);
        const embeddings = try arena.alloc([]const f64, 1);
        embeddings[0] = coordinates;
        return .{ .embeddings = embeddings, .warnings = &.{} };
    }
};

test "embedMany uses barriered parallel waves and preserves value order" {
    const io = std.testing.io;
    var model: WaveEmbeddingModel = .{ .supports_parallel = true };
    const values = [_][]const u8{ "a", "b", "c" };
    const Runner = struct {
        fn run(task_io: std.Io, target: *WaveEmbeddingModel, inputs: []const []const u8) anyerror!EmbedManyResult {
            return embedMany(task_io, std.testing.allocator, .{
                .model = .{ .model = target.embeddingModel() },
                .values = inputs,
                .max_parallel_calls = 2,
            });
        }
    };
    var future = try io.concurrent(Runner.run, .{ io, &model, &values });
    defer if (future.cancel(io)) |cleanup_result| {
        var owned = cleanup_result;
        owned.deinit();
    } else |_| {};

    try model.started[0].wait(io);
    try model.started[1].wait(io);
    try std.testing.expect(!model.started[2].isSet());
    model.release[0].set(io);
    model.release[1].set(io);
    try model.started[2].wait(io);
    try std.testing.expect(model.ended[0].isSet());
    try std.testing.expect(model.ended[1].isSet());
    try std.testing.expect(model.start_order[2] > model.end_order[0]);
    try std.testing.expect(model.start_order[2] > model.end_order[1]);
    model.release[2].set(io);

    const result = try future.await(io);
    try std.testing.expectEqual(@as(f64, 'a'), result.embeddings[0][0]);
    try std.testing.expectEqual(@as(f64, 'b'), result.embeddings[1][0]);
    try std.testing.expectEqual(@as(f64, 'c'), result.embeddings[2][0]);
}

test "embedMany serializes chunks when the model forbids parallel calls" {
    const io = std.testing.io;
    var model: WaveEmbeddingModel = .{ .supports_parallel = false };
    const values = [_][]const u8{ "a", "b", "c" };
    const Runner = struct {
        fn run(task_io: std.Io, target: *WaveEmbeddingModel, inputs: []const []const u8) anyerror!EmbedManyResult {
            return embedMany(task_io, std.testing.allocator, .{
                .model = .{ .model = target.embeddingModel() },
                .values = inputs,
            });
        }
    };
    var future = try io.concurrent(Runner.run, .{ io, &model, &values });
    defer if (future.cancel(io)) |cleanup_result| {
        var owned = cleanup_result;
        owned.deinit();
    } else |_| {};

    try model.started[0].wait(io);
    try std.testing.expect(!model.started[1].isSet());
    model.release[0].set(io);
    try model.started[1].wait(io);
    try std.testing.expect(model.ended[0].isSet());
    try std.testing.expect(!model.started[2].isSet());
    model.release[1].set(io);
    try model.started[2].wait(io);
    try std.testing.expect(model.ended[1].isSet());
    model.release[2].set(io);

    const result = try future.await(io);
    try std.testing.expectEqual(3, result.embeddings.len);
}
