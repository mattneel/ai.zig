from __future__ import annotations

import ctypes
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from ._lib import BytesArg, lib
from ._results import Blob, consume_result, consume_result_document
from .generate import make_options
from .providers import ImageModel, SpeechModel, TranscriptionModel


@dataclass(frozen=True)
class ImageResult:
    metadata: dict[str, Any]
    images: tuple[Blob, ...]


@dataclass(frozen=True)
class SpeechResult:
    metadata: dict[str, Any]
    audio: Blob


def generate_image(
    model: ImageModel,
    prompt: str,
    options: Mapping[str, Any] | None = None,
    *,
    n: int | None = None,
    max_images_per_call: int | None = None,
    size: str | None = None,
    aspect_ratio: str | None = None,
    seed: int | None = None,
    max_retries: int | None = None,
    **values: Any,
) -> ImageResult:
    if not prompt:
        raise ValueError("prompt must not be empty")
    options_arg = BytesArg(
        make_options(
            options,
            prompt=prompt,
            n=n,
            max_images_per_call=max_images_per_call,
            size=size,
            aspect_ratio=aspect_ratio,
            seed=seed,
            max_retries=max_retries,
            **values,
        )
    )
    handle = ctypes.c_void_p()
    status = lib.ai_generate_image(
        model.runtime.handle,
        model.handle,
        options_arg.ptr,
        options_arg.len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    metadata, blobs = consume_result(handle, include_blobs=True)
    return ImageResult(metadata=metadata, images=blobs)


def generate_speech(
    model: SpeechModel,
    text: str,
    options: Mapping[str, Any] | None = None,
    *,
    voice: str | None = None,
    output_format: str | None = None,
    instructions: str | None = None,
    speed: float | None = None,
    language: str | None = None,
    max_retries: int | None = None,
    **values: Any,
) -> SpeechResult:
    if not text:
        raise ValueError("text must not be empty")
    options_arg = BytesArg(
        make_options(
            options,
            text=text,
            voice=voice,
            output_format=output_format,
            instructions=instructions,
            speed=speed,
            language=language,
            max_retries=max_retries,
            **values,
        )
    )
    handle = ctypes.c_void_p()
    status = lib.ai_generate_speech(
        model.runtime.handle,
        model.handle,
        options_arg.ptr,
        options_arg.len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    metadata, blobs = consume_result(handle, include_blobs=True)
    if len(blobs) != 1:
        raise RuntimeError(f"speech result returned {len(blobs)} audio blobs")
    return SpeechResult(metadata=metadata, audio=blobs[0])


def transcribe(
    model: TranscriptionModel,
    audio: bytes | bytearray | memoryview,
    options: Mapping[str, Any] | None = None,
    *,
    max_retries: int | None = None,
    **values: Any,
) -> dict[str, Any]:
    audio_arg = BytesArg(audio)
    if audio_arg.len == 0:
        raise ValueError("audio must not be empty")
    options_arg = BytesArg(
        make_options(options, max_retries=max_retries, **values)
    )
    handle = ctypes.c_void_p()
    status = lib.ai_transcribe(
        model.runtime.handle,
        model.handle,
        audio_arg.ptr,
        audio_arg.len,
        options_arg.ptr,
        options_arg.len,
        ctypes.byref(handle),
    )
    model.runtime._check(status)
    return consume_result_document(handle)
