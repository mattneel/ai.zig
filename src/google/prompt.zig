const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;
pub const ConvertError = provider.Error || Allocator.Error;

pub const Converted = struct {
    contents: std.json.Value,
    system_instruction: ?std.json.Value,
    warnings: []const provider.Warning,
};

pub fn convert(
    arena: Allocator,
    prompt: provider.Prompt,
    model_id: []const u8,
    diag: ?*provider.Diagnostics,
) ConvertError!Converted {
    const is_gemma = startsWithIgnoreCase(model_id, "gemma-");
    const is_gemini3 = isGemini3(model_id);
    var system_parts = std.json.Array.init(arena);
    var system_text: std.ArrayList(u8) = .empty;
    defer system_text.deinit(arena);
    var contents = std.json.Array.init(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var seen_non_system = false;
    var injected_gemma_system = false;

    for (prompt) |message| switch (message) {
        .system => |system| {
            if (seen_non_system) return unsupported(
                arena,
                diag,
                "system messages are only supported at the beginning of the conversation",
            );
            var part: std.json.ObjectMap = .empty;
            try putString(&part, arena, "text", system.content);
            try system_parts.append(.{ .object = part });
            if (system_text.items.len != 0) try system_text.appendSlice(arena, "\n\n");
            try system_text.appendSlice(arena, system.content);
        },
        .user => |user| {
            seen_non_system = true;
            var parts = std.json.Array.init(arena);
            if (is_gemma and !injected_gemma_system and system_text.items.len != 0) {
                var system_part: std.json.ObjectMap = .empty;
                try putString(&system_part, arena, "text", try std.fmt.allocPrint(arena, "{s}\n\n", .{system_text.items}));
                try parts.append(.{ .object = system_part });
                injected_gemma_system = true;
            }
            for (user.content) |part| switch (part) {
                .text => |text| {
                    var item: std.json.ObjectMap = .empty;
                    try putString(&item, arena, "text", text.text);
                    try parts.append(.{ .object = item });
                },
                .file => |file| try parts.append(try userFile(arena, file, diag)),
            };
            try contents.append(try content(arena, "user", parts));
        },
        .assistant => |assistant| {
            seen_non_system = true;
            var parts = std.json.Array.init(arena);
            for (assistant.content) |part| switch (part) {
                .text => |text| if (text.text.len != 0) {
                    var item: std.json.ObjectMap = .empty;
                    try putString(&item, arena, "text", text.text);
                    try addThoughtSignature(&item, arena, text.provider_options);
                    try parts.append(.{ .object = item });
                },
                .reasoning => |reasoning| if (reasoning.text.len != 0) {
                    var item: std.json.ObjectMap = .empty;
                    try putString(&item, arena, "text", reasoning.text);
                    try item.put(arena, "thought", .{ .bool = true });
                    try addThoughtSignature(&item, arena, reasoning.provider_options);
                    try parts.append(.{ .object = item });
                },
                .file => |file| try parts.append(try assistantInputFile(arena, file, diag)),
                .reasoning_file => |file| try parts.append(try assistantFile(arena, file.media_type, file.data, file.provider_options, true, diag)),
                .tool_call => |tool_call| {
                    var item: std.json.ObjectMap = .empty;
                    const server_id = googleOptionString(tool_call.provider_options, "serverToolCallId");
                    const server_type = googleOptionString(tool_call.provider_options, "serverToolType");
                    if (server_id != null and server_type != null) {
                        var call: std.json.ObjectMap = .empty;
                        try putString(&call, arena, "id", server_id.?);
                        try putString(&call, arena, "toolType", server_type.?);
                        try call.put(arena, "args", try provider_utils.cloneJsonValue(arena, tool_call.input));
                        try item.put(arena, "toolCall", .{ .object = call });
                    } else {
                        var call: std.json.ObjectMap = .empty;
                        try putString(&call, arena, "id", tool_call.tool_call_id);
                        try putString(&call, arena, "name", tool_call.tool_name);
                        try call.put(arena, "args", try provider_utils.cloneJsonValue(arena, tool_call.input));
                        try item.put(arena, "functionCall", .{ .object = call });
                    }
                    if (thoughtSignature(tool_call.provider_options)) |signature| {
                        try putString(&item, arena, "thoughtSignature", signature);
                    } else if (is_gemini3) {
                        try putString(&item, arena, "thoughtSignature", "skip_thought_signature_validator");
                        try warnings.append(arena, .{ .other = .{
                            .message = try std.fmt.allocPrint(
                                arena,
                                "Replayed a functionCall part for Gemini 3 without providerOptions.google.thoughtSignature (tool: `{s}`); injected skip_thought_signature_validator.",
                                .{tool_call.tool_name},
                            ),
                        } });
                    }
                    try parts.append(.{ .object = item });
                },
                .tool_result => |tool_result| {
                    const server_id = googleOptionString(tool_result.provider_options, "serverToolCallId");
                    const server_type = googleOptionString(tool_result.provider_options, "serverToolType");
                    if (server_id != null and server_type != null) {
                        var response: std.json.ObjectMap = .empty;
                        try putString(&response, arena, "id", server_id.?);
                        try putString(&response, arena, "toolType", server_type.?);
                        try response.put(arena, "response", try toolResultServerValue(arena, tool_result.output));
                        var item: std.json.ObjectMap = .empty;
                        try item.put(arena, "toolResponse", .{ .object = response });
                        try addThoughtSignature(&item, arena, tool_result.provider_options);
                        try parts.append(.{ .object = item });
                    } else {
                        try warnings.append(arena, .{ .unsupported = .{ .feature = "assistant content type: tool_result" } });
                    }
                },
                .custom => try warnings.append(arena, .{ .unsupported = .{
                    .feature = "assistant content type: custom",
                } }),
            };
            try contents.append(try content(arena, "model", parts));
        },
        .tool => |tool_message| {
            seen_non_system = true;
            var parts = std.json.Array.init(arena);
            for (tool_message.content) |part| switch (part) {
                .tool_approval_response => {},
                .tool_result => |tool_result| {
                    if (!try appendServerToolResultToLastModel(arena, &contents, tool_result)) {
                        try appendToolResult(arena, &parts, tool_result, is_gemini3, diag);
                    }
                },
            };
            try contents.append(try content(arena, "user", parts));
        },
    };

    const system_instruction: ?std.json.Value = if (!is_gemma and system_parts.items.len != 0) blk: {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "parts", .{ .array = system_parts });
        break :blk .{ .object = object };
    } else null;
    return .{
        .contents = .{ .array = contents },
        .system_instruction = system_instruction,
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn content(arena: Allocator, role: []const u8, parts: std.json.Array) Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try putString(&object, arena, "role", role);
    try object.put(arena, "parts", .{ .array = parts });
    return .{ .object = object };
}

fn userFile(arena: Allocator, file: provider.FilePart, diag: ?*provider.Diagnostics) ConvertError!std.json.Value {
    return switch (file.data) {
        .url => |value| fileData(arena, file.media_type, value.url),
        .reference => |value| fileData(arena, file.media_type, try providerReference(arena, value.reference, diag)),
        .text => |value| inlineData(
            arena,
            if (provider_utils.isFullMediaType(file.media_type)) file.media_type else "text/plain",
            try provider_utils.encodeBase64(arena, value.text),
            false,
            null,
        ),
        .data => |value| inlineData(
            arena,
            file.media_type,
            try binaryToBase64(arena, value.data),
            false,
            null,
        ),
    };
}

fn assistantFile(
    arena: Allocator,
    media_type: []const u8,
    data: provider.GeneratedFileData,
    provider_options: ?provider.ProviderOptions,
    thought: bool,
    diag: ?*provider.Diagnostics,
) ConvertError!std.json.Value {
    return switch (data) {
        .url => unsupported(arena, diag, "file data URLs in assistant messages"),
        .data => |value| inlineData(
            arena,
            media_type,
            try binaryToBase64(arena, value.data),
            thought,
            thoughtSignature(provider_options),
        ),
    };
}

fn assistantInputFile(
    arena: Allocator,
    file: provider.FilePart,
    diag: ?*provider.Diagnostics,
) ConvertError!std.json.Value {
    return switch (file.data) {
        .url => unsupported(arena, diag, "file data URLs in assistant messages"),
        .reference => |value| fileData(
            arena,
            file.media_type,
            try providerReference(arena, value.reference, diag),
        ),
        .text => |value| inlineData(
            arena,
            if (provider_utils.isFullMediaType(file.media_type)) file.media_type else "text/plain",
            try provider_utils.encodeBase64(arena, value.text),
            false,
            thoughtSignature(file.provider_options),
        ),
        .data => |value| inlineData(
            arena,
            file.media_type,
            try binaryToBase64(arena, value.data),
            false,
            thoughtSignature(file.provider_options),
        ),
    };
}

fn appendToolResult(
    arena: Allocator,
    parts: *std.json.Array,
    tool_result: provider.ToolResultPart,
    supports_function_response_parts: bool,
    diag: ?*provider.Diagnostics,
) ConvertError!void {
    var response_content: std.json.Value = .null;
    var response_parts = std.json.Array.init(arena);
    var legacy_parts = std.json.Array.init(arena);
    var has_response_parts = false;

    switch (tool_result.output) {
        .text => |value| response_content = .{ .string = try arena.dupe(u8, value.value) },
        .json => |value| response_content = try provider_utils.cloneJsonValue(arena, value.value),
        .error_text => |value| response_content = .{ .string = try arena.dupe(u8, value.value) },
        .error_json => |value| response_content = try provider_utils.cloneJsonValue(arena, value.value),
        .execution_denied => |value| response_content = .{ .string = try arena.dupe(u8, value.reason orelse "Tool call execution denied.") },
        .content => |value| {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(arena);
            for (value.value) |part| switch (part) {
                .text => |text_part| {
                    if (text.items.len != 0) try text.append(arena, '\n');
                    try text.appendSlice(arena, text_part.text);
                },
                .file => |file_part| switch (file_part.data) {
                    .data => |data| {
                        const inline_part = try inlineData(
                            arena,
                            file_part.media_type,
                            try binaryToBase64(arena, data.data),
                            false,
                            null,
                        );
                        if (supports_function_response_parts) {
                            try response_parts.append(inline_part);
                            has_response_parts = true;
                        } else {
                            try legacy_parts.append(inline_part);
                            var success: std.json.ObjectMap = .empty;
                            const kind = if (std.mem.startsWith(u8, file_part.media_type, "image/")) "image" else "file";
                            try putString(
                                &success,
                                arena,
                                "text",
                                try std.fmt.allocPrint(arena, "Tool executed successfully and returned this {s} as a response", .{kind}),
                            );
                            try legacy_parts.append(.{ .object = success });
                        }
                    },
                    .url, .reference, .text => try appendJsonText(arena, &text, part),
                },
                .custom => try appendJsonText(arena, &text, part),
            };
            response_content = .{ .string = try arena.dupe(u8, if (text.items.len != 0) text.items else "Tool executed successfully.") };
        },
    }

    var response: std.json.ObjectMap = .empty;
    try putString(&response, arena, "name", tool_result.tool_name);
    try response.put(arena, "content", response_content);
    var function_response: std.json.ObjectMap = .empty;
    try putString(&function_response, arena, "id", tool_result.tool_call_id);
    try putString(&function_response, arena, "name", tool_result.tool_name);
    try function_response.put(arena, "response", .{ .object = response });
    if (has_response_parts) try function_response.put(arena, "parts", .{ .array = response_parts });
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena, "functionResponse", .{ .object = function_response });
    try parts.append(.{ .object = wrapper });
    for (legacy_parts.items) |legacy| try parts.append(legacy);
    _ = diag;
}

fn appendJsonText(arena: Allocator, text: *std.ArrayList(u8), value: anytype) Allocator.Error!void {
    if (text.items.len != 0) try text.append(arena, '\n');
    const json = provider.wire.stringifyAlloc(arena, value) catch return error.OutOfMemory;
    try text.appendSlice(arena, json);
}

fn fileData(arena: Allocator, media_type: []const u8, uri: []const u8) Allocator.Error!std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try putString(&data, arena, "mimeType", media_type);
    try putString(&data, arena, "fileUri", uri);
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "fileData", .{ .object = data });
    return .{ .object = object };
}

fn inlineData(
    arena: Allocator,
    media_type: []const u8,
    data_value: []const u8,
    thought: bool,
    signature: ?[]const u8,
) Allocator.Error!std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try putString(&data, arena, "mimeType", media_type);
    try putString(&data, arena, "data", data_value);
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "inlineData", .{ .object = data });
    if (thought) try object.put(arena, "thought", .{ .bool = true });
    if (signature) |value| try putString(&object, arena, "thoughtSignature", value);
    return .{ .object = object };
}

fn providerReference(arena: Allocator, reference: provider.ProviderReference, diag: ?*provider.Diagnostics) ConvertError![]const u8 {
    if (reference == .object) {
        if (reference.object.get("google")) |value| if (value == .string) return arena.dupe(u8, value.string);
    }
    const reference_json = try provider_utils.stringifyJsonValueAlloc(arena, reference);
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{ .no_such_provider_reference = .{
        .message = "No Google provider reference was found",
        .provider = "google",
        .reference_json = reference_json,
    } });
    return error.NoSuchProviderReferenceError;
}

fn addThoughtSignature(object: *std.json.ObjectMap, arena: Allocator, provider_options: ?provider.ProviderOptions) Allocator.Error!void {
    if (thoughtSignature(provider_options)) |value| try putString(object, arena, "thoughtSignature", value);
}

fn thoughtSignature(provider_options: ?provider.ProviderOptions) ?[]const u8 {
    return googleOptionString(provider_options, "thoughtSignature");
}

fn googleOptionString(provider_options: ?provider.ProviderOptions, name: []const u8) ?[]const u8 {
    const root = provider_options orelse return null;
    if (root != .object) return null;
    const google = root.object.get("google") orelse return null;
    if (google != .object) return null;
    const value = google.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn toolResultServerValue(arena: Allocator, output: provider.ToolResultOutput) Allocator.Error!std.json.Value {
    return switch (output) {
        .json => |value| provider_utils.cloneJsonValue(arena, value.value),
        .error_json => |value| provider_utils.cloneJsonValue(arena, value.value),
        else => .{ .object = .empty },
    };
}

fn appendServerToolResultToLastModel(
    arena: Allocator,
    contents: *std.json.Array,
    tool_result: provider.ToolResultPart,
) Allocator.Error!bool {
    const server_id = googleOptionString(tool_result.provider_options, "serverToolCallId") orelse return false;
    const server_type = googleOptionString(tool_result.provider_options, "serverToolType") orelse return false;
    if (contents.items.len == 0) return false;
    const last = &contents.items[contents.items.len - 1];
    if (last.* != .object or !std.mem.eql(u8, optionalJsonString(last.object.get("role")) orelse "", "model")) return false;
    const parts = last.object.getPtr("parts") orelse return false;
    if (parts.* != .array) return false;
    var response: std.json.ObjectMap = .empty;
    try putString(&response, arena, "id", server_id);
    try putString(&response, arena, "toolType", server_type);
    try response.put(arena, "response", try toolResultServerValue(arena, tool_result.output));
    var item: std.json.ObjectMap = .empty;
    try item.put(arena, "toolResponse", .{ .object = response });
    try addThoughtSignature(&item, arena, tool_result.provider_options);
    try parts.array.append(.{ .object = item });
    return true;
}

fn optionalJsonString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return if (item == .string) item.string else null;
}

fn binaryToBase64(arena: Allocator, data: provider.BinaryData) Allocator.Error![]const u8 {
    return switch (data) {
        .bytes => |bytes| provider_utils.encodeBase64(arena, bytes),
        .base64 => |base64| arena.dupe(u8, base64),
    };
}

fn isGemini3(model_id: []const u8) bool {
    return std.ascii.eqlIgnoreCase(model_id, "gemini-3") or
        startsWithIgnoreCase(model_id, "gemini-3.") or
        startsWithIgnoreCase(model_id, "gemini-3-");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn unsupported(arena: Allocator, diag: ?*provider.Diagnostics, functionality: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .unsupported_functionality = .{
            .message = "Google Gemini prompt feature is unsupported",
            .functionality = functionality,
        },
    });
    return error.UnsupportedFunctionalityError;
}

test "Google prompt maps leading system instructions and function call responses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"city\":\"Paris\"}", .{});
    const output = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"weather\":\"sunny\"}", .{});
    const messages = [_]provider.Message{
        .{ .system = .{ .content = "be concise" } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "weather?" } }} } },
        .{ .assistant = .{ .content = &.{.{ .tool_call = .{ .tool_call_id = "call-1", .tool_name = "weather", .input = input } }} } },
        .{ .tool = .{ .content = &.{.{ .tool_result = .{ .tool_call_id = "call-1", .tool_name = "weather", .output = .{ .json = .{ .value = output } } } }} } },
    };
    const converted = try convert(arena, &messages, "gemini-2.5-flash", null);
    try std.testing.expectEqualStrings("be concise", converted.system_instruction.?.object.get("parts").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("model", converted.contents.array.items[1].object.get("role").?.string);
    const function_call = converted.contents.array.items[1].object.get("parts").?.array.items[0].object.get("functionCall").?.object;
    try std.testing.expectEqualStrings("weather", function_call.get("name").?.string);
    const function_response = converted.contents.array.items[2].object.get("parts").?.array.items[0].object.get("functionResponse").?.object;
    try std.testing.expectEqualStrings("call-1", function_response.get("id").?.string);
}

test "Google prompt carries thought signatures and injects Gemini 3 replay sentinel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const metadata = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"google\":{\"thoughtSignature\":\"signed\"}}", .{});
    const messages = [_]provider.Message{.{ .assistant = .{ .content = &.{
        .{ .text = .{ .text = "answer", .provider_options = metadata } },
        .{ .tool_call = .{ .tool_call_id = "call-2", .tool_name = "lookup", .input = empty } },
    } } }};
    const converted = try convert(arena, &messages, "gemini-3-pro-preview", null);
    const parts = converted.contents.array.items[0].object.get("parts").?.array.items;
    try std.testing.expectEqualStrings("signed", parts[0].object.get("thoughtSignature").?.string);
    try std.testing.expectEqualStrings("skip_thought_signature_validator", parts[1].object.get("thoughtSignature").?.string);
    try std.testing.expectEqual(1, converted.warnings.len);
}

test "Google prompt rejects system messages after conversation content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const messages = [_]provider.Message{
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } },
        .{ .system = .{ .content = "late" } },
    };
    try std.testing.expectError(error.UnsupportedFunctionalityError, convert(arena_state.allocator(), &messages, "gemini-2.5-flash", null));
}

test "Google prompt prepends Gemma system text to the first user content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const messages = [_]provider.Message{
        .{ .system = .{ .content = "system" } },
        .{ .user = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } },
    };
    const converted = try convert(arena_state.allocator(), &messages, "gemma-3-12b-it", null);
    try std.testing.expect(converted.system_instruction == null);
    const parts = converted.contents.array.items[0].object.get("parts").?.array.items;
    try std.testing.expectEqualStrings("system\n\n", parts[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("hello", parts[1].object.get("text").?.string);
}
