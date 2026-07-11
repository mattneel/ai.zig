from __future__ import annotations

import ctypes
from collections.abc import Callable
from typing import TypeVar

from ._lib import (
    AnthropicConfig,
    BytesArg,
    OpenAICompatibleConfig,
    OpenAIConfig,
    OpenAILanguageAPI,
    OpenRouterConfig,
    XAIConfig,
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
        return self._create_model(
            model_id,
            lib.ai_provider_language_model,
            Model,
        )

    def embedding_model(self, model_id: str) -> "EmbeddingModel":
        return self._create_model(
            model_id,
            lib.ai_provider_embedding_model,
            EmbeddingModel,
        )

    def image_model(self, model_id: str) -> "ImageModel":
        return self._create_model(
            model_id,
            lib.ai_provider_image_model,
            ImageModel,
        )

    def speech_model(self, model_id: str) -> "SpeechModel":
        return self._create_model(
            model_id,
            lib.ai_provider_speech_model,
            SpeechModel,
        )

    def transcription_model(self, model_id: str) -> "TranscriptionModel":
        return self._create_model(
            model_id,
            lib.ai_provider_transcription_model,
            TranscriptionModel,
        )

    def _create_model(
        self,
        model_id: str,
        factory: Callable[..., int],
        model_type: type[_ModelT],
    ) -> _ModelT:
        encoded = BytesArg(model_id)
        handle = ctypes.c_void_p()
        status = factory(
            self.handle,
            encoded.ptr,
            encoded.len,
            ctypes.byref(handle),
        )
        self.runtime._check(status)
        return model_type(self, handle)

    def close(self) -> None:
        if self._handle:
            lib.ai_provider_destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self) -> "Provider":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


class _OwnedModel:
    _destroy: Callable[[ctypes.c_void_p], None]

    def __init__(self, provider: Provider, handle: ctypes.c_void_p):
        self.provider = provider
        self.runtime = provider.runtime
        self._handle = handle

    @property
    def handle(self) -> ctypes.c_void_p:
        if not self._handle:
            raise RuntimeError(f"{type(self).__name__} is closed")
        return self._handle

    def close(self) -> None:
        if self._handle:
            type(self)._destroy(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self: _ModelT) -> _ModelT:
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


_ModelT = TypeVar("_ModelT", bound=_OwnedModel)


class Model(_OwnedModel):
    _destroy = lib.ai_model_destroy


class EmbeddingModel(_OwnedModel):
    _destroy = lib.ai_embedding_model_destroy


class ImageModel(_OwnedModel):
    _destroy = lib.ai_image_model_destroy


class SpeechModel(_OwnedModel):
    _destroy = lib.ai_speech_model_destroy


class TranscriptionModel(_OwnedModel):
    _destroy = lib.ai_transcription_model_destroy


def anthropic(
    runtime: Runtime,
    *,
    api_key: str,
    base_url: str | None = None,
) -> Provider:
    key = BytesArg(api_key)
    base = BytesArg(base_url)
    config = AnthropicConfig(
        ctypes.sizeof(AnthropicConfig), key.ptr, key.len, base.ptr, base.len
    )
    return _create_provider(runtime, lib.ai_provider_anthropic, config)


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
        ctypes.sizeof(OpenRouterConfig),
        key.ptr,
        key.len,
        base.ptr,
        base.len,
        referer_arg.ptr,
        referer_arg.len,
        title_arg.ptr,
        title_arg.len,
    )
    return _create_provider(runtime, lib.ai_provider_openrouter, config)


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
        ctypes.sizeof(OpenAICompatibleConfig),
        name_arg.ptr,
        name_arg.len,
        base.ptr,
        base.len,
        key.ptr,
        key.len,
    )
    return _create_provider(runtime, lib.ai_provider_openai_compatible, config)


def openai(
    runtime: Runtime,
    *,
    api_key: str,
    base_url: str | None = None,
    organization: str | None = None,
    project: str | None = None,
    language_api: str | OpenAILanguageAPI = OpenAILanguageAPI.RESPONSES,
) -> Provider:
    key = BytesArg(api_key)
    base = BytesArg(base_url)
    organization_arg = BytesArg(organization)
    project_arg = BytesArg(project)
    config = OpenAIConfig(
        ctypes.sizeof(OpenAIConfig),
        key.ptr,
        key.len,
        base.ptr,
        base.len,
        organization_arg.ptr,
        organization_arg.len,
        project_arg.ptr,
        project_arg.len,
        int(_openai_language_api(language_api)),
    )
    return _create_provider(runtime, lib.ai_provider_openai, config)


def xai(
    runtime: Runtime,
    *,
    api_key: str,
    base_url: str | None = None,
) -> Provider:
    key = BytesArg(api_key)
    base = BytesArg(base_url)
    config = XAIConfig(
        ctypes.sizeof(XAIConfig),
        key.ptr,
        key.len,
        base.ptr,
        base.len,
    )
    return _create_provider(runtime, lib.ai_provider_xai, config)


def _create_provider(
    runtime: Runtime,
    factory: Callable[..., int],
    config: ctypes.Structure,
) -> Provider:
    handle = ctypes.c_void_p()
    status = factory(runtime.handle, ctypes.byref(config), ctypes.byref(handle))
    runtime._check(status)
    return Provider(runtime, handle)


def _openai_language_api(value: str | OpenAILanguageAPI) -> OpenAILanguageAPI:
    if isinstance(value, OpenAILanguageAPI):
        if value == OpenAILanguageAPI.UNKNOWN:
            raise ValueError("language_api must be 'responses' or 'chat'")
        return value
    normalized = value.strip().lower()
    if normalized == "responses":
        return OpenAILanguageAPI.RESPONSES
    if normalized == "chat":
        return OpenAILanguageAPI.CHAT
    raise ValueError("language_api must be 'responses' or 'chat'")
