# Agents

`ai.ToolLoopAgent` packages stable model, tool, prompt, retry, timeout,
output, telemetry, and callback settings for repeated calls. It does not own
a second generation engine: it prepares a call and delegates to the same
live-validated `generateText` and `streamText` paths.

## Lifecycle

1. Construct a model and any `NamedTool` values whose storage outlives the
   agent and its active streams.
2. Initialize `ToolLoopAgentSettings`.
3. Call `generate` for an owned blocking result or `stream` for an owned
   `StreamTextResult`.
4. Deinitialize each result; the Zig agent itself is a small value and owns no
   heap allocation requiring a destructor.

The default stop condition is `stepCount(20)`. Supplying an explicit empty
`stop_when` slice preserves bare `generateText`'s single-step behavior. Agent
requests add the `ai-sdk-zig-agent/tool-loop` user-agent suffix.

## A reusable weather agent

```zig
var weather_state: WeatherState = .{};
const tools = weatherTools(&weather_state);

var agent = ai.ToolLoopAgent.init(.{
    .model = .{ .model = model },
    .id = "weather-agent",
    .instructions = .{
        .text = "Call weather once, then answer in one short sentence.",
    },
    .tools = &tools,
    .max_output_tokens = 200,
});

var result = try agent.generate(io, gpa, .{
    .prompt = .{ .text = "What is the weather in Paris?" },
});
defer result.deinit();
std.debug.print("{s}\n", .{result.text()});
```

`AgentCallParameters` accepts either `prompt` or `messages`, optional
call-specific JSON options, a timeout override, lifecycle callbacks, and
stream transforms. Settings callbacks and call callbacks are merged so both
observe the same operation.

## Preparing calls

`prepare_call` receives fully resolved settings without lifecycle callbacks
and can return a sparse `PrepareCallResult`. An absent field inherits the
base setting. Replacing `prompt` clears inherited `messages`, and replacing
`messages` clears inherited `prompt`, preventing an ambiguous request.

`call_options_schema` validates the per-call `options` JSON before the hook.
The hook can change the model, instructions, tool selection and order, stop
conditions, `prepare_step`, retry count, timeouts, contexts, output strategy,
telemetry, and tool-approval configuration.

## Streaming agents

`agent.stream` returns the same core stream type documented in
[Text Generation & Streaming](text-generation.md). The stream attaches a
cleanup resource that retains the prepared-call arena and merged callback
bundle until `deinit(io)`. It can emit tool calls/results, per-step finishes,
and one final finish across the complete loop.

The type-erased `ai.agent_api.Agent` interface exposes `generate` and `stream`
vtables for UI and embedding layers that should not know the concrete agent
type. The C, Python, and Rust wrappers expose reusable agents too, with
stronger handle ownership rules described in their chapters.

Agent behavior is beta. The C ABI v1 surface is stable at the binary boundary,
but the Zig settings structure and wrapper-level convenience APIs may still
change.

