from __future__ import annotations

import ctypes
import json
from collections.abc import Mapping, Sequence
from typing import Any

from ._lib import BytesArg, lib
from ._results import consume_result_document
from .generate import make_options
from .providers import Model
from .stream import ObjectStream, _open_stream


def generate_object(
    model: Model,
    schema: Mapping[str, Any] | str,
    options: Mapping[str, Any] | None = None,
    *,
    prompt: str | None = None,
    messages: Sequence[Mapping[str, Any]] | None = None,
    instructions: str | None = None,
    max_retries: int | None = None,
    max_output_tokens: int | None = None,
    **values: Any,
) -> dict[str, Any]:
    encoded_options = make_options(
        options,
        prompt=prompt,
        messages=messages,
        instructions=instructions,
        max_retries=max_retries,
        max_output_tokens=max_output_tokens,
        **values,
    )
    options_arg = BytesArg(encoded_options)
    schema_arg = BytesArg(_schema_json(schema))
    handle = ctypes.c_void_p()
    status = lib.ai_generate_object(
        model.runtime.handle,
        model.handle,
        options_arg.ptr,
        options_arg.len,
        schema_arg.ptr,
        schema_arg.len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    return consume_result_document(handle)


def stream_object(
    model: Model,
    schema: Mapping[str, Any] | str,
    options: Mapping[str, Any] | None = None,
    *,
    prompt: str | None = None,
    messages: Sequence[Mapping[str, Any]] | None = None,
    instructions: str | None = None,
    max_retries: int | None = None,
    max_output_tokens: int | None = None,
    **values: Any,
) -> ObjectStream:
    encoded_options = make_options(
        options,
        prompt=prompt,
        messages=messages,
        instructions=instructions,
        max_retries=max_retries,
        max_output_tokens=max_output_tokens,
        **values,
    )
    options_arg = BytesArg(encoded_options)
    schema_arg = BytesArg(_schema_json(schema))

    def start(out: Any) -> int:
        return lib.ai_stream_object(
            model.runtime.handle,
            model.handle,
            options_arg.ptr,
            options_arg.len,
            schema_arg.ptr,
            schema_arg.len,
            out,
        )

    return _open_stream(model, start, stream_type=ObjectStream)


def _schema_json(schema: Mapping[str, Any] | str) -> str:
    if isinstance(schema, str):
        return schema
    if isinstance(schema, Mapping):
        return json.dumps(schema, separators=(",", ":"), ensure_ascii=False)
    raise TypeError("schema must be a mapping or a JSON string")
