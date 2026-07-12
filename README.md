# ai.zig

**AI SDK semantics. Zig runtime. C portability.**

ai.zig is an **independent, parity-focused Zig 0.16 implementation of the
[Vercel AI SDK](https://github.com/vercel/ai) v7 core**, built on `std.Io`.
It provides `generateText`, `streamText`, multi-step tool execution,
structured output, embeddings, reranking, reusable agents, UI message
streams with a framework-agnostic Chat client, and an MCP client across the
supported providers listed below — usable directly from Zig or through its
C ABI, Python bindings, and Rust `-sys` + safe wrapper.

**Documentation:** [Getting Started](https://mattneel.github.io/ai.zig/getting-started.html) ·
[Providers](https://mattneel.github.io/ai.zig/providers/index.html) · [C ABI](https://mattneel.github.io/ai.zig/c-abi.html) ·
Bindings ([Python](https://mattneel.github.io/ai.zig/bindings/python.html), [Rust](https://mattneel.github.io/ai.zig/bindings/rust.html))

> ai.zig is an independent project and is **not affiliated with or endorsed
> by Vercel**. The upstream SDK is vendored read-only under `inspiration/`
> as the porting reference.

## Status

| Surface | State | Live-tested against | C ABI | Python | Rust |
| --- | --- | --- | --- | --- | --- |
| Text generation + streaming | beta | Anthropic, OpenAI (Chat + Responses) | yes | yes | yes |
| Multi-step tool loops (incl. approvals) | beta | Anthropic, OpenAI | yes | yes | yes |
| Structured output (Output strategies) | beta | Claude Haiku 4.5 | objects | objects | objects |
| Embeddings / reranking | beta | — (canned fixtures) | embeddings | embeddings | embeddings |
| Agent (`ToolLoopAgent`) | beta | Anthropic, OpenAI | yes | yes | yes |
| UI message stream + Chat client | beta | — (canned + in-process e2e) | UI chunks | UI chunks | UI chunks |
| MCP client (stdio / SSE / streamable HTTP) | beta | stdio live (child process); SSE + streamable HTTP via canned fixtures | — | — | — |
| Media: image / speech / transcribe / video | beta | speech→transcribe live; image + video via canned fixtures | image/speech/transcribe | image/speech/transcribe | image/speech/transcribe |
| Providers: anthropic, google, openai, openai_compatible, openrouter, xai | beta | per rows above | via generate/stream (google pending) | all listed except google (C ABI pending) | all listed except google (C ABI pending) |
| Realtime + WebSocket client | beta | OpenAI realtime (gpt-realtime) | — | — | — |
| Rust bindings | beta | Anthropic streaming + tool callback | full ABI v1 | — | full ABI v1 |

*Last verified: 2026-07-11. The "Live-tested against" column reports the endpoints exercised by that
successful `-Dlive` gate; other cells state the non-live coverage. The full suite runs at every phase
gate; see [docs/roadmap.md](docs/roadmap.md) for per-phase acceptance and
[docs/contracts.md](docs/contracts.md) for behavioral contracts and known sharp edges.*

**Stability vocabulary:** `beta` means implemented and covered by the full test suite, but the Zig API
may still change. `preview` means narrower coverage and no compatibility guarantee.

The [**C ABI v1 policy**](https://mattneel.github.io/ai.zig/c-abi.html) is implemented and enforced in-tree;
cross-release verification against tagged artifacts begins with the first tagged release. The Python
and Rust packages wrap every ABI v1 surface listed in the table and run offline integration suites in
CI, but neither is published; their language-level APIs remain preview while packaging and downstream feedback settle.

GitHub Actions runs the full test suite on Linux, macOS, and Windows across x86_64 and arm64 (six
runners), plus formatting, Python-wrapper, Rust-wrapper, and differential-conformance jobs; Windows FFI artifacts target MinGW.

## Installing

Not yet published to a package index. Consume it as a Zig package from a checkout (or your fork):

```zig
// build.zig.zon
.dependencies = .{ .ai_zig = .{ .path = "../ai.zig" } },

// build.zig
const ai_dep = b.dependency("ai_zig", .{ .target = target, .optimize = optimize });
exe_mod.addImport("ai", ai_dep.module("ai"));
```

See [Getting Started](https://mattneel.github.io/ai.zig/getting-started.html) for fetched dependencies, provider imports, and a complete program.

## Quick start

With `chat` created from a configured provider factory (see [Getting Started](https://mattneel.github.io/ai.zig/getting-started.html) for the full setup), streaming is a pull loop over a typed part union:

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

Continue with [structured output](https://mattneel.github.io/ai.zig/structured-output.html),
[tools](https://mattneel.github.io/ai.zig/tools.html), and [agents](https://mattneel.github.io/ai.zig/agents.html).

## Bindings

The unpublished [Python](https://mattneel.github.io/ai.zig/bindings/python.html) and [Rust](https://mattneel.github.io/ai.zig/bindings/rust.html)
packages are language-idiomatic wrappers over [C ABI v1](https://mattneel.github.io/ai.zig/c-abi.html). Their chapters cover the complete
surfaces, build and lifetime contracts, callback containment, cancellation, and live-tested examples.

## Model routing — read this once

Bare string model ids like `"anthropic/claude-…"` resolve through a **default provider**, which is
**OpenRouter** when enabled — meaning requests, credentials, and billing go to OpenRouter, not to the named vendor.
ai.zig does not inspect the process environment implicitly: until the application explicitly configures a default
provider, a bare id fails with an explanatory `LoadAPIKeyError` and sends no request. Compile the built-in OpenRouter path out with
`-Ddefault-openrouter=false`; see [Providers](https://mattneel.github.io/ai.zig/providers/index.html#explicit-models-versus-bare-ids).

## What "parity" means here

Not "1:1". ai.zig targets the upstream **v7 core** at these levels:

1. **Provider wire parity** — for supported provider/surface combinations, request bodies, response mapping,
   stream-part sequences, and error taxonomies match upstream except for deviations recorded in the fidelity ledger.
   This is fixture-tested, including fixtures derived from the upstream suites.
2. **Core behavioral parity** — tool loops, stop conditions, prepareStep, output strategies, retry policy, abort
   semantics: the relevant upstream fixtures and behavioral contracts are ported as Zig tests.
3. **Conceptual API parity** — the upstream v7 mental model and canonical names are primary. Selected deprecated
   compatibility APIs (`generateObject` and `streamObject`) are retained where they materially ease migration and
   are clearly marked as deprecated.
4. **Intentional Zig adaptations** — allocators/arenas, error unions + diagnostics, pull-based streams over `std.Io`,
   explicit cancellation. Every deviation is itemized with rationale in the [fidelity ledger](docs/porting-guide.md) (§18).
5. **Unsupported surfaces** — see the status table; notably Vercel AI Gateway routing (replaced by opt-in OpenRouter)
   and the framework UI bindings (React/Vue/etc. are out of scope; the framework-agnostic Chat core they wrap *is* ported).

## Architecture

```
ai ───────────────┬──▶ provider_utils ──▶ provider        (pure spec: types + vtables)
providers/* ──────┤        openrouter (default), openai, anthropic,
mcp ──────────────┘        openai_compatible, xai, …
ffi (libai.a / libai.so + ai.h) ──▶ ai                    (C ABI over everything)
```

See [Core Concepts](https://mattneel.github.io/ai.zig/core-concepts.html#module-responsibilities) for module responsibilities and the `std.Io` runtime design.

## Building and testing

`zig build test` runs the full suite; live API smokes are opt-in via `zig build test-integration -Dlive`
and require explicit keys. See [Development](https://mattneel.github.io/ai.zig/development.html) for all commands and
[`AGENTS.md`](AGENTS.md) for contributor ground rules.

## Upstream pin

`inspiration/` tracks [vercel/ai](https://github.com/vercel/ai) at the **v7** major (`ai@7.0.22`,
`@ai-sdk/provider@4.0.3` — interface version **V4**, `@ai-sdk/provider-utils@5.0.7`).

## License

[Apache-2.0](LICENSE), with attribution and provenance in [NOTICE](NOTICE).
The vendored upstream tree under `inspiration/` retains its own Apache-2.0
license (Copyright Vercel, Inc.). ai.zig is not affiliated with or endorsed
by Vercel.
