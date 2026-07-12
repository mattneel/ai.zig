# OpenRouter

OpenRouter is a thin, explicit wrapper over `openai_compatible`. It supplies
the OpenRouter base URL, API-key name, structured-output support, optional
usage streaming, and attribution headers while preserving routed model ids
verbatim.

## Explicit construction

```zig
var router = openrouter.createOpenRouter(.{
    .api_key = api_key,
    .transport = transport.transport(),
    .http_referer = "https://example.com",
    .x_title = "Example application",
    .include_usage = true,
});
var chat = try router.chatModel("openai/gpt-4o-mini", null);
```

The dated live provider smoke uses `openai/gpt-4o-mini`. Unit tests also use
`vendor/model` to verify that the wrapper does not rewrite ids.

`OPENROUTER_API_KEY` and `OPENROUTER_BASE_URL` are recognized through an
injected `EnvLookup`; the default URL is `https://openrouter.ai/api/v1`.
`HTTP-Referer` and `X-Title` are added only when configured. Chat and embedding
factories use the same wrapper settings.

## Default model routing

When compiled with the default `-Ddefault-openrouter=true`, bare string model
references resolve through the built-in OpenRouter default. That behavior is
opt-in at runtime, not implicit credential discovery:

```zig
ai.setDefaultRuntime(gpa, io);
ai.setDefaultEnv(provider_utils.EnvLookup.fromMap(init.environ_map));
```

Without an installed default environment containing `OPENROUTER_API_KEY`, a
bare id fails with `LoadAPIKeyError` and sends no request. Applications can
replace the default with `ai.setDefaultProvider`, call
`ai.useOpenRouterDefault` explicitly, or compile the built-in path out with
`-Ddefault-openrouter=false`.

That no-default path is covered by a test: a bare id returns
`LoadAPIKeyError`, not a request.

This matters for trust and billing. A string such as
`"anthropic/claude-..."` names an OpenRouter route when the OpenRouter default
resolves it; it does not contact Anthropic directly. Construct the native
[Anthropic provider](anthropic.md) to pin that request path.

Every completed core step records `provider_name` and `model_id`, making the
resolved route available to logs, telemetry, and result inspection.

## Exposure and limits

OpenRouter text generation/streaming and embeddings are available in Zig and
through C ABI v1, Python, and Rust provider constructors. Actual model
capabilities and availability remain OpenRouter/vendor properties. The wrapper
advertises OpenAI-compatible structured output and uses generic embedding
defaults; provider errors still flow through the common diagnostic taxonomy.

The status table distinguishes this implementation coverage from dated live
evidence. Do not infer that every routed provider/model pair has been
live-tested from the wrapper's beta status.
