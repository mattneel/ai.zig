const wire_test_support = @import("wire_test_support.zig");
const realtime = @import("realtime_model.zig");
const transcription = @import("transcription_model.zig");

const roundTrip = wire_test_support.roundTrip;

test "wire ClientEvent session-update" {
    try roundTrip(realtime.ClientEvent,
        \\{"type":"session-update","config":{"instructions":"Be helpful","voice":"alloy","outputModalities":["text","audio"],"inputAudioFormat":{"type":"audio/pcm","rate":24000},"inputAudioTranscription":{"model":"whisper-1","language":"en"},"outputAudioTranscription":{"prompt":"verbatim"},"outputAudioFormat":{"type":"audio/pcm","rate":24000},"turnDetection":{"type":"server-vad","threshold":0.5,"silenceDurationMs":500,"prefixPaddingMs":300},"tools":[{"type":"function","name":"weather","description":"Weather","parameters":{"type":"object"}}],"providerOptions":{"openai":{"temperature":0.8}}}}
    );
}

test "wire ClientEvent input-audio-append" {
    try roundTrip(realtime.ClientEvent,
        \\{"type":"input-audio-append","audio":"AQID"}
    );
}

test "wire ClientEvent input-audio-commit" {
    try roundTrip(realtime.ClientEvent, "{\"type\":\"input-audio-commit\"}");
}

test "wire ClientEvent input-audio-clear" {
    try roundTrip(realtime.ClientEvent, "{\"type\":\"input-audio-clear\"}");
}

test "wire ClientEvent conversation-item-create" {
    try roundTrip(realtime.ClientEvent,
        \\{"type":"conversation-item-create","item":{"type":"text-message","role":"user","text":"hello"}}
    );
}

test "wire ClientEvent conversation-item-truncate" {
    try roundTrip(realtime.ClientEvent,
        \\{"type":"conversation-item-truncate","itemId":"item-1","contentIndex":0,"audioEndMs":1250}
    );
}

test "wire ClientEvent response-create" {
    try roundTrip(realtime.ClientEvent,
        \\{"type":"response-create","options":{"modalities":["audio"],"instructions":"Answer","metadata":{"requestId":"r1"}}}
    );
}

test "wire ClientEvent response-cancel" {
    try roundTrip(realtime.ClientEvent, "{\"type\":\"response-cancel\"}");
}

test "wire ConversationItem text-message" {
    try roundTrip(realtime.ConversationItem,
        \\{"type":"text-message","role":"user","text":"hello"}
    );
}

test "wire ConversationItem audio-message" {
    try roundTrip(realtime.ConversationItem,
        \\{"type":"audio-message","role":"user","audio":"AAEC"}
    );
}

test "wire ConversationItem function-call-output" {
    try roundTrip(realtime.ConversationItem,
        \\{"type":"function-call-output","callId":"call-1","name":"weather","output":"{\"temperature\":21}"}
    );
}

test "wire ServerEvent session-created" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"session-created","sessionId":"session-1","raw":{"type":"session.created"}}
    );
}

test "wire ServerEvent session-updated" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"session-updated","raw":{"type":"session.updated"}}
    );
}

test "wire ServerEvent speech-started" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"speech-started","itemId":"item-1","raw":{"type":"input_audio_buffer.speech_started"}}
    );
}

test "wire ServerEvent speech-stopped" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"speech-stopped","itemId":"item-1","raw":{"type":"input_audio_buffer.speech_stopped"}}
    );
}

test "wire ServerEvent audio-committed" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"audio-committed","itemId":"item-2","previousItemId":"item-1","raw":{}}
    );
}

test "wire ServerEvent conversation-item-added" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"conversation-item-added","itemId":"item-2","item":{"role":"assistant"},"raw":{}}
    );
}

test "wire ServerEvent input-transcription-completed" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"input-transcription-completed","itemId":"item-2","transcript":"hello","raw":{}}
    );
}

test "wire ServerEvent response-created" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"response-created","responseId":"response-1","raw":{}}
    );
}

test "wire ServerEvent response-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"response-done","responseId":"response-1","status":"completed","raw":{}}
    );
}

test "wire ServerEvent output-item-added" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"output-item-added","responseId":"response-1","itemId":"item-3","raw":{}}
    );
}

test "wire ServerEvent output-item-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"output-item-done","responseId":"response-1","itemId":"item-3","raw":{}}
    );
}

test "wire ServerEvent content-part-added" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"content-part-added","responseId":"response-1","itemId":"item-3","raw":{}}
    );
}

test "wire ServerEvent content-part-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"content-part-done","responseId":"response-1","itemId":"item-3","raw":{}}
    );
}

test "wire ServerEvent audio-delta" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"audio-delta","responseId":"response-1","itemId":"item-3","delta":"AQID","raw":{}}
    );
}

test "wire ServerEvent audio-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"audio-done","responseId":"response-1","itemId":"item-3","raw":{}}
    );
}

test "wire ServerEvent audio-transcript-delta" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"audio-transcript-delta","responseId":"response-1","itemId":"item-3","delta":"hel","raw":{}}
    );
}

test "wire ServerEvent audio-transcript-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"audio-transcript-done","responseId":"response-1","itemId":"item-3","transcript":"hello","raw":{}}
    );
}

test "wire ServerEvent text-delta" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"text-delta","responseId":"response-1","itemId":"item-3","delta":"hello","raw":{}}
    );
}

test "wire ServerEvent text-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"text-done","responseId":"response-1","itemId":"item-3","text":"hello","raw":{}}
    );
}

test "wire ServerEvent function-call-arguments-delta" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"function-call-arguments-delta","responseId":"response-1","itemId":"item-3","callId":"call-1","delta":"{\"city\":" ,"raw":{}}
    );
}

test "wire ServerEvent function-call-arguments-done" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"function-call-arguments-done","responseId":"response-1","itemId":"item-3","callId":"call-1","name":"weather","arguments":"{\"city\":\"Paris\"}","raw":{}}
    );
}

test "wire ServerEvent error" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"error","message":"bad request","code":"invalid_request","raw":{}}
    );
}

test "wire ServerEvent custom" {
    try roundTrip(realtime.ServerEvent,
        \\{"type":"custom","rawType":"vendor.event","raw":{"type":"vendor.event","data":1}}
    );
}

test "wire TranscriptionStreamPart stream-start" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"stream-start","warnings":[]}
    );
}

test "wire TranscriptionStreamPart transcript-delta" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"transcript-delta","id":"segment-1","delta":"hel","providerMetadata":{"deepgram":{"channel":0}}}
    );
}

test "wire TranscriptionStreamPart transcript-partial" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"transcript-partial","id":"segment-1","text":"hello wor","startSecond":0.5,"durationInSeconds":1.25,"channelIndex":0}
    );
}

test "wire TranscriptionStreamPart transcript-final" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"transcript-final","id":"segment-1","text":"hello world","startSecond":0.5,"endSecond":1.75,"channelIndex":0}
    );
}

test "wire TranscriptionStreamPart response-metadata" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"response-metadata","timestamp":"2025-03-05T12:34:56.000Z","modelId":"whisper-1","headers":{"x-id":"abc"},"body":{"request":"ok"}}
    );
}

test "wire TranscriptionStreamPart finish" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"finish","text":"hello world","segments":[{"text":"hello world","startSecond":0,"endSecond":1.5}],"language":"en","durationInSeconds":1.5,"providerMetadata":{"openai":{"id":"t1"}}}
    );
}

test "wire TranscriptionStreamPart raw" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"raw","rawValue":{"vendor":"chunk"}}
    );
}

test "wire TranscriptionStreamPart error" {
    try roundTrip(transcription.StreamPart,
        \\{"type":"error","error":{"message":"audio corrupt"}}
    );
}
