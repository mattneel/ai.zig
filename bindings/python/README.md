# ai.zig Python bindings

`ai_zig` is the standard-library-only Python wrapper for the stable ai.zig C
ABI v1. It validates the ABI major at import time and exposes owning handles as
context managers, pull streams as iterators, canonical JSON as Python values,
and media blobs as owned `bytes`.

The package is not yet published. From a repository checkout:

```sh
zig build
python -m pip install -e 'bindings/python[test]'
python -m pytest bindings/python/tests -q -k 'not live'
```

The loader searches the checkout's `zig-out/lib` directory. Set
`AI_ZIG_LIB=/absolute/path/to/libai.so` (or the platform equivalent) when the
shared library lives elsewhere.

## Surface

- `generate_text` / `stream_text`: result dictionaries and parsed part
  iterators, including Python `Tool` callbacks.
- `generate_object` / `stream_object`: mapping or JSON-string schemas, parsed
  result dictionaries, and `ObjectStream.partials()` for parsed partial values.
  The ABI checks schema syntax and object shape; applications that require full
  semantic JSON-Schema validation should run their chosen Python validator.
- `embed` / `embed_many`: parsed embedding result dictionaries.
- `Agent`: context-managed reusable agent with `run()` and `stream()`.
- `stream_text_ui`: iterator of parsed UI-message chunk dictionaries.
- `register_telemetry` / `clear_telemetry`: mapping, callable, or object-based
  telemetry callbacks with a context-managed registration.
- `generate_image` / `generate_speech` / `transcribe`: parsed metadata plus
  copied `Blob.data` bytes for image and speech results.
- Providers: `anthropic`, `openrouter`, `openai_compatible`, native `openai`,
  and native `xai`; providers create language, embedding, image, speech, and
  transcription model handles where supported.

```python
from ai_zig import Agent, Runtime, Tool, openai

weather = Tool(
    "weather",
    lambda args: {"city": args["city"], "temperature": 21},
    input_schema={
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"],
    },
)

with Runtime() as runtime:
    with openai(runtime, api_key="explicit-key") as provider:
        with provider.language_model("gpt-4o-mini") as model:
            with Agent(model, tools=[weather], max_steps=3) as agent:
                print(agent.run(prompt="Use weather for Paris.")["text"])
```

API keys are always explicit constructor arguments. The package and C library
do not read them from the environment. The repository's
[`examples/python`](../../examples/python/) CLI shows a public-surface-only,
tool-enabled real-provider stream.

## GIL, callback exceptions, and shutdown

### GIL and callback threads

The library is loaded with `ctypes.CDLL`, so ctypes releases the GIL while a
thread is inside an ordinary blocking C call. Tool execution and telemetry
`on_event`, `enter`, and `exit` callbacks may arrive concurrently on ai.zig
runtime-pool threads rather than the thread that initiated the request.

The callbacks use `ctypes.CFUNCTYPE`. Before calling Python, ctypes acquires the
GIL and creates a temporary Python thread state when the calling native thread
was not created by Python. Python code is therefore safe to execute, but there
is no callback ordering guarantee, shared mutable state still needs normal
thread synchronization, and `threading.local()` values do not persist across
separate callbacks from a foreign-created thread. The GIL serializes Python
bytecode; it does not make a multi-callback protocol atomic. Long-running tool
callbacks also remain cooperative: cancellation cannot preempt arbitrary
Python code already executing.

### Exception containment

No Python exception is allowed to unwind through a C callback boundary.

- `Tool` catches `BaseException`, stores it in `tool.last_exception`, and
  returns `AI_TOOL_ERROR`. The core exposes that failure as a tool-error output
  and applies its normal tool-loop behavior.
- Telemetry callbacks catch `BaseException`, append it to
  `registration.callback_exceptions`, expose the newest as
  `registration.last_exception`, and return normally. Telemetry failures do
  not fail the model operation.
- Status failures from ordinary ABI calls become `AiError`. A machinery error
  returned from `ai_stream_next` raises `AiError`; model/tool error *parts* that
  are valid stream data remain parsed dictionaries.

This includes `KeyboardInterrupt` and `SystemExit` raised inside a callback:
they are contained and recorded, so callback authors should surface any
application-level stop signal explicitly after the call returns.

### Shutdown and deinitialization

Use `with` blocks or explicit `close()` calls. Recommended shutdown order is:

1. let blocking model/agent calls return, and finish or close streams,
2. close agents and model handles,
3. close providers,
4. close telemetry registrations (logical unregister),
5. after every telemetry-producing operation has quiesced, call
   `clear_telemetry()`,
6. close the runtime.

`Stream.close()` first cancels the producer, waits for any sole in-progress
`next()` call to return, and only then destroys the C stream. `Stream.cancel()`
is the lighter thread-safe operation that unblocks a pull but leaves ownership
with the stream. Do not start more than one concurrent consumer.

Agent streams retain the C agent, and the Python stream retains the `Agent`, so
tool callback objects live through the last stream pull. C child handles retain
their parents, but a closed Python owner is not reusable and destruction must
still not race another call using the same caller-owned reference. One-shot
result documents and media bytes are copied into Python before their C result
handles and blob buffers are freed.

Telemetry unregister is only a logical disable. An already-entered callback
may finish afterward, so the wrapper retains its CFUNCTYPE functions, user
object, and enter tokens until `clear_telemetry()`. Clear is process-global: do
not race it with registration/unregistration, and call it only after operations
holding copied telemetry dispatchers have stopped. It invalidates every
registration and releases their retained runtimes.

Handle `__del__` methods attempt best-effort `close()` and suppress shutdown
errors, but Python does not guarantee destructor timing (especially for cycles
or interpreter teardown). `__del__` does not establish stream-thread joins at
a predictable point and does not call process-global `clear_telemetry()`.
Deterministic context-manager shutdown is the contract.
