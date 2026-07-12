# Development

Development follows the dependency spine `provider → provider_utils →
providers → ai`, with streaming, concurrency, diagnostics, and FFI treated as
core behavior rather than optional follow-up work.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | the implementation (one directory per module) |
| `include/ai.h` | the hand-written C ABI header (ABI-locked by test) |
| `bindings/python/` | the `ai_zig` ctypes package + pytest suite |
| `bindings/rust/` | the `ai-sys` declarations + safe `ai` wrapper workspace |
| `inspiration/` | vendored Vercel AI SDK monorepo — **read-only** reference |
| `docs/porting-guide.md` | TS→Zig mapping + the fidelity ledger |
| `docs/contracts.md` | behavioral contracts, lifetimes, known sharp edges |
| `docs/roadmap.md` | phased plan, acceptance criteria, completion status |
| `docs/research/` | deep research reports + working Zig 0.16 prototypes |

## Build and tests

```sh
zig build test --summary all
zig build --summary all
```

The first command aggregates every module test plus C header/snapshot checks
and the Linux public-symbol check. The second builds modules and installs the
static/shared ABI artifacts.

Target one module with:

```sh
zig build test-provider
zig build test-provider-utils
zig build test-ai
zig build test-otel
zig build test-openai-compatible
zig build test-openrouter
zig build test-xai
zig build test-anthropic
zig build test-openai
zig build test-google
zig build test-mcp
zig build test-ffi
zig build test-integration
```

`test-support` also exists for the shared harness. Filter test names with
`zig build test -Dtest-filter=sse`. Build only the ABI with `zig build ffi`,
or the differential executable with `zig build conformance-runner`.

## Live tests

Live tests are opt-in:

```sh
zig build test-integration -Dlive --summary all
```

Supply credentials as environment variables without committing, copying, or
printing their values. Current live gates recognize:

- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `XAI_API_KEY`
- `GOOGLE_API_KEY`
- `OPENROUTER_API_KEY`

The test harness may source those names from a repository-external env file,
but its location is deliberately not part of the public workflow contract.
Image and video live calls remain cost-gated.

## Bindings and conformance

```sh
zig build
python -m pip install -e 'bindings/python[test]'
python -m pytest bindings/python/tests -q -k 'not live'

(cd bindings/rust && cargo test --workspace --locked)

npm ci --prefix conformance
zig build conformance-runner
npm run --prefix conformance conformance
```

The binding tests use local canned servers and require the freshly built C
library. Conformance creates ignored artifacts consumed by the book build.

## Documentation

mdBook 0.5.2 is the pinned local and CI version:

```sh
bash scripts/build-book.sh
```

The script copies canonical contracts, porting guide, roadmap, and the current
conformance report into ignored appendix sources before building
`docs/book/book`. Do not hand-edit generated appendix files.

Zig fences use `docs/book/theme/highlight.js`, a stock mdBook bundle extended
with this repository's original grammar. Its keywords and builtins derive from
the tokenizer and `BuiltinFn` tables selected by `zig env`; the Node check runs
every book snippet and rejects drift from the pinned compiler.

## Local GitHub Actions checks

`act` can parse and run suitable CI jobs:

```sh
act push --list
act push -j fmt
act push -j python
act push -j rust
act push -j test --matrix os:ubuntu-latest
```

GitHub Pages deployment uses GitHub's OIDC and Pages service, so local `act`
cannot exercise `actions/deploy-pages`; `act push --list` still verifies that
both workflow files parse and exposes their jobs.

## CI shape

The main CI test matrix covers Linux x86_64/arm64, macOS arm64/x86_64, and
Windows x86_64/arm64. Windows FFI artifacts target MinGW. The native Zig
0.16.0 ARM64 Windows compiler is affected by an LLVM miscompile, so that lane
downloads the checksum-pinned x86_64 compiler, runs it under Windows ARM
emulation, and cross-compiles the ARM64 GNU target.

Separate jobs run formatting, Python bindings, Rust fmt/clippy/tests, and
differential conformance. The docs workflow reruns conformance, builds this
book, uploads the Pages artifact, and deploys only from `master` or manual
dispatch.

## Fidelity discipline

Read the upstream implementation and tests before porting. Preserve canonical
v7 names where they do not fight Zig conventions. Any intentional behavior
change lands with its rationale in the
[fidelity ledger](appendix/porting-guide.md#18-fidelity-ledger-intentional-deviations) and an
equivalent test. Unsupported surfaces belong in the status table rather than
behind stubs or inflated compatibility language.

The appendix contains the normative [contracts](appendix/contracts.md),
[porting guide](appendix/porting-guide.md), and [roadmap](appendix/roadmap.md).
