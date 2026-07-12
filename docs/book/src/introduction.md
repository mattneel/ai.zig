# Introduction

ai.zig is an independent, parity-focused Zig 0.16 implementation of the
[Vercel AI SDK](https://github.com/vercel/ai) v7 core, built on Zig's
`std.Io` execution model. It provides provider interfaces, orchestration,
streaming, tool loops, structured output, embeddings, agents, UI-message
streams, realtime sessions, media operations, and an MCP client. The same
core is exposed through a stable C ABI v1 and language-idiomatic Python and
Rust wrappers.

The project is broad, but its claims are deliberately bounded. The current
[feature and status table](https://github.com/mattneel/ai.zig#status) is the
place to check whether a surface is implemented, what has been live-tested,
and whether it is exposed through the C, Python, and Rust layers. In that
table, **beta** means implemented and covered by the full test suite while
the Zig API may still change. **Preview** means narrower coverage and no
compatibility guarantee.

## What parity means here

Parity does not mean an undifferentiated line-for-line translation. ai.zig
targets the upstream v7 core at five explicit levels, matching the repository
README's contract:

1. **Provider wire parity** — for supported provider/surface combinations,
   request bodies, response mapping, stream-part sequences, and error
   taxonomies match upstream except for deviations recorded in the fidelity
   ledger. This is fixture-tested, including fixtures derived from upstream
   suites.
2. **Core behavioral parity** — tool loops, stop conditions, `prepareStep`,
   output strategies, retry policy, and abort semantics are checked through
   ported fixtures and behavioral contracts.
3. **Conceptual API parity** — the upstream v7 mental model and canonical
   names are primary. Selected deprecated compatibility APIs
   (`generateObject` and `streamObject`) remain where they materially ease
   migration and are clearly identified as compatibility surfaces.
4. **Intentional Zig adaptations** — allocators and arenas, error unions plus
   diagnostics, pull-based streams over `std.Io`, and explicit cancellation.
   Every deviation is itemized with rationale in the
   [fidelity ledger](appendix/porting-guide.md#18-fidelity-ledger-intentional-deviations).
5. **Unsupported surfaces** — the status table is authoritative. Notable
   exclusions include Vercel AI Gateway routing, replaced by opt-in
   OpenRouter, and framework-specific React/Vue bindings. The
   framework-agnostic Chat core those bindings wrap is ported.

The distinction between a provider-level contract and a core behavior is
important. A provider can match its HTTP and SSE vocabulary while an
orchestrator still differs in tool ordering or retry behavior. The
[differential conformance harness](conformance.md) therefore records both
requests and normalized results instead of reducing compatibility to a raw
test count.

## Stability and releases

The C ABI v1 policy is implemented and enforced in-tree: version queries,
frozen numeric tags, size-prefixed extensible structs, symbol visibility,
the ELF SONAME, and a frozen snapshot client are tested. The `abi-compat` CI
job checks the latest published release's header and frozen clients against the
current library. It reports a clean skip while no release exists, so
cross-release evidence begins only after v0.1.0 is published.

The Python and Rust packages cover the ABI v1 surfaces documented in their
chapters, but neither package is published yet. Their language-level APIs
remain preview while packaging and downstream feedback settle. The Zig API
is beta and may change.

## License and provenance

ai.zig is licensed under Apache-2.0. Its design derives from the Vercel AI SDK
provider wire protocols, behavioral contracts, type shapes, and test fixtures.
The upstream repository is vendored read-only under `inspiration/` with its
license intact. See the repository
[`NOTICE`](https://github.com/mattneel/ai.zig/blob/master/NOTICE) for the full
provenance statement.

ai.zig is not affiliated with or endorsed by Vercel. Start with
[Getting Started](getting-started.md), then use [Core Concepts](core-concepts.md)
to understand the lifetime and execution rules shared by every chapter.
