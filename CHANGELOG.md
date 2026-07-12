# Changelog

This changelog records curated user-facing changes. The project uses the
stability vocabulary and parity boundaries documented in the README.

## [0.1.0] - 2026-07-12

ai.zig 0.1.0 is the initial public beta package release of the independent,
parity-focused Vercel AI SDK v7 core implementation for Zig 0.16.

### Highlights

- Added the `std.Io`-based Zig core for text generation and streaming,
  multi-step tool loops and approvals, reusable agents, structured output,
  embeddings and reranking, UI message streams and Chat state, MCP transports,
  realtime sessions over WebSocket, and image, speech, transcription, video,
  file, and skill media operations.
- Added native Anthropic, OpenAI, and Google providers; OpenAI-compatible
  configuration with Groq, DeepSeek, Mistral, Together AI, and Fireworks
  presets; and OpenRouter and xAI providers. Coverage remains bounded by the
  README status table and fidelity ledger.
- Added the stable C ABI v1 boundary with version queries, frozen numeric tags,
  size-prefixed extensible structures, opaque handles, explicit ownership and
  teardown rules, callback and pull-stream surfaces, ELF symbol visibility,
  and SONAME policy. Package version 0.1.0 and C ABI version 1.0.0 are separate:
  compatible package releases retain `AI_ABI_VERSION` 1.0.0 and ELF SONAME
  `libai.so.1`.
- Added Python `ctypes` and Rust `ai-sys` plus safe-wrapper packages covering
  the documented ABI v1 surfaces. Both wrapper APIs are preview and their
  packages remain unpublished to PyPI and crates.io in this release.
- Added a thread-safe OpenTelemetry exporter with correlated generate, step,
  model, and tool spans plus configurable OTLP/HTTP JSON batching.
- Added a differential conformance harness whose 14 deterministic offline
  scenarios pass 14/14 against the pinned upstream `ai@7.0.22` behavior for
  the covered text, streaming, tool, object, embedding, retry, and error cases.
- Added six-platform CI across x86_64 and arm64 Linux, macOS, and Windows,
  wrapper-specific checks, formatting, and differential conformance reporting.
- Added the mdBook documentation site with contracts, provider and feature
  guides, binding lifecycle documentation, the fidelity ledger, and the
  generated conformance report.
