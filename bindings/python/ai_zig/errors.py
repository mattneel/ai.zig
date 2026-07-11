from __future__ import annotations

import json
from collections.abc import Callable

from ._lib import AiString, Status, read_string, status_name


class AiError(RuntimeError):
    def __init__(self, status: int, detail: str = ""):
        self.status = Status(status) if status in Status._value2member_map_ else Status.UNKNOWN
        self.status_name = status_name(status)
        self.detail = detail
        message = detail
        try:
            document = json.loads(detail)
            if isinstance(document, dict):
                message = str(document.get("message") or detail)
        except (json.JSONDecodeError, TypeError):
            pass
        super().__init__(f"{self.status_name}: {message or 'ai.zig call failed'}")


def check(status: int, last_error: Callable[[], AiString]) -> None:
    if status == Status.OK:
        return
    detail = read_string(last_error()).decode("utf-8", errors="replace")
    raise AiError(status, detail)
