# Python streaming-tool example

This directory is a consumer-style example: `chat.py` imports only the public
installed `ai_zig` package and does not use repository test helpers.

From the repository root, build the shared library and install the Python
package in editable mode:

```sh
zig build
python -m pip install -e bindings/python
```

Then provide one real provider key and run the CLI:

```sh
export ANTHROPIC_API_KEY='...'
python examples/python/chat.py
```

or:

```sh
export OPENAI_API_KEY='...'
python examples/python/chat.py
```

Pass a prompt and optional provider-specific model override when useful:

```sh
python examples/python/chat.py 'Use weather for Montréal.' --model MODEL_ID
```

The example prefers Anthropic when both keys are present. Its local `weather`
tool returns a deterministic demo reading, so the transcript shows the
Python callback executing inside the Zig tool loop. If neither key exists,
the program prints setup guidance and exits successfully without attempting a
network request. When the package is installed outside this checkout, set
`AI_ZIG_LIB` to the absolute shared-library path before starting it.
