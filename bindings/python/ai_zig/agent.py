from __future__ import annotations

import ctypes
from collections.abc import Mapping, Sequence
from typing import Any

from ._lib import AgentConfig, BytesArg, lib
from ._results import consume_result_document
from .generate import make_options
from .providers import Model
from .stream import Stream, _open_stream
from .tools import Tool, tool_array


class Agent:
    """A context-managed ``ai_agent`` with retained Python tool callbacks."""

    def __init__(
        self,
        model: Model,
        *,
        tools: Sequence[Tool] = (),
        instructions: str | None = None,
        max_steps: int = 20,
    ):
        if not 1 <= max_steps <= 0xFFFFFFFF:
            raise ValueError("max_steps must be between 1 and 2**32 - 1")
        self.model = model
        self.runtime = model.runtime
        self._tools = tuple(tools)
        self._c_tools, tools_len = tool_array(self._tools)
        self._instructions = BytesArg(instructions)
        self._handle = ctypes.c_void_p()
        config = AgentConfig(
            ctypes.sizeof(AgentConfig),
            self._c_tools,
            tools_len,
            self._instructions.ptr,
            self._instructions.len,
            max_steps,
        )
        status = lib.ai_agent_create(
            self.runtime.handle,
            model.handle,
            ctypes.byref(config),
            ctypes.byref(self._handle),
        )
        self.runtime._check(status)

    @property
    def handle(self) -> ctypes.c_void_p:
        if not self._handle:
            raise RuntimeError("Agent is closed")
        return self._handle

    def run(
        self,
        options: Mapping[str, Any] | None = None,
        *,
        prompt: str | None = None,
        messages: Sequence[Mapping[str, Any]] | None = None,
        instructions: str | None = None,
        max_retries: int | None = None,
        max_output_tokens: int | None = None,
        timeout_ms: int | None = None,
        tool_choice: Any = None,
        **values: Any,
    ) -> dict[str, Any]:
        options_arg = BytesArg(
            make_options(
                options,
                prompt=prompt,
                messages=messages,
                instructions=instructions,
                max_retries=max_retries,
                max_output_tokens=max_output_tokens,
                timeout_ms=timeout_ms,
                tool_choice=tool_choice,
                **values,
            )
        )
        handle = ctypes.c_void_p()
        status = lib.ai_agent_run(
            self.handle,
            options_arg.ptr,
            options_arg.len,
            ctypes.byref(handle),
        )
        self.runtime._check(status)
        return consume_result_document(handle)

    def stream(
        self,
        options: Mapping[str, Any] | None = None,
        *,
        prompt: str | None = None,
        messages: Sequence[Mapping[str, Any]] | None = None,
        instructions: str | None = None,
        max_retries: int | None = None,
        max_output_tokens: int | None = None,
        timeout_ms: int | None = None,
        tool_choice: Any = None,
        **values: Any,
    ) -> Stream:
        options_arg = BytesArg(
            make_options(
                options,
                prompt=prompt,
                messages=messages,
                instructions=instructions,
                max_retries=max_retries,
                max_output_tokens=max_output_tokens,
                timeout_ms=timeout_ms,
                tool_choice=tool_choice,
                **values,
            )
        )

        def start(out: Any) -> int:
            return lib.ai_agent_stream(
                self.handle,
                options_arg.ptr,
                options_arg.len,
                out,
            )

        return _open_stream(self, start, keepalive=self._tools)

    def close(self) -> None:
        if self._handle:
            lib.ai_agent_destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self) -> "Agent":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass
