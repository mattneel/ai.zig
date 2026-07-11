#include "ai.h"

#include <stddef.h>

_Static_assert(AI_ABI_VERSION == 0x01000000u, "ABI version packing drift");
_Static_assert(AI_OK == 0, "status drift");
_Static_assert(AI_PART_UI_MESSAGE == 27, "part tag drift");
_Static_assert(offsetof(ai_runtime_config, struct_size) == 0,
               "struct_size must remain first");

int main(void) {
    if (ai_abi_version() != AI_ABI_VERSION) return 1;
    ai_string version = ai_abi_version_string();
    if (version.len != 5) return 2;

    ai_runtime_config runtime_config = {0};
    runtime_config.struct_size = sizeof(runtime_config);
    ai_runtime *runtime = NULL;
    if (ai_runtime_create(&runtime_config, &runtime) != AI_OK) return 3;

    static const unsigned char key[] = "header-smoke-key";
    ai_openai_config openai = {0};
    openai.struct_size = sizeof(openai);
    openai.api_key_ptr = key;
    openai.api_key_len = sizeof(key) - 1;
    openai.language_api = AI_OPENAI_RESPONSES;
    ai_provider *provider = NULL;
    if (ai_provider_openai(runtime, &openai, &provider) != AI_OK) return 4;
    ai_provider_destroy(provider);
    ai_runtime_destroy(runtime);
    return 0;
}
