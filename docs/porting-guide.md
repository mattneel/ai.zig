# Porting guide: Vercel AI SDK → Zig 0.16

This is the concrete design document for the port. It compresses the deep
research in [`docs/research/`](research/) into decisions and recipes. When a
claim here seems surprising, the research reports carry the file-level
evidence; when code is being written, the upstream sources and their tests in
`inspiration/` are the final authority.

Target: upstream **v7** (`ai@7.0.22`), provider interface version **V4**.
Legacy v2/v3 spec trees under `inspiration/packages/provider/src/*/v2,v3` are
out of scope.

---

## 1. Upstream anatomy and port order

~70 packages in the monorepo; the dependency spine forces the port order:

```
1. @ai-sdk/provider        (225 files /  9.5k LOC)  pure spec, zero deps
2. @ai-sdk/provider-utils  (142 files /  7.9k LOC)  HTTP/SSE/JSON/retry plumbing
3. @ai-sdk/gateway         ( 47 files /  4.9k LOC)  HARD dep of `ai` (string model ids)
   @ai-sdk/openai-compatible (25 / 2.9k)            parent of ~12 thin providers
   native providers (anthropic 10.4k, openai 13.2k, google 11.8k, …)
4. ai                      (321 files / 36.5k LOC)  generateText/streamText/objects/agent/ui-stream/media
   @ai-sdk/mcp             ( 20 files /  5.3k LOC)  JSON-RPC client, 3 transports
```

Classification of the rest (see `research/sdk-inventory.md` for the full
census): 40 packages are concrete providers following one identical adapter
recipe; react/vue/svelte/angular/rsc are thin bindings over framework-agnostic
code that lives in `ai/src/ui` (port the core, skip the bindings);
harness/workflow/sandbox/policy-opa are an experimental agent-runtime layer
(deferred); codemod/devtools/langchain/llamaindex/valibot are out of scope.
`test-server` must be *recreated* in Zig (in-process HTTP mock) because nearly
every upstream test suite depends on it.

Two upstream quirks that shape the port:

- **`ai` hard-imports `@ai-sdk/gateway`** (default global provider for string
  model ids like `"anthropic/claude-opus-4.6"`). In Zig, make the default
  provider an explicit registration (settable vtable pointer) instead of a
  hard link dependency; the gateway module implements it. Porting gateway is
  cheap: its wire format *is* the JSON serialization of the normalized
  CallOptions/StreamParts (see §11).
- **Errors are data.** Stream errors, tool errors, invalid tool calls, and
  aborts flow through streams as typed parts, not exceptions. Only machinery
  failures throw. This is a gift to Zig — model them as union variants.

## 2. The provider spec (`provider` module)

`LanguageModelV4` is the single most load-bearing interface:

```zig
pub const LanguageModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        provider: *const fn (ctx) []const u8,
        model_id: *const fn (ctx) []const u8,
        supported_urls: *const fn (ctx, Allocator) SupportedUrls,
        do_generate: *const fn (ctx, Io, Allocator, CallOptions) Error!GenerateResult,
        do_stream:   *const fn (ctx, Io, Allocator, CallOptions, *StreamResult) Error!void,
    };
};
```

Key facts to preserve exactly (full field lists in
`research/sdk-provider-spec.md`):

- **CallOptions**: prompt, maxOutputTokens, temperature, stopSequences, topP,
  topK, presence/frequencyPenalty, responseFormat (`text` | `json{schema?,
  name?, description?}`), seed, tools, toolChoice (4-variant union),
  includeRawChunks, headers, `reasoning` effort enum
  (`provider-default|none|minimal|low|medium|high|xhigh`), providerOptions.
  AbortSignal → Io cancelation (§5). PromiseLike-valued properties
  (supportedUrls, maxEmbeddingsPerCall) become plain possibly-blocking calls.
- **The stream-part union has 21 tags** — text/reasoning/tool-input
  start-delta-end triples correlated by string `id`, tool-approval-request,
  tool-call (input = *stringified JSON*), tool-result, custom, file,
  reasoning-file, source (url|document sub-discriminator), stream-start
  (carries warnings, first part), response-metadata, finish (usage +
  finishReason), raw, error (may appear mid-stream, multiple allowed). Model
  it as one exhaustive tagged union; new upstream variants must force a
  compile error at every switch.
- **doGenerate content** is a 9-variant union; **usage** is structured
  (`inputTokens{total,noCache,cacheRead,cacheWrite}`,
  `outputTokens{total,text,reasoning}`, all optional, plus `raw` JSON);
  **finishReason** is `{unified: enum(6), raw: ?[]const u8}`.
- **Prompt**: system/user/assistant/tool messages with per-role content-part
  unions; note the asymmetry that generated tool-call content carries `input`
  as a JSON *string* while prompt ToolCallPart carries parsed JSON.
- **SharedV4FileData** is a tagged union `data | url | reference | text`.
- **Sibling specs**: EmbeddingV4, ImageV4, SpeechV4, TranscriptionV4 (with an
  8-variant experimental stream), RerankingV4, VideoV4, FilesV4/SkillsV4,
  RealtimeV4 (a pure WebSocket event *codec*: 8 client / 23 server event
  variants — transport lives elsewhere). ProviderV4 exposes
  languageModel/embeddingModel/imageModel (required) + optional others.
- **supportedUrls uses `RegExp[]`** and Zig std has no regex. Decision: the
  vtable exposes `urlIsSupported(media_type, url) bool` as a callback;
  built-in providers implement it with literal-prefix/glob matching; a full
  regex engine is not warranted.

## 3. Type mapping (TS → Zig)

| TypeScript construct | Zig mapping |
| --- | --- |
| discriminated union on `type`/`role` string | `union(enum)` + stable tag↔wire-string tables for (de)serialization |
| `number \| undefined` (incl. NaN sentinels) | optionals (`?u64`, `?f64`); replace upstream NaN token sentinels with `null` |
| `Date` | `i64` epoch milliseconds (wire) / `Io.Timestamp` (internal) |
| `JSONValue` / `Record<string, JSONObject>` | `std.json.Value` (arena-owned); providerOptions/Metadata as `Value` maps with typed per-provider parse helpers |
| `Promise<T>` | plain blocking call taking `io: Io` (colorblind functions) |
| `DelayedPromise<T>` | one-shot cell: `{ event: Io.Event, value: E!T }` with `resolve()`/`await(io)`; the JS laziness motivation disappears |
| `ReadableStream<T>` | `Io.Queue(T)` (bounded, caller-provided buffer, suspend-based backpressure, `close()` = drain-then-`error.Closed`) |
| `ReadableStream.tee()` | **no stdlib primitive** — build `Broadcast(T)`: shared append-only part log (`Io.Mutex` + `Io.Condition.broadcast`) with per-consumer cursors; doubles as the step accumulator the SDK needs anyway |
| stitchable stream (multi-step splice) | outer `Io.Queue(Part)` + inner queue of step-streams + one driver task in an `Io.Group`; `close` vs `terminate` = inner-queue close vs `group.cancel` |
| `AbortSignal` / `AbortSignal.any` / timeouts | `Future.cancel`/`Group.cancel`; `error.Canceled` at the next cancelation point; timeouts via racing tasks or `Io.Timeout` where ops support it; chunk-timeout = deadline reset per pull |
| `TransformStream` chains | pull-based stage structs: each owns `next(io) !?Part` pulling from upstream — backpressure falls out like WHATWG `pull()` |
| zod schema | tagged union: comptime-generated JSON Schema from a Zig type (walk `@typeInfo`; structs → `additionalProperties:false` objects, optionals → not-required, enums → string enums) \| raw JSON-Schema string + optional validate fn (the C-ABI path) \| none |
| `DeepPartial<T>` streaming partials | `std.json.Value` (upstream doesn't validate object-mode partials either; FFI-friendly) |
| error classes w/ payloads + Symbol markers | Zig `error` set for the ~35 names + a parallel `Diagnostics` payload struct (out-param or result-carried); markers are obsolete (nominal types); C ABI gets `enum(c_int)` codes + payload getters |
| `structuredClone` between steps | explicit deep-copy into the destination arena |
| callback merging / `Promise.allSettled` notify | `notify()` helper: run callbacks (optionally as Io tasks), join, swallow per-callback errors — callbacks are *awaited* (pipeline-pausing), preserve that |
| secure-json-parse proto-pollution guard | intentionally omitted (no prototype chain); keep `std.json` strict. Documented deviation. |

## 4. Streaming architecture (`streamText`)

Upstream is a 5-layer WHATWG pull pipeline
(`research/sdk-generate-text.md` has the full anatomy):
provider chunks → standardize → tool-input callbacks → tool execution →
per-step assembly/continuation → gate/transforms/output-parse/event-processor.

Zig design:

- Each stage is a struct with `next(io) !?Part` pulling from its upstream;
  the whole chain is driven by the consumer. The provider end is an SSE
  decoder over the response `*Io.Reader`.
- The producer side (HTTP read + SSE decode + event mapping) runs as a task
  (`io.async`, degrading gracefully single-threaded) writing into an
  `Io.Queue(StreamPart)`; consumer loop:
  `while (q.getOne(io)) |part| {...} else |err| switch (err) { error.Closed => done, error.Canceled => |e| return e }`.
  This mirrors the stdlib's own `netLookup` producer-into-caller-queue shape.
- Multi-step continuation: no recursion — an explicit loop appends step
  streams through the stitchable-stream construct (§3 table). Step N+1's
  provider call starts while step N's tail (tool results after
  `model-call-end`) is still flushing, synchronized by the `stepFinish`
  one-shot cell exactly as upstream.
- Derived streams (`textStream`, `partialOutputStream`, …) come from
  `Broadcast(T)` cursors, not repeated tee-buffering. The event processor
  records everything needed for `StepResult`, so result promises
  (`.text`, `.usage`, `.finishReason`, `.steps`) are one-shot cells resolved
  at flush; accessing any of them drains the stream (`consumeStream()`
  equivalent) exactly like upstream's lazy auto-consumption.
- Behavioral contracts to preserve (test-verified upstream): canonical part
  order `start, start-step, …content…, finish-step, [next step…], finish`;
  abort emits `abort` part, fires `onAbort`, and skips `onError`/`onEnd`;
  empty text deltas dropped; in-stream `error` parts never throw from
  iteration; incomplete model stream with no output ⇒ synthetic
  `NoOutputGeneratedError`; `onChunk` awaited per part (pauses pipeline);
  usage summed fieldwise with undefined+undefined=undefined.
- Tool execution: valid client tool calls queue during the step and run
  concurrently after `model-call-end` via an `Io.Group`, streaming
  `preliminary` tool-results into the step stream; tool errors become
  `tool-error` parts (data, not errors). Tool timeout = per-tool deadline
  merged with the call's cancelation.
- `smoothStream`, `extractReasoningMiddleware`, `extractJsonMiddleware` are
  incremental per-id state machines with lookahead buffering (12-byte suffix
  holdback for the JSON fence stripper) — port exactly; they double as early
  tests of the stage abstraction.

## 5. Concurrency and cancelation rules

- `Io` is stored on context structs by value (16 bytes), never constructed
  inside the library; tests use `std.testing.io`; error paths can use
  `Io.failing`.
- Every public op that can block carries `error.Canceled` in its error set.
- `io.async` **may run inline** when the pool is saturated — never rely on it
  for correctness-required concurrency; use `io.concurrent` and handle
  `error.ConcurrencyUnavailable` (which is also the single-threaded story).
  A validated deadlock exists in the naive `io.async` pump-loop pattern —
  see `research/zig-http-json.md`.
- Cancelation is one-shot: after acknowledging `error.Canceled` without
  propagating (e.g. partial queue progress), call `io.recancel()`.
- Cleanup idiom everywhere:
  `var fut = io.async(f, .{args}); defer if (fut.cancel(io)) |res| res.deinit() else |_| {};`
- Ship on `Io.Threaded` (the only production-ready impl; evented backends
  lack networking in 0.16). Concurrency knobs surface from
  `Threaded.InitOptions{async_limit, concurrent_limit}`.

## 6. Memory and ownership

Grounded in stdlib precedent (`std.json.Parsed(T)` arena-per-document;
`http.Client` borrow-until-invalidated header strings):

- **Arena-per-step** for stream-part payloads: SSE payloads are parsed with
  `parseFromTokenSourceLeaky` into the step arena; parts flow *by value*
  through queues with slices into that arena; the arena is freed after the
  step's `finish-step` is consumed and step text is copied into the
  whole-call result arena.
- Text deltas MUST be copied out of the HTTP connection buffer at
  SSE-decode time (the transport invalidates borrowed slices).
- `Io.Queue` memcpys elements — `StreamPart` must stay POD-with-slices, no
  self-references.
- Response head strings from `http.Client` are invalidated when body reading
  starts — copy headers before streaming (the SDK exposes response headers).
- Crossing any boundary that outlives the step ⇒ dupe into the destination's
  allocator. The C ABI boundary has its own rule (§15).
- Per-request wire assembly (request body, converted prompt) shares one
  request arena. Response messages are deep-cloned between steps (upstream
  contract) — clone into the call arena.

## 7. Network layer

`std.http.Client` needs almost no abstraction on top
(verified end-to-end: `research/prototypes/sse_demo.zig` POSTs JSON and
incrementally parses a chunked SSE response on 0.16.0):

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
var req = try client.request(.POST, uri, .{ .extra_headers = &.{...} });
req.transfer_encoding = .{ .content_length = payload.len };
var bw = try req.sendBody(&.{}); try bw.writer.writeAll(payload); try bw.end();
var response = try req.receiveHead(&redirect_buffer);
const body = response.reader(&transfer_buffer); // *Io.Reader, chunked de-framed
```

The injectable-`fetch` abstraction becomes an `HttpTransport` vtable
(method, uri, headers, body reader → response) so tests and the FFI can
substitute transports — it is the single polymorphism point every provider
uses, mirroring upstream `FetchFunction`.

**Must build (absent from stdlib):**

1. **SSE decoder** over `*Io.Reader` — WHATWG-compliant: BOM strip on first
   chunk, `\r`/`\n`/`\r\n` with deferred trailing CR, `data:`/`event:`/`id:`/
   `retry:` fields, comment lines, multi-line data joined with `\n`, dispatch
   on blank line only when data present, `id` NUL rejection, `[DONE]`
   handling at the JSON layer. Gotcha: use `takeDelimiter` (consumes the
   delimiter), not `takeDelimiterExclusive`; the transfer buffer bounds line
   length (`error.StreamTooLong`).
2. **Retry with exponential backoff** — two layers like upstream: generic
   engine (maxRetries=2, initial 2000ms, factor 2, abort-aware cancellable
   sleep) in provider_utils; `retry-after-ms`/`retry-after` header awareness
   (≤60s cap rule) in the ai layer. Retryable = APICallError with
   status 408/409/429/≥500 or connection failure.
3. **Per-request timeout** — none exists in `http.Client`; implement
   abort/timeout as cancelation (spawned request task + racing deadline).
4. **WebSocket client** (~500 lines, for realtime + streaming transcription;
   full recipe with exact signatures in `research/gap-realtime-websocket.md`):
   handshake through `client.request(.GET, wss_uri, …)` + upgrade headers
   (auth rides `Sec-WebSocket-Protocol` subprotocols — never headers);
   `receiveHead` returns the 101 with the connection reader parked at the
   first frame; steal the connection (`req.connection = null`, the CONNECT
   precedent); reuse `http.Server.WebSocket`'s packed header structs and
   SHA-1 accept recipe but invert masking (client sends masked); dedicated
   recv task + mutex-guarded writer + ping keepalive; allocator-backed
   message reader (audio deltas exceed 8 KiB buffers).
5. **Multipart/form-data encoder** writing to `http.BodyWriter` (for
   transcription/image-edit uploads): boundary generation, per-part
   Content-Disposition/Content-Type, repeated `key[]` array fields, exact
   Content-Length precomputation (all payloads are in-memory).
6. **SSRF-guarded download helper** mirroring `validateDownloadUrl`
   (private-range IPv4/IPv6 blocklist, 10-redirect cap, 2 GiB size limit,
   cancel-body-on-reject socket hygiene).

Known acceptable limitations: no HTTP/2 (provider APIs work on 1.1), TLS
1.2/1.3 only, no client cert auth, `connectUnix` broken in stdlib.

## 8. JSON and schema strategy

- Wire parsing: `std.json` typed parse with `.ignore_unknown_fields = true`
  into arena-backed structs; response schemas stay deliberately minimal and
  nullish-tolerant (upstream philosophy: unknown fields/events must not
  fail — unknown Responses-API event types coerce to an `unknown` variant).
  Unions-by-`type`-field need a small custom dispatch helper.
- **`fixJson`** — the partial-JSON repair state machine powering
  `streamObject` partials and tool-input streaming — ports 1:1: linear scan,
  explicit 17-state stack, output = `input[0..lastValid+1]` + closers.
  It is load-bearing; port its tests first.
- Incremental partial-object parsing pairs `fixJson` with re-parse per delta
  and `isDeepEqualData` dedup over `std.json.Value` (hot path — memoize).
- Schema abstraction is tiny (two capabilities: produce a draft-07 JSON
  Schema document; optionally validate a value). Comptime generator from Zig
  types + runtime raw-schema constructor for FFI. Post-process always forces
  `additionalProperties:false` on object schemas (OpenAI structured-outputs
  requirement — `addAdditionalPropertiesToJsonSchema` walk).
- Serialization: `std.json.Stringify` streaming writer for request bodies;
  conditional-field spreads become optionals + `emit_null_optional_fields=false`.

## 9. Errors and diagnostics

~35 error names across provider/ai packages, each carrying payloads
(APICallError: url, statusCode, responseHeaders, responseBody, isRetryable;
NoObjectGeneratedError: text, response, usage, finishReason; …). Zig errors
carry no payload, so:

- One Zig error set for the names; a `Diagnostics` tagged union carried via
  out-param (or on the result object) holds payloads. `getErrorMessage`
  equivalent formats them.
- `isRetryable` default: statusCode ∈ {408, 409, 429} or ≥500; connection
  failures retryable.
- Gateway needs only `{status_code, error_type enum, is_retryable,
  generation_id?, message}` in core (retry + wrapGatewayError contract).
- C ABI: stable `enum(c_int)` status codes + `ai_last_error_*` getters (§15).

## 10. Provider implementation recipe

A provider is exactly (validated against anthropic/openai/openai-compatible,
full mapping tables in `research/sdk-providers-concrete.md`):

1. Factory closing over settings (baseURL + env fallback + trailing-slash
   strip, apiKey via env fallback *at call time*, per-request headers
   closure, injectable transport, optional `name` override driving the
   providerOptions namespace).
2. Model struct implementing the V4 vtable; `getArgs` pipeline: collect
   warnings for unsupported params → parse namespaced providerOptions →
   static per-modelId capabilities table → map `reasoning` effort to
   provider knobs → convert prompt → prepare tools/toolChoice → assemble
   body.
3. `doGenerate`: POST via provider_utils, error-schema → APICallError,
   map typed response content → spec content parts.
4. `doStream`: POST with stream flag; SSE events → spec stream parts via a
   per-stream state machine struct (per-index/id hashmaps of in-flight
   blocks, usage accumulator, finish-reason mapping). The upstream
   `tee()`-based first-chunk error peek (Anthropic returns HTTP 200 for
   overloads!) becomes buffered peek-and-replay before handing the stream to
   the consumer.
5. providerOptions/providerMetadata round-tripping is load-bearing
   (Anthropic thinking signatures/cacheControl; OpenAI itemId/encrypted
   reasoning) — preserve as `std.json.Value` verbatim.
6. Byte-exact quirks: manual JSON-string tool-input synthesis (OpenAI
   code-interpreter prefix deltas), Anthropic betas set → single header,
   trailing-whitespace trim on assistant prefill, `'' → '{}'` tool input.

Port `openai-compatible` early — it unlocks ~12 vendors nearly for free.

## 11. Gateway module

Wire body for `/language-model` *is* the JSON serialization of normalized
CallOptions (minus abortSignal, binary file data base64-encoded — copy, do
not mutate the caller's prompt as upstream does); the SSE stream *is*
normalized StreamParts verbatim. So the port's canonical (de)serializers
double as the gateway codec. Auth: `AI_GATEWAY_API_KEY` else OIDC token
(`VERCEL_OIDC_TOKEN`), method echoed in `ai-gateway-auth-method`; protocol
headers `ai-gateway-protocol-version: 0.0.1`,
`ai-language-model-{specification-version,id,streaming}`. Metadata endpoint
cached with stale-while-revalidate + single-flight (mutex + generation
counter). Details: `research/gap-gateway.md`.

## 12. UI message stream, MCP, realtime

- **UI message stream** (the server↔client wire protocol): ~27-variant chunk
  union over SSE (`data: {json}\n\n`, `data: [DONE]\n\n`, headers incl.
  `x-vercel-ai-ui-message-stream: v1`). Fully portable: chunk types, SSE
  encoder (trivial `Io.Writer` wrapper), `createUIMessageStream` writer with
  `merge()` (io tasks + MPSC queue + completion counting),
  `processUIMessageStream` reducer (pull-loop over chunks mutating an
  arena-allocated UIMessage; 7-state tool lifecycle incl. approvals),
  `convertToModelMessages`, and the framework-agnostic `AbstractChat` state
  machine + `ChatTransport` (HTTP transport over `std.http.Client`) — this
  is what gives Python/Rust wrappers a chat client for free. Dynamic type
  keys (`data-{name}`, `tool-{name}`) need a union variant carrying the name
  slice. React/Vue/etc. bindings are out of scope.
- **MCP**: JSON-RPC 2.0 client with id-correlated handlers; transports:
  stdio (`std.process.spawn` + newline framing), legacy HTTP+SSE, Streamable
  HTTP (session ids, resumable inbound SSE with `last-event-id`, backoff
  reconnect — a good std.Io stress test). OAuth 2.1 phased later. MCP tools
  become dynamic tools whose execute calls `tools/call`.
- **Realtime**: the portable core is the event reducer (pure state machine +
  side maps), session orchestration (tool-call gating, barge-in truncation
  math), the V4 event codec unions, and PCM16/base64/resample audio utils.
  Transport = the §7 WebSocket client behind a `RealtimeTransport` vtable
  (upstream hard-wires the browser transport — invert that). Audio
  capture/playback is host-provided across the FFI.

## 13. Media, files, telemetry, misc

- Media orchestration (`generateImage/Speech/Video`, `transcribe`,
  `uploadFile/Skill`): resolve model → retry per call → fan out parallel
  calls when `n > maxPerCall` (Io.Group) → merge warnings/usage/metadata →
  `No*GeneratedError{responses}` on empty. Video *polling lives in
  providers* (create job → cancellable sleep loop → status GET, wall-clock
  timeout). `detectMediaType` magic-bytes table ports directly (incl.
  base64-prefix sniff and ID3 skip). Lazy base64↔bytes `GeneratedFile` with
  allocator-aware getters.
- **Telemetry**: the integration contract is an Allocator-style vtable of
  ~17 *optional* callbacks + 2 execute-wrappers, dispatched in parallel,
  awaited, errors swallowed; `isEnabled=false` ⇒ empty dispatcher, local
  integrations replace globals, onStepEnd fans out to deprecated
  onStepFinish. Design the dispatcher *before* porting generateText (~60
  call sites). Replace ambient-context execute-wrappers with paired
  enter/exit hooks returning a token (documented deviation). The Node
  `diagnostics_channel` layer becomes an optional atomic-gated span-event
  channel (comptime-removable). `logWarnings`: global tri-state
  (default/disabled/custom fn), exact upstream message format, once-only
  info note. The gen_ai SemConv span inventory (`research/gap-telemetry-logger.md`)
  specs a future otel exporter module.
- **Registry/customProvider**: split-at-first-separator + hashmap lookups;
  template-literal typing degrades to runtime string ids.
- **Ids**: `createIdGenerator` (16-char, 62-alphabet, non-crypto) — use a
  seeded PRNG; `io.random` where entropy is wanted.

## 14. Public API shape (Zig side)

Comptime where types earn their keep, dynamic where the wire is dynamic:

```zig
const result = try ai.generateText(io, gpa, .{
    .model = anthropic.languageModel("claude-opus-4-6"),
    .prompt = .{ .text = "..." },
    .tools = &.{ weatherTool }, // comptime-typed toolset; dynamic JSON variant exists
    .stop_when = ai.stepCount(5),
});

var stream = try ai.streamText(io, gpa, .{ .model = ..., .prompt = ... });
defer stream.deinit();
while (try stream.next()) |part| switch (part) {
    .text_delta => |d| ...,
    .tool_call => |tc| ...,
    else => {},
};
```

`TOOLS` generics → comptime toolset struct (typed input/output per tool) with
a dynamic JSON-value tool variant for dynamic/invalid/MCP tools.
`Output(COMPLETE, PARTIAL)` → comptime interface over the four strategies
(object/array/enum/no-schema); array-mode textDelta synthesis and
last-element-skip logic ported exactly so `textStream` stays valid JSON.

## 15. C ABI layer (validated design)

A working prototype was built and exercised from Python ctypes and C during
research (`research/prototypes/cabi/`, findings in
`research/zig-ffi-export.md`):

- **Runtime**: one long-lived opaque `ai_runtime` handle owning
  {thread-safe gpa, `Io.Threaded`}; every export is a blocking colorblind
  call passing `rt.threaded.io()`. Never Evented/Uring under FFI (fiber
  runtimes are init-thread-pinned). Caveats to document: `Threaded.init`
  installs process-global SIGIO/SIGPIPE handlers; panics abort the host —
  every export must be total (`catch return .status`).
- **Types**: `enum(c_int)` status codes (+ `ai_status_name` via `@tagName`);
  ptr+len strings; opaque handles with create/destroy; explicit backing ints
  on every extern enum/packed struct (0.16 *forbids* implicit backing in
  extern contexts); no slices/error-unions/optionals in signatures.
- **Streaming**: pull model as primary — `ai_stream_next(stream, *out_part)`
  blocks on the internal `Io.Queue`; out-struct pointers **borrow a
  per-stream scratch arena valid until the next call** (the `std.json` Token
  idiom), with `ai_part_clone`/`ai_part_free` for retention;
  `error.Closed` → `AI_STREAM_DONE`, `error.Canceled` → `AI_CANCELED`; a
  `min=0` poll variant exists. Push model (callback + `user_data`,
  `callconv(.c)`) as secondary. Cancelation from a foreign thread interrupts
  a blocked producer in ~0.2 ms (validated).
- **Memory**: boundary buffers from `std.heap.c_allocator` with paired free
  exports; one-shot results (generateText final) use callee-allocated
  out-params.
- **Header**: `-femit-h` is dead in 0.16 — `include/ai.h` is hand-written,
  shipped via `installHeader`, and locked by an ABI test that
  `b.addTranslateC`-imports the header and comptime-asserts it against the
  Zig exports.
- **Config**: env vars are non-global in 0.16; API keys/proxy config are
  explicit C API parameters (with optional libc `environ` reading when
  linked).
- Complex payloads (providerMetadata, UI chunks) cross the boundary as JSON
  strings; wrappers re-expose typed forms. Telemetry registration *is* the
  vtable: `ai_telemetry_t{ void* ctx; …callback fields }`.

## 16. Build and packaging

- One root `build.zig` exposing named modules mirroring the npm graph:
  `provider`, `provider_utils`, `gateway`, `ai`, `openai`, `anthropic`,
  `openai_compatible`, `mcp`, wired with `mod.addImport`.
- C ABI artifact: two `b.addLibrary` calls (`.linkage = .static` with
  `bundle_compiler_rt = true`, and `.dynamic` with `.version` for the
  soname) sharing one ffi root module; `link_libc = true`, `pic = true`;
  `installHeadersDirectory("include", "ai")`.
- Per-module test steps (`zig build test-provider`, `test-ai`, …) aggregated
  under `zig build test`; filters via `-Dtest-filter`.

## 17. Testing strategy

- **Upstream tests are the spec.** Every ported unit ships with tests ported
  from (or equivalent to) the upstream vitest suites; behavioral contracts
  called out in the research reports (stream part ordering, abort semantics,
  retry behavior, SSE edge cases, fixJson corpus) are the priority list.
- Recreate `test-server` as an in-process Zig HTTP mock over
  `std.http.Server` (+ `convert-array-to-readable-stream` equivalent for
  canned SSE), since nearly every upstream suite depends on it.
- `std.testing.io` for unit tests; `Io.failing` for error-path tests without
  network; the FFI gets ctypes-driven integration tests plus the
  translate-c ABI-lock test.
- Streaming determinism: pipeline stages are pure over `Reader.fixed` inputs
  (the SSE decoder and event mappers never touch `Io` directly), mirroring
  how `std.crypto.tls.Client` composes Reader→Reader.

## 18. Fidelity ledger (intentional deviations)

Track every deviation here; anything not listed is a bug.

1. Symbol-marker `isInstance` → nominal Zig types + error codes.
2. `secure-json-parse` proto-pollution guard omitted (no prototype chain).
3. PromiseLike-valued spec properties → synchronous possibly-blocking calls.
4. `supportedUrls: RegExp[]` → match-callback in the vtable (no regex engine).
5. NaN usage sentinels → optionals.
6. Ambient-context telemetry execute-wrappers → enter/exit token hooks.
7. `tee()` unbounded buffering → Broadcast log with per-consumer cursors
   (same observable semantics; memory = consumer lag, as upstream).
8. Node `diagnostics_channel` → optional comptime-gated span channel.
9. Gateway hard-import in core → explicit default-provider registration.
10. JS runtime user-agent suffixes (`runtime/node.js/…`) → `runtime/zig/…`.
