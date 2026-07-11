//! Prompt standardization, tool preparation, and provider-prompt lowering.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const message = @import("message.zig");
const tool = @import("tool.zig");
const logger = @import("logger.zig");

const Allocator = std.mem.Allocator;

pub const Instructions = union(enum) {
    text: []const u8,
    message: message.SystemModelMessage,
    messages: []const message.SystemModelMessage,
};

pub const PromptValue = union(enum) {
    text: []const u8,
    messages: []const message.ModelMessage,
};

pub const PromptInput = struct {
    instructions: ?Instructions = null,
    prompt: ?PromptValue = null,
    messages: ?[]const message.ModelMessage = null,
    allow_system_in_messages: bool = false,
};

pub const StandardizedPrompt = struct {
    instructions: ?Instructions,
    messages: []const message.ModelMessage,
};

pub fn standardizePrompt(
    arena: Allocator,
    input: PromptInput,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!StandardizedPrompt {
    if (input.prompt == null and input.messages == null) {
        return invalidPrompt(arena, diag, "prompt or messages must be defined");
    }
    if (input.prompt != null and input.messages != null) {
        return invalidPrompt(arena, diag, "prompt and messages cannot be defined at the same time");
    }

    const messages: []const message.ModelMessage = if (input.prompt) |prompt| switch (prompt) {
        .text => |text| blk: {
            const result = try arena.alloc(message.ModelMessage, 1);
            result[0] = .{ .user = .{ .content = .{ .text = text } } };
            break :blk result;
        },
        .messages => |values| values,
    } else input.messages.?;

    if (messages.len == 0) {
        return invalidPrompt(arena, diag, "messages must not be empty");
    }
    if (!input.allow_system_in_messages) {
        for (messages) |item| switch (item) {
            .system => return invalidPrompt(
                arena,
                diag,
                "System messages are not allowed in the prompt or messages fields. Use the instructions option instead.",
            ),
            else => {},
        };
    }
    return .{ .instructions = input.instructions, .messages = messages };
}

fn invalidPrompt(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    text: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .invalid_prompt = .{
        .message = text,
    } });
    return error.InvalidPromptError;
}

pub const LanguageModelCallOptions = struct {
    max_output_tokens: ?f64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?f64 = null,
    reasoning: ?provider.ReasoningEffort = null,
};

pub const PreparedLanguageModelCallOptions = struct {
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?i64 = null,
    reasoning: ?provider.ReasoningEffort = null,
};

pub fn prepareLanguageModelCallOptions(
    arena: Allocator,
    options: LanguageModelCallOptions,
    diag: ?*provider.Diagnostics,
) provider.Error!PreparedLanguageModelCallOptions {
    const max_output_tokens: ?u64 = if (options.max_output_tokens) |value| blk: {
        if (!std.math.isFinite(value) or @floor(value) != value) {
            return invalidArgument(arena, diag, "maxOutputTokens", "maxOutputTokens must be an integer", value);
        }
        if (value < 1 or value >= 0x1p64) {
            return invalidArgument(arena, diag, "maxOutputTokens", "maxOutputTokens must be >= 1", value);
        }
        break :blk @intFromFloat(value);
    } else null;
    const seed: ?i64 = if (options.seed) |value| blk: {
        if (!std.math.isFinite(value) or @floor(value) != value or
            value < -0x1p63 or value >= 0x1p63)
        {
            return invalidArgument(arena, diag, "seed", "seed must be an integer", value);
        }
        break :blk @intFromFloat(value);
    } else null;

    return .{
        .max_output_tokens = max_output_tokens,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .top_k = options.top_k,
        .presence_penalty = options.presence_penalty,
        .frequency_penalty = options.frequency_penalty,
        .stop_sequences = options.stop_sequences,
        .seed = seed,
        .reasoning = options.reasoning,
    };
}

fn invalidArgument(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    parameter: []const u8,
    text: []const u8,
    value: f64,
) provider.Error {
    var buffer: [64]u8 = undefined;
    const value_json = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch null;
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .invalid_argument = .{
        .message = text,
        .parameter = parameter,
        .value_json = value_json,
    } });
    return error.InvalidArgumentError;
}

pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    named: []const u8,
};

pub fn prepareToolChoice(choice: ?ToolChoice) provider.ToolChoice {
    return if (choice) |value| switch (value) {
        .auto => .{ .auto = .{} },
        .none => .{ .none = .{} },
        .required => .{ .required = .{} },
        .named => |name| .{ .tool = .{ .tool_name = name } },
    } else .{ .auto = .{} };
}

pub fn prepareTools(
    arena: Allocator,
    tools: ?tool.ToolSet,
    tool_order: ?[]const []const u8,
    tools_context: ?std.json.Value,
    diag: ?*provider.Diagnostics,
) anyerror!?[]const provider.Tool {
    const source = tools orelse return null;
    if (source.len == 0) return null;

    const ordered = try orderTools(arena, source, tool_order);
    const result = try arena.alloc(provider.Tool, ordered.len);
    for (ordered, result) |named, *destination| {
        switch (named.tool.kind) {
            .function, .dynamic => {
                const context = if (tools_context) |value|
                    if (value == .object) value.object.get(named.name) else null
                else
                    null;
                const description = if (named.tool.description) |description| switch (description) {
                    .text => |text| text,
                    .resolver => |resolver| try resolver.resolve(context),
                } else null;
                const input_schema = try schemaDocumentValue(arena, named.tool.input_schema, diag);
                const examples = if (named.tool.input_examples) |input_examples| blk: {
                    const converted = try arena.alloc(provider.FunctionTool.InputExample, input_examples.len);
                    for (input_examples, converted) |example, *item| {
                        item.* = .{ .input = try provider_utils.cloneJsonValue(arena, example.input) };
                    }
                    break :blk converted;
                } else null;
                destination.* = .{ .function = .{
                    .name = named.name,
                    .description = description,
                    .input_schema = input_schema,
                    .input_examples = examples,
                    .strict = named.tool.strict,
                    .provider_options = named.tool.provider_options,
                } };
            },
            .provider_defined, .provider_executed => {
                const id = named.tool.provider_id orelse
                    return invalidToolDefinition(arena, diag, "provider tool id is required");
                const args = named.tool.provider_args orelse
                    return invalidToolDefinition(arena, diag, "provider tool args are required");
                destination.* = .{ .provider = .{
                    .name = named.name,
                    .id = id,
                    .args = try provider_utils.cloneJsonValue(arena, args),
                } };
            },
        }
    }
    return result;
}

fn schemaDocumentValue(
    arena: Allocator,
    schema: provider_utils.Schema,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!std.json.Value {
    return switch (schema.document) {
        .text => |text| provider_utils.parseJson(std.json.Value, arena, text, diag),
        .value => |value| provider_utils.cloneJsonValue(arena, value),
    };
}

fn invalidToolDefinition(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    text: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .invalid_argument = .{
        .message = text,
        .parameter = "tools",
    } });
    return error.InvalidArgumentError;
}

fn orderTools(
    arena: Allocator,
    tools: tool.ToolSet,
    tool_order: ?[]const []const u8,
) Allocator.Error![]const tool.NamedTool {
    const result = try arena.alloc(tool.NamedTool, tools.len);
    var used = try arena.alloc(bool, tools.len);
    @memset(used, false);
    var count: usize = 0;

    if (tool_order) |order| {
        for (order) |ordered_name| {
            for (tools, 0..) |named, index| {
                if (!used[index] and std.mem.eql(u8, named.name, ordered_name)) {
                    result[count] = named;
                    used[index] = true;
                    count += 1;
                    break;
                }
            }
        }
    }

    var remaining = try arena.alloc(tool.NamedTool, tools.len - count);
    var remaining_count: usize = 0;
    for (tools, used) |named, is_used| {
        if (!is_used) {
            remaining[remaining_count] = named;
            remaining_count += 1;
        }
    }
    std.mem.sort(tool.NamedTool, remaining[0..remaining_count], {}, struct {
        fn lessThan(_: void, a: tool.NamedTool, b: tool.NamedTool) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    @memcpy(result[count..], remaining[0..remaining_count]);
    return result;
}

pub const ErrorMode = enum { none, text, json };

pub fn createToolModelOutput(
    arena: Allocator,
    tool_call_id: []const u8,
    input: std.json.Value,
    output: ?std.json.Value,
    selected_tool: ?*const tool.Tool,
    error_mode: ErrorMode,
) anyerror!message.ToolResultOutput {
    const value = output orelse std.json.Value.null;
    switch (error_mode) {
        .text => return .{ .error_text = .{
            .value = try errorText(arena, output),
        } },
        .json => return .{ .error_json = .{
            .value = try provider_utils.cloneJsonValue(arena, value),
        } },
        .none => {},
    }

    if (selected_tool) |selected| {
        if (selected.to_model_output) |converter| {
            return converter.convert(arena, tool_call_id, input, value);
        }
    }
    return switch (value) {
        .string => |text| .{ .text = .{ .value = try arena.dupe(u8, text) } },
        else => .{ .json = .{ .value = try provider_utils.cloneJsonValue(arena, value) } },
    };
}

fn errorText(arena: Allocator, value: ?std.json.Value) Allocator.Error![]const u8 {
    const output = value orelse return arena.dupe(u8, "unknown error");
    return switch (output) {
        .string => |text| arena.dupe(u8, text),
        else => provider_utils.stringifyJsonValueAlloc(arena, output),
    };
}

pub const FileConversion = struct {
    data: provider.FileData,
    media_type: ?[]const u8 = null,
};

pub fn convertFilePartData(
    arena: Allocator,
    content: message.FilePartData,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!FileConversion {
    return switch (content) {
        .data => |data| convertInlineData(arena, data, diag),
        .url => |url| convertUrl(arena, url, diag),
        .reference => |reference| .{ .data = .{ .reference = .{
            .reference = try provider_utils.cloneJsonValue(arena, reference),
        } } },
        .text => |text| .{ .data = .{ .text = .{ .text = try arena.dupe(u8, text) } } },
        .string => |text| if (isAbsoluteUrl(text))
            convertUrl(arena, text, diag)
        else
            convertInlineData(arena, .{ .base64 = text }, diag),
    };
}

fn convertInlineData(
    arena: Allocator,
    data: message.DataContent,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!FileConversion {
    switch (data) {
        .base64 => |base64| if (std.mem.startsWith(u8, base64, "data:")) {
            return invalidDataContent(
                arena,
                diag,
                "Data URLs are not valid inline data. Pass them as { type: \"url\", url } instead.",
            );
        },
        else => {},
    }
    return .{ .data = .{ .data = .{ .data = switch (data) {
        .bytes => |bytes| .{ .bytes = try arena.dupe(u8, bytes) },
        .base64 => |base64| .{ .base64 = try arena.dupe(u8, base64) },
    } } } };
}

fn convertUrl(
    arena: Allocator,
    url: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!FileConversion {
    if (!std.ascii.startsWithIgnoreCase(url, "data:")) {
        return .{ .data = .{ .url = .{ .url = try arena.dupe(u8, url) } } };
    }
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse
        return invalidDataContent(arena, diag, "Invalid data URL format in content");
    const header = url["data:".len..comma];
    const semicolon = std.mem.indexOfScalar(u8, header, ';') orelse
        return invalidDataContent(arena, diag, "Invalid data URL format in content");
    const media_type = header[0..semicolon];
    if (media_type.len == 0 or
        std.mem.indexOf(u8, header[semicolon..], ";base64") == null or
        comma + 1 == url.len)
    {
        return invalidDataContent(arena, diag, "Invalid data URL format in content");
    }
    return .{
        .data = .{ .data = .{ .data = .{ .base64 = try arena.dupe(u8, url[comma + 1 ..]) } } },
        .media_type = try arena.dupe(u8, media_type),
    };
}

pub fn convertDataContentToBytes(
    arena: Allocator,
    content: message.DataContent,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)![]const u8 {
    return switch (content) {
        .bytes => |bytes| arena.dupe(u8, bytes),
        .base64 => |base64| provider_utils.decodeBase64(arena, base64) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => invalidDataContent(
                arena,
                diag,
                "Invalid data content. Content string is not a base64-encoded media.",
            ),
        },
    };
}

pub fn convertDataContentToBase64(
    arena: Allocator,
    content: message.DataContent,
) Allocator.Error![]const u8 {
    return switch (content) {
        .bytes => |bytes| provider_utils.encodeBase64(arena, bytes),
        .base64 => |base64| arena.dupe(u8, base64),
    };
}

fn invalidDataContent(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    text: []const u8,
) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .invalid_data_content = .{
        .message = text,
    } });
    return error.InvalidDataContentError;
}

fn isAbsoluteUrl(text: []const u8) bool {
    const uri = std.Uri.parse(text) catch return false;
    return uri.scheme.len != 0;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

pub const ConvertOptions = struct {
    prompt: StandardizedPrompt,
    model: ?provider.LanguageModel = null,
    transport: ?provider_utils.HttpTransport = null,
    provider_name: ?[]const u8 = null,
    download_options: provider_utils.DownloadOptions = .{},
};

pub const DownloadedAsset = struct {
    data: []const u8,
    media_type: ?[]const u8 = null,
};

const DownloadedAssets = std.StringHashMapUnmanaged(DownloadedAsset);

const PlannedDownload = struct {
    url: []const u8,
    media_type: []const u8,
};

const DownloadJob = struct {
    io: std.Io,
    transport: provider_utils.HttpTransport,
    plan: PlannedDownload,
    options: provider_utils.DownloadOptions,
    arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    result: ?provider_utils.DownloadResult = null,
    err: ?anyerror = null,

    fn run(self: *DownloadJob) void {
        self.result = provider_utils.download(
            self.io,
            self.arena_state.allocator(),
            self.transport,
            self.plan.url,
            self.options,
            &self.diagnostics,
        ) catch |err| {
            self.err = err;
            return;
        };
    }

    fn deinit(self: *DownloadJob) void {
        self.diagnostics.deinit();
        self.arena_state.deinit();
    }
};

/// Lowers application messages into the provider V4 prompt. Independent URL
/// downloads run in an Io.Group and use per-job arenas backed by the caller's
/// thread-safe GPA; results are copied into the request arena after join.
pub fn convertToLanguageModelPrompt(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) anyerror!provider.Prompt {
    var downloaded_assets = try downloadAssets(io, gpa, arena, options, diag);

    var approval_to_call: std.StringHashMapUnmanaged([]const u8) = .empty;
    var approved_calls: std.StringHashMapUnmanaged(void) = .empty;
    for (options.prompt.messages) |item| switch (item) {
        .assistant => |assistant| switch (assistant.content) {
            .text => {},
            .parts => |parts| for (parts) |part| switch (part) {
                .tool_approval_request => |request| try approval_to_call.put(
                    arena,
                    request.approval_id,
                    request.tool_call_id,
                ),
                else => {},
            },
        },
        else => {},
    };
    for (options.prompt.messages) |item| switch (item) {
        .tool => |tool_message| for (tool_message.content) |part| switch (part) {
            .tool_approval_response => |response| if (approval_to_call.get(response.approval_id)) |call_id| {
                try approved_calls.put(arena, call_id, {});
            },
            else => {},
        },
        else => {},
    };

    var converted: std.ArrayList(provider.Message) = .empty;
    defer converted.deinit(arena);
    if (options.prompt.instructions) |instructions| switch (instructions) {
        .text => |text| try converted.append(arena, .{ .system = .{
            .content = try arena.dupe(u8, text),
        } }),
        .message => |system| try converted.append(arena, .{ .system = .{
            .content = try arena.dupe(u8, system.content),
            .provider_options = try cloneOptionalJson(arena, system.provider_options),
        } }),
        .messages => |systems| for (systems) |system| try converted.append(arena, .{ .system = .{
            .content = try arena.dupe(u8, system.content),
            .provider_options = try cloneOptionalJson(arena, system.provider_options),
        } }),
    };
    for (options.prompt.messages) |item| {
        try converted.append(
            arena,
            try convertMessage(arena, item, &downloaded_assets, options.provider_name, diag),
        );
    }

    // Merge consecutive tool messages while retaining the first message's
    // provider options, matching the upstream object mutation semantics.
    var combined: std.ArrayList(provider.Message) = .empty;
    defer combined.deinit(arena);
    for (converted.items) |item| switch (item) {
        .tool => |tool_message| if (combined.items.len != 0 and combined.items[combined.items.len - 1] == .tool) {
            const previous = &combined.items[combined.items.len - 1].tool;
            const merged = try arena.alloc(
                provider.ToolContentPart,
                previous.content.len + tool_message.content.len,
            );
            @memcpy(merged[0..previous.content.len], previous.content);
            @memcpy(merged[previous.content.len..], tool_message.content);
            previous.content = merged;
        } else {
            try combined.append(arena, item);
        },
        else => try combined.append(arena, item),
    };

    var unresolved: std.StringHashMapUnmanaged(void) = .empty;
    var unresolved_order: std.ArrayList([]const u8) = .empty;
    defer unresolved_order.deinit(arena);
    for (combined.items) |item| switch (item) {
        .assistant => |assistant| for (assistant.content) |part| switch (part) {
            .tool_call => |call| if (call.provider_executed != true) {
                if (!unresolved.contains(call.tool_call_id)) {
                    try unresolved_order.append(arena, call.tool_call_id);
                }
                try unresolved.put(arena, call.tool_call_id, {});
            },
            else => {},
        },
        .tool => |tool_message| for (tool_message.content) |part| switch (part) {
            .tool_result => |result| _ = unresolved.remove(result.tool_call_id),
            else => {},
        },
        .user, .system => {
            subtractApproved(&unresolved, &approved_calls);
            if (unresolved.count() != 0) {
                return missingToolResults(arena, diag, &unresolved, unresolved_order.items);
            }
        },
    };
    subtractApproved(&unresolved, &approved_calls);
    if (unresolved.count() != 0) {
        return missingToolResults(arena, diag, &unresolved, unresolved_order.items);
    }

    var output: std.ArrayList(provider.Message) = .empty;
    defer output.deinit(arena);
    for (combined.items) |item| switch (item) {
        .tool => |tool_message| if (tool_message.content.len != 0)
            try output.append(arena, item),
        else => try output.append(arena, item),
    };
    return output.toOwnedSlice(arena);
}

pub fn downloadAssets(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    options: ConvertOptions,
    diag: ?*provider.Diagnostics,
) anyerror!DownloadedAssets {
    var planned: std.ArrayList(PlannedDownload) = .empty;
    defer planned.deinit(arena);
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (options.prompt.messages) |item| switch (item) {
        .user => |user| switch (user.content) {
            .text => {},
            .parts => |parts| for (parts) |part| switch (part) {
                .text => {},
                .image => |image| try planFile(
                    arena,
                    &planned,
                    &seen,
                    image.image,
                    image.media_type orelse "image",
                    options.model,
                    diag,
                ),
                .file => |file| try planFile(
                    arena,
                    &planned,
                    &seen,
                    file.data,
                    file.media_type,
                    options.model,
                    diag,
                ),
            },
        },
        .tool => |tool_message| for (tool_message.content) |part| switch (part) {
            .tool_result => |result| try planToolOutputFiles(
                arena,
                &planned,
                &seen,
                result.output,
                options.model,
                diag,
            ),
            else => {},
        },
        .assistant => |assistant| switch (assistant.content) {
            .text => {},
            .parts => |parts| for (parts) |part| switch (part) {
                .tool_result => |result| try planToolOutputFiles(
                    arena,
                    &planned,
                    &seen,
                    result.output,
                    options.model,
                    diag,
                ),
                else => {},
            },
        },
        .system => {},
    };

    var assets: DownloadedAssets = .empty;
    if (planned.items.len == 0) return assets;
    const transport = options.transport orelse {
        provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
            .message = "A download transport is required for unsupported URL file parts",
            .url = planned.items[0].url,
        } });
        return error.DownloadError;
    };

    const jobs = try arena.alloc(DownloadJob, planned.items.len);
    var initialized: usize = 0;
    defer for (jobs[0..initialized]) |*job| job.deinit();
    for (planned.items, jobs) |plan, *job| {
        job.* = .{
            .io = io,
            .transport = transport,
            .plan = plan,
            .options = options.download_options,
            .arena_state = .init(gpa),
            .diagnostics = provider.Diagnostics.init(gpa),
        };
        initialized += 1;
    }

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (jobs) |*job| group.async(io, DownloadJob.run, .{job});
    try group.await(io);

    for (jobs) |*job| {
        if (job.err) |err| {
            if (job.diagnostics.available) {
                provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), job.diagnostics.payload);
            }
            return err;
        }
        const result = job.result.?;
        try assets.put(arena, try arena.dupe(u8, job.plan.url), .{
            .data = try arena.dupe(u8, result.data),
            .media_type = if (result.media_type) |media_type|
                try arena.dupe(u8, media_type)
            else
                null,
        });
    }
    return assets;
}

fn planToolOutputFiles(
    arena: Allocator,
    planned: *std.ArrayList(PlannedDownload),
    seen: *std.StringHashMapUnmanaged(void),
    output: message.ToolResultOutput,
    model: ?provider.LanguageModel,
    diag: ?*provider.Diagnostics,
) anyerror!void {
    switch (output) {
        .content => |content| for (content.value) |part| switch (part) {
            .file => |file| try planFile(
                arena,
                planned,
                seen,
                file.data,
                file.media_type,
                model,
                diag,
            ),
            else => {},
        },
        else => {},
    }
}

fn planFile(
    arena: Allocator,
    planned: *std.ArrayList(PlannedDownload),
    seen: *std.StringHashMapUnmanaged(void),
    data: message.FilePartData,
    declared_media_type: []const u8,
    model: ?provider.LanguageModel,
    diag: ?*provider.Diagnostics,
) anyerror!void {
    const converted = try convertFilePartData(arena, data, diag);
    const url = switch (converted.data) {
        .url => |value| value.url,
        else => return,
    };
    const media_type = converted.media_type orelse declared_media_type;
    if (model) |language_model| {
        if (language_model.urlIsSupported(media_type, url)) return;
    }
    if (seen.contains(url)) return;
    try seen.put(arena, url, {});
    try planned.append(arena, .{ .url = url, .media_type = media_type });
}

fn convertMessage(
    arena: Allocator,
    item: message.ModelMessage,
    downloaded: *const DownloadedAssets,
    provider_name: ?[]const u8,
    diag: ?*provider.Diagnostics,
) anyerror!provider.Message {
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);

    const converted: provider.Message = switch (item) {
        .system => |system| .{ .system = .{
            .content = try arena.dupe(u8, system.content),
            .provider_options = try cloneOptionalJson(arena, system.provider_options),
        } },
        .user => |user| .{ .user = .{
            .content = try convertUserContent(arena, user.content, downloaded, &warnings, diag),
            .provider_options = try cloneOptionalJson(arena, user.provider_options),
        } },
        .assistant => |assistant| .{ .assistant = .{
            .content = try convertAssistantContent(
                arena,
                assistant.content,
                downloaded,
                provider_name,
                &warnings,
                diag,
            ),
            .provider_options = try cloneOptionalJson(arena, assistant.provider_options),
        } },
        .tool => |tool_message| .{ .tool = .{
            .content = try convertToolContent(
                arena,
                tool_message.content,
                downloaded,
                provider_name,
                &warnings,
                diag,
            ),
            .provider_options = try cloneOptionalJson(arena, tool_message.provider_options),
        } },
    };
    if (warnings.items.len != 0) logger.logWarnings(arena, .{ .warnings = warnings.items });
    return converted;
}

fn convertUserContent(
    arena: Allocator,
    content: message.Content(message.UserContentPart),
    downloaded: *const DownloadedAssets,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) anyerror![]const provider.UserContentPart {
    return switch (content) {
        .text => |text| blk: {
            const result = try arena.alloc(provider.UserContentPart, 1);
            result[0] = .{ .text = .{ .text = try arena.dupe(u8, text) } };
            break :blk result;
        },
        .parts => |parts| blk: {
            const result = try arena.alloc(provider.UserContentPart, parts.len);
            var count: usize = 0;
            for (parts) |part| switch (part) {
                .text => |text| if (text.text.len != 0) {
                    result[count] = .{ .text = .{
                        .text = try arena.dupe(u8, text.text),
                        .provider_options = try cloneOptionalJson(arena, text.provider_options),
                    } };
                    count += 1;
                },
                .image => |image| {
                    try warnings.append(arena, .{ .deprecated = .{
                        .setting = "\"image\" content part",
                        .message = "The \"image\" content part type is deprecated. Use a \"file\" part with mediaType: 'image' (or a more specific image/* subtype) instead.",
                    } });
                    result[count] = .{ .file = try convertFile(
                        arena,
                        image.image,
                        null,
                        image.media_type orelse "image",
                        image.provider_options,
                        downloaded,
                        diag,
                    ) };
                    count += 1;
                },
                .file => |file| {
                    result[count] = .{ .file = try convertFile(
                        arena,
                        file.data,
                        file.filename,
                        file.media_type,
                        file.provider_options,
                        downloaded,
                        diag,
                    ) };
                    count += 1;
                },
            };
            break :blk result[0..count];
        },
    };
}

fn convertAssistantContent(
    arena: Allocator,
    content: message.Content(message.AssistantContentPart),
    downloaded: *const DownloadedAssets,
    provider_name: ?[]const u8,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) anyerror![]const provider.AssistantContentPart {
    return switch (content) {
        .text => |text| blk: {
            const result = try arena.alloc(provider.AssistantContentPart, 1);
            result[0] = .{ .text = .{ .text = try arena.dupe(u8, text) } };
            break :blk result;
        },
        .parts => |parts| blk: {
            const result = try arena.alloc(provider.AssistantContentPart, parts.len);
            var count: usize = 0;
            for (parts) |part| switch (part) {
                .tool_approval_request => {},
                .text => |text| if (text.text.len != 0 or text.provider_options != null) {
                    result[count] = .{ .text = .{
                        .text = try arena.dupe(u8, text.text),
                        .provider_options = try cloneOptionalJson(arena, text.provider_options),
                    } };
                    count += 1;
                },
                .custom => |custom| {
                    result[count] = .{ .custom = .{
                        .kind = try arena.dupe(u8, custom.kind),
                        .provider_options = try cloneOptionalJson(arena, custom.provider_options),
                    } };
                    count += 1;
                },
                .file => |file| {
                    result[count] = .{ .file = try convertFile(
                        arena,
                        file.data,
                        file.filename,
                        file.media_type,
                        file.provider_options,
                        downloaded,
                        diag,
                    ) };
                    count += 1;
                },
                .reasoning => |reasoning| {
                    result[count] = .{ .reasoning = .{
                        .text = try arena.dupe(u8, reasoning.text),
                        .provider_options = try cloneOptionalJson(arena, reasoning.provider_options),
                    } };
                    count += 1;
                },
                .reasoning_file => |file| {
                    const converted = try convertFilePartData(arena, file.data, diag);
                    const generated_data: provider.GeneratedFileData = switch (converted.data) {
                        .data => |data| .{ .data = .{ .data = data.data } },
                        .url => |url| .{ .url = .{ .url = url.url } },
                        else => return invalidDataContent(
                            arena,
                            diag,
                            "Reasoning file data must be inline data or a URL",
                        ),
                    };
                    result[count] = .{ .reasoning_file = .{
                        .data = generated_data,
                        .media_type = try arena.dupe(u8, converted.media_type orelse file.media_type),
                        .provider_options = try cloneOptionalJson(arena, file.provider_options),
                    } };
                    count += 1;
                },
                .tool_call => |call| {
                    result[count] = .{ .tool_call = .{
                        .tool_call_id = try arena.dupe(u8, call.tool_call_id),
                        .tool_name = try arena.dupe(u8, call.tool_name),
                        .input = try provider_utils.cloneJsonValue(arena, call.input),
                        .provider_executed = call.provider_executed,
                        .provider_options = try cloneOptionalJson(arena, call.provider_options),
                    } };
                    count += 1;
                },
                .tool_result => |tool_result| {
                    result[count] = .{ .tool_result = .{
                        .tool_call_id = try arena.dupe(u8, tool_result.tool_call_id),
                        .tool_name = try arena.dupe(u8, tool_result.tool_name),
                        .output = try mapToolResultOutput(
                            arena,
                            tool_result.output,
                            downloaded,
                            provider_name,
                            warnings,
                            diag,
                        ),
                        .provider_options = try cloneOptionalJson(arena, tool_result.provider_options),
                    } };
                    count += 1;
                },
            };
            break :blk result[0..count];
        },
    };
}

fn convertToolContent(
    arena: Allocator,
    content: []const message.ToolContentPart,
    downloaded: *const DownloadedAssets,
    provider_name: ?[]const u8,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) anyerror![]const provider.ToolContentPart {
    const result = try arena.alloc(provider.ToolContentPart, content.len);
    var count: usize = 0;
    for (content) |part| switch (part) {
        .tool_approval_response => |response| if (response.provider_executed == true) {
            result[count] = .{ .tool_approval_response = .{
                .approval_id = try arena.dupe(u8, response.approval_id),
                .approved = response.approved,
                .reason = if (response.reason) |reason| try arena.dupe(u8, reason) else null,
            } };
            count += 1;
        },
        .tool_result => |tool_result| {
            result[count] = .{ .tool_result = .{
                .tool_call_id = try arena.dupe(u8, tool_result.tool_call_id),
                .tool_name = try arena.dupe(u8, tool_result.tool_name),
                .output = try mapToolResultOutput(
                    arena,
                    tool_result.output,
                    downloaded,
                    provider_name,
                    warnings,
                    diag,
                ),
                .provider_options = try cloneOptionalJson(arena, tool_result.provider_options),
            } };
            count += 1;
        },
    };
    return result[0..count];
}

fn convertFile(
    arena: Allocator,
    input_data: message.FilePartData,
    filename: ?[]const u8,
    declared_media_type: []const u8,
    provider_options: ?provider.ProviderOptions,
    downloaded: *const DownloadedAssets,
    diag: ?*provider.Diagnostics,
) anyerror!provider.FilePart {
    const converted = try convertFilePartData(arena, input_data, diag);
    var data = converted.data;
    var media_type: []const u8 = converted.media_type orelse declared_media_type;

    if (data == .url) {
        if (downloaded.get(data.url.url)) |asset| {
            data = .{ .data = .{ .data = .{ .bytes = asset.data } } };
            if (asset.media_type) |downloaded_media_type| {
                if (!provider_utils.isFullMediaType(media_type)) {
                    media_type = downloaded_media_type;
                }
            }
        }
    }

    if (data == .data) {
        const detected = switch (data.data.data) {
            .bytes => |bytes| try provider_utils.detectMediaType(arena, .{ .bytes = bytes }, "image"),
            .base64 => |base64| try provider_utils.detectMediaType(arena, .{ .base64 = base64 }, "image"),
        };
        if (detected) |detected_media_type| media_type = detected_media_type;
    }
    if (media_type.len == 0) return invalidDataContent(arena, diag, "Media type is missing for file part");
    return .{
        .filename = if (filename) |name| try arena.dupe(u8, name) else null,
        .data = data,
        .media_type = try arena.dupe(u8, media_type),
        .provider_options = try cloneOptionalJson(arena, provider_options),
    };
}

fn mapToolResultOutput(
    arena: Allocator,
    output: message.ToolResultOutput,
    downloaded: *const DownloadedAssets,
    provider_name: ?[]const u8,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) anyerror!provider.ToolResultOutput {
    return switch (output) {
        .text => |value| .{ .text = .{
            .value = try arena.dupe(u8, value.value),
            .provider_options = try cloneOptionalJson(arena, value.provider_options),
        } },
        .json => |value| .{ .json = .{
            .value = try provider_utils.cloneJsonValue(arena, value.value),
            .provider_options = try cloneOptionalJson(arena, value.provider_options),
        } },
        .execution_denied => |value| .{ .execution_denied = .{
            .reason = if (value.reason) |reason| try arena.dupe(u8, reason) else null,
            .provider_options = try cloneOptionalJson(arena, value.provider_options),
        } },
        .error_text => |value| .{ .error_text = .{
            .value = try arena.dupe(u8, value.value),
            .provider_options = try cloneOptionalJson(arena, value.provider_options),
        } },
        .error_json => |value| .{ .error_json = .{
            .value = try provider_utils.cloneJsonValue(arena, value.value),
            .provider_options = try cloneOptionalJson(arena, value.provider_options),
        } },
        .content => |content| blk: {
            const parts = try arena.alloc(provider.ToolResultContentPart, content.value.len);
            for (content.value, parts) |part, *destination| {
                destination.* = try mapToolResultContentPart(
                    arena,
                    part,
                    downloaded,
                    provider_name,
                    warnings,
                    diag,
                );
            }
            break :blk .{ .content = .{ .value = parts } };
        },
    };
}

fn mapToolResultContentPart(
    arena: Allocator,
    part: message.ToolResultContentPart,
    downloaded: *const DownloadedAssets,
    provider_name: ?[]const u8,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) anyerror!provider.ToolResultContentPart {
    return switch (part) {
        .text => |text| .{ .text = .{
            .text = try arena.dupe(u8, text.text),
            .provider_options = try cloneOptionalJson(arena, text.provider_options),
        } },
        .file => |file| .{ .file = toolResultFile(try convertFile(
            arena,
            file.data,
            file.filename,
            file.media_type,
            file.provider_options,
            downloaded,
            diag,
        )) },
        .file_data => |file| blk: {
            try deprecation(warnings, arena, "file-data", "The \"file-data\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'data', data } instead.");
            break :blk .{ .file = .{
                .data = .{ .data = .{ .data = .{ .base64 = try arena.dupe(u8, file.data) } } },
                .media_type = try arena.dupe(u8, file.media_type),
                .filename = if (file.filename) |name| try arena.dupe(u8, name) else null,
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .file_url => |file| blk: {
            const media_type = file.media_type orelse mediaTypeFromUrl(file.url);
            const warning_message = if (file.media_type == null)
                try std.fmt.allocPrint(
                    arena,
                    "The \"file-url\" tool result content part with URL \"{s}\" is missing a \"mediaType\". {s} The \"file-url\" type for tool result content is deprecated. Use the \"file\" type with mediaType and {{ type: 'url', url }} instead.",
                    .{
                        file.url,
                        if (std.mem.eql(u8, media_type, "application/octet-stream"))
                            "Unable to infer media type from URL. Defaulting to 'application/octet-stream'."
                        else
                            try std.fmt.allocPrint(arena, "Inferred media type '{s}' from URL.", .{media_type}),
                    },
                )
            else
                "The \"file-url\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'url', url } instead.";
            try deprecation(warnings, arena, "file-url", warning_message);
            break :blk .{ .file = .{
                .data = .{ .url = .{ .url = try arena.dupe(u8, file.url) } },
                .media_type = try arena.dupe(u8, media_type),
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .file_id => |file| blk: {
            try deprecation(warnings, arena, "file-id", "The \"file-id\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'reference', reference } instead.");
            break :blk .{ .file = .{
                .data = .{ .reference = .{ .reference = try fileIdReference(arena, file.file_id, provider_name, diag) } },
                .media_type = "application",
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .file_reference => |file| blk: {
            try deprecation(warnings, arena, "file-reference", "The \"file-reference\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'reference', reference } instead.");
            break :blk .{ .file = .{
                .data = .{ .reference = .{ .reference = try provider_utils.cloneJsonValue(arena, file.provider_reference) } },
                .media_type = "application",
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .image_data => |file| blk: {
            try deprecation(warnings, arena, "image-data", "The \"image-data\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'data', data } instead.");
            break :blk .{ .file = .{
                .data = .{ .data = .{ .data = .{ .base64 = try arena.dupe(u8, file.data) } } },
                .media_type = try arena.dupe(u8, file.media_type),
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .image_url => |file| blk: {
            try deprecation(warnings, arena, "image-url", "The \"image-url\" type for tool result content is deprecated. Use the \"file\" type with mediaType 'image' (or a specific image/* subtype) and { type: 'url', url } instead.");
            break :blk .{ .file = .{
                .data = .{ .url = .{ .url = try arena.dupe(u8, file.url) } },
                .media_type = "image",
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .image_file_id => |file| blk: {
            try deprecation(warnings, arena, "image-file-id", "The \"image-file-id\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'reference', reference } instead.");
            break :blk .{ .file = .{
                .data = .{ .reference = .{ .reference = try fileIdReference(arena, file.file_id, provider_name, diag) } },
                .media_type = "image",
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .image_file_reference => |file| blk: {
            try deprecation(warnings, arena, "image-file-reference", "The \"image-file-reference\" type for tool result content is deprecated. Use the \"file\" type with mediaType and { type: 'reference', reference } instead.");
            break :blk .{ .file = .{
                .data = .{ .reference = .{ .reference = try provider_utils.cloneJsonValue(arena, file.provider_reference) } },
                .media_type = "image",
                .provider_options = try cloneOptionalJson(arena, file.provider_options),
            } };
        },
        .custom => |custom| .{ .custom = .{
            .provider_options = try cloneOptionalJson(arena, custom.provider_options),
        } },
    };
}

fn toolResultFile(file: provider.FilePart) provider.ToolResultContentPart.File {
    return .{
        .data = file.data,
        .media_type = file.media_type,
        .filename = file.filename,
        .provider_options = file.provider_options,
    };
}

fn deprecation(
    warnings: *std.ArrayList(provider.Warning),
    arena: Allocator,
    kind: []const u8,
    text: []const u8,
) Allocator.Error!void {
    try warnings.append(arena, .{ .deprecated = .{
        .setting = try std.fmt.allocPrint(arena, "\"tool-result\" content of type \"{s}\"", .{kind}),
        .message = text,
    } });
}

fn fileIdReference(
    arena: Allocator,
    file_id: message.FileId,
    provider_name: ?[]const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!std.json.Value {
    return switch (file_id) {
        .references => |references| provider_utils.cloneJsonValue(arena, references),
        .id => |id| blk: {
            const name = provider_name orelse return invalidDataContent(
                arena,
                diag,
                "Cannot convert string fileId to provider reference without a provider ID. Use a reference map instead.",
            );
            var object: std.json.ObjectMap = .empty;
            try object.put(arena, try arena.dupe(u8, name), .{ .string = try arena.dupe(u8, id) });
            break :blk .{ .object = object };
        },
    };
}

fn mediaTypeFromUrl(url: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const fragment = std.mem.indexOfScalar(u8, url[0..query], '#') orelse query;
    const path = url[0..fragment];
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const extension = path[dot + 1 ..];
    const Entry = struct { extension: []const u8, media_type: []const u8 };
    const entries = [_]Entry{
        .{ .extension = "jpg", .media_type = "image/jpeg" },
        .{ .extension = "jpeg", .media_type = "image/jpeg" },
        .{ .extension = "png", .media_type = "image/png" },
        .{ .extension = "gif", .media_type = "image/gif" },
        .{ .extension = "webp", .media_type = "image/webp" },
        .{ .extension = "svg", .media_type = "image/svg+xml" },
        .{ .extension = "avif", .media_type = "image/avif" },
        .{ .extension = "heic", .media_type = "image/heic" },
        .{ .extension = "bmp", .media_type = "image/bmp" },
        .{ .extension = "tiff", .media_type = "image/tiff" },
        .{ .extension = "tif", .media_type = "image/tiff" },
        .{ .extension = "pdf", .media_type = "application/pdf" },
        .{ .extension = "mp4", .media_type = "video/mp4" },
        .{ .extension = "webm", .media_type = "video/webm" },
        .{ .extension = "mp3", .media_type = "audio/mpeg" },
        .{ .extension = "wav", .media_type = "audio/wav" },
        .{ .extension = "ogg", .media_type = "audio/ogg" },
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry.extension)) return entry.media_type;
    }
    return "application/octet-stream";
}

fn cloneOptionalJson(arena: Allocator, value: ?std.json.Value) Allocator.Error!?std.json.Value {
    return if (value) |item| try provider_utils.cloneJsonValue(arena, item) else null;
}

fn subtractApproved(
    unresolved: *std.StringHashMapUnmanaged(void),
    approved: *const std.StringHashMapUnmanaged(void),
) void {
    var iterator = approved.iterator();
    while (iterator.next()) |entry| _ = unresolved.remove(entry.key_ptr.*);
}

fn missingToolResults(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    unresolved: *const std.StringHashMapUnmanaged(void),
    insertion_order: []const []const u8,
) provider.Error {
    const ids = arena.alloc([]const u8, unresolved.count()) catch return error.MissingToolResultsError;
    var index: usize = 0;
    for (insertion_order) |id| {
        if (unresolved.contains(id)) {
            ids[index] = id;
            index += 1;
        }
    }
    const joined = std.mem.join(arena, ", ", ids) catch "unknown";
    const text = if (ids.len > 1)
        std.fmt.allocPrint(arena, "Tool results are missing for tool calls {s}.", .{joined}) catch
            "Tool results are missing."
    else
        std.fmt.allocPrint(arena, "Tool result is missing for tool call {s}.", .{joined}) catch
            "Tool result is missing.";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .missing_tool_results = .{
        .message = text,
        .tool_call_ids = ids,
    } });
    return error.MissingToolResultsError;
}

test "standardizePrompt exact errors and string lowering" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.InvalidPromptError,
        standardizePrompt(arena, .{}, &diagnostics),
    );
    try std.testing.expectEqualStrings(
        "prompt or messages must be defined",
        diagnostics.payload.invalid_prompt.message,
    );

    const one_message = [_]message.ModelMessage{.{ .user = .{ .content = .{ .text = "hello" } } }};
    try std.testing.expectError(
        error.InvalidPromptError,
        standardizePrompt(arena, .{
            .prompt = .{ .text = "hello" },
            .messages = &one_message,
        }, &diagnostics),
    );
    try std.testing.expectEqualStrings(
        "prompt and messages cannot be defined at the same time",
        diagnostics.payload.invalid_prompt.message,
    );

    const empty = [_]message.ModelMessage{};
    try std.testing.expectError(
        error.InvalidPromptError,
        standardizePrompt(arena, .{ .messages = &empty }, &diagnostics),
    );
    try std.testing.expectEqualStrings("messages must not be empty", diagnostics.payload.invalid_prompt.message);

    const system_messages = [_]message.ModelMessage{.{ .system = .{ .content = "rules" } }};
    try std.testing.expectError(
        error.InvalidPromptError,
        standardizePrompt(arena, .{ .messages = &system_messages }, &diagnostics),
    );
    try std.testing.expectEqualStrings(
        "System messages are not allowed in the prompt or messages fields. Use the instructions option instead.",
        diagnostics.payload.invalid_prompt.message,
    );

    const standardized = try standardizePrompt(arena, .{ .prompt = .{ .text = "hello" } }, null);
    try std.testing.expectEqualStrings("hello", standardized.messages[0].user.content.text);
}

test "prepareLanguageModelCallOptions validates integers with diagnostics" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.InvalidArgumentError,
        prepareLanguageModelCallOptions(std.testing.allocator, .{ .max_output_tokens = 10.5 }, &diagnostics),
    );
    try std.testing.expectEqualStrings("maxOutputTokens", diagnostics.payload.invalid_argument.parameter);
    try std.testing.expectEqualStrings(
        "maxOutputTokens must be an integer",
        diagnostics.payload.invalid_argument.message,
    );
    try std.testing.expectError(
        error.InvalidArgumentError,
        prepareLanguageModelCallOptions(std.testing.allocator, .{ .max_output_tokens = 0 }, &diagnostics),
    );
    const valid = try prepareLanguageModelCallOptions(std.testing.allocator, .{
        .max_output_tokens = 100,
        .seed = 42,
        .reasoning = .high,
    }, null);
    try std.testing.expectEqual(100, valid.max_output_tokens.?);
    try std.testing.expectEqual(42, valid.seed.?);
    try std.testing.expectEqual(.high, valid.reasoning.?);
}

test "prepareTools orders, resolves descriptions, and lowers schemas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Resolver = struct {
        fn resolve(_: ?*anyopaque, context: ?std.json.Value) anyerror![]const u8 {
            return context.?.string;
        }
    };
    var context_object: std.json.ObjectMap = .empty;
    try context_object.put(arena, "middle", .{ .string = "context description" });
    const tools = [_]tool.NamedTool{
        .{ .name = "zebra", .tool = .{
            .description = .{ .text = "z" },
            .input_schema = provider_utils.rawSchema("{\"type\":\"object\"}", null),
        } },
        .{ .name = "alpha", .tool = .{
            .description = .{ .text = "a" },
            .input_schema = provider_utils.rawSchema("{\"type\":\"object\"}", null),
        } },
        .{ .name = "middle", .tool = .{
            .kind = .dynamic,
            .description = .{ .resolver = .{ .resolve_fn = Resolver.resolve } },
            .input_schema = provider_utils.rawSchema("{\"type\":\"object\"}", null),
        } },
        .{ .name = "providerTool", .tool = .{
            .kind = .provider_executed,
            .input_schema = provider_utils.rawSchema("{}", null),
            .provider_id = "provider.tool",
            .provider_args = .{ .object = .empty },
        } },
    };
    const order = [_][]const u8{"middle"};
    const prepared = (try prepareTools(
        arena,
        &tools,
        &order,
        .{ .object = context_object },
        null,
    )).?;
    try std.testing.expectEqualStrings("middle", prepared[0].function.name);
    try std.testing.expectEqualStrings("context description", prepared[0].function.description.?);
    try std.testing.expectEqualStrings("alpha", prepared[1].function.name);
    try std.testing.expectEqualStrings("providerTool", prepared[2].provider.name);
    try std.testing.expectEqualStrings("provider.tool", prepared[2].provider.id);
    try std.testing.expectEqualStrings("zebra", prepared[3].function.name);
    try std.testing.expect(prepared[0].function.input_schema == .object);
}

test "createToolModelOutput covers error modes, hook, and default output kinds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input: std.json.Value = .{ .integer = 1 };

    const text_error = try createToolModelOutput(
        arena,
        "call",
        input,
        .{ .object = .empty },
        null,
        .text,
    );
    try std.testing.expectEqualStrings("{}", text_error.error_text.value);
    const json_error = try createToolModelOutput(arena, "call", input, null, null, .json);
    try std.testing.expect(json_error.error_json.value == .null);
    const text = try createToolModelOutput(
        arena,
        "call",
        input,
        .{ .string = "answer" },
        null,
        .none,
    );
    try std.testing.expectEqualStrings("answer", text.text.value);

    const Converter = struct {
        fn convert(
            _: ?*anyopaque,
            _: Allocator,
            tool_call_id: []const u8,
            _: std.json.Value,
            _: std.json.Value,
        ) anyerror!message.ToolResultOutput {
            return .{ .text = .{ .value = tool_call_id } };
        }
    };
    const selected: tool.Tool = .{
        .input_schema = provider_utils.rawSchema("{}", null),
        .to_model_output = .{ .convert_fn = Converter.convert },
    };
    const hooked = try createToolModelOutput(
        arena,
        "hooked-call",
        input,
        .{ .integer = 9 },
        &selected,
        .none,
    );
    try std.testing.expectEqualStrings("hooked-call", hooked.text.value);
}

test "file data helpers handle data URLs, URL probes, bytes, and invalid inline data URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data_url = try convertFilePartData(
        arena,
        .{ .string = "data:text/plain;base64,aGVsbG8=" },
        null,
    );
    try std.testing.expectEqualStrings("text/plain", data_url.media_type.?);
    try std.testing.expectEqualStrings("aGVsbG8=", data_url.data.data.data.base64);
    const url = try convertFilePartData(
        arena,
        .{ .string = "https://example.test/file.pdf" },
        null,
    );
    try std.testing.expectEqualStrings("https://example.test/file.pdf", url.data.url.url);
    try std.testing.expectEqualStrings(
        "hello",
        try convertDataContentToBytes(arena, .{ .base64 = "aGVsbG8=" }, null),
    );
    try std.testing.expectError(
        error.InvalidDataContentError,
        convertFilePartData(
            arena,
            .{ .data = .{ .base64 = "data:text/plain;base64,aGVsbG8=" } },
            null,
        ),
    );
}

test "prompt conversion merges tool messages and approval responses satisfy missing results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const assistant_parts = [_]message.AssistantContentPart{
        .{ .tool_call = .{
            .tool_call_id = "call-1",
            .tool_name = "weather",
            .input = .{ .object = .empty },
        } },
        .{ .tool_approval_request = .{
            .approval_id = "approval-1",
            .tool_call_id = "call-1",
        } },
    };
    const approval_parts = [_]message.ToolContentPart{.{ .tool_approval_response = .{
        .approval_id = "approval-1",
        .approved = true,
    } }};
    const result_parts = [_]message.ToolContentPart{.{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "weather",
        .output = .{ .json = .{ .value = .{ .integer = 72 } } },
    } }};
    const messages = [_]message.ModelMessage{
        .{ .assistant = .{ .content = .{ .parts = &assistant_parts } } },
        .{ .tool = .{ .content = &approval_parts } },
        .{ .tool = .{ .content = &result_parts } },
    };
    const converted = try convertToLanguageModelPrompt(
        std.testing.io,
        std.testing.allocator,
        arena,
        .{ .prompt = .{ .instructions = null, .messages = &messages } },
        null,
    );
    try std.testing.expectEqual(2, converted.len);
    try std.testing.expectEqual(1, converted[0].assistant.content.len);
    try std.testing.expectEqual(1, converted[1].tool.content.len);
    try std.testing.expect(converted[1].tool.content[0] == .tool_result);
}

test "approved tool calls do not require tool results and empty tool messages are dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const assistant_parts = [_]message.AssistantContentPart{
        .{ .tool_call = .{
            .tool_call_id = "approved-call",
            .tool_name = "dangerous",
            .input = .null,
        } },
        .{ .tool_approval_request = .{
            .approval_id = "approval",
            .tool_call_id = "approved-call",
        } },
    };
    const approval = [_]message.ToolContentPart{.{ .tool_approval_response = .{
        .approval_id = "approval",
        .approved = true,
    } }};
    const messages = [_]message.ModelMessage{
        .{ .assistant = .{ .content = .{ .parts = &assistant_parts } } },
        .{ .tool = .{ .content = &approval } },
    };
    const converted = try convertToLanguageModelPrompt(
        std.testing.io,
        std.testing.allocator,
        arena,
        .{ .prompt = .{ .instructions = null, .messages = &messages } },
        null,
    );
    try std.testing.expectEqual(1, converted.len);
    try std.testing.expect(converted[0] == .assistant);
    try std.testing.expectEqual(1, converted[0].assistant.content.len);
}

test "prompt conversion reports missing results and filters empty text precisely" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const assistant_parts = [_]message.AssistantContentPart{.{ .tool_call = .{
        .tool_call_id = "missing",
        .tool_name = "tool",
        .input = .null,
    } }};
    const missing_messages = [_]message.ModelMessage{.{ .assistant = .{
        .content = .{ .parts = &assistant_parts },
    } }};
    try std.testing.expectError(
        error.MissingToolResultsError,
        convertToLanguageModelPrompt(
            std.testing.io,
            std.testing.allocator,
            arena,
            .{ .prompt = .{ .instructions = null, .messages = &missing_messages } },
            &diagnostics,
        ),
    );
    try std.testing.expectEqualStrings("missing", diagnostics.payload.missing_tool_results.tool_call_ids[0]);

    const user_parts = [_]message.UserContentPart{
        .{ .text = .{ .text = "" } },
        .{ .text = .{ .text = "kept" } },
    };
    const filtered_messages = [_]message.ModelMessage{.{ .user = .{
        .content = .{ .parts = &user_parts },
    } }};
    const filtered = try convertToLanguageModelPrompt(
        std.testing.io,
        std.testing.allocator,
        arena,
        .{ .prompt = .{ .instructions = null, .messages = &filtered_messages } },
        null,
    );
    try std.testing.expectEqual(1, filtered[0].user.content.len);
    try std.testing.expectEqualStrings("kept", filtered[0].user.content[0].text.text);
}

test "image parts lower to files and emit the exact deprecation warning record" {
    const Capture = struct {
        calls: usize = 0,
        setting: ?[]const u8 = null,
        fn log(raw: ?*anyopaque, options: *const logger.Options) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.setting = options.warnings[0].deprecated.setting;
        }
    };
    var capture: Capture = .{};
    logger.setWarningLogger(.{ .custom = .{ .ctx = &capture, .log_fn = Capture.log } });
    defer logger.setWarningLogger(.default);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_parts = [_]message.UserContentPart{.{ .image = .{
        .image = .{ .data = .{ .base64 = "/9j/3Q==" } },
    } }};
    const messages = [_]message.ModelMessage{.{ .user = .{
        .content = .{ .parts = &user_parts },
    } }};
    const converted = try convertToLanguageModelPrompt(
        std.testing.io,
        std.testing.allocator,
        arena,
        .{ .prompt = .{ .instructions = null, .messages = &messages } },
        null,
    );
    try std.testing.expectEqualStrings("image/jpeg", converted[0].user.content[0].file.media_type);
    try std.testing.expectEqual(1, capture.calls);
    try std.testing.expectEqualStrings("\"image\" content part", capture.setting.?);
}
