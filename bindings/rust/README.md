# ai.zig Rust bindings

This Cargo workspace wraps the frozen ai.zig C ABI v1:

- `ai-sys` is a checked-in, hand-written declaration crate matching
  `include/ai.h`. Keeping generated tooling out of consumer builds avoids a
  Clang/bindgen dependency and makes ABI review a direct header-to-Rust diff.
  C enums use integer aliases plus frozen constants so a newer append-only
  value cannot create an invalid Rust discriminant.
- `ai` is the safe wrapper: owning runtime/provider/model/result/stream/agent
  handles, iterator streams, Rust closure tools and telemetry, object and
  embedding calls, and copied image/speech blobs.

Neither crate is published yet.

## Build and test

From the repository root:

```sh
zig build
cd bindings/rust
cargo test --workspace --locked
cargo clippy --workspace -- -D warnings
cargo fmt --check
```

`ai-sys/build.rs` searches `../../../zig-out/lib` relative to the crate. Set
`AI_ZIG_LIB_DIR=/absolute/path/to/lib` to override it. Static linking is the
default so tests and downstream binaries do not need a runtime loader path.
Set `AI_ZIG_LINK_STATIC=0` to link `libai.so.1` (or the platform equivalent)
dynamically; then configure `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, or the
platform's install-name mechanism when the shared library is outside a system
search path.

## Safe surface

Canonical JSON remains `&str`/`String`: beyond its `ai-sys` sibling, the
wrapper has zero runtime dependencies and does not force a particular JSON
ecosystem on applications.
Callers pass options and schemas as JSON strings and may parse result/part JSON
with `serde_json`, `simd-json`, or their existing parser. Media blobs are copied
into Rust-owned `Vec<u8>` values.

```rust
use ai::{OpenAiCompatibleConfig, PartType, Runtime};

# fn run() -> ai::AiResult<()> {
let runtime = Runtime::new()?;
let mut settings = OpenAiCompatibleConfig::new(
    "local",
    "http://127.0.0.1:8000/v1",
);
settings.api_key = Some("explicit-key");
let provider = runtime.openai_compatible(settings)?;
let model = provider.language_model("model-id")?;

let stream = model.stream_text(r#"{"prompt":"hello"}"#, &[])?;
for part in stream {
    let part = part?;
    if part.kind == PartType::TextDelta {
        print!("{}", part.text);
    }
}
# Ok(())
# }
```

`Runtime::new` checks `ai_abi_version()` before constructing any handle and
rejects a different ABI major. Every extensible C struct constructed by either
crate sets `struct_size` to `size_of::<T>()`.

## Ownership and shutdown

Private `Arc` ownership nodes mirror the C retain graph. Each node's `Drop`
calls its C destroy function before releasing the retained parent:

```text
Stream -> Agent -> Model -> Provider -> Runtime
       \-> Model ---------------------> Runtime
Result -------------------------------> Runtime
```

Dropping a public parent early is therefore safe, but a dropped public value
cannot be reused. A stream owns cloned tool closures for its full lifetime; an
agent owns its tool closures until the agent and all derived streams are gone.
`Stream` implements one-consumer `Iterator`. Its drop path cancels before
destroying, while `StreamCancel` is a weak, thread-safe capability that can
race and unblock a blocked pull without extending the C handle's lifetime.

Recommended orderly shutdown is: finish or cancel streams, drop agents and
models, drop providers, unregister telemetry, call `clear_telemetry()` after
all telemetry-producing work quiesces, then drop the runtime. The ownership
graph makes other parent/child drop orders memory-safe, but it cannot make a
destroy race with an outstanding foreign call valid.

## Callback containment

Tool closures are `Fn(&str) -> Result<String, String> + Send + Sync + 'static`
because the runtime may invoke them concurrently. Successful JSON is allocated
with `ai_alloc`; ai.zig consumes and frees it. Returned errors become
`AI_TOOL_ERROR`, and `catch_unwind` converts unwinding Rust panics to the same
status. `Tool::last_failure` records the last returned error or panic payload.
No unwind crosses the C boundary. Rust's panic hook still runs before a panic
is caught, and a binary built with `panic = "abort"` terminates by definition.

Telemetry event/enter/exit closures use the same `catch_unwind` containment;
failures are available from `TelemetryRegistration::callback_failures` and do
not fail model operations. Unregister is only a logical disable. A private
process registry retains callback code, user state, enter tokens, vtables, and
the runtime until `clear_telemetry()`. Clear is process-global and must run only
after copied dispatchers and in-flight callbacks have quiesced, exactly as the
C contract requires.
