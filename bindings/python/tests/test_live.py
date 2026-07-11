from __future__ import annotations

import os

import pytest

from ai_zig import Runtime, anthropic, generate_text, stream_text


@pytest.mark.skipif(
    not os.environ.get("ANTHROPIC_API_KEY"),
    reason="ANTHROPIC_API_KEY is not available",
)
def test_live_anthropic_generate_and_stream_smoke():
    with Runtime() as runtime, anthropic(
        runtime, api_key=os.environ["ANTHROPIC_API_KEY"]
    ) as provider:
        with provider.language_model("claude-haiku-4-5-20251001") as model:
            generated = generate_text(
                model,
                prompt="Reply with exactly: ffi-live-ok",
                max_output_tokens=32,
                max_retries=1,
            )
            assert generated["text"]

            with stream_text(
                model,
                prompt="Reply with exactly: ffi-stream-ok",
                max_output_tokens=32,
                max_retries=1,
            ) as stream:
                parts = list(stream)
            assert any(part["type"] == "text-delta" for part in parts)
            assert parts[-1]["type"] == "finish"
