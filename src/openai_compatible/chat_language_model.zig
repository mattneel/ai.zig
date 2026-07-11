const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const config_api = @import("config.zig");

const Allocator = std.mem.Allocator;
const BuildError = provider.Error || Allocator.Error;

pub const PreparedRequest = struct {
    body: std.json.Value,
    warnings: []const provider.Warning,
    metadata_key: []const u8,
};

pub const ChatLanguageModel = struct {
    model_id: []const u8,
    config: config_api.Config,

    pub fn languageModel(self: *ChatLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn model(self: *ChatLanguageModel) provider.LanguageModel {
        return self.languageModel();
    }

    pub fn prepareRequest(
        self: *ChatLanguageModel,
        arena: Allocator,
        options: *const provider.CallOptions,
        stream: bool,
        diag: ?*provider.Diagnostics,
    ) BuildError!PreparedRequest {
        return buildArgs(self, arena, options, stream, diag);
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .urlIsSupported = vUrlIsSupported,
        .doGenerate = vDoGenerate,
        .doStream = vDoStream,
    };

    fn vProvider(raw: *anyopaque) []const u8 {
        return fromRaw(raw).config.provider;
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vUrlIsSupported(_: *anyopaque, media_type: []const u8, url: []const u8) bool {
        return std.mem.startsWith(u8, media_type, "image/") and
            (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"));
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        return fromRaw(raw).doGenerate(io, arena, options, diag);
    }

    fn vDoStream(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return fromRaw(raw).doStream(io, arena, options, diag);
    }

    fn fromRaw(raw: *anyopaque) *ChatLanguageModel {
        return @ptrCast(@alignCast(raw));
    }

    fn doGenerate(
        self: *ChatLanguageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const prepared = try buildArgs(self, arena, options, false, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const url = try buildUrl(arena, self.config.base_url, self.config.query_params);
        const request_headers = try self.resolveHeaders(arena, options.headers);
        var failure_context: FailureContext = .{ .hooks = self.config.error_hooks };
        const result = try provider_utils.postJsonToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = request_headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = .{ .ctx = &failure_context, .handle_fn = handleFailure },
            },
            diag,
        );
        return mapGenerateResponse(
            io,
            arena,
            prepared,
            result.value,
            result.response_headers,
            diag,
        );
    }

    fn doStream(
        self: *ChatLanguageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.CallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        const prepared = try buildArgs(self, arena, options, true, diag);
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, prepared.body);
        const url = try buildUrl(arena, self.config.base_url, self.config.query_params);
        const request_headers = try self.resolveHeaders(arena, options.headers);
        var failure_context: FailureContext = .{ .hooks = self.config.error_hooks };
        const Stream = provider_utils.JsonEventStream(std.json.Value);
        const result = try provider_utils.postJsonToApi(
            Stream,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = request_headers, .body_json = body_json },
            .{
                .success = provider_utils.eventSourceResponseHandler(std.json.Value),
                .failure = .{ .ctx = &failure_context, .handle_fn = handleFailure },
            },
            diag,
        );

        // The caller-supplied doStream arena owns the event stream, mapper,
        // queue, and every returned slice. The PartStream must be deinitialized
        // before that arena is released.
        const state = try arena.create(StreamState);
        state.* = .{
            .arena = arena,
            .events = result.value,
            .warnings = prepared.warnings,
            .metadata_key = prepared.metadata_key,
            .include_raw = options.include_raw_chunks orelse false,
            .diag = diag,
            .id_generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag),
            .tracker = undefined,
        };
        state.tracker = provider_utils.StreamingToolCallTracker.init(arena, &state.id_generator);
        try state.queue.append(arena, .{ .stream_start = .{ .warnings = prepared.warnings } });

        return .{
            .stream = .{ .ctx = state, .vtable = &StreamState.vtable },
            .request = .{ .body = prepared.body },
            .response = .{ .headers = result.response_headers },
        };
    }

    fn resolveHeaders(
        self: *const ChatLanguageModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
    ) Allocator.Error![]const provider.Header {
        var auth_entries: [1]provider_utils.HeaderEntry = undefined;
        var auth: []const provider_utils.HeaderEntry = &.{};
        if (try resolveApiKey(self.config, arena)) |api_key| {
            auth_entries[0] = .{
                .name = "authorization",
                .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}),
            };
            auth = &auth_entries;
        }

        const resolved = self.config.headers.resolve();
        const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |h| h.len else 0);
        if (call_headers) |headers| {
            for (headers, call_entries) |header, *entry| {
                entry.* = .{ .name = header.name, .value = header.value };
            }
        }
        const lists = [_][]const provider_utils.HeaderEntry{ auth, resolved, call_entries };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(
            arena,
            combined,
            &.{"ai-sdk-zig/openai-compatible/0.0.0"},
        );
    }
};

fn buildArgs(
    self: *ChatLanguageModel,
    arena: Allocator,
    options: *const provider.CallOptions,
    stream: bool,
    diag: ?*provider.Diagnostics,
) BuildError!PreparedRequest {
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var body: std.json.ObjectMap = .empty;

    try putString(&body, arena, "model", self.model_id);
    if (options.max_output_tokens) |value| try body.put(arena, "max_tokens", try uintValue(arena, value));
    if (options.temperature) |value| try body.put(arena, "temperature", .{ .float = value });
    if (options.top_p) |value| try body.put(arena, "top_p", .{ .float = value });
    if (options.frequency_penalty) |value| try body.put(arena, "frequency_penalty", .{ .float = value });
    if (options.presence_penalty) |value| try body.put(arena, "presence_penalty", .{ .float = value });
    if (options.stop_sequences) |values| try body.put(arena, "stop", try stringArray(arena, values));
    if (options.seed) |value| try body.put(arena, "seed", .{ .integer = value });

    if (options.top_k != null) {
        try warnings.append(arena, .{ .unsupported = .{ .feature = "topK" } });
    }

    const provider_options = try parseCompatibleOptions(
        arena,
        options.provider_options,
        self.config.provider_name,
        &warnings,
        diag,
    );

    if (provider_options.user) |value| try putString(&body, arena, "user", value);

    if (options.response_format) |format| switch (format) {
        .text => {},
        .json => |json| {
            if (json.schema != null and !self.config.supports_structured_outputs) {
                try warnings.append(arena, .{ .unsupported = .{
                    .feature = "responseFormat",
                    .details = "JSON response format schema is only supported with structuredOutputs",
                } });
            }
            var response_format: std.json.ObjectMap = .empty;
            if (self.config.supports_structured_outputs and json.schema != null) {
                try putString(&response_format, arena, "type", "json_schema");
                var json_schema: std.json.ObjectMap = .empty;
                try json_schema.put(arena, "schema", try provider_utils.cloneJsonValue(arena, json.schema.?));
                try json_schema.put(arena, "strict", .{ .bool = provider_options.strict_json_schema });
                try putString(&json_schema, arena, "name", json.name orelse "response");
                if (json.description) |value| try putString(&json_schema, arena, "description", value);
                try response_format.put(arena, "json_schema", .{ .object = json_schema });
            } else {
                try putString(&response_format, arena, "type", "json_object");
            }
            try body.put(arena, "response_format", .{ .object = response_format });
        },
    };

    // The generic vendor escape hatch deliberately spreads unknown options
    // into the body after standardized settings.
    var unknown_iterator = provider_options.unknown.iterator();
    while (unknown_iterator.next()) |entry| {
        try body.put(
            arena,
            try arena.dupe(u8, entry.key_ptr.*),
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
        );
    }

    const reasoning_effort = provider_options.reasoning_effort orelse reasoningName(options.reasoning);
    if (reasoning_effort) |value| try putString(&body, arena, "reasoning_effort", value);
    if (provider_options.text_verbosity) |value| try putString(&body, arena, "verbosity", value);

    try body.put(arena, "messages", try convertMessages(arena, options.prompt, diag));
    try prepareTools(arena, options.tools, options.tool_choice, &body, &warnings);

    if (stream) {
        try body.put(arena, "stream", .{ .bool = true });
        if (self.config.include_usage) {
            var stream_options: std.json.ObjectMap = .empty;
            try stream_options.put(arena, "include_usage", .{ .bool = true });
            try body.put(arena, "stream_options", .{ .object = stream_options });
        }
    }

    return .{
        .body = .{ .object = body },
        .warnings = try warnings.toOwnedSlice(arena),
        .metadata_key = provider_options.metadata_key,
    };
}

const ParsedCompatibleOptions = struct {
    user: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    text_verbosity: ?[]const u8 = null,
    strict_json_schema: bool = true,
    metadata_key: []const u8,
    unknown: std.json.ObjectMap = .empty,
};

fn parseCompatibleOptions(
    arena: Allocator,
    value: ?provider.ProviderOptions,
    raw_name: []const u8,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) BuildError!ParsedCompatibleOptions {
    const camel_name = try toCamelCase(arena, raw_name);
    var result: ParsedCompatibleOptions = .{ .metadata_key = raw_name };
    const root = if (value) |options| switch (options) {
        .object => |object| object,
        .null => return result,
        else => return invalidType(diag, arena, "providerOptions must be a JSON object"),
    } else return result;

    if (!std.mem.eql(u8, raw_name, camel_name) and root.get(camel_name) != null) {
        result.metadata_key = camel_name;
    }
    if (root.get("openai-compatible") != null) {
        try warnings.append(arena, .{ .deprecated = .{
            .setting = "providerOptions key 'openai-compatible'",
            .message = "Use 'openaiCompatible' instead.",
        } });
    }
    if (!std.mem.eql(u8, raw_name, camel_name) and root.get(raw_name) != null) {
        try warnings.append(arena, .{ .deprecated = .{
            .setting = try std.fmt.allocPrint(arena, "providerOptions key '{s}'", .{raw_name}),
            .message = try std.fmt.allocPrint(arena, "Use '{s}' instead.", .{camel_name}),
        } });
    }

    const keys = [_][]const u8{ "openai-compatible", "openaiCompatible", raw_name, camel_name };
    for (keys) |key| {
        const namespace_value = root.get(key) orelse continue;
        if (namespace_value == .null) continue;
        if (namespace_value != .object) return invalidType(
            diag,
            arena,
            "OpenAI-compatible provider options namespace must be an object",
        );
        var iterator = namespace_value.object.iterator();
        while (iterator.next()) |entry| {
            const option_name = entry.key_ptr.*;
            if (std.mem.eql(u8, option_name, "user")) {
                result.user = try optionalString(entry.value_ptr.*, diag, arena, "user");
            } else if (std.mem.eql(u8, option_name, "reasoningEffort")) {
                result.reasoning_effort = try optionalString(entry.value_ptr.*, diag, arena, "reasoningEffort");
            } else if (std.mem.eql(u8, option_name, "textVerbosity")) {
                result.text_verbosity = try optionalString(entry.value_ptr.*, diag, arena, "textVerbosity");
            } else if (std.mem.eql(u8, option_name, "strictJsonSchema")) {
                result.strict_json_schema = switch (entry.value_ptr.*) {
                    .bool => |item| item,
                    .null => true,
                    else => return invalidType(diag, arena, "strictJsonSchema must be a boolean"),
                };
            } else {
                try result.unknown.put(
                    arena,
                    try arena.dupe(u8, option_name),
                    try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
                );
            }
        }
    }
    return result;
}

fn optionalString(
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    field: []const u8,
) BuildError!?[]const u8 {
    return switch (value) {
        .string => |item| item,
        .null => null,
        else => {
            const message = try std.fmt.allocPrint(arena, "{s} must be a string", .{field});
            return invalidType(diag, arena, message);
        },
    };
}

fn invalidType(
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    message: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else arena, .{
        .type_validation = .{ .message = message },
    });
    return error.TypeValidationError;
}

fn convertMessages(
    arena: Allocator,
    prompt: provider.Prompt,
    diag: ?*provider.Diagnostics,
) BuildError!std.json.Value {
    var messages = std.json.Array.init(arena);
    for (prompt) |message| switch (message) {
        .system => |system| {
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "role", "system");
            try putString(&object, arena, "content", system.content);
            try mergeOpenAiMetadata(arena, &object, system.provider_options);
            try messages.append(.{ .object = object });
        },
        .user => |user| {
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "role", "user");
            if (user.content.len == 1 and user.content[0] == .text) {
                const text = user.content[0].text;
                try putString(&object, arena, "content", text.text);
                try mergeOpenAiMetadata(arena, &object, text.provider_options);
            } else {
                var content = std.json.Array.init(arena);
                for (user.content) |part| switch (part) {
                    .text => |text| {
                        var item: std.json.ObjectMap = .empty;
                        try putString(&item, arena, "type", "text");
                        try putString(&item, arena, "text", text.text);
                        try mergeOpenAiMetadata(arena, &item, text.provider_options);
                        try content.append(.{ .object = item });
                    },
                    .file => |file| try content.append(try convertUserFile(arena, file, diag)),
                };
                try object.put(arena, "content", .{ .array = content });
            }
            try mergeOpenAiMetadata(arena, &object, user.provider_options);
            try messages.append(.{ .object = object });
        },
        .assistant => |assistant| {
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "role", "assistant");
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(arena);
            var reasoning: std.ArrayList(u8) = .empty;
            defer reasoning.deinit(arena);
            var tool_calls = std.json.Array.init(arena);

            for (assistant.content) |part| switch (part) {
                .text => |value| try text.appendSlice(arena, value.text),
                .reasoning => |value| try reasoning.appendSlice(arena, value.text),
                .tool_call => |tool_call| {
                    var call: std.json.ObjectMap = .empty;
                    try putString(&call, arena, "id", tool_call.tool_call_id);
                    try putString(&call, arena, "type", "function");
                    var function: std.json.ObjectMap = .empty;
                    try putString(&function, arena, "name", tool_call.tool_name);
                    try putString(
                        &function,
                        arena,
                        "arguments",
                        try provider_utils.stringifyJsonValueAlloc(arena, tool_call.input),
                    );
                    try call.put(arena, "function", .{ .object = function });
                    try mergeOpenAiMetadata(arena, &call, tool_call.provider_options);
                    if (thoughtSignature(tool_call.provider_options)) |signature| {
                        var google: std.json.ObjectMap = .empty;
                        try putString(&google, arena, "thought_signature", signature);
                        var extra: std.json.ObjectMap = .empty;
                        try extra.put(arena, "google", .{ .object = google });
                        try call.put(arena, "extra_content", .{ .object = extra });
                    }
                    try tool_calls.append(.{ .object = call });
                },
                else => {},
            };

            if (tool_calls.items.len != 0 and text.items.len == 0) {
                try object.put(arena, "content", .null);
            } else {
                try putString(&object, arena, "content", text.items);
            }
            if (reasoning.items.len != 0) try putString(&object, arena, "reasoning_content", reasoning.items);
            if (tool_calls.items.len != 0) try object.put(arena, "tool_calls", .{ .array = tool_calls });
            try mergeOpenAiMetadata(arena, &object, assistant.provider_options);
            try messages.append(.{ .object = object });
        },
        .tool => |tool_message| {
            for (tool_message.content) |part| switch (part) {
                .tool_approval_response => {},
                .tool_result => |tool_result| {
                    var object: std.json.ObjectMap = .empty;
                    try putString(&object, arena, "role", "tool");
                    try putString(&object, arena, "tool_call_id", tool_result.tool_call_id);
                    try putString(
                        &object,
                        arena,
                        "content",
                        try toolResultText(arena, tool_result.output),
                    );
                    try mergeOpenAiMetadata(arena, &object, tool_result.provider_options);
                    try messages.append(.{ .object = object });
                },
            };
        },
    };
    return .{ .array = messages };
}

fn convertUserFile(
    arena: Allocator,
    file: provider.FilePart,
    diag: ?*provider.Diagnostics,
) BuildError!std.json.Value {
    const top_level = provider_utils.getTopLevelMediaType(file.media_type);
    var object: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, top_level, "image")) {
        try putString(&object, arena, "type", "image_url");
        var image: std.json.ObjectMap = .empty;
        switch (file.data) {
            .url => |value| try putString(&image, arena, "url", value.url),
            .data => |value| {
                const encoded = try binaryToBase64(arena, value.data);
                try putString(
                    &image,
                    arena,
                    "url",
                    try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ file.media_type, encoded }),
                );
            },
            else => return unsupported(diag, arena, "image file data type"),
        }
        try object.put(arena, "image_url", .{ .object = image });
    } else if (std.mem.eql(u8, top_level, "audio")) {
        const format = if (std.mem.eql(u8, file.media_type, "audio/wav"))
            "wav"
        else if (std.mem.eql(u8, file.media_type, "audio/mp3") or
            std.mem.eql(u8, file.media_type, "audio/mpeg"))
            "mp3"
        else
            return unsupported(diag, arena, "audio media type");
        const data = switch (file.data) {
            .data => |value| try binaryToBase64(arena, value.data),
            else => return unsupported(diag, arena, "audio file parts with URLs or references"),
        };
        try putString(&object, arena, "type", "input_audio");
        var input_audio: std.json.ObjectMap = .empty;
        try putString(&input_audio, arena, "data", data);
        try putString(&input_audio, arena, "format", format);
        try object.put(arena, "input_audio", .{ .object = input_audio });
    } else if (std.mem.eql(u8, file.media_type, "application/pdf")) {
        const data = switch (file.data) {
            .data => |value| try binaryToBase64(arena, value.data),
            else => return unsupported(diag, arena, "PDF file parts with URLs or references"),
        };
        try putString(&object, arena, "type", "file");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "filename", file.filename orelse "document.pdf");
        try putString(
            &item,
            arena,
            "file_data",
            try std.fmt.allocPrint(arena, "data:application/pdf;base64,{s}", .{data}),
        );
        try object.put(arena, "file", .{ .object = item });
    } else if (std.mem.eql(u8, top_level, "text")) {
        const text = switch (file.data) {
            .text => return unsupported(diag, arena, "text file parts"),
            .url => |value| value.url,
            .data => |value| switch (value.data) {
                .bytes => |bytes| bytes,
                .base64 => |base64| provider_utils.decodeBase64(arena, base64) catch
                    return unsupported(diag, arena, "invalid base64 text file"),
            },
            .reference => return unsupported(diag, arena, "file parts with provider references"),
        };
        try putString(&object, arena, "type", "text");
        try putString(&object, arena, "text", text);
    } else {
        return unsupported(diag, arena, "file part media type");
    }
    try mergeOpenAiMetadata(arena, &object, file.provider_options);
    return .{ .object = object };
}

fn binaryToBase64(arena: Allocator, data: provider.BinaryData) Allocator.Error![]const u8 {
    return switch (data) {
        .bytes => |bytes| provider_utils.encodeBase64(arena, bytes),
        .base64 => |base64| arena.dupe(u8, base64),
    };
}

fn toolResultText(arena: Allocator, output: provider.ToolResultOutput) Allocator.Error![]const u8 {
    return switch (output) {
        .text => |value| arena.dupe(u8, value.value),
        .error_text => |value| arena.dupe(u8, value.value),
        .execution_denied => |value| arena.dupe(u8, value.reason orelse "Tool call execution denied."),
        .json => |value| provider_utils.stringifyJsonValueAlloc(arena, value.value),
        .error_json => |value| provider_utils.stringifyJsonValueAlloc(arena, value.value),
        .content => |value| blk: {
            var array = std.json.Array.init(arena);
            for (value.value) |part| switch (part) {
                .text => |text| {
                    var item: std.json.ObjectMap = .empty;
                    try putString(&item, arena, "type", "text");
                    try putString(&item, arena, "text", text.text);
                    try array.append(.{ .object = item });
                },
                else => {},
            };
            break :blk provider_utils.stringifyJsonValueAlloc(arena, .{ .array = array });
        },
    };
}

fn mergeOpenAiMetadata(
    arena: Allocator,
    destination: *std.json.ObjectMap,
    provider_options: ?provider.ProviderOptions,
) Allocator.Error!void {
    const root = provider_options orelse return;
    if (root != .object) return;
    const value = root.object.get("openaiCompatible") orelse return;
    if (value != .object) return;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try destination.put(
            arena,
            try arena.dupe(u8, entry.key_ptr.*),
            try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
        );
    }
}

fn thoughtSignature(provider_options: ?provider.ProviderOptions) ?[]const u8 {
    const root = provider_options orelse return null;
    if (root != .object) return null;
    const google = root.object.get("google") orelse return null;
    if (google != .object) return null;
    const signature = google.object.get("thoughtSignature") orelse return null;
    return if (signature == .string) signature.string else null;
}

fn prepareTools(
    arena: Allocator,
    tools: ?[]const provider.Tool,
    tool_choice: ?provider.ToolChoice,
    body: *std.json.ObjectMap,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!void {
    const input_tools = tools orelse return;
    if (input_tools.len == 0) return;
    var output = std.json.Array.init(arena);
    for (input_tools) |tool| switch (tool) {
        .provider => |value| try warnings.append(arena, .{ .unsupported = .{
            .feature = try std.fmt.allocPrint(arena, "provider-defined tool {s}", .{value.id}),
        } }),
        .function => |value| {
            var item: std.json.ObjectMap = .empty;
            try putString(&item, arena, "type", "function");
            var function: std.json.ObjectMap = .empty;
            try putString(&function, arena, "name", value.name);
            if (value.description) |description| try putString(&function, arena, "description", description);
            try function.put(arena, "parameters", try provider_utils.cloneJsonValue(arena, value.input_schema));
            if (value.strict) |strict| try function.put(arena, "strict", .{ .bool = strict });
            try item.put(arena, "function", .{ .object = function });
            try output.append(.{ .object = item });
        },
    };
    try body.put(arena, "tools", .{ .array = output });

    if (tool_choice) |choice| switch (choice) {
        .auto => try putString(body, arena, "tool_choice", "auto"),
        .none => try putString(body, arena, "tool_choice", "none"),
        .required => try putString(body, arena, "tool_choice", "required"),
        .tool => |named| {
            var choice_object: std.json.ObjectMap = .empty;
            try putString(&choice_object, arena, "type", "function");
            var function: std.json.ObjectMap = .empty;
            try putString(&function, arena, "name", named.tool_name);
            try choice_object.put(arena, "function", .{ .object = function });
            try body.put(arena, "tool_choice", .{ .object = choice_object });
        },
    };
}

fn mapGenerateResponse(
    io: std.Io,
    arena: Allocator,
    prepared: PreparedRequest,
    response: std.json.Value,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.CallError!provider.GenerateResult {
    const root = try requireObject(response, diag, arena, "OpenAI-compatible response must be an object");
    const choices = try requireArrayField(root, "choices", diag, arena);
    if (choices.items.len == 0) return invalidResponse(diag, arena, "OpenAI-compatible response has no choices");
    const choice = try requireObject(choices.items[0], diag, arena, "OpenAI-compatible choice must be an object");
    const message = try requireObjectField(choice, "message", diag, arena);
    var content: std.ArrayList(provider.Content) = .empty;
    defer content.deinit(arena);

    if (optionalStringField(message, "content")) |text| if (text.len != 0) {
        try content.append(arena, .{ .text = .{ .text = try arena.dupe(u8, text) } });
    };
    const reasoning = optionalStringField(message, "reasoning_content") orelse
        optionalStringField(message, "reasoning");
    if (reasoning) |text| if (text.len != 0) {
        try content.append(arena, .{ .reasoning = .{ .text = try arena.dupe(u8, text) } });
    };

    if (message.get("tool_calls")) |tool_calls_value| if (tool_calls_value == .array) {
        var generator = try provider_utils.IdGenerator.initFromIo(io, .{ .prefix = "call" }, diag);
        for (tool_calls_value.array.items) |item| {
            if (item != .object) continue;
            const function = item.object.get("function") orelse continue;
            if (function != .object) continue;
            const name = optionalStringField(function.object, "name") orelse continue;
            const arguments = optionalStringField(function.object, "arguments") orelse "";
            const id = optionalStringField(item.object, "id") orelse try generator.nextAlloc(arena);
            const metadata = if (extractThoughtSignature(item.object)) |signature|
                try makeThoughtMetadata(arena, prepared.metadata_key, signature)
            else
                null;
            try content.append(arena, .{ .tool_call = .{
                .tool_call_id = try arena.dupe(u8, id),
                .tool_name = try arena.dupe(u8, name),
                .input = try arena.dupe(u8, arguments),
                .provider_metadata = metadata,
            } });
        }
    };

    const usage_value = root.get("usage") orelse std.json.Value.null;
    const finish_raw = optionalStringField(choice, "finish_reason");
    return .{
        .content = try content.toOwnedSlice(arena),
        .finish_reason = .{ .unified = mapFinishReason(finish_raw), .raw = finish_raw },
        .usage = try convertUsage(arena, usage_value),
        .provider_metadata = try makeUsageMetadata(arena, prepared.metadata_key, usage_value),
        .request = .{ .body = prepared.body },
        .response = .{
            .id = optionalStringField(root, "id"),
            .timestamp_ms = timestampMillis(root.get("created")),
            .model_id = optionalStringField(root, "model"),
            .headers = response_headers,
            .body = response,
        },
        .warnings = prepared.warnings,
    };
}

const PendingToolCall = struct {
    id: ?[]const u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    provider_metadata: ?provider.ProviderMetadata = null,

    fn deinit(self: *PendingToolCall, allocator: Allocator) void {
        self.arguments.deinit(allocator);
        self.* = undefined;
    }
};

const StreamState = struct {
    arena: Allocator,
    events: provider_utils.JsonEventStream(std.json.Value),
    warnings: []const provider.Warning,
    metadata_key: []const u8,
    include_raw: bool,
    diag: ?*provider.Diagnostics,
    id_generator: provider_utils.IdGenerator,
    tracker: provider_utils.StreamingToolCallTracker,
    pending: std.AutoHashMapUnmanaged(usize, PendingToolCall) = .empty,
    pending_order: std.ArrayList(usize) = .empty,
    forwarded: std.AutoHashMapUnmanaged(usize, void) = .empty,
    queue: std.ArrayList(provider.StreamPart) = .empty,
    queue_index: usize = 0,
    first_chunk: bool = true,
    active_reasoning: bool = false,
    active_text: bool = false,
    finish_reason: provider.FinishReason = .{ .unified = .other },
    usage: ?std.json.Value = null,
    flushed: bool = false,
    deinitialized: bool = false,

    const vtable: provider.PartStream.VTable = .{
        .next = next,
        .deinit = deinit,
    };

    fn next(raw: *anyopaque, _: std.Io) provider.NextError!?provider.StreamPart {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return null;
        while (self.queue_index >= self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.queue_index = 0;
            if (self.flushed) return null;
            try self.fillQueue();
        }
        defer self.queue_index += 1;
        return self.queue.items[self.queue_index];
    }

    fn deinit(raw: *anyopaque, _: std.Io) void {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        if (self.deinitialized) return;
        self.events.deinit();
        self.tracker.deinit();
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(self.arena);
        self.pending.deinit(self.arena);
        self.pending_order.deinit(self.arena);
        self.forwarded.deinit(self.arena);
        self.queue.deinit(self.arena);
        self.deinitialized = true;
    }

    fn fillQueue(self: *StreamState) provider.NextError!void {
        while (self.queue.items.len == 0) {
            const event = self.events.next(self.arena) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponseDataError => return error.InvalidResponseDataError,
                else => return invalidStream(self.diag, self.arena, @errorName(err)),
            };
            if (event == null) {
                try self.flush();
                return;
            }

            switch (event.?) {
                .failure => |failure| {
                    if (self.include_raw) {
                        try self.queue.append(self.arena, .{ .raw = .{ .raw_value = .{
                            .string = failure.raw,
                        } } });
                    }
                    self.finish_reason = .{ .unified = .@"error" };
                    try self.queue.append(self.arena, .{ .err = .{ .error_value = .{
                        .string = failure.message,
                    } } });
                },
                .success => |success| {
                    if (self.include_raw) {
                        try self.queue.append(self.arena, .{ .raw = .{ .raw_value = success.value } });
                    }
                    try self.mapChunk(success.value);
                },
            }
        }
    }

    fn mapChunk(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (value != .object) {
            self.finish_reason = .{ .unified = .@"error" };
            try self.queue.append(self.arena, .{ .err = .{ .error_value = value } });
            return;
        }
        const root = value.object;
        if (root.get("error")) |error_value| {
            self.finish_reason = .{ .unified = .@"error" };
            try self.queue.append(self.arena, .{ .err = .{ .error_value = error_value } });
            return;
        }

        if (self.first_chunk) {
            self.first_chunk = false;
            try self.queue.append(self.arena, .{ .response_metadata = .{
                .id = optionalStringField(root, "id"),
                .timestamp_ms = timestampMillis(root.get("created")),
                .model_id = optionalStringField(root, "model"),
            } });
        }

        if (root.get("usage")) |usage| {
            if (usage != .null) self.usage = usage;
        }
        const choices_value = root.get("choices") orelse return;
        if (choices_value != .array or choices_value.array.items.len == 0) return;
        const choice_value = choices_value.array.items[0];
        if (choice_value != .object) return;
        const choice = choice_value.object;
        if (optionalStringField(choice, "finish_reason")) |raw_reason| {
            self.finish_reason = .{ .unified = mapFinishReason(raw_reason), .raw = raw_reason };
        }
        const delta_value = choice.get("delta") orelse return;
        if (delta_value != .object) return;
        const delta = delta_value.object;

        const reasoning = optionalStringField(delta, "reasoning_content") orelse
            optionalStringField(delta, "reasoning");
        if (reasoning) |text| if (text.len != 0) {
            if (!self.active_reasoning) {
                try self.queue.append(self.arena, .{ .reasoning_start = .{ .id = "reasoning-0" } });
                self.active_reasoning = true;
            }
            try self.queue.append(self.arena, .{ .reasoning_delta = .{
                .id = "reasoning-0",
                .delta = text,
            } });
        };

        if (optionalStringField(delta, "content")) |text| if (text.len != 0) {
            try self.endReasoning();
            if (!self.active_text) {
                try self.queue.append(self.arena, .{ .text_start = .{ .id = "0" } });
                self.active_text = true;
            }
            try self.queue.append(self.arena, .{ .text_delta = .{ .id = "0", .delta = text } });
        };

        if (delta.get("tool_calls")) |tool_calls| if (tool_calls == .array) {
            try self.endReasoning();
            for (tool_calls.array.items) |tool_delta| try self.processToolDelta(tool_delta);
        };
    }

    fn endReasoning(self: *StreamState) Allocator.Error!void {
        if (!self.active_reasoning) return;
        try self.queue.append(self.arena, .{ .reasoning_end = .{ .id = "reasoning-0" } });
        self.active_reasoning = false;
    }

    fn processToolDelta(self: *StreamState, value: std.json.Value) provider.NextError!void {
        if (value != .object) return;
        const object = value.object;
        const index = optionalIndex(object.get("index"));
        const function = object.get("function");
        const function_object: ?std.json.ObjectMap = if (function) |item|
            if (item == .object) item.object else null
        else
            null;
        const name = if (function_object) |item| optionalStringField(item, "name") else null;
        const arguments = if (function_object) |item| optionalStringField(item, "arguments") else null;
        const id = optionalStringField(object, "id");
        const type_name = optionalStringField(object, "type");
        const metadata = if (extractThoughtSignature(object)) |signature|
            try makeThoughtMetadata(self.arena, self.metadata_key, signature)
        else
            null;

        if (index == null or self.forwarded.contains(index.?)) {
            const parts = try self.tracker.handleDelta(.{
                .index = index,
                .id = id,
                .type = type_name,
                .function = if (function_object != null) .{
                    .name = name,
                    .arguments = arguments,
                } else null,
                .provider_metadata = metadata,
            }, self.diag);
            try self.appendTrackerParts(parts);
            return;
        }

        const key = index.?;
        const result = try self.pending.getOrPut(self.arena, key);
        if (!result.found_existing) {
            result.value_ptr.* = .{ .id = id, .provider_metadata = metadata };
            try self.pending_order.append(self.arena, key);
        } else {
            if (result.value_ptr.id == null and id != null) result.value_ptr.id = id;
            if (result.value_ptr.provider_metadata == null and metadata != null)
                result.value_ptr.provider_metadata = metadata;
        }
        if (arguments) |fragment| try result.value_ptr.arguments.appendSlice(self.arena, fragment);
        if (name) |tool_name| {
            const parts = try self.tracker.handleDelta(.{
                .index = key,
                .id = result.value_ptr.id,
                .type = type_name,
                .function = .{
                    .name = tool_name,
                    .arguments = result.value_ptr.arguments.items,
                },
                .provider_metadata = result.value_ptr.provider_metadata,
            }, self.diag);
            try self.appendTrackerParts(parts);
            var removed = self.pending.fetchRemove(key).?.value;
            removed.deinit(self.arena);
            try self.forwarded.put(self.arena, key, {});
        }
    }

    fn appendTrackerParts(
        self: *StreamState,
        parts: []const provider.StreamPart,
    ) Allocator.Error!void {
        for (parts) |part| {
            const owned = switch (part) {
                .tool_input_delta => |delta| provider.StreamPart{ .tool_input_delta = .{
                    .id = delta.id,
                    .delta = try self.arena.dupe(u8, delta.delta),
                    .provider_metadata = delta.provider_metadata,
                } },
                else => part,
            };
            try self.queue.append(self.arena, owned);
        }
    }

    fn flush(self: *StreamState) provider.NextError!void {
        if (self.flushed) return;
        try self.endReasoning();
        if (self.active_text) {
            try self.queue.append(self.arena, .{ .text_end = .{ .id = "0" } });
            self.active_text = false;
        }

        for (self.pending_order.items) |index| {
            const pending = self.pending.getPtr(index) orelse continue;
            const parts = try self.tracker.handleDelta(.{
                .index = index,
                .id = pending.id,
                .function = .{ .arguments = pending.arguments.items },
                .provider_metadata = pending.provider_metadata,
            }, self.diag);
            try self.appendTrackerParts(parts);
        }
        const final_tool_parts = try self.tracker.flush();
        try self.appendTrackerParts(final_tool_parts);

        const usage_value = self.usage orelse std.json.Value.null;
        try self.queue.append(self.arena, .{ .finish = .{
            .finish_reason = self.finish_reason,
            .usage = try convertUsage(self.arena, usage_value),
            .provider_metadata = try makeUsageMetadata(self.arena, self.metadata_key, usage_value),
        } });
        self.flushed = true;
    }
};

const FailureContext = struct { hooks: config_api.ErrorHooks };

fn handleFailure(
    raw: ?*anyopaque,
    _: std.Io,
    arena: Allocator,
    response: *provider_utils.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    diag: ?*provider.Diagnostics,
) provider_utils.RequestError!void {
    const context: *FailureContext = @ptrCast(@alignCast(raw.?));
    const body = provider_utils.http_transport.readBodyWithLimit(
        arena,
        &response.body,
        provider_utils.api.default_max_response_size,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setApiDiagnostic(
                diag,
                arena,
                "Failed to read error response",
                url,
                response,
                null,
                request_body_json,
                provider.isRetryableStatus(response.status),
            );
            return error.APICallError;
        },
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch null;
    const message = if (parsed) |value|
        if (context.hooks.message_fn) |message_fn|
            message_fn(context.hooks.ctx, value) orelse defaultErrorMessage(value) orelse response.status_text
        else
            defaultErrorMessage(value) orelse response.status_text
    else
        response.status_text;
    const retryable = if (context.hooks.retryable_fn) |retry_fn|
        retry_fn(context.hooks.ctx, response.status, parsed)
    else
        provider.isRetryableStatus(response.status);
    setApiDiagnostic(
        diag,
        arena,
        message,
        url,
        response,
        body,
        request_body_json,
        retryable,
    );
    return error.APICallError;
}

fn setApiDiagnostic(
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    message: []const u8,
    url: []const u8,
    response: *const provider_utils.Response,
    body: ?[]const u8,
    request_body_json: ?[]const u8,
    retryable: bool,
) void {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else arena, .{ .api_call = .{
        .message = message,
        .url = url,
        .status_code = response.status,
        .response_headers = response.headers,
        .response_body = body,
        .is_retryable = retryable,
        .request_body_json = request_body_json,
        .data_json = body,
    } });
}

fn defaultErrorMessage(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const error_value = value.object.get("error") orelse return null;
    if (error_value != .object) return null;
    return optionalStringField(error_value.object, "message");
}

fn convertUsage(arena: Allocator, value: std.json.Value) Allocator.Error!provider.Usage {
    if (value != .object) return .{
        .input_tokens = .{},
        .output_tokens = .{},
    };
    const object = value.object;
    const prompt_tokens = optionalU64(object.get("prompt_tokens"));
    const completion_tokens = optionalU64(object.get("completion_tokens"));
    const cached_tokens = nestedU64(object, "prompt_tokens_details", "cached_tokens") orelse 0;
    const reasoning_tokens = nestedU64(object, "completion_tokens_details", "reasoning_tokens") orelse 0;
    return .{
        .input_tokens = .{
            .total = prompt_tokens,
            .no_cache = if (prompt_tokens) |total| total -| cached_tokens else null,
            .cache_read = if (prompt_tokens != null) cached_tokens else null,
        },
        .output_tokens = .{
            .total = completion_tokens,
            .text = if (completion_tokens) |total| total -| reasoning_tokens else null,
            .reasoning = if (completion_tokens != null) reasoning_tokens else null,
        },
        .raw = try provider_utils.cloneJsonValue(arena, value),
    };
}

fn makeUsageMetadata(
    arena: Allocator,
    key: []const u8,
    usage: std.json.Value,
) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    if (usage == .object) {
        if (nestedU64(usage.object, "completion_tokens_details", "accepted_prediction_tokens")) |value| {
            try details.put(arena, "acceptedPredictionTokens", try uintValue(arena, value));
        }
        if (nestedU64(usage.object, "completion_tokens_details", "rejected_prediction_tokens")) |value| {
            try details.put(arena, "rejectedPredictionTokens", try uintValue(arena, value));
        }
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, try arena.dupe(u8, key), .{ .object = details });
    return .{ .object = root };
}

fn makeThoughtMetadata(
    arena: Allocator,
    key: []const u8,
    signature: []const u8,
) Allocator.Error!provider.ProviderMetadata {
    var details: std.json.ObjectMap = .empty;
    try putString(&details, arena, "thoughtSignature", signature);
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, try arena.dupe(u8, key), .{ .object = details });
    return .{ .object = root };
}

fn extractThoughtSignature(object: std.json.ObjectMap) ?[]const u8 {
    const extra = object.get("extra_content") orelse return null;
    if (extra != .object) return null;
    const google = extra.object.get("google") orelse return null;
    if (google != .object) return null;
    return optionalStringField(google.object, "thought_signature");
}

fn resolveApiKey(config: config_api.Config, arena: Allocator) Allocator.Error!?[]const u8 {
    if (config.api_key) |value| {
        const copy: []const u8 = try arena.dupe(u8, value);
        return copy;
    }
    const env_name = config.api_key_env_var orelse try derivedApiKeyEnv(arena, config.provider_name);
    return provider_utils.loadOptionalSetting(.{
        .explicit = null,
        .env_var = env_name,
        .description = "OpenAI-compatible",
        .setting_name = "apiKey",
        .env = config.env,
    }, arena);
}

fn derivedApiKeyEnv(arena: Allocator, provider_name: []const u8) Allocator.Error![]const u8 {
    const output = try arena.alloc(u8, provider_name.len + "_API_KEY".len);
    for (provider_name, output[0..provider_name.len]) |source, *destination| {
        destination.* = if (std.ascii.isAlphanumeric(source)) std.ascii.toUpper(source) else '_';
    }
    @memcpy(output[provider_name.len..], "_API_KEY");
    return output;
}

fn buildUrl(
    arena: Allocator,
    base_url: []const u8,
    query_params: []const config_api.QueryParam,
) Allocator.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    try output.appendSlice(arena, base_url);
    try output.appendSlice(arena, "/chat/completions");
    for (query_params, 0..) |query, index| {
        try output.append(arena, if (index == 0) '?' else '&');
        try appendPercentEncoded(arena, &output, query.name);
        try output.append(arena, '=');
        try appendPercentEncoded(arena, &output, query.value);
    }
    return output.toOwnedSlice(arena);
}

fn appendPercentEncoded(
    arena: Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(arena, byte);
        } else {
            try output.appendSlice(arena, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn toCamelCase(arena: Allocator, input: []const u8) Allocator.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    var uppercase_next = false;
    for (input) |byte| {
        if ((byte == '-' or byte == '_') and output.items.len != 0) {
            uppercase_next = true;
            continue;
        }
        try output.append(arena, if (uppercase_next) std.ascii.toUpper(byte) else byte);
        uppercase_next = false;
    }
    return output.toOwnedSlice(arena);
}

fn reasoningName(value: ?provider.ReasoningEffort) ?[]const u8 {
    return switch (value orelse return null) {
        .provider_default, .none => null,
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn mapFinishReason(value: ?[]const u8) provider.FinishReasonUnified {
    const reason = value orelse return .other;
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call"))
        return .tool_calls;
    return .other;
}

fn requireObject(
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    message: []const u8,
) provider.Error!std.json.ObjectMap {
    return if (value == .object) value.object else invalidResponse(diag, arena, message);
}

fn requireObjectField(
    object: std.json.ObjectMap,
    field: []const u8,
    diag: ?*provider.Diagnostics,
    arena: Allocator,
) provider.Error!std.json.ObjectMap {
    const value = object.get(field) orelse return invalidResponse(diag, arena, "Required response object is missing");
    return requireObject(value, diag, arena, "Required response field must be an object");
}

fn requireArrayField(
    object: std.json.ObjectMap,
    field: []const u8,
    diag: ?*provider.Diagnostics,
    arena: Allocator,
) provider.Error!std.json.Array {
    const value = object.get(field) orelse return invalidResponse(diag, arena, "Required response array is missing");
    return if (value == .array) value.array else invalidResponse(diag, arena, "Required response field must be an array");
}

fn invalidResponse(
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    message: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else arena, .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
}

fn invalidStream(
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    message: []const u8,
) provider.NextError {
    return invalidResponse(diag, arena, message);
}

fn unsupported(
    diag: ?*provider.Diagnostics,
    arena: Allocator,
    functionality: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else arena, .{
        .unsupported_functionality = .{
            .message = "OpenAI-compatible prompt feature is unsupported",
            .functionality = functionality,
        },
    });
    return error.UnsupportedFunctionalityError;
}

fn optionalStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalIndex(value: ?std.json.Value) ?usize {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        else => null,
    };
}

fn timestampMillis(value: ?std.json.Value) ?i64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| std.math.mul(i64, integer, 1000) catch null,
        .float => |float| if (std.math.isFinite(float)) @intFromFloat(float * 1000.0) else null,
        else => null,
    };
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}

fn nestedU64(object: std.json.ObjectMap, outer: []const u8, inner: []const u8) ?u64 {
    const value = object.get(outer) orelse return null;
    if (value != .object) return null;
    return optionalU64(value.object.get(inner));
}

fn uintValue(arena: Allocator, value: u64) Allocator.Error!std.json.Value {
    if (value <= std.math.maxInt(i64)) return .{ .integer = @intCast(value) };
    return .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{value}) };
}

fn putString(
    object: *std.json.ObjectMap,
    arena: Allocator,
    key: []const u8,
    value: []const u8,
) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn stringArray(arena: Allocator, values: []const []const u8) Allocator.Error!std.json.Value {
    var array = std.json.Array.init(arena);
    for (values) |value| try array.append(.{ .string = try arena.dupe(u8, value) });
    return .{ .array = array };
}

test "finish reason and usage conversion follow OpenAI-compatible semantics" {
    try std.testing.expectEqual(provider.FinishReasonUnified.tool_calls, mapFinishReason("function_call"));
    try std.testing.expectEqual(provider.FinishReasonUnified.content_filter, mapFinishReason("content_filter"));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const usage_value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"prompt_tokens\":20,\"completion_tokens\":30,\"prompt_tokens_details\":{\"cached_tokens\":5},\"completion_tokens_details\":{\"reasoning_tokens\":10}}",
        .{},
    );
    const usage = try convertUsage(arena, usage_value);
    try std.testing.expectEqual(20, usage.input_tokens.total.?);
    try std.testing.expectEqual(15, usage.input_tokens.no_cache.?);
    try std.testing.expectEqual(5, usage.input_tokens.cache_read.?);
    try std.testing.expectEqual(20, usage.output_tokens.text.?);
    try std.testing.expectEqual(10, usage.output_tokens.reasoning.?);
}
