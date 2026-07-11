# ai.zig ctypes proof

This package is the Phase 6 proof that the stable C ABI drives the real SDK,
including callback tools and pull-based streaming. It has no runtime dependency
beyond Python's standard library; tests use `pytest`.

Build the static/shared libraries and run the suite from the repository root:

```sh
zig build ffi
python3 -m pytest bindings/python
```

The loader searches `zig-out/lib` for the platform library. Set
`AI_ZIG_LIB=/absolute/path/to/libai.so` (or the platform equivalent) to load a
different build.

API keys are never read by the C library. The live test passes an explicit
`ANTHROPIC_API_KEY`; `bindings/python/tests/conftest.py` loads it from the
process environment or `~/src/rctr/.env` when available.

```python
from ai_zig import Runtime, Tool, generate_text, openai_compatible

with Runtime() as runtime:
    with openai_compatible(
        runtime,
        name="local",
        base_url="http://127.0.0.1:8000/v1",
        api_key="explicit-key",
    ) as provider:
        with provider.language_model("model-id") as model:
            weather = Tool("weather", lambda args: {"temperature": 21})
            result = generate_text(
                model,
                prompt="Weather in Paris?",
                tools=[weather],
                max_steps=2,
            )
            print(result["text"])
```

`Stream` is both an iterator and context manager. Its `cancel()` method calls
the thread-safe C cancellation entry point; always close or use a `with` block.
