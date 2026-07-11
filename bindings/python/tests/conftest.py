from __future__ import annotations

import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest


PYTHON_BINDING = Path(__file__).resolve().parents[1]
if str(PYTHON_BINDING) not in sys.path:
    sys.path.insert(0, str(PYTHON_BINDING))


def _load_env_file() -> None:
    path = Path.home() / "src" / "rctr" / ".env"
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(name.strip(), value)


_load_env_file()


class CannedServer:
    def __init__(self):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self) -> None:
                length = int(self.headers.get("content-length", "0"))
                body = self.rfile.read(length)
                with owner.lock:
                    owner.requests.append(
                        {
                            "path": self.path,
                            "headers": dict(self.headers.items()),
                            "body": body,
                            "json": json.loads(body.decode("utf-8")),
                        }
                    )
                    response = owner.responses.popleft()
                self.close_connection = True
                if response[0] == "json":
                    _, status, payload = response
                    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                    self.send_response(status)
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(encoded)))
                    self.send_header("connection", "close")
                    self.end_headers()
                    self.wfile.write(encoded)
                    return

                _, events = response
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("cache-control", "no-cache")
                self.send_header("connection", "close")
                self.end_headers()
                try:
                    for data, delay_after in events:
                        self.wfile.write(b"data: " + data.encode("utf-8") + b"\n\n")
                        self.wfile.flush()
                        if delay_after:
                            time.sleep(delay_after)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, format: str, *args) -> None:
                del format, args

        self.responses: deque[tuple] = deque()
        self.requests: list[dict] = []
        self.lock = threading.Lock()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_port}"

    def enqueue_json(self, payload: dict, *, status: int = 200) -> None:
        with self.lock:
            self.responses.append(("json", status, payload))

    def enqueue_sse(self, events: list[str | tuple[str, float]]) -> None:
        normalized = [
            (event, 0.0) if isinstance(event, str) else event for event in events
        ]
        with self.lock:
            self.responses.append(("sse", normalized))

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)


@pytest.fixture
def canned_server():
    server = CannedServer()
    try:
        yield server
    finally:
        server.close()
