# OpenAI-compatible

`openai_compatible` is the reusable Chat Completions and embeddings template
for local servers and vendors with OpenAI-shaped APIs. It keeps vendor quirks
explicit instead of assuming every nominally compatible endpoint implements
the same options.

## Generic factory

```zig
const factory = openai_compatible.createOpenAiCompatible(.{
    .provider_name = "local.chat",
    .base_url = "http://127.0.0.1:8000/v1",
    .api_key = "explicit-key",
    .transport = transport.transport(),
    .include_usage = true,
    .supports_structured_outputs = true,
});
var chat = try factory.chatModel("vendor/model", null);
```

`provider_name`, `base_url`, and `transport` are required. A local server can
omit authentication. If `api_key` is absent and an `EnvLookup` is supplied,
`api_key_env_var` selects the name; otherwise the factory derives an uppercase
`<PROVIDER_NAME>_API_KEY` name.

The provider supports static/dynamic headers, default vendor headers, query
parameters, a user-agent suffix, optional streaming usage, strict-schema
defaults, embedding limits/parallelism, and custom error-message/retryability
hooks. Unknown namespaced provider options are spread into the request body
after standardized settings as a deliberate vendor escape hatch.

Tests use `vendor/model` for request/stream mappings and `fixture-chat` /
`fixture-embedding` for the preset conformance loop. Those are fixture ids,
not recommendations for a public vendor.

## Included vendor presets

The table below is generated conceptually from the checked-in
`vendors.table`; the factory tests iterate every row.

| Preset | Default base URL | Chat | Embeddings | Structured output | Notable quirks |
| --- | --- | --- | --- | --- | --- |
| Groq | `https://api.groq.com/openai/v1` | yes | no | yes | standard usage behavior |
| DeepSeek | `https://api.deepseek.com` | yes | no | no | include stream usage |
| Mistral | `https://api.mistral.ai/v1` | yes | yes | yes | strict schema defaults false; 32 embeddings/call; serial chunks |
| Together AI | `https://api.together.xyz/v1` | yes | yes | no | generic embedding defaults |
| Fireworks | `https://api.fireworks.ai/inference/v1` | yes | yes | no | include stream usage; vendor error extractor |

Constructors are `createGroq`, `createDeepSeek`, `createMistral`,
`createTogetherAi` (plus `createTogetherAI` alias), and `createFireworks`.
Each uses the key/base names listed in the [provider overview](index.md#environment-name-reference).

## Structured output behavior

When `supports_structured_outputs` is true and a schema is present, the chat
request uses `response_format.type = "json_schema"` with schema, name,
description, and the resolved strict flag. Otherwise it emits a typed warning
for the unsupported schema and falls back to `json_object` mode.

Compatibility is asserted at the wire layer by canned HTTP/SSE fixtures:
authorization, query encoding, reasoning-content deltas, buffered indexed
tool-call deltas, request option namespaces, response metadata, finish reason,
and usage mapping. A preset flag is not a live guarantee about every model a
vendor may expose.

The C ABI, Python, and Rust wrappers expose the generic factory. The five Zig
presets are currently a Zig convenience surface rather than five separate C
constructors.

