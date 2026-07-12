# C ABI

ai.zig's C ABI v1 is a first-class stable binary boundary over the Zig core.
The hand-written [`ai.h`](https://github.com/mattneel/ai.zig/blob/master/include/ai.h)
uses opaque handles, status returns, pointer/length inputs, size-prefixed
structs, explicit destruction, callback tools, and pull streams.

The normative text is the build-time copy of
[Behavioral Contracts](appendix/contracts.md#c-abi-v1-contract). This chapter
is a linking and lifecycle guide, not a replacement for that contract.

## Version and struct evolution

`AI_ABI_VERSION` and `ai_abi_version()` both encode 1.0.0 as an 8-bit major,
8-bit minor, and 16-bit patch. Before using the library, compare the header
major with the high byte of the runtime value. `ai_abi_version_string()`
returns static borrowed text.

Every extensible caller-supplied config, descriptor, callback vtable, and
output begins with `size_t struct_size`:

```c
ai_runtime_config config = {0};
config.struct_size = sizeof(config);

ai_runtime *runtime = NULL;
ai_status status = ai_runtime_create(&config, &runtime);
if (status != AI_OK) {
    /* ai_runtime_last_error is available only after a runtime exists. */
    return 1;
}
```

The v1 library **rejects a struct smaller than the v1 required prefix**. It
**accepts a larger struct and ignores the unknown tail**. Compatible fields
append at the end; they are never inserted or reordered within the ABI major.
`ai_string` is the frozen two-word exception returned by value.

All public status, part, and endpoint-selection numerics are frozen. New
values append; released values are never renumbered or reused. Consumers must
tolerate unknown newer values and can fall back to a stream part's JSON.

## Handles and threading

| Handle | Key rule |
| --- | --- |
| `ai_runtime` | ref-counted `std.Io.Threaded` root; children retain it |
| `ai_provider` | immutable; concurrent model creation; models retain it |
| model handles | immutable; concurrent blocking calls; streams retain language models |
| `ai_result` | immutable getters; destruction must not race a getter |
| `ai_stream` | one `next` consumer; `cancel` may race a blocked `next` |
| `ai_agent` | immutable settings; callback state must outlive runs/streams |
| telemetry registration | logical unregister; callback storage lives until global clear |

Parent-first teardown is safe after a child has been created because the child
retains its parent. A dropped caller-owned pointer cannot be reused, and
destroying a handle must not race an ordinary call through that same pointer.

Stream teardown is specific: call `ai_stream_cancel` from any thread, let the
sole blocked `ai_stream_next` return, then call `ai_stream_destroy`. A part's
text and JSON borrow stream scratch storage until the next pull or destroy.
Use `ai_part_clone` when JSON must outlive that point.

## Memory crossing the boundary

- Result-string getters borrow until `ai_result_destroy`.
- Ordinary input pointers are borrowed for the call and copied if a returned
  handle needs them.
- `ai_result_blob` and `ai_part_clone` allocate library memory; release it
  with `ai_buf_free`.
- A successful tool callback allocates `ai_tool_result.ptr` with `ai_alloc`;
  the SDK consumes and frees it after callback return.
- No exception or panic may unwind through a C callback. A Zig panic aborts
  the host; recoverable failures return `ai_status`.

Options, schemas, objects, embeddings, UI chunks, telemetry events, and media
metadata use canonical JSON at the boundary. Image and speech bytes use
indexed blobs. C schema input is syntax-checked and forwarded; semantic result
validation remains the host application's responsibility.

## Build and link

```sh
zig build ffi -Doptimize=ReleaseSafe
```

The build installs the platform static and shared libraries under
`zig-out/lib/` and the public header as `zig-out/include/ai.h`. A simple
dynamic link on ELF platforms can use:

```sh
zig cc example.c -Izig-out/include -Lzig-out/lib -lai -o example
LD_LIBRARY_PATH="$PWD/zig-out/lib" ./example
```

For a checkout-friendly static binary, name the archive explicitly so the
linker cannot prefer the shared object:

```sh
zig cc example.c -Izig-out/include zig-out/lib/libai.a -o example
```

Use the platform's normal loader/install-name mechanism in production. ELF
uses SONAME `libai.so.1`; compatible minor/patch releases retain it. Public
dynamic symbols are restricted to the `ai_` prefix by the version script.

## Frozen snapshot client

The ABI test suite does more than compile the current header against the
current library. `src/ffi/abi_v1_snapshot_client.c` intentionally does not
include `ai.h`; it carries frozen v1 declarations, checks version
`0x01000000`, creates a runtime and OpenAI provider, and links/runs against the
new library. The `abi-compat` CI job also fetches the latest published pruned
source archive and compiles that release's header and frozen clients against
the current library. It skips cleanly before the first release exists and
starts producing cross-release evidence after v0.1.0 is published.

C ABI v1 currently exposes Anthropic, OpenRouter, generic OpenAI-compatible,
native OpenAI, and xAI provider constructors. Native Google remains pending.
Video, realtime, MCP, and streaming transcription are not ABI v1 surfaces.
