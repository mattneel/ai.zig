# Core Concepts

ai.zig keeps the upstream mental model while making execution, allocation,
and failure detail explicit. The same four rules recur across providers,
orchestration, realtime, MCP, and the C ABI.

## `std.Io` is an explicit capability

Zig 0.16 passes `std.Io` by value, like `std.mem.Allocator`. Public operations
that may sleep, spawn work, read a socket, or drive a stream receive an `io`
argument. An executable normally obtains it from `std.process.Init`:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    _ = io;
    _ = gpa;
}
```

`HttpClientTransport.init(gpa, io)` owns a `std.http.Client` and exposes the
type-erased `provider_utils.HttpTransport` vtable providers consume. The
transport, provider model, and orchestration call all receive the same I/O
capability. Tool callbacks also receive the task's `std.Io`, allowing
cooperative cancellation through `io.checkCancel()`.

Concurrent operations use `std.Io.Group`, `io.async`/`io.concurrent`, futures,
events, mutexes, and `Io.Queue`. A constrained I/O implementation may support
an explicitly documented inline degradation for some operations. The
WebSocket client is different: it requires real concurrency for receive and
keepalive tasks and reports `ConcurrencyUnavailable` rather than pretending a
blocking-only transport is equivalent.

## Allocators and arenas

At the provider boundary, `LanguageModel.doGenerate` and `doStream` receive a
caller-owned arena. Returned provider content, usage metadata, and request
metadata borrow that arena. A provider `PartStream` uses a tighter
borrow-until-next-call rule for each pulled part.

High-level operations such as `generateText`, `embed`, and `generateObject`
allocate an internal `ArenaAllocator` from the supplied general-purpose
allocator. Their result types own that arena and expose `deinit()`. Streaming
results use `deinit(io)` because teardown may cancel or join I/O work.

Use one short-lived arena for request assembly and parse work; retain the
owning result for as long as any returned slice is needed. Never free or reset
an arena while provider values still point into it.

## Messages and `CallOptions`

`provider.Message` is the provider-level prompt union:

- `system` holds text plus optional provider options;
- `user` holds text and file content parts;
- `assistant` can hold text, reasoning, files, tool calls, and approval
  requests;
- `tool` holds tool results and approval responses.

The high-level `ai` module accepts a simple `prompt`, full `ModelMessage`
values, and optional instructions, then standardizes and converts them into
the provider prompt. `provider.CallOptions` is the shared provider contract
for the already-converted prompt plus model settings:

| Group | Fields |
| --- | --- |
| Sampling | `max_output_tokens`, `temperature`, `top_p`, `top_k`, penalties, `seed`, `stop_sequences` |
| Output | `response_format`, `reasoning`, `include_raw_chunks` |
| Tools | `tools`, `tool_choice` |
| Request | `headers`, `provider_options` |

Provider-specific options are JSON under provider namespaces. Standardized
settings are validated before the provider call; unsupported combinations
usually become typed warnings rather than silently changing wire data.

## Errors and `Diagnostics`

The Zig error union carries a stable structural category such as
`APICallError`, `InvalidPromptError`, `NoSuchModelError`,
`InvalidToolInputError`, `NoObjectGeneratedError`, or `RetryError`.
`provider.Error` currently contains 36 SDK categories covering configuration,
wire parsing, prompts, tools and approvals, structured output, media, UI
messages, downloads, provider resolution, and retries.

The optional `*provider.Diagnostics` supplies owned structured context without
replacing the original error. Its tagged payload includes fields such as URL,
HTTP status, retryability, response body, parameter name, model id, offending
JSON, available tools, finish reason, and accumulated retry messages. Setting
new diagnostics resets only the diagnostics-owned arena.

```zig
var diagnostics = provider.Diagnostics.init(gpa);
defer diagnostics.deinit();

const value = operation(&diagnostics) catch |err| {
    if (diagnostics.available) {
        const message = try diagnostics.message(arena);
        std.log.err("{s}: {s}", .{ @errorName(err), message });
    }
    return err;
};
_ = value;
```

Mid-stream provider failures are usually stream data (`err` parts) so the
consumer observes their position relative to other parts. Machinery failures
from `next()` remain Zig errors.

## Retry behavior

Model operations default to two retries: up to three attempts total. The
default delay starts at 2000 ms and doubles. HTTP 408, 409, 429, and 5xx
responses are classified as retryable by the common error path. Cancellation
propagates immediately and is never wrapped.

The first non-retryable error is returned unchanged. If a later attempt turns
non-retryable, or the retry budget is exhausted, the operation returns
`RetryError` and diagnostics preserve the reason and captured messages. Tool
execution is never retried by this engine; model calls are.

See the normative [Behavioral Contracts](appendix/contracts.md) for stream
retention, cancellation layers, approval signatures, and ownership edges.

