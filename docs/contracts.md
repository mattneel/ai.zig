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

## C ABI (preview) lifetimes

- Stream parts returned by `ai_stream_next` **borrow a per-stream scratch
  arena valid until the next call on that stream** (or destroy); use
  `ai_part_clone` + `ai_buf_free` to retain. One-shot results are
  callee-allocated; free via the paired free functions.
- `ai_stream_cancel` is safe from any thread and may race `ai_stream_next`
  (that is its purpose). `ai_stream_destroy` must **not** race a
  concurrent `next` — cancel, let the consumer return, then destroy.
- Every export is total: failures are status codes + per-handle last-error;
  no panic crosses the boundary. `ai_runtime` owns an `Io.Threaded` whose
  init installs process-global SIGIO/SIGPIPE handlers (restored on
  destroy) — visible to embedding hosts.
- Unknown-to-your-header stream-part tags may appear as new
  `ai_part_type` values in newer libraries: treat unrecognized values as
  opaque and fall back to the part's JSON payload. (Numeric-value
  stability across releases is an ABI v1 commitment, not yet made.)

## Explicitly open (tracked in the roadmap)

- ABI v1 policy: `AI_ABI_VERSION` + runtime query, tag-value stability,
  struct size/version fields, SONAME policy, old-client/new-library
  compatibility tests.
- Differential conformance harness against the pinned TypeScript SDK with
  a published per-surface pass table.
- Threat-model document (approvals, SSRF/DNS-rebinding, FFI embedding).
- Duplicate tool-call-id contract; approval hardening fields.
