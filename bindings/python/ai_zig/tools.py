from __future__ import annotations

import ctypes
import json
import threading
from collections.abc import Callable, Sequence
from typing import Any

from ._lib import BytesArg, CTool, Status, ToolExecute, lib


class Tool:
    def __init__(
        self,
        name: str,
        execute: Callable[[Any], Any],
        *,
        description: str = "",
        input_schema: dict[str, Any] | str | None = None,
    ):
        self.name = name
        self.description = description
        self.input_schema = input_schema if input_schema is not None else {}
        self.execute = execute
        self.last_exception: BaseException | None = None
        self._exception_lock = threading.Lock()
        self._name = BytesArg(name)
        self._description = BytesArg(description)
        schema_text = (
            self.input_schema
            if isinstance(self.input_schema, str)
            else json.dumps(self.input_schema, separators=(",", ":"), ensure_ascii=False)
        )
        self._schema = BytesArg(schema_text)
        self._callback = ToolExecute(self._invoke)
        self._c_tool = CTool(
            ctypes.sizeof(CTool),
            self._name.ptr,
            self._name.len,
            self._description.ptr,
            self._description.len,
            self._schema.ptr,
            self._schema.len,
            self._callback,
            None,
        )

    @property
    def c_tool(self) -> CTool:
        return self._c_tool

    def _invoke(self, user_data, input_ptr, input_len, out) -> int:
        del user_data
        try:
            payload = ctypes.string_at(input_ptr, input_len)
            value = json.loads(payload.decode("utf-8"))
            encoded = json.dumps(
                self.execute(value), separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            ptr = lib.ai_alloc(len(encoded))
            if encoded and not ptr:
                return int(Status.OUT_OF_MEMORY)
            if encoded:
                ctypes.memmove(ptr, encoded, len(encoded))
            out.contents.struct_size = ctypes.sizeof(out.contents)
            out.contents.ptr = ptr
            out.contents.len = len(encoded)
            return int(Status.OK)
        except BaseException as exc:  # ctypes must never unwind through C.
            with self._exception_lock:
                self.last_exception = exc
            return int(Status.TOOL_ERROR)


def tool_array(tools: Sequence[Tool]) -> tuple[object | None, int]:
    if not tools:
        return None, 0
    array_type = CTool * len(tools)
    return array_type(*(tool.c_tool for tool in tools)), len(tools)
