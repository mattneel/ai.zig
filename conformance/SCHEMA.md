# Differential conformance schema

The harness runs one declarative scenario against the pinned TypeScript SDK
and ai.zig. Each runner emits the same JSON envelope:

```json
{
  "surface": "generateText",
  "result": {
    "text": null,
    "object": null,
    "embedding": null,
    "embeddings": null,
    "value": null,
    "values": null
  },
  "stream_parts": [],
  "usage": null,
  "finish_reason": null,
  "steps": [],
  "messages": [],
  "error": null
}
```

Unused result fields are `null`. `messages` is the canonical ModelMessage
wire representation, with optional `providerExecuted: false` normalized to
absence because the upstream default is omitted. Tool-call and tool-result
messages are compared as well as the summarized `steps[].tool_calls` and
`steps[].tool_results`.
Errors intentionally compare only `{ "category": "..." }`; provider error
wording and native stack details are not compatibility surfaces.

Language usage has the fixed shape below. Embedding operations use the same
shape with only `tokens` populated.

```json
{
  "input_tokens": 5,
  "input_token_details": {
    "no_cache_tokens": 5,
    "cache_read_tokens": 0,
    "cache_write_tokens": 0
  },
  "output_tokens": 3,
  "output_token_details": {
    "text_tokens": 3,
    "reasoning_tokens": 0
  },
  "total_tokens": 8,
  "tokens": null
}
```

## Stream-part mapping

The common names retain upstream's public spelling. Zig enum tags use the
repository's snake_case convention.

| Upstream TypeScript | ai.zig | Common type |
| --- | --- | --- |
| `start` | `start` | `start` |
| `start-step` | `start_step` | `start-step` |
| `text-start` | `text_start` | `text-start` |
| `text-delta` | `text_delta` | `text-delta` |
| `text-end` | `text_end` | `text-end` |
| `reasoning-start` | `reasoning_start` | `reasoning-start` |
| `reasoning-delta` | `reasoning_delta` | `reasoning-delta` |
| `reasoning-end` | `reasoning_end` | `reasoning-end` |
| `tool-input-start` | `tool_input_start` | `tool-input-start` |
| `tool-input-delta` | `tool_input_delta` | `tool-input-delta` |
| `tool-input-end` | `tool_input_end` | `tool-input-end` |
| `tool-call` | `tool_call` | `tool-call` |
| `tool-result` | `tool_result` | `tool-result` |
| `finish-step` | `finish_step` | `finish-step` |
| `finish` | `finish` | `finish` |
| `error` | `err` | `error` |

`streamObject` maps `object`, `text-delta`, `finish`, and `error` in the same
way. Ordered common parts retain provider-supplied IDs and semantic payloads.
Generated call IDs, response timestamps, request duration, and performance
rates are not emitted because they are nondeterministic orchestration
metadata rather than provider or core behavior.

## Request normalization and deviations

Request methods, paths, and parsed JSON bodies compare exactly with object
key-order insensitivity. The curated header set is `content-type`, auth
headers, `anthropic-version`, `anthropic-beta`, and OpenAI organization/project
headers. Hop-by-hop and transport headers are dropped. User-agent values are
presence-only because fidelity-ledger item 10 changes the JavaScript runtime
suffix to the Zig runtime suffix.

Retry scenarios set `comparison.requests` to `count-and-order`; their request
count, ordinal, method, and path still compare, while retry timing, headers,
and repeated payloads do not. A scenario is `LEDGERED` only when every raw
diff path is covered by an `expected_deviations` entry whose reason explicitly
references the fidelity ledger. Unsupported Zig surfaces are `SKIPPED` with a
reason; they are never counted as passes.
