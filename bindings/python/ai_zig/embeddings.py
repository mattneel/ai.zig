from __future__ import annotations

import ctypes
from collections.abc import Mapping, Sequence
from typing import Any

from ._lib import AiString, BytesArg, lib
from ._results import consume_result_document
from .generate import make_options
from .providers import EmbeddingModel


def embed(
    model: EmbeddingModel,
    value: str | bytes,
    options: Mapping[str, Any] | None = None,
    *,
    max_retries: int | None = None,
    **values: Any,
) -> dict[str, Any]:
    value_arg = BytesArg(value)
    options_arg = BytesArg(
        make_options(options, max_retries=max_retries, **values)
    )
    handle = ctypes.c_void_p()
    status = lib.ai_embed(
        model.runtime.handle,
        model.handle,
        value_arg.ptr,
        value_arg.len,
        options_arg.ptr,
        options_arg.len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    return consume_result_document(handle)


def embed_many(
    model: EmbeddingModel,
    values: Sequence[str | bytes],
    options: Mapping[str, Any] | None = None,
    *,
    max_retries: int | None = None,
    max_parallel_calls: int | None = None,
    **option_values: Any,
) -> dict[str, Any]:
    value_args = tuple(BytesArg(value) for value in values)
    if value_args:
        array_type = AiString * len(value_args)
        c_values = array_type(
            *(AiString(value.ptr, value.len) for value in value_args)
        )
    else:
        c_values = None
    options_arg = BytesArg(
        make_options(
            options,
            max_retries=max_retries,
            max_parallel_calls=max_parallel_calls,
            **option_values,
        )
    )
    handle = ctypes.c_void_p()
    status = lib.ai_embed_many(
        model.runtime.handle,
        model.handle,
        c_values,
        len(value_args),
        options_arg.ptr,
        options_arg.len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    return consume_result_document(handle)
