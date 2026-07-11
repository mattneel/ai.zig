from __future__ import annotations

import ctypes
import json
import threading
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Iterator, TypeVar

from ._lib import BytesArg, Part, Status, lib, read_string
from .errors import AiError
from .generate import make_options
from .providers import Model
from .tools import Tool, tool_array


class Stream(Iterator[dict[str, Any]]):
    """One-consumer pull stream with thread-safe cancellation and close."""

    def __init__(
        self,
        owner: Any,
        handle: ctypes.c_void_p,
        *,
        keepalive: Sequence[object] = (),
    ):
        self.owner = owner
        self.runtime = owner.runtime
        self._handle = handle
        self._keepalive = tuple(keepalive)
        self._next_lock = threading.RLock()
        self._state_lock = threading.Lock()
        self._closing = False

    def __iter__(self) -> "Stream":
        return self

    def __next__(self) -> dict[str, Any]:
        with self._next_lock:
            with self._state_lock:
                if self._closing or not self._handle:
                    raise StopIteration
                handle = self._handle

            part = Part()
            part.struct_size = ctypes.sizeof(Part)
            status = lib.ai_stream_next(handle, ctypes.byref(part))
            if status == Status.STREAM_DONE:
                self._destroy_after_next(handle)
                raise StopIteration
            if status != Status.OK:
                detail = read_string(lib.ai_stream_last_error(handle)).decode(
                    "utf-8", errors="replace"
                )
                self._destroy_after_next(handle)
                raise AiError(status, detail)
            payload = ctypes.string_at(part.json_ptr, part.json_len)
            return json.loads(payload.decode("utf-8"))

    def cancel(self) -> None:
        with self._state_lock:
            if self._closing or not self._handle:
                return
            handle = self._handle
        status = lib.ai_stream_cancel(handle)
        if status != Status.OK:
            detail = read_string(lib.ai_stream_last_error(handle)).decode(
                "utf-8", errors="replace"
            )
            raise AiError(status, detail)

    def close(self) -> None:
        with self._state_lock:
            if self._closing or not self._handle:
                return
            self._closing = True
            handle = self._handle

        status = lib.ai_stream_cancel(handle)
        detail = ""
        if status != Status.OK:
            detail = read_string(lib.ai_stream_last_error(handle)).decode(
                "utf-8", errors="replace"
            )

        # ai_stream_destroy must not race a blocked ai_stream_next. Cancel the
        # producer first, then wait until the sole pull has returned.
        with self._next_lock:
            with self._state_lock:
                owns_handle = bool(
                    self._handle and self._handle.value == handle.value
                )
            if owns_handle:
                lib.ai_stream_destroy(handle)
                with self._state_lock:
                    self._handle = ctypes.c_void_p()
                    self._keepalive = ()
                    self._closing = False

        if status != Status.OK:
            raise AiError(status, detail)

    def _destroy_after_next(self, handle: ctypes.c_void_p) -> None:
        with self._state_lock:
            owns_handle = bool(self._handle and self._handle.value == handle.value)
            if owns_handle:
                self._closing = True
        if not owns_handle:
            return
        lib.ai_stream_destroy(handle)
        with self._state_lock:
            self._handle = ctypes.c_void_p()
            self._keepalive = ()
            self._closing = False

    def __enter__(self: _StreamT) -> _StreamT:
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


_StreamT = TypeVar("_StreamT", bound=Stream)


class ObjectStream(Stream):
    """Object stream whose ``partials()`` view yields parsed partial values."""

    def partials(self) -> Iterator[Any]:
        for part in self:
            if part.get("type") == "object":
                yield part["object"]


class UIStream(Stream):
    """Iterator of parsed UI-message chunk dictionaries."""


def _open_stream(
    owner: Any,
    starter: Callable[[Any], int],
    *,
    stream_type: type[_StreamT] = Stream,
    keepalive: Sequence[object] = (),
) -> _StreamT:
    handle = ctypes.c_void_p()
    status = starter(ctypes.byref(handle))
    owner.runtime._check(status)
    return stream_type(owner, handle, keepalive=keepalive)


def _stream_text_call(
    model: Model,
    encoded_options: bytes,
    tools: Sequence[Tool],
    function: Callable[..., int],
    stream_type: type[_StreamT] = Stream,
) -> _StreamT:
    kept_tools = tuple(tools)
    c_tools, tools_len = tool_array(kept_tools)
    options_arg = BytesArg(encoded_options)

    def start(out: Any) -> int:
        return function(
            model.runtime.handle,
            model.handle,
            options_arg.ptr,
            options_arg.len,
            c_tools,
            tools_len,
            out,
        )

    return _open_stream(
        model,
        start,
        stream_type=stream_type,
        keepalive=kept_tools,
    )


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
    return _stream_text_call(model, encoded, tools, lib.ai_stream_text)


def stream_text_ui(
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
) -> UIStream:
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
    return _stream_text_call(
        model,
        encoded,
        tools,
        lib.ai_stream_text_ui,
        UIStream,
    )
