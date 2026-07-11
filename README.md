# ai.zig

A **1:1 port of the [Vercel AI SDK](https://github.com/vercel/ai) to Zig 0.16**,
built on Zig's new `std.Io` interface, with a **stable C ABI** and
language-idiomatic wrappers (Python, Rust, …) on top.

One SDK for talking to LLMs — `generateText`, `streamText`, `generateObject`,
tool calling, the multi-step agent loop, embeddings, reranking, media
generation, MCP, realtime — with the same capabilities and the same mental
model as the upstream TypeScript SDK, expressed in idiomatic Zig and callable
from any language that can speak C.

## Why

- **The upstream SDK is the best-designed provider abstraction in the
  ecosystem.** Its layered architecture (`provider` spec → `provider-utils`
  plumbing → concrete providers → `ai` core) and its exhaustive
  discriminated-union protocol for streaming map *directly* onto Zig tagged
  unions and vtables. The design ports almost mechanically; the concurrency
  is where the real work lives.
- **Zig 0.16's `std.Io` is the right substrate for it.** `Io` is passed by
  value like `Allocator`; `io.async`/`Future.cancel` give structured
  concurrency with first-class cancelation (`error.Canceled` in every I/O
  error set); `Io.Queue(T)` is an MPMC channel with suspend-based
  backpressure — the natural analog of the SDK's `ReadableStream` pipelines.
  `std.http.Client`, TLS 1.2/1.3, and `std.json` are stdlib-provided and
  already `Io`-integrated. Code written against `Io` today (threaded backend)
  gets the evented/io_uring backend for free when it lands.
- **A C ABI makes it universal.** The core is "colorblind" Zig taking an
  `io: Io` parameter; the FFI layer wraps it in a long-lived opaque runtime
  handle with blocking calls, pull-based streaming, and sub-millisecond
  cancelation — validated against Python `ctypes` during research
  (see `docs/research/prototypes/cabi/`).

## What "1:1" means

Feature parity and conceptual parity with upstream — same functions, same
stream-part vocabulary, same behavioral contracts (the upstream test suites
are the spec) — not a line-by-line transliteration of TypeScript. Where
JavaScript idioms have no Zig analog (prototype-pollution guards, Symbol
markers, `Promise` laziness), the porting guide documents the exact deviation
and its rationale.

**Non-negotiable:** streaming, concurrency, cancelation, and the network
layer are the heart of this SDK and are ported in full. A blocking-only port
is a failed port.

## Status

**Research & planning.** The upstream SDK (pinned as a submodule at
`inspiration/`, currently `ai@7.0.22` / provider spec **V4**) and the Zig
0.16 stdlib have been researched in depth; the results live in
[`docs/research/`](docs/research/). Implementation follows the
[roadmap](docs/roadmap.md). No SDK code exists yet — `src/` is scaffold.

## Architecture at a glance

The Zig module graph mirrors the npm dependency spine:

```
ai ───────────────┬──▶ provider_utils ──▶ provider        (pure spec: types + vtables)
  └──▶ gateway ───┤
providers/* ──────┘        openai, anthropic, google, openai_compatible, …
mcp ──────────────┘
ffi (libai.a / libai.so + ai.h) ──▶ ai                    (C ABI over everything)
```

- **`provider`** — the specification: `LanguageModelV4` et al., the 21-variant
  stream-part union, prompt/content types, usage, errors. Pure data + vtables.
- **`provider_utils`** — HTTP transport over `std.http.Client`, SSE decoder,
  retry with backoff, safe JSON, schema abstraction, id generation.
- **`gateway`** — Vercel AI Gateway provider (the upstream default for string
  model ids; wire format *is* the normalized SDK types).
- **`ai`** — `generateText`/`streamText` (multi-step tool loop),
  `generateObject`/`streamObject`, `embed`/`embedMany`, `rerank`, Agent,
  middleware, registry, UI message stream protocol, media generation.
- **`ffi`** — the C ABI: opaque handles, status codes, pull-based stream
  iteration, callback registration; ships `ai.h` plus static & shared libs.

## Toolchain

This repo uses [anyzig](https://github.com/marler8997/anyzig); the pinned
compiler version comes from `build.zig.zon` (`0.16.0`).

```sh
zig build test        # run the tests
zig env               # locate the real compiler + stdlib source (.std_dir)
```

When the compiler rejects something, the stdlib source at `zig env`'s
`.std_dir` is the documentation. Required reading for contributors (humans
and agents): [`AGENTS.md`](AGENTS.md), then the Zig 0.16 release-notes
sections *"I/O as an Interface"* and *"Juicy Main"*.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | the Zig implementation (scaffold today) |
| `inspiration/` | vendored Vercel AI SDK monorepo — **read-only** porting source of truth |
| `docs/porting-guide.md` | concrete TS→Zig mapping: types, streaming, memory, network, FFI |
| `docs/roadmap.md` | phased implementation plan with acceptance criteria |
| `docs/research/` | deep research reports on upstream internals and Zig 0.16 idioms |
| `docs/research/prototypes/` | working 0.16 proofs: SSE-over-HTTP client, C ABI + Python ctypes |
| `AGENTS.md` | rules for all agents working in this repo |

## Upstream pin

`inspiration/` tracks [vercel/ai](https://github.com/vercel/ai) at the
**v7** major (`ai@7.0.22`, `@ai-sdk/provider@4.0.3` — interface version
**V4**, `@ai-sdk/provider-utils@5.0.7`). The port targets V4 exclusively;
legacy v2/v3 spec versions are out of scope.

## License

TBD (upstream is Apache-2.0).
