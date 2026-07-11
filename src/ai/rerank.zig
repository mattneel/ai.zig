//! Reranking with document-to-result index mapping.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const events = @import("events.zig");
const logger = @import("logger.zig");
const registry = @import("registry.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;

pub const Document = union(enum) {
    text: []const u8,
    object: std.json.Value,
};

pub const RankedDocument = struct {
    original_index: usize,
    score: f64,
    document: Document,
};

pub const StartEvent = struct {
    call_id: []const u8,
    operation_id: []const u8 = "ai.rerank",
    provider_name: []const u8,
    model_id: []const u8,
    documents: []const Document,
    query: []const u8,
    top_n: ?u32,
    max_retries: u32,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
};

pub const EndEvent = struct {
    call_id: []const u8,
    operation_id: []const u8 = "ai.rerank",
    provider_name: []const u8,
    model_id: []const u8,
    documents: []const Document,
    query: []const u8,
    ranking: []const RankedDocument,
    warnings: []const provider.Warning,
    provider_metadata: ?provider.ProviderMetadata = null,
    response: provider.reranking_model.ResponseInfo,
};

pub const Callbacks = struct {
    on_start: ?provider_utils.Callback(StartEvent) = null,
    on_end: ?provider_utils.Callback(EndEvent) = null,
    on_error: ?provider_utils.Callback(events.ErrorEvent) = null,
};

pub const RerankOptions = struct {
    model: registry.RerankingModelRef,
    documents: []const Document,
    query: []const u8,
    top_n: ?u32 = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const RerankResult = struct {
    arena_state: std.heap.ArenaAllocator,
    original_documents: []const Document,
    ranking: []const RankedDocument,
    reranked_documents: []const Document,
    provider_metadata: ?provider.ProviderMetadata,
    response: provider.reranking_model.ResponseInfo,

    pub fn deinit(self: *RerankResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn rerankedDocuments(self: *const RerankResult) []const Document {
        return self.reranked_documents;
    }
};

pub fn rerank(io: std.Io, gpa: Allocator, options: RerankOptions) anyerror!RerankResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveRerankingModel(options.model, options.diag);
    var id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call", .size = 24 }, options.diag);
    const call_id = try id_generator.nextAlloc(arena);
    const headers = try provider_utils.withUserAgentSuffix(arena, options.headers orelse &.{}, &.{"ai/0.0.0"});
    const dispatcher = try telemetry.createTelemetryDispatcher(io, arena, options.telemetry);
    const original_documents = try cloneDocuments(arena, options.documents);
    const query = try arena.dupe(u8, options.query);
    const start_event: StartEvent = .{
        .call_id = call_id,
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .documents = original_documents,
        .query = query,
        .top_n = options.top_n,
        .max_retries = options.max_retries,
        .headers = headers,
        .provider_options = options.provider_options,
    };
    try provider_utils.notify(io, start_event, &.{options.callbacks.on_start});

    if (original_documents.len == 0) {
        const response: provider.reranking_model.ResponseInfo = .{
            .timestamp_ms = timestampMilliseconds(io),
            .model_id = try arena.dupe(u8, model.modelId()),
        };
        const end_event: EndEvent = .{
            .call_id = call_id,
            .provider_name = model.provider(),
            .model_id = model.modelId(),
            .documents = original_documents,
            .query = query,
            .ranking = &.{},
            .warnings = &.{},
            .response = response,
        };
        try provider_utils.notify(io, end_event, &.{options.callbacks.on_end});
        return .{
            .arena_state = arena_state,
            .original_documents = original_documents,
            .ranking = &.{},
            .reranked_documents = &.{},
            .provider_metadata = null,
            .response = response,
        };
    }

    const provider_documents = try lowerDocuments(arena, original_documents, options.diag);
    var attempt: Attempt = .{
        .model = model,
        .arena = arena,
        .options = .{
            .documents = provider_documents,
            .query = query,
            .top_n = options.top_n,
            .provider_options = options.provider_options,
            .headers = headers,
        },
        .call_id = call_id,
        .dispatcher = &dispatcher,
    };
    const model_result = provider_utils.retry(
        provider.RerankingResult,
        io,
        .{ .max_retries = options.max_retries },
        &attempt,
        Attempt.call,
        options.diag,
    ) catch |err| {
        try notifyError(io, call_id, err, options.diag, options.callbacks.on_error, &dispatcher);
        return err;
    };

    const ranking = try arena.alloc(RankedDocument, model_result.ranking.len);
    const reranked_documents = try arena.alloc(Document, model_result.ranking.len);
    for (model_result.ranking, ranking, reranked_documents) |item, *mapped, *document| {
        if (item.index >= original_documents.len) {
            setInvalidResponse(options.diag, "Reranking model returned an out-of-range document index.");
            return error.InvalidResponseDataError;
        }
        const index: usize = @intCast(item.index);
        mapped.* = .{
            .original_index = index,
            .score = item.relevance_score,
            .document = original_documents[index],
        };
        document.* = original_documents[index];
    }
    const warnings = try cloneWarnings(arena, model_result.warnings orelse &.{});
    const provider_metadata = if (model_result.provider_metadata) |metadata|
        try provider_utils.cloneJsonValue(arena, metadata)
    else
        null;
    const response = try responseInfo(arena, io, model.modelId(), model_result.response);
    logger.logWarnings(arena, .{
        .warnings = warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });
    const end_event: EndEvent = .{
        .call_id = call_id,
        .provider_name = model.provider(),
        .model_id = model.modelId(),
        .documents = original_documents,
        .query = query,
        .ranking = ranking,
        .warnings = warnings,
        .provider_metadata = provider_metadata,
        .response = response,
    };
    try provider_utils.notify(io, end_event, &.{options.callbacks.on_end});

    return .{
        .arena_state = arena_state,
        .original_documents = original_documents,
        .ranking = ranking,
        .reranked_documents = reranked_documents,
        .provider_metadata = provider_metadata,
        .response = response,
    };
}

const Attempt = struct {
    model: provider.RerankingModel,
    arena: Allocator,
    options: provider.RerankingCallOptions,
    call_id: []const u8,
    dispatcher: *const telemetry.Dispatcher,

    fn call(self: *Attempt, io: std.Io, _: u32, diag: ?*provider.Diagnostics) provider.reranking_model.CallError!provider.RerankingResult {
        const document_type = switch (self.options.documents) {
            .text => "text",
            .object => "object",
        };
        const start_event: events.RerankStartEvent = .{
            .call_id = self.call_id,
            .operation_id = "ai.rerank.doRerank",
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .documents = self.options.documents,
            .query = self.options.query,
            .top_n = self.options.top_n,
        };
        try self.dispatcher.onRerankStart(&start_event);
        const result = try self.model.doRerank(io, self.arena, &self.options, diag);
        const end_event: events.RerankEndEvent = .{
            .call_id = self.call_id,
            .operation_id = "ai.rerank.doRerank",
            .provider_name = self.model.provider(),
            .model_id = self.model.modelId(),
            .documents_type = document_type,
            .ranking = result.ranking,
        };
        try self.dispatcher.onRerankEnd(&end_event);
        return result;
    }
};

fn lowerDocuments(
    arena: Allocator,
    documents: []const Document,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!provider.RerankingDocuments {
    return switch (documents[0]) {
        .text => blk: {
            const values = try arena.alloc([]const u8, documents.len);
            for (documents, values) |document, *destination| switch (document) {
                .text => |value| destination.* = value,
                .object => return invalidArgument(diag, "documents", "All rerank documents must have the same type."),
            };
            break :blk .{ .text = .{ .values = values } };
        },
        .object => blk: {
            const values = try arena.alloc(std.json.Value, documents.len);
            for (documents, values) |document, *destination| switch (document) {
                .object => |value| destination.* = value,
                .text => return invalidArgument(diag, "documents", "All rerank documents must have the same type."),
            };
            break :blk .{ .object = .{ .values = values } };
        },
    };
}

fn cloneDocuments(arena: Allocator, documents: []const Document) Allocator.Error![]const Document {
    const result = try arena.alloc(Document, documents.len);
    for (documents, result) |document, *destination| destination.* = switch (document) {
        .text => |value| .{ .text = try arena.dupe(u8, value) },
        .object => |value| .{ .object = try provider_utils.cloneJsonValue(arena, value) },
    };
    return result;
}

fn responseInfo(
    arena: Allocator,
    io: std.Io,
    model_id: []const u8,
    optional: ?provider.reranking_model.ResponseInfo,
) Allocator.Error!provider.reranking_model.ResponseInfo {
    const value = optional orelse provider.reranking_model.ResponseInfo{};
    const headers = if (value.headers) |source| blk: {
        const result = try arena.alloc(provider.Header, source.len);
        for (source, result) |header, *destination| destination.* = .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        };
        break :blk result;
    } else null;
    return .{
        .id = if (value.id) |id| try arena.dupe(u8, id) else null,
        .timestamp_ms = value.timestamp_ms orelse timestampMilliseconds(io),
        .model_id = try arena.dupe(u8, value.model_id orelse model_id),
        .headers = headers,
        .body = if (value.body) |body| try provider_utils.cloneJsonValue(arena, body) else null,
    };
}

fn cloneWarnings(arena: Allocator, source: []const provider.Warning) Allocator.Error![]const provider.Warning {
    const result = try arena.alloc(provider.Warning, source.len);
    for (source, result) |warning, *destination| destination.* = switch (warning) {
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
    return result;
}

fn timestampMilliseconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
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

test "rerank maps indices to original documents and short-circuits empty input" {
    const Model = struct {
        calls: usize = 0,

        fn rerankingModel(self: *@This()) provider.RerankingModel {
            return .{ .ctx = self, .vtable = &vtable };
        }
        const vtable: provider.RerankingModel.VTable = .{
            .provider = vProvider,
            .modelId = vModelId,
            .doRerank = doRerank,
        };
        fn fromRaw(raw: *anyopaque) *@This() {
            return @ptrCast(@alignCast(raw));
        }
        fn vProvider(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn vModelId(_: *anyopaque) []const u8 {
            return "rerank";
        }
        fn doRerank(raw: *anyopaque, _: std.Io, _: Allocator, _: *const provider.RerankingCallOptions, _: ?*provider.Diagnostics) provider.reranking_model.CallError!provider.RerankingResult {
            fromRaw(raw).calls += 1;
            return .{
                .ranking = &.{
                    .{ .index = 2, .relevance_score = 0.9 },
                    .{ .index = 0, .relevance_score = 0.5 },
                },
            };
        }
    };
    var model: Model = .{};
    const documents = [_]Document{ .{ .text = "a" }, .{ .text = "b" }, .{ .text = "c" } };
    var result = try rerank(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.rerankingModel() },
        .documents = &documents,
        .query = "q",
    });
    defer result.deinit();
    try std.testing.expectEqual(2, result.ranking[0].original_index);
    try std.testing.expectEqualStrings("c", result.rerankedDocuments()[0].text);

    var empty = try rerank(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model.rerankingModel() },
        .documents = &.{},
        .query = "q",
    });
    defer empty.deinit();
    try std.testing.expectEqual(1, model.calls);
    try std.testing.expectEqual(0, empty.ranking.len);
}
