# OpenAI

The native OpenAI package contains distinct Responses and Chat Completions
language implementations plus embeddings, image generation, speech,
transcription, and realtime models. The distinction is explicit in the
factory API and preserved in provider names and request mapping.

## Responses versus Chat

```zig
var factory = openai.createOpenAi(.{
    .allocator = gpa,
    .api_key = api_key,
    .transport = transport.transport(),
});

var responses = try factory.responses("gpt-4o-mini", null);
var chat = try factory.chat("gpt-4o-mini", null);
```

`factory.languageModel(...)` is an alias for `responses(...)`, matching the
upstream default. `providerAdapter(...).languageModel(...)` also routes to the
Responses API. Choose `chat(...)` when the target is specifically
Chat Completions-compatible.

Responses uses item-shaped input/output, reasoning summary lifecycle parts,
provider tool mapping, and item-reference optimization across steps. Chat
uses message-shaped `/chat/completions` requests and the indexed tool-call
delta tracker. Both expose the same provider `LanguageModel` interface to the
core.

The factory recognizes `OPENAI_API_KEY` and `OPENAI_BASE_URL` through an
injected `EnvLookup`; explicit settings win. It also supports organization,
project, custom headers, a custom provider name, and an injectable WebSocket
factory. API keys are resolved at call time.

## Other model factories

```zig
var embedding = try factory.embeddingModel("text-embedding-3-small", null);
var image = try factory.imageModel("gpt-image-1", null);
var speech = try factory.speechModel("gpt-4o-mini-tts", null);
var transcription = try factory.transcriptionModel(
    "gpt-4o-mini-transcribe",
    null,
);
var realtime = try factory.realtimeModel("gpt-realtime", null);
```

The exact ids above appear in repository tests or live smokes. Realtime
transcription fixtures also use `gpt-realtime-whisper`. See [Media](../media.md)
and [Realtime & WebSocket](../realtime.md) for orchestration semantics.

## Structured output

Chat writes a JSON schema under `response_format.json_schema`; Responses
writes it under `text.format`. Both carry the requested name/description and
the OpenAI `strictJsonSchema` option, which defaults to true. Schema-free JSON
requests use the provider's JSON-object mode.

OpenAI option parsing is endpoint-specific. Unsupported combinations—such as
reasoning-model sampling parameters or unavailable service tiers—are removed
with typed warnings. Function and provider-defined tool support also differs
between Chat and Responses, so choose the endpoint before supplying
provider-specific options.

## C ABI endpoint selection

`ai_openai_config.language_api` is a frozen enum with
`AI_OPENAI_RESPONSES` and `AI_OPENAI_CHAT`. The native C constructor stores
that selection in the provider handle, and the Python `openai(...,
language_api="chat")` helper exposes it. Rust uses `OpenAiLanguageApi`.

The live suite separately exercises Chat, Responses, a Responses tool agent,
realtime WebSocket behavior, and a speech-to-transcription round trip. Image
generation stays cost-gated in live tests and is covered by canned wire
fixtures.

