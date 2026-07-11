const std = @import("std");
const c = @import("ai_c_header");
const options = @import("options.zig");
const providers = @import("providers.zig");
const result = @import("result.zig");
const runtime = @import("runtime.zig");
const stream = @import("stream.zig");
const types = @import("types.zig");

test "translated ai.h is ABI-locked to Zig exports" {
    comptime {
        assertEnumValues();

        assertAbiType(c.ai_string, types.ai_string);
        assertAbiType(c.ai_runtime_config, types.ai_runtime_config);
        assertAbiType(c.ai_anthropic_config, types.ai_anthropic_config);
        assertAbiType(c.ai_openrouter_config, types.ai_openrouter_config);
        assertAbiType(c.ai_openai_compatible_config, types.ai_openai_compatible_config);
        assertAbiType(c.ai_tool_result, types.ai_tool_result);
        assertAbiType(c.ai_tool, types.ai_tool);
        assertAbiType(c.ai_part, types.ai_part);

        assertAbiType(@TypeOf(c.ai_status_name), @TypeOf(runtime.ai_status_name));
        assertAbiType(@TypeOf(c.ai_alloc), @TypeOf(runtime.ai_alloc));
        assertAbiType(@TypeOf(c.ai_buf_free), @TypeOf(runtime.ai_buf_free));
        assertAbiType(@TypeOf(c.ai_runtime_create), @TypeOf(runtime.ai_runtime_create));
        assertAbiType(@TypeOf(c.ai_runtime_destroy), @TypeOf(runtime.ai_runtime_destroy));
        assertAbiType(@TypeOf(c.ai_runtime_last_error), @TypeOf(runtime.ai_runtime_last_error));
        assertAbiType(@TypeOf(c.ai_provider_anthropic), @TypeOf(providers.ai_provider_anthropic));
        assertAbiType(@TypeOf(c.ai_provider_openrouter), @TypeOf(providers.ai_provider_openrouter));
        assertAbiType(
            @TypeOf(c.ai_provider_openai_compatible),
            @TypeOf(providers.ai_provider_openai_compatible),
        );
        assertAbiType(@TypeOf(c.ai_provider_destroy), @TypeOf(providers.ai_provider_destroy));
        assertAbiType(
            @TypeOf(c.ai_provider_language_model),
            @TypeOf(providers.ai_provider_language_model),
        );
        assertAbiType(@TypeOf(c.ai_model_destroy), @TypeOf(providers.ai_model_destroy));
        assertAbiType(@TypeOf(c.ai_generate_text), @TypeOf(result.ai_generate_text));
        assertAbiType(@TypeOf(c.ai_result_json), @TypeOf(result.ai_result_json));
        assertAbiType(@TypeOf(c.ai_result_text), @TypeOf(result.ai_result_text));
        assertAbiType(
            @TypeOf(c.ai_result_finish_reason),
            @TypeOf(result.ai_result_finish_reason),
        );
        assertAbiType(
            @TypeOf(c.ai_result_total_tokens),
            @TypeOf(result.ai_result_total_tokens),
        );
        assertAbiType(@TypeOf(c.ai_result_destroy), @TypeOf(result.ai_result_destroy));
        assertAbiType(@TypeOf(c.ai_stream_text), @TypeOf(stream.ai_stream_text));
        assertAbiType(@TypeOf(c.ai_stream_next), @TypeOf(stream.ai_stream_next));
        assertAbiType(@TypeOf(c.ai_stream_cancel), @TypeOf(stream.ai_stream_cancel));
        assertAbiType(@TypeOf(c.ai_stream_last_error), @TypeOf(stream.ai_stream_last_error));
        assertAbiType(@TypeOf(c.ai_part_clone), @TypeOf(stream.ai_part_clone));
        assertAbiType(@TypeOf(c.ai_stream_destroy), @TypeOf(stream.ai_stream_destroy));

        _ = options;
    }
}

fn assertEnumValues() void {
    assertInt(c.AI_OK, @intFromEnum(types.Status.ok));
    assertInt(c.AI_STREAM_DONE, @intFromEnum(types.Status.stream_done));
    assertInt(c.AI_INVALID_ARGUMENT, @intFromEnum(types.Status.invalid_argument));
    assertInt(c.AI_API_CALL, @intFromEnum(types.Status.api_call));
    assertInt(c.AI_NO_SUCH_MODEL, @intFromEnum(types.Status.no_such_model));
    assertInt(c.AI_NO_SUCH_PROVIDER, @intFromEnum(types.Status.no_such_provider));
    assertInt(c.AI_LOAD_API_KEY, @intFromEnum(types.Status.load_api_key));
    assertInt(c.AI_LOAD_SETTING, @intFromEnum(types.Status.load_setting));
    assertInt(c.AI_RETRY, @intFromEnum(types.Status.retry));
    assertInt(c.AI_CANCELED, @intFromEnum(types.Status.canceled));
    assertInt(c.AI_TIMEOUT, @intFromEnum(types.Status.timeout));
    assertInt(c.AI_OUT_OF_MEMORY, @intFromEnum(types.Status.out_of_memory));
    assertInt(c.AI_INVALID_JSON, @intFromEnum(types.Status.invalid_json));
    assertInt(c.AI_INVALID_PROMPT, @intFromEnum(types.Status.invalid_prompt));
    assertInt(c.AI_INVALID_RESPONSE, @intFromEnum(types.Status.invalid_response));
    assertInt(c.AI_NO_SUCH_TOOL, @intFromEnum(types.Status.no_such_tool));
    assertInt(c.AI_TOOL_ERROR, @intFromEnum(types.Status.tool_error));
    assertInt(c.AI_UNSUPPORTED, @intFromEnum(types.Status.unsupported));
    assertInt(c.AI_UNKNOWN, @intFromEnum(types.Status.unknown));

    inline for (.{
        .{ c.AI_PART_TEXT_START, types.PartType.text_start },
        .{ c.AI_PART_TEXT_END, types.PartType.text_end },
        .{ c.AI_PART_TEXT_DELTA, types.PartType.text_delta },
        .{ c.AI_PART_REASONING_START, types.PartType.reasoning_start },
        .{ c.AI_PART_REASONING_END, types.PartType.reasoning_end },
        .{ c.AI_PART_REASONING_DELTA, types.PartType.reasoning_delta },
        .{ c.AI_PART_CUSTOM, types.PartType.custom },
        .{ c.AI_PART_TOOL_INPUT_START, types.PartType.tool_input_start },
        .{ c.AI_PART_TOOL_INPUT_END, types.PartType.tool_input_end },
        .{ c.AI_PART_TOOL_INPUT_DELTA, types.PartType.tool_input_delta },
        .{ c.AI_PART_SOURCE, types.PartType.source },
        .{ c.AI_PART_FILE, types.PartType.file },
        .{ c.AI_PART_REASONING_FILE, types.PartType.reasoning_file },
        .{ c.AI_PART_TOOL_CALL, types.PartType.tool_call },
        .{ c.AI_PART_TOOL_RESULT, types.PartType.tool_result },
        .{ c.AI_PART_TOOL_ERROR, types.PartType.tool_error },
        .{ c.AI_PART_TOOL_OUTPUT_DENIED, types.PartType.tool_output_denied },
        .{ c.AI_PART_TOOL_APPROVAL_REQUEST, types.PartType.tool_approval_request },
        .{ c.AI_PART_TOOL_APPROVAL_RESPONSE, types.PartType.tool_approval_response },
        .{ c.AI_PART_START_STEP, types.PartType.start_step },
        .{ c.AI_PART_FINISH_STEP, types.PartType.finish_step },
        .{ c.AI_PART_START, types.PartType.start },
        .{ c.AI_PART_FINISH, types.PartType.finish },
        .{ c.AI_PART_ABORT, types.PartType.abort },
        .{ c.AI_PART_ERROR, types.PartType.err },
        .{ c.AI_PART_RAW, types.PartType.raw },
        .{ c.AI_PART_UNKNOWN, types.PartType.unknown },
    }) |mapping| assertInt(mapping[0], @intFromEnum(mapping[1]));
}

fn assertInt(comptime actual: anytype, comptime expected: anytype) void {
    if (actual != expected) @compileError("ai.h enum value drift");
}

fn assertAbiType(comptime A: type, comptime B: type) void {
    if (A == B) return;
    const a = @typeInfo(A);
    const b = @typeInfo(B);
    switch (a) {
        .int => |a_info| switch (b) {
            .int => |b_info| {
                if (a_info.bits != b_info.bits or a_info.signedness != b_info.signedness) fail(A, B);
            },
            .@"enum" => |b_info| assertAbiType(A, b_info.tag_type),
            else => fail(A, B),
        },
        .@"enum" => |a_info| switch (b) {
            .int => assertAbiType(a_info.tag_type, B),
            .@"enum" => |b_info| assertAbiType(a_info.tag_type, b_info.tag_type),
            else => fail(A, B),
        },
        .pointer => |a_info| switch (b) {
            .pointer => |b_info| {
                if (a_info.size != b_info.size or
                    a_info.is_const != b_info.is_const or
                    a_info.is_volatile != b_info.is_volatile or
                    a_info.alignment != b_info.alignment)
                {
                    fail(A, B);
                }
                assertAbiType(a_info.child, b_info.child);
            },
            else => fail(A, B),
        },
        .optional => |a_info| switch (b) {
            .optional => |b_info| assertAbiType(a_info.child, b_info.child),
            else => fail(A, B),
        },
        .@"struct" => |a_info| switch (b) {
            .@"struct" => |b_info| {
                if (a_info.layout != b_info.layout or a_info.fields.len != b_info.fields.len) fail(A, B);
                inline for (a_info.fields, b_info.fields) |a_field, b_field| {
                    if (!std.mem.eql(u8, a_field.name, b_field.name)) fail(A, B);
                    if (@offsetOf(A, a_field.name) != @offsetOf(B, b_field.name)) fail(A, B);
                    assertAbiType(a_field.type, b_field.type);
                }
                if (@sizeOf(A) != @sizeOf(B) or @alignOf(A) != @alignOf(B)) fail(A, B);
            },
            else => fail(A, B),
        },
        .@"fn" => |a_info| switch (b) {
            .@"fn" => |b_info| {
                if (!a_info.calling_convention.eql(b_info.calling_convention) or
                    a_info.params.len != b_info.params.len or
                    a_info.is_var_args != b_info.is_var_args)
                {
                    fail(A, B);
                }
                inline for (a_info.params, b_info.params) |a_param, b_param| {
                    assertAbiType(a_param.type.?, b_param.type.?);
                }
                assertAbiType(a_info.return_type.?, b_info.return_type.?);
            },
            else => fail(A, B),
        },
        .void => switch (b) {
            .void => {},
            else => fail(A, B),
        },
        .@"opaque" => switch (b) {
            .@"opaque" => {},
            else => fail(A, B),
        },
        else => fail(A, B),
    }
}

fn fail(comptime A: type, comptime B: type) noreturn {
    @compileError("ai.h ABI drift: " ++ @typeName(A) ++ " != " ++ @typeName(B));
}
