from __future__ import annotations

import ctypes
import itertools
import json
import threading
import weakref
from collections.abc import Callable, Mapping
from typing import Any

from ._lib import (
    TelemetryEnter,
    TelemetryEvent,
    TelemetryExit,
    TelemetryVTable,
    lib,
)
from .runtime import Runtime


class _CallbackState:
    def __init__(
        self,
        on_event: Callable[[str, Any], Any] | None,
        enter: Callable[[str, str], Any] | None,
        exit: Callable[[str, Any], Any] | None,
    ):
        self.on_event = on_event
        self.enter = enter
        self.exit = exit
        self._exception_lock = threading.Lock()
        self._exceptions: list[BaseException] = []
        self._token_lock = threading.Lock()
        self._tokens: dict[int, Any] = {}
        self._token_ids = itertools.count(1)

        self.event_callback = (
            TelemetryEvent(self._on_event) if on_event is not None else TelemetryEvent()
        )
        self.enter_callback = (
            TelemetryEnter(self._enter) if enter is not None else TelemetryEnter()
        )
        self.exit_callback = (
            TelemetryExit(self._exit) if exit is not None else TelemetryExit()
        )
        self.vtable = TelemetryVTable(
            ctypes.sizeof(TelemetryVTable),
            None,
            self.event_callback,
            self.enter_callback,
            self.exit_callback,
        )

    @property
    def exceptions(self) -> tuple[BaseException, ...]:
        with self._exception_lock:
            return tuple(self._exceptions)

    @property
    def last_exception(self) -> BaseException | None:
        with self._exception_lock:
            return self._exceptions[-1] if self._exceptions else None

    def _record_exception(self, exception: BaseException) -> None:
        with self._exception_lock:
            self._exceptions.append(exception)

    def _on_event(
        self,
        user_data: int | None,
        name_ptr: int | None,
        name_len: int,
        event_ptr: int | None,
        event_len: int,
    ) -> None:
        del user_data
        try:
            name = ctypes.string_at(name_ptr, name_len).decode("utf-8")
            payload = ctypes.string_at(event_ptr, event_len)
            event = json.loads(payload.decode("utf-8"))
            assert self.on_event is not None
            self.on_event(name, event)
        except BaseException as exception:
            self._record_exception(exception)

    def _enter(
        self,
        user_data: int | None,
        scope_ptr: int | None,
        scope_len: int,
        call_id_ptr: int | None,
        call_id_len: int,
    ) -> int | None:
        del user_data
        try:
            scope = ctypes.string_at(scope_ptr, scope_len).decode("utf-8")
            call_id = ctypes.string_at(call_id_ptr, call_id_len).decode("utf-8")
            assert self.enter is not None
            token = self.enter(scope, call_id)
            if token is None or self.exit is None:
                return None
            with self._token_lock:
                token_id = next(self._token_ids)
                self._tokens[token_id] = token
            return token_id
        except BaseException as exception:
            self._record_exception(exception)
            return None

    def _exit(
        self,
        user_data: int | None,
        scope_ptr: int | None,
        scope_len: int,
        token_ptr: int | None,
    ) -> None:
        del user_data
        try:
            scope = ctypes.string_at(scope_ptr, scope_len).decode("utf-8")
            token_id = int(token_ptr) if token_ptr else 0
            if token_id:
                with self._token_lock:
                    token = self._tokens.pop(token_id, None)
            else:
                token = None
            assert self.exit is not None
            self.exit(scope, token)
        except BaseException as exception:
            self._record_exception(exception)

    def clear_tokens(self) -> None:
        with self._token_lock:
            self._tokens.clear()


class TelemetryRegistration:
    """A logical telemetry registration retained until ``clear_telemetry``."""

    def __init__(self, handle: ctypes.c_void_p, state: _CallbackState):
        self._handle = handle
        self._state = state
        self._active = True

    @property
    def active(self) -> bool:
        return self._active

    @property
    def callback_exceptions(self) -> tuple[BaseException, ...]:
        return self._state.exceptions

    @property
    def last_exception(self) -> BaseException | None:
        return self._state.last_exception

    def close(self) -> None:
        with _registry_lock:
            if not self._active or not self._handle:
                return
            lib.ai_telemetry_unregister(self._handle)
            self._active = False

    def _mark_cleared(self) -> None:
        self._active = False
        self._handle = ctypes.c_void_p()

    def __enter__(self) -> "TelemetryRegistration":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


_registry_lock = threading.RLock()
_callback_states: dict[int, _CallbackState] = {}
_registration_objects: weakref.WeakSet[TelemetryRegistration] = weakref.WeakSet()


def register(
    runtime: Runtime,
    callbacks_or_object: Mapping[str, Callable[..., Any]] | object,
) -> TelemetryRegistration:
    """Register mapping entries or object methods named on_event/enter/exit."""

    on_event, enter, exit = _callbacks(callbacks_or_object)
    if on_event is None and enter is None and exit is None:
        raise ValueError("telemetry callbacks must define on_event, enter, or exit")
    state = _CallbackState(on_event, enter, exit)
    handle = ctypes.c_void_p()
    with _registry_lock:
        status = lib.ai_telemetry_register(
            runtime.handle,
            ctypes.byref(state.vtable),
            ctypes.byref(handle),
        )
        runtime._check(status)
        registration = TelemetryRegistration(handle, state)
        _callback_states[handle.value] = state
        _registration_objects.add(registration)
    return registration


def clear() -> None:
    """Clear all registrations after every telemetry-producing call quiesces."""

    with _registry_lock:
        lib.ai_telemetry_clear()
        for registration in tuple(_registration_objects):
            registration._mark_cleared()
        for state in _callback_states.values():
            state.clear_tokens()
        _callback_states.clear()


def _callbacks(
    callbacks_or_object: Mapping[str, Callable[..., Any]] | object,
) -> tuple[
    Callable[[str, Any], Any] | None,
    Callable[[str, str], Any] | None,
    Callable[[str, Any], Any] | None,
]:
    if callable(callbacks_or_object) and not isinstance(callbacks_or_object, Mapping):
        return callbacks_or_object, None, None
    if isinstance(callbacks_or_object, Mapping):
        values = tuple(callbacks_or_object.get(name) for name in ("on_event", "enter", "exit"))
    else:
        values = tuple(
            getattr(callbacks_or_object, name, None)
            for name in ("on_event", "enter", "exit")
        )
    for name, value in zip(("on_event", "enter", "exit"), values, strict=True):
        if value is not None and not callable(value):
            raise TypeError(f"telemetry {name} callback must be callable")
    return values
