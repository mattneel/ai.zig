const std = @import("std");
const wire = @import("wire.zig");
const wire_test_support = @import("wire_test_support.zig");
const shared = @import("shared.zig");
const language = @import("language_model.zig");
const embedding = @import("embedding_model.zig");
const image = @import("image_model.zig");
const speech = @import("speech_model.zig");
const transcription = @import("transcription_model.zig");
const reranking = @import("reranking_model.zig");
const video = @import("video_model.zig");
const files = @import("files.zig");
const skills = @import("skills.zig");
const realtime = @import("realtime_model.zig");
const errors = @import("errors.zig");

const roundTrip = wire_test_support.roundTrip;
const roundTripWithOptions = wire_test_support.roundTripWithOptions;

test "wire Tool function" {
    try roundTrip(language.Tool,
        \\{"type":"function","name":"sum","description":"Add","inputSchema":{"type":"object"},"inputExamples":[{"input":{"a":1,"b":2}}],"strict":true}
    );
}

test "wire Tool provider" {
    try roundTrip(language.Tool,
        \\{"type":"provider","id":"openai.web_search","name":"search","args":{"depth":2}}
    );
}

test "wire GeneratedFileData data" {
    try roundTripWithOptions(shared.GeneratedFileData,
        \\{"type":"data","data":[0,127,255]}
    , .{ .normalizes_binary = true });
}

test "wire GeneratedFileData url" {
    try roundTrip(shared.GeneratedFileData,
        \\{"type":"url","url":"https://example.com/generated.png"}
    );
}

test "wire UploadFileData data" {
    try roundTrip(shared.UploadFileData,
        \\{"type":"data","data":"AQID"}
    );
}

test "wire UploadFileData text" {
    try roundTrip(shared.UploadFileData,
        \\{"type":"text","text":"skill instructions"}
    );
}

test "wire EmbeddingCallOptions" {
    try roundTrip(embedding.CallOptions,
        \\{"values":["one","two"],"providerOptions":{"openai":{"dimensions":3}},"headers":{"x-id":"abc"}}
    );
}

test "wire EmbeddingResult" {
    try roundTrip(embedding.Result,
        \\{"embeddings":[[0.125,-2.5],[3,4]],"usage":{"tokens":7},"providerMetadata":{"openai":{"requestId":"r1"}},"response":{"headers":{"x-id":"abc"},"body":{"ok":true}},"warnings":[]}
    );
}

test "wire ImageFile file" {
    try roundTripWithOptions(image.ImageFile,
        \\{"type":"file","mediaType":"image/png","data":[1,2,3],"providerOptions":{"openai":{"purpose":"mask"}}}
    , .{ .normalizes_binary = true });
}

test "wire ImageFile url" {
    try roundTrip(image.ImageFile,
        \\{"type":"url","url":"https://example.com/input.png"}
    );
}

test "wire ImageCallOptions" {
    try roundTrip(image.CallOptions,
        \\{"prompt":"a fox","n":2,"size":"1024x768","aspectRatio":"4:3","seed":4,"files":[{"type":"url","url":"https://example.com/input.png"}],"mask":null,"providerOptions":{"openai":{"quality":"hd"}},"headers":{"x-id":"abc"}}
    );
}

test "wire ImageResult" {
    try roundTripWithOptions(image.Result,
        \\{"images":["AQID",[4,5,6]],"warnings":[],"providerMetadata":{"openai":{"images":[{"revisedPrompt":"fox"}]}},"response":{"timestamp":"2025-03-05T12:34:56.789Z","modelId":"image-1","headers":{"x-id":"abc"}},"usage":{"inputTokens":4,"outputTokens":8,"totalTokens":12}}
    , .{ .normalizes_binary = true });
}

test "wire SpeechCallOptions" {
    try roundTrip(speech.CallOptions,
        \\{"text":"hello","voice":"alloy","outputFormat":"mp3","instructions":"slow","speed":0.9,"language":"en","providerOptions":{"openai":{}},"headers":{"x-id":"abc"}}
    );
}

test "wire SpeechResult" {
    try roundTrip(speech.Result,
        \\{"audio":"AQID","warnings":[],"request":{"body":{"text":"hello"}},"response":{"timestamp":"2025-03-05T12:34:56.000Z","modelId":"tts-1","headers":{"x-id":"abc"},"body":{"ok":true}},"providerMetadata":{"openai":{"voice":"alloy"}}}
    );
}

test "wire TranscriptionCallOptions" {
    try roundTripWithOptions(transcription.CallOptions,
        \\{"audio":[1,2,3],"mediaType":"audio/wav","providerOptions":{"openai":{"language":"en"}},"headers":{"x-id":"abc"}}
    , .{ .normalizes_binary = true });
}

test "wire TranscriptionResult" {
    try roundTrip(transcription.Result,
        \\{"text":"hello","segments":[{"text":"hello","startSecond":0,"endSecond":1.5}],"language":"en","durationInSeconds":1.5,"warnings":[],"request":{"body":"multipart"},"response":{"timestamp":"2025-03-05T12:34:56.123Z","modelId":"whisper-1","headers":{"x-id":"abc"},"body":{"ok":true}},"providerMetadata":{"openai":{"id":"t1"}}}
    );
}

test "wire RerankingDocuments text" {
    try roundTrip(reranking.Documents,
        \\{"type":"text","values":["one","two"]}
    );
}

test "wire RerankingDocuments object" {
    try roundTrip(reranking.Documents,
        \\{"type":"object","values":[{"title":"one"},{"title":"two"}]}
    );
}

test "wire RerankingResult" {
    try roundTrip(reranking.Result,
        \\{"ranking":[{"index":1,"relevanceScore":0.9},{"index":0,"relevanceScore":0.2}],"providerMetadata":{"cohere":{"id":"r1"}},"warnings":[{"type":"other","message":"note"}],"response":{"id":"r1","timestamp":"2025-03-05T12:34:56.000Z","modelId":"rerank-1","headers":{"x-id":"abc"},"body":{"ok":true}}}
    );
}

test "wire VideoFile file" {
    try roundTrip(video.VideoFile,
        \\{"type":"file","mediaType":"video/mp4","data":"AQID"}
    );
}

test "wire VideoFile url" {
    try roundTrip(video.VideoFile,
        \\{"type":"url","url":"https://example.com/input.mp4","mediaType":"video/mp4"}
    );
}

test "wire VideoData url" {
    try roundTrip(video.VideoData,
        \\{"type":"url","url":"https://example.com/output.mp4","mediaType":"video/mp4"}
    );
}

test "wire VideoData base64" {
    try roundTrip(video.VideoData,
        \\{"type":"base64","data":"AQID","mediaType":"video/mp4"}
    );
}

test "wire VideoData binary" {
    try roundTripWithOptions(video.VideoData,
        \\{"type":"binary","data":[1,2,255],"mediaType":"video/mp4"}
    , .{ .normalizes_binary = true });
}

test "wire VideoCallOptions" {
    try roundTrip(video.CallOptions,
        \\{"prompt":"ocean","n":1,"aspectRatio":"16:9","resolution":"1280x720","duration":5,"fps":24,"seed":3,"image":{"type":"url","url":"https://example.com/start.png","mediaType":"image/png"},"frameImages":[{"image":{"type":"url","url":"https://example.com/end.png"},"frameType":"last_frame"}],"inputReferences":[],"generateAudio":true,"providerOptions":{"fal":{"loop":false}},"headers":{"x-id":"abc"}}
    );
}

test "wire VideoResult" {
    try roundTripWithOptions(video.Result,
        \\{"videos":[{"type":"url","url":"https://example.com/output.mp4","mediaType":"video/mp4"},{"type":"base64","data":"AQID","mediaType":"video/mp4"},{"type":"binary","data":[1,2,3],"mediaType":"video/mp4"}],"warnings":[],"providerMetadata":{"fal":{"duration":5}},"response":{"timestamp":"2025-03-05T12:34:56.000Z","modelId":"video-1","headers":{"x-id":"abc"}}}
    , .{ .normalizes_binary = true });
}

test "wire Files upload options and result" {
    try roundTrip(files.UploadFileCallOptions,
        \\{"data":{"type":"text","text":"document"},"mediaType":"text/plain","filename":"a.txt","providerOptions":{"openai":{"purpose":"assistants"}}}
    );
    try roundTrip(files.UploadFileResult,
        \\{"providerReference":{"openai":"file-1"},"mediaType":"text/plain","filename":"a.txt","providerMetadata":{"openai":{"bytes":8}},"warnings":[]}
    );
}

test "wire Skills upload options and result" {
    try roundTripWithOptions(skills.UploadSkillCallOptions,
        \\{"files":[{"path":"SKILL.md","data":{"type":"text","text":"instructions"}},{"path":"asset.bin","data":{"type":"data","data":[1,2]}}],"displayTitle":"Example","providerOptions":{"anthropic":{"beta":true}}}
    , .{ .normalizes_binary = true });
    try roundTrip(skills.UploadSkillResult,
        \\{"providerReference":{"anthropic":"skill-1"},"displayTitle":"Example","name":"example","description":"A skill","latestVersion":"v1","providerMetadata":{"anthropic":{"files":2}},"warnings":[]}
    );
}

test "wire Realtime client secret and websocket config" {
    try roundTrip(realtime.ClientSecretOptions,
        \\{"expiresAfterSeconds":60,"sessionConfig":{"instructions":"hello"}}
    );
    try roundTrip(realtime.ClientSecretResult,
        \\{"token":"secret","url":"wss://example.com","expiresAt":1730000000}
    );
    try roundTrip(realtime.WebSocketConfig,
        \\{"url":"wss://example.com","protocols":["realtime","token"]}
    );
}

test "wire top-level CallOptions convenience codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const options = try wire.parseCallOptions(arena.allocator(),
        \\{"prompt":[{"role":"system","content":"hello"}],"reasoning":"provider-default"}
    );
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try wire.writeCallOptions(options, &output.writer);
    try std.testing.expectEqualStrings(
        "{\"prompt\":[{\"role\":\"system\",\"content\":\"hello\"}],\"reasoning\":\"provider-default\"}",
        output.written(),
    );
}

test "wire FinishReasonUnified stop" {
    try roundTrip(errors.FinishReasonUnified, "\"stop\"");
}

test "wire FinishReasonUnified length" {
    try roundTrip(errors.FinishReasonUnified, "\"length\"");
}

test "wire FinishReasonUnified content-filter" {
    try roundTrip(errors.FinishReasonUnified, "\"content-filter\"");
}

test "wire FinishReasonUnified tool-calls" {
    try roundTrip(errors.FinishReasonUnified, "\"tool-calls\"");
}

test "wire FinishReasonUnified error" {
    try roundTrip(errors.FinishReasonUnified, "\"error\"");
}

test "wire FinishReasonUnified other" {
    try roundTrip(errors.FinishReasonUnified, "\"other\"");
}

test "wire Video FrameType values" {
    try roundTrip(video.FrameType, "\"first_frame\"");
    try roundTrip(video.FrameType, "\"last_frame\"");
}

test "wire realtime TurnDetectionType values" {
    try roundTrip(realtime.TurnDetectionType, "\"server-vad\"");
    try roundTrip(realtime.TurnDetectionType, "\"semantic-vad\"");
    try roundTrip(realtime.TurnDetectionType, "\"disabled\"");
}
