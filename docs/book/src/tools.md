# Tools & Tool Loops

Tools are runtime values, not comptime-only declarations. `ai.NamedTool`
pairs the public name used in a tool set with an `ai.tool.Tool`; the tool's
optional `execute` vtable receives validated JSON, the current `std.Io`, an
execution arena, and message/context metadata.

## Define a tool

This shape is adapted from the repository's live Anthropic and OpenAI tool
loop tests:

```zig
const Weather = struct {
    fn execute(
        _: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        const city = input.object.get("city").?.string;
        var output: std.json.ObjectMap = .empty;
        try output.put(arena, "city", .{ .string = city });
        try output.put(arena, "condition", .{ .string = "sunny" });
        try output.put(arena, "temperatureC", .{ .integer = 21 });
        return .{ .value = .{ .object = output } };
    }
};

const tools = [_]ai.NamedTool{.{
    .name = "weather",
    .tool = .{
        .description = .{ .text = "Get the weather for a city" },
        .input_schema = provider_utils.schemaFromType(struct {
            city: []const u8,
        }),
        .execute = .{ .execute_fn = Weather.execute },
    },
}};
```

`schemaFromType` emits a camel-cased draft-07-style schema and a Zig validator
for booleans, numbers, strings, slices, enums, structs, optionals, and defaults.
Object schemas set `additionalProperties: false`. For unions or a schema
owned elsewhere, use `provider_utils.rawSchema(document_json, validator)`.

A tool can return one JSON `value` or a pull-based `PreliminaryStream`. Every
streamed value except the final one is marked preliminary; preliminary values
appear on the live stream but are excluded from completed step records.
Input-start, input-delta, and input-available callbacks, dynamic descriptions,
output conversion, provider-defined tools, context schemas, and input examples
are represented directly on `ai.tool.Tool`.

## Run multiple model steps

```zig
var result = try ai.generateText(io, gpa, .{
    .model = .{ .model = model },
    .prompt = .{ .text = "What is the weather in Paris?" },
    .tools = &tools,
    .stop_when = &.{ai.stepCount(5)},
});
defer result.deinit();
```

The model call can emit a tool call, ai.zig validates and executes it, the
result is converted into the next prompt, and another model step begins.
Available stop conditions include `stepCount`, `hasToolCall`, and
`loopFinished`; `prepare_step` can replace model/settings/tools between
steps. `active_tools` filters the set without reallocating tool definitions,
and `tool_order` controls provider presentation order.

Approved blocking-call tools execute concurrently in isolated arenas, while
results are assembled in original tool-call order. Streaming keeps incoming
wire order; after `model_call_end`, separate tool outputs interleave in
completion order. A thrown tool error becomes a `tool_error` output and is fed
back to the model rather than canceling sibling tools. Model retries never
retry tool code.

## Complete Anthropic tool loop

A tool-enabled call that can complete in two model steps — the model requests
the tool, ai.zig executes it, and the model incorporates the result:

```zig
const std = @import("std");
const ai = @import("ai");
const anthropic = @import("anthropic");
const provider_utils = @import("provider_utils");

const Weather = struct {
    fn execute(
        _: ?*anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        input: std.json.Value,
        _: ai.tool.ToolExecutionOptions,
    ) anyerror!ai.tool.ToolOutput {
        _ = input; // {"city": "..."} — validated against the schema below
        var output: std.json.ObjectMap = .empty;
        try output.put(arena, "condition", .{ .string = "sunny" });
        try output.put(arena, "temperature", .{ .integer = 21 });
        return .{ .value = .{ .object = output } };
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, api_key: []const u8) !void {
    var transport = provider_utils.HttpClientTransport.init(gpa, io);
    defer transport.deinit();

    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key, // keys are always explicit — nothing reads your env
        .transport = transport.transport(),
    });
    var chat = try factory.messages("claude-haiku-4-5-20251001", null);

    const tools = [_]ai.NamedTool{.{
        .name = "weather",
        .tool = .{
            .description = .{ .text = "Get the weather for a city" },
            .input_schema = provider_utils.schemaFromType(struct { city: []const u8 }),
            .execute = .{ .ctx = null, .execute_fn = Weather.execute },
        },
    }};

    var result = try ai.generateText(io, gpa, .{
        .model = .{ .model = chat.languageModel() },
        .prompt = .{ .text = "What is the weather in Paris?" },
        .tools = &tools,
        .stop_when = &.{ai.stepCount(5)},
    });
    defer result.deinit();

    std.debug.print("{s}\n", .{result.text()});
    // The result also exposes steps, usage, messages, and resolved model metadata.
}
```

## Approvals

Approval is implemented for function tools. `needs_approval` can be `.no`,
`.yes`, or a resolver that decides from validated input and execution context.
A blocked call emits a `tool_approval_request` and is not executed. The
application supplies a corresponding approval response in the next prompt;
approved calls are replayed before step zero, while denial becomes an
`execution-denied` tool result with the optional reason.

Set `tool_approval_secret` to sign requests with HMAC-SHA256. The signature
binds approval id, tool-call id, tool name, and a digest of canonical JSON
input. Omitting a secret preserves the upstream unsigned flow. The current
signature intentionally does not bind a user, run, model, expiry, or nonce;
do not treat it as a cross-system bearer token. The normative limitations are
in [Behavioral Contracts](appendix/contracts.md#tool-approval-signatures).

Approval parts are available in both blocking result content and streaming
parts, and the UI-message reducer carries the approval lifecycle. Realtime
tool calls use a separate all-outputs-ready gate described in
[Realtime & WebSocket](realtime.md#tool-gating-and-barge-in).
