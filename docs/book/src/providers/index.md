# Providers

Providers implement the V4 provider specification consumed by the v7 core.
Constructing a provider chooses authentication, base URL, headers, and wire
behavior; constructing a model chooses a model id and surface. Model ids are
passed through to the provider and are not centrally validated against a
catalog.

## Surface overview

| Module | Language | Embedding | Other native surfaces |
| --- | --- | --- | --- |
| `anthropic` | Messages | — | provider tools and thinking |
| `openai` | Responses (default) and Chat Completions | yes | image, speech, transcription, realtime |
| `google` | native `generateContent` / SSE | yes | Google provider tools |
| `openai_compatible` | Chat Completions | configurable | generic embeddings and five presets |
| `openrouter` | OpenAI-compatible chat | OpenAI-compatible | attribution headers, routed ids |
| `xai` | OpenAI-compatible chat | — | native deferred-job video |

The repository status table is more precise than this capability sketch: it
separates fixture coverage, live evidence, C ABI exposure, and wrapper
coverage. In particular, the native Google module is implemented and tested
in Zig, while Google provider construction through C ABI v1—and therefore
through the Python and Rust wrappers—is still pending.

Every provider requires a `provider_utils.HttpTransport`; the usual choice is:

```zig
var transport = provider_utils.HttpClientTransport.init(gpa, io);
defer transport.deinit();
```

Provider settings accept explicit keys. Most also accept an injected
`provider_utils.EnvLookup`; this is not implicit process-environment access:

```zig
const env = provider_utils.EnvLookup.fromMap(init.environ_map);
const factory = openai.createOpenAi(.{
    .allocator = init.gpa,
    .env = env,
    .transport = transport.transport(),
});
```

Explicit settings win. Base URLs are resolved when the factory is created;
API keys are generally resolved at call time, allowing an injected lookup to
rotate values without reconstructing every model.

## Environment-name reference

These are all provider `*_API_KEY` and `*_BASE_URL` names read by current
source. They are consulted only through an explicitly supplied `EnvLookup`.

| Provider | API key lookup | Base URL lookup | Default base URL |
| --- | --- | --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` | `https://api.anthropic.com/v1` |
| OpenAI | `OPENAI_API_KEY` | `OPENAI_BASE_URL` | `https://api.openai.com/v1` |
| Google native | `GOOGLE_GENERATIVE_AI_API_KEY`, then `GOOGLE_API_KEY` | none; use `base_url` | `https://generativelanguage.googleapis.com/v1beta` |
| OpenRouter | `OPENROUTER_API_KEY` | `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` |
| xAI | `XAI_API_KEY` | `XAI_BASE_URL` | `https://api.x.ai/v1` |
| Groq preset | `GROQ_API_KEY` | `GROQ_BASE_URL` | `https://api.groq.com/openai/v1` |
| DeepSeek preset | `DEEPSEEK_API_KEY` | `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` |
| Mistral preset | `MISTRAL_API_KEY` | `MISTRAL_BASE_URL` | `https://api.mistral.ai/v1` |
| Together AI preset | `TOGETHER_API_KEY` | `TOGETHER_BASE_URL` | `https://api.together.xyz/v1` |
| Fireworks preset | `FIREWORKS_API_KEY` | `FIREWORKS_BASE_URL` | `https://api.fireworks.ai/inference/v1` |

Anthropic also recognizes `ANTHROPIC_AUTH_TOKEN` as an injected bearer-token
alternative; configuring both it and an API key is rejected. A generic
OpenAI-compatible factory derives `<PROVIDER_NAME>_API_KEY` when
`api_key_env_var` is absent, replacing non-alphanumeric characters with
underscores and uppercasing the name. Its base URL is always explicit.

## Explicit models versus bare ids

Constructing a provider and model, as every provider chapter demonstrates,
pins the request path. A bare `LanguageModelRef` string is different: the
built-in default resolver is OpenRouter when compiled in. It still sends no
request without an application-installed runtime and `OPENROUTER_API_KEY`
lookup. Configure that path with `ai.setDefaultRuntime` plus
`ai.setDefaultEnv`, install a custom provider with `ai.setDefaultProvider`, or
compile it out with `-Ddefault-openrouter=false`.

Every completed text step records the resolved provider name and model id.
For production code, explicit provider construction is the clearest way to
make credential and billing boundaries visible.

