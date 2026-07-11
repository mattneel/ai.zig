from __future__ import annotations

import time

import pytest

from ai_zig import AiError, Runtime, Tool, generate_text, openai_compatible, stream_text
from ai_zig._lib import Status


def _provider(runtime: Runtime, server):
    return openai_compatible(
        runtime,
        name="pytest",
        base_url=server.base_url,
        api_key="test-key",
    )


def test_generate_text_two_step_python_tool_callback(canned_server):
    canned_server.enqueue_json(
        {
            "id": "chat-1",
            "created": 1700000000,
            "model": "vendor/model",
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [
                            {
                                "id": "call-weather",
                                "type": "function",
                                "function": {
                                    "name": "weather",
                                    "arguments": '{"city":"Paris"}',
                                },
                            }
                        ],
                    },
                    "finish_reason": "tool_calls",
                }
            ],
            "usage": {"prompt_tokens": 4, "completion_tokens": 2},
        }
    )
    canned_server.enqueue_json(
        {
            "id": "chat-2",
            "created": 1700000001,
            "model": "vendor/model",
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": "Paris is sunny and 21 C.",
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 8, "completion_tokens": 5},
        }
    )
    calls = []
    weather = Tool(
        "weather",
        lambda value: calls.append(value) or {"condition": "sunny", "temperature": 21},
        description="Get weather",
        input_schema={"type": "object", "properties": {"city": {"type": "string"}}},
    )

    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with provider.language_model("vendor/model") as model:
            result = generate_text(
                model,
                prompt="What is the weather in Paris?",
                tools=[weather],
                max_steps=2,
                max_retries=0,
            )

    assert result["text"] == "Paris is sunny and 21 C."
    assert result["finishReason"]["unified"] == "stop"
    assert len(result["steps"]) == 2
    assert calls == [{"city": "Paris"}]
    assert len(canned_server.requests) == 2
    second_messages = canned_server.requests[1]["json"]["messages"]
    assert any(message["role"] == "tool" for message in second_messages)


def test_stream_iterator_order_and_prompt_cross_thread_cancel(canned_server):
    canned_server.enqueue_sse(
        [
            '{"id":"stream-1","created":1700000000,"model":"vendor/model","choices":[{"delta":{"content":"Hel"}}]}',
            '{"id":"stream-1","choices":[{"delta":{"content":"lo"}}]}',
            '{"id":"stream-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":2}}',
            "[DONE]",
        ]
    )
    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with provider.language_model("vendor/model") as model:
            with stream_text(model, prompt="hello", max_retries=0) as stream:
                parts = list(stream)

            types = [part["type"] for part in parts]
            assert types[0] == "start"
            assert [part["text"] for part in parts if part["type"] == "text-delta"] == [
                "Hel",
                "lo",
            ]
            assert types[-1] == "finish"

            canned_server.enqueue_sse(
                [
                    (
                        '{"id":"stream-cancel","created":1700000001,"model":"vendor/model","choices":[{"delta":{"content":"A"}}]}',
                        1.0,
                    ),
                    '{"id":"stream-cancel","choices":[{"delta":{"content":"B"}}]}',
                    '{"id":"stream-cancel","choices":[{"delta":{},"finish_reason":"stop"}]}',
                    "[DONE]",
                ]
            )
            with stream_text(model, prompt="cancel", max_retries=0) as stream:
                for part in stream:
                    if part["type"] == "text-delta":
                        break
                started = time.perf_counter()
                stream.cancel()
                elapsed = time.perf_counter() - started
            assert elapsed < 0.15


def test_error_diagnostics_surface_as_ai_error(canned_server):
    canned_server.enqueue_json(
        {"error": {"message": "bad test key"}},
        status=401,
    )
    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with provider.language_model("vendor/model") as model:
            with pytest.raises(AiError) as caught:
                generate_text(model, prompt="fail", max_retries=0)

    assert caught.value.status == Status.API_CALL
    assert "bad test key" in str(caught.value)
