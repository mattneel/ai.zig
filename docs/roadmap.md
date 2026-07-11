# Roadmap

Phased implementation plan. Ordering is forced by the upstream dependency
spine (`provider` → `provider_utils` → providers/`gateway` → `ai`) plus two
project-specific constraints: the telemetry dispatcher must exist before
`generateText` is ported (~60 call sites, cannot be retrofitted), and the
C ABI gets an early vertical slice (Phase 6) so FFI constraints stay honest
rather than being bolted on at the end.

Every phase lands with tests ported from (or equivalent to) the upstream
suites, and `zig build test` green. LOC figures are upstream TS source as a
sizing signal, not a target.

---

## Phase 0 — Foundations

**Goal:** the skeleton everything else lands in.

- `build.zig` exposing named modules (`provider`, `provider_utils`, `ai`,
  `openai_compatible`, `anthropic`, `openai`, `gateway`, `mcp`, `ffi`) with
  per-module test steps aggregated under `zig build test`
  (`-Dtest-filter` supported).
- Error set + `Diagnostics` payload union (the ~35 upstream error names with
  their payload fields; porting-guide §9).
- `notify()` callback helper (parallel, awaited, errors swallowed) and the
  one-shot cell (`Io.Event` + value; DelayedPromise equivalent).
- Id generation (`createIdGenerator` semantics: 16-char, 62-alphabet).
- Test harness: in-process HTTP mock over `std.http.Server` with canned
  JSON/SSE responses (upstream `test-server` equivalent) — required by
  nearly every later test suite.

**Accept:** `zig build test` runs module test skeletons; mock server can
serve a canned SSE stream consumed by a test client.

## Phase 1 — `provider`: the V4 specification (~9.5k LOC upstream)

**Goal:** every V4 type as Zig data + vtables. Pure spec, no runtime logic.

- LanguageModelV4 vtable; CallOptions; prompt/message/content-part unions;
  the full 21-variant stream-part union; 9-variant content union; usage;
  finishReason; warnings; SharedV4FileData; tool definitions/toolChoice;
  ToolResultOutput.
- Sibling model specs: embedding, image, speech, transcription (+ stream
  parts), reranking, video, files/skills, realtime event codec unions.
  ProviderV4 vtable.
- JSON (de)serializers for every union with stable tag↔wire-string mapping.
  These serializers double as the gateway codec later — treat them as
  canonical.

**Accept:** round-trip (parse → serialize → parse) fixture tests using JSON
captured from upstream test fixtures; exhaustive-switch compile guarantees on
all unions. `zig build test-provider` green.

## Phase 2 — `provider_utils`: transport & plumbing (~7.9k LOC)

**Goal:** the concurrency/network core.

- `HttpTransport` vtable over `std.http.Client`; postJson/postFormData/get
  helpers; response handlers (JSON, binary, error-schema→APICallError);
  header utilities (combine/normalize/user-agent suffix); loadApiKey/Setting
  (call-time env lookup).
- **SSE decoder** over `*Io.Reader` (WHATWG semantics; porting-guide §7) —
  the single most safety-critical port; test against the eventsource-parser
  behavior corpus (BOM, CR/LF/CRLF, multi-line data, comments, retry
  validation, partial-line buffering).
- `parseJsonEventStream` (SSE → validated `ParseResult(T)`, `[DONE]`
  handling, never-throw mid-stream).
- Retry engine + abort-aware sleep; **fixJson** + `parsePartialJson`
  (port the upstream test corpus first); safeParseJSON result unions;
  schema abstraction (comptime generator + raw-JSON-schema constructor +
  `additionalProperties:false` walk); `detectMediaType` magic-bytes tables;
  base64/uint8 utils; SSRF-guarded download helper.

**Accept:** SSE decoder passes the ported spec corpus; a test POSTs JSON to
the mock server and consumes a chunked SSE stream incrementally (the
`sse_demo.zig` flow as a test); fixJson corpus green.
`zig build test-provider-utils` green.

## Phase 3 — First providers: `openai_compatible` + `anthropic` (~13k LOC)

**Goal:** prove the spec + plumbing against real wire formats.

- `openai_compatible` chat model (the vendor template: pluggable error
  structure, unknown-option passthrough, reasoning_content handling,
  indexed tool-call delta tracker).
- `anthropic` (richest single-endpoint provider): factory, capabilities
  table, prompt conversion (system blocks, cache_control, thinking
  signatures, tool_use reconstruction), betas set → header, SSE event → part
  state machine, first-chunk error peek (HTTP-200 overload!), usage/stop
  mapping.
- StreamingToolCallTracker equivalent (shared by chat-style providers).

**Accept:** doGenerate/doStream fixture tests against the mock server using
recorded upstream fixtures; a gated live smoke test (`-Dlive` + env key)
streams a real completion. `zig build test-anthropic` green.

## Phase 4 — `ai` core, non-streaming: telemetry → prompt → `generateText`

**Goal:** the multi-step tool loop, correct before streaming exists.

- **Telemetry dispatcher first** (vtable of optional callbacks, dispatcher
  semantics from `research/gap-telemetry-logger.md`), `logWarnings`,
  global registry.
- Prompt layer: standardizePrompt, convertToLanguageModelPrompt (parallel
  URL downloads via Io.Group, tool-message merging, MissingToolResults
  enforcement, approval-id mapping), prepareTools/ToolChoice/CallOptions
  validation.
- `generateText`: step loop with stopWhen/prepareStep, parseToolCall
  (repair/refine/never-throw invalid fallback), approval resolution
  (HMAC signing), concurrent tool execution (Io.Group), asContent
  interleaving, toResponseMessages (deep-clone into call arena), usage
  accumulation, output parsing gate.
- Registry, customProvider, resolve-model with pluggable default provider;
  wrapLanguageModel + defaultSettings/addToolInputExamples middleware.

**Accept:** ported upstream generate-text test contracts (multi-step loop,
tool errors as data, deferred provider tools, stop conditions, callback
ordering); `zig build test-ai` green.

## Phase 5 — `streamText`: the full streaming pipeline

**Goal:** the hardest subsystem; everything upstream's 5 layers do.

- `Broadcast(T)` part log (tee equivalent) + stitchable stream (outer queue,
  inner-stream queue, driver task) + producer-into-`Io.Queue` provider end.
- streamLanguageModelCall standardization (incl. performance stats),
  tool-callback stage, executeToolsFromStream (concurrent execution after
  model-call-end, preliminary results), per-step assembly + continuation
  (stepFinish one-shot sync), event processor + result cells with
  auto-drain accessors.
- Abort/timeout: merged cancelation (total/step/chunk/tool timeouts),
  abort-part semantics (no onError/onEnd after abort).
- smoothStream, extractReasoning/extractJson/simulateStreaming middleware
  (stream state machines).

**Accept:** ported stream-text behavioral contracts — canonical part order,
abort mid-stream, error-part flow, multi-consumer derived streams, empty
delta dropping, missing-id synthetic errors, usage totals. A live gated
smoke test streams from Anthropic. `zig build test-ai` green.

## Phase 6 — C ABI v0 + Python proof (`ffi` module)

**Goal:** early vertical slice; validates the boundary before surface grows.

- `ai_runtime` (gpa + `Io.Threaded`), status codes, hand-written `ai.h`,
  translate-c ABI-lock test, static+shared artifacts.
- `ai_generate_text` (blocking, callee-allocated out), `ai_stream_text` +
  `ai_stream_next` pull iteration (scratch-arena borrow + clone/free),
  `ai_stream_cancel`, provider construction, explicit key config.
- Python ctypes wrapper prototype exercising generate, stream, cancel
  (the `research/prototypes/cabi` patterns productionized).

**Accept:** Python integration test streams parts and cancels mid-stream;
ABI-lock test green; both artifacts build (`zig build`).

## Phase 7 — Structured output & embeddings

- generateObject/streamObject: four output strategies (object/array/enum/
  no-schema) with exact array textDelta synthesis; partial parsing via
  fixJson + isDeepEqualData dedup; repair hook; NoObjectGeneratedError
  payloads.
- Output spec for generateText/streamText (`experimental_output` path:
  text/object/array/choice/json + element streams).
- embed/embedMany (batch by maxEmbeddingsPerCall, wave-based parallelism
  barrier, order preservation), rerank.

**Accept:** ported generate-object/embed test suites; partial-object stream
fixtures produce identical partial sequences. 

## Phase 8 — Agent, gateway, `openai` full

- ToolLoopAgent (settings, prepareCall, callback merging, default
  stopWhen=stepCount(20)), agent UI-stream helpers.
- `gateway` module: language + embedding models, auth (api-key/OIDC),
  metadata cache (stale-while-revalidate + single-flight), GatewayError
  taxonomy, o11y headers; register as installable default provider.
- `openai` native package: Chat + Responses APIs (item-based stream mapping,
  reasoning summary lifecycle, item_reference optimization), embeddings.

**Accept:** agent loop tests; gateway fixture tests (wire = normalized types);
OpenAI Responses stream mapping fixtures.

## Phase 9 — UI message stream, Chat, MCP

- UI chunk union + SSE encode/decode; createUIMessageStream (writer.merge
  concurrency); processUIMessageStream reducer; convertToModelMessages;
  validateUIMessages; readUIMessageStream; toUIMessageChunk mapping;
  AbstractChat + HTTP/Default/TextStream/Direct transports; an
  `std.http.Server` example endpoint (`toUIMessageStreamResponse`
  equivalent).
- MCP: JSON-RPC layer, stdio transport (std.process), Streamable HTTP
  (session ids, resumable inbound SSE, reconnect backoff), legacy SSE;
  MCP tools → SDK dynamic tools. OAuth deferred.

**Accept:** reducer contract tests (7-state tool lifecycle, approvals,
data-part reconciliation); MCP client talks to a real stdio server
(e.g. a reference server) in a gated test.

## Phase 10 — Media & files

- Multipart/form-data encoder over `http.BodyWriter` (exact content-length).
- generateImage/generateSpeech/transcribe/generateVideo/uploadFile/
  uploadSkill orchestration (parallel fan-out, No*Generated diagnostics,
  lazy GeneratedFile); OpenAI image/speech/transcription models; one
  video provider with job polling (xai pattern).

**Accept:** multipart wire-format fixtures byte-exact; media orchestration
suites ported.

## Phase 11 — Realtime & WebSocket

- WebSocket client (~500 LOC; handshake via http.Client + connection
  takeover, client-side masking, ping/pong/close handshake, allocator-backed
  large messages, recv task + mutex-guarded writer, keepalive) — spec in
  `research/gap-realtime-websocket.md`.
- Realtime: event reducer, session (tool gating, barge-in), transport vtable,
  audio utils (PCM16/base64/resample); OpenAI realtime codec + gateway
  identity codec + subprotocol auth; streaming transcription (openai
  realtime WS path) unlocked here too.

**Accept:** reducer/session contract tests; WS client interop test against
the mock server's WebSocket upgrade (std.http.Server supports it); gated
live realtime smoke test.

## Phase 12 — FFI v1, wrappers, breadth

- Complete C ABI surface (objects/embeddings/agent/chat/UI chunks as JSON,
  telemetry vtable registration, media).
- Idiomatic wrappers: Python package (ctypes/cffi, iterators over pull
  streams, context managers) and Rust `-sys` crate + safe wrapper.
- Provider breadth via `openai_compatible` config table (xai, groq,
  deepseek, mistral, togetherai, fireworks, …); `google` native provider;
  otel exporter module implementing the telemetry vtable (gen_ai SemConv).

**Accept:** wrapper test suites in CI; a third-party-style example app per
wrapper; provider conformance fixtures shared across vendors.

---

## Cross-cutting rules

- **Fidelity ledger** (porting-guide §18) is updated in the same change as
  any new deviation.
- Every phase ports the relevant upstream *tests*, not just code.
- Live-API tests are opt-in (`-Dlive` + env keys), never in default CI.
- Upstream tracks a moving target: `inspiration/` is re-pinned deliberately,
  with a diff review of `packages/provider` (spec changes ripple furthest).
