# ai.zig

A **1:1 port of the [Vercel AI SDK](https://github.com/vercel/ai) to Zig 0.16**,
built on Zig's new `std.Io` interface, with a **stable C ABI** and
language-idiomatic wrappers (Python today, Rust planned) on top.

One SDK for talking to LLMs — `generateText`, `streamText`, multi-step
agentic tool loops, structured output, embeddings, reranking — with the same
capabilities and the same mental model as the upstream TypeScript SDK,
expressed in idiomatic Zig and callable from any language that can speak C.

## Status

**Core implemented and live-validated** (roadmap phases 0–8 of 12):

- `generateText` / `streamText` with the full multi-step tool loop —
  stop conditions, `prepareStep`, tool-call repair/refinement, approvals
  (HMAC-signed), concurrent tool execution with streamed preliminary
  results, total/step/chunk/per-tool timeouts, retries with `Retry-After`
- `generateObject` / `streamObject` and the output strategies
  (object/array/choice/json) with partial-object streaming over
  repair-based incremental JSON parsing
- `embed` / `embedMany` (wave-parallel batching) and `rerank`
- `ToolLoopAgent` over any provider
- Providers: **anthropic** (native, incl. thinking/cache-control/betas),
  **openai** (Chat Completions *and* the item-based Responses API),
  **openai_compatible** (the vendor template), **openrouter** (default
  provider for bare `"vendor/model"` ids)
- Telemetry vtable + dispatcher, warning logger, provider registry,
  middleware (`wrapLanguageModel`, extract-reasoning/JSON, simulate
  streaming, smooth-stream transform)
- **C ABI** (`libai.a` / `libai.so` + hand-written `ai.h`, ABI-locked by a
  translate-c test) and **Python ctypes bindings** — a Python tool callback
  executes inside the Zig agentic loop; streams cancel cross-thread in
  sub-millisecond time

430+ Zig tests plus a Python suite; every phase gate includes live smokes
against real Anthropic and OpenAI endpoints (`-Dlive`). Remaining phases:
UI message stream + MCP, media generation, realtime/WebSocket, FFI v1 +
Rust crate ([roadmap](docs/roadmap.md)).

## Using it (Zig)

A two-step agentic call — the model asks for a tool, ai.zig runs it and
feeds the result back, the model answers:

```zig
const std = @import("std");
const ai = @import("ai");
const anthropic = @import("anthropic");
const provider_utils = @import("provider_utils");

const Weather = struct {
    fn execute(
        _: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        _ = input; // {"city": "..."} — validated against the schema below
        var output: std.json.ObjectMap = .empty;
        try output.put(arena, "condition", .{ .string = "sunny" });
        try output.put(arena, "temperature", .{ .integer = 21 });
        return .{ .value = .{ .object = output } };
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, api_key: []const u8) !void {
    var transport = provider_utils.HttpClientTransport.init(gpa, io);
    defer transport.deinit();

    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key,
        .transport = transport.transport(),
    });
    var chat = try factory.messages("claude-haiku-4-5-20251001", null);

    const tools = [_]ai.NamedTool{.{
        .name = "weather",
        .tool = .{
            .description = .{ .text = "Get the weather for a city" },
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = null, .execute_fn = Weather.execute },
        },
    }};

    var result = try ai.generateText(io, gpa, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.stepCount(5)},
    });
    defer result.deinit();

    std.debug.print("{s}\n", .{result.text()}); // steps, usage, messages all on result
}
```

Streaming is a pull loop over a typed part union:

```zig
var stream = try ai.streamText(io, gpa, .{
    .model = .{ .model = chat.languageModel() },
    .prompt = .{ .text = "Write a haiku about comptime." },
});
defer stream.deinit(io);

while (try stream.next(io)) |part| switch (part) {
    .text_delta => |delta| std.debug.print("{s}", .{delta.text}),
    .finish => |finish| std.debug.print("\n[{t}]\n", .{finish.finish_reason.unified}),
    else => {},
};
```

The same loop runs `tool_call` / `tool_result` / `reasoning_delta` /
`finish_step` parts during agentic streams; `stream.textStream(io)` gives an
independent text-only cursor, and accessors like `stream.text()` auto-drain.

## Using it (Python)

```python
from ai_zig import Runtime, Tool, generate_text, openai_compatible

with Runtime() as runtime:
    with openai_compatible(runtime, name="local",
                           base_url="http://127.0.0.1:8000/v1",
                           api_key="explicit-key") as provider:
        with provider.language_model("model-id") as model:
            weather = Tool("weather", lambda args: {"temperature": 21})
            result = generate_text(model, prompt="Weather in Paris?",
                                   tools=[weather], max_steps=2)
            print(result["text"])
```

The tool lambda runs *inside* the Zig loop via a C callback; `stream_text`
returns an iterator whose `cancel()` interrupts a blocked pull from any
thread. Build and test: `zig build ffi && python3 -m pytest bindings/python`
(see [bindings/python/README.md](bindings/python/README.md)).

## Architecture

The implemented module graph mirrors the npm dependency spine:

```
ai ───────────────┬──▶ provider_utils ──▶ provider        (pure spec: types + vtables)
providers/* ──────┤        openrouter (default), openai, anthropic,
mcp (phase 9) ────┘        openai_compatible, …
ffi (libai.a / libai.so + ai.h) ──▶ ai                    (C ABI over everything)
```

(Upstream's `@ai-sdk/gateway` — Vercel's hosted proxy — is skipped; bare
`"vendor/model"` string ids resolve through a thin **OpenRouter** provider
by default, runtime-overridable and compile-out-able via
`-Ddefault-openrouter=false`. See porting guide §11.)

- **`provider`** — the V4 specification: `LanguageModel` et al., the 21-tag
  stream-part union, prompt/content types, usage, errors + `Diagnostics`,
  and the canonical JSON wire codec (comptime-exhaustive tag tables).
- **`provider_utils`** — `HttpTransport` over `std.http.Client`, the WHATWG
  SSE decoder, retry engine, `fixJson`/partial-JSON, schema abstraction,
  SSRF-guarded downloads.
- **`ai`** — the core: generate/stream text and objects, agent, prompt
  conversion, registry, middleware, telemetry, and the streaming pipeline
  (Broadcast part log + stitchable multi-step stream over `Io.Queue`).
- **`ffi`** — opaque handles, `enum(c_int)` statuses, pull-based stream
  iteration with borrow-until-next-call parts, callback tools.

## Why Zig 0.16

`Io` is passed by value like `Allocator`; `io.async`/`Future.cancel` give
structured concurrency with first-class cancelation (`error.Canceled` in
every I/O error set); `Io.Queue(T)` is an MPMC channel with suspend-based
backpressure — the natural analog of the SDK's `ReadableStream` pipelines.
`std.http.Client`, TLS 1.2/1.3, and `std.json` are stdlib-provided and
already `Io`-integrated. Code written against `Io` today (threaded backend)
gets the evented/io_uring backend for free when it lands. **Streaming,
concurrency, cancelation, and the network layer are ported in full** — a
blocking-only port would be a failed port.

## Building and testing

This repo uses [anyzig](https://github.com/marler8997/anyzig); the pinned
compiler comes from `build.zig.zon` (**0.16.0**).

| Command | Purpose |
| --- | --- |
| `zig build test` | full suite (per-module aggregates) |
| `zig build test-ai` / `test-provider` / `test-anthropic` / … | one module |
| `zig build test -Dtest-filter=sse` | filter by test-name substring |
| `zig build test-integration -Dlive` | live API smokes (needs real keys) |
| `zig build ffi` | build `libai.a`, `libai.so.*`, install `include/ai.h` |
| `python3 -m pytest bindings/python` | Python binding suite |
| `zig env` | locate the real compiler + stdlib source (`.std_dir`) |

When the compiler rejects something, the stdlib source at `.std_dir` is the
documentation. Required reading for contributors (humans and agents):
[`AGENTS.md`](AGENTS.md), then the Zig 0.16 release-notes sections
*"I/O as an Interface"* and *"Juicy Main"*.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | the Zig implementation (one directory per module) |
| `include/ai.h` | the hand-written C ABI header (ABI-locked by test) |
| `bindings/python/` | the `ai_zig` ctypes package + pytest suite |
| `inspiration/` | vendored Vercel AI SDK monorepo — **read-only** source of truth |
| `docs/porting-guide.md` | TS→Zig mapping: types, streaming, memory, network, FFI, fidelity ledger |
| `docs/roadmap.md` | phased plan with acceptance criteria and completion status |
| `docs/research/` | deep research reports + working Zig 0.16 prototypes |
| `AGENTS.md` | rules for all agents working in this repo |

## Upstream pin

`inspiration/` tracks [vercel/ai](https://github.com/vercel/ai) at the
**v7** major (`ai@7.0.22`, `@ai-sdk/provider@4.0.3` — interface version
**V4**, `@ai-sdk/provider-utils@5.0.7`). The port targets V4 exclusively.
Intentional deviations are itemized in the porting guide's
[fidelity ledger](docs/porting-guide.md) (§18) — currently 16 entries, each
with rationale.

## License

TBD (upstream is Apache-2.0).
