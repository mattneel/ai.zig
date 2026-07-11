#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import threading

from ai_zig import AiError, Runtime, Tool, anthropic, openai, stream_text


DEFAULT_ANTHROPIC_MODEL = "claude-haiku-4-5-20251001"
DEFAULT_OPENAI_MODEL = "gpt-4o-mini"
_output_lock = threading.Lock()


def weather(arguments: dict) -> dict:
    city = str(arguments.get("city", "unknown"))
    result = {"city": city, "condition": "sunny", "temperature_c": 21}
    with _output_lock:
        print(f"tool> weather({city!r}) -> {result}", flush=True)
    return result


WEATHER = Tool(
    "weather",
    weather,
    description="Return the demo weather reading for a city.",
    input_schema={
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"],
        "additionalProperties": False,
    },
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stream one tool-enabled response through ai.zig."
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        default="Use the weather tool for Paris, then answer in one short sentence.",
    )
    parser.add_argument("--model", help="Override the provider's default model id.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    openai_key = os.environ.get("OPENAI_API_KEY")
    if not anthropic_key and not openai_key:
        print(
            "No provider key found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY "
            "to run the streaming demo."
        )
        return 0

    try:
        with Runtime() as runtime:
            if anthropic_key:
                provider = anthropic(runtime, api_key=anthropic_key)
                model_id = args.model or DEFAULT_ANTHROPIC_MODEL
                provider_name = "Anthropic"
            else:
                provider = openai(
                    runtime,
                    api_key=openai_key,
                    language_api="chat",
                )
                model_id = args.model or DEFAULT_OPENAI_MODEL
                provider_name = "OpenAI"

            with provider:
                with provider.language_model(model_id) as model:
                    print(f"provider> {provider_name} ({model_id})")
                    wrote_text = False
                    with stream_text(
                        model,
                        prompt=args.prompt,
                        instructions="Always call the weather tool before answering.",
                        tools=[WEATHER],
                        max_steps=3,
                        max_retries=1,
                        max_output_tokens=256,
                    ) as stream:
                        for part in stream:
                            if part.get("type") == "text-delta":
                                with _output_lock:
                                    if not wrote_text:
                                        print("assistant> ", end="", flush=True)
                                    print(part["text"], end="", flush=True)
                                wrote_text = True
                    if not wrote_text:
                        print("assistant> (the model returned no text)")
                    else:
                        print()
    except (AiError, OSError) as error:
        print(f"ai.zig request failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
