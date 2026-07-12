# Telemetry & OpenTelemetry

The core telemetry system is a borrowed vtable integration point. The `otel`
module is one concrete implementation that turns core lifecycle events into
OpenTelemetry `gen_ai` spans and exports OTLP/HTTP JSON without pulling in a
third-party OTel SDK.

## Telemetry vtable

`ai.Telemetry.VTable` has optional callbacks for:

- generate start, step start/end, model-call start/end, tool start/end,
  operation end, abort, and error;
- structured-object operation and step start/end;
- embedding and reranking start/end;
- paired enter/exit hooks around model calls and tool execution.

Callbacks receive stable event structs plus `Meta`: `record_inputs`,
`record_outputs`, and an optional `function_id`. Event callback errors are
swallowed so observability cannot fail the model operation. Integrations are
dispatched concurrently and awaited; enter hooks preserve registration order
and exit in reverse order.

`TelemetryOptions.enabled = false` disables dispatch. A non-null local
`integrations` slice, including an empty slice, replaces the global registry
for that call. Otherwise the dispatcher snapshots globally registered
borrowed handles.

## Registration lifetime

```zig
try ai.registerTelemetry(gpa, &.{integration});
defer ai.clearTelemetryRegistry();
```

The registry owns only its handle array. Integration vtables and contexts must
remain valid until `clearTelemetryRegistry`. Clear is process-global and must
run only after operations holding copied dispatchers have quiesced.

## OTLP/HTTP JSON exporter

```zig
var exporter = try otel.Exporter.init(gpa, io, .{
    .endpoint = "http://localhost:4318/v1/traces",
    .service_name = "my-ai-service",
    .max_batch_size = 64,
});
var registration = try otel.register(&exporter);

// Run generateText, generateObject, embed, or rerank operations here.

try registration.deinit(); // flush the borrowed registration
ai.clearTelemetryRegistry();
try exporter.deinit();
```

`otel.Config` also accepts request headers and an injected HTTP transport.
The exporter emits protobuf-JSON-shaped `resourceSpans/scopeSpans/spans` to
the configured endpoint. IDs are cryptographically random. There is no timer
or background export thread in v1: call `flush`, let the batch-size threshold
flush synchronously, or rely on `deinit` to attempt a final flush.

Failed exports leave the batch intact for a later retry. `deinit` releases all
state even when the final flush fails and returns the flush error afterward.
No telemetry callbacks or hook scopes may still be active during exporter
destruction.

## Span model

Text/tool loops produce correlated spans such as:

- `invoke_agent <model>` for the root operation;
- `step 1`, `step 2`, and so on;
- `chat <model>` for provider calls;
- `execute_tool <name>` parented to the preceding model call.

Embedding and reranking callback shapes lack an outer operation lifetime, so
their provider-call spans are roots. Object generation uses its stable call id
to correlate operation and model work.

Attributes use the Phase 12 pinned convention: `gen_ai.operation.name`,
`gen_ai.system`, `gen_ai.request.*`, `gen_ai.response.*`,
`gen_ai.usage.*`, `gen_ai.tool.*`, and `gen_ai.execute_tool.duration`.
Instructions and tool arguments are recorded only with `record_inputs`; model
text and tool outputs only with `record_outputs`.

The pinned `gen_ai.system` name deliberately differs from newer upstream
`gen_ai.provider.name` spelling. That choice is an explicit versioned
convention, not an accidental claim that all OTel semantic-convention drafts
are interchangeable.

