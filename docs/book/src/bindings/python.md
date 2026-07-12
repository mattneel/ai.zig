# Python Bindings

`ai_zig` is a Python 3.12+ standard-library-only `ctypes` wrapper over C ABI
v1. It validates the ABI major at import, uses context managers for owning
handles, parses canonical JSON into Python values, exposes streams as
iterators, and copies media blobs into Python `bytes`.

The package is not published. Install it from a checkout:

```sh
zig build
python -m pip install -e 'bindings/python[test]'
```

The loader searches the checkout's `zig-out/lib`. Set `AI_ZIG_LIB` to an
absolute shared-library path when loading from elsewhere.

## Surface tour

- `generate_text`, `stream_text`, and `stream_text_ui`;
- `generate_object`, `stream_object`, and parsed partials;
- `embed` and `embed_many`;
- reusable `Agent.run` and `Agent.stream`;
- telemetry registration and global clear;
- image, speech, and transcription with copied blobs;
- Anthropic, OpenRouter, generic OpenAI-compatible, native OpenAI, and native
  xAI providers.

Google construction, video, realtime, MCP, and streaming transcription are
not C ABI v1 surfaces and therefore are not in this wrapper.

## Blocking OpenAI-compatible example

```python
from ai_zig import Runtime, Tool, generate_text, openai_compatible

with Runtime() as runtime:
    with openai_compatible(runtime, name="local",
                           base_url="http://127.0.0.1:8000/v1",
                           api_key="explicit-key") as provider:
        with provider.language_model("model-id") as model:
            weather = Tool("weather", lambda args: {"temperature": 21})
            result = generate_text(model, prompt="Weather in Paris?",
                                   tools=[weather], max_steps=2)
            print(result["text"])
```

The tool lambda runs *inside* the Zig loop via a C callback; `stream_text`
returns an iterator whose `cancel()` unblocks a waiting pull from any thread.
The callback, cancellation, and lifetime rules are normative in
[Behavioral Contracts](../appendix/contracts.md).

## Streaming tool example

This runnable pattern mirrors `examples/python/chat.py` while keeping the
provider choice explicit:

```python
from ai_zig import Runtime, Tool, anthropic, stream_text

weather = Tool(
    "weather",
    lambda args: {
        "city": args["city"],
        "condition": "sunny",
        "temperature_c": 21,
    },
    description="Return demo weather for a city.",
    input_schema={
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"],
        "additionalProperties": False,
    },
)

with Runtime() as runtime:
    with anthropic(runtime, api_key="explicit-key") as provider:
        with provider.language_model("claude-haiku-4-5-20251001") as model:
            with stream_text(
                model,
                prompt="Use weather for Paris, then answer briefly.",
                instructions="Always call weather before answering.",
                tools=[weather],
                max_steps=3,
                max_retries=1,
            ) as stream:
                for part in stream:
                    if part["type"] == "text-delta":
                        print(part["text"], end="", flush=True)
```

API keys are explicit constructor arguments. The example CLI may read an
environment variable in Python, but neither the package nor C library
implicitly reads provider credentials.

## GIL and exceptions

The library is loaded with `ctypes.CDLL`, so ctypes releases the GIL during
ordinary blocking C calls. Tool and telemetry callbacks may arrive
concurrently on runtime-pool threads. `CFUNCTYPE` acquires the GIL and creates
a temporary Python thread state, but shared mutable state still needs locks;
`threading.local()` state is not guaranteed to persist between foreign-thread
callbacks.

No Python exception crosses C. `Tool` catches `BaseException`, stores it in
`last_exception`, and returns `AI_TOOL_ERROR`, which becomes model-visible
tool-error data. Telemetry exceptions are collected on the registration and do
not fail model operations. This containment includes `KeyboardInterrupt` and
`SystemExit` raised inside callbacks.

## Shutdown

Use `with` or explicit `close()`. Finish/cancel streams, close agents/models,
close providers, logically unregister telemetry, call `clear_telemetry()`
after telemetry-producing operations quiesce, then close the runtime.

`Stream.close()` cancels, waits for the sole in-progress pull to return, and
destroys the C stream. `cancel()` is the lighter thread-safe unblock operation.
Best-effort `__del__` methods suppress shutdown errors but do not provide
deterministic joins or global telemetry cleanup.

## Mock and live tests

```sh
python -m pytest bindings/python/tests -q -k 'not live'
ANTHROPIC_API_KEY='...' \
  python -m pytest bindings/python/tests/test_live.py -q
```

Offline tests run an in-process canned HTTP/SSE server and exercise callback,
stream, media, object, embedding, telemetry, and ownership behavior without
provider cost. The live test uses the dated Anthropic Haiku model and skips
when the key is absent.
