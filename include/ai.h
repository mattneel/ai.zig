#ifndef AI_ZIG_AI_H
#define AI_ZIG_AI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ai_runtime ai_runtime;
typedef struct ai_provider ai_provider;
typedef struct ai_model ai_model;
typedef struct ai_result ai_result;
typedef struct ai_stream ai_stream;

/** Stable status values. New values may be added without renumbering v0. */
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

/** Public stream-part tags, in the same order as Zig TextStreamPart. */
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
    AI_PART_UNKNOWN = -1
} ai_part_type;

/** Borrowed byte string. The owning function documents its lifetime. */
typedef struct ai_string {
    const unsigned char *ptr;
    size_t len;
} ai_string;

/** Runtime thread-pool limits. Zero selects the std.Io.Threaded default. */
typedef struct ai_runtime_config {
    size_t async_limit;
    size_t concurrent_limit;
} ai_runtime_config;

typedef struct ai_anthropic_config {
    const unsigned char *api_key_ptr;
    size_t api_key_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
} ai_anthropic_config;

typedef struct ai_openrouter_config {
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
    const unsigned char *name_ptr;
    size_t name_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
} ai_openai_compatible_config;

/** Callback-owned output. Allocate ptr with ai_alloc; the SDK frees it. */
typedef struct ai_tool_result {
    unsigned char *ptr;
    size_t len;
} ai_tool_result;

typedef ai_status (*ai_tool_execute_fn)(void *user_data,
                                        const unsigned char *input_json,
                                        size_t input_len,
                                        ai_tool_result *out);

/**
 * Function tool descriptor. All input strings and user_data must remain valid
 * for the enclosing generate call or stream lifetime. execute runs on an
 * std.Io.Threaded pool thread; language runtimes must attach that thread as
 * required (ctypes CFUNCTYPE acquires Python's GIL automatically).
 */
typedef struct ai_tool {
    const unsigned char *name_ptr;
    size_t name_len;
    const unsigned char *description_ptr;
    size_t description_len;
    const unsigned char *input_schema_json_ptr;
    size_t input_schema_json_len;
    ai_tool_execute_fn execute;
    void *user_data;
} ai_tool;

/** Borrowed stream part, valid until the next ai_stream_next or destroy. */
typedef struct ai_part {
    ai_part_type type;
    const unsigned char *json_ptr;
    size_t json_len;
    const unsigned char *text_ptr;
    size_t text_len;
} ai_part;

/** Returns a static lowercase name; unknown integer values return "unknown". */
const char *ai_status_name(ai_status status);

/** Library allocator for callback result buffers. Pair with ai_buf_free. */
unsigned char *ai_alloc(size_t len);

/** Frees a buffer allocated by ai_alloc or a cloning output function. */
void ai_buf_free(const unsigned char *ptr, size_t len);

/**
 * Creates a blocking FFI runtime over std.Io.Threaded. The runtime changes the
 * process-wide SIGIO and SIGPIPE handlers until its last child is destroyed.
 * Debug builds use a thread-safe Zig DebugAllocator (and report leaks at final
 * teardown); optimized builds use smp_allocator. Boundary buffers always use
 * the libc-compatible allocator exposed by ai_alloc/ai_buf_free.
 * It must outlive direct use of every child handle. Panics abort the host, so
 * exported entry points validate inputs and translate recoverable errors.
 */
ai_status ai_runtime_create(const ai_runtime_config *config, ai_runtime **out);

/** Releases the caller's runtime reference. Child handles retain it safely. */
void ai_runtime_destroy(ai_runtime *runtime);

/** Borrowed JSON error document, valid until the next failing runtime call. */
ai_string ai_runtime_last_error(const ai_runtime *runtime);

/** Creates an Anthropic provider. API keys are explicit; no environment read. */
ai_status ai_provider_anthropic(ai_runtime *runtime,
                                const ai_anthropic_config *config,
                                ai_provider **out);

/** Creates an OpenRouter provider. API keys are explicit; no environment read. */
ai_status ai_provider_openrouter(ai_runtime *runtime,
                                 const ai_openrouter_config *config,
                                 ai_provider **out);

/** Creates a generic OpenAI-compatible provider. api_key may be null/empty. */
ai_status ai_provider_openai_compatible(
    ai_runtime *runtime, const ai_openai_compatible_config *config,
    ai_provider **out);

/** Releases a provider reference. Models retain their provider. */
void ai_provider_destroy(ai_provider *provider);

/** Creates a language model. The model id is copied by the library. */
ai_status ai_provider_language_model(ai_provider *provider,
                                     const unsigned char *model_id,
                                     size_t model_id_len, ai_model **out);

/** Releases a language-model reference. Active streams retain their model. */
void ai_model_destroy(ai_model *model);

/**
 * Runs generateText. options_json uses canonical camelCase wire names; prompt
 * is a string or messages is the canonical ModelMessage array. maxSteps maps
 * to the SDK step-count stop condition. The returned result owns all getters.
 */
ai_status ai_generate_text(ai_runtime *runtime, ai_model *model,
                           const unsigned char *options_json,
                           size_t options_json_len, const ai_tool *tools,
                           size_t tools_len, ai_result **out);

/** Borrowed canonical GenerateTextResult JSON; valid until result destroy. */
ai_string ai_result_json(const ai_result *result);

/** Borrowed final text; valid until result destroy. */
ai_string ai_result_text(const ai_result *result);

/** Borrowed unified finish-reason string; valid until result destroy. */
ai_string ai_result_finish_reason(const ai_result *result);

/** Sum of known input and output tokens; missing counts contribute zero. */
uint64_t ai_result_total_tokens(const ai_result *result);

/** Releases the result and all borrowed strings returned from it. */
void ai_result_destroy(ai_result *result);

/** Starts streamText on the runtime pool and returns a pull iterator handle. */
ai_status ai_stream_text(ai_runtime *runtime, ai_model *model,
                         const unsigned char *options_json,
                         size_t options_json_len, const ai_tool *tools,
                         size_t tools_len, ai_stream **out);

/**
 * Blocks for one part. AI_OK fills out, AI_STREAM_DONE is normal EOF, and
 * other statuses describe failure. out fields borrow stream scratch storage.
 * Only one consumer may call ai_stream_next at a time.
 */
ai_status ai_stream_next(ai_stream *stream, ai_part *out);

/** Requests cancellation from any foreign thread and waits for quiescence. */
ai_status ai_stream_cancel(ai_stream *stream);

/** Borrowed JSON error document, valid until the next failing stream call. */
ai_string ai_stream_last_error(const ai_stream *stream);

/** Clones part->json_ptr/json_len with ai_alloc; pair with ai_buf_free. */
ai_status ai_part_clone(const ai_part *part, ai_string *out_json);

/** Cancels if needed, joins the producer, and releases the stream. */
void ai_stream_destroy(ai_stream *stream);

#ifdef __cplusplus
}
#endif

#endif /* AI_ZIG_AI_H */
