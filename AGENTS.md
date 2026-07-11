# AGENTS.md — ai.zig

Instructions for all agents working in this repository.

## Objective

A **1:1 port of the Vercel AI SDK to Zig 0.16**, built on Zig's new `std.Io`
model, plus a **C ABI (FFI) layer** with language-idiomatic wrappers
(Python, Rust, etc.) on top of it.

"1:1" means feature parity and conceptual parity — same capabilities, same
mental model (`generateText`, `streamText`, `generateObject`, `embed`, tool
calling, agent loop, provider abstraction, middleware) — expressed in
idiomatic Zig, not transliterated TypeScript.

## Non-negotiables

1. **Do not skip or stub concurrency, async, streaming, or network code
   because it is difficult.** Streaming and the async model are the core of
   this SDK, not an optional extra. A port that only does blocking
   `generateText` is a failure.
2. **Compiler errors are signal, not noise.** When Zig 0.16 rejects your
   code, the error is directing you to read the standard library source and
   learn the current idiom. Do not downgrade the approach, hand-wave with
   `anyopaque`, or give up. Open the stdlib and read how it does it.
3. **The stdlib source is the documentation.** Zig 0.16's `std.Io` is new
   and thinly documented online; your training data is likely stale. The
   authoritative reference is the stdlib shipped with the exact compiler
   this repo pins (see Toolchain below). Read `std/Io.zig`, `std/Io/`,
   `std/http/`, and their tests before designing anything that does I/O.

## Toolchain: anyzig

The `zig` on PATH is **anyzig**, a wrapper that multiplexes real Zig
versions:

- `zig <cmd>` — resolves the version from `.minimum_zig_version` in the
  `build.zig.zon` of the CWD (this repo pins **0.16.0**).
- `zig <version> <cmd>` — explicitly runs that version
  (e.g. `zig 0.16.0 build test`).
- `zig env` — prints where the real compiler lives. Key fields:
  - `.zig_exe` — the actual compiler binary
  - `.std_dir` — **the stdlib source; read code here for idioms**

Currently that resolves to:

```
/home/autark/.cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std
```

Do not hardcode that hash-path in code or docs other than this note — always
re-derive it with `zig env` (it changes when the pinned version changes).

## Reference material: `inspiration/`

The Vercel AI SDK is vendored as a git submodule at `inspiration/`
(https://github.com/vercel/ai). This is the porting source of truth.
Key locations:

- `inspiration/packages/ai/src/` — core SDK: `generate-text/` (incl.
  streaming + tool loop), `generate-object/`, `embed/`, `agent/`,
  `prompt/`, `middleware/`, `registry/`, `ui-message-stream/`, `error/`
- `inspiration/packages/provider/` — the provider **specification**
  (LanguageModelV3 et al.): the interface every provider implements
- `inspiration/packages/provider-utils/` — shared provider plumbing:
  HTTP/SSE helpers, JSON parsing, schema validation
- `inspiration/packages/openai/`, `anthropic/`, `google/`, ... — concrete
  providers
- `inspiration/packages/mcp/` — Model Context Protocol client

When porting a feature, read the TypeScript implementation *and its tests*
first; the tests encode the behavioral contract you must preserve.

Never modify anything under `inspiration/` — it is read-only reference.

## Reference material: `/mnt/c/src/zig-corpora`

Idiomatic Zig 0.16.0 reference code and material lives outside the repo at
`/mnt/c/src/zig-corpora/`:

- `relnotes/release-notes.md` — the **Zig 0.16.0 release notes**.
  ⚠ The file is UTF-16LE with CRLF; convert before grepping:
  `iconv -f UTF-16LE -t UTF-8 release-notes.md`.
  **Required reading before writing any code:**
  - *"Juicy Main"* — the new entry point: `pub fn main(init: std.process.Init)`
    hands you `init.io` (the `Io` instance), `init.gpa`, `init.arena`,
    `init.environ_map`, and `init.minimal.args`. There is no global
    allocator, no global environ, and no global Io — everything threads
    through parameters.
  - *"I/O as an Interface"* — the new `std.Io` model. `Io` is passed by
    value like `Allocator`; concrete implementations include
    `Io.Threaded`, `Io.Uring`, etc. This is the async/concurrency
    foundation the whole port stands on.
- `ziglang/` — the full ziglang/zig source tree (`lib/std/` is the stdlib,
  `doc/`, compiler `src/`) for cross-referencing idioms and finding usage
  examples of new APIs (`grep -r` here when unsure how something is used).
- `ziex/` — a full-stack Zig web framework: a large idiomatic Zig 0.16
  codebase, useful as an example of real-world `Io`, HTTP, and build usage.
- `translate-c/` — the translate-c project.

## C FFI layer

A first-class goal, not an afterthought: a stable C ABI (`export fn` /
`extern struct`, built as both static and shared library) exposing the SDK
to other languages, with idiomatic wrapper packages (Python via ctypes/cffi,
Rust via a `-sys` crate + safe wrapper, etc.).

Design constraints this imposes on the core:

- Every public capability needs a C-representable surface: opaque handles,
  explicit create/destroy, error codes + `last_error` style detail,
  callback-based streaming (function pointer + `user_data`).
- Memory ownership across the boundary must be explicit and documented;
  the library allocates, the library frees.
- No Zig-only types (slices, error unions, optionals) in exported
  signatures — use pointer+length, out-params, and status codes.

## Repository layout

- `src/` — the Zig implementation (`root.zig` is the library root)
- `inspiration/` — vendored Vercel AI SDK (read-only)
- `docs/porting-guide.md` — **read before designing anything**: the concrete
  TS→Zig mapping (types, streaming architecture, memory/ownership, network
  layer, C ABI design, fidelity ledger of intentional deviations)
- `docs/roadmap.md` — phased implementation plan with acceptance criteria;
  work follows the phases in order
- `docs/research/` — deep research reports on upstream internals and Zig
  0.16 idioms, with file-level evidence; `docs/research/prototypes/` holds
  working 0.16 proofs (SSE-over-HTTP client; C ABI + Python ctypes)
- `build.zig` / `build.zig.zon` — build; `zig build test` runs the tests

## Working rules

- Match Vercel AI SDK naming where it doesn't fight Zig conventions
  (e.g. `generateText` → `generateText`; module layout mirrors
  `packages/ai/src/`).
- Every ported unit ships with tests ported from (or equivalent to) the
  upstream tests.
- Any intentional behavioral deviation from upstream is recorded in the
  fidelity ledger (`docs/porting-guide.md` §18) in the same change.
- `zig build test` must pass before any commit.
- No third-party Zig dependencies without prior discussion — the stdlib's
  HTTP client, TLS, and JSON are the default answer. Pre-approved
  exception: vendoring **miniaudio** (single-file C) for the *optional*
  native audio capture/playback module, if/when realtime demos need it.
- Live-API smoke tests are opt-in (`-Dlive`) and read real keys from
  `~/src/rctr/.env` (`export`-format: `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, …). Source it when running live tests; never commit,
  copy into the repo, or print its values.
