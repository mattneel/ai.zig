from __future__ import annotations

import ctypes
import json
from dataclasses import dataclass
from typing import Any

from ._lib import AiBuffer, Status, lib, read_string
from .errors import AiError


@dataclass(frozen=True)
class Blob:
    """An owned Python copy of a library result blob."""

    data: bytes
    media_type: str


def consume_result(
    handle: ctypes.c_void_p,
    *,
    include_blobs: bool = False,
) -> tuple[dict[str, Any], tuple[Blob, ...]]:
    """Copy a result document and optional blobs, then destroy the C handle."""

    try:
        payload = read_string(lib.ai_result_json(handle))
        document = json.loads(payload.decode("utf-8"))
        blobs = _copy_blobs(handle) if include_blobs else ()
        return document, blobs
    finally:
        lib.ai_result_destroy(handle)


def consume_result_document(handle: ctypes.c_void_p) -> dict[str, Any]:
    document, _ = consume_result(handle)
    return document


def _copy_blobs(handle: ctypes.c_void_p) -> tuple[Blob, ...]:
    copied: list[Blob] = []
    for index in range(lib.ai_result_blob_count(handle)):
        media_type = read_string(lib.ai_result_blob_media_type(handle, index)).decode(
            "utf-8", errors="replace"
        )
        buffer = AiBuffer()
        buffer.struct_size = ctypes.sizeof(AiBuffer)
        status = lib.ai_result_blob(handle, index, ctypes.byref(buffer))
        if status != Status.OK:
            raise AiError(status)
        try:
            data = ctypes.string_at(buffer.ptr, buffer.len) if buffer.len else b""
        finally:
            if buffer.ptr:
                lib.ai_buf_free(buffer.ptr, buffer.len)
        copied.append(Blob(data=data, media_type=media_type))
    return tuple(copied)
