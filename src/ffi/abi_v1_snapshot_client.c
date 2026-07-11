/*
 * Frozen ABI-v1 client fixture. Intentionally does not include ai.h: this is
 * an old-client source snapshot compiled and linked against the new library.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct ai_runtime ai_runtime;
typedef struct ai_provider ai_provider;
typedef int ai_status;
enum { AI_V1_OK = 0, AI_V1_OPENAI_RESPONSES = 0 };

typedef struct ai_runtime_config_v1 {
    size_t struct_size;
    size_t async_limit;
    size_t concurrent_limit;
} ai_runtime_config_v1;

typedef struct ai_openai_config_v1 {
    size_t struct_size;
    const unsigned char *api_key_ptr;
    size_t api_key_len;
    const unsigned char *base_url_ptr;
    size_t base_url_len;
    const unsigned char *organization_ptr;
    size_t organization_len;
    const unsigned char *project_ptr;
    size_t project_len;
    int language_api;
} ai_openai_config_v1;

extern uint32_t ai_abi_version(void);
extern ai_status ai_runtime_create(const ai_runtime_config_v1 *, ai_runtime **);
extern void ai_runtime_destroy(ai_runtime *);
extern ai_status ai_provider_openai(ai_runtime *, const ai_openai_config_v1 *,
                                    ai_provider **);
extern void ai_provider_destroy(ai_provider *);

int main(void) {
    if (ai_abi_version() != 0x01000000u) return 1;
    ai_runtime_config_v1 config = {sizeof(config), 0, 0};
    ai_runtime *runtime = NULL;
    if (ai_runtime_create(&config, &runtime) != AI_V1_OK) return 2;
    static const unsigned char key[] = "v1-snapshot-key";
    ai_openai_config_v1 openai = {0};
    openai.struct_size = sizeof(openai);
    openai.api_key_ptr = key;
    openai.api_key_len = sizeof(key) - 1;
    openai.language_api = AI_V1_OPENAI_RESPONSES;
    ai_provider *provider = NULL;
    if (ai_provider_openai(runtime, &openai, &provider) != AI_V1_OK) return 3;
    ai_provider_destroy(provider);
    ai_runtime_destroy(runtime);
    return 0;
}
