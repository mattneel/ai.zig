const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const BuildError = provider.Error || Allocator.Error;

pub const CacheControlValidator = struct {
    breakpoints: usize = 0,

    pub fn get(
        self: *CacheControlValidator,
        allocator: Allocator,
        provider_options: ?provider.ProviderOptions,
        context_type: []const u8,
        can_cache: bool,
        warnings: *std.ArrayList(provider.Warning),
    ) Allocator.Error!?std.json.Value {
        const value = cacheControlValue(provider_options) orelse return null;
        if (!can_cache) {
            try warnings.append(allocator, .{ .unsupported = .{
                .feature = "cache_control on non-cacheable context",
                .details = try std.fmt.allocPrint(
                    allocator,
                    "cache_control cannot be set on {s}. It will be ignored.",
                    .{context_type},
                ),
            } });
            return null;
        }
        self.breakpoints += 1;
        if (self.breakpoints > 4) {
            try warnings.append(allocator, .{ .unsupported = .{
                .feature = "cacheControl breakpoint limit",
                .details = try std.fmt.allocPrint(
                    allocator,
                    "Maximum 4 cache breakpoints exceeded (found {d}). This breakpoint will be ignored.",
                    .{self.breakpoints},
                ),
            } });
            return null;
        }
        const copy: std.json.Value = try provider_utils.cloneJsonValue(allocator, value);
        return copy;
    }
};

pub const Result = struct {
    system: ?std.json.Value,
    messages: std.json.Value,
    betas: utils.BetaSet,
};

pub fn convert(
    allocator: Allocator,
    input: provider.Prompt,
    send_reasoning: bool,
    tools: ?[]const provider.Tool,
    warnings: *std.ArrayList(provider.Warning),
    cache_validator: *CacheControlValidator,
    diag: ?*provider.Diagnostics,
) BuildError!Result {
    var betas: utils.BetaSet = .{};
    var system: ?std.json.Value = null;
    var messages = std.json.Array.init(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const start = index;
        const run = switch (input[index]) {
            .system => Run.system,
            .assistant => Run.assistant,
            .user, .tool => Run.user,
        };
        index += 1;
        while (index < input.len and roleRun(input[index]) == run) index += 1;
        const is_last_block = index == input.len;

        switch (run) {
            .system => {
                var content = std.json.Array.init(allocator);
                for (input[start..index]) |message| {
                    const item = message.system;
                    var block: std.json.ObjectMap = .empty;
                    try utils.putString(&block, allocator, "type", "text");
                    try utils.putString(&block, allocator, "text", item.content);
                    if (try cache_validator.get(
                        allocator,
                        item.provider_options,
                        "system message",
                        true,
                        warnings,
                    )) |cache| try block.put(allocator, "cache_control", cache);
                    try content.append(.{ .object = block });
                }
                if (system == null) {
                    system = .{ .array = content };
                } else {
                    var message: std.json.ObjectMap = .empty;
                    try utils.putString(&message, allocator, "role", "system");
                    try message.put(allocator, "content", .{ .array = content });
                    try messages.append(.{ .object = message });
                    try betas.add(allocator, "mid-conversation-system-2026-04-07");
                }
            },
            .user => {
                var content = std.json.Array.init(allocator);
                for (input[start..index]) |message| switch (message) {
                    .user => |user| {
                        for (user.content, 0..) |part, part_index| {
                            const is_last = part_index + 1 == user.content.len;
                            var cache = try cache_validator.get(
                                allocator,
                                switch (part) {
                                    .text => |value| value.provider_options,
                                    .file => |value| value.provider_options,
                                },
                                "user message part",
                                true,
                                warnings,
                            );
                            if (cache == null and is_last) cache = try cache_validator.get(
                                allocator,
                                user.provider_options,
                                "user message",
                                true,
                                warnings,
                            );
                            try content.append(try convertUserPart(
                                allocator,
                                part,
                                cache,
                                &betas,
                                diag,
                            ));
                        }
                    },
                    .tool => |tool_message| {
                        for (tool_message.content, 0..) |part, part_index| switch (part) {
                            .tool_approval_response => {},
                            .tool_result => |result| {
                                var cache = try cache_validator.get(
                                    allocator,
                                    result.provider_options,
                                    "tool result part",
                                    true,
                                    warnings,
                                );
                                if (cache == null) cache = try cache_validator.get(
                                    allocator,
                                    outputProviderOptions(result.output),
                                    "tool result output",
                                    true,
                                    warnings,
                                );
                                if (cache == null and part_index + 1 == tool_message.content.len) {
                                    cache = try cache_validator.get(
                                        allocator,
                                        tool_message.provider_options,
                                        "tool result message",
                                        true,
                                        warnings,
                                    );
                                }
                                try content.append(try convertToolResult(
                                    allocator,
                                    result,
                                    cache,
                                    &betas,
                                    warnings,
                                    diag,
                                ));
                            },
                        };
                    },
                    else => unreachable,
                };
                var message: std.json.ObjectMap = .empty;
                try utils.putString(&message, allocator, "role", "user");
                try message.put(allocator, "content", .{ .array = content });
                try messages.append(.{ .object = message });
            },
            .assistant => {
                var content = std.json.Array.init(allocator);
                for (input[start..index], 0..) |message, message_index| {
                    const assistant = message.assistant;
                    for (assistant.content, 0..) |part, part_index| {
                        const final_part = is_last_block and
                            message_index + 1 == index - start and
                            part_index + 1 == assistant.content.len;
                        switch (part) {
                            .text => |text| {
                                var block: std.json.ObjectMap = .empty;
                                const metadata_type = anthropicString(text.provider_options, "type");
                                if (metadata_type != null and std.mem.eql(u8, metadata_type.?, "compaction")) {
                                    try utils.putString(&block, allocator, "type", "compaction");
                                    try utils.putString(&block, allocator, "content", text.text);
                                } else {
                                    try utils.putString(&block, allocator, "type", "text");
                                    try utils.putString(
                                        &block,
                                        allocator,
                                        "text",
                                        if (final_part) std.mem.trimEnd(u8, text.text, " \t\r\n") else text.text,
                                    );
                                }
                                var cache = try cache_validator.get(
                                    allocator,
                                    text.provider_options,
                                    "assistant message part",
                                    true,
                                    warnings,
                                );
                                if (cache == null and part_index + 1 == assistant.content.len) {
                                    cache = try cache_validator.get(
                                        allocator,
                                        assistant.provider_options,
                                        "assistant message",
                                        true,
                                        warnings,
                                    );
                                }
                                if (cache) |value| try block.put(allocator, "cache_control", value);
                                try content.append(.{ .object = block });
                            },
                            .reasoning => |reasoning| {
                                if (!send_reasoning) {
                                    try warnings.append(allocator, .{ .other = .{
                                        .message = "sending reasoning content is disabled for this model",
                                    } });
                                    continue;
                                }
                                const signature = anthropicString(reasoning.provider_options, "signature");
                                const redacted = anthropicString(reasoning.provider_options, "redactedData");
                                if (signature == null and redacted == null) {
                                    try warnings.append(allocator, .{ .other = .{
                                        .message = "unsupported reasoning metadata",
                                    } });
                                    continue;
                                }
                                _ = try cache_validator.get(
                                    allocator,
                                    reasoning.provider_options,
                                    if (signature != null) "thinking block" else "redacted thinking block",
                                    false,
                                    warnings,
                                );
                                var block: std.json.ObjectMap = .empty;
                                if (signature) |value| {
                                    try utils.putString(&block, allocator, "type", "thinking");
                                    try utils.putString(&block, allocator, "thinking", reasoning.text);
                                    try utils.putString(&block, allocator, "signature", value);
                                } else {
                                    try utils.putString(&block, allocator, "type", "redacted_thinking");
                                    try utils.putString(&block, allocator, "data", redacted.?);
                                }
                                try content.append(.{ .object = block });
                            },
                            .tool_call => |tool_call| {
                                var cache = try cache_validator.get(
                                    allocator,
                                    tool_call.provider_options,
                                    "assistant message part",
                                    true,
                                    warnings,
                                );
                                if (cache == null and part_index + 1 == assistant.content.len) {
                                    cache = try cache_validator.get(
                                        allocator,
                                        assistant.provider_options,
                                        "assistant message",
                                        true,
                                        warnings,
                                    );
                                }
                                try content.append(try convertAssistantToolCall(
                                    allocator,
                                    tool_call,
                                    cache,
                                    tools,
                                    warnings,
                                ));
                            },
                            .tool_result => |tool_result| {
                                const converted = try convertAssistantToolResult(
                                    allocator,
                                    tool_result,
                                    tools,
                                    warnings,
                                );
                                if (converted) |value| try content.append(value);
                            },
                            else => {},
                        }
                    }
                }
                const reordered = try moveToolUseBlocksToEnd(allocator, content);
                var message: std.json.ObjectMap = .empty;
                try utils.putString(&message, allocator, "role", "assistant");
                try message.put(allocator, "content", reordered);
                try messages.append(.{ .object = message });
            },
        }
    }

    return .{
        .system = system,
        .messages = .{ .array = messages },
        .betas = betas,
    };
}

const Run = enum { system, user, assistant };

fn roleRun(message: provider.Message) Run {
    return switch (message) {
        .system => .system,
        .assistant => .assistant,
        .user, .tool => .user,
    };
}

fn convertUserPart(
    allocator: Allocator,
    part: provider.UserContentPart,
    cache: ?std.json.Value,
    betas: *utils.BetaSet,
    diag: ?*provider.Diagnostics,
) BuildError!std.json.Value {
    var block: std.json.ObjectMap = .empty;
    switch (part) {
        .text => |text| {
            try utils.putString(&block, allocator, "type", "text");
            try utils.putString(&block, allocator, "text", text.text);
        },
        .file => |file| {
            const file_options = anthropicObject(file.provider_options);
            const container_upload = if (file_options) |object|
                utils.optionalBool(object, "containerUpload") orelse false
            else
                false;
            switch (file.data) {
                .reference => |reference| {
                    const file_id = try resolveReference(allocator, reference.reference, diag);
                    try betas.add(allocator, "files-api-2025-04-14");
                    if (container_upload) {
                        try utils.putString(&block, allocator, "type", "container_upload");
                        try utils.putString(&block, allocator, "file_id", file_id);
                        return .{ .object = block };
                    }
                    if (std.mem.startsWith(u8, file.media_type, "image/")) {
                        try utils.putString(&block, allocator, "type", "image");
                    } else {
                        try utils.putString(&block, allocator, "type", "document");
                    }
                    var source: std.json.ObjectMap = .empty;
                    try utils.putString(&source, allocator, "type", "file");
                    try utils.putString(&source, allocator, "file_id", file_id);
                    try block.put(allocator, "source", .{ .object = source });
                },
                .text => |text| {
                    try utils.putString(&block, allocator, "type", "document");
                    var source: std.json.ObjectMap = .empty;
                    try utils.putString(&source, allocator, "type", "text");
                    try utils.putString(&source, allocator, "media_type", "text/plain");
                    try utils.putString(&source, allocator, "data", text.text);
                    try block.put(allocator, "source", .{ .object = source });
                    try addDocumentOptions(allocator, &block, file.filename, file_options);
                },
                .url => |url| {
                    const is_image = std.mem.startsWith(u8, file.media_type, "image/");
                    const is_pdf = std.mem.eql(u8, file.media_type, "application/pdf");
                    if (!is_image and !is_pdf and !std.mem.eql(u8, file.media_type, "text/plain")) {
                        return unsupported(diag, allocator, file.media_type);
                    }
                    if (is_pdf) try betas.add(allocator, "pdfs-2024-09-25");
                    try utils.putString(&block, allocator, "type", if (is_image) "image" else "document");
                    var source: std.json.ObjectMap = .empty;
                    try utils.putString(&source, allocator, "type", "url");
                    try utils.putString(&source, allocator, "url", url.url);
                    try block.put(allocator, "source", .{ .object = source });
                    if (!is_image) try addDocumentOptions(allocator, &block, file.filename, file_options);
                },
                .data => |data| {
                    const is_image = std.mem.startsWith(u8, file.media_type, "image/");
                    const is_pdf = std.mem.eql(u8, file.media_type, "application/pdf");
                    const is_text = std.mem.eql(u8, file.media_type, "text/plain");
                    if (!is_image and !is_pdf and !is_text) return unsupported(diag, allocator, file.media_type);
                    if (is_pdf) try betas.add(allocator, "pdfs-2024-09-25");
                    try utils.putString(&block, allocator, "type", if (is_image) "image" else "document");
                    var source: std.json.ObjectMap = .empty;
                    if (is_text) {
                        try utils.putString(&source, allocator, "type", "text");
                        try utils.putString(&source, allocator, "media_type", "text/plain");
                        const bytes = switch (data.data) {
                            .bytes => |value| value,
                            .base64 => |value| provider_utils.decodeBase64(allocator, value) catch
                                return unsupported(diag, allocator, "invalid base64 text"),
                        };
                        try utils.putString(&source, allocator, "data", bytes);
                    } else {
                        try utils.putString(&source, allocator, "type", "base64");
                        try utils.putString(&source, allocator, "media_type", file.media_type);
                        try utils.putString(&source, allocator, "data", try binaryBase64(allocator, data.data));
                    }
                    try block.put(allocator, "source", .{ .object = source });
                    if (!is_image) try addDocumentOptions(allocator, &block, file.filename, file_options);
                },
            }
        },
    }
    if (cache) |value| try block.put(allocator, "cache_control", value);
    return .{ .object = block };
}

fn addDocumentOptions(
    allocator: Allocator,
    block: *std.json.ObjectMap,
    filename: ?[]const u8,
    options: ?std.json.ObjectMap,
) Allocator.Error!void {
    if (options) |object| {
        if (utils.optionalString(object, "title") orelse filename) |title| try utils.putString(block, allocator, "title", title);
        if (utils.optionalString(object, "context")) |context| try utils.putString(block, allocator, "context", context);
        if (object.get("citations")) |citations| if (citations == .object and
            (utils.optionalBool(citations.object, "enabled") orelse false))
        {
            var enabled: std.json.ObjectMap = .empty;
            try enabled.put(allocator, "enabled", .{ .bool = true });
            try block.put(allocator, "citations", .{ .object = enabled });
        };
    } else if (filename) |title| {
        try utils.putString(block, allocator, "title", title);
    }
}

fn convertToolResult(
    allocator: Allocator,
    result: provider.ToolResultPart,
    cache: ?std.json.Value,
    betas: *utils.BetaSet,
    warnings: *std.ArrayList(provider.Warning),
    diag: ?*provider.Diagnostics,
) BuildError!std.json.Value {
    var block: std.json.ObjectMap = .empty;
    try utils.putString(&block, allocator, "type", "tool_result");
    try utils.putString(&block, allocator, "tool_use_id", result.tool_call_id);
    switch (result.output) {
        .text => |value| try utils.putString(&block, allocator, "content", value.value),
        .error_text => |value| {
            try utils.putString(&block, allocator, "content", value.value);
            try block.put(allocator, "is_error", .{ .bool = true });
        },
        .execution_denied => |value| try utils.putString(
            &block,
            allocator,
            "content",
            value.reason orelse "Tool call execution denied.",
        ),
        .json => |value| try utils.putString(
            &block,
            allocator,
            "content",
            try provider_utils.stringifyJsonValueAlloc(allocator, value.value),
        ),
        .error_json => |value| {
            try utils.putString(
                &block,
                allocator,
                "content",
                try provider_utils.stringifyJsonValueAlloc(allocator, value.value),
            );
            try block.put(allocator, "is_error", .{ .bool = true });
        },
        .content => |value| {
            var content = std.json.Array.init(allocator);
            for (value.value) |part| switch (part) {
                .text => |text| {
                    var item: std.json.ObjectMap = .empty;
                    try utils.putString(&item, allocator, "type", "text");
                    try utils.putString(&item, allocator, "text", text.text);
                    try content.append(.{ .object = item });
                },
                .file => |file| {
                    const user_part: provider.UserContentPart = .{ .file = .{
                        .filename = file.filename,
                        .data = file.data,
                        .media_type = file.media_type,
                        .provider_options = file.provider_options,
                    } };
                    try content.append(try convertUserPart(allocator, user_part, null, betas, diag));
                },
                .custom => try warnings.append(allocator, .{ .other = .{
                    .message = "unsupported custom tool content part",
                } }),
            };
            try block.put(allocator, "content", .{ .array = content });
        },
    }
    if (cache) |value| try block.put(allocator, "cache_control", value);
    return .{ .object = block };
}

fn convertAssistantToolCall(
    allocator: Allocator,
    tool_call: provider.ToolCallPart,
    cache: ?std.json.Value,
    tools: ?[]const provider.Tool,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!std.json.Value {
    var block: std.json.ObjectMap = .empty;
    if (tool_call.provider_executed orelse false) {
        const provider_name = toProviderToolName(tools, tool_call.tool_name);
        if (std.mem.eql(u8, provider_name, "web_search") or
            std.mem.eql(u8, provider_name, "web_fetch") or
            std.mem.eql(u8, provider_name, "code_execution") or
            std.mem.eql(u8, provider_name, "tool_search_tool_regex") or
            std.mem.eql(u8, provider_name, "tool_search_tool_bm25") or
            std.mem.eql(u8, provider_name, "advisor"))
        {
            try utils.putString(&block, allocator, "type", "server_tool_use");
            try utils.putString(&block, allocator, "id", tool_call.tool_call_id);
            try utils.putString(&block, allocator, "name", provider_name);
            try block.put(allocator, "input", try provider_utils.cloneJsonValue(allocator, tool_call.input));
        } else {
            try warnings.append(allocator, .{ .other = .{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "provider executed tool call for tool {s} is not supported",
                    .{tool_call.tool_name},
                ),
            } });
            try utils.putString(&block, allocator, "type", "fallback");
        }
    } else {
        try utils.putString(&block, allocator, "type", "tool_use");
        try utils.putString(&block, allocator, "id", tool_call.tool_call_id);
        try utils.putString(&block, allocator, "name", tool_call.tool_name);
        const input = if (tool_call.input == .object)
            try provider_utils.cloneJsonValue(allocator, tool_call.input)
        else blk: {
            var wrapped: std.json.ObjectMap = .empty;
            try wrapped.put(allocator, "rawInvalidInput", try provider_utils.cloneJsonValue(allocator, tool_call.input));
            break :blk std.json.Value{ .object = wrapped };
        };
        try block.put(allocator, "input", input);
        if (anthropicObject(tool_call.provider_options)) |metadata| {
            if (metadata.get("caller")) |caller| if (caller == .object) {
                var wire_caller: std.json.ObjectMap = .empty;
                if (utils.optionalString(caller.object, "type")) |caller_type| {
                    try utils.putString(&wire_caller, allocator, "type", caller_type);
                    if (utils.optionalString(caller.object, "toolId")) |tool_id| {
                        try utils.putString(&wire_caller, allocator, "tool_id", tool_id);
                    }
                    try block.put(allocator, "caller", .{ .object = wire_caller });
                }
            };
        }
    }
    if (cache) |value| try block.put(allocator, "cache_control", value);
    return .{ .object = block };
}

fn convertAssistantToolResult(
    allocator: Allocator,
    result: provider.ToolResultPart,
    tools: ?[]const provider.Tool,
    warnings: *std.ArrayList(provider.Warning),
) Allocator.Error!?std.json.Value {
    const provider_name = toProviderToolName(tools, result.tool_name);
    if (!std.mem.eql(u8, provider_name, "web_search")) {
        try warnings.append(allocator, .{ .other = .{
            .message = try std.fmt.allocPrint(
                allocator,
                "provider executed tool result for tool {s} is not supported",
                .{result.tool_name},
            ),
        } });
        return null;
    }
    if (result.output != .json and result.output != .error_json) return null;
    var block: std.json.ObjectMap = .empty;
    try utils.putString(&block, allocator, "type", "web_search_tool_result");
    try utils.putString(&block, allocator, "tool_use_id", result.tool_call_id);
    const value = switch (result.output) {
        .json => |item| item.value,
        .error_json => |item| item.value,
        else => unreachable,
    };
    try block.put(allocator, "content", try provider_utils.cloneJsonValue(allocator, value));
    return .{ .object = block };
}

fn moveToolUseBlocksToEnd(
    allocator: Allocator,
    source: std.json.Array,
) Allocator.Error!std.json.Value {
    var output = std.json.Array.init(allocator);
    var segment_start: usize = 0;
    for (source.items, 0..) |part, index| {
        const kind = if (part == .object) utils.optionalString(part.object, "type") else null;
        if (kind != null and (std.mem.eql(u8, kind.?, "thinking") or
            std.mem.eql(u8, kind.?, "redacted_thinking")))
        {
            try appendReorderedSegment(&output, source.items[segment_start..index]);
            try output.append(part);
            segment_start = index + 1;
        }
    }
    try appendReorderedSegment(&output, source.items[segment_start..]);
    return .{ .array = output };
}

fn appendReorderedSegment(output: *std.json.Array, segment: []const std.json.Value) Allocator.Error!void {
    for (segment) |part| if (!isToolUse(part)) try output.append(part);
    for (segment) |part| if (isToolUse(part)) try output.append(part);
}

fn isToolUse(value: std.json.Value) bool {
    if (value != .object) return false;
    const kind = utils.optionalString(value.object, "type") orelse return false;
    return std.mem.eql(u8, kind, "tool_use");
}

fn outputProviderOptions(output: provider.ToolResultOutput) ?provider.ProviderOptions {
    return switch (output) {
        .text => |value| value.provider_options,
        .json => |value| value.provider_options,
        .execution_denied => |value| value.provider_options,
        .error_text => |value| value.provider_options,
        .error_json => |value| value.provider_options,
        .content => |value| blk: {
            for (value.value) |part| switch (part) {
                .text => |item| if (item.provider_options) |options| break :blk options,
                .file => |item| if (item.provider_options) |options| break :blk options,
                .custom => |item| if (item.provider_options) |options| break :blk options,
            };
            break :blk null;
        },
    };
}

fn cacheControlValue(options: ?provider.ProviderOptions) ?std.json.Value {
    const object = anthropicObject(options) orelse return null;
    return object.get("cacheControl") orelse object.get("cache_control");
}

fn anthropicObject(options: ?provider.ProviderOptions) ?std.json.ObjectMap {
    const root = options orelse return null;
    if (root != .object) return null;
    const value = root.object.get("anthropic") orelse return null;
    return if (value == .object) value.object else null;
}

fn anthropicString(options: ?provider.ProviderOptions, key: []const u8) ?[]const u8 {
    const object = anthropicObject(options) orelse return null;
    return utils.optionalString(object, key);
}

fn resolveReference(
    allocator: Allocator,
    reference: provider.ProviderReference,
    diag: ?*provider.Diagnostics,
) BuildError![]const u8 {
    if (reference == .object) {
        if (reference.object.get("anthropic")) |value| if (value == .string) return value.string;
    }
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else allocator, .{
        .no_such_provider_reference = .{
            .message = "Provider reference does not contain an anthropic file id",
            .provider = "anthropic",
            .reference_json = "{}",
        },
    });
    return error.NoSuchProviderReferenceError;
}

fn binaryBase64(allocator: Allocator, data: provider.BinaryData) Allocator.Error![]const u8 {
    return switch (data) {
        .bytes => |bytes| provider_utils.encodeBase64(allocator, bytes),
        .base64 => |base64| allocator.dupe(u8, base64),
    };
}

pub fn toProviderToolName(tools: ?[]const provider.Tool, custom_name: []const u8) []const u8 {
    if (tools) |items| for (items) |tool| switch (tool) {
        .provider => |item| if (std.mem.eql(u8, item.name, custom_name)) return wireToolName(item.id),
        else => {},
    };
    return custom_name;
}

pub fn toCustomToolName(tools: ?[]const provider.Tool, provider_name: []const u8) []const u8 {
    if (tools) |items| for (items) |tool| switch (tool) {
        .provider => |item| if (std.mem.eql(u8, wireToolName(item.id), provider_name)) return item.name,
        else => {},
    };
    return provider_name;
}

fn wireToolName(id: []const u8) []const u8 {
    if (std.mem.indexOf(u8, id, "computer_") != null) return "computer";
    if (std.mem.indexOf(u8, id, "text_editor_20241022") != null or
        std.mem.indexOf(u8, id, "text_editor_20250124") != null) return "str_replace_editor";
    if (std.mem.indexOf(u8, id, "text_editor_") != null) return "str_replace_based_edit_tool";
    if (std.mem.indexOf(u8, id, "bash_") != null) return "bash";
    if (std.mem.indexOf(u8, id, "web_search_") != null) return "web_search";
    if (std.mem.indexOf(u8, id, "web_fetch_") != null) return "web_fetch";
    if (std.mem.indexOf(u8, id, "code_execution_") != null) return "code_execution";
    if (std.mem.indexOf(u8, id, "memory_") != null) return "memory";
    if (std.mem.indexOf(u8, id, "tool_search_regex_") != null) return "tool_search_tool_regex";
    if (std.mem.indexOf(u8, id, "tool_search_bm25_") != null) return "tool_search_tool_bm25";
    if (std.mem.indexOf(u8, id, "advisor_") != null) return "advisor";
    return id;
}

fn unsupported(diag: ?*provider.Diagnostics, allocator: Allocator, functionality: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |value| value.allocator else allocator, .{
        .unsupported_functionality = .{
            .message = "Anthropic prompt feature is unsupported",
            .functionality = functionality,
        },
    });
    return error.UnsupportedFunctionalityError;
}

fn parseValue(allocator: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

test "prompt conversion handles top-level and mid-conversation system runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const messages = [_]provider.Message{
        .{ .system = .{ .content = "initial" } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "hi" } }} } },
        .{ .assistant = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } },
        .{ .system = .{ .content = "switch tone" } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "go" } }} } },
    };
    var warnings: std.ArrayList(provider.Warning) = .empty;
    var validator: CacheControlValidator = .{};
    const result = try convert(
        allocator,
        &messages,
        true,
        null,
        &warnings,
        &validator,
        null,
    );
    try std.testing.expectEqualStrings("initial", result.system.?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("system", result.messages.array.items[2].object.get("role").?.string);
    try std.testing.expectEqualStrings("mid-conversation-system-2026-04-07", result.betas.order.items[0]);
}

test "prompt conversion trims final assistant text and round-trips signed thinking and tool_use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const reasoning_options = try parseValue(allocator, "{\"anthropic\":{\"signature\":\"sig-1\"}}");
    const input = try parseValue(allocator, "{\"city\":\"Paris\"}");
    const messages = [_]provider.Message{
        .{ .assistant = .{ .content = &.{
            .{ .reasoning = .{ .text = "Think", .provider_options = reasoning_options } },
            .{ .tool_call = .{
                .tool_call_id = "call-1",
                .tool_name = "weather",
                .input = input,
            } },
            .{ .text = .{ .text = "answer  \n" } },
        } } },
    };
    var warnings: std.ArrayList(provider.Warning) = .empty;
    var validator: CacheControlValidator = .{};
    const result = try convert(
        allocator,
        &messages,
        true,
        null,
        &warnings,
        &validator,
        null,
    );
    const content = result.messages.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("thinking", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("sig-1", content[0].object.get("signature").?.string);
    try std.testing.expectEqualStrings("answer", content[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("tool_use", content[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("Paris", content[2].object.get("input").?.object.get("city").?.string);
}

test "prompt cache control keeps four breakpoints and drops the fifth" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const cache = try parseValue(allocator, "{\"anthropic\":{\"cacheControl\":{\"type\":\"ephemeral\"}}}");
    const messages = [_]provider.Message{
        .{ .system = .{ .content = "one", .provider_options = cache } },
        .{ .system = .{ .content = "two", .provider_options = cache } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "three", .provider_options = cache } }} } },
        .{ .assistant = .{ .content = &.{.{ .text = .{ .text = "four", .provider_options = cache } }} } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "five", .provider_options = cache } }} } },
    };
    var warnings: std.ArrayList(provider.Warning) = .empty;
    var validator: CacheControlValidator = .{};
    const result = try convert(
        allocator,
        &messages,
        true,
        null,
        &warnings,
        &validator,
        null,
    );
    try std.testing.expectEqual(5, validator.breakpoints);
    try std.testing.expectEqual(1, warnings.items.len);
    try std.testing.expect(result.messages.array.items[2].object.get("content").?.array.items[0].object.get("cache_control") == null);
}
