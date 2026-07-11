from __future__ import annotations

import ctypes

from ._lib import (
    AnthropicConfig,
    BytesArg,
    OpenAICompatibleConfig,
    OpenRouterConfig,
    lib,
)
from .runtime import Runtime


class Provider:
    def __init__(self, runtime: Runtime, handle: ctypes.c_void_p):
        self.runtime = runtime
        self._handle = handle

    @property
    def handle(self) -> ctypes.c_void_p:
        if not self._handle:
            raise RuntimeError("Provider is closed")
        return self._handle

    def language_model(self, model_id: str) -> "Model":
        encoded = BytesArg(model_id)
        handle = ctypes.c_void_p()
        status = lib.ai_provider_language_model(
            self.handle, encoded.ptr, encoded.len, ctypes.byref(handle)
        )
        self.runtime._check(status)
        return Model(self, handle)

    def close(self) -> None:
        if self._handle:
            lib.ai_provider_destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self) -> "Provider":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()


class Model:
    def __init__(self, provider: Provider, handle: ctypes.c_void_p):
        self.provider = provider
        self.runtime = provider.runtime
        self._handle = handle

    @property
    def handle(self) -> ctypes.c_void_p:
        if not self._handle:
            raise RuntimeError("Model is closed")
        return self._handle

    def close(self) -> None:
        if self._handle:
            lib.ai_model_destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self) -> "Model":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()


def anthropic(
    runtime: Runtime,
    *,
    api_key: str,
    base_url: str | None = None,
) -> Provider:
    key = BytesArg(api_key)
    base = BytesArg(base_url)
    config = AnthropicConfig(key.ptr, key.len, base.ptr, base.len)
    handle = ctypes.c_void_p()
    status = lib.ai_provider_anthropic(runtime.handle, ctypes.byref(config), ctypes.byref(handle))
    runtime._check(status)
    return Provider(runtime, handle)


def openrouter(
    runtime: Runtime,
    *,
    api_key: str,
    base_url: str | None = None,
    referer: str | None = None,
    title: str | None = None,
) -> Provider:
    key = BytesArg(api_key)
    base = BytesArg(base_url)
    referer_arg = BytesArg(referer)
    title_arg = BytesArg(title)
    config = OpenRouterConfig(
        key.ptr,
        key.len,
        base.ptr,
        base.len,
        referer_arg.ptr,
        referer_arg.len,
        title_arg.ptr,
        title_arg.len,
    )
    handle = ctypes.c_void_p()
    status = lib.ai_provider_openrouter(runtime.handle, ctypes.byref(config), ctypes.byref(handle))
    runtime._check(status)
    return Provider(runtime, handle)


def openai_compatible(
    runtime: Runtime,
    *,
    name: str,
    base_url: str,
    api_key: str | None = None,
) -> Provider:
    name_arg = BytesArg(name)
    base = BytesArg(base_url)
    key = BytesArg(api_key)
    config = OpenAICompatibleConfig(
        name_arg.ptr,
        name_arg.len,
        base.ptr,
        base.len,
        key.ptr,
        key.len,
    )
    handle = ctypes.c_void_p()
    status = lib.ai_provider_openai_compatible(
        runtime.handle, ctypes.byref(config), ctypes.byref(handle)
    )
    runtime._check(status)
    return Provider(runtime, handle)
