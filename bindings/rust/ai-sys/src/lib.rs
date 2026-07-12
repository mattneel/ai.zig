//! Raw, hand-written declarations for the frozen ai.zig C ABI v1.
//!
//! The bindings are checked in intentionally: consumers do not need Clang or
//! bindgen, and review can compare this file directly with `include/ai.h`.

#![allow(non_camel_case_types, non_upper_case_globals)]

use core::ffi::{c_char, c_int, c_void};

pub const AI_ABI_VERSION_MAJOR: u32 = 1;
pub const AI_ABI_VERSION_MINOR: u32 = 0;
pub const AI_ABI_VERSION_PATCH: u32 = 0;
pub const AI_ABI_VERSION: u32 =
    (AI_ABI_VERSION_MAJOR << 24) | (AI_ABI_VERSION_MINOR << 16) | AI_ABI_VERSION_PATCH;

#[repr(C)]
pub struct ai_runtime {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_provider {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_model {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_embedding_model {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_image_model {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_speech_model {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_transcription_model {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_result {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_stream {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_agent {
    _private: [u8; 0],
}
#[repr(C)]
pub struct ai_telemetry_registration {
    _private: [u8; 0],
}

// C enums are represented as integer aliases so newer append-only values do
// not create an invalid Rust enum discriminant.
pub type ai_status = c_int;
pub const AI_OK: ai_status = 0;
pub const AI_STREAM_DONE: ai_status = 1;
pub const AI_INVALID_ARGUMENT: ai_status = 10;
pub const AI_API_CALL: ai_status = 20;
pub const AI_NO_SUCH_MODEL: ai_status = 30;
pub const AI_NO_SUCH_PROVIDER: ai_status = 31;
pub const AI_LOAD_API_KEY: ai_status = 40;
pub const AI_LOAD_SETTING: ai_status = 41;
pub const AI_RETRY: ai_status = 50;
pub const AI_CANCELED: ai_status = 60;
pub const AI_TIMEOUT: ai_status = 61;
pub const AI_OUT_OF_MEMORY: ai_status = 70;
pub const AI_INVALID_JSON: ai_status = 80;
pub const AI_INVALID_PROMPT: ai_status = 81;
pub const AI_INVALID_RESPONSE: ai_status = 82;
pub const AI_NO_SUCH_TOOL: ai_status = 90;
pub const AI_TOOL_ERROR: ai_status = 91;
pub const AI_UNSUPPORTED: ai_status = 100;
pub const AI_UNKNOWN: ai_status = -1;

pub type ai_part_type = c_int;
pub const AI_PART_TEXT_START: ai_part_type = 0;
pub const AI_PART_TEXT_END: ai_part_type = 1;
pub const AI_PART_TEXT_DELTA: ai_part_type = 2;
pub const AI_PART_REASONING_START: ai_part_type = 3;
pub const AI_PART_REASONING_END: ai_part_type = 4;
pub const AI_PART_REASONING_DELTA: ai_part_type = 5;
pub const AI_PART_CUSTOM: ai_part_type = 6;
pub const AI_PART_TOOL_INPUT_START: ai_part_type = 7;
pub const AI_PART_TOOL_INPUT_END: ai_part_type = 8;
pub const AI_PART_TOOL_INPUT_DELTA: ai_part_type = 9;
pub const AI_PART_SOURCE: ai_part_type = 10;
pub const AI_PART_FILE: ai_part_type = 11;
pub const AI_PART_REASONING_FILE: ai_part_type = 12;
pub const AI_PART_TOOL_CALL: ai_part_type = 13;
pub const AI_PART_TOOL_RESULT: ai_part_type = 14;
pub const AI_PART_TOOL_ERROR: ai_part_type = 15;
pub const AI_PART_TOOL_OUTPUT_DENIED: ai_part_type = 16;
pub const AI_PART_TOOL_APPROVAL_REQUEST: ai_part_type = 17;
pub const AI_PART_TOOL_APPROVAL_RESPONSE: ai_part_type = 18;
pub const AI_PART_START_STEP: ai_part_type = 19;
pub const AI_PART_FINISH_STEP: ai_part_type = 20;
pub const AI_PART_START: ai_part_type = 21;
pub const AI_PART_FINISH: ai_part_type = 22;
pub const AI_PART_ABORT: ai_part_type = 23;
pub const AI_PART_ERROR: ai_part_type = 24;
pub const AI_PART_RAW: ai_part_type = 25;
pub const AI_PART_OBJECT: ai_part_type = 26;
pub const AI_PART_UI_MESSAGE: ai_part_type = 27;
pub const AI_PART_UNKNOWN: ai_part_type = -1;

pub type ai_openai_language_api = c_int;
pub const AI_OPENAI_RESPONSES: ai_openai_language_api = 0;
pub const AI_OPENAI_CHAT: ai_openai_language_api = 1;
pub const AI_OPENAI_LANGUAGE_API_UNKNOWN: ai_openai_language_api = -1;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_string {
    pub ptr: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_runtime_config {
    pub struct_size: usize,
    pub async_limit: usize,
    pub concurrent_limit: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_anthropic_config {
    pub struct_size: usize,
    pub api_key_ptr: *const u8,
    pub api_key_len: usize,
    pub base_url_ptr: *const u8,
    pub base_url_len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_openrouter_config {
    pub struct_size: usize,
    pub api_key_ptr: *const u8,
    pub api_key_len: usize,
    pub base_url_ptr: *const u8,
    pub base_url_len: usize,
    pub referer_ptr: *const u8,
    pub referer_len: usize,
    pub title_ptr: *const u8,
    pub title_len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_openai_compatible_config {
    pub struct_size: usize,
    pub name_ptr: *const u8,
    pub name_len: usize,
    pub base_url_ptr: *const u8,
    pub base_url_len: usize,
    pub api_key_ptr: *const u8,
    pub api_key_len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_openai_config {
    pub struct_size: usize,
    pub api_key_ptr: *const u8,
    pub api_key_len: usize,
    pub base_url_ptr: *const u8,
    pub base_url_len: usize,
    pub organization_ptr: *const u8,
    pub organization_len: usize,
    pub project_ptr: *const u8,
    pub project_len: usize,
    pub language_api: ai_openai_language_api,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_xai_config {
    pub struct_size: usize,
    pub api_key_ptr: *const u8,
    pub api_key_len: usize,
    pub base_url_ptr: *const u8,
    pub base_url_len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_tool_result {
    pub struct_size: usize,
    pub ptr: *mut u8,
    pub len: usize,
}

pub type ai_tool_execute_fn = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        input_json: *const u8,
        input_len: usize,
        out: *mut ai_tool_result,
    ) -> ai_status,
>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_tool {
    pub struct_size: usize,
    pub name_ptr: *const u8,
    pub name_len: usize,
    pub description_ptr: *const u8,
    pub description_len: usize,
    pub input_schema_json_ptr: *const u8,
    pub input_schema_json_len: usize,
    pub execute: ai_tool_execute_fn,
    pub user_data: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_part {
    pub struct_size: usize,
    pub r#type: ai_part_type,
    pub json_ptr: *const u8,
    pub json_len: usize,
    pub text_ptr: *const u8,
    pub text_len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_buffer {
    pub struct_size: usize,
    pub ptr: *mut u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_agent_config {
    pub struct_size: usize,
    pub tools: *const ai_tool,
    pub tools_len: usize,
    pub system_ptr: *const u8,
    pub system_len: usize,
    pub max_steps: u32,
}

pub type ai_telemetry_event_fn = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        event_name: *const u8,
        event_name_len: usize,
        event_json: *const u8,
        event_json_len: usize,
    ),
>;
pub type ai_telemetry_enter_fn = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        scope_name: *const u8,
        scope_name_len: usize,
        call_id: *const u8,
        call_id_len: usize,
    ) -> *mut c_void,
>;
pub type ai_telemetry_exit_fn = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        scope_name: *const u8,
        scope_name_len: usize,
        token: *mut c_void,
    ),
>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ai_telemetry_vtable {
    pub struct_size: usize,
    pub user_data: *mut c_void,
    pub on_event: ai_telemetry_event_fn,
    pub enter: ai_telemetry_enter_fn,
    pub exit: ai_telemetry_exit_fn,
}

unsafe extern "C" {
    pub fn ai_abi_version() -> u32;
    pub fn ai_abi_version_string() -> ai_string;
    pub fn ai_status_name(status: ai_status) -> *const c_char;
    pub fn ai_alloc(len: usize) -> *mut u8;
    pub fn ai_buf_free(ptr: *const u8, len: usize);

    pub fn ai_runtime_create(
        config: *const ai_runtime_config,
        out: *mut *mut ai_runtime,
    ) -> ai_status;
    pub fn ai_runtime_destroy(runtime: *mut ai_runtime);
    pub fn ai_runtime_last_error(runtime: *const ai_runtime) -> ai_string;

    pub fn ai_provider_anthropic(
        runtime: *mut ai_runtime,
        config: *const ai_anthropic_config,
        out: *mut *mut ai_provider,
    ) -> ai_status;
    pub fn ai_provider_openrouter(
        runtime: *mut ai_runtime,
        config: *const ai_openrouter_config,
        out: *mut *mut ai_provider,
    ) -> ai_status;
    pub fn ai_provider_openai_compatible(
        runtime: *mut ai_runtime,
        config: *const ai_openai_compatible_config,
        out: *mut *mut ai_provider,
    ) -> ai_status;
    pub fn ai_provider_openai(
        runtime: *mut ai_runtime,
        config: *const ai_openai_config,
        out: *mut *mut ai_provider,
    ) -> ai_status;
    pub fn ai_provider_xai(
        runtime: *mut ai_runtime,
        config: *const ai_xai_config,
        out: *mut *mut ai_provider,
    ) -> ai_status;
    pub fn ai_provider_destroy(provider: *mut ai_provider);

    pub fn ai_provider_language_model(
        provider: *mut ai_provider,
        model_id: *const u8,
        model_id_len: usize,
        out: *mut *mut ai_model,
    ) -> ai_status;
    pub fn ai_model_destroy(model: *mut ai_model);
    pub fn ai_provider_embedding_model(
        provider: *mut ai_provider,
        model_id: *const u8,
        model_id_len: usize,
        out: *mut *mut ai_embedding_model,
    ) -> ai_status;
    pub fn ai_embedding_model_destroy(model: *mut ai_embedding_model);
    pub fn ai_provider_image_model(
        provider: *mut ai_provider,
        model_id: *const u8,
        model_id_len: usize,
        out: *mut *mut ai_image_model,
    ) -> ai_status;
    pub fn ai_image_model_destroy(model: *mut ai_image_model);
    pub fn ai_provider_speech_model(
        provider: *mut ai_provider,
        model_id: *const u8,
        model_id_len: usize,
        out: *mut *mut ai_speech_model,
    ) -> ai_status;
    pub fn ai_speech_model_destroy(model: *mut ai_speech_model);
    pub fn ai_provider_transcription_model(
        provider: *mut ai_provider,
        model_id: *const u8,
        model_id_len: usize,
        out: *mut *mut ai_transcription_model,
    ) -> ai_status;
    pub fn ai_transcription_model_destroy(model: *mut ai_transcription_model);

    pub fn ai_generate_text(
        runtime: *mut ai_runtime,
        model: *mut ai_model,
        options_json: *const u8,
        options_json_len: usize,
        tools: *const ai_tool,
        tools_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
    pub fn ai_generate_object(
        runtime: *mut ai_runtime,
        model: *mut ai_model,
        options_json: *const u8,
        options_json_len: usize,
        schema_json: *const u8,
        schema_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
    pub fn ai_embed(
        runtime: *mut ai_runtime,
        model: *mut ai_embedding_model,
        value: *const u8,
        value_len: usize,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
    pub fn ai_embed_many(
        runtime: *mut ai_runtime,
        model: *mut ai_embedding_model,
        values: *const ai_string,
        values_len: usize,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;

    pub fn ai_result_json(result: *const ai_result) -> ai_string;
    pub fn ai_result_text(result: *const ai_result) -> ai_string;
    pub fn ai_result_finish_reason(result: *const ai_result) -> ai_string;
    pub fn ai_result_total_tokens(result: *const ai_result) -> u64;
    pub fn ai_result_blob_count(result: *const ai_result) -> usize;
    pub fn ai_result_blob_media_type(result: *const ai_result, index: usize) -> ai_string;
    pub fn ai_result_blob(result: *const ai_result, index: usize, out: *mut ai_buffer)
    -> ai_status;
    pub fn ai_result_destroy(result: *mut ai_result);

    pub fn ai_stream_text(
        runtime: *mut ai_runtime,
        model: *mut ai_model,
        options_json: *const u8,
        options_json_len: usize,
        tools: *const ai_tool,
        tools_len: usize,
        out: *mut *mut ai_stream,
    ) -> ai_status;
    pub fn ai_stream_text_ui(
        runtime: *mut ai_runtime,
        model: *mut ai_model,
        options_json: *const u8,
        options_json_len: usize,
        tools: *const ai_tool,
        tools_len: usize,
        out: *mut *mut ai_stream,
    ) -> ai_status;
    pub fn ai_stream_object(
        runtime: *mut ai_runtime,
        model: *mut ai_model,
        options_json: *const u8,
        options_json_len: usize,
        schema_json: *const u8,
        schema_json_len: usize,
        out: *mut *mut ai_stream,
    ) -> ai_status;
    pub fn ai_stream_next(stream: *mut ai_stream, out: *mut ai_part) -> ai_status;
    pub fn ai_stream_cancel(stream: *mut ai_stream) -> ai_status;
    pub fn ai_stream_last_error(stream: *const ai_stream) -> ai_string;
    pub fn ai_part_clone(part: *const ai_part, out_json: *mut ai_string) -> ai_status;
    pub fn ai_stream_destroy(stream: *mut ai_stream);

    pub fn ai_agent_create(
        runtime: *mut ai_runtime,
        model: *mut ai_model,
        config: *const ai_agent_config,
        out: *mut *mut ai_agent,
    ) -> ai_status;
    pub fn ai_agent_run(
        agent: *mut ai_agent,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
    pub fn ai_agent_stream(
        agent: *mut ai_agent,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_stream,
    ) -> ai_status;
    pub fn ai_agent_destroy(agent: *mut ai_agent);

    pub fn ai_telemetry_register(
        runtime: *mut ai_runtime,
        callbacks: *const ai_telemetry_vtable,
        out: *mut *mut ai_telemetry_registration,
    ) -> ai_status;
    pub fn ai_telemetry_unregister(registration: *mut ai_telemetry_registration);
    pub fn ai_telemetry_clear();

    pub fn ai_generate_image(
        runtime: *mut ai_runtime,
        model: *mut ai_image_model,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
    pub fn ai_generate_speech(
        runtime: *mut ai_runtime,
        model: *mut ai_speech_model,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
    pub fn ai_transcribe(
        runtime: *mut ai_runtime,
        model: *mut ai_transcription_model,
        audio: *const u8,
        audio_len: usize,
        options_json: *const u8,
        options_json_len: usize,
        out: *mut *mut ai_result,
    ) -> ai_status;
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::mem::{align_of, size_of};

    #[test]
    fn frozen_value_and_prefix_layouts_match_v1() {
        assert_eq!(AI_ABI_VERSION, 0x0100_0000);
        assert_eq!(AI_TOOL_ERROR, 91);
        assert_eq!(AI_PART_UI_MESSAGE, 27);
        assert_eq!(size_of::<ai_string>(), size_of::<usize>() * 2);
        assert_eq!(align_of::<ai_runtime_config>(), align_of::<usize>());
        assert_eq!(size_of::<ai_runtime_config>(), size_of::<usize>() * 3);
    }
}
