//! Language-model middleware and the Phase 4a non-stream-state built-ins.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub const OperationType = enum { generate, stream };

pub const GenerateThunk = struct {
    ctx: *anyopaque,
    call_fn: *const fn (ctx: *anyopaque) provider.CallError!provider.GenerateResult,

    pub fn call(self: GenerateThunk) provider.CallError!provider.GenerateResult {
        return self.call_fn(self.ctx);
    }
};

pub const StreamThunk = struct {
    ctx: *anyopaque,
    call_fn: *const fn (ctx: *anyopaque) provider.CallError!provider.StreamResult,

    pub fn call(self: StreamThunk) provider.CallError!provider.StreamResult {
        return self.call_fn(self.ctx);
    }
};

pub const WrapContext = struct {
    io: std.Io,
    arena: Allocator,
    params: *const provider.CallOptions,
    model: provider.LanguageModel,
    do_generate: GenerateThunk,
    do_stream: StreamThunk,
};

pub const LanguageModelMiddleware = struct {
    ctx: ?*anyopaque = null,
    override_provider: ?*const fn (ctx: ?*anyopaque, model: provider.LanguageModel) []const u8 = null,
    override_model_id: ?*const fn (ctx: ?*anyopaque, model: provider.LanguageModel) []const u8 = null,
    transform_params: ?*const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        operation: OperationType,
        params: *const provider.CallOptions,
        model: provider.LanguageModel,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!*const provider.CallOptions = null,
    wrap_generate: ?*const fn (
        ctx: ?*anyopaque,
        wrap: *const WrapContext,
    ) provider.CallError!provider.GenerateResult = null,
    wrap_stream: ?*const fn (
        ctx: ?*anyopaque,
        wrap: *const WrapContext,
    ) provider.CallError!provider.StreamResult = null,
};

const CallContext = struct {
    io: std.Io,
    arena: Allocator,
    model: provider.LanguageModel,
    params: *const provider.CallOptions,
    diag: ?*provider.Diagnostics,

    fn generate(raw: *anyopaque) provider.CallError!provider.GenerateResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.model.doGenerate(self.io, self.arena, self.params, self.diag);
    }

    fn stream(raw: *anyopaque) provider.CallError!provider.StreamResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.model.doStream(self.io, self.arena, self.params, self.diag);
    }
};

const WrappedModel = struct {
    inner: provider.LanguageModel,
    middleware: LanguageModelMiddleware,

    const vtable: provider.LanguageModel.VTable = .{
        .provider = modelProvider,
        .modelId = modelId,
        .urlIsSupported = urlIsSupported,
        .doGenerate = doGenerate,
        .doStream = doStream,
    };

    fn fromRaw(raw: *anyopaque) *WrappedModel {
        return @ptrCast(@alignCast(raw));
    }

    fn languageModel(self: *WrappedModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn modelProvider(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        if (self.middleware.override_provider) |override| {
            return override(self.middleware.ctx, self.inner);
        }
        return self.inner.provider();
    }

    fn modelId(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        if (self.middleware.override_model_id) |override| {
            return override(self.middleware.ctx, self.inner);
        }
        return self.inner.modelId();
    }

    fn urlIsSupported(raw: *anyopaque, media_type: []const u8, url: []const u8) bool {
        return fromRaw(raw).inner.urlIsSupported(media_type, url);
    }

    fn doGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        params: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const self = fromRaw(raw);
        const transformed = if (self.middleware.transform_params) |transform|
            try transform(self.middleware.ctx, arena, .generate, params, self.inner, diag)
        else
            params;
        var call_context: CallContext = .{
            .io = io,
            .arena = arena,
            .model = self.inner,
            .params = transformed,
            .diag = diag,
        };
        const wrap: WrapContext = .{
            .io = io,
            .arena = arena,
            .params = transformed,
            .model = self.inner,
            .do_generate = .{ .ctx = &call_context, .call_fn = CallContext.generate },
            .do_stream = .{ .ctx = &call_context, .call_fn = CallContext.stream },
        };
        if (self.middleware.wrap_generate) |wrapper| {
            return wrapper(self.middleware.ctx, &wrap);
        }
        return wrap.do_generate.call();
    }

    fn doStream(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        params: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const self = fromRaw(raw);
        const transformed = if (self.middleware.transform_params) |transform|
            try transform(self.middleware.ctx, arena, .stream, params, self.inner, diag)
        else
            params;
        var call_context: CallContext = .{
            .io = io,
            .arena = arena,
            .model = self.inner,
            .params = transformed,
            .diag = diag,
        };
        const wrap: WrapContext = .{
            .io = io,
            .arena = arena,
            .params = transformed,
            .model = self.inner,
            .do_generate = .{ .ctx = &call_context, .call_fn = CallContext.generate },
            .do_stream = .{ .ctx = &call_context, .call_fn = CallContext.stream },
        };
        if (self.middleware.wrap_stream) |wrapper| {
            return wrapper(self.middleware.ctx, &wrap);
        }
        return wrap.do_stream.call();
    }
};

/// Reverse-folds middleware into an arena-owned model chain. The first
/// middleware transforms first and is the outermost wrapper.
pub fn wrapLanguageModel(
    arena: Allocator,
    model: provider.LanguageModel,
    middlewares: []const LanguageModelMiddleware,
) Allocator.Error!provider.LanguageModel {
    var result = model;
    var index = middlewares.len;
    while (index != 0) {
        index -= 1;
        const wrapped = try arena.create(WrappedModel);
        wrapped.* = .{ .inner = result, .middleware = middlewares[index] };
        result = wrapped.languageModel();
    }
    return result;
}

pub const DefaultSettings = struct {
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    response_format: ?provider.ResponseFormat = null,
    seed: ?i64 = null,
    tools: ?[]const provider.Tool = null,
    tool_choice: ?provider.ToolChoice = null,
    headers: ?provider.Headers = null,
    reasoning: ?provider.ReasoningEffort = null,
    provider_options: ?provider.ProviderOptions = null,
};

pub fn defaultSettingsMiddleware(settings: *const DefaultSettings) LanguageModelMiddleware {
    return .{ .ctx = @ptrCast(@constCast(settings)), .transform_params = transformDefaultSettings };
}

fn transformDefaultSettings(
    raw: ?*anyopaque,
    arena: Allocator,
    _: OperationType,
    params: *const provider.CallOptions,
    _: provider.LanguageModel,
    _: ?*provider.Diagnostics,
) provider.CallError!*const provider.CallOptions {
    const settings: *const DefaultSettings = @ptrCast(@alignCast(raw.?));
    const result = try arena.create(provider.CallOptions);
    result.* = params.*;
    if (result.max_output_tokens == null) result.max_output_tokens = settings.max_output_tokens;
    if (result.temperature == null) result.temperature = settings.temperature;
    if (result.stop_sequences == null) result.stop_sequences = settings.stop_sequences;
    if (result.top_p == null) result.top_p = settings.top_p;
    if (result.top_k == null) result.top_k = settings.top_k;
    if (result.presence_penalty == null) result.presence_penalty = settings.presence_penalty;
    if (result.frequency_penalty == null) result.frequency_penalty = settings.frequency_penalty;
    if (result.response_format == null) result.response_format = settings.response_format;
    if (result.seed == null) result.seed = settings.seed;
    if (result.tools == null) result.tools = settings.tools;
    if (result.tool_choice == null) result.tool_choice = settings.tool_choice;
    if (result.reasoning == null) result.reasoning = settings.reasoning;
    result.headers = try mergeHeaders(arena, settings.headers, params.headers);
    result.provider_options = try mergeOptionalJson(
        arena,
        settings.provider_options,
        params.provider_options,
    );
    return result;
}

fn mergeHeaders(
    arena: Allocator,
    defaults: ?provider.Headers,
    overrides: ?provider.Headers,
) Allocator.Error!?provider.Headers {
    if (defaults == null and overrides == null) return null;
    const default_entries = try toHeaderEntries(arena, defaults orelse &.{});
    const override_entries = try toHeaderEntries(arena, overrides orelse &.{});
    const lists = [_][]const provider_utils.HeaderEntry{ default_entries, override_entries };
    return try provider_utils.combineHeaders(arena, &lists);
}

fn toHeaderEntries(
    arena: Allocator,
    headers: provider.Headers,
) Allocator.Error![]const provider_utils.HeaderEntry {
    const result = try arena.alloc(provider_utils.HeaderEntry, headers.len);
    for (headers, result) |header, *entry| entry.* = .{
        .name = header.name,
        .value = header.value,
    };
    return result;
}

fn mergeOptionalJson(
    arena: Allocator,
    defaults: ?std.json.Value,
    overrides: ?std.json.Value,
) Allocator.Error!?std.json.Value {
    if (defaults == null and overrides == null) return null;
    if (defaults == null) return try provider_utils.cloneJsonValue(arena, overrides.?);
    if (overrides == null) return try provider_utils.cloneJsonValue(arena, defaults.?);
    return try mergeJson(arena, defaults.?, overrides.?);
}

fn mergeJson(arena: Allocator, base: std.json.Value, overrides: std.json.Value) Allocator.Error!std.json.Value {
    if (base != .object or overrides != .object) {
        return provider_utils.cloneJsonValue(arena, overrides);
    }
    var object: std.json.ObjectMap = .empty;
    var base_iterator = base.object.iterator();
    while (base_iterator.next()) |entry| {
        try object.put(
            arena,
            try arena.dupe(u8, entry.key_ptr.*),
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
        );
    }
    var override_iterator = overrides.object.iterator();
    while (override_iterator.next()) |entry| {
        const merged = if (object.get(entry.key_ptr.*)) |existing|
            try mergeJson(arena, existing, entry.value_ptr.*)
        else
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*);
        try object.put(arena, try arena.dupe(u8, entry.key_ptr.*), merged);
    }
    return .{ .object = object };
}

pub const ToolInputExamplesOptions = struct {
    prefix: []const u8 = "Input Examples:",
    remove: bool = true,
};

pub fn addToolInputExamplesMiddleware(options: *const ToolInputExamplesOptions) LanguageModelMiddleware {
    return .{ .ctx = @ptrCast(@constCast(options)), .transform_params = transformToolExamples };
}

fn transformToolExamples(
    raw: ?*anyopaque,
    arena: Allocator,
    _: OperationType,
    params: *const provider.CallOptions,
    _: provider.LanguageModel,
    _: ?*provider.Diagnostics,
) provider.CallError!*const provider.CallOptions {
    const options: *const ToolInputExamplesOptions = @ptrCast(@alignCast(raw.?));
    const tools = params.tools orelse return params;
    if (tools.len == 0) return params;

    const transformed = try arena.alloc(provider.Tool, tools.len);
    for (tools, transformed) |input_tool, *output_tool| switch (input_tool) {
        .provider => output_tool.* = input_tool,
        .function => |function_tool| {
            const examples = function_tool.input_examples orelse {
                output_tool.* = input_tool;
                continue;
            };
            if (examples.len == 0) {
                output_tool.* = input_tool;
                continue;
            }
            var description: std.Io.Writer.Allocating = .init(arena);
            defer description.deinit();
            if (function_tool.description) |text| {
                description.writer.print("{s}\n\n", .{text}) catch return error.OutOfMemory;
            }
            description.writer.print("{s}\n", .{options.prefix}) catch return error.OutOfMemory;
            for (examples, 0..) |example, index| {
                if (index != 0) description.writer.writeByte('\n') catch return error.OutOfMemory;
                const encoded = try provider_utils.stringifyJsonValueAlloc(arena, example.input);
                description.writer.writeAll(encoded) catch return error.OutOfMemory;
            }
            var updated = function_tool;
            updated.description = try description.toOwnedSlice();
            if (options.remove) updated.input_examples = null;
            output_tool.* = .{ .function = updated };
        },
    };
    const result = try arena.create(provider.CallOptions);
    result.* = params.*;
    result.tools = transformed;
    return result;
}

// TODO(phase-5): extractReasoningMiddleware, extractJsonMiddleware, and
// simulateStreamingMiddleware are stream state machines and land with the
// Phase 5 pull-stage framework.

test "wrapLanguageModel transforms first-to-last and wraps outermost-first" {
    const Trace = struct {
        bytes: *[16]u8,
        index: *usize,
        transform_byte: u8,
        before_byte: u8,
        after_byte: u8,

        fn transform(
            raw: ?*anyopaque,
            _: Allocator,
            _: OperationType,
            params: *const provider.CallOptions,
            _: provider.LanguageModel,
            _: ?*provider.Diagnostics,
        ) provider.CallError!*const provider.CallOptions {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.bytes[self.index.*] = self.transform_byte;
            self.index.* += 1;
            return params;
        }

        fn wrapGenerate(raw: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.GenerateResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.bytes[self.index.*] = self.before_byte;
            self.index.* += 1;
            const result = try wrap.do_generate.call();
            self.bytes[self.index.*] = self.after_byte;
            self.index.* += 1;
            return result;
        }
    };
    const Base = struct {
        trace: *[16]u8,
        index: *usize,

        fn providerName(_: *anyopaque) []const u8 {
            return "base";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "model";
        }
        fn supported(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn generate(
            raw: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: *const provider.CallOptions,
            _: ?*provider.Diagnostics,
        ) provider.CallError!provider.GenerateResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.trace[self.index.*] = 5;
            self.index.* += 1;
            return .{
                .content = &.{},
                .finish_reason = .{ .unified = .stop },
                .usage = .{ .input_tokens = .{}, .output_tokens = .{} },
                .warnings = &.{},
            };
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

    var bytes: [16]u8 = undefined;
    var index: usize = 0;
    var base_context: Base = .{ .trace = &bytes, .index = &index };
    const base: provider.LanguageModel = .{ .ctx = &base_context, .vtable = &.{
        .provider = Base.providerName,
        .modelId = Base.modelId,
        .urlIsSupported = Base.supported,
        .doGenerate = Base.generate,
        .doStream = Base.stream,
    } };
    var first: Trace = .{
        .bytes = &bytes,
        .index = &index,
        .transform_byte = 1,
        .before_byte = 2,
        .after_byte = 7,
    };
    var second: Trace = .{
        .bytes = &bytes,
        .index = &index,
        .transform_byte = 3,
        .before_byte = 4,
        .after_byte = 6,
    };
    const middlewares = [_]LanguageModelMiddleware{
        .{ .ctx = &first, .transform_params = Trace.transform, .wrap_generate = Trace.wrapGenerate },
        .{ .ctx = &second, .transform_params = Trace.transform, .wrap_generate = Trace.wrapGenerate },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try wrapLanguageModel(arena, base, &middlewares);
    const options: provider.CallOptions = .{ .prompt = &.{} };
    _ = try wrapped.doGenerate(std.testing.io, arena, &options, null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7 }, bytes[0..7]);
}

test "wrapLanguageModel stream path has the same transform and nesting order" {
    const Trace = struct {
        bytes: *[16]u8,
        index: *usize,
        transform_byte: u8,
        before_byte: u8,
        after_byte: u8,

        fn transform(
            raw: ?*anyopaque,
            _: Allocator,
            operation: OperationType,
            params: *const provider.CallOptions,
            _: provider.LanguageModel,
            _: ?*provider.Diagnostics,
        ) provider.CallError!*const provider.CallOptions {
            std.debug.assert(operation == .stream);
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.bytes[self.index.*] = self.transform_byte;
            self.index.* += 1;
            return params;
        }

        fn wrapStream(raw: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.StreamResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.bytes[self.index.*] = self.before_byte;
            self.index.* += 1;
            const result = try wrap.do_stream.call();
            self.bytes[self.index.*] = self.after_byte;
            self.index.* += 1;
            return result;
        }
    };
    const Base = struct {
        trace: *[16]u8,
        index: *usize,

        fn p(_: *anyopaque) []const u8 {
            return "base";
        }
        fn m(_: *anyopaque) []const u8 {
            return "model";
        }
        fn u(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn g(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
            return error.UnsupportedFunctionalityError;
        }
        fn s(raw: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.trace[self.index.*] = 5;
            self.index.* += 1;
            return .{ .stream = .{ .ctx = raw, .vtable = &stream_vtable } };
        }
        fn next(_: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
            return null;
        }
        fn deinit(_: *anyopaque, _: std.Io) void {}
        const stream_vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };
    };

    var bytes: [16]u8 = undefined;
    var index: usize = 0;
    var base_context: Base = .{ .trace = &bytes, .index = &index };
    const base: provider.LanguageModel = .{ .ctx = &base_context, .vtable = &.{
        .provider = Base.p,
        .modelId = Base.m,
        .urlIsSupported = Base.u,
        .doGenerate = Base.g,
        .doStream = Base.s,
    } };
    var first: Trace = .{ .bytes = &bytes, .index = &index, .transform_byte = 1, .before_byte = 2, .after_byte = 7 };
    var second: Trace = .{ .bytes = &bytes, .index = &index, .transform_byte = 3, .before_byte = 4, .after_byte = 6 };
    const middlewares = [_]LanguageModelMiddleware{
        .{ .ctx = &first, .transform_params = Trace.transform, .wrap_stream = Trace.wrapStream },
        .{ .ctx = &second, .transform_params = Trace.transform, .wrap_stream = Trace.wrapStream },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = try wrapLanguageModel(arena, base, &middlewares);
    const params: provider.CallOptions = .{ .prompt = &.{} };
    const stream = try wrapped.doStream(std.testing.io, arena, &params, null);
    stream.stream.deinit(std.testing.io);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7 }, bytes[0..7]);
}

test "default settings params win and provider options deep merge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const defaults_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"anthropic\":{\"cache\":{\"type\":\"ephemeral\"},\"feature\":true}}",
        .{},
    );
    const params_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"anthropic\":{\"feature\":false,\"other\":1}}",
        .{},
    );
    const defaults: DefaultSettings = .{ .temperature = 0.7, .provider_options = defaults_json };
    const middleware = defaultSettingsMiddleware(&defaults);
    const params: provider.CallOptions = .{
        .prompt = &.{},
        .temperature = 0.5,
        .provider_options = params_json,
    };
    var marker: u8 = 0;
    const Dummy = struct {
        fn p(_: *anyopaque) []const u8 {
            return "p";
        }
        fn m(_: *anyopaque) []const u8 {
            return "m";
        }
        fn u(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn g(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
            return error.UnsupportedFunctionalityError;
        }
        fn s(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
            return error.UnsupportedFunctionalityError;
        }
    };
    const model: provider.LanguageModel = .{ .ctx = &marker, .vtable = &.{
        .provider = Dummy.p,
        .modelId = Dummy.m,
        .urlIsSupported = Dummy.u,
        .doGenerate = Dummy.g,
        .doStream = Dummy.s,
    } };
    const transformed = try middleware.transform_params.?(
        middleware.ctx,
        arena,
        .generate,
        &params,
        model,
        null,
    );
    try std.testing.expectEqual(0.5, transformed.temperature.?);
    const anthropic = transformed.provider_options.?.object.get("anthropic").?.object;
    try std.testing.expect(anthropic.get("cache") != null);
    try std.testing.expectEqual(false, anthropic.get("feature").?.bool);
    try std.testing.expectEqual(1, anthropic.get("other").?.integer);
}

test "addToolInputExamples rewrites description and removes flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var input: std.json.ObjectMap = .empty;
    try input.put(arena, "location", .{ .string = "London" });
    const examples = [_]provider.FunctionTool.InputExample{.{ .input = .{ .object = input } }};
    const tools = [_]provider.Tool{.{ .function = .{
        .name = "weather",
        .description = "Get weather",
        .input_schema = .{ .object = .empty },
        .input_examples = &examples,
    } }};
    const params: provider.CallOptions = .{ .prompt = &.{}, .tools = &tools };
    const options: ToolInputExamplesOptions = .{};
    const middleware = addToolInputExamplesMiddleware(&options);
    var marker: u8 = 0;
    const Dummy = struct {
        fn p(_: *anyopaque) []const u8 {
            return "p";
        }
        fn m(_: *anyopaque) []const u8 {
            return "m";
        }
        fn u(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn g(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.GenerateResult {
            return error.UnsupportedFunctionalityError;
        }
        fn s(_: *anyopaque, _: std.Io, _: Allocator, _: *const provider.CallOptions, _: ?*provider.Diagnostics) provider.CallError!provider.StreamResult {
            return error.UnsupportedFunctionalityError;
        }
    };
    const model: provider.LanguageModel = .{ .ctx = &marker, .vtable = &.{
        .provider = Dummy.p,
        .modelId = Dummy.m,
        .urlIsSupported = Dummy.u,
        .doGenerate = Dummy.g,
        .doStream = Dummy.s,
    } };
    const transformed = try middleware.transform_params.?(
        middleware.ctx,
        arena,
        .generate,
        &params,
        model,
        null,
    );
    try std.testing.expectEqualStrings(
        "Get weather\n\nInput Examples:\n{\"location\":\"London\"}",
        transformed.tools.?[0].function.description.?,
    );
    try std.testing.expectEqual(null, transformed.tools.?[0].function.input_examples);
}
