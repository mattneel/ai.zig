const std = @import("std");
const wire = @import("wire.zig");
const wire_test_support = @import("wire_test_support.zig");
const shared = @import("shared.zig");
const language = @import("language_model.zig");
const errors = @import("errors.zig");

const roundTrip = wire_test_support.roundTrip;
const roundTripWithOptions = wire_test_support.roundTripWithOptions;

test "wire StreamPart text-start" {
    try roundTrip(language.StreamPart,
        \\{"type":"text-start","id":"text-1","providerMetadata":{"test":{"a":1}}}
    );
}

test "wire StreamPart text-delta" {
    try roundTrip(language.StreamPart,
        \\{"type":"text-delta","id":"text-1","delta":"hello"}
    );
}

test "wire StreamPart text-end" {
    try roundTrip(language.StreamPart,
        \\{"type":"text-end","id":"text-1"}
    );
}

test "wire StreamPart reasoning-start" {
    try roundTrip(language.StreamPart,
        \\{"type":"reasoning-start","id":"reasoning-1"}
    );
}

test "wire StreamPart reasoning-delta" {
    try roundTrip(language.StreamPart,
        \\{"type":"reasoning-delta","id":"reasoning-1","delta":"thinking"}
    );
}

test "wire StreamPart reasoning-end" {
    try roundTrip(language.StreamPart,
        \\{"type":"reasoning-end","id":"reasoning-1"}
    );
}

test "wire StreamPart tool-input-start" {
    try roundTrip(language.StreamPart,
        \\{"type":"tool-input-start","id":"call-1","toolName":"weather","providerExecuted":true,"dynamic":true,"title":"Weather"}
    );
}

test "wire StreamPart tool-input-delta" {
    try roundTrip(language.StreamPart,
        \\{"type":"tool-input-delta","id":"call-1","delta":"{\"city\":"}
    );
}

test "wire StreamPart tool-input-end" {
    try roundTrip(language.StreamPart,
        \\{"type":"tool-input-end","id":"call-1"}
    );
}

test "wire StreamPart tool-approval-request" {
    try roundTrip(language.StreamPart,
        \\{"type":"tool-approval-request","approvalId":"approval-1","toolCallId":"call-1"}
    );
}

test "wire StreamPart tool-call string input" {
    try roundTrip(language.StreamPart,
        \\{"type":"tool-call","toolCallId":"call-1","toolName":"weather","input":"{\"city\":\"Paris\"}","providerExecuted":false,"dynamic":true}
    );
}

test "wire StreamPart tool-result" {
    try roundTrip(language.StreamPart,
        \\{"type":"tool-result","toolCallId":"call-1","toolName":"weather","result":{"temperature":21},"isError":false,"preliminary":true,"dynamic":true}
    );
}

test "wire StreamPart custom" {
    try roundTrip(language.StreamPart,
        \\{"type":"custom","kind":"anthropic.redacted-thinking","providerMetadata":{"anthropic":{"signature":"abc"}}}
    );
}

test "wire StreamPart file" {
    try roundTrip(language.StreamPart,
        \\{"type":"file","mediaType":"image/png","data":{"type":"data","data":"aGVsbG8="}}
    );
}

test "wire StreamPart reasoning-file" {
    try roundTrip(language.StreamPart,
        \\{"type":"reasoning-file","mediaType":"image/png","data":{"type":"url","url":"https://example.com/reason.png"}}
    );
}

test "wire StreamPart source url" {
    try roundTrip(language.StreamPart,
        \\{"type":"source","sourceType":"url","id":"source-1","url":"https://example.com","title":"Example"}
    );
}

test "wire StreamPart source document" {
    try roundTrip(language.StreamPart,
        \\{"type":"source","sourceType":"document","id":"source-2","mediaType":"application/pdf","title":"Paper","filename":"paper.pdf"}
    );
}

test "wire StreamPart stream-start" {
    try roundTrip(language.StreamPart,
        \\{"type":"stream-start","warnings":[{"type":"unsupported","feature":"temperature","details":"ignored"}]}
    );
}

// Sourced from gateway-language-model.test.ts timestamp conversion fixture.
test "wire StreamPart response-metadata" {
    try roundTrip(language.StreamPart,
        \\{"type":"response-metadata","id":"test-id","timestamp":"2023-12-07T10:30:00.000Z","modelId":"test-model"}
    );
}

test "wire StreamPart finish" {
    try roundTrip(language.StreamPart,
        \\{"type":"finish","usage":{"inputTokens":{"total":10,"noCache":8,"cacheRead":2,"cacheWrite":1},"outputTokens":{"total":5,"text":4,"reasoning":1},"raw":{"vendor":15}},"finishReason":{"unified":"tool-calls","raw":"tool_use"}}
    );
}

// Sourced from gateway-language-model.test.ts raw-chunk fixture.
test "wire StreamPart raw" {
    try roundTrip(language.StreamPart,
        \\{"type":"raw","rawValue":{"id":"test-chunk","choices":[{"delta":{"content":"Hello"}}]}}
    );
}

test "wire StreamPart error" {
    try roundTrip(language.StreamPart,
        \\{"type":"error","error":{"message":"provider failed","retryable":false}}
    );
}

test "wire Content text" {
    try roundTrip(language.Content,
        \\{"type":"text","text":"hello","providerMetadata":{"openai":{"id":"x"}}}
    );
}

test "wire Content reasoning" {
    try roundTrip(language.Content,
        \\{"type":"reasoning","text":"because"}
    );
}

test "wire Content custom" {
    try roundTrip(language.Content,
        \\{"type":"custom","kind":"provider.block"}
    );
}

test "wire Content reasoning-file" {
    try roundTripWithOptions(language.Content,
        \\{"type":"reasoning-file","mediaType":"image/png","data":{"type":"data","data":[1,2,3]}}
    , .{ .normalizes_binary = true });
}

test "wire Content file" {
    try roundTrip(language.Content,
        \\{"type":"file","mediaType":"audio/wav","data":{"type":"url","url":"https://example.com/audio.wav"}}
    );
}

test "wire Content tool-approval-request" {
    try roundTrip(language.Content,
        \\{"type":"tool-approval-request","approvalId":"approval-2","toolCallId":"call-2"}
    );
}

test "wire Content source url" {
    try roundTrip(language.Content,
        \\{"type":"source","sourceType":"url","id":"s1","url":"https://ziglang.org"}
    );
}

test "wire Content source document" {
    try roundTrip(language.Content,
        \\{"type":"source","sourceType":"document","id":"s2","mediaType":"text/plain","title":"Notes"}
    );
}

test "wire Content tool-call string input" {
    try roundTrip(language.Content,
        \\{"type":"tool-call","toolCallId":"call-3","toolName":"lookup","input":"{}"}
    );
}

test "wire Content tool-result" {
    try roundTrip(language.Content,
        \\{"type":"tool-result","toolCallId":"call-3","toolName":"lookup","result":[1,true,"ok"]}
    );
}

test "wire Message system role" {
    try roundTrip(language.Message,
        \\{"role":"system","content":"You are concise.","providerOptions":{"openai":{"store":false}}}
    );
}

test "wire Message user role exercises all user parts" {
    try roundTrip(language.Message,
        \\{"role":"user","content":[{"type":"text","text":"describe"},{"type":"file","filename":"image.png","data":{"type":"url","url":"https://example.com/image.png"},"mediaType":"image/png"}]}
    );
}

test "wire Message assistant role exercises all assistant parts" {
    try roundTrip(language.Message,
        \\{"role":"assistant","content":[{"type":"text","text":"answer"},{"type":"file","data":{"type":"text","text":"inline"},"mediaType":"text/plain"},{"type":"custom","kind":"provider.hidden"},{"type":"reasoning","text":"thought"},{"type":"reasoning-file","data":{"type":"data","data":"AA=="},"mediaType":"image/png"},{"type":"tool-call","toolCallId":"c1","toolName":"lookup","input":{"q":"zig"},"providerExecuted":true},{"type":"tool-result","toolCallId":"c1","toolName":"lookup","output":{"type":"text","value":"done"}}]}
    );
}

test "wire Message tool role exercises all tool parts" {
    try roundTrip(language.Message,
        \\{"role":"tool","content":[{"type":"tool-result","toolCallId":"c1","toolName":"lookup","output":{"type":"json","value":{"ok":true}}},{"type":"tool-approval-response","approvalId":"a1","approved":false,"reason":"unsafe"}]}
    );
}

test "wire ToolResultOutput text" {
    try roundTrip(language.ToolResultOutput,
        \\{"type":"text","value":"ok","providerOptions":{"p":{"x":1}}}
    );
}

test "wire ToolResultOutput json" {
    try roundTrip(language.ToolResultOutput,
        \\{"type":"json","value":{"ok":true}}
    );
}

test "wire ToolResultOutput execution-denied" {
    try roundTrip(language.ToolResultOutput,
        \\{"type":"execution-denied","reason":"user denied"}
    );
}

test "wire ToolResultOutput error-text" {
    try roundTrip(language.ToolResultOutput,
        \\{"type":"error-text","value":"failed"}
    );
}

test "wire ToolResultOutput error-json" {
    try roundTrip(language.ToolResultOutput,
        \\{"type":"error-json","value":{"code":500}}
    );
}

test "wire ToolResultOutput content with every nested part" {
    try roundTrip(language.ToolResultOutput,
        \\{"type":"content","value":[{"type":"text","text":"caption"},{"type":"file","data":{"type":"reference","reference":{"openai":"file-1"}},"mediaType":"application/pdf","filename":"a.pdf"},{"type":"custom","providerOptions":{"p":{"opaque":[1,2]}}}]}
    );
}

test "wire FileData data base64" {
    try roundTrip(shared.FileData,
        \\{"type":"data","data":"AQID"}
    );
}

// Gateway language/image/video models base64-normalize Uint8Array inputs.
test "wire FileData bytes serialize as canonical base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"type":"data","data":[1,2,3]}
    , .{});
    const value = try wire.parse(shared.FileData, allocator, json);
    const canonical = try wire.stringifyAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("{\"type\":\"data\",\"data\":\"AQID\"}", canonical);
}

test "wire FileData url" {
    try roundTrip(shared.FileData,
        \\{"type":"url","url":"https://example.com/file"}
    );
}

test "wire FileData reference" {
    try roundTrip(shared.FileData,
        \\{"type":"reference","reference":{"openai":"file-a","anthropic":"file-b"}}
    );
}

test "wire FileData text" {
    try roundTrip(shared.FileData,
        \\{"type":"text","text":"inline document"}
    );
}

test "wire Warning unsupported" {
    try roundTrip(shared.Warning,
        \\{"type":"unsupported","feature":"seed","details":"ignored"}
    );
}

test "wire Warning compatibility" {
    try roundTrip(shared.Warning,
        \\{"type":"compatibility","feature":"tools"}
    );
}

test "wire Warning deprecated" {
    try roundTrip(shared.Warning,
        \\{"type":"deprecated","setting":"maxTokens","message":"use maxOutputTokens"}
    );
}

test "wire Warning other" {
    try roundTrip(shared.Warning,
        \\{"type":"other","message":"provider note"}
    );
}

test "wire ToolChoice auto" {
    try roundTrip(language.ToolChoice, "{\"type\":\"auto\"}");
}

test "wire ToolChoice none" {
    try roundTrip(language.ToolChoice, "{\"type\":\"none\"}");
}

test "wire ToolChoice required" {
    try roundTrip(language.ToolChoice, "{\"type\":\"required\"}");
}

test "wire ToolChoice named tool" {
    try roundTrip(language.ToolChoice, "{\"type\":\"tool\",\"toolName\":\"weather\"}");
}

test "wire ResponseFormat text" {
    try roundTrip(language.ResponseFormat, "{\"type\":\"text\"}");
}

test "wire ResponseFormat json" {
    try roundTrip(language.ResponseFormat,
        \\{"type":"json","schema":{"type":"object","properties":{"answer":{"type":"string"}}},"name":"answer","description":"An answer"}
    );
}

test "wire ReasoningEffort provider-default" {
    try roundTrip(language.ReasoningEffort, "\"provider-default\"");
}

test "wire ReasoningEffort none" {
    try roundTrip(language.ReasoningEffort, "\"none\"");
}

test "wire ReasoningEffort minimal" {
    try roundTrip(language.ReasoningEffort, "\"minimal\"");
}

test "wire ReasoningEffort low" {
    try roundTrip(language.ReasoningEffort, "\"low\"");
}

test "wire ReasoningEffort medium" {
    try roundTrip(language.ReasoningEffort, "\"medium\"");
}

test "wire ReasoningEffort high" {
    try roundTrip(language.ReasoningEffort, "\"high\"");
}

test "wire ReasoningEffort xhigh" {
    try roundTrip(language.ReasoningEffort, "\"xhigh\"");
}

// Gateway language-model tests establish this request body is passed through.
test "wire CallOptions full request fixture" {
    try roundTrip(language.CallOptions,
        \\{"prompt":[{"role":"user","content":[{"type":"text","text":"Hello"}]}],"maxOutputTokens":128,"temperature":0.2,"stopSequences":["STOP"],"topP":0.9,"topK":40,"presencePenalty":0.1,"frequencyPenalty":0.2,"responseFormat":{"type":"json","schema":{"type":"object"}},"seed":42,"tools":[{"type":"function","name":"weather","description":"Get weather","inputSchema":{"type":"object"},"inputExamples":[{"input":{"city":"Paris"}}],"strict":true,"providerOptions":{"openai":{"x":1}}},{"type":"provider","id":"openai.web_search","name":"search","args":{"depth":2}}],"toolChoice":{"type":"tool","toolName":"weather"},"includeRawChunks":true,"headers":{"x-test":"yes"},"reasoning":"high","providerOptions":{"gateway":{"order":["openai","anthropic"]}}}
    );
}

test "wire GenerateResult full response fixture" {
    try roundTrip(language.GenerateResult,
        \\{"content":[{"type":"text","text":"Hello"}],"finishReason":{"unified":"stop","raw":"end_turn"},"usage":{"inputTokens":{"total":4},"outputTokens":{"total":2,"text":2}},"providerMetadata":{"anthropic":{"cache":{"read":1}}},"request":{"body":{"model":"test"}},"response":{"id":"r1","timestamp":"2025-03-05T12:34:56.789Z","modelId":"model-1","headers":{"x-request-id":"abc"},"body":{"ok":true}},"warnings":[]}
    );
}

test "wire providerOptions and providerMetadata remain opaque and ordered" {
    const fixture =
        \\{"content":[{"type":"text","text":"x","providerMetadata":{"vendor":{"nested":[1.0,{"flag":true},null],"large":9007199254740993}}}],"finishReason":{"unified":"stop"},"usage":{"inputTokens":{},"outputTokens":{}},"providerMetadata":{"z":{"b":2,"a":1}},"warnings":[]}
    ;
    try roundTrip(language.GenerateResult, fixture);
}

test "wire unknown object fields are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const part = try wire.parseStreamPart(arena.allocator(),
        \\{"type":"text-delta","id":"t1","delta":"x","futureField":{"ignored":true}}
    );
    const canonical = try wire.stringifyAlloc(std.testing.allocator, part);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("{\"type\":\"text-delta\",\"id\":\"t1\",\"delta\":\"x\"}", canonical);
}

test "wire null optionals are treated as absent and omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const part = try wire.parseStreamPart(arena.allocator(),
        \\{"type":"response-metadata","id":null,"timestamp":null,"modelId":null}
    );
    const canonical = try wire.stringifyAlloc(std.testing.allocator, part);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("{\"type\":\"response-metadata\"}", canonical);
}

test "wire unknown StreamPart tag reports InvalidStreamPart diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = errors.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.InvalidStreamPartError,
        wire.parseStreamPartWithDiagnostics(
            arena.allocator(),
            \\{"type":"future-part","value":1}
        ,
            &diagnostics,
        ),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings(
        "unknown language model stream part type",
        diagnostics.payload.invalid_stream_part.message,
    );
}

test "wire missing required field reports validation field diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = errors.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.TypeValidationError,
        wire.parseStreamPartWithDiagnostics(
            arena.allocator(),
            \\{"type":"text-delta","delta":"missing id"}
        ,
            &diagnostics,
        ),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings("id", diagnostics.payload.type_validation.context.?.field.?);
}

test "wire later invalid field reports its own validation diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = errors.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.TypeValidationError,
        wire.parseStreamPartWithDiagnostics(
            arena.allocator(),
            \\{"type":"text-delta","id":"text-1","delta":42}
        ,
            &diagnostics,
        ),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings("delta", diagnostics.payload.type_validation.context.?.field.?);
}

test "wire invalid finish usage reports usage validation diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = errors.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(
        error.TypeValidationError,
        wire.parseStreamPartWithDiagnostics(
            arena.allocator(),
            \\{"type":"finish","usage":"invalid","finishReason":{"unified":"stop"}}
        ,
            &diagnostics,
        ),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings("usage", diagnostics.payload.type_validation.context.?.field.?);
}

test "wire parsed slices are arena-owned rather than borrowed from JSON text" {
    var source = "{\"type\":\"text-delta\",\"id\":\"t1\",\"delta\":\"hello\"}".*;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const part = try wire.parseStreamPart(arena.allocator(), &source);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("t1", part.text_delta.id);
    try std.testing.expectEqualStrings("hello", part.text_delta.delta);
}

test "wire provider references require string-valued objects without type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bad_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"type":"reference","reference":{"openai":42}}
    , .{});
    try std.testing.expectError(
        error.TypeValidationError,
        wire.parse(shared.FileData, allocator, bad_value),
    );
}

test "wire generated tool result rejects JSON null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bad_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"type":"tool-result","toolCallId":"c1","toolName":"x","result":null}
    , .{});
    try std.testing.expectError(
        error.TypeValidationError,
        wire.parse(language.Content, allocator, bad_value),
    );
}
