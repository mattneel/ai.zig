# Text Generation & Streaming

There are two useful layers: provider calls expose the exact model contract,
while `ai.generateText` and `ai.streamText` add prompt conversion, retries,
tools, multi-step orchestration, callbacks, telemetry, timeouts, and result
aggregation.

## Provider-level calls

`provider.LanguageModel` is a fat-pointer interface. `doGenerate` returns a
single `GenerateResult`; `doStream` returns request/response metadata plus a
pull-based `PartStream`:

```zig
var request_arena_state = std.heap.ArenaAllocator.init(gpa);
defer request_arena_state.deinit();
const arena = request_arena_state.allocator();

const messages = [_]provider.Message{.{ .user = .{
    .content = &.{.{ .text = .{ .text = "Hello" } }},
} }};
const options: provider.CallOptions = .{ .prompt = &messages };

const streamed = try model.doStream(io, arena, &options, null);
defer streamed.stream.deinit(io);
while (try streamed.stream.next(io)) |part| {
    switch (part) {
        .text_delta => |delta| std.debug.print("{s}", .{delta.delta}),
        .finish => |finish| std.debug.print("\n[{t}]\n", .{
            finish.finish_reason.unified,
        }),
        else => {},
    }
}
```

Each provider stream part and its nested slices remain valid only until the
next `next()` call or stream teardown. Copy a value into longer-lived storage
before advancing.

The provider `StreamPart` union has 21 outer tags:

`text_start`, `text_delta`, `text_end`, `reasoning_start`,
`reasoning_delta`, `reasoning_end`, `tool_input_start`,
`tool_input_delta`, `tool_input_end`, `tool_approval_request`, `tool_call`,
`tool_result`, `custom`, `file`, `reasoning_file`, `source`, `stream_start`,
`response_metadata`, `finish`, `raw`, and `err`.

## Core orchestration

`ai.generateText` owns its result arena. The final result exposes text,
reasoning, content, files, sources, tool calls/results, response messages,
warnings, per-step model metadata and performance, final finish reason, and
total usage. Add `stop_when = &.{ai.stepCount(n)}` when tools should be able to
continue across model steps.

`ai.streamText` uses the same call settings but emits the orchestration-level
`TextStreamPart` vocabulary. This union includes provider content and the
step/tool lifecycle added by the core. Its complete 26-tag list is:

`text_start`, `text_end`, `text_delta`, `reasoning_start`, `reasoning_end`,
`reasoning_delta`, `custom`, `tool_input_start`, `tool_input_end`,
`tool_input_delta`, `source`, `file`, `reasoning_file`, `tool_call`,
`tool_result`, `tool_error`, `tool_output_denied`, `tool_approval_request`,
`tool_approval_response`, `start_step`, `finish_step`, `start`, `finish`,
`abort`, `err`, and `raw`.

```zig
var stream = try ai.streamText(io, gpa, .{
    .model = .{ .model = model },
    .prompt = .{ .text = "Write a haiku about comptime." },
});
defer stream.deinit(io);

while (try stream.next(io)) |part| switch (part) {
    .text_delta => |delta| std.debug.print("{s}", .{delta.text}),
    .finish_step => |step| std.debug.print("\nstep: {t}\n", .{
        step.finish_reason.unified,
    }),
    .finish => |finish| std.debug.print("total output tokens: {?d}\n", .{
        finish.total_usage.output_tokens.total,
    }),
    .abort => |abort| std.log.warn("aborted: {?s}", .{abort.reason}),
    .err => |stream_error| std.log.err("stream error: {any}", .{
        stream_error.error_value,
    }),
    else => {},
};
```

The main cursor drives the pipeline. `fullStream()`, `textStream()`, partial
output, and element cursors replay a mutex-protected broadcast log. Promise-like
accessors such as `text(io)`, `steps(io)`, and `totalUsage(io)` drain the
remaining stream before returning. Retention is intentionally unbounded for
the result lifetime, matching upstream tee semantics.

## Finish reasons and usage

`provider.FinishReason` preserves two views: `unified` is one of `stop`,
`length`, `content_filter`, `tool_calls`, `error`, or `other`; `raw` keeps the
provider-specific value when available.

`provider.Usage` separates input totals into no-cache, cache-read, and
cache-write tokens, and output totals into text and reasoning tokens. All
counts are optional because providers do not always report each dimension.
`finish_step.usage` describes one model call; final `finish.total_usage`
aggregates the multi-step operation.

Transforms, `on_chunk`, error/abort callbacks, raw chunks, and granular
total/step/chunk/tool timeouts are configured on `StreamTextOptions`. Awaited
chunk callbacks pause the pull pipeline and therefore backpressure the
provider connection.

Tool-specific ordering and cancellation limits are covered in
[Tools & Tool Loops](tools.md) and the
[Behavioral Contracts](appendix/contracts.md#streaming-broadcast-log-and-cursors).

