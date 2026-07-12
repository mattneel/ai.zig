# Media

The high-level media APIs normalize inputs, resolve a provider model, apply
retries, fan out calls where the provider has a per-call limit, aggregate
warnings and metadata, and return arena-owned files or text.

## Implemented surfaces

| Operation | High-level API | Native provider | Model used by repository evidence |
| --- | --- | --- | --- |
| Image | `ai.generateImage` | OpenAI | `gpt-image-1` fixtures |
| Speech | `ai.generateSpeech` | OpenAI | `gpt-4o-mini-tts` live |
| Transcription | `ai.transcribe` | OpenAI | `gpt-4o-mini-transcribe` live |
| Streaming transcription | `ai.streamTranscribe` | OpenAI realtime | `gpt-realtime-whisper` integration fixture |
| Video | `ai.generateVideo` | xAI | `grok-imagine-video` fixtures |

Provider V4 also defines media interfaces independently of those concrete
implementations. A custom provider can implement the same image, speech,
transcription, or video vtable and pass it to the core orchestrator.

## Speech-to-transcription pattern

The live Phase 10 smoke uses this lifecycle:

```zig
var speech_model = try factory.speechModel("gpt-4o-mini-tts", null);
var speech = try ai.generateSpeech(io, gpa, .{
    .model = .{ .model = speech_model.speechModel() },
    .text = "A short message from ai.zig.",
    .voice = "alloy",
    .output_format = "mp3",
});
defer speech.deinit();

const audio = try speech.audio.bytes(speech.arena_state.allocator());
var transcription_model = try factory.transcriptionModel(
    "gpt-4o-mini-transcribe",
    null,
);
var transcript = try ai.transcribe(io, gpa, .{
    .model = .{ .model = transcription_model.transcriptionModel() },
    .audio = .{ .data = .{ .bytes = audio } },
});
defer transcript.deinit();

std.debug.print("{s}\n", .{transcript.text});
```

`GeneratedFile` can retain bytes, base64, or a URL-backed value depending on
the provider path; the high-level video flow downloads returned URLs and
normalizes the media type. Result storage remains valid until the result's
`deinit()`.

## Image and video fan-out

`generateImage` and `generateVideo` respect the provider's maximum outputs per
call. When the requested `n` exceeds that maximum, the core creates multiple
jobs and runs them concurrently through `std.Io.Group`, then merges files,
warnings, response metadata, and provider metadata in call order.

Video accepts text or image prompts, first/last frame images, input references,
duration, aspect ratio, resolution, FPS, seed, audio generation, headers, and
provider options. The xAI implementation supports one video per provider call
and validates its narrower native option set. See the [xAI page](providers/xai.md)
for deferred-job behavior.

## Downloads and input safety

The common downloader handles inline `data:` URLs and HTTP(S), validates each
redirect, applies a size cap, and blocks obvious local/private address
literals. It does not resolve DNS before the request, so DNS rebinding remains
an explicitly open hardening item. Applications handling untrusted media URLs
should read the normative [SSRF policy](appendix/contracts.md#ssrf--download-policy).

## C ABI and wrappers

C ABI v1 exposes image, speech, and blocking transcription. Generated image
and speech bytes are indexed result blobs allocated by the library and copied
by both wrappers. Video and streaming transcription are not C ABI v1 surfaces
today, so they remain Zig-only. The Python and Rust chapters describe the
corresponding wrapper methods.

## Live-test cost policy

Default tests use canned HTTP, multipart, SSE, WebSocket, and polling fixtures.
The opt-in live suite performs a real OpenAI speech-to-transcription round
trip because it validates two media directions at controlled cost. Real image
and video generation is explicitly skipped as cost-gated. A passing fixture
test proves wire and orchestration behavior; it is not presented as a dated
live-provider claim.

