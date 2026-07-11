# Research reports

Deep-research reports produced 2026-07-10 against `inspiration/` at
`ai@7.0.22` (provider spec **V4**) and the Zig **0.16.0** stdlib. Each report
was written by an agent that read the actual sources; file references at the
bottom of each report point to the evidence. The porting guide and roadmap
are synthesized from these — when writing code, prefer re-reading the
upstream source, and treat these as maps rather than the territory.

## Upstream (Vercel AI SDK)

| Report | Covers |
| --- | --- |
| [sdk-inventory.md](sdk-inventory.md) | full ~70-package census, dependency spine, port-relevance classification, LOC counts |
| [sdk-provider-spec.md](sdk-provider-spec.md) | `@ai-sdk/provider` V4: LanguageModelV4, all 21 stream-part variants, all sibling model specs, error taxonomy, v3→v4 delta |
| [sdk-generate-text.md](sdk-generate-text.md) | generateText step loop + streamText 5-layer pipeline, chunk vocabularies, abort/timeout, test-verified contracts |
| [sdk-object-embed.md](sdk-object-embed.md) | generateObject/streamObject output strategies, fixJson, schema abstraction, embed/embedMany/rerank |
| [sdk-agent-prompt-middleware.md](sdk-agent-prompt-middleware.md) | ToolLoopAgent, ModelMessage/prompt conversion, middleware, registry, full error inventory |
| [sdk-provider-utils.md](sdk-provider-utils.md) | HTTP helpers, SSE parsing algorithm, retry/backoff, secure JSON, schema/validator, SSRF guards |
| [sdk-providers-concrete.md](sdk-providers-concrete.md) | anthropic + openai (Chat & Responses) + openai-compatible: the provider recipe, event→part mapping tables |
| [sdk-streams-ui-mcp.md](sdk-streams-ui-mcp.md) | UI message stream wire protocol, Chat state machine, tool machinery, MCP client + 3 transports |
| [gap-gateway.md](gap-gateway.md) | gateway auth/metadata/errors; the 5 static couplings from `ai` core |
| [gap-telemetry-logger.md](gap-telemetry-logger.md) | Telemetry vtable contract, dispatcher semantics, tracingChannel protocol, logWarnings, otel span inventory |
| [gap-media-upload.md](gap-media-upload.md) | generateImage/Speech/Video, transcribe, uploads, multipart requirements, provider polling pattern |
| [gap-realtime-websocket.md](gap-realtime-websocket.md) | realtime session/reducer/codec + a complete wss:// client recipe for Zig 0.16 |

## Zig 0.16

| Report | Covers |
| --- | --- |
| [zig-io-model.md](zig-io-model.md) | std.Io interface/vtable, async/Future/Group/Select/Queue/Batch, cancelation semantics, Reader/Writer, Io.net, Threaded internals |
| [zig-http-json.md](zig-http-json.md) | http.Client request lifecycle, chunked/TLS/redirects/pool, std.json three layers, verified POST+SSE example, stdlib gap list |
| [zig-ffi-export.md](zig-ffi-export.md) | export fn rules, 0.16 extern breaking changes, addLibrary packaging, validated C ABI + Python ctypes patterns, Threaded-under-FFI |
| [gap-streaming-ownership-packaging.md](gap-streaming-ownership-packaging.md) | Io.Queue semantics, broadcast/tee design, DelayedPromise mapping, arena-per-step ownership, multi-module build.zig |

## Prototypes (built and run on Zig 0.16.0)

- [prototypes/sse_demo.zig](prototypes/sse_demo.zig) — POST JSON, receive a
  chunked `text/event-stream` response, parse SSE lines incrementally,
  JSON-decode each event. Verified events arrive incrementally.
- [prototypes/cabi/](prototypes/cabi/) — C ABI library prototype: opaque
  runtime handle over `Io.Threaded`, `enum(c_int)` status codes, ptr+len
  strings, callback + pull-based streaming over `Io.Queue`, exercised from
  Python ctypes (`test_ffi.py`, `test_stream.py`) and C; cancellation from
  Python interrupted a blocked producer in ~0.2 ms.
