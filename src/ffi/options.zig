const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const providers = @import("providers.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const WireOptions = struct {
    instructions: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    messages: ?[]const ai.ModelMessage = null,
    allow_system_in_messages: bool = false,
    tool_choice: ?std.json.Value = null,
    max_output_tokens: ?f64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?f64 = null,
    reasoning: ?provider.ReasoningEffort = null,
    headers: ?provider.Headers = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    timeout: ?std.json.Value = null,
    timeout_ms: ?u64 = null,
    max_steps: u32 = 1,
    tools_context: ?std.json.Value = null,
    runtime_context: ?std.json.Value = null,
    include_raw_chunks: bool = false,
};

const TimeoutWire = struct {
    total_ms: ?u64 = null,
    step_ms: ?u64 = null,
    chunk_ms: ?u64 = null,
    tool_ms: ?u64 = null,
    tools: []const ai.ToolTimeout = &.{},
};

pub const ParsedOptions = struct {
    wire: WireOptions,
    tool_choice: ?ai.prompt.ToolChoice,
    timeout: ?ai.TimeoutConfiguration,

    pub fn generate(
        self: ParsedOptions,
        model: provider.LanguageModel,
        tools: []const ai.NamedTool,
        stop_when: []const ai.StopCondition,
        diagnostics: *provider.Diagnostics,
    ) ai.GenerateTextOptions {
        return .{
            .model = .{ .model = model },
            .instructions = if (self.wire.instructions) |value| .{ .text = value } else null,
            .prompt = if (self.wire.prompt) |value| .{ .text = value } else null,
            .messages = self.wire.messages,
            .allow_system_in_messages = self.wire.allow_system_in_messages,
            .tools = tools,
            .tool_choice = self.tool_choice,
            .stop_when = stop_when,
            .max_output_tokens = self.wire.max_output_tokens,
            .temperature = self.wire.temperature,
            .top_p = self.wire.top_p,
            .top_k = self.wire.top_k,
            .presence_penalty = self.wire.presence_penalty,
            .frequency_penalty = self.wire.frequency_penalty,
            .stop_sequences = self.wire.stop_sequences,
            .seed = self.wire.seed,
            .reasoning = self.wire.reasoning,
            .headers = self.wire.headers,
            .provider_options = self.wire.provider_options,
            .max_retries = self.wire.max_retries,
            .timeout = self.timeout,
            .tools_context = self.wire.tools_context,
            .runtime_context = self.wire.runtime_context,
            .diag = diagnostics,
        };
    }

    pub fn stream(
        self: ParsedOptions,
        model: provider.LanguageModel,
        tools: []const ai.NamedTool,
        stop_when: []const ai.StopCondition,
        diagnostics: *provider.Diagnostics,
    ) ai.StreamTextOptions {
        const base = self.generate(model, tools, stop_when, diagnostics);
        return .{
            .model = base.model,
            .instructions = base.instructions,
            .prompt = base.prompt,
            .messages = base.messages,
            .allow_system_in_messages = base.allow_system_in_messages,
            .tools = base.tools,
            .tool_choice = base.tool_choice,
            .stop_when = base.stop_when,
            .max_output_tokens = base.max_output_tokens,
            .temperature = base.temperature,
            .top_p = base.top_p,
            .top_k = base.top_k,
            .presence_penalty = base.presence_penalty,
            .frequency_penalty = base.frequency_penalty,
            .stop_sequences = base.stop_sequences,
            .seed = base.seed,
            .reasoning = base.reasoning,
            .headers = base.headers,
            .provider_options = base.provider_options,
            .max_retries = base.max_retries,
            .timeout = base.timeout,
            .tools_context = base.tools_context,
            .runtime_context = base.runtime_context,
            .diag = diagnostics,
            .include_raw_chunks = self.wire.include_raw_chunks,
        };
    }
};

const ToolContext = struct {
    callback: *const fn (
        user_data: ?*anyopaque,
        input_json: [*c]const u8,
        input_len: usize,
        out: [*c]types.ai_tool_result,
    ) callconv(.c) types.Status,
    user_data: ?*anyopaque,

    fn execute(
        raw: ?*anyopaque,
        _: std.Io,
        arena: Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        const self: *ToolContext = @ptrCast(@alignCast(raw.?));
        const input_json = try provider.wire.stringifyAlloc(arena, input);
        var output: types.ai_tool_result = .{
            .struct_size = @sizeOf(types.ai_tool_result),
            .ptr = null,
            .len = 0,
        };
        const status = self.callback(self.user_data, input_json.ptr, input_json.len, &output);
        defer if (output.ptr != null) std.heap.c_allocator.free(output.ptr[0..output.len]);
        if (status != .ok) return types.errorFromStatus(status);
        if (output.struct_size < types.minimumStructSize(types.ai_tool_result)) return error.InvalidArgumentError;
        if (output.ptr == null) return error.JSONParseError;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, output.ptr[0..output.len], .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.JSONParseError,
        };
        return .{ .value = value };
    }
};

pub fn parse(
    arena: Allocator,
    ptr: [*c]const u8,
    len: usize,
    diagnostics: *provider.Diagnostics,
) provider.CallError!ParsedOptions {
    const text = providers.optionalSlice(ptr, len) catch
        return invalid(diagnostics, "optionsJson pointer is null", "optionsJson", null);
    const source = if (text.len == 0) "{}" else text;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(diagnostics, "optionsJson is not valid JSON", "optionsJson", source),
    };
    const wire = provider.wire.parse(WireOptions, arena, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(
            diagnostics,
            "optionsJson does not match the canonical FFI option schema",
            "optionsJson",
            source,
        ),
    };
    if (wire.max_steps == 0) {
        return invalid(diagnostics, "maxSteps must be at least 1", "maxSteps", null);
    }
    if (wire.timeout != null and wire.timeout_ms != null) {
        return invalid(
            diagnostics,
            "timeout and timeoutMs cannot both be defined",
            "timeout",
            null,
        );
    }
    return .{
        .wire = wire,
        .tool_choice = try parseToolChoice(wire.tool_choice, diagnostics),
        .timeout = try parseTimeout(arena, wire.timeout, wire.timeout_ms, diagnostics),
    };
}

pub fn stopConditions(parsed: ParsedOptions, storage: *[1]ai.StopCondition) []const ai.StopCondition {
    if (parsed.wire.max_steps == 1) return &.{};
    storage[0] = ai.stepCount(parsed.wire.max_steps);
    return storage;
}

pub fn parseTools(
    arena: Allocator,
    input: [*c]const types.ai_tool,
    len: usize,
    diagnostics: *provider.Diagnostics,
) provider.CallError![]const ai.NamedTool {
    if (len == 0) return &.{};
    if (input == null) return invalid(diagnostics, "tools pointer is null", "tools", null);

    const stride_ptr: [*c]const usize = @ptrCast(input);
    const stride = stride_ptr[0];
    if (stride < types.minimumStructSize(types.ai_tool)) {
        return invalid(diagnostics, "tool struct_size is too small", "tools.structSize", null);
    }
    if (stride > std.math.maxInt(usize) / len) {
        return invalid(diagnostics, "tool array size overflows", "tools.structSize", null);
    }
    const contexts = try arena.alloc(ToolContext, len);
    const result = try arena.alloc(ai.NamedTool, len);
    const bytes: [*]const u8 = @ptrCast(input);
    for (contexts, result, 0..) |*context, *destination, index| {
        const source_ptr: [*c]const types.ai_tool = @ptrCast(@alignCast(bytes + index * stride));
        const source = types.readStruct(types.ai_tool, source_ptr) catch
            return invalid(diagnostics, "tool struct_size is too small", "tools.structSize", null);
        const name = providers.requiredSlice(source.name_ptr, source.name_len) catch
            return invalid(diagnostics, "tool name is required", "tools.name", null);
        const description = providers.optionalSlice(source.description_ptr, source.description_len) catch
            return invalid(diagnostics, "tool description pointer is null", "tools.description", null);
        const schema = providers.requiredSlice(
            source.input_schema_json_ptr,
            source.input_schema_json_len,
        ) catch return invalid(
            diagnostics,
            "tool inputSchemaJson is required",
            "tools.inputSchemaJson",
            null,
        );
        _ = std.json.parseFromSliceLeaky(std.json.Value, arena, schema, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid(
                diagnostics,
                "tool inputSchemaJson is not valid JSON",
                "tools.inputSchemaJson",
                schema,
            ),
        };
        const callback = source.execute orelse return invalid(
            diagnostics,
            "tool execute callback is required",
            "tools.execute",
            null,
        );
        const owned_name = try arena.dupe(u8, name);
        const owned_description = try arena.dupe(u8, description);
        const owned_schema = try arena.dupe(u8, schema);
        context.* = .{ .callback = callback, .user_data = source.user_data };
        destination.* = .{
            .name = owned_name,
            .tool = .{
                .description = if (owned_description.len == 0)
                    null
                else
                    .{ .text = owned_description },
                .input_schema = provider_utils.rawSchema(owned_schema, null),
                .execute = .{ .ctx = context, .execute_fn = ToolContext.execute },
            },
        };
    }
    return result;
}

fn parseToolChoice(
    value: ?std.json.Value,
    diagnostics: *provider.Diagnostics,
) provider.CallError!?ai.prompt.ToolChoice {
    const selected = value orelse return null;
    if (selected == .string) {
        if (std.mem.eql(u8, selected.string, "auto")) return .auto;
        if (std.mem.eql(u8, selected.string, "none")) return .none;
        if (std.mem.eql(u8, selected.string, "required")) return .required;
    }
    if (selected == .object) {
        const tool_name = selected.object.get("toolName") orelse selected.object.get("tool_name");
        if (tool_name) |name| if (name == .string and name.string.len != 0) {
            return .{ .named = name.string };
        };
    }
    return invalid(
        diagnostics,
        "toolChoice must be auto, none, required, or an object with toolName",
        "toolChoice",
        null,
    );
}

fn parseTimeout(
    arena: Allocator,
    value: ?std.json.Value,
    timeout_ms: ?u64,
    diagnostics: *provider.Diagnostics,
) provider.CallError!?ai.TimeoutConfiguration {
    if (timeout_ms) |milliseconds| return .{ .total_ms = milliseconds };
    const selected = value orelse return null;
    switch (selected) {
        .integer => |milliseconds| {
            if (milliseconds < 0) {
                return invalid(diagnostics, "timeout must be non-negative", "timeout", null);
            }
            return .{ .total_ms = @intCast(milliseconds) };
        },
        .object => {
            const parsed = provider.wire.parse(TimeoutWire, arena, selected) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(
                    diagnostics,
                    "timeout object is invalid",
                    "timeout",
                    null,
                ),
            };
            return .{ .granular = .{
                .total_ms = parsed.total_ms,
                .step_ms = parsed.step_ms,
                .chunk_ms = parsed.chunk_ms,
                .tool_ms = parsed.tool_ms,
                .tools = parsed.tools,
            } };
        },
        else => return invalid(
            diagnostics,
            "timeout must be an integer or object",
            "timeout",
            null,
        ),
    }
}

fn invalid(
    diagnostics: *provider.Diagnostics,
    message: []const u8,
    parameter: []const u8,
    value_json: ?[]const u8,
) provider.Error {
    provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .invalid_argument = .{
        .message = message,
        .parameter = parameter,
        .value_json = value_json,
    } });
    return error.InvalidArgumentError;
}

test "bad FFI options become invalid_argument diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.InvalidArgumentError,
        parse(arena_state.allocator(), "{".ptr, 1, &diagnostics),
    );
    try std.testing.expectEqualStrings("optionsJson", diagnostics.payload.invalid_argument.parameter);
}
