from __future__ import annotations

import ctypes
import json
from collections.abc import Mapping, Sequence
from typing import Any

from ._lib import BytesArg, lib, read_string
from .providers import Model
from .tools import Tool, tool_array


_OPTION_NAMES = {
    "allow_system_in_messages": "allowSystemInMessages",
    "tool_choice": "toolChoice",
    "max_output_tokens": "maxOutputTokens",
    "top_p": "topP",
    "top_k": "topK",
    "presence_penalty": "presencePenalty",
    "frequency_penalty": "frequencyPenalty",
    "stop_sequences": "stopSequences",
    "provider_options": "providerOptions",
    "max_retries": "maxRetries",
    "timeout_ms": "timeoutMs",
    "max_steps": "maxSteps",
    "tools_context": "toolsContext",
    "runtime_context": "runtimeContext",
    "include_raw_chunks": "includeRawChunks",
}


def make_options(
    options: Mapping[str, Any] | None = None,
    *,
    prompt: str | None = None,
    messages: Sequence[Mapping[str, Any]] | None = None,
    instructions: str | None = None,
    **values: Any,
) -> bytes:
    document = dict(options or {})
    if prompt is not None:
        document["prompt"] = prompt
    if messages is not None:
        document["messages"] = list(messages)
    if instructions is not None:
        document["instructions"] = instructions
    for name, value in values.items():
        if value is not None:
            document[_OPTION_NAMES.get(name, name)] = value
    return json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def generate_text(
    model: Model,
    options: Mapping[str, Any] | None = None,
    *,
    prompt: str | None = None,
    messages: Sequence[Mapping[str, Any]] | None = None,
    instructions: str | None = None,
    tools: Sequence[Tool] = (),
    max_steps: int | None = None,
    max_retries: int | None = None,
    max_output_tokens: int | None = None,
    **values: Any,
) -> dict[str, Any]:
    encoded = make_options(
        options,
        prompt=prompt,
        messages=messages,
        instructions=instructions,
        max_steps=max_steps,
        max_retries=max_retries,
        max_output_tokens=max_output_tokens,
        **values,
    )
    options_arg = BytesArg(encoded)
    c_tools, tools_len = tool_array(tools)
    handle = ctypes.c_void_p()
    status = lib.ai_generate_text(
        model.runtime.handle,
        model.handle,
        options_arg.ptr,
        options_arg.len,
        c_tools,
        tools_len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    try:
        payload = read_string(lib.ai_result_json(handle))
        return json.loads(payload.decode("utf-8"))
    finally:
        lib.ai_result_destroy(handle)
