# xAI

The xAI provider combines OpenAI-compatible chat with a native deferred-job
video model. The two model families share authentication, base URL, headers,
transport, and provider ownership but use different wire implementations.

## Construction

```zig
var factory = xai.createXai(.{
    .allocator = gpa,
    .api_key = api_key,
    .transport = transport.transport(),
});

var chat = try factory.chatModel("grok-4", null);
var video = try factory.videoModel("grok-imagine-video", null);
```

`languageModel` aliases `chatModel`. The chat provider name is `xai.chat` and
declares OpenAI-compatible structured-output support. The video provider name
is `xai.video`. `embeddingModel` returns `NoSuchModelError`, and the adapter's
image-model path is intentionally unsupported.

`XAI_API_KEY` and `XAI_BASE_URL` are recognized through an injected
`EnvLookup`; the default URL is `https://api.x.ai/v1`. The key is resolved at
call time for both chat and video. The model ids above come from the checked-in
factory tests and video fixtures.

## Video job lifecycle

The video implementation creates a job, polls its status with retry-aware
HTTP handling, and returns one URL-backed video when the job is done. It
advertises a maximum of one video per provider call; high-level
`ai.generateVideo` can fan out multiple calls concurrently when `n > 1`.

Supported native inputs include a text prompt, start image, frame images,
reference images, edit/extend modes, duration, aspect ratio, and xAI-specific
resolution/provider options. Unsupported generic options such as custom FPS,
seed, or multiple videos in one provider call produce warnings or validation
errors rather than being silently sent.

The provider downloads returned URLs through the common guarded downloader,
normalizes media types, and retains xAI job metadata such as request id,
duration, progress, URL, and cost ticks when present. See [Media](../media.md)
for result ownership and cost-gated live-test policy.

## Exposure status

Native xAI chat is exposed through C ABI v1 and both language wrappers. The C
ABI media surface currently includes image, speech, and transcription, not
video; xAI video is therefore a Zig surface today. Python and Rust provider
constructors can create xAI language handles but do not expose video
generation through ABI v1.

The live integration suite reads `XAI_API_KEY` for provider smoke coverage,
while image/video generation itself remains cost-gated and uses canned wire
fixtures by default. This keeps ordinary CI deterministic and avoids
accidental paid generation.

