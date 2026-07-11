from __future__ import annotations

import ctypes
import json
from collections.abc import Mapping, Sequence
from typing import Any, Iterator

from ._lib import BytesArg, Part, Status, lib, read_string
from .errors import AiError
from .generate import make_options
from .providers import Model
from .tools import Tool, tool_array


class Stream(Iterator[dict[str, Any]]):
    def __init__(
        self,
        model: Model,
        encoded_options: bytes,
        tools: Sequence[Tool],
    ):
        self.model = model
        self.runtime = model.runtime
        self._handle = ctypes.c_void_p()
        self._tools = tuple(tools)
        self._c_tools, self._tools_len = tool_array(self._tools)
        self._options = BytesArg(encoded_options)
        status = lib.ai_stream_text(
            self.runtime.handle,
            model.handle,
            self._options.ptr,
            self._options.len,
            self._c_tools,
            self._tools_len,
            ctypes.byref(self._handle),
        )
        self.runtime._check(status)

    def __iter__(self) -> "Stream":
        return self

    def __next__(self) -> dict[str, Any]:
        if not self._handle:
            raise StopIteration
        part = Part()
        part.struct_size = ctypes.sizeof(Part)
        status = lib.ai_stream_next(self._handle, ctypes.byref(part))
        if status == Status.STREAM_DONE:
            self.close()
            raise StopIteration
        if status != Status.OK:
            detail = read_string(lib.ai_stream_last_error(self._handle)).decode(
                "utf-8", errors="replace"
            )
            self.close()
            raise AiError(status, detail)
        payload = ctypes.string_at(part.json_ptr, part.json_len)
        return json.loads(payload.decode("utf-8"))

    def cancel(self) -> None:
        if not self._handle:
            return
        status = lib.ai_stream_cancel(self._handle)
        if status != Status.OK:
            detail = read_string(lib.ai_stream_last_error(self._handle)).decode(
                "utf-8", errors="replace"
            )
            raise AiError(status, detail)

    def close(self) -> None:
        if getattr(self, "_handle", None):
            lib.ai_stream_destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self) -> "Stream":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()


def stream_text(
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
) -> Stream:
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
    return Stream(model, encoded, tools)
