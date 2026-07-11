from __future__ import annotations

import ctypes

from ._lib import RuntimeConfig, lib, read_string
from .errors import check


class Runtime:
    def __init__(self, *, async_limit: int = 0, concurrent_limit: int = 0):
        self._handle = ctypes.c_void_p()
        if async_limit < 0 or concurrent_limit < 0:
            raise ValueError("runtime limits must be non-negative")
        config = RuntimeConfig(ctypes.sizeof(RuntimeConfig), async_limit, concurrent_limit)
        handle = ctypes.c_void_p()
        status = lib.ai_runtime_create(ctypes.byref(config), ctypes.byref(handle))
        if status != 0:
            raise RuntimeError(f"ai_runtime_create failed with status {status}")
        self._handle = handle

    @property
    def handle(self) -> ctypes.c_void_p:
        if not self._handle:
            raise RuntimeError("Runtime is closed")
        return self._handle

    def last_error(self) -> str:
        if not self._handle:
            return ""
        return read_string(lib.ai_runtime_last_error(self._handle)).decode(
            "utf-8", errors="replace"
        )

    def _check(self, status: int) -> None:
        check(status, lambda: lib.ai_runtime_last_error(self.handle))

    def close(self) -> None:
        if getattr(self, "_handle", None):
            lib.ai_runtime_destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self) -> "Runtime":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()
