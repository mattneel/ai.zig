# Anthropic

The native Anthropic provider implements the Messages API rather than routing
through an OpenAI-compatible facade. It maps system blocks, cache controls,
thinking content and signatures, tool-use reconstruction, beta headers,
usage, stop reasons, and Anthropic's SSE event state machine.

## Construction

```zig
const factory = try anthropic.createAnthropic(.{
    .api_key = api_key,
    .transport = transport.transport(),
});
var claude = try factory.messages("claude-haiku-4-5-20251001", &diagnostics);
const model = claude.languageModel();
```

`messages`, `chat`, and `languageModel` are aliases returning an
`AnthropicLanguageModel`. The default provider name is
`anthropic.messages`. `embeddingModel` reports `NoSuchModelError` because
Anthropic does not expose embeddings through this package.

Explicit `api_key` and `auth_token` are mutually exclusive. With an injected
environment lookup, the provider recognizes `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, and `ANTHROPIC_BASE_URL`. The official base URL is
normalized to include `/v1`; trailing slashes are removed.

## Models used by repository evidence

- `claude-haiku-4-5-20251001` drives the live text, tool-loop, structured
  output, Python, and Rust smoke paths.
- `claude-sonnet-4-5-20250929` appears in native mapping and capability tests.
- `claude-3-haiku-20240307` checks the older-family capability fallback.

These examples are dated evidence, not a promise that a provider will keep a
model available. Applications own model selection and provider billing.

## Thinking, tools, and structured output

`provider.ReasoningEffort` maps to adaptive thinking for capable families or
to an explicit token budget for older thinking models. When thinking is
enabled, unsupported sampling settings are removed with warnings. Known model
families also carry maximum-output and structured-output capability data.

Function tools become Anthropic tool definitions. Tool-use blocks stream
through `tool_input_start`/delta/end and then `tool_call`; generated tool calls
retain provider metadata. Provider-defined tools and cache-control betas are
represented through provider options and headers.

For a JSON response schema, `structuredOutputMode` controls the path:

- `outputFormat` forces native `output_config.format`;
- `jsonTool` forces the synthetic JSON tool path;
- `auto` uses native format for model families marked capable and otherwise
  falls back to the synthetic `json` tool.

The fallback appends a required `json` tool, disables parallel tool use, and
extracts its input as the response. Native format adds the current structured
output beta when required by tool preparation.

## Error handling

Anthropic may encode an overloaded error as the first event of an HTTP 200
SSE response. The stream implementation peeks and maps that event into the
common API error taxonomy before normal part delivery. HTTP errors,
authentication errors, invalid event transitions, and malformed tool input
populate `Diagnostics` with provider context.

Use the high-level [Tools & Tool Loops](../tools.md) API for execution and
approval behavior. The provider layer only maps model wire parts; the core
owns validation, concurrent callback execution, retries, and subsequent
steps.

