# Realtime & WebSocket

Realtime support is split into a provider event vocabulary, a persistent
event reducer, a session orchestrator, host-injected audio, and an RFC 6455
client. The current concrete provider is OpenAI realtime.

## Session model

`ai.RealtimeSession.init(gpa, io, options)` receives a
`provider.RealtimeModel`, session configuration, tools, callbacks, audio, and
an optional transport. Without a custom transport it uses the provider model
to create a short-lived client secret, asks the model for WebSocket URL and
protocols, connects, and sends `session_update`.

The session exposes:

- `connect`, `disconnect`, and idempotent `dispose`;
- `sendTextMessage`, `sendAudio`, `commitAudio`, and `clearAudioBuffer`;
- `requestResponse` and `cancelResponse`;
- `addToolOutput` for manual tool completion;
- `startAudioCapture`, `stopAudioCapture`, and `stopPlayback`;
- `state(arena)` for a caller-owned deep snapshot.

State contains connection status, UI messages, a bounded event history,
capture state, and playback state. The reducer default keeps the newest 500
server events. Streaming text/audio transcripts and tool arguments are
assembled into framework-neutral `UIMessage` parts.

Collection callbacks receive deep snapshots valid for the callback duration.
The reducer itself uses independent arenas for messages and event-ring entries,
so replacing a streaming message or evicting an event releases displaced
payload rather than growing one session-wide arena forever.

## Tool gating and barge-in

Realtime function calls can complete out of order. The session records every
call id in the current response and every submitted output. It sends exactly
one new `response.create` only after both conditions are true:

1. the server has closed the response with `response.done`; and
2. every recorded tool call has a submitted output.

An `on_tool_call` handler can return a JSON value automatically or return
`null` for manual completion. Automatic handlers run concurrently in the
session tool group. A failed `response.create` retains readiness state so a
later trigger can retry; an in-flight claim prevents duplicate sends.

When a server `speech_started` event arrives during playback, the session
implements barge-in: it reads the host playback offset, stops playback,
publishes `is_playing = false`, and sends `conversation.item.truncate` for the
current response item. Playback remains marked active until explicit stop or
barge-in because the host audio vtable has no completion callback.

## Host audio and utilities

`RealtimeAudio` is an injected vtable for playback, capture, current playback
offset, and teardown. `stop_capture` must quiesce capture callbacks before
returning. The built-in null audio implementation makes text-only sessions
possible without a native audio dependency.

The `ai.realtime.audio` helpers:

- encode normalized `f32` samples as little-endian PCM16 base64;
- decode PCM16 base64 back to normalized samples;
- resample with linear interpolation and upstream-compatible length rounding.

All returned sample buffers are allocator-owned. Invalid base64, odd PCM byte
lengths, and zero sample rates are errors.

## WebSocket client design

`provider_utils.WebSocketLike` is injectable; the default `RealWebSocket`
uses `std.http.Client` for TCP/TLS and the HTTP upgrade, validates the 101
response and `Sec-WebSocket-Accept`, rejects unrequested protocols/extensions,
then takes ownership of the upgraded connection.

The client masks outbound frames, validates text UTF-8 and close codes,
reassembles allocator-backed inbound messages up to a configurable limit,
answers ping with pong, and shares one writer mutex across application sends,
automatic control frames, keepalive pings, and close. A receive task feeds a
bounded `Io.Queue`; an optional keepalive task sends after the idle interval.
Defaults are 4 MiB maximum messages, 30 seconds idle, a 5 second close wait,
and 32 queued inbound items.

Real concurrency is mandatory for receive and keepalive tasks. A
single-threaded `std.Io` returns `ConcurrencyUnavailable`; realtime does not
degrade into a misleading blocking shim.

## Disposal contract

Disposal uses an atomic `active → disposing → disposed` lifecycle. Calls from
inside session callbacks defer disconnect/disposal until callback unwinding.
The winning disposer stops audio, disconnects the transport, cancels tool
tasks, waits for active calls, tears down callbacks and reducer storage, and
drops delayed tool results. Other disposal attempts become no-ops.

The OpenAI factory's `realtimeModel("gpt-realtime", ...)` supplies the current
provider codec and subprotocol authentication. Realtime is beta and has no C
ABI v1 wrapper surface yet.

