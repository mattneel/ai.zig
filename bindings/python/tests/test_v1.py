from __future__ import annotations

import json
import threading

import pytest

from ai_zig import (
    Agent,
    Runtime,
    Tool,
    clear_telemetry,
    embed,
    embed_many,
    generate_image,
    generate_object,
    generate_speech,
    generate_text,
    openai,
    openai_compatible,
    register_telemetry,
    stream_object,
    stream_text_ui,
    transcribe,
    xai,
)


def _provider(runtime: Runtime, server):
    return openai_compatible(
        runtime,
        name="pytest-v1",
        base_url=server.base_url,
        api_key="test-key",
    )


def _chat_response(
    text: str,
    *,
    response_id: str,
    prompt_tokens: int = 2,
    completion_tokens: int = 2,
) -> dict:
    return {
        "id": response_id,
        "created": 1700000000,
        "model": "vendor/model",
        "choices": [
            {
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
        },
    }


def _tool_call_response(call_id: str = "call-weather") -> dict:
    return {
        "id": f"response-{call_id}",
        "created": 1700000000,
        "model": "vendor/model",
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "id": call_id,
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
        "usage": {"prompt_tokens": 3, "completion_tokens": 2},
    }


@pytest.fixture
def clean_telemetry():
    clear_telemetry()
    try:
        yield
    finally:
        clear_telemetry()


def test_generate_object_and_stream_parsed_partials(canned_server):
    schema = {
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"],
        "additionalProperties": False,
    }
    canned_server.enqueue_json(
        {
            "id": "object-1",
            "created": 1700000000,
            "model": "vendor/model",
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": '{"city":"Paris"}',
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 3, "completion_tokens": 4},
        }
    )
    canned_server.enqueue_sse(
        [
            '{"id":"object-stream","created":1700000001,"model":"vendor/model","choices":[{"delta":{"content":"{\\"city\\":"}}]}',
            '{"id":"object-stream","choices":[{"delta":{"content":"\\"Paris\\"}"}}]}',
            '{"id":"object-stream","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4}}',
            "[DONE]",
        ]
    )

    with Runtime() as runtime, openai(
        runtime,
        api_key="test-key",
        base_url=canned_server.base_url,
        language_api="chat",
    ) as provider:
        with provider.language_model("gpt-test") as model:
            generated = generate_object(
                model,
                schema,
                prompt="Return a city.",
                max_retries=0,
            )
            with stream_object(
                model,
                json.dumps(schema),
                prompt="Return a city.",
                max_retries=0,
            ) as stream:
                partials = list(stream.partials())

    assert generated["object"] == {"city": "Paris"}
    assert partials
    assert partials[-1] == {"city": "Paris"}
    assert canned_server.requests[0]["json"]["response_format"]["type"] == "json_schema"


def test_embed_and_embed_many_return_canonical_documents(canned_server):
    canned_server.enqueue_json(
        {
            "object": "list",
            "data": [
                {
                    "object": "embedding",
                    "embedding": [0.25, 0.75],
                    "index": 0,
                }
            ],
            "model": "text-embedding-test",
            "usage": {"prompt_tokens": 2, "total_tokens": 2},
        }
    )
    canned_server.enqueue_json(
        {
            "object": "list",
            "data": [
                {"object": "embedding", "embedding": [1.0, 0.0], "index": 0},
                {"object": "embedding", "embedding": [0.0, 1.0], "index": 1},
            ],
            "model": "text-embedding-test",
            "usage": {"prompt_tokens": 4, "total_tokens": 4},
        }
    )

    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with provider.embedding_model("text-embedding-test") as model:
            one = embed(model, "hello", max_retries=0)
            many = embed_many(
                model,
                ["one", "two"],
                max_retries=0,
                max_parallel_calls=2,
            )

    assert one["value"] == "hello"
    assert one["embedding"] == [0.25, 0.75]
    assert one["usage"]["tokens"] == 2
    assert many["values"] == ["one", "two"]
    assert many["embeddings"] == [[1.0, 0.0], [0.0, 1.0]]
    assert [request["path"] for request in canned_server.requests] == [
        "/embeddings",
        "/embeddings",
    ]
    assert canned_server.requests[1]["json"]["input"] == ["one", "two"]


def test_agent_run_and_stream_retain_python_tool_callback(canned_server):
    canned_server.enqueue_json(_tool_call_response("call-run"))
    canned_server.enqueue_json(_chat_response("run complete", response_id="run-2"))
    canned_server.enqueue_sse(
        [
            '{"id":"agent-stream-1","created":1700000001,"model":"vendor/model","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-stream","type":"function","function":{"name":"weather","arguments":"{\\"city\\":\\"Paris\\"}"}}]}}]}',
            '{"id":"agent-stream-1","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}',
            "[DONE]",
        ]
    )
    canned_server.enqueue_sse(
        [
            '{"id":"agent-stream-2","created":1700000002,"model":"vendor/model","choices":[{"delta":{"content":"stream complete"}}]}',
            '{"id":"agent-stream-2","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}',
            "[DONE]",
        ]
    )
    calls: list[dict] = []
    weather = Tool(
        "weather",
        lambda value: calls.append(value) or {"condition": "sunny"},
        input_schema={
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    )

    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with provider.language_model("vendor/model") as model:
            with Agent(
                model,
                tools=[weather],
                instructions="Use the weather tool.",
                max_steps=2,
            ) as agent:
                generated = agent.run(prompt="Weather?", max_retries=0)
                with agent.stream(prompt="Weather again?", max_retries=0) as stream:
                    parts = list(stream)

    assert generated["text"] == "run complete"
    assert [part["text"] for part in parts if part["type"] == "text-delta"] == [
        "stream complete"
    ]
    assert calls == [{"city": "Paris"}, {"city": "Paris"}]


def test_tool_callback_exception_is_contained_by_agent(canned_server):
    class CallbackFailure(RuntimeError):
        pass

    def explode(value):
        del value
        raise CallbackFailure("tool exploded")

    failing_tool = Tool("weather", explode, input_schema={"type": "object"})
    canned_server.enqueue_json(_tool_call_response("call-failure"))
    canned_server.enqueue_json(_chat_response("recovered", response_id="failure-2"))

    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with provider.language_model("vendor/model") as model:
            with Agent(model, tools=[failing_tool], max_steps=2) as agent:
                result = agent.run(prompt="Use weather.", max_retries=0)

    assert result["text"] == "recovered"
    assert isinstance(failing_tool.last_exception, CallbackFailure)
    assert len(canned_server.requests) == 2


def test_ui_chunks_and_telemetry_object_callbacks(canned_server, clean_telemetry):
    canned_server.enqueue_sse(
        [
            '{"id":"ui-1","created":1700000003,"model":"vendor/model","choices":[{"delta":{"content":"UI"}}]}',
            '{"id":"ui-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}',
            "[DONE]",
        ]
    )

    class Recorder:
        def __init__(self):
            self.events: list[tuple[str, dict]] = []
            self.enters: list[tuple[str, str, int]] = []
            self.exits: list[tuple[str, object]] = []

        def on_event(self, name: str, event: dict) -> None:
            self.events.append((name, event))

        def enter(self, scope: str, call_id: str) -> object:
            token = (scope, call_id, threading.get_ident())
            self.enters.append(token)
            return token

        def exit(self, scope: str, token: object) -> None:
            self.exits.append((scope, token))

    recorder = Recorder()
    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with register_telemetry(runtime, recorder) as registration:
            with provider.language_model("vendor/model") as model:
                with stream_text_ui(model, prompt="hello", max_retries=0) as stream:
                    chunks = list(stream)
        assert not registration.active
        clear_telemetry()

    assert any(chunk["type"] == "text-delta" for chunk in chunks)
    assert recorder.events
    assert all(isinstance(event, dict) for _, event in recorder.events)
    assert recorder.enters
    assert len(recorder.enters) == len(recorder.exits)
    assert {scope for scope, _ in recorder.exits} == {
        scope for scope, _, _ in recorder.enters
    }


def test_telemetry_callback_exception_is_contained(canned_server, clean_telemetry):
    class TelemetryFailure(RuntimeError):
        pass

    def raise_from_event(name: str, event: dict) -> None:
        del name, event
        raise TelemetryFailure("telemetry exploded")

    canned_server.enqueue_json(_chat_response("still works", response_id="telemetry"))
    with Runtime() as runtime, _provider(runtime, canned_server) as provider:
        with register_telemetry(
            runtime, {"on_event": raise_from_event}
        ) as registration:
            with provider.language_model("vendor/model") as model:
                result = generate_text(model, prompt="hello", max_retries=0)
        callback_exception = registration.last_exception
        clear_telemetry()

    assert result["text"] == "still works"
    assert isinstance(callback_exception, TelemetryFailure)


def test_media_wrappers_copy_blobs_and_transcription_audio(canned_server):
    canned_server.enqueue_json(
        {
            "created": 1733837122,
            "data": [{"b64_json": "aGk="}],
            "usage": {"input_tokens": 1, "output_tokens": 2, "total_tokens": 3},
        }
    )
    canned_server.enqueue_bytes(b"ID3audio", content_type="audio/mpeg")
    canned_server.enqueue_json(
        {
            "text": "hello world",
            "language": "english",
            "duration": 1.5,
            "segments": [{"start": 0, "end": 1.5, "text": "hello world"}],
        }
    )

    with Runtime() as runtime, openai(
        runtime,
        api_key="test-key",
        base_url=canned_server.base_url,
        language_api="chat",
    ) as provider:
        with provider.image_model("gpt-image-1") as image_model:
            image = generate_image(
                image_model,
                "draw",
                n=1,
                max_retries=0,
            )
        with provider.speech_model("gpt-4o-mini-tts") as speech_model:
            speech = generate_speech(
                speech_model,
                "hello",
                voice="alloy",
                max_retries=0,
            )
        with provider.transcription_model("whisper-1") as transcription_model:
            transcript = transcribe(
                transcription_model,
                b"RIFFtiny",
                max_retries=0,
            )

    assert image.images[0].data == b"hi"
    assert image.images[0].media_type == "image/png"
    assert speech.audio.data == b"ID3audio"
    assert speech.audio.media_type == "audio/mp3"
    assert transcript["text"] == "hello world"
    assert [request["path"] for request in canned_server.requests] == [
        "/images/generations",
        "/audio/speech",
        "/audio/transcriptions",
    ]
    assert canned_server.requests[2]["json"] is None
    assert canned_server.requests[2]["content_type"].startswith("multipart/form-data")


def test_native_xai_constructor_creates_language_model_without_network(canned_server):
    with Runtime() as runtime, xai(
        runtime,
        api_key="xai-key",
        base_url=canned_server.base_url,
    ) as provider:
        with provider.language_model("grok-test") as model:
            assert model.handle

    assert canned_server.requests == []
