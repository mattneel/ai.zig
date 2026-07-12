# Google Generative AI

The `google` module is a native Gemini provider. It calls
`generateContent`, `streamGenerateContent` over SSE, `embedContent`, and
`batchEmbedContents`; it does not translate through the OpenAI-compatible
Gemini endpoint.

## Construction and authentication

```zig
const factory = google.createGoogleGenerativeAi(.{
    .allocator = gpa,
    .api_key = api_key,
    .transport = transport.transport(),
});
var gemini = try factory.chat("gemini-2.5-flash", null);
```

`chat` and `languageModel` are aliases. `embedding` and `embeddingModel` are
aliases for the native embedding implementation. The default base URL is
`https://generativelanguage.googleapis.com/v1beta`; override it with the
explicit `base_url` setting. There is no Google base-URL environment-name
lookup in current code.

When `api_key` is absent, the injected environment lookup checks the
canonical `GOOGLE_GENERATIVE_AI_API_KEY` first, then accepts
`GOOGLE_API_KEY` as an ai.zig compatibility fallback. Authentication is sent
as `x-goog-api-key`.

The live native-wire smoke uses `gemini-2.5-flash`. Embedding tests use
`gemini-embedding-001`. A separate integration smoke exercises
`gemini-2.5-flash` through Google's OpenAI-compatible endpoint, but that is a
test of `openai_compatible`, not this native module.

## Native prompt and tools

The prompt converter maps system instructions, user/model turns, files,
function calls, function responses, and reasoning/thought metadata into
Gemini content. It supports function declarations plus Google provider tools
such as search, URL context, code execution, file search, enterprise search,
and Maps when the model-family checks allow them.

Function-tool modes map to `AUTO`, `NONE`, `ANY`, or `VALIDATED`; strict
functions and newer provider-tool combinations choose validated mode. Safety,
thinking, response modalities, service tier, cached content, labels, and
other native options live under the `google` provider-options namespace.

## Structured output and embeddings

JSON output sets `generationConfig.responseMimeType` to
`application/json`. When structured outputs are enabled (the default), the
provider converts the common JSON Schema into Google's supported
`responseSchema` subset. Unsupported schema keywords such as
`additionalProperties` are omitted during conversion. Set
`providerOptions.google.structuredOutputs` to false to keep JSON MIME mode
without sending a schema.

The embedding model advertises a maximum of 100 values per call and supports
parallel calls. `ai.embedMany` therefore batches at 100 and runs waves up to
the caller's `max_parallel_calls`, preserving input order.

## Exposure status

Native Google text, streaming, structured output, tools, and embeddings are
implemented and covered by module/integration tests; native Gemini also has a
dated live smoke. The C ABI v1 has no Google provider constructor yet. As a
result, Python and Rust wrappers do not expose this provider today. This is a
known pending breadth item, not an implied wrapper capability.

Use the Zig module directly until that ABI surface lands, and consult the
project [status table](https://github.com/mattneel/ai.zig#status) for the
current exposure matrix.

