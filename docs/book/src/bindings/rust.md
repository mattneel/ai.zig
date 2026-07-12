# Rust Bindings

The Rust workspace contains two unpublished crates over C ABI v1:

- `ai-sys`: checked-in declarations matching `include/ai.h`, with integer
  aliases and frozen constants for C enums;
- `ai`: a safe, zero-third-party-runtime-dependency wrapper with owning
  handles, iterator streams, callback containment, canonical JSON strings,
  and copied media blobs.

Keeping `ai-sys` hand-written avoids a consumer-time Clang/bindgen dependency
and makes ABI review a direct header-to-Rust diff.

## Build and linking

```sh
zig build
cd bindings/rust
cargo test --workspace --locked
cargo clippy --workspace -- -D warnings
cargo fmt --check
```

`ai-sys/build.rs` searches the repository `zig-out/lib` by default.
`AI_ZIG_LIB_DIR=/absolute/path/to/lib` overrides it. Static linking is the
default; set `AI_ZIG_LINK_STATIC=0` for the shared library. On Linux/macOS the
build script adds an rpath for the configured directory in dynamic mode.

## Streaming tool example

This follows the downstream-only `examples/rust` binary:

```rust
use ai::{AnthropicConfig, PartType, Runtime, Tool};

fn run(api_key: &str) -> ai::AiResult<()> {
    let runtime = Runtime::new()?;
    let provider = runtime.anthropic(AnthropicConfig::new(api_key))?;
    let model = provider.language_model("claude-haiku-4-5-20251001")?;
    let weather = Tool::new(
        "weather",
        "Return weather for a city",
        r#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}"#,
        |_input| Ok(
            r#"{"city":"Paris","temperature_c":21,"condition":"sunny"}"#
                .to_owned(),
        ),
    );

    let options = r#"{"prompt":"Use weather for Paris.","maxSteps":2}"#;
    for part in model.stream_text(options, &[weather])? {
        let part = part?;
        if part.kind == PartType::TextDelta {
            print!("{}", part.text);
        }
    }
    Ok(())
}
```

Canonical options, schemas, result documents, and part JSON remain `&str` or
`String`; applications can use their existing JSON crate. The wrapper itself
does not force `serde_json`. Image and speech blobs are copied to `Vec<u8>`.

## Drop order and cancellation

Private `Arc` nodes mirror the C retain graph:

```text
Stream -> Agent -> Model -> Provider -> Runtime
       \-> Model ---------------------> Runtime
Result -------------------------------> Runtime
```

Each node's `Drop` destroys the C handle before releasing its retained parent.
Dropping a public parent early is safe after child construction, but the
dropped value cannot be reused. `Stream` is a one-consumer `Iterator`; its
drop path cancels before destroy. `StreamCancel` is a weak, thread-safe
capability that can unblock a pull without extending the C handle lifetime.

## Callback containment

Tools require `Fn(&str) -> Result<String, String> + Send + Sync + 'static`
because runtime threads may call them concurrently. Success JSON is allocated
with `ai_alloc`; the core consumes it. Returned errors and `catch_unwind`
panic payloads become `AI_TOOL_ERROR`, and `Tool::last_failure` records the
last failure. A `panic = "abort"` binary still terminates by definition.

Telemetry closures use the same containment. A private process registry keeps
callback code, state, enter tokens, vtables, and the runtime alive until
`clear_telemetry()`. Call global clear only after copied dispatchers and
callbacks quiesce.

The safe wrapper covers the ABI providers/surfaces documented in the
[C ABI chapter](../c-abi.md); native Google, video, realtime, MCP, and
streaming transcription are not exposed. Offline tests use a dependency-free
TCP canned server; the consumer example is separately live-tested with an
explicit Anthropic key and has a no-key, no-request path.

