//! UI message validation and lowering to application `ModelMessage`s.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const message = @import("../message.zig");
const prompt = @import("../prompt.zig");
const tool_api = @import("../tool.zig");
const ui = @import("ui_messages.zig");
const process = @import("process_ui_stream.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const ConvertDataPart = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        arena: Allocator,
        part: ui.DataUIPart,
    ) anyerror!?message.UserContentPart,

    pub fn call(self: ConvertDataPart, arena: Allocator, part: ui.DataUIPart) anyerror!?message.UserContentPart {
        return self.call_fn(self.ctx, arena, part);
    }
};

pub const ConvertOptions = struct {
    tools: tool_api.ToolSet = &.{},
    ignore_incomplete_tool_calls: bool = false,
    convert_data_part: ?ConvertDataPart = null,
    diag: ?*provider.Diagnostics = null,
};

pub fn convertToModelMessages(
    arena: Allocator,
    messages_in: []const ui.UIMessage,
    options: ConvertOptions,
) anyerror![]const message.ModelMessage {
    var output: std.ArrayList(message.ModelMessage) = .empty;
    defer output.deinit(arena);

    for (messages_in) |ui_message| switch (ui_message.role) {
        .system => try convertSystem(arena, &output, ui_message),
        .user => try convertUser(arena, &output, ui_message, options),
        .assistant => try convertAssistant(arena, &output, ui_message, options),
    };
    return output.toOwnedSlice(arena);
}

fn convertSystem(
    arena: Allocator,
    output: *std.ArrayList(message.ModelMessage),
    ui_message: ui.UIMessage,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(arena);
    var provider_options: ?JsonValue = null;
    for (ui_message.parts) |part| switch (part) {
        .text => |value| {
            try text.appendSlice(arena, value.text);
            if (value.provider_metadata) |metadata| provider_options = try mergeObjects(arena, provider_options, metadata);
        },
        else => {},
    };
    try output.append(arena, .{ .system = .{
        .content = try text.toOwnedSlice(arena),
        .provider_options = provider_options,
    } });
}

fn convertUser(
    arena: Allocator,
    output: *std.ArrayList(message.ModelMessage),
    ui_message: ui.UIMessage,
    options: ConvertOptions,
) !void {
    var content: std.ArrayList(message.UserContentPart) = .empty;
    defer content.deinit(arena);
    for (ui_message.parts) |part| switch (part) {
        .text => |value| try content.append(arena, .{ .text = .{
            .text = try arena.dupe(u8, value.text),
            .provider_options = try cloneOptionalValue(arena, value.provider_metadata),
        } }),
        .file => |value| try content.append(arena, .{ .file = try modelFilePart(arena, value) }),
        .data => |value| if (options.convert_data_part) |converter| {
            if (try converter.call(arena, value)) |converted| try content.append(arena, converted);
        },
        else => {},
    };
    try output.append(arena, .{ .user = .{
        .content = .{ .parts = try content.toOwnedSlice(arena) },
    } });
}

fn convertAssistant(
    arena: Allocator,
    output: *std.ArrayList(message.ModelMessage),
    ui_message: ui.UIMessage,
    options: ConvertOptions,
) !void {
    var block: std.ArrayList(ui.UIMessagePart) = .empty;
    defer block.deinit(arena);

    for (ui_message.parts) |part| switch (part) {
        .step_start => {
            try processBlock(arena, output, block.items, options);
            block.clearRetainingCapacity();
        },
        .tool, .dynamic_tool => |tool| {
            if (options.ignore_incomplete_tool_calls and switch (tool.state) {
                .input_streaming, .input_available => true,
                else => false,
            }) continue;
            try block.append(arena, part);
        },
        else => try block.append(arena, part),
    };
    try processBlock(arena, output, block.items, options);
}

fn processBlock(
    arena: Allocator,
    output: *std.ArrayList(message.ModelMessage),
    block: []const ui.UIMessagePart,
    options: ConvertOptions,
) !void {
    if (block.len == 0) return;
    var assistant_content: std.ArrayList(message.AssistantContentPart) = .empty;
    defer assistant_content.deinit(arena);

    for (block) |part| switch (part) {
        .text => |value| try assistant_content.append(arena, .{ .text = .{
            .text = try arena.dupe(u8, value.text),
            .provider_options = try cloneOptionalValue(arena, value.provider_metadata),
        } }),
        .custom => |value| try assistant_content.append(arena, .{ .custom = .{
            .kind = try arena.dupe(u8, value.kind),
            .provider_options = try cloneOptionalValue(arena, value.provider_metadata),
        } }),
        .file => |value| try assistant_content.append(arena, .{ .file = try modelFilePart(arena, value) }),
        .reasoning => |value| try assistant_content.append(arena, .{ .reasoning = .{
            .text = try arena.dupe(u8, value.text),
            .provider_options = try cloneOptionalValue(arena, value.provider_metadata),
        } }),
        .reasoning_file => |value| try assistant_content.append(arena, .{ .reasoning_file = .{
            .data = .{ .url = try arena.dupe(u8, value.url) },
            .media_type = try arena.dupe(u8, value.media_type),
            .provider_options = try cloneOptionalValue(arena, value.provider_metadata),
        } }),
        .tool => |tool| try appendToolAssistantContent(arena, &assistant_content, tool, options),
        .dynamic_tool => |tool| try appendToolAssistantContent(arena, &assistant_content, tool, options),
        .data => |value| if (options.convert_data_part) |converter| {
            if (try converter.call(arena, value)) |converted| switch (converted) {
                .text => |text| try assistant_content.append(arena, .{ .text = text }),
                .file => |file| try assistant_content.append(arena, .{ .file = file }),
                .image => {},
            };
        },
        .source_url, .source_document, .step_start => {},
    };

    if (assistant_content.items.len != 0) {
        try output.append(arena, .{ .assistant = .{
            .content = .{ .parts = try assistant_content.toOwnedSlice(arena) },
        } });
    }

    var tool_content: std.ArrayList(message.ToolContentPart) = .empty;
    defer tool_content.deinit(arena);
    for (block) |part| {
        const tool = switch (part) {
            .tool => |value| value,
            .dynamic_tool => |value| value,
            else => continue,
        };
        const approval = toolApprovalResponse(tool.state);
        if (tool.provider_executed == true and approval == null) continue;

        if (approval) |response| {
            try tool_content.append(arena, .{ .tool_approval_response = .{
                .approval_id = try arena.dupe(u8, response.id),
                .approved = response.approved,
                .reason = try cloneOptionalString(arena, response.reason),
                .provider_executed = tool.provider_executed,
            } });
            if (!response.approved and tool.state == .approval_responded) {
                try tool_content.append(arena, .{ .tool_result = .{
                    .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
                    .tool_name = try arena.dupe(u8, tool.name),
                    .output = .{ .execution_denied = .{
                        .reason = try cloneOptionalString(arena, response.reason),
                    } },
                    .provider_options = try cloneOptionalValue(arena, stateCallMetadata(tool.state)),
                } });
            }
        }

        if (tool.provider_executed == true) continue;
        switch (tool.state) {
            .output_available => |state| try tool_content.append(arena, .{ .tool_result = .{
                .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
                .tool_name = try arena.dupe(u8, tool.name),
                .output = try prompt.createToolModelOutput(
                    arena,
                    tool.tool_call_id,
                    state.input,
                    state.output,
                    findTool(options.tools, tool.name),
                    .none,
                ),
                .provider_options = try cloneOptionalValue(arena, state.call_provider_metadata),
            } }),
            .output_error => |state| try tool_content.append(arena, .{ .tool_result = .{
                .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
                .tool_name = try arena.dupe(u8, tool.name),
                .output = try prompt.createToolModelOutput(
                    arena,
                    tool.tool_call_id,
                    state.input orelse state.raw_input orelse .null,
                    .{ .string = state.error_text },
                    findTool(options.tools, tool.name),
                    .text,
                ),
                .provider_options = try cloneOptionalValue(arena, state.call_provider_metadata),
            } }),
            .output_denied => |state| try tool_content.append(arena, .{ .tool_result = .{
                .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
                .tool_name = try arena.dupe(u8, tool.name),
                .output = .{ .error_text = .{
                    .value = try arena.dupe(u8, state.approval.reason orelse "Tool call execution denied."),
                } },
                .provider_options = try cloneOptionalValue(arena, state.call_provider_metadata),
            } }),
            else => {},
        }
    }

    if (tool_content.items.len != 0) {
        try output.append(arena, .{ .tool = .{
            .content = try tool_content.toOwnedSlice(arena),
        } });
    }
}

fn appendToolAssistantContent(
    arena: Allocator,
    content: *std.ArrayList(message.AssistantContentPart),
    tool: ui.ToolUIPart,
    options: ConvertOptions,
) !void {
    if (tool.state == .input_streaming) return;
    const input = switch (tool.state) {
        .output_error => |state| state.input orelse state.raw_input orelse .null,
        else => toolInput(tool.state) orelse .null,
    };
    try content.append(arena, .{ .tool_call = .{
        .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
        .tool_name = try arena.dupe(u8, tool.name),
        .input = try provider_utils.cloneJsonValue(arena, input),
        .provider_executed = tool.provider_executed,
        .provider_options = try cloneOptionalValue(arena, stateCallMetadata(tool.state)),
    } });

    if (toolApprovalRequest(tool.state)) |approval| {
        try content.append(arena, .{ .tool_approval_request = .{
            .approval_id = try arena.dupe(u8, approval.id),
            .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
            .is_automatic = approval.is_automatic,
            .signature = try cloneOptionalString(arena, approval.signature),
        } });
    }

    if (tool.provider_executed == true) switch (tool.state) {
        .output_available => |state| try content.append(arena, .{ .tool_result = .{
            .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
            .tool_name = try arena.dupe(u8, tool.name),
            .output = try prompt.createToolModelOutput(
                arena,
                tool.tool_call_id,
                state.input,
                state.output,
                findTool(options.tools, tool.name),
                .none,
            ),
            .provider_options = try cloneOptionalValue(arena, state.result_provider_metadata orelse state.call_provider_metadata),
        } }),
        .output_error => |state| try content.append(arena, .{ .tool_result = .{
            .tool_call_id = try arena.dupe(u8, tool.tool_call_id),
            .tool_name = try arena.dupe(u8, tool.name),
            .output = try prompt.createToolModelOutput(
                arena,
                tool.tool_call_id,
                state.input orelse state.raw_input orelse .null,
                .{ .string = state.error_text },
                findTool(options.tools, tool.name),
                .json,
            ),
            .provider_options = try cloneOptionalValue(arena, state.result_provider_metadata orelse state.call_provider_metadata),
        } }),
        else => {},
    };
}

fn modelFilePart(arena: Allocator, value: ui.FileUIPart) !message.FilePart {
    return .{
        .data = if (value.provider_reference) |reference|
            .{ .reference = try provider_utils.cloneJsonValue(arena, reference) }
        else
            .{ .url = try arena.dupe(u8, value.url) },
        .filename = try cloneOptionalString(arena, value.filename),
        .media_type = try arena.dupe(u8, value.media_type),
        .provider_options = try cloneOptionalValue(arena, value.provider_metadata),
    };
}

pub const ValidateOptions = struct {
    metadata_schema: ?provider_utils.Schema = null,
    data_schemas: []const process.NamedSchema = &.{},
    tools: tool_api.ToolSet = &.{},
    diag: ?*provider.Diagnostics = null,
};

pub fn SafeValidateResult(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: anyerror,
    };
}

pub fn safeValidateUIMessages(
    arena: Allocator,
    values: []const ui.UIMessage,
    options: ValidateOptions,
) SafeValidateResult([]const ui.UIMessage) {
    return .{ .success = validateUIMessages(arena, values, options) catch |err| return .{ .failure = err } };
}

pub fn validateUIMessages(
    arena: Allocator,
    values: []const ui.UIMessage,
    options: ValidateOptions,
) anyerror![]const ui.UIMessage {
    if (values.len == 0) return validationError(arena, options.diag, "Messages array must not be empty", null, null);
    for (values, 0..) |value, message_index| {
        if (value.parts.len == 0) return validationError(arena, options.diag, "Message must contain at least one part", value.id, null);
        if (options.metadata_schema) |schema| {
            try validateSchema(arena, schema, value.metadata orelse .null, options.diag);
        }
        for (value.parts, 0..) |part, part_index| {
            try validatePartShape(arena, part, value.id, options.diag);
            switch (part) {
                .data => |data| if (options.data_schemas.len != 0) {
                    const schema = schemaFor(options.data_schemas, data.name) orelse
                        return validationError(arena, options.diag, "No data schema found for data part", value.id, data.name);
                    try validateSchema(arena, schema, data.data, options.diag);
                },
                .tool => |tool| if (options.tools.len != 0) try validateToolPart(arena, tool, options, message_index, part_index),
                .dynamic_tool => {},
                else => {},
            }
        }
    }
    return values;
}

pub fn parseAndValidateUIMessages(
    arena: Allocator,
    value: JsonValue,
    options: ValidateOptions,
) anyerror![]const ui.UIMessage {
    const parsed = provider.wire.parse([]const ui.UIMessage, arena, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return validationError(arena, options.diag, "UI messages failed structural validation", null, null),
    };
    return validateUIMessages(arena, parsed, options);
}

fn validatePartShape(
    arena: Allocator,
    part: ui.UIMessagePart,
    message_id: []const u8,
    diag: ?*provider.Diagnostics,
) !void {
    const tool_metadata = switch (part) {
        .tool => |tool| tool.tool_metadata,
        .dynamic_tool => |tool| tool.tool_metadata,
        else => null,
    };
    if (tool_metadata) |metadata| if (metadata != .object)
        return validationError(arena, diag, "Tool metadata must be a JSON object", message_id, null);
    if (part == .file) if (part.file.provider_reference) |reference| {
        if (reference != .object) return validationError(arena, diag, "Provider reference must be an object", message_id, null);
        var iterator = reference.object.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.* != .string)
            return validationError(arena, diag, "Provider reference values must be strings", message_id, entry.key_ptr.*);
    };
}

fn validateToolPart(
    arena: Allocator,
    part: ui.ToolUIPart,
    options: ValidateOptions,
    _: usize,
    _: usize,
) !void {
    const selected = findTool(options.tools, part.name);
    if (selected == null and switch (part.state) {
        .output_available, .output_error, .output_denied => true,
        else => false,
    }) return;
    const tool = selected orelse return validationError(arena, options.diag, "No tool schema found for tool part", part.tool_call_id, part.name);

    switch (part.state) {
        .input_available => |state| try validateSchema(arena, tool.input_schema, state.input, options.diag),
        .output_available => |state| {
            try validateSchema(arena, tool.input_schema, state.input, options.diag);
            if (tool.output_schema) |schema| try validateSchema(arena, schema, state.output, options.diag);
        },
        // Invalid-input failures deliberately retain raw invalid input.
        .output_error => {},
        else => {},
    }
}

fn validateSchema(arena: Allocator, schema: provider_utils.Schema, value: JsonValue, diag: ?*provider.Diagnostics) !void {
    const validator = schema.validator orelse return validationError(arena, diag, "Schema has no runtime validator", null, null);
    try validator.validate(arena, value, diag);
}

fn schemaFor(schemas: []const process.NamedSchema, name: []const u8) ?provider_utils.Schema {
    for (schemas) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.schema;
    return null;
}

fn validationError(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    text: []const u8,
    entity_id: ?[]const u8,
    entity_name: ?[]const u8,
) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{ .type_validation = .{
        .message = text,
        .context = .{ .entity_id = entity_id, .entity_name = entity_name },
    } });
    return error.TypeValidationError;
}

fn findTool(tools: tool_api.ToolSet, name: []const u8) ?*const tool_api.Tool {
    for (tools) |*named| if (std.mem.eql(u8, named.name, name)) return &named.tool;
    return null;
}

fn toolInput(state: ui.ToolState) ?JsonValue {
    return switch (state) {
        .input_streaming => |value| value.input,
        .input_available => |value| value.input,
        .approval_requested => |value| value.input,
        .approval_responded => |value| value.input,
        .output_available => |value| value.input,
        .output_error => |value| value.input,
        .output_denied => |value| value.input,
    };
}

fn stateCallMetadata(state: ui.ToolState) ?JsonValue {
    return switch (state) {
        .input_streaming => |value| value.call_provider_metadata,
        .input_available => |value| value.call_provider_metadata,
        .approval_requested => |value| value.call_provider_metadata,
        .approval_responded => |value| value.call_provider_metadata,
        .output_available => |value| value.call_provider_metadata,
        .output_error => |value| value.call_provider_metadata,
        .output_denied => |value| value.call_provider_metadata,
    };
}

fn toolApprovalRequest(state: ui.ToolState) ?ui.ApprovalRequest {
    return switch (state) {
        .approval_requested => |value| value.approval,
        .approval_responded => |value| .{
            .id = value.approval.id,
            .is_automatic = value.approval.is_automatic,
            .signature = value.approval.signature,
        },
        .output_available => |value| if (value.approval) |approval| .{
            .id = approval.id,
            .is_automatic = approval.is_automatic,
            .signature = approval.signature,
        } else null,
        .output_error => |value| if (value.approval) |approval| .{
            .id = approval.id,
            .is_automatic = approval.is_automatic,
            .signature = approval.signature,
        } else null,
        .output_denied => |value| .{
            .id = value.approval.id,
            .is_automatic = value.approval.is_automatic,
            .signature = value.approval.signature,
        },
        else => null,
    };
}

fn toolApprovalResponse(state: ui.ToolState) ?ui.ApprovalResponse {
    return switch (state) {
        .approval_responded => |value| value.approval,
        .output_available => |value| value.approval,
        .output_error => |value| value.approval,
        .output_denied => |value| value.approval,
        else => null,
    };
}

fn mergeObjects(arena: Allocator, base: ?JsonValue, override: JsonValue) Allocator.Error!JsonValue {
    if (base == null or base.? != .object or override != .object) return provider_utils.cloneJsonValue(arena, override);
    var result = try provider_utils.cloneJsonValue(arena, base.?);
    var iterator = override.object.iterator();
    while (iterator.next()) |entry| try result.object.put(
        arena,
        try arena.dupe(u8, entry.key_ptr.*),
        try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
    );
    return result;
}

fn cloneOptionalString(arena: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (value) |text| try arena.dupe(u8, text) else null;
}

fn cloneOptionalValue(arena: Allocator, value: ?JsonValue) Allocator.Error!?JsonValue {
    return if (value) |item| try provider_utils.cloneJsonValue(arena, item) else null;
}

test "convertToModelMessages splits assistant steps and lowers approvals and tool outputs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]ui.UIMessagePart{
        .{ .text = .{ .text = "first" } },
        .{ .tool = .{
            .name = "weather",
            .tool_call_id = "c1",
            .state = .{ .output_available = .{
                .input = .{ .string = "NYC" },
                .output = .{ .string = "sunny" },
            } },
        } },
        .{ .step_start = {} },
        .{ .tool = .{
            .name = "danger",
            .tool_call_id = "c2",
            .state = .{ .approval_responded = .{
                .input = .null,
                .approval = .{ .id = "a2", .approved = false, .reason = "denied" },
            } },
        } },
    };
    const input = [_]ui.UIMessage{.{ .id = "a", .role = .assistant, .parts = &parts }};
    const converted = try convertToModelMessages(arena, &input, .{});
    try std.testing.expectEqual(4, converted.len);
    try std.testing.expect(converted[0] == .assistant);
    try std.testing.expect(converted[1] == .tool);
    try std.testing.expect(converted[2] == .assistant);
    try std.testing.expect(converted[3] == .tool);
    try std.testing.expect(converted[3].tool.content[1].tool_result.output == .execution_denied);
}

test "validateUIMessages validates tool schemas but not output-error input" {
    const Input = struct { city: []const u8 };
    const Output = struct { temperature: i32 };
    const tool = tool_api.NamedTool{ .name = "weather", .tool = .{
        .input_schema = provider_utils.schemaFromType(Input),
        .output_schema = provider_utils.schemaFromType(Output),
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const good_input = try std.json.parseFromSliceLeaky(JsonValue, arena, "{\"city\":\"NYC\"}", .{});
    const good_output = try std.json.parseFromSliceLeaky(JsonValue, arena, "{\"temperature\":72}", .{});
    const parts = [_]ui.UIMessagePart{.{ .tool = .{
        .name = "weather",
        .tool_call_id = "c",
        .state = .{ .output_available = .{ .input = good_input, .output = good_output } },
    } }};
    const values = [_]ui.UIMessage{.{ .id = "a", .role = .assistant, .parts = &parts }};
    _ = try validateUIMessages(arena, &values, .{ .tools = &.{tool} });

    const invalid_parts = [_]ui.UIMessagePart{.{ .tool = .{
        .name = "weather",
        .tool_call_id = "bad",
        .state = .{ .output_error = .{ .raw_input = .{ .string = "not an object" }, .error_text = "invalid" } },
    } }};
    const invalid_values = [_]ui.UIMessage{.{ .id = "a", .role = .assistant, .parts = &invalid_parts }};
    _ = try validateUIMessages(arena, &invalid_values, .{ .tools = &.{tool} });
}
