#ifndef AI_ZIG_AI_H
#define AI_ZIG_AI_H

#include <stddef.h>
#include <stdint.h>

/*
 * ai.zig C ABI v1
 *
 * ABI version packing is 8 bits major, 8 bits minor, 16 bits patch. Clients
 * should compare AI_ABI_VERSION_MAJOR with ai_abi_version() >> 24 before use.
 * The pre-v1 addition of struct_size to descriptors/configs is the only
 * intentional source break recorded by this first stable header.
 *
 * Struct evolution: callers set struct_size to sizeof(the struct). The
 * library rejects a value smaller than the v1 required prefix and accepts
 * larger values while ignoring the unknown tail. New optional fields append
 * at the end; fields are never inserted or reordered within an ABI major.
 * ai_string is the sole fixed, non-extensible value view because it is
 * returned by value; its two-word layout is frozen for the ABI major.
 *
 * Numeric freeze: every ai_status, ai_part_type, and public enum value is
 * permanent. New values append only. Values are never renumbered or reused.
 * Consumers must tolerate unknown newer values.
 *
 * ELF policy: the dynamic library SONAME is libai.so.<ABI major>; compatible
 * minor/patch releases retain the SONAME, and an ABI break increments both
 * AI_ABI_VERSION_MAJOR and the SONAME major. The dynamic library's public
 * namespace contains only symbols beginning with ai_. Mach-O/PE equivalents
 * follow the same ABI-major and symbol-prefix policy.
 */

#define AI_ABI_VERSION_MAJOR 1u
#define AI_ABI_VERSION_MINOR 0u
#define AI_ABI_VERSION_PATCH 0u
#define AI_ABI_VERSION_PACK(major, minor, patch) \
    ((((uint32_t)(major) & 0xffu) << 24) | \
     (((uint32_t)(minor) & 0xffu) << 16) | \
     ((uint32_t)(patch) & 0xffffu))
#define AI_ABI_VERSION \
    AI_ABI_VERSION_PACK(AI_ABI_VERSION_MAJOR, AI_ABI_VERSION_MINOR, \
                        AI_ABI_VERSION_PATCH)

#if defined(__GNUC__) || defined(__clang__)
#define AI_API __attribute__((visibility("default")))
#else
#define AI_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ai_runtime ai_runtime;
typedef struct ai_provider ai_provider;
typedef struct ai_model ai_model;
typedef struct ai_embedding_model ai_embedding_model;
typedef struct ai_image_model ai_image_model;
typedef struct ai_speech_model ai_speech_model;
typedef struct ai_transcription_model ai_transcription_model;
typedef struct ai_result ai_result;
typedef struct ai_stream ai_stream;
typedef struct ai_agent ai_agent;
typedef struct ai_telemetry_registration ai_telemetry_registration;

/** Frozen status values. Append-only; never renumber or reuse a value. */
typedef enum ai_status {
    AI_OK = 0,
    AI_STREAM_DONE = 1,
    AI_INVALID_ARGUMENT = 10,
    AI_API_CALL = 20,
    AI_NO_SUCH_MODEL = 30,
    AI_NO_SUCH_PROVIDER = 31,
    AI_LOAD_API_KEY = 40,
    AI_LOAD_SETTING = 41,
    AI_RETRY = 50,
    AI_CANCELED = 60,
    AI_TIMEOUT = 61,
    AI_OUT_OF_MEMORY = 70,
    AI_INVALID_JSON = 80,
    AI_INVALID_PROMPT = 81,
    AI_INVALID_RESPONSE = 82,
    AI_NO_SUCH_TOOL = 90,
    AI_TOOL_ERROR = 91,
    AI_UNSUPPORTED = 100,
    AI_UNKNOWN = -1
} ai_status;

/** Frozen stream-part tags. Append-only; never renumber or reuse a value. */
typedef enum ai_part_type {
    AI_PART_TEXT_START = 0,
    AI_PART_TEXT_END = 1,
    AI_PART_TEXT_DELTA = 2,
    AI_PART_REASONING_START = 3,
    AI_PART_REASONING_END = 4,
    AI_PART_REASONING_DELTA = 5,
    AI_PART_CUSTOM = 6,
    AI_PART_TOOL_INPUT_START = 7,
    AI_PART_TOOL_INPUT_END = 8,
    AI_PART_TOOL_INPUT_DELTA = 9,
    AI_PART_SOURCE = 10,
    AI_PART_FILE = 11,
    AI_PART_REASONING_FILE = 12,
    AI_PART_TOOL_CALL = 13,
    AI_PART_TOOL_RESULT = 14,
    AI_PART_TOOL_ERROR = 15,
    AI_PART_TOOL_OUTPUT_DENIED = 16,
    AI_PART_TOOL_APPROVAL_REQUEST = 17,
    AI_PART_TOOL_APPROVAL_RESPONSE = 18,
    AI_PART_START_STEP = 19,
    AI_PART_FINISH_STEP = 20,
    AI_PART_START = 21,
    AI_PART_FINISH = 22,
    AI_PART_ABORT = 23,
    AI_PART_ERROR = 24,
    AI_PART_RAW = 25,
    AI_PART_OBJECT = 26,
    AI_PART_UI_MESSAGE = 27,
    AI_PART_UNKNOWN = -1
} ai_part_type;

/** Native OpenAI language endpoint selection. Values are frozen. */
typedef enum ai_openai_language_api {
    AI_OPENAI_RESPONSES = 0,
    AI_OPENAI_CHAT = 1,
    AI_OPENAI_LANGUAGE_API_UNKNOWN = -1
} ai_openai_language_api;

/** Frozen two-word borrowed byte view. The producing function owns storage. */
typedef struct ai_string {
    const unsigned char *ptr;
    size_t len;
} ai_string;

typedef struct ai_runtime_config {
    size_t struct_size;
    size_t async_limit;
    size_t concurrent_limit;
} ai_runtime_config;

typedef struct ai_anthropic_config {
    size_t struct_size;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
} ai_anthropic_config;

typedef struct ai_openrouter_config {
    size_t struct_size;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
    const unsigned char *referer_ptr;
    size_t referer_len;
    const unsigned char *title_ptr;
    size_t title_len;
} ai_openrouter_config;

typedef struct ai_openai_compatible_config {
    size_t struct_size;
    const unsigned char *name_ptr;
    size_t name_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
} ai_openai_compatible_config;

typedef struct ai_openai_config {
    size_t struct_size;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
    const unsigned char *organization_ptr;
    size_t organization_len;
    const unsigned char *project_ptr;
    size_t project_len;
    ai_openai_language_api language_api;
} ai_openai_config;

typedef struct ai_xai_config {
    size_t struct_size;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
} ai_xai_config;

/**
 * Callback-owned output. The SDK sets struct_size; do not write beyond that
 * reported prefix. Allocate ptr with ai_alloc; the SDK frees it.
 */
typedef struct ai_tool_result {
    size_t struct_size;
    unsigned char *ptr;
    size_t len;
} ai_tool_result;

typedef ai_status (*ai_tool_execute_fn)(void *user_data,
                                        const unsigned char *input_json,
                                        size_t input_len,
                                        ai_tool_result *out);

/**
 * Tool strings and user_data must remain valid for an agent lifetime or the
 * enclosing direct call/stream. execute may run concurrently on runtime pool
 * threads. The SDK initializes out->struct_size before invoking execute.
 */
typedef struct ai_tool {
    size_t struct_size;
    const unsigned char *name_ptr;
    size_t name_len;
    const unsigned char *description_ptr;
    size_t description_len;
    const unsigned char *input_schema_json_ptr;
    size_t input_schema_json_len;
    ai_tool_execute_fn execute;
    void *user_data;
} ai_tool;

/** Borrowed stream part, valid until the next call on that stream/destroy. */
typedef struct ai_part {
    size_t struct_size;
    ai_part_type type;
    const unsigned char *json_ptr;
    size_t json_len;
    const unsigned char *text_ptr;
    size_t text_len;
} ai_part;

/** Library-owned bytes returned by ai_result_blob; free with ai_buf_free. */
typedef struct ai_buffer {
    size_t struct_size;
    unsigned char *ptr;
    size_t len;
} ai_buffer;

typedef struct ai_agent_config {
    size_t struct_size;
    const ai_tool *tools;
    size_t tools_len;
    const unsigned char *system_ptr;
    size_t system_len;
    uint32_t max_steps;
} ai_agent_config;

/** Event/scope byte views are borrowed only for the callback invocation. */
typedef void (*ai_telemetry_event_fn)(void *user_data,
                                      const unsigned char *event_name,
                                      size_t event_name_len,
                                      const unsigned char *event_json,
                                      size_t event_json_len);
typedef void *(*ai_telemetry_enter_fn)(void *user_data,
                                       const unsigned char *scope_name,
                                       size_t scope_name_len,
                                       const unsigned char *call_id,
                                       size_t call_id_len);
typedef void (*ai_telemetry_exit_fn)(void *user_data,
                                     const unsigned char *scope_name,
                                     size_t scope_name_len, void *token);

/**
 * Borrowed callbacks/user_data remain valid until ai_telemetry_clear. An
 * enter token is client-owned and is returned unchanged to the paired exit.
 */
typedef struct ai_telemetry_vtable {
    size_t struct_size;
    void *user_data;
    ai_telemetry_event_fn on_event;
    ai_telemetry_enter_fn enter;
    ai_telemetry_exit_fn exit;
} ai_telemetry_vtable;

AI_API uint32_t ai_abi_version(void);
AI_API ai_string ai_abi_version_string(void);
AI_API const char *ai_status_name(ai_status status);
AI_API unsigned char *ai_alloc(size_t len);
AI_API void ai_buf_free(const unsigned char *ptr, size_t len);

/**
 * Creates a blocking std.Io.Threaded runtime. Zero limits select Zig defaults.
 * The runtime changes process-wide SIGIO/SIGPIPE handlers until final release.
 * Child handles retain it, so caller destroy order is flexible.
 */
AI_API ai_status ai_runtime_create(const ai_runtime_config *config,
                                   ai_runtime **out);
AI_API void ai_runtime_destroy(ai_runtime *runtime);
/** Borrowed until the next failing runtime call or final runtime release. */
AI_API ai_string ai_runtime_last_error(const ai_runtime *runtime);

AI_API ai_status ai_provider_anthropic(ai_runtime *runtime,
                                       const ai_anthropic_config *config,
                                       ai_provider **out);
AI_API ai_status ai_provider_openrouter(ai_runtime *runtime,
                                        const ai_openrouter_config *config,
                                        ai_provider **out);
AI_API ai_status ai_provider_openai_compatible(
    ai_runtime *runtime, const ai_openai_compatible_config *config,
    ai_provider **out);
AI_API ai_status ai_provider_openai(ai_runtime *runtime,
                                    const ai_openai_config *config,
                                    ai_provider **out);
AI_API ai_status ai_provider_xai(ai_runtime *runtime,
                                 const ai_xai_config *config,
                                 ai_provider **out);
AI_API void ai_provider_destroy(ai_provider *provider);

AI_API ai_status ai_provider_language_model(ai_provider *provider,
                                            const unsigned char *model_id,
                                            size_t model_id_len,
                                            ai_model **out);
AI_API void ai_model_destroy(ai_model *model);
AI_API ai_status ai_provider_embedding_model(ai_provider *provider,
                                             const unsigned char *model_id,
                                             size_t model_id_len,
                                             ai_embedding_model **out);
AI_API void ai_embedding_model_destroy(ai_embedding_model *model);
AI_API ai_status ai_provider_image_model(ai_provider *provider,
                                         const unsigned char *model_id,
                                         size_t model_id_len,
                                         ai_image_model **out);
AI_API void ai_image_model_destroy(ai_image_model *model);
AI_API ai_status ai_provider_speech_model(ai_provider *provider,
                                          const unsigned char *model_id,
                                          size_t model_id_len,
                                          ai_speech_model **out);
AI_API void ai_speech_model_destroy(ai_speech_model *model);
AI_API ai_status ai_provider_transcription_model(
    ai_provider *provider, const unsigned char *model_id, size_t model_id_len,
    ai_transcription_model **out);
AI_API void ai_transcription_model_destroy(ai_transcription_model *model);

AI_API ai_status ai_generate_text(ai_runtime *runtime, ai_model *model,
                                  const unsigned char *options_json,
                                  size_t options_json_len,
                                  const ai_tool *tools, size_t tools_len,
                                  ai_result **out);
/**
 * schema_json is a raw JSON Schema document forwarded to the provider. The
 * FFI validates schema syntax and generated JSON/object shape; it has no host
 * schema-validator callback, so semantic JSON-Schema validation belongs in
 * the language wrapper/application. ai_result_json contains the object and
 * generation metadata.
 */
AI_API ai_status ai_generate_object(ai_runtime *runtime, ai_model *model,
                                    const unsigned char *options_json,
                                    size_t options_json_len,
                                    const unsigned char *schema_json,
                                    size_t schema_json_len, ai_result **out);
/** Embedding result JSON contains values, vectors, usage, and metadata. */
AI_API ai_status ai_embed(ai_runtime *runtime, ai_embedding_model *model,
                          const unsigned char *value, size_t value_len,
                          const unsigned char *options_json,
                          size_t options_json_len, ai_result **out);
AI_API ai_status ai_embed_many(ai_runtime *runtime, ai_embedding_model *model,
                               const ai_string *values, size_t values_len,
                               const unsigned char *options_json,
                               size_t options_json_len, ai_result **out);

/** Result getters borrow storage until ai_result_destroy. */
AI_API ai_string ai_result_json(const ai_result *result);
AI_API ai_string ai_result_text(const ai_result *result);
AI_API ai_string ai_result_finish_reason(const ai_result *result);
AI_API uint64_t ai_result_total_tokens(const ai_result *result);
AI_API size_t ai_result_blob_count(const ai_result *result);
AI_API ai_string ai_result_blob_media_type(const ai_result *result,
                                           size_t index);
AI_API ai_status ai_result_blob(const ai_result *result, size_t index,
                                ai_buffer *out);
AI_API void ai_result_destroy(ai_result *result);

AI_API ai_status ai_stream_text(ai_runtime *runtime, ai_model *model,
                                const unsigned char *options_json,
                                size_t options_json_len,
                                const ai_tool *tools, size_t tools_len,
                                ai_stream **out);
/** Same model call, converted through the core UI-message chunk adapter. */
AI_API ai_status ai_stream_text_ui(ai_runtime *runtime, ai_model *model,
                                   const unsigned char *options_json,
                                   size_t options_json_len,
                                   const ai_tool *tools, size_t tools_len,
                                   ai_stream **out);
AI_API ai_status ai_stream_object(ai_runtime *runtime, ai_model *model,
                                  const unsigned char *options_json,
                                  size_t options_json_len,
                                  const unsigned char *schema_json,
                                  size_t schema_json_len, ai_stream **out);
/** Set out->struct_size before every call. Only one concurrent next is valid. */
AI_API ai_status ai_stream_next(ai_stream *stream, ai_part *out);
/** Thread-safe and intended to race a blocked ai_stream_next. */
AI_API ai_status ai_stream_cancel(ai_stream *stream);
AI_API ai_string ai_stream_last_error(const ai_stream *stream);
/** Clones part JSON; free out_json->ptr/out_json->len with ai_buf_free. */
AI_API ai_status ai_part_clone(const ai_part *part, ai_string *out_json);
/** Must not race next; cancel, join the consumer, then destroy. */
AI_API void ai_stream_destroy(ai_stream *stream);

AI_API ai_status ai_agent_create(ai_runtime *runtime, ai_model *model,
                                 const ai_agent_config *config,
                                 ai_agent **out);
AI_API ai_status ai_agent_run(ai_agent *agent,
                              const unsigned char *options_json,
                              size_t options_json_len, ai_result **out);
AI_API ai_status ai_agent_stream(ai_agent *agent,
                                 const unsigned char *options_json,
                                 size_t options_json_len, ai_stream **out);
AI_API void ai_agent_destroy(ai_agent *agent);

AI_API ai_status ai_telemetry_register(
    ai_runtime *runtime, const ai_telemetry_vtable *callbacks,
    ai_telemetry_registration **out);
/** Logical, thread-safe disable; storage is reclaimed by ai_telemetry_clear. */
AI_API void ai_telemetry_unregister(ai_telemetry_registration *registration);
/** Do not race register/unregister; call after copied dispatchers quiesce. */
AI_API void ai_telemetry_clear(void);

/** Metadata is JSON; generated image bytes are indexed result blobs. */
AI_API ai_status ai_generate_image(ai_runtime *runtime, ai_image_model *model,
                                   const unsigned char *options_json,
                                   size_t options_json_len, ai_result **out);
/** Metadata is JSON; generated audio bytes are an indexed result blob. */
AI_API ai_status ai_generate_speech(ai_runtime *runtime,
                                    ai_speech_model *model,
                                    const unsigned char *options_json,
                                    size_t options_json_len, ai_result **out);
/** audio is borrowed only for this blocking call. */
AI_API ai_status ai_transcribe(ai_runtime *runtime,
                               ai_transcription_model *model,
                               const unsigned char *audio, size_t audio_len,
                               const unsigned char *options_json,
                               size_t options_json_len, ai_result **out);

#ifdef __cplusplus
}
#endif

#endif /* AI_ZIG_AI_H */
