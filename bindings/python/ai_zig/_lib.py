from __future__ import annotations

import ctypes
import os
import platform
from enum import IntEnum
from pathlib import Path


ABI_VERSION_MAJOR = 1
ABI_VERSION_MINOR = 0
ABI_VERSION_PATCH = 0
ABI_VERSION = (ABI_VERSION_MAJOR << 24) | (ABI_VERSION_MINOR << 16) | ABI_VERSION_PATCH


class Status(IntEnum):
    OK = 0
    STREAM_DONE = 1
    INVALID_ARGUMENT = 10
    API_CALL = 20
    NO_SUCH_MODEL = 30
    NO_SUCH_PROVIDER = 31
    LOAD_API_KEY = 40
    LOAD_SETTING = 41
    RETRY = 50
    CANCELED = 60
    TIMEOUT = 61
    OUT_OF_MEMORY = 70
    INVALID_JSON = 80
    INVALID_PROMPT = 81
    INVALID_RESPONSE = 82
    NO_SUCH_TOOL = 90
    TOOL_ERROR = 91
    UNSUPPORTED = 100
    UNKNOWN = -1


class PartType(IntEnum):
    TEXT_START = 0
    TEXT_END = 1
    TEXT_DELTA = 2
    REASONING_START = 3
    REASONING_END = 4
    REASONING_DELTA = 5
    CUSTOM = 6
    TOOL_INPUT_START = 7
    TOOL_INPUT_END = 8
    TOOL_INPUT_DELTA = 9
    SOURCE = 10
    FILE = 11
    REASONING_FILE = 12
    TOOL_CALL = 13
    TOOL_RESULT = 14
    TOOL_ERROR = 15
    TOOL_OUTPUT_DENIED = 16
    TOOL_APPROVAL_REQUEST = 17
    TOOL_APPROVAL_RESPONSE = 18
    START_STEP = 19
    FINISH_STEP = 20
    START = 21
    FINISH = 22
    ABORT = 23
    ERROR = 24
    RAW = 25
    OBJECT = 26
    UI_MESSAGE = 27
    UNKNOWN = -1


class OpenAILanguageAPI(IntEnum):
    RESPONSES = 0
    CHAT = 1
    UNKNOWN = -1


class AiString(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("len", ctypes.c_size_t)]


class RuntimeConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("async_limit", ctypes.c_size_t),
        ("concurrent_limit", ctypes.c_size_t),
    ]


class AnthropicConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("api_key_ptr", ctypes.c_void_p),
        ("api_key_len", ctypes.c_size_t),
        ("base_url_ptr", ctypes.c_void_p),
        ("base_url_len", ctypes.c_size_t),
    ]


class OpenRouterConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("api_key_ptr", ctypes.c_void_p),
        ("api_key_len", ctypes.c_size_t),
        ("base_url_ptr", ctypes.c_void_p),
        ("base_url_len", ctypes.c_size_t),
        ("referer_ptr", ctypes.c_void_p),
        ("referer_len", ctypes.c_size_t),
        ("title_ptr", ctypes.c_void_p),
        ("title_len", ctypes.c_size_t),
    ]


class OpenAICompatibleConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("name_ptr", ctypes.c_void_p),
        ("name_len", ctypes.c_size_t),
        ("base_url_ptr", ctypes.c_void_p),
        ("base_url_len", ctypes.c_size_t),
        ("api_key_ptr", ctypes.c_void_p),
        ("api_key_len", ctypes.c_size_t),
    ]


class ToolResult(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("ptr", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
    ]


ToolExecute = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ToolResult),
)


class CTool(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("name_ptr", ctypes.c_void_p),
        ("name_len", ctypes.c_size_t),
        ("description_ptr", ctypes.c_void_p),
        ("description_len", ctypes.c_size_t),
        ("input_schema_json_ptr", ctypes.c_void_p),
        ("input_schema_json_len", ctypes.c_size_t),
        ("execute", ToolExecute),
        ("user_data", ctypes.c_void_p),
    ]


class Part(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("type", ctypes.c_int),
        ("json_ptr", ctypes.c_void_p),
        ("json_len", ctypes.c_size_t),
        ("text_ptr", ctypes.c_void_p),
        ("text_len", ctypes.c_size_t),
    ]


class OpenAIConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("api_key_ptr", ctypes.c_void_p),
        ("api_key_len", ctypes.c_size_t),
        ("base_url_ptr", ctypes.c_void_p),
        ("base_url_len", ctypes.c_size_t),
        ("organization_ptr", ctypes.c_void_p),
        ("organization_len", ctypes.c_size_t),
        ("project_ptr", ctypes.c_void_p),
        ("project_len", ctypes.c_size_t),
        ("language_api", ctypes.c_int),
    ]


class XAIConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("api_key_ptr", ctypes.c_void_p),
        ("api_key_len", ctypes.c_size_t),
        ("base_url_ptr", ctypes.c_void_p),
        ("base_url_len", ctypes.c_size_t),
    ]


class AiBuffer(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("ptr", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
    ]


class AgentConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("tools", ctypes.POINTER(CTool)),
        ("tools_len", ctypes.c_size_t),
        ("system_ptr", ctypes.c_void_p),
        ("system_len", ctypes.c_size_t),
        ("max_steps", ctypes.c_uint32),
    ]


TelemetryEvent = ctypes.CFUNCTYPE(
    None,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
)
TelemetryEnter = ctypes.CFUNCTYPE(
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
)
TelemetryExit = ctypes.CFUNCTYPE(
    None,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
)


class TelemetryVTable(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_size_t),
        ("user_data", ctypes.c_void_p),
        ("on_event", TelemetryEvent),
        ("enter", TelemetryEnter),
        ("exit", TelemetryExit),
    ]


class BytesArg:
    def __init__(self, value: str | bytes | None):
        if value is None:
            self.data = b""
            self.buffer = None
            self.ptr = None
            self.len = 0
            return
        self.data = value.encode("utf-8") if isinstance(value, str) else bytes(value)
        if not self.data:
            self.buffer = None
            self.ptr = None
            self.len = 0
            return
        self.buffer = ctypes.create_string_buffer(self.data, len(self.data))
        self.ptr = ctypes.cast(self.buffer, ctypes.c_void_p)
        self.len = len(self.data)


def read_string(value: AiString) -> bytes:
    if not value.ptr or not value.len:
        return b""
    return ctypes.string_at(value.ptr, value.len)


def _library_candidates() -> list[Path]:
    override = os.environ.get("AI_ZIG_LIB")
    if override:
        return [Path(override).expanduser()]
    root = Path(__file__).resolve().parents[3]
    lib_dir = root / "zig-out" / "lib"
    system = platform.system()
    if system == "Darwin":
        names = ["libai.dylib", "libai.1.dylib", "libai.1.0.0.dylib"]
    elif system == "Windows":
        names = ["ai.dll", "libai.dll"]
    else:
        names = ["libai.so", "libai.so.1", "libai.so.1.0.0"]
    return [lib_dir / name for name in names]


def _load() -> ctypes.CDLL:
    candidates = _library_candidates()
    for candidate in candidates:
        if candidate.exists():
            return ctypes.CDLL(str(candidate))
    searched = ", ".join(str(path) for path in candidates)
    raise OSError(f"ai.zig shared library not found ({searched}); run `zig build ffi`")


lib = _load()

lib.ai_abi_version.argtypes = []
lib.ai_abi_version.restype = ctypes.c_uint32
lib.ai_abi_version_string.argtypes = []
lib.ai_abi_version_string.restype = AiString
_loaded_abi_version = int(lib.ai_abi_version())
if (_loaded_abi_version >> 24) != ABI_VERSION_MAJOR:
    raise OSError(
        "ai.zig ABI major mismatch: "
        f"binding={ABI_VERSION_MAJOR}, library={_loaded_abi_version >> 24}"
    )
lib.ai_status_name.argtypes = [ctypes.c_int]
lib.ai_status_name.restype = ctypes.c_char_p
lib.ai_alloc.argtypes = [ctypes.c_size_t]
lib.ai_alloc.restype = ctypes.c_void_p
lib.ai_buf_free.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
lib.ai_buf_free.restype = None

lib.ai_runtime_create.argtypes = [
    ctypes.POINTER(RuntimeConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_runtime_create.restype = ctypes.c_int
lib.ai_runtime_destroy.argtypes = [ctypes.c_void_p]
lib.ai_runtime_destroy.restype = None
lib.ai_runtime_last_error.argtypes = [ctypes.c_void_p]
lib.ai_runtime_last_error.restype = AiString

lib.ai_provider_anthropic.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(AnthropicConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_provider_anthropic.restype = ctypes.c_int
lib.ai_provider_openrouter.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(OpenRouterConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_provider_openrouter.restype = ctypes.c_int
lib.ai_provider_openai_compatible.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(OpenAICompatibleConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_provider_openai_compatible.restype = ctypes.c_int
lib.ai_provider_openai.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(OpenAIConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_provider_openai.restype = ctypes.c_int
lib.ai_provider_xai.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(XAIConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_provider_xai.restype = ctypes.c_int
lib.ai_provider_destroy.argtypes = [ctypes.c_void_p]
lib.ai_provider_destroy.restype = None
lib.ai_provider_language_model.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_provider_language_model.restype = ctypes.c_int
lib.ai_model_destroy.argtypes = [ctypes.c_void_p]
lib.ai_model_destroy.restype = None
for _model_factory in (
    "ai_provider_embedding_model",
    "ai_provider_image_model",
    "ai_provider_speech_model",
    "ai_provider_transcription_model",
):
    _function = getattr(lib, _model_factory)
    _function.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    _function.restype = ctypes.c_int
for _model_destroy in (
    "ai_embedding_model_destroy",
    "ai_image_model_destroy",
    "ai_speech_model_destroy",
    "ai_transcription_model_destroy",
):
    _function = getattr(lib, _model_destroy)
    _function.argtypes = [ctypes.c_void_p]
    _function.restype = None

lib.ai_generate_text.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(CTool),
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_generate_text.restype = ctypes.c_int
lib.ai_generate_object.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_generate_object.restype = ctypes.c_int
lib.ai_embed.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_embed.restype = ctypes.c_int
lib.ai_embed_many.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(AiString),
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_embed_many.restype = ctypes.c_int
lib.ai_result_json.argtypes = [ctypes.c_void_p]
lib.ai_result_json.restype = AiString
lib.ai_result_text.argtypes = [ctypes.c_void_p]
lib.ai_result_text.restype = AiString
lib.ai_result_finish_reason.argtypes = [ctypes.c_void_p]
lib.ai_result_finish_reason.restype = AiString
lib.ai_result_total_tokens.argtypes = [ctypes.c_void_p]
lib.ai_result_total_tokens.restype = ctypes.c_uint64
lib.ai_result_blob_count.argtypes = [ctypes.c_void_p]
lib.ai_result_blob_count.restype = ctypes.c_size_t
lib.ai_result_blob_media_type.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
lib.ai_result_blob_media_type.restype = AiString
lib.ai_result_blob.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(AiBuffer)]
lib.ai_result_blob.restype = ctypes.c_int
lib.ai_result_destroy.argtypes = [ctypes.c_void_p]
lib.ai_result_destroy.restype = None

lib.ai_stream_text.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(CTool),
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_stream_text.restype = ctypes.c_int
lib.ai_stream_text_ui.argtypes = lib.ai_stream_text.argtypes
lib.ai_stream_text_ui.restype = ctypes.c_int
lib.ai_stream_object.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_stream_object.restype = ctypes.c_int
lib.ai_stream_next.argtypes = [ctypes.c_void_p, ctypes.POINTER(Part)]
lib.ai_stream_next.restype = ctypes.c_int
lib.ai_stream_cancel.argtypes = [ctypes.c_void_p]
lib.ai_stream_cancel.restype = ctypes.c_int
lib.ai_stream_last_error.argtypes = [ctypes.c_void_p]
lib.ai_stream_last_error.restype = AiString
lib.ai_part_clone.argtypes = [ctypes.POINTER(Part), ctypes.POINTER(AiString)]
lib.ai_part_clone.restype = ctypes.c_int
lib.ai_stream_destroy.argtypes = [ctypes.c_void_p]
lib.ai_stream_destroy.restype = None

lib.ai_agent_create.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(AgentConfig),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_agent_create.restype = ctypes.c_int
lib.ai_agent_run.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_agent_run.restype = ctypes.c_int
lib.ai_agent_stream.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_agent_stream.restype = ctypes.c_int
lib.ai_agent_destroy.argtypes = [ctypes.c_void_p]
lib.ai_agent_destroy.restype = None

lib.ai_telemetry_register.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(TelemetryVTable),
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_telemetry_register.restype = ctypes.c_int
lib.ai_telemetry_unregister.argtypes = [ctypes.c_void_p]
lib.ai_telemetry_unregister.restype = None
lib.ai_telemetry_clear.argtypes = []
lib.ai_telemetry_clear.restype = None

for _media_call in ("ai_generate_image", "ai_generate_speech"):
    _function = getattr(lib, _media_call)
    _function.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    _function.restype = ctypes.c_int
lib.ai_transcribe.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_void_p),
]
lib.ai_transcribe.restype = ctypes.c_int


def status_name(status: int) -> str:
    value = lib.ai_status_name(status)
    return value.decode("ascii") if value else "unknown"
