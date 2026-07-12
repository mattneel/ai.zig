# Behavioral contracts and sharp edges

What the implementation actually guarantees today. Statements here are
verified against the code and tests as of 2026-07-11; items that are not
yet nailed down are marked **open**. When behavior here diverges from
upstream deliberately, it is also in the porting guide's fidelity ledger.

## Streaming (Broadcast log and cursors)

- Every public stream part is appended to a **Broadcast log** owned by the
  result's arena. The log is the same storage that builds `StepResult`s, so
  retention is **unbounded by design for the life of the result** — this
  matches upstream `tee()` semantics, where memory equals consumer lag.
  Freeing happens at `result.deinit()`, never per-part.
- `next()` (the fullStream pull) is the **sole pipeline driver**. Derived
  cursors (`textStream`, partial-output cursors) replay the log
  independently and **block until the driver advances** past their
  position. A cursor that stops reading costs nothing extra (the log exists
  anyway); it never blocks the driver.
- Promise-like accessors (`text()`, `steps()`, `usage()`, …) call
  `consumeStream()` internally: they **block until the entire multi-step
  operation completes**, then return the recorded value or the recorded
  failure.
- Cursors may be read from different threads; the log is mutex-guarded.
  There is no explicit detach — drop the cursor and stop reading.
- Backpressure: awaited `onChunk` callbacks pause the pipeline (pull-only
  stitchable mode), which backpressures the provider connection directly.

## Tool execution ordering and failure

- `generateText`: approved client tool calls execute **concurrently**
  (isolated per-tool arenas); results are assembled in **tool-call order**
  (stable) regardless of completion order.
- `streamText`: incoming parts keep wire order; after `model_call_end`,
  tool outputs from *different* tools interleave in **completion order**;
  within one tool, preliminary results precede the final result in order.
  Preliminary results are excluded from step records.
- A tool failure (throw) becomes a `tool-error` **part/output — data, not
  an error** — and does not cancel sibling tools or the request; the loop
  can continue with the error fed back to the model.
- Per-tool timeouts surface as the abort path for that tool's execution
  future; the SDK-visible outcome is a tool-error output. Retries apply to
  **model calls only**, never to tool execution (upstream parity).
- Approval-gated calls are never executed while blocked; a blocked call
  halts the loop (output count stays below call count) until the
  application responds.
- **Open:** duplicate tool-call ids within one response are not explicitly
  defended against (upstream relies on provider uniqueness); behavior is
  last-write-wins in id-keyed maps. Needs a defined contract + test.

## Cancellation — three different layers

1. **Unblocking a waiting consumer** (`stream.next()`, FFI
   `ai_stream_next`, Python `Stream.cancel()`): validated sub-millisecond,
   callable from any thread.
2. **In-flight Zig I/O**: cancellation requests are honored at the next
   cancellation point of cancelable I/O operations (Zig 0.16 semantics: a
   request may go unacknowledged, and an operation may still complete
   successfully — cleanup handles both).
3. **User tool code, including Python callbacks: cooperative only.** A
   timeout or cancel returns control to the SDK caller; it does **not**
   preempt callback code already running. The callback may finish later;
   its side effects can occur after the request has already reported
   timeout/abort. CPU-bound Zig tools can add cooperative points via
   `io.checkCancel()`; arbitrary Python code cannot be interrupted safely.

Python specifics: ctypes releases the GIL around blocking C calls and
acquires it for callbacks; concurrent tools may invoke Python callbacks
from multiple pool threads (the GIL serializes actual Python execution).
Python exceptions inside a tool callback are converted to an error status
at the boundary and become tool-error outputs — they never unwind into Zig.

## Tool-approval signatures

Current contract (upstream parity): HMAC-SHA256 with an **application
supplied secret** (`tool_approval_secret`); no secret → approvals are
unsigned, exactly like upstream without `experimental_toolApprovalSecret`.
The signed payload binds: `approval_id`, `tool_call_id`, `tool_name`, and a
base64url SHA-256 digest of the **canonicalized JSON input**.

**Not bound** (open hardening items — adding them would be a deliberate
upstream deviation to ledger): conversation/run id, principal, provider or
model, expiry, nonce/replay protection, the approval decision itself, key
rotation. Treat signatures as request/response integrity within one
process's trust domain, not as bearer tokens across trust boundaries.

## SSRF / download policy

`data:` URLs decoded inline; otherwise http/https only. Blocked by
string-level checks: `localhost`, `*.local`, `*.localhost` (trailing dot
stripped), private/special IPv4 ranges (0/8, 10/8, 100.64/10, 127/8,
169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 198.18/15, ≥240/4), IPv6
loopback/unspecified/ULA/link-local/site-local/multicast plus IPv4-mapped
and NAT64 embeddings. Manual redirect following (≤10 hops) re-validates
every hop; 2 GiB size cap. **No DNS resolution is performed** — a public
hostname that *resolves* to a private address is not caught at this layer
(DNS-rebinding defense is an open item). Tests may opt in to loopback via
`allow_private_networks`.

## Realtime sessions

- State callbacks (`on_status`, `on_messages`, `on_events`,
  `on_is_capturing`, and `on_is_playing`) are serialized. Snapshot delivery
  is monotonic independently for each callback channel: if a newer full-state
  snapshot for a channel has already been delivered, an older snapshot that
  arrives later is coalesced. A newer publication on one channel does not
  suppress an older, still-current snapshot on another channel. Re-entrant
  session changes are queued until the active state callback returns, and no
  state callback runs while the reducer state mutex is held.
- The host-provided `RealtimeAudio` vtable owns playback lifetime.
  `is_playing` becomes true when audio is handed to `play` and becomes
  false only on explicit `stopPlayback` or a server `speech_started`
  barge-in. The core has no playback-completion callback and does not
  automatically clear `is_playing` when host playback finishes.
- `dispose()` is idempotent and safe from session callbacks (deferred and
  executed by the dispatcher) and from foreign threads (lifecycle CAS
  `active → disposing → disposed`; exactly one winner tears down after all
  active calls quiesce; losers are no-ops). Tool handlers that complete
  after disposal have their outputs dropped safely.
- A failed gated `response.create` retains tool-readiness state and
  surfaces through `on_error`; a later readiness trigger (e.g. a redundant
  `response.done`) retries, and an in-flight claim prevents duplicate
  concurrent sends.
- The WebSocket client requires real concurrency (`io.concurrent`) for its
  receive/keepalive tasks — construction fails under a single-threaded Io
  rather than degrading.

## C ABI v1 contract

The header and library report the same packed `1.0.0` ABI version. Packing is
8-bit major, 8-bit minor, 16-bit patch; clients compare the header's
`AI_ABI_VERSION_MAJOR` with the high byte of `ai_abi_version()` before using
the library. All `ai_status`, `ai_part_type`, and other public enum values are
frozen: additions append, and released values are never renumbered or reused.
The ELF SONAME is `libai.so.1`; an ABI break increments both the ABI major and
SONAME major. Public dynamic symbols use only the `ai_` prefix.

Caller-provided config, descriptor, callback, and extensible output structs
start with `size_t struct_size`. Callers set it to `sizeof(struct)`. The v1
library rejects a value smaller than the v1 prefix; it accepts a larger value
and ignores its unknown tail. Future compatible fields append at the end.
`ai_string` is the deliberate exception: it is a frozen two-word borrowed
value returned by value, so changing it requires an ABI-major bump.

Memory and errors:

- Every fallible operation is total for recoverable failures: it returns an
  `ai_status`.
  Operations with an owning runtime or stream record a JSON error document;
  pre-runtime validation and pure clone/blob helpers return status only. A
  Zig panic still aborts the host; no language exception may unwind through
  a C callback.
- `ai_string` getters borrow storage from the documented owner. Result strings
  last until result destruction; runtime/stream error strings last until the
  next failure on that handle or destruction; ABI version text is static.
- Ordinary pointer/length inputs are borrowed only for the call and are copied
  when a returned handle needs them. The exceptions are explicitly retained
  tool callback state and telemetry callback state described below.
- `ai_stream_next` parts borrow per-stream scratch storage until the next call
  on that stream or destruction. `ai_part_clone` clones the JSON field.
- `ai_result_blob` and `ai_part_clone` allocate with the library boundary
  allocator. Free their pointer/length with `ai_buf_free`. Tool callbacks
  allocate successful `ai_tool_result.ptr` with `ai_alloc`; the SDK consumes
  and frees it after the callback returns. Tool input JSON is borrowed only
  during the callback.
- Telemetry event/scope byte views are borrowed only during the callback. An
  enter callback's opaque token remains client-owned and is returned unchanged
  to the paired exit callback.
- Options, schemas, object/embedding results, UI chunks, telemetry events, and
  media metadata use canonical JSON at the ABI boundary. Image and speech
  bytes use indexed result blobs; transcription audio is borrowed for its
  blocking call only. Object schemas are syntax-checked and forwarded as raw
  JSON Schema; because the C surface has no validator callback, applications
  perform semantic JSON-Schema validation of returned objects when required.

Handle ownership, thread safety, and destruction order:

Unless a bullet explicitly permits a race, destroying a handle must not race
an API call that is using that same caller-owned reference. Retained child
references make parent-first teardown safe only after handle creation returns.

- `ai_runtime`: thread-safe reference-counted root owning `std.Io.Threaded`.
  Initialization installs process-global SIGIO/SIGPIPE handlers, restored at
  final release. Children retain it, so the caller may drop its runtime
  reference before children; no new child may be created through a dropped
  reference.
- `ai_provider`: immutable after construction and safe for concurrent model
  creation. It retains the runtime. Models retain it, so provider destroy may
  precede model destroy.
- `ai_model`, `ai_embedding_model`, `ai_image_model`, `ai_speech_model`, and
  `ai_transcription_model`: immutable, safe for concurrent blocking calls, and
  retain their provider/runtime. Active results copy their final data; active
  streams or agents retain the language model they use.
- `ai_result`: immutable and safe for concurrent getters. Each getter borrows
  until `ai_result_destroy`; destruction must not race a getter. Results retain
  only the runtime, not provider/model handles.
- `ai_stream`: exactly one consumer may call `ai_stream_next` at a time.
  `ai_stream_cancel` is safe from any thread and may race a blocked `next`.
  `ai_stream_destroy` must not race `next`: cancel, let the consumer return,
  then destroy. A stream retains its runtime and source owner (model or agent).
- `ai_agent`: immutable configuration after creation, safe for concurrent
  runs, and retains its language model/runtime. Tool callback `user_data` and
  callback code must stay valid until all agent runs/streams finish and the
  agent is destroyed. Streams retain the agent; caller destroy order is
  otherwise flexible.
- `ai_telemetry_registration`: registration borrows callback code and
  `user_data`. Callbacks may run concurrently on runtime pool threads. Unregister
  is a thread-safe logical disable; an already-entered callback may still
  finish, and storage/user data remain valid until `ai_telemetry_clear`.
  Clear is process-global and must not race register/unregister; run it only
  after operations that may hold a copied telemetry dispatcher have quiesced.
  It invalidates registration handles and releases their retained runtimes.

Unknown-to-your-header enum/tag values may appear from a newer library within
the same ABI major. Treat them as opaque; stream consumers fall back to the
part JSON document.

## Explicitly open (tracked in the roadmap)

- Differential conformance harness against the pinned TypeScript SDK with
  a published per-surface pass table.
- Threat-model document (approvals, SSRF/DNS-rebinding, FFI embedding).
- Duplicate tool-call-id contract; approval hardening fields.
