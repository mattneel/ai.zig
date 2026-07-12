# Rust streaming-tool example

This is a downstream-style binary crate: it depends only on the public safe
`ai` crate and does not import `ai-sys`. It opens an Anthropic streaming chat,
lets the model call one Rust `weather` closure, and prints text deltas as they
arrive.

```sh
zig build
cd examples/rust
export ANTHROPIC_API_KEY=... # explicit; ai.zig never reads it implicitly
cargo run -- "Use the weather tool for Paris, then answer in one short sentence."
```

Set `AI_MODEL` to override the dated default
`claude-haiku-4-5-20251001`. With no key, the program reports that no request
was sent and exits successfully.

## Captured transcripts

Live run on 2026-07-11 (the key was sourced from the repository-external
credential file and was neither printed nor copied):

```text
model: claude-haiku-4-5-20251001
user: Use the weather tool for Paris, then answer in one short sentence.
assistant:
[tool] weather input: {"city":"Paris"}
Paris is currently 21°C and sunny.
```

No-key run on 2026-07-11:

```text
ANTHROPIC_API_KEY is not set; no provider request was sent.
Set it and rerun this command to start the streaming chat.
```
