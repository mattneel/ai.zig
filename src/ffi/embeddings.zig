const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const providers = @import("providers.zig");
const result_api = @import("result.zig");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const WireOptions = struct {
    max_retries: u32 = 2,
    max_parallel_calls: ?usize = null,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
};

const EmbedDocument = struct {
    value: []const u8,
    embedding: []const f64,
    usage: provider.EmbeddingUsage,
    warnings: []const provider.Warning,
    provider_metadata: ?provider.ProviderMetadata,
    response: ?provider.EmbeddingResponseInfo,
};

const EmbedManyDocument = struct {
    values: []const []const u8,
    embeddings: []const []const f64,
    usage: provider.EmbeddingUsage,
    warnings: []const provider.Warning,
    provider_metadata: ?provider.ProviderMetadata,
    responses: []const ?provider.EmbeddingResponseInfo,
};

pub export fn ai_embed(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_embedding_model,
    value_ptr: [*c]const u8,
    value_len: usize,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.embeddingModelFromHandle(value) else return runtime.invalid("embedding model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    const input = providers.optionalSlice(value_ptr, value_len) catch
        return runtime.invalid("embedding value pointer is invalid", "value");
    model.retain();
    defer model.release();

    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const options = parseOptions(arena, options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    var embedded = ai.embed(runtime.io(), allocator, .{
        .model = .{ .model = model.interface },
        .value = input,
        .max_retries = options.max_retries,
        .headers = options.headers,
        .provider_options = options.provider_options,
        .diag = &diagnostics,
    }) catch |err| return runtime.fail(err, &diagnostics);
    defer embedded.deinit();
    const document: EmbedDocument = .{
        .value = embedded.value,
        .embedding = embedded.embedding,
        .usage = embedded.usage,
        .warnings = embedded.warnings,
        .provider_metadata = embedded.provider_metadata,
        .response = embedded.response,
    };
    const result = result_api.create(
        runtime,
        document,
        "",
        "",
        embedded.usage.tokens orelse 0,
        &.{},
    ) catch |err| return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

pub export fn ai_embed_many(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_embedding_model,
    values: [*c]const types.ai_string,
    values_len: usize,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.embeddingModelFromHandle(value) else return runtime.invalid("embedding model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    if (values_len != 0 and values == null) return runtime.invalid("values pointer is null", "values");
    model.retain();
    defer model.release();

    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const options = parseOptions(arena, options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    const input = arena.alloc([]const u8, values_len) catch |err| return runtime.fail(err, null);
    for (values[0..values_len], input) |source, *destination| {
        if (source.len != 0 and source.ptr == null) return runtime.invalid("value pointer is null", "values");
        destination.* = if (source.len == 0) "" else source.ptr[0..source.len];
    }
    var embedded = ai.embedMany(runtime.io(), allocator, .{
        .model = .{ .model = model.interface },
        .values = input,
        .max_parallel_calls = options.max_parallel_calls,
        .max_retries = options.max_retries,
        .headers = options.headers,
        .provider_options = options.provider_options,
        .diag = &diagnostics,
    }) catch |err| return runtime.fail(err, &diagnostics);
    defer embedded.deinit();
    const document: EmbedManyDocument = .{
        .values = embedded.values,
        .embeddings = embedded.embeddings,
        .usage = embedded.usage,
        .warnings = embedded.warnings,
        .provider_metadata = embedded.provider_metadata,
        .responses = embedded.responses,
    };
    const result = result_api.create(
        runtime,
        document,
        "",
        "",
        embedded.usage.tokens orelse 0,
        &.{},
    ) catch |err| return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

fn parseOptions(
    arena: Allocator,
    ptr: [*c]const u8,
    len: usize,
    diagnostics: *provider.Diagnostics,
) provider.CallError!WireOptions {
    const text = providers.optionalSlice(ptr, len) catch {
        setInvalid(diagnostics, "optionsJson pointer is null", "optionsJson");
        return error.InvalidArgumentError;
    };
    const source = if (text.len == 0) "{}" else text;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setInvalid(diagnostics, "optionsJson is not valid JSON", "optionsJson");
            return error.InvalidArgumentError;
        },
    };
    return provider.wire.parse(WireOptions, arena, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setInvalid(diagnostics, "optionsJson does not match embedding options", "optionsJson");
            return error.InvalidArgumentError;
        },
    };
}

fn setInvalid(diagnostics: *provider.Diagnostics, message: []const u8, parameter: []const u8) void {
    provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .invalid_argument = .{
        .message = message,
        .parameter = parameter,
    } });
}
