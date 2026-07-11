const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const options_api = @import("options.zig");
const providers = @import("providers.zig");
const result_api = @import("result.zig");
const runtime_api = @import("runtime.zig");
const stream_api = @import("stream.zig");
const types = @import("types.zig");
const wire_json = @import("wire_json.zig");

const Allocator = std.mem.Allocator;

const ObjectDocument = struct {
    object: std.json.Value,
    reasoning: ?[]const u8,
    finish_reason: provider.FinishReason,
    usage: provider.Usage,
    warnings: []const provider.Warning,
    request: ai.generate_text_types.RequestMetadata,
    response: ai.generate_text_types.ResponseMetadata,
    provider_metadata: ?provider.ProviderMetadata,
};

pub export fn ai_generate_object(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    schema_json: [*c]const u8,
    schema_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.modelFromHandle(value) else return runtime.invalid("model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    model.retain();
    defer model.release();

    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const parsed = options_api.parse(arena, options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    validateOptions(parsed, &diagnostics) catch |err| return runtime.fail(err, &diagnostics);
    const schema = parseSchema(arena, schema_json, schema_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    var generated = ai.generateObject(runtime.io(), allocator, objectOptions(
        parsed,
        model.interface,
        schema,
        &diagnostics,
    )) catch |err| return runtime.fail(err, &diagnostics);
    defer generated.deinit();
    const document: ObjectDocument = .{
        .object = generated.object,
        .reasoning = generated.reasoning,
        .finish_reason = generated.finish_reason,
        .usage = generated.usage,
        .warnings = generated.warnings,
        .request = generated.request,
        .response = generated.response,
        .provider_metadata = generated.provider_metadata,
    };
    const total = (generated.usage.input_tokens.total orelse 0) +|
        (generated.usage.output_tokens.total orelse 0);
    const result = result_api.create(
        runtime,
        document,
        "",
        wire_json.finishReasonName(generated.finish_reason),
        total,
        &.{},
    ) catch |err| return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

pub export fn ai_stream_object(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    schema_json: [*c]const u8,
    schema_json_len: usize,
    out: [*c]?*types.ai_stream,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.modelFromHandle(value) else return runtime.invalid("model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    model.retain();
    const self = stream_api.allocateForOwner(runtime, model, releaseModel) catch |err| {
        model.release();
        return runtime.fail(err, null);
    };
    const arena = self.request_arena_state.allocator();
    const parsed = options_api.parse(arena, options_json, options_json_len, &self.diagnostics) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        stream_api.discardBeforeStart(self);
        return status;
    };
    validateOptions(parsed, &self.diagnostics) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        stream_api.discardBeforeStart(self);
        return status;
    };
    const schema = parseSchema(arena, schema_json, schema_json_len, &self.diagnostics) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        stream_api.discardBeforeStart(self);
        return status;
    };
    const object_stream = ai.streamObject(runtime.io(), runtime.allocator(), streamObjectOptions(
        parsed,
        model.interface,
        schema,
        &self.diagnostics,
    )) catch |err| {
        const status = runtime.fail(err, &self.diagnostics);
        stream_api.discardBeforeStart(self);
        return status;
    };
    return stream_api.startObjectPrepared(self, object_stream, out);
}

fn parseSchema(
    arena: Allocator,
    ptr: [*c]const u8,
    len: usize,
    diagnostics: *provider.Diagnostics,
) provider.CallError!provider_utils.Schema {
    const source = providers.requiredSlice(ptr, len) catch {
        setInvalid(diagnostics, "schemaJson is required", "schemaJson");
        return error.InvalidArgumentError;
    };
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setInvalid(diagnostics, "schemaJson is not valid JSON", "schemaJson");
            return error.InvalidArgumentError;
        },
    };
    return provider_utils.rawSchema(try arena.dupe(u8, source), null);
}

fn objectOptions(
    parsed: options_api.ParsedOptions,
    model: provider.LanguageModel,
    schema: provider_utils.Schema,
    diagnostics: *provider.Diagnostics,
) ai.GenerateObjectOptions {
    return .{
        .model = .{ .model = model },
        .instructions = if (parsed.wire.instructions) |value| .{ .text = value } else null,
        .prompt = if (parsed.wire.prompt) |value| .{ .text = value } else null,
        .messages = parsed.wire.messages,
        .allow_system_in_messages = parsed.wire.allow_system_in_messages,
        .max_output_tokens = parsed.wire.max_output_tokens,
        .temperature = parsed.wire.temperature,
        .top_p = parsed.wire.top_p,
        .top_k = parsed.wire.top_k,
        .presence_penalty = parsed.wire.presence_penalty,
        .frequency_penalty = parsed.wire.frequency_penalty,
        .seed = parsed.wire.seed,
        .headers = parsed.wire.headers,
        .provider_options = parsed.wire.provider_options,
        .max_retries = parsed.wire.max_retries,
        .output = .object,
        .schema = schema,
        .diag = diagnostics,
    };
}

fn streamObjectOptions(
    parsed: options_api.ParsedOptions,
    model: provider.LanguageModel,
    schema: provider_utils.Schema,
    diagnostics: *provider.Diagnostics,
) ai.StreamObjectOptions {
    const generated = objectOptions(parsed, model, schema, diagnostics);
    return .{
        .model = generated.model,
        .instructions = generated.instructions,
        .prompt = generated.prompt,
        .messages = generated.messages,
        .allow_system_in_messages = generated.allow_system_in_messages,
        .max_output_tokens = generated.max_output_tokens,
        .temperature = generated.temperature,
        .top_p = generated.top_p,
        .top_k = generated.top_k,
        .presence_penalty = generated.presence_penalty,
        .frequency_penalty = generated.frequency_penalty,
        .seed = generated.seed,
        .headers = generated.headers,
        .provider_options = generated.provider_options,
        .max_retries = generated.max_retries,
        .output = generated.output,
        .schema = generated.schema,
        .diag = generated.diag,
    };
}

fn setInvalid(diagnostics: *provider.Diagnostics, message: []const u8, parameter: []const u8) void {
    provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .invalid_argument = .{
        .message = message,
        .parameter = parameter,
    } });
}

fn validateOptions(
    parsed: options_api.ParsedOptions,
    diagnostics: *provider.Diagnostics,
) provider.Error!void {
    if (parsed.wire.max_steps != 1) {
        setInvalid(diagnostics, "generateObject is single-step; maxSteps must be 1", "maxSteps");
        return error.InvalidArgumentError;
    }
    if (parsed.tool_choice != null or
        parsed.timeout != null or
        parsed.wire.stop_sequences != null or
        parsed.wire.reasoning != null or
        parsed.wire.tools_context != null or
        parsed.wire.runtime_context != null or
        parsed.wire.include_raw_chunks)
    {
        setInvalid(
            diagnostics,
            "optionsJson contains a generateText-only field unsupported by generateObject",
            "optionsJson",
        );
        return error.InvalidArgumentError;
    }
}

fn releaseModel(raw: *anyopaque) void {
    const model: *providers.Model = @ptrCast(@alignCast(raw));
    model.release();
}
