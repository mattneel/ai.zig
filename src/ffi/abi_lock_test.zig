const std = @import("std");
const c = @import("ai_c_header");
const agent = @import("agent.zig");
const embeddings = @import("embeddings.zig");
const media = @import("media.zig");
const objects = @import("objects.zig");
const options = @import("options.zig");
const providers = @import("providers.zig");
const result = @import("result.zig");
const runtime = @import("runtime.zig");
const stream = @import("stream.zig");
const telemetry = @import("telemetry.zig");
const types = @import("types.zig");

test "translated ai.h is ABI-locked to Zig exports" {
    comptime {
        @setEvalBranchQuota(100_000);
        assertFrozenNumericValues();
        assertEnumValues();
        assertInt(c.AI_ABI_VERSION_MAJOR, types.abi_version_major);
        assertInt(c.AI_ABI_VERSION_MINOR, types.abi_version_minor);
        assertInt(c.AI_ABI_VERSION_PATCH, types.abi_version_patch);
        assertInt(c.AI_ABI_VERSION, types.abi_version);

        assertAbiType(c.ai_string, types.ai_string);
        assertAbiType(c.ai_runtime_config, types.ai_runtime_config);
        assertAbiType(c.ai_anthropic_config, types.ai_anthropic_config);
        assertAbiType(c.ai_openrouter_config, types.ai_openrouter_config);
        assertAbiType(c.ai_openai_compatible_config, types.ai_openai_compatible_config);
        assertAbiType(c.ai_openai_config, types.ai_openai_config);
        assertAbiType(c.ai_xai_config, types.ai_xai_config);
        assertAbiType(c.ai_tool_result, types.ai_tool_result);
        assertAbiType(c.ai_tool, types.ai_tool);
        assertAbiType(c.ai_part, types.ai_part);
        assertAbiType(c.ai_buffer, types.ai_buffer);
        assertAbiType(c.ai_agent_config, types.ai_agent_config);
        assertAbiType(c.ai_telemetry_vtable, types.ai_telemetry_vtable);
        assertFrozenLayouts();

        assertAbiType(@TypeOf(c.ai_abi_version), @TypeOf(runtime.ai_abi_version));
        assertAbiType(@TypeOf(c.ai_abi_version_string), @TypeOf(runtime.ai_abi_version_string));
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
        assertAbiType(@TypeOf(c.ai_provider_openai), @TypeOf(providers.ai_provider_openai));
        assertAbiType(@TypeOf(c.ai_provider_xai), @TypeOf(providers.ai_provider_xai));
        assertAbiType(@TypeOf(c.ai_provider_destroy), @TypeOf(providers.ai_provider_destroy));
        assertAbiType(
            @TypeOf(c.ai_provider_language_model),
            @TypeOf(providers.ai_provider_language_model),
        );
        assertAbiType(@TypeOf(c.ai_model_destroy), @TypeOf(providers.ai_model_destroy));
        assertAbiType(
            @TypeOf(c.ai_provider_embedding_model),
            @TypeOf(providers.ai_provider_embedding_model),
        );
        assertAbiType(
            @TypeOf(c.ai_embedding_model_destroy),
            @TypeOf(providers.ai_embedding_model_destroy),
        );
        assertAbiType(
            @TypeOf(c.ai_provider_image_model),
            @TypeOf(providers.ai_provider_image_model),
        );
        assertAbiType(@TypeOf(c.ai_image_model_destroy), @TypeOf(providers.ai_image_model_destroy));
        assertAbiType(
            @TypeOf(c.ai_provider_speech_model),
            @TypeOf(providers.ai_provider_speech_model),
        );
        assertAbiType(@TypeOf(c.ai_speech_model_destroy), @TypeOf(providers.ai_speech_model_destroy));
        assertAbiType(
            @TypeOf(c.ai_provider_transcription_model),
            @TypeOf(providers.ai_provider_transcription_model),
        );
        assertAbiType(
            @TypeOf(c.ai_transcription_model_destroy),
            @TypeOf(providers.ai_transcription_model_destroy),
        );
        assertAbiType(@TypeOf(c.ai_generate_text), @TypeOf(result.ai_generate_text));
        assertAbiType(@TypeOf(c.ai_generate_object), @TypeOf(objects.ai_generate_object));
        assertAbiType(@TypeOf(c.ai_stream_object), @TypeOf(objects.ai_stream_object));
        assertAbiType(@TypeOf(c.ai_embed), @TypeOf(embeddings.ai_embed));
        assertAbiType(@TypeOf(c.ai_embed_many), @TypeOf(embeddings.ai_embed_many));
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
        assertAbiType(@TypeOf(c.ai_result_blob_count), @TypeOf(result.ai_result_blob_count));
        assertAbiType(
            @TypeOf(c.ai_result_blob_media_type),
            @TypeOf(result.ai_result_blob_media_type),
        );
        assertAbiType(@TypeOf(c.ai_result_blob), @TypeOf(result.ai_result_blob));
        assertAbiType(@TypeOf(c.ai_result_destroy), @TypeOf(result.ai_result_destroy));
        assertAbiType(@TypeOf(c.ai_stream_text), @TypeOf(stream.ai_stream_text));
        assertAbiType(@TypeOf(c.ai_stream_text_ui), @TypeOf(stream.ai_stream_text_ui));
        assertAbiType(@TypeOf(c.ai_stream_next), @TypeOf(stream.ai_stream_next));
        assertAbiType(@TypeOf(c.ai_stream_cancel), @TypeOf(stream.ai_stream_cancel));
        assertAbiType(@TypeOf(c.ai_stream_last_error), @TypeOf(stream.ai_stream_last_error));
        assertAbiType(@TypeOf(c.ai_part_clone), @TypeOf(stream.ai_part_clone));
        assertAbiType(@TypeOf(c.ai_stream_destroy), @TypeOf(stream.ai_stream_destroy));
        assertAbiType(@TypeOf(c.ai_agent_create), @TypeOf(agent.ai_agent_create));
        assertAbiType(@TypeOf(c.ai_agent_run), @TypeOf(agent.ai_agent_run));
        assertAbiType(@TypeOf(c.ai_agent_stream), @TypeOf(agent.ai_agent_stream));
        assertAbiType(@TypeOf(c.ai_agent_destroy), @TypeOf(agent.ai_agent_destroy));
        assertAbiType(
            @TypeOf(c.ai_telemetry_register),
            @TypeOf(telemetry.ai_telemetry_register),
        );
        assertAbiType(
            @TypeOf(c.ai_telemetry_unregister),
            @TypeOf(telemetry.ai_telemetry_unregister),
        );
        assertAbiType(@TypeOf(c.ai_telemetry_clear), @TypeOf(telemetry.ai_telemetry_clear));
        assertAbiType(@TypeOf(c.ai_generate_image), @TypeOf(media.ai_generate_image));
        assertAbiType(@TypeOf(c.ai_generate_speech), @TypeOf(media.ai_generate_speech));
        assertAbiType(@TypeOf(c.ai_transcribe), @TypeOf(media.ai_transcribe));

        _ = options;
    }
}

fn assertFrozenNumericValues() void {
    assertInt(types.abi_version_major, 1);
    assertInt(types.abi_version_minor, 0);
    assertInt(types.abi_version_patch, 0);
    assertInt(types.abi_version, 0x01000000);

    inline for (.{
        .{ types.Status.ok, 0 },
        .{ types.Status.stream_done, 1 },
        .{ types.Status.invalid_argument, 10 },
        .{ types.Status.api_call, 20 },
        .{ types.Status.no_such_model, 30 },
        .{ types.Status.no_such_provider, 31 },
        .{ types.Status.load_api_key, 40 },
        .{ types.Status.load_setting, 41 },
        .{ types.Status.retry, 50 },
        .{ types.Status.canceled, 60 },
        .{ types.Status.timeout, 61 },
        .{ types.Status.out_of_memory, 70 },
        .{ types.Status.invalid_json, 80 },
        .{ types.Status.invalid_prompt, 81 },
        .{ types.Status.invalid_response, 82 },
        .{ types.Status.no_such_tool, 90 },
        .{ types.Status.tool_error, 91 },
        .{ types.Status.unsupported, 100 },
        .{ types.Status.unknown, -1 },
    }) |mapping| assertInt(@intFromEnum(mapping[0]), mapping[1]);

    inline for (.{
        .{ types.PartType.text_start, 0 },
        .{ types.PartType.text_end, 1 },
        .{ types.PartType.text_delta, 2 },
        .{ types.PartType.reasoning_start, 3 },
        .{ types.PartType.reasoning_end, 4 },
        .{ types.PartType.reasoning_delta, 5 },
        .{ types.PartType.custom, 6 },
        .{ types.PartType.tool_input_start, 7 },
        .{ types.PartType.tool_input_end, 8 },
        .{ types.PartType.tool_input_delta, 9 },
        .{ types.PartType.source, 10 },
        .{ types.PartType.file, 11 },
        .{ types.PartType.reasoning_file, 12 },
        .{ types.PartType.tool_call, 13 },
        .{ types.PartType.tool_result, 14 },
        .{ types.PartType.tool_error, 15 },
        .{ types.PartType.tool_output_denied, 16 },
        .{ types.PartType.tool_approval_request, 17 },
        .{ types.PartType.tool_approval_response, 18 },
        .{ types.PartType.start_step, 19 },
        .{ types.PartType.finish_step, 20 },
        .{ types.PartType.start, 21 },
        .{ types.PartType.finish, 22 },
        .{ types.PartType.abort, 23 },
        .{ types.PartType.err, 24 },
        .{ types.PartType.raw, 25 },
        .{ types.PartType.object, 26 },
        .{ types.PartType.ui_message, 27 },
        .{ types.PartType.unknown, -1 },
    }) |mapping| assertInt(@intFromEnum(mapping[0]), mapping[1]);

    assertInt(@intFromEnum(types.OpenAiLanguageApi.responses), 0);
    assertInt(@intFromEnum(types.OpenAiLanguageApi.chat), 1);
    assertInt(@intFromEnum(types.OpenAiLanguageApi.unknown), -1);
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
        .{ c.AI_PART_OBJECT, types.PartType.object },
        .{ c.AI_PART_UI_MESSAGE, types.PartType.ui_message },
        .{ c.AI_PART_UNKNOWN, types.PartType.unknown },
    }) |mapping| assertInt(mapping[0], @intFromEnum(mapping[1]));

    assertInt(c.AI_OPENAI_RESPONSES, @intFromEnum(types.OpenAiLanguageApi.responses));
    assertInt(c.AI_OPENAI_CHAT, @intFromEnum(types.OpenAiLanguageApi.chat));
    assertInt(c.AI_OPENAI_LANGUAGE_API_UNKNOWN, @intFromEnum(types.OpenAiLanguageApi.unknown));
}

fn assertFrozenLayouts() void {
    if (@sizeOf(usize) == 8) {
        assertLayout(types.ai_string, 16, 8, .{ .{ "ptr", 0 }, .{ "len", 8 } });
        assertLayout(types.ai_runtime_config, 24, 8, .{ .{ "struct_size", 0 }, .{ "async_limit", 8 }, .{ "concurrent_limit", 16 } });
        assertLayout(types.ai_anthropic_config, 40, 8, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 8 }, .{ "api_key_len", 16 }, .{ "base_url_ptr", 24 }, .{ "base_url_len", 32 } });
        assertLayout(types.ai_openrouter_config, 72, 8, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 8 }, .{ "api_key_len", 16 }, .{ "base_url_ptr", 24 }, .{ "base_url_len", 32 }, .{ "referer_ptr", 40 }, .{ "referer_len", 48 }, .{ "title_ptr", 56 }, .{ "title_len", 64 } });
        assertLayout(types.ai_openai_compatible_config, 56, 8, .{ .{ "struct_size", 0 }, .{ "name_ptr", 8 }, .{ "name_len", 16 }, .{ "base_url_ptr", 24 }, .{ "base_url_len", 32 }, .{ "api_key_ptr", 40 }, .{ "api_key_len", 48 } });
        assertLayout(types.ai_openai_config, 80, 8, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 8 }, .{ "api_key_len", 16 }, .{ "base_url_ptr", 24 }, .{ "base_url_len", 32 }, .{ "organization_ptr", 40 }, .{ "organization_len", 48 }, .{ "project_ptr", 56 }, .{ "project_len", 64 }, .{ "language_api", 72 } });
        assertLayout(types.ai_xai_config, 40, 8, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 8 }, .{ "api_key_len", 16 }, .{ "base_url_ptr", 24 }, .{ "base_url_len", 32 } });
        assertLayout(types.ai_tool_result, 24, 8, .{ .{ "struct_size", 0 }, .{ "ptr", 8 }, .{ "len", 16 } });
        assertLayout(types.ai_tool, 72, 8, .{ .{ "struct_size", 0 }, .{ "name_ptr", 8 }, .{ "name_len", 16 }, .{ "description_ptr", 24 }, .{ "description_len", 32 }, .{ "input_schema_json_ptr", 40 }, .{ "input_schema_json_len", 48 }, .{ "execute", 56 }, .{ "user_data", 64 } });
        assertLayout(types.ai_part, 48, 8, .{ .{ "struct_size", 0 }, .{ "type", 8 }, .{ "json_ptr", 16 }, .{ "json_len", 24 }, .{ "text_ptr", 32 }, .{ "text_len", 40 } });
        assertLayout(types.ai_buffer, 24, 8, .{ .{ "struct_size", 0 }, .{ "ptr", 8 }, .{ "len", 16 } });
        assertLayout(types.ai_agent_config, 48, 8, .{ .{ "struct_size", 0 }, .{ "tools", 8 }, .{ "tools_len", 16 }, .{ "system_ptr", 24 }, .{ "system_len", 32 }, .{ "max_steps", 40 } });
        assertLayout(types.ai_telemetry_vtable, 40, 8, .{ .{ "struct_size", 0 }, .{ "user_data", 8 }, .{ "on_event", 16 }, .{ "enter", 24 }, .{ "exit", 32 } });
    } else if (@sizeOf(usize) == 4) {
        assertLayout(types.ai_string, 8, 4, .{ .{ "ptr", 0 }, .{ "len", 4 } });
        assertLayout(types.ai_runtime_config, 12, 4, .{ .{ "struct_size", 0 }, .{ "async_limit", 4 }, .{ "concurrent_limit", 8 } });
        assertLayout(types.ai_anthropic_config, 20, 4, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 4 }, .{ "api_key_len", 8 }, .{ "base_url_ptr", 12 }, .{ "base_url_len", 16 } });
        assertLayout(types.ai_openrouter_config, 36, 4, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 4 }, .{ "api_key_len", 8 }, .{ "base_url_ptr", 12 }, .{ "base_url_len", 16 }, .{ "referer_ptr", 20 }, .{ "referer_len", 24 }, .{ "title_ptr", 28 }, .{ "title_len", 32 } });
        assertLayout(types.ai_openai_compatible_config, 28, 4, .{ .{ "struct_size", 0 }, .{ "name_ptr", 4 }, .{ "name_len", 8 }, .{ "base_url_ptr", 12 }, .{ "base_url_len", 16 }, .{ "api_key_ptr", 20 }, .{ "api_key_len", 24 } });
        assertLayout(types.ai_openai_config, 40, 4, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 4 }, .{ "api_key_len", 8 }, .{ "base_url_ptr", 12 }, .{ "base_url_len", 16 }, .{ "organization_ptr", 20 }, .{ "organization_len", 24 }, .{ "project_ptr", 28 }, .{ "project_len", 32 }, .{ "language_api", 36 } });
        assertLayout(types.ai_xai_config, 20, 4, .{ .{ "struct_size", 0 }, .{ "api_key_ptr", 4 }, .{ "api_key_len", 8 }, .{ "base_url_ptr", 12 }, .{ "base_url_len", 16 } });
        assertLayout(types.ai_tool_result, 12, 4, .{ .{ "struct_size", 0 }, .{ "ptr", 4 }, .{ "len", 8 } });
        assertLayout(types.ai_tool, 36, 4, .{ .{ "struct_size", 0 }, .{ "name_ptr", 4 }, .{ "name_len", 8 }, .{ "description_ptr", 12 }, .{ "description_len", 16 }, .{ "input_schema_json_ptr", 20 }, .{ "input_schema_json_len", 24 }, .{ "execute", 28 }, .{ "user_data", 32 } });
        assertLayout(types.ai_part, 24, 4, .{ .{ "struct_size", 0 }, .{ "type", 4 }, .{ "json_ptr", 8 }, .{ "json_len", 12 }, .{ "text_ptr", 16 }, .{ "text_len", 20 } });
        assertLayout(types.ai_buffer, 12, 4, .{ .{ "struct_size", 0 }, .{ "ptr", 4 }, .{ "len", 8 } });
        assertLayout(types.ai_agent_config, 24, 4, .{ .{ "struct_size", 0 }, .{ "tools", 4 }, .{ "tools_len", 8 }, .{ "system_ptr", 12 }, .{ "system_len", 16 }, .{ "max_steps", 20 } });
        assertLayout(types.ai_telemetry_vtable, 20, 4, .{ .{ "struct_size", 0 }, .{ "user_data", 4 }, .{ "on_event", 8 }, .{ "enter", 12 }, .{ "exit", 16 } });
    } else @compileError("unsupported pointer width for ABI lock");
}

fn assertLayout(
    comptime T: type,
    comptime expected_size: usize,
    comptime expected_alignment: usize,
    comptime offsets: anytype,
) void {
    if (@sizeOf(T) != expected_size or @alignOf(T) != expected_alignment) {
        @compileError("frozen ABI size/alignment drift: " ++ @typeName(T));
    }
    inline for (offsets) |entry| {
        if (@offsetOf(T, entry[0]) != entry[1]) {
            @compileError("frozen ABI field offset drift: " ++ @typeName(T) ++ "." ++ entry[0]);
        }
    }
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
