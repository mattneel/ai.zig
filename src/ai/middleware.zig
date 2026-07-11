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

/// Synthesizes the canonical provider stream from one `doGenerate` call.
pub fn simulateStreamingMiddleware() LanguageModelMiddleware {
    return .{ .wrap_stream = wrapSimulatedStream };
}

fn wrapSimulatedStream(_: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.StreamResult {
    const generated = try wrap.do_generate.call();
    const state = try wrap.arena.create(SimulatedStreamState);
    state.* = .{ .arena = wrap.arena, .generated = generated };
    return .{
        .stream = .{ .ctx = state, .vtable = &SimulatedStreamState.vtable },
        .request = generated.request orelse .{},
        .response = .{ .headers = if (generated.response) |response| response.headers else null },
    };
}

const SimulatedStreamState = struct {
    arena: Allocator,
    generated: provider.GenerateResult,
    phase: enum { stream_start, response_metadata, content, finish, done } = .stream_start,
    content_index: usize = 0,
    id_counter: usize = 0,
    subphase: u2 = 0,

    const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
        const self: *SimulatedStreamState = @ptrCast(@alignCast(raw));
        while (true) switch (self.phase) {
            .stream_start => {
                self.phase = .response_metadata;
                return .{ .stream_start = .{ .warnings = self.generated.warnings } };
            },
            .response_metadata => {
                self.phase = .content;
                const response = self.generated.response orelse provider.ResponseInfo{};
                return .{ .response_metadata = .{
                    .id = response.id,
                    .timestamp_ms = response.timestamp_ms,
                    .model_id = response.model_id,
                } };
            },
            .content => {
                if (self.content_index == self.generated.content.len) {
                    self.phase = .finish;
                    continue;
                }
                const content = self.generated.content[self.content_index];
                switch (content) {
                    .text => |value| {
                        if (value.text.len == 0) {
                            self.content_index += 1;
                            continue;
                        }
                        const id = try std.fmt.allocPrint(self.arena, "{d}", .{self.id_counter});
                        switch (self.subphase) {
                            0 => {
                                self.subphase = 1;
                                return .{ .text_start = .{ .id = id } };
                            },
                            1 => {
                                self.subphase = 2;
                                return .{ .text_delta = .{ .id = id, .delta = value.text } };
                            },
                            else => {
                                self.subphase = 0;
                                self.content_index += 1;
                                self.id_counter += 1;
                                return .{ .text_end = .{ .id = id } };
                            },
                        }
                    },
                    .reasoning => |value| {
                        const id = try std.fmt.allocPrint(self.arena, "{d}", .{self.id_counter});
                        switch (self.subphase) {
                            0 => {
                                self.subphase = 1;
                                return .{ .reasoning_start = .{
                                    .id = id,
                                    .provider_metadata = value.provider_metadata,
                                } };
                            },
                            1 => {
                                self.subphase = 2;
                                return .{ .reasoning_delta = .{ .id = id, .delta = value.text } };
                            },
                            else => {
                                self.subphase = 0;
                                self.content_index += 1;
                                self.id_counter += 1;
                                return .{ .reasoning_end = .{ .id = id } };
                            },
                        }
                    },
                    .tool_call => |value| {
                        self.content_index += 1;
                        return .{ .tool_call = value };
                    },
                    .tool_result => |value| {
                        self.content_index += 1;
                        return .{ .tool_result = value };
                    },
                    .tool_approval_request => |value| {
                        self.content_index += 1;
                        return .{ .tool_approval_request = value };
                    },
                    .custom => |value| {
                        self.content_index += 1;
                        return .{ .custom = value };
                    },
                    .file => |value| {
                        self.content_index += 1;
                        return .{ .file = value };
                    },
                    .reasoning_file => |value| {
                        self.content_index += 1;
                        return .{ .reasoning_file = value };
                    },
                    .source => |value| {
                        self.content_index += 1;
                        return .{ .source = value };
                    },
                }
            },
            .finish => {
                self.phase = .done;
                return .{ .finish = .{
                    .finish_reason = self.generated.finish_reason,
                    .usage = self.generated.usage,
                    .provider_metadata = self.generated.provider_metadata,
                } };
            },
            .done => return null,
        };
    }

    fn deinit(_: *anyopaque, _: std.Io) void {}
};

pub const JsonTransform = struct {
    ctx: ?*anyopaque = null,
    transform_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        text: []const u8,
    ) provider.CallError![]const u8,

    pub fn transform(self: JsonTransform, arena: Allocator, text: []const u8) provider.CallError![]const u8 {
        return self.transform_fn(self.ctx, arena, text);
    }
};

pub const ExtractJsonOptions = struct {
    transform: ?JsonTransform = null,
};

/// Strips Markdown JSON fences. `options` is borrowed for the wrapped model's
/// lifetime; pass `null` for the built-in transform.
pub fn extractJsonMiddleware(options: ?*const ExtractJsonOptions) LanguageModelMiddleware {
    return .{
        .ctx = @ptrCast(@constCast(options)),
        .wrap_generate = wrapGenerateJson,
        .wrap_stream = wrapStreamJson,
    };
}

fn jsonOptions(raw: ?*anyopaque) ExtractJsonOptions {
    const options: *const ExtractJsonOptions = @ptrCast(@alignCast(raw orelse return .{}));
    return options.*;
}

fn wrapGenerateJson(raw: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.GenerateResult {
    const generated = try wrap.do_generate.call();
    const output = try wrap.arena.alloc(provider.Content, generated.content.len);
    const options = jsonOptions(raw);
    for (generated.content, output) |part, *transformed| switch (part) {
        .text => |value| {
            var text_value = value;
            text_value.text = if (options.transform) |custom|
                try custom.transform(wrap.arena, value.text)
            else
                try defaultJsonTransform(wrap.arena, value.text);
            transformed.* = .{ .text = text_value };
        },
        else => transformed.* = part,
    };
    var result = generated;
    result.content = output;
    return result;
}

fn wrapStreamJson(raw: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.StreamResult {
    const streamed = try wrap.do_stream.call();
    const state = try wrap.arena.create(JsonStreamState);
    const options = jsonOptions(raw);
    state.* = .{
        .arena = wrap.arena,
        .upstream = streamed.stream,
        .custom_transform = options.transform,
    };
    var result = streamed;
    result.stream = .{ .ctx = state, .vtable = &JsonStreamState.vtable };
    return result;
}

const JsonStreamState = struct {
    arena: Allocator,
    upstream: provider.PartStream,
    custom_transform: ?JsonTransform,
    blocks: std.StringHashMapUnmanaged(*Block) = .empty,
    pending: [3]provider.StreamPart = undefined,
    pending_len: usize = 0,
    pending_index: usize = 0,
    deinitialized: bool = false,

    const suffix_buffer_size = 12;
    const Phase = enum { prefix, streaming, buffering };
    const Block = struct {
        start: provider.language_model.BlockBoundary,
        phase: Phase,
        buffer: std.ArrayList(u8) = .empty,
        prefix_stripped: bool = false,
    };

    const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw_state: *anyopaque, io: std.Io) provider.NextError!?provider.StreamPart {
        const self: *JsonStreamState = @ptrCast(@alignCast(raw_state));
        while (true) {
            if (self.pending_index < self.pending_len) {
                defer self.pending_index += 1;
                return self.pending[self.pending_index];
            }
            self.pending_index = 0;
            self.pending_len = 0;

            const part = (try self.upstream.next(io)) orelse return null;
            switch (part) {
                .text_start => |value| {
                    const block = try self.arena.create(Block);
                    block.* = .{
                        .start = .{
                            .id = try self.arena.dupe(u8, value.id),
                            .provider_metadata = if (value.provider_metadata) |metadata|
                                try provider_utils.cloneJsonValue(self.arena, metadata)
                            else
                                null,
                        },
                        .phase = if (self.custom_transform != null) .buffering else .prefix,
                    };
                    try self.blocks.put(self.arena, block.start.id, block);
                    continue;
                },
                .text_delta => |value| {
                    const block = self.blocks.get(value.id) orelse return part;
                    try block.buffer.appendSlice(self.arena, value.delta);
                    if (block.phase == .buffering) continue;
                    if (block.phase == .prefix) try self.resolvePrefix(block);
                    if (block.phase == .streaming and block.buffer.items.len > suffix_buffer_size) {
                        const stream_len = block.buffer.items.len - suffix_buffer_size;
                        const delta = try self.arena.dupe(u8, block.buffer.items[0..stream_len]);
                        shiftBuffer(&block.buffer, stream_len);
                        self.push(.{ .text_delta = .{ .id = block.start.id, .delta = delta } });
                    }
                    if (self.pending_len != 0) continue;
                },
                .text_end => |value| {
                    const removed = self.blocks.fetchRemove(value.id) orelse return part;
                    const block = removed.value;
                    if (block.phase == .prefix or block.phase == .buffering) self.push(.{ .text_start = block.start });
                    const remaining = if (block.phase == .buffering)
                        try self.custom_transform.?.transform(self.arena, block.buffer.items)
                    else if (block.prefix_stripped or block.phase == .streaming)
                        try stripJsonSuffix(self.arena, block.buffer.items)
                    else
                        try defaultJsonTransform(self.arena, block.buffer.items);
                    if (remaining.len != 0) self.push(.{ .text_delta = .{
                        .id = block.start.id,
                        .delta = remaining,
                    } });
                    self.push(.{ .text_end = .{
                        .id = try self.arena.dupe(u8, value.id),
                        .provider_metadata = if (value.provider_metadata) |metadata|
                            try provider_utils.cloneJsonValue(self.arena, metadata)
                        else
                            null,
                    } });
                    continue;
                },
                else => return part,
            }
        }
    }

    fn resolvePrefix(self: *JsonStreamState, block: *Block) Allocator.Error!void {
        const buffer = block.buffer.items;
        if (buffer.len != 0 and buffer[0] != '`') {
            block.phase = .streaming;
            self.push(.{ .text_start = block.start });
            return;
        }
        if (std.mem.startsWith(u8, buffer, "```")) {
            const newline = std.mem.indexOfScalar(u8, buffer, '\n') orelse return;
            if (jsonFencePrefixLength(buffer[0 .. newline + 1])) |prefix_len| {
                shiftBuffer(&block.buffer, prefix_len);
                block.prefix_stripped = true;
            }
            block.phase = .streaming;
            self.push(.{ .text_start = block.start });
            return;
        }
        if (buffer.len >= 3) {
            block.phase = .streaming;
            self.push(.{ .text_start = block.start });
        }
    }

    fn push(self: *JsonStreamState, part: provider.StreamPart) void {
        std.debug.assert(self.pending_len < self.pending.len);
        self.pending[self.pending_len] = part;
        self.pending_len += 1;
    }

    fn deinit(raw_state: *anyopaque, io: std.Io) void {
        const self: *JsonStreamState = @ptrCast(@alignCast(raw_state));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.upstream.deinit(io);
    }
};

fn shiftBuffer(buffer: *std.ArrayList(u8), amount: usize) void {
    const remaining = buffer.items.len - amount;
    std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[amount..]);
    buffer.items.len = remaining;
}

fn jsonFencePrefixLength(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, "```")) return null;
    var index: usize = 3;
    if (std.mem.startsWith(u8, text[index..], "json")) index += 4;
    while (index < text.len and isFenceSpace(text[index])) index += 1;
    if (index < text.len and text[index] == '\n') return index + 1;
    return null;
}

fn defaultJsonTransform(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var value = text;
    if (std.mem.startsWith(u8, value, "```")) {
        var index: usize = 3;
        if (std.mem.startsWith(u8, value[index..], "json")) index += 4;
        while (index < value.len and isFenceSpace(value[index])) index += 1;
        if (index < value.len and value[index] == '\n') index += 1;
        value = value[index..];
    }
    value = try stripJsonSuffix(arena, value);
    return arena.dupe(u8, std.mem.trim(u8, value, " \t\r\n\x0b\x0c"));
}

fn stripJsonSuffix(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var end = text.len;
    while (end != 0 and isWhitespace(text[end - 1])) end -= 1;
    if (end >= 3 and std.mem.eql(u8, text[end - 3 .. end], "```")) {
        end -= 3;
        if (end != 0 and text[end - 1] == '\n') end -= 1;
        while (end != 0 and isWhitespace(text[end - 1])) end -= 1;
    }
    return arena.dupe(u8, text[0..end]);
}

fn isFenceSpace(value: u8) bool {
    return switch (value) {
        ' ', '\t', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn isWhitespace(value: u8) bool {
    return isFenceSpace(value) or value == '\n';
}

pub const ExtractReasoningOptions = struct {
    tag_name: []const u8,
    separator: []const u8 = "\n",
    starts_with_reasoning: bool = false,
};

/// Extracts `<tag>reasoning</tag>` from generated text. Options are borrowed
/// for the wrapped model's lifetime.
pub fn extractReasoningMiddleware(options: *const ExtractReasoningOptions) LanguageModelMiddleware {
    return .{
        .ctx = @ptrCast(@constCast(options)),
        .wrap_generate = wrapGenerateReasoning,
        .wrap_stream = wrapStreamReasoning,
    };
}

fn reasoningOptions(raw: ?*anyopaque) *const ExtractReasoningOptions {
    return @ptrCast(@alignCast(raw.?));
}

fn wrapGenerateReasoning(raw: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.GenerateResult {
    const options = reasoningOptions(raw);
    const generated = try wrap.do_generate.call();
    var output: std.ArrayList(provider.Content) = .empty;
    defer output.deinit(wrap.arena);
    const opening = try std.fmt.allocPrint(wrap.arena, "<{s}>", .{options.tag_name});
    const closing = try std.fmt.allocPrint(wrap.arena, "</{s}>", .{options.tag_name});

    for (generated.content) |part| switch (part) {
        .text => |value| {
            const input = if (options.starts_with_reasoning)
                try std.mem.concat(wrap.arena, u8, &.{ opening, value.text })
            else
                value.text;
            var reasoning_writer: std.Io.Writer.Allocating = .init(wrap.arena);
            defer reasoning_writer.deinit();
            var text_writer: std.Io.Writer.Allocating = .init(wrap.arena);
            defer text_writer.deinit();
            var cursor: usize = 0;
            var matched = false;
            while (std.mem.indexOfPos(u8, input, cursor, opening)) |open_index| {
                const reasoning_start = open_index + opening.len;
                const close_index = std.mem.indexOfPos(u8, input, reasoning_start, closing) orelse break;
                const segment = input[cursor..open_index];
                try appendSeparated(&text_writer.writer, options.separator, segment);
                try appendSeparated(
                    &reasoning_writer.writer,
                    options.separator,
                    input[reasoning_start..close_index],
                );
                cursor = close_index + closing.len;
                matched = true;
            }
            if (!matched) {
                try output.append(wrap.arena, part);
                continue;
            }
            try appendSeparated(&text_writer.writer, options.separator, input[cursor..]);
            try output.append(wrap.arena, .{ .reasoning = .{
                .text = try reasoning_writer.toOwnedSlice(),
            } });
            try output.append(wrap.arena, .{ .text = .{
                .text = try text_writer.toOwnedSlice(),
                .provider_metadata = value.provider_metadata,
            } });
        },
        else => try output.append(wrap.arena, part),
    };
    var result = generated;
    result.content = try output.toOwnedSlice(wrap.arena);
    return result;
}

fn appendSeparated(writer: *std.Io.Writer, separator: []const u8, value: []const u8) Allocator.Error!void {
    if (value.len == 0) return;
    if (writer.end != 0) writer.writeAll(separator) catch return error.OutOfMemory;
    writer.writeAll(value) catch return error.OutOfMemory;
}

fn wrapStreamReasoning(raw: ?*anyopaque, wrap: *const WrapContext) provider.CallError!provider.StreamResult {
    const options = reasoningOptions(raw);
    const streamed = try wrap.do_stream.call();
    const state = try wrap.arena.create(ReasoningStreamState);
    state.* = .{
        .arena = wrap.arena,
        .upstream = streamed.stream,
        .opening_tag = try std.fmt.allocPrint(wrap.arena, "<{s}>", .{options.tag_name}),
        .closing_tag = try std.fmt.allocPrint(wrap.arena, "</{s}>", .{options.tag_name}),
        .separator = try wrap.arena.dupe(u8, options.separator),
        .starts_with_reasoning = options.starts_with_reasoning,
    };
    var result = streamed;
    result.stream = .{ .ctx = state, .vtable = &ReasoningStreamState.vtable };
    return result;
}

const ReasoningStreamState = struct {
    arena: Allocator,
    upstream: provider.PartStream,
    opening_tag: []const u8,
    closing_tag: []const u8,
    separator: []const u8,
    starts_with_reasoning: bool,
    extractions: std.StringHashMapUnmanaged(*Extraction) = .empty,
    pending: std.ArrayList(provider.StreamPart) = .empty,
    pending_index: usize = 0,
    deinitialized: bool = false,

    const Extraction = struct {
        is_first_reasoning: bool = true,
        is_first_text: bool = true,
        after_switch: bool = false,
        is_reasoning: bool,
        buffer: std.ArrayList(u8) = .empty,
        id_counter: usize = 0,
        text_id: []const u8,
        delayed_text_start: ?provider.language_model.BlockBoundary = null,
    };

    const vtable: provider.PartStream.VTable = .{ .next = next, .deinit = deinit };

    fn next(raw_state: *anyopaque, io: std.Io) provider.NextError!?provider.StreamPart {
        const self: *ReasoningStreamState = @ptrCast(@alignCast(raw_state));
        while (true) {
            if (self.pending_index < self.pending.items.len) {
                defer self.pending_index += 1;
                return self.pending.items[self.pending_index];
            }
            self.pending.clearRetainingCapacity();
            self.pending_index = 0;

            const part = (try self.upstream.next(io)) orelse return null;
            switch (part) {
                .text_start => |value| {
                    const extraction = try self.getExtraction(value.id);
                    extraction.delayed_text_start = .{
                        .id = try self.arena.dupe(u8, value.id),
                        .provider_metadata = if (value.provider_metadata) |metadata|
                            try provider_utils.cloneJsonValue(self.arena, metadata)
                        else
                            null,
                    };
                    continue;
                },
                .text_end => |value| {
                    if (self.extractions.fetchRemove(value.id)) |removed| if (removed.value.delayed_text_start) |start| {
                        try self.pending.append(self.arena, .{ .text_start = start });
                    };
                    try self.pending.append(self.arena, .{ .text_end = .{
                        .id = try self.arena.dupe(u8, value.id),
                        .provider_metadata = if (value.provider_metadata) |metadata|
                            try provider_utils.cloneJsonValue(self.arena, metadata)
                        else
                            null,
                    } });
                    continue;
                },
                .text_delta => |value| {
                    const extraction = try self.getExtraction(value.id);
                    try extraction.buffer.appendSlice(self.arena, value.delta);
                    try self.processExtraction(extraction);
                    if (self.pending.items.len == 0) continue;
                },
                else => return part,
            }
        }
    }

    fn getExtraction(self: *ReasoningStreamState, id: []const u8) Allocator.Error!*Extraction {
        if (self.extractions.get(id)) |existing| return existing;
        const extraction = try self.arena.create(Extraction);
        extraction.* = .{
            .is_reasoning = self.starts_with_reasoning,
            .text_id = try self.arena.dupe(u8, id),
        };
        try self.extractions.put(self.arena, extraction.text_id, extraction);
        return extraction;
    }

    fn processExtraction(self: *ReasoningStreamState, extraction: *Extraction) Allocator.Error!void {
        while (true) {
            const next_tag = if (extraction.is_reasoning) self.closing_tag else self.opening_tag;
            const start_index = potentialStartIndex(extraction.buffer.items, next_tag) orelse {
                try self.publish(extraction, extraction.buffer.items);
                extraction.buffer.clearRetainingCapacity();
                return;
            };
            const prefix = try self.arena.dupe(u8, extraction.buffer.items[0..start_index]);
            try self.publish(extraction, prefix);
            const full_match = start_index + next_tag.len <= extraction.buffer.items.len;
            if (!full_match) {
                shiftBuffer(&extraction.buffer, start_index);
                return;
            }
            shiftBuffer(&extraction.buffer, start_index + next_tag.len);
            if (extraction.is_reasoning) {
                const id = try self.reasoningId(extraction.id_counter);
                if (extraction.is_first_reasoning) {
                    try self.pending.append(self.arena, .{ .reasoning_start = .{ .id = id } });
                }
                try self.pending.append(self.arena, .{ .reasoning_end = .{ .id = id } });
                extraction.id_counter += 1;
            }
            extraction.is_reasoning = !extraction.is_reasoning;
            extraction.after_switch = true;
        }
    }

    fn publish(
        self: *ReasoningStreamState,
        extraction: *Extraction,
        value: []const u8,
    ) Allocator.Error!void {
        if (value.len == 0) return;
        const needs_separator = extraction.after_switch and
            (if (extraction.is_reasoning) !extraction.is_first_reasoning else !extraction.is_first_text);
        const text = if (needs_separator)
            try std.mem.concat(self.arena, u8, &.{ self.separator, value })
        else
            try self.arena.dupe(u8, value);

        if (extraction.is_reasoning) {
            const id = try self.reasoningId(extraction.id_counter);
            if (extraction.after_switch or extraction.is_first_reasoning) {
                try self.pending.append(self.arena, .{ .reasoning_start = .{ .id = id } });
            }
            try self.pending.append(self.arena, .{ .reasoning_delta = .{ .id = id, .delta = text } });
            extraction.is_first_reasoning = false;
        } else {
            if (extraction.delayed_text_start) |start| {
                try self.pending.append(self.arena, .{ .text_start = start });
                extraction.delayed_text_start = null;
            }
            try self.pending.append(self.arena, .{ .text_delta = .{
                .id = extraction.text_id,
                .delta = text,
            } });
            extraction.is_first_text = false;
        }
        extraction.after_switch = false;
    }

    fn reasoningId(self: *ReasoningStreamState, counter: usize) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "reasoning-{d}", .{counter});
    }

    fn deinit(raw_state: *anyopaque, io: std.Io) void {
        const self: *ReasoningStreamState = @ptrCast(@alignCast(raw_state));
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.upstream.deinit(io);
    }
};

fn potentialStartIndex(text: []const u8, searched: []const u8) ?usize {
    if (searched.len == 0) return null;
    if (std.mem.indexOf(u8, text, searched)) |index| return index;
    var index = text.len;
    while (index != 0) {
        index -= 1;
        const suffix = text[index..];
        if (std.mem.startsWith(u8, searched, suffix)) return index;
    }
    return null;
}

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
