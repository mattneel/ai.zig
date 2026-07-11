const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const capabilities = @import("capabilities.zig");
const options_api = @import("options.zig");

const Allocator = std.mem.Allocator;
pub const ConvertError = provider.Error || Allocator.Error;

pub const ConvertedMessages = struct {
    value: std.json.Value,
    warnings: []const provider.Warning,
};

pub fn convertMessages(
    arena: Allocator,
    prompt: provider.Prompt,
    mode: capabilities.SystemMessageMode,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) ConvertError!ConvertedMessages {
    var messages = std.json.Array.init(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);

    for (prompt) |prompt_message| switch (prompt_message) {
        .system => |system| switch (mode) {
            .remove => try warnings.append(arena, .{ .other = .{ .message = "system messages are removed for this model" } }),
            .system, .developer => {
                var object: std.json.ObjectMap = .empty;
                try putString(&object, arena, "role", if (mode == .developer) "developer" else "system");
                if (promptCacheBreakpoint(system.provider_options, namespace)) |breakpoint| {
                    var content = std.json.Array.init(arena);
                    var part: std.json.ObjectMap = .empty;
                    try putString(&part, arena, "type", "text");
                    try putString(&part, arena, "text", system.content);
                    try part.put(arena, "prompt_cache_breakpoint", try provider_utils.cloneJsonValue(arena, breakpoint));
                    try content.append(.{ .object = part });
                    try object.put(arena, "content", .{ .array = content });
                } else {
                    try putString(&object, arena, "content", system.content);
                }
                try messages.append(.{ .object = object });
            },
        },
        .user => |user| {
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "role", "user");
            if (user.content.len == 1 and user.content[0] == .text and
                promptCacheBreakpoint(user.content[0].text.provider_options, namespace) == null)
            {
                try putString(&object, arena, "content", user.content[0].text.text);
            } else {
                var content = std.json.Array.init(arena);
                for (user.content, 0..) |part, index| switch (part) {
                    .text => |text| {
                        var item: std.json.ObjectMap = .empty;
                        try putString(&item, arena, "type", "text");
                        try putString(&item, arena, "text", text.text);
                        try addPromptCacheBreakpoint(arena, &item, text.provider_options, namespace);
                        try content.append(.{ .object = item });
                    },
                    .file => |file| try content.append(try convertUserFile(arena, file, index, namespace, diag)),
                };
                try object.put(arena, "content", .{ .array = content });
            }
            try messages.append(.{ .object = object });
        },
        .assistant => |assistant| {
            var object: std.json.ObjectMap = .empty;
            try putString(&object, arena, "role", "assistant");
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(arena);
            var text_parts = std.json.Array.init(arena);
            var has_breakpoint = false;
            var tool_calls = std.json.Array.init(arena);

            for (assistant.content) |part| switch (part) {
                .text => |value| {
                    try text.appendSlice(arena, value.text);
                    var text_part: std.json.ObjectMap = .empty;
                    try putString(&text_part, arena, "type", "text");
                    try putString(&text_part, arena, "text", value.text);
                    if (promptCacheBreakpoint(value.provider_options, namespace)) |breakpoint| {
                        has_breakpoint = true;
                        try text_part.put(arena, "prompt_cache_breakpoint", try provider_utils.cloneJsonValue(arena, breakpoint));
                    }
                    try text_parts.append(.{ .object = text_part });
                },
                .tool_call => |tool_call| {
                    var call: std.json.ObjectMap = .empty;
                    try putString(&call, arena, "id", tool_call.tool_call_id);
                    try putString(&call, arena, "type", "function");
                    var function: std.json.ObjectMap = .empty;
                    try putString(&function, arena, "name", tool_call.tool_name);
                    try putString(&function, arena, "arguments", try provider_utils.stringifyJsonValueAlloc(arena, tool_call.input));
                    try call.put(arena, "function", .{ .object = function });
                    try tool_calls.append(.{ .object = call });
                },
                .file, .custom, .reasoning, .reasoning_file, .tool_result => try warnings.append(arena, .{ .unsupported = .{
                    .feature = try std.fmt.allocPrint(arena, "assistant content type: {s}", .{@tagName(part)}),
                } }),
            };

            if (has_breakpoint) {
                try object.put(arena, "content", .{ .array = text_parts });
            } else if (tool_calls.items.len != 0 and text.items.len == 0) {
                try object.put(arena, "content", .null);
            } else {
                try putString(&object, arena, "content", text.items);
            }
            if (tool_calls.items.len != 0) try object.put(arena, "tool_calls", .{ .array = tool_calls });
            try messages.append(.{ .object = object });
        },
        .tool => |tool_message| {
            for (tool_message.content) |part| switch (part) {
                .tool_approval_response => {},
                .tool_result => |tool_result| {
                    var object: std.json.ObjectMap = .empty;
                    try putString(&object, arena, "role", "tool");
                    try putString(&object, arena, "tool_call_id", tool_result.tool_call_id);
                    const content_value = try toolResultText(arena, tool_result.output);
                    const breakpoint = toolResultPromptCacheBreakpoint(tool_result.output, namespace) orelse
                        promptCacheBreakpoint(tool_result.provider_options, namespace);
                    if (breakpoint) |value| {
                        var content = std.json.Array.init(arena);
                        var text_part: std.json.ObjectMap = .empty;
                        try putString(&text_part, arena, "type", "text");
                        try putString(&text_part, arena, "text", content_value);
                        try text_part.put(arena, "prompt_cache_breakpoint", try provider_utils.cloneJsonValue(arena, value));
                        try content.append(.{ .object = text_part });
                        try object.put(arena, "content", .{ .array = content });
                    } else {
                        try putString(&object, arena, "content", content_value);
                    }
                    try messages.append(.{ .object = object });
                },
            };
        },
    };

    return .{
        .value = .{ .array = messages },
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn convertUserFile(
    arena: Allocator,
    file: provider.FilePart,
    index: usize,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) ConvertError!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    if (file.data == .reference) {
        try putString(&object, arena, "type", "file");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "file_id", try resolveReference(arena, file.data.reference.reference, namespace, diag));
        try object.put(arena, "file", .{ .object = item });
        try addPromptCacheBreakpoint(arena, &object, file.provider_options, namespace);
        return .{ .object = object };
    }
    if (file.data == .text) return unsupported(arena, diag, "text file parts");

    const top_level = provider_utils.getTopLevelMediaType(file.media_type);
    if (std.mem.eql(u8, top_level, "image")) {
        try putString(&object, arena, "type", "image_url");
        var image: std.json.ObjectMap = .empty;
        switch (file.data) {
            .url => |value| try putString(&image, arena, "url", value.url),
            .data => |value| {
                const encoded = try binaryToBase64(arena, value.data);
                const media_type = try resolvedInlineMediaType(arena, file.media_type, value.data, diag);
                try putString(&image, arena, "url", try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ media_type, encoded }));
            },
            .reference, .text => unreachable,
        }
        if (partStringOption(file.provider_options, namespace, "imageDetail")) |detail| {
            try putString(&image, arena, "detail", detail);
        }
        try object.put(arena, "image_url", .{ .object = image });
    } else if (std.mem.eql(u8, top_level, "audio")) {
        const format = if (std.mem.eql(u8, file.media_type, "audio/wav"))
            "wav"
        else if (std.mem.eql(u8, file.media_type, "audio/mp3") or std.mem.eql(u8, file.media_type, "audio/mpeg"))
            "mp3"
        else
            return unsupported(arena, diag, "audio content media type");
        const encoded = switch (file.data) {
            .data => |value| try binaryToBase64(arena, value.data),
            else => return unsupported(arena, diag, "audio file parts with URLs"),
        };
        try putString(&object, arena, "type", "input_audio");
        var input_audio: std.json.ObjectMap = .empty;
        try putString(&input_audio, arena, "data", encoded);
        try putString(&input_audio, arena, "format", format);
        try object.put(arena, "input_audio", .{ .object = input_audio });
    } else if (std.mem.eql(u8, file.media_type, "application/pdf")) {
        const encoded = switch (file.data) {
            .data => |value| try binaryToBase64(arena, value.data),
            else => return unsupported(arena, diag, "PDF file parts with URLs"),
        };
        try putString(&object, arena, "type", "file");
        var item: std.json.ObjectMap = .empty;
        const filename = file.filename orelse try std.fmt.allocPrint(arena, "part-{d}.pdf", .{index});
        try putString(&item, arena, "filename", filename);
        try putString(&item, arena, "file_data", try std.fmt.allocPrint(arena, "data:application/pdf;base64,{s}", .{encoded}));
        try object.put(arena, "file", .{ .object = item });
    } else {
        return unsupported(arena, diag, "file part media type");
    }
    try addPromptCacheBreakpoint(arena, &object, file.provider_options, namespace);
    return .{ .object = object };
}

fn resolvedInlineMediaType(
    arena: Allocator,
    media_type: []const u8,
    data: provider.BinaryData,
    diag: ?*provider.Diagnostics,
) ConvertError![]const u8 {
    if (provider_utils.isFullMediaType(media_type)) return media_type;
    const detected = provider_utils.detectMediaType(arena, switch (data) {
        .bytes => |bytes| .{ .bytes = bytes },
        .base64 => |base64| .{ .base64 = base64 },
    }, provider_utils.getTopLevelMediaType(media_type)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return detected orelse unsupported(arena, diag, "file part media type could not be resolved");
}

fn resolveReference(
    arena: Allocator,
    reference: provider.ProviderReference,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) ConvertError![]const u8 {
    if (reference == .object) {
        if (reference.object.get(namespace)) |value| if (value == .string) return value.string;
        if (!std.mem.eql(u8, namespace, "openai")) {
            if (reference.object.get("openai")) |value| if (value == .string) return value.string;
        }
    }
    const reference_json = try provider_utils.stringifyJsonValueAlloc(arena, reference);
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .no_such_provider_reference = .{
            .message = "No OpenAI provider reference was found",
            .provider = namespace,
            .reference_json = reference_json,
        },
    });
    return error.NoSuchProviderReferenceError;
}

fn toolResultProviderOptions(output: provider.ToolResultOutput) ?provider.ProviderOptions {
    return switch (output) {
        .text => |value| value.provider_options,
        .json => |value| value.provider_options,
        .execution_denied => |value| value.provider_options,
        .error_text => |value| value.provider_options,
        .error_json => |value| value.provider_options,
        .content => null,
    };
}

fn toolResultPromptCacheBreakpoint(
    output: provider.ToolResultOutput,
    namespace: []const u8,
) ?std.json.Value {
    if (output == .content) {
        for (output.content.value) |part| {
            const part_options = switch (part) {
                .text => |value| value.provider_options,
                .file => |value| value.provider_options,
                .custom => |value| value.provider_options,
            };
            if (promptCacheBreakpoint(part_options, namespace)) |breakpoint| return breakpoint;
        }
        return null;
    }
    return promptCacheBreakpoint(toolResultProviderOptions(output), namespace);
}

fn toolResultText(arena: Allocator, output: provider.ToolResultOutput) Allocator.Error![]const u8 {
    return switch (output) {
        .text => |value| arena.dupe(u8, value.value),
        .error_text => |value| arena.dupe(u8, value.value),
        .execution_denied => |value| arena.dupe(u8, value.reason orelse "Tool call execution denied."),
        .json => |value| provider_utils.stringifyJsonValueAlloc(arena, value.value),
        .error_json => |value| provider_utils.stringifyJsonValueAlloc(arena, value.value),
        .content => |value| provider.wire.stringifyAlloc(arena, value.value) catch return error.OutOfMemory,
    };
}

fn binaryToBase64(arena: Allocator, data: provider.BinaryData) Allocator.Error![]const u8 {
    return switch (data) {
        .bytes => |bytes| provider_utils.encodeBase64(arena, bytes),
        .base64 => |base64| arena.dupe(u8, base64),
    };
}

fn promptCacheBreakpoint(provider_options: ?provider.ProviderOptions, namespace: []const u8) ?std.json.Value {
    const options = options_api.namespaceObject(provider_options, namespace) orelse return null;
    const value = options.get("promptCacheBreakpoint") orelse return null;
    return if (value == .object) value else null;
}

fn partStringOption(provider_options: ?provider.ProviderOptions, namespace: []const u8, name: []const u8) ?[]const u8 {
    const options = options_api.namespaceObject(provider_options, namespace) orelse return null;
    const value = options.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn addPromptCacheBreakpoint(
    arena: Allocator,
    object: *std.json.ObjectMap,
    provider_options: ?provider.ProviderOptions,
    namespace: []const u8,
) Allocator.Error!void {
    if (promptCacheBreakpoint(provider_options, namespace)) |breakpoint| {
        try object.put(arena, "prompt_cache_breakpoint", try provider_utils.cloneJsonValue(arena, breakpoint));
    }
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn unsupported(arena: Allocator, diag: ?*provider.Diagnostics, functionality: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .unsupported_functionality = .{
            .message = "OpenAI Chat Completions prompt feature is unsupported",
            .functionality = functionality,
        },
    });
    return error.UnsupportedFunctionalityError;
}
