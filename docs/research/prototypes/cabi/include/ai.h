#ifndef AI_H
#define AI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ai_runtime ai_runtime;

typedef enum ai_status {
    AI_OK = 0,
    AI_OUT_OF_MEMORY = 1,
    AI_INVALID_ARGUMENT = 2,
    AI_CANCELED = 3,
    AI_NETWORK = 4,
    AI_UNKNOWN = -1,
} ai_status;

typedef void (*ai_chunk_cb)(void *user_data, const unsigned char *chunk_ptr,
                            size_t chunk_len);

ai_status ai_runtime_create(ai_runtime **out);
void ai_runtime_destroy(ai_runtime *rt);

ai_status ai_echo_upper(ai_runtime *rt, const unsigned char *text_ptr,
                        size_t text_len, unsigned char **out_ptr,
                        size_t *out_len);
void ai_buf_free(unsigned char *ptr, size_t len);

const char *ai_status_name(ai_status status);

ai_status ai_stream_blocking(ai_runtime *rt, ai_chunk_cb cb, void *user_data);

#ifdef __cplusplus
}
#endif

#endif /* AI_H */
