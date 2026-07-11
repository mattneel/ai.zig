# ai.zig

**AI SDK semantics. Zig runtime. C portability.**

ai.zig is an **independent, parity-focused Zig 0.16 implementation of the
[Vercel AI SDK](https://github.com/vercel/ai) v7 core**, built on `std.Io`.
It provides `generateText`, `streamText`, multi-step tool execution,
structured output, embeddings, reranking, reusable agents, chat-UI
streaming, and an MCP client across Anthropic, OpenAI, OpenAI-compatible
providers, and OpenRouter — usable directly from Zig or through its C ABI
and Python bindings.

> ai.zig is an independent project and is **not affiliated with or endorsed
> by Vercel**. The upstream SDK is vendored read-only under `inspiration/`
> as the porting reference.

## Status

| Surface | State | Live-tested against | C ABI | Python |
| --- | --- | --- | --- | --- |
| Text generation + streaming | beta | Anthropic, OpenAI (Chat + Responses) | yes | yes |
| Multi-step tool loops (incl. approvals) | beta | Anthropic, OpenAI | yes | yes |
| Structured output (Output strategies) | beta | Anthropic (haiku) | — | — |
| Embeddings / reranking | beta | — (canned fixtures) | — | — |
| Agent (`ToolLoopAgent`) | beta | Anthropic, OpenAI | — | — |
| UI message stream + Chat client | beta | — (canned + in-process e2e) | — | — |
| MCP client (stdio / SSE / streamable HTTP) | beta | real stdio child process | — | — |
| Media (image / speech / transcribe / video) | beta | OpenAI speech→transcribe round trip | — | — |
| Providers: anthropic, openai, openai_compatible, openrouter, xai | beta | per rows above | via generate/stream | via generate/stream |
| **C ABI + Python bindings** | **preview** (pending ABI v1) | Anthropic | — | — |
| Realtime + WebSocket client | beta | OpenAI realtime (gpt-realtime) | — | — |
| Rust bindings | planned | — | — | — |

*Table dated 2026-07-11; live rows name the endpoints actually exercised by
the `-Dlive` gate that session. The full suite is run at every phase gate;
see [docs/roadmap.md](docs/roadmap.md) for per-phase acceptance and
[docs/contracts.md](docs/contracts.md) for the behavioral contracts and
known sharp edges.*

**The C ABI is a tested preview, not yet a stability promise.** A
translate-c test locks the header against the current tree; cross-release
compatibility (ABI versioning, tag-value stability, old-client-new-library
tests) is the ABI v1 work tracked in the roadmap.

## Installing

Not yet published to a package index. Consume it as a Zig package from a
checkout (or your fork):

```zig
// build.zig.zon
.dependencies = .{
    .ai_zig = .{ .path = "../ai.zig" }, // or .url/.hash of a fetched archive
},
```

```zig
// build.zig
const ai_dep = b.dependency("ai_zig", .{ .target = target, .optimize = optimize });
exe_mod.addImport("ai", ai_dep.module("ai"));
exe_mod.addImport("anthropic", ai_dep.module("anthropic"));
exe_mod.addImport("provider_utils", ai_dep.module("provider_utils"));
```

Modules exposed: `ai`, `provider`, `provider_utils`, `anthropic`, `openai`,
`openai_compatible`, `openrouter`, `xai`, `mcp`. For C/Python:
`zig build ffi` produces `zig-out/lib/libai.{a,so*}` + `zig-out/include/ai.h`.

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
        .api_key = api_key, // keys are always explicit — nothing reads your env
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

    std.debug.print("{s}\n", .{result.text()}); // steps, usage, resolved model per step
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

**Structured output** follows the current v7 model: `generateText` /
`streamText` with object, array, choice, and JSON **Output strategies**
(partial-object streaming included). `generateObject` / `streamObject`
compatibility APIs are also provided, matching upstream's
deprecated-but-present surface.

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
returns an iterator whose `cancel()` unblocks a waiting pull from any
thread. See [docs/contracts.md](docs/contracts.md) for the callback,
cancellation, and lifetime rules, and
[bindings/python/README.md](bindings/python/README.md) to build and test.

## Model routing — read this once

Bare string model ids like `"anthropic/claude-…"` resolve through a
**default provider**, which is **OpenRouter** when enabled — meaning those
requests, credentials, and billing go to OpenRouter, not to the named
vendor.

There is no silent path to that behavior: ai.zig never reads ambient
environment variables, so bare ids **fail with an explanatory
`LoadAPIKeyError`** until your application explicitly opts in via
`ai.setDefaultRuntime(gpa, io)` + `ai.setDefaultEnv(...)` (supplying
`OPENROUTER_API_KEY`) or installs its own default with
`ai.setDefaultProvider(...)`. The built-in OpenRouter default can be
compiled out entirely with `-Ddefault-openrouter=false`. To pin the request
path, construct providers explicitly (as in the examples above) — every
step result carries the resolved provider and model id.

## What "parity" means here

Not "1:1". ai.zig targets the upstream **v7 core** at these levels:

1. **Provider wire parity** — request bodies, response mapping, stream-part
   sequences, and error taxonomies match upstream, fixture-tested (many
   fixtures copied verbatim from upstream test suites).
2. **Core behavioral parity** — tool loops, stop conditions, prepareStep,
   output strategies, retry policy, abort semantics: the upstream test
   contracts are ported as Zig tests.
3. **Conceptual API parity** — the upstream mental model with canonical
   names only (deprecated aliases are not carried).
4. **Intentional Zig adaptations** — allocators/arenas, error unions +
   diagnostics, pull-based streams over `std.Io`, explicit cancellation.
   Every deviation is itemized with rationale in the
   [fidelity ledger](docs/porting-guide.md) (§18, 16 entries).
5. **Unsupported surfaces** — see the status table; notably Vercel-Gateway
   routing (replaced by opt-in OpenRouter), realtime (planned), and the
   framework UI bindings (React/Vue/etc. are out of scope; the
   framework-agnostic Chat core they wrap *is* ported).

## Why Zig 0.16

`Io` is passed by value like `Allocator`; `io.async`/`Future.cancel` give
structured concurrency where cancelable I/O operations report
`error.Canceled` at well-defined points; `Io.Queue(T)` is an MPMC channel
with suspend-based backpressure — a natural analog of the SDK's
`ReadableStream` pipelines. `std.http.Client`, TLS 1.2/1.3, and `std.json`
are stdlib-provided and `Io`-integrated. Code written against `std.Io`
today (threaded backend) is positioned to use future evented/io_uring
backends with little or no public API change. Streaming, concurrency,
cancellation, and the network layer are ported in full — a blocking-only
port would have been a failed port.

Cancellation is layered, and the layers differ (see
[docs/contracts.md](docs/contracts.md)): unblocking a waiting `next()` is
immediate; in-flight I/O cancels at its next cancellation point; **user
tool code is cooperative** — a timeout or cancel unblocks the SDK caller
but cannot preempt arbitrary callback code still running.

## Architecture

```
ai ───────────────┬──▶ provider_utils ──▶ provider        (pure spec: types + vtables)
providers/* ──────┤        openrouter (default), openai, anthropic,
mcp ──────────────┘        openai_compatible, xai, …
ffi (libai.a / libai.so + ai.h) ──▶ ai                    (C ABI over everything)
```

- **`provider`** — the V4 specification: model vtables, the 21-tag
  stream-part union, prompt/content types, usage, errors + diagnostics,
  and the canonical JSON wire codec (comptime-exhaustive tag tables).
- **`provider_utils`** — `HttpTransport` over `std.http.Client`, WHATWG SSE
  decoder, retry engine, partial-JSON repair, schema abstraction,
  multipart encoder, SSRF-guarded downloads.
- **`ai`** — generate/stream text and objects, agent, prompt conversion,
  registry, middleware, telemetry, the streaming pipeline (Broadcast part
  log + stitchable multi-step stream over `Io.Queue`), UI message stream +
  Chat, media orchestration.
- **`mcp`** — JSON-RPC client, stdio/SSE/streamable-HTTP transports, MCP
  tools bridged into the tool loop.
- **`ffi`** — opaque handles, `enum(c_int)` statuses, pull-based stream
  iteration with borrow-until-next-call parts, callback tools.

## Building and testing

Uses [anyzig](https://github.com/marler8997/anyzig); the pinned compiler
comes from `build.zig.zon` (**0.16.0**).

| Command | Purpose |
| --- | --- |
| `zig build test` | full suite (per-module aggregates) |
| `zig build test-ai` / `test-provider` / `test-mcp` / … | one module |
| `zig build test -Dtest-filter=sse` | filter by test-name substring |
| `zig build test-integration -Dlive` | live API smokes (explicit keys required) |
| `zig build ffi` | build `libai` + install `include/ai.h` |
| `python3 -m pytest bindings/python` | Python binding suite |

Contributor ground rules (humans and agents): [`AGENTS.md`](AGENTS.md).
When the compiler pushes back, the stdlib source at `zig env`'s `.std_dir`
is the documentation.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | the implementation (one directory per module) |
| `include/ai.h` | the hand-written C ABI header (ABI-locked by test) |
| `bindings/python/` | the `ai_zig` ctypes package + pytest suite |
| `inspiration/` | vendored Vercel AI SDK monorepo — **read-only** reference |
| `docs/porting-guide.md` | TS→Zig mapping + the fidelity ledger |
| `docs/contracts.md` | behavioral contracts, lifetimes, known sharp edges |
| `docs/roadmap.md` | phased plan, acceptance criteria, completion status |
| `docs/research/` | deep research reports + working Zig 0.16 prototypes |

## Upstream pin

`inspiration/` tracks [vercel/ai](https://github.com/vercel/ai) at the
**v7** major (`ai@7.0.22`, `@ai-sdk/provider@4.0.3` — interface version
**V4**, `@ai-sdk/provider-utils@5.0.7`).

## License

[Apache-2.0](LICENSE), with attribution and provenance in [NOTICE](NOTICE).
The vendored upstream tree under `inspiration/` retains its own Apache-2.0
license (Copyright Vercel, Inc.). ai.zig is not affiliated with or endorsed
by Vercel.
