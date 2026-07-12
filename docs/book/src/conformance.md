# Conformance & Parity

The differential harness compares observable behavior against pinned upstream
packages. It complements Zig unit/integration tests; it does not replace the
provider live-smoke layer or the fidelity ledger.

## How a scenario runs

Each JSON scenario defines a surface, provider, model id, normalized input,
and deterministic fake-server responses. The harness then performs the same
sequence twice:

```text
scenario -> shared fake provider -> pinned TypeScript SDK -> captured run
        \-> shared fake provider -> ai.zig runner          -> captured run

captured runs -> normalization -> structural diff -> report
```

The fake server records method, path, headers, and raw request body. The
TypeScript runner uses pinned `ai` and provider packages; the Zig executable
uses the public provider/core modules. Both map results into one common
envelope containing requests, stream parts, tool messages, finish reasons,
usage, steps, objects/embeddings, and error categories.

Normalization canonicalizes JSON object order, curates semantically relevant
headers, reduces retries to count/order where requested, and treats the
runtime-specific user-agent suffix as a boolean presence check—the deliberate
fidelity-ledger deviation. It does not erase arbitrary response or stream
differences.

## Status meanings

- **PASS**: the normalized upstream and Zig runs are structurally exact.
- **LEDGERED**: differences exist, every diff path is matched by the
  scenario's expected deviation, and every deviation reason references the
  fidelity ledger.
- **FAIL**: an uncovered difference or harness failure exists; the command
  exits nonzero.
- **SKIPPED**: one runner explicitly reports that the scenario cannot apply.

`LEDGERED` is not a softer spelling of pass. It exposes an intentional Zig
adaptation and ties it to the normative rationale. A scenario cannot mark a
difference ledgered with an unreferenced free-form explanation.

## Current harness

The initial suite contains 14 offline scenarios for OpenAI and Anthropic text
generation/streaming, multi-step tools, structured object generation and
streaming, OpenAI embeddings, retry decisions, and provider error mapping.
The Node package pins exact upstream versions in `conformance/package.json`;
the generated report prints the relevant pins.

Run it locally with:

```sh
npm ci --prefix conformance
zig build conformance-runner
npm run --prefix conformance conformance
```

Artifacts are written to `conformance/.artifacts/report.md` and `report.json`.
The docs build copies the Markdown artifact into this book. In documentation
CI, conformance runs immediately before mdBook so the deployed table describes
that exact commit:

**[Open the generated conformance report](appendix/conformance-report.md).**

When no local artifact exists, `scripts/build-book.sh` generates a short stub
instead of embedding stale data.

## Live provider-drift layer

Differential scenarios use deterministic fixtures and prove compatibility
against pinned SDK behavior. Opt-in `-Dlive` tests separately detect provider
drift with real, dated model ids. The public status table reports which
endpoints passed the latest live gate and distinguishes those checks from
canned coverage.

A provider can change independently of the pinned upstream SDK, and a pinned
upstream release can differ intentionally from Zig. Keeping fixture
conformance, ledgered deviations, and dated live evidence separate makes each
claim inspectable.

