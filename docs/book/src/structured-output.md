# Structured Output

Structured output is available through the current v7 `Output` strategies on
`generateText`/`streamText` and through the deprecated-but-retained
`generateObject`/`streamObject` compatibility APIs.

## Output strategies

The five strategies are:

| Constructor | Result | Streaming support |
| --- | --- | --- |
| `ai.text()` | text | text deltas |
| `ai.object(schema)` | validated JSON object | partial objects |
| `ai.array(element_schema)` | validated JSON array | partial arrays and element stream |
| `ai.choice(values)` | one exact string choice | unambiguous partial choice |
| `ai.json()` | arbitrary parsed JSON | partial JSON |

`objectWithOptions`, `arrayWithOptions`, `choiceWithOptions`, and
`jsonWithOptions` add a schema name and description. The strategy converts
itself into `provider.ResponseFormat`, parses the final accumulated text, and
optionally validates partial values.

```zig
const Answer = struct {
    city: []const u8,
    temperature_c: i32,
};

var result = try ai.generateText(io, gpa, .{
    .model = .{ .model = model },
    .prompt = .{ .text = "Return Paris weather as JSON." },
    .output = ai.object(provider_utils.schemaFromType(Answer)),
});
defer result.deinit();

const value = (try result.output()).json;
std.debug.print("{any}\n", .{value});
```

For streaming, `partialOutputStream()` repairs accumulated JSON and suppresses
deep-equal duplicates. `elementStream(diag)` exists only for array output and
publishes completed array elements once. The core synthesizes exact array
text deltas, including brackets and commas, from validated partial values.

## Compatibility APIs

`generateObject` performs one model step and supports `object`, `array`,
`enum`, and `no_schema` modes. `generateObjectAs(T, ...)` supplies
`schemaFromType(T)` and parses the final object into `T`. A `repair_text`
callback may rewrite malformed JSON once after a parse or type-validation
failure.

`streamObject` exposes `object`, `text_delta`, `err`, and `finish` parts plus
independent full, partial-object, text, and element cursors. It uses the same
broadcast retention and pull-driver rules as `streamText`.

## Provider schema handling

- **OpenAI Chat** sends `response_format.type = "json_schema"` with schema,
  strict flag, name, and description. Without a schema it uses
  `json_object`.
- **OpenAI Responses** sends the equivalent schema under
  `text.format`, matching the Responses wire shape.
- **Anthropic** uses native `output_config.format.type = "json_schema"` for
  model families marked structured-output capable. Older/unknown families
  fall back to a forced synthetic `json` tool, disable parallel tool use,
  and extract the tool input as the output.
- **Google Generative AI** sets `generationConfig.responseMimeType` to
  `application/json` and converts supported schema keywords into native
  `responseSchema`. `providerOptions.google.structuredOutputs = false` keeps
  JSON MIME mode but omits the schema.
- **OpenAI-compatible** emits `json_schema` only when the factory or preset
  declares `supports_structured_outputs`; otherwise it warns and uses
  `json_object`.

Schemas from `schemaFromType` include a validator. Raw schemas may omit one;
in that case provider enforcement and JSON shape checks are all the Zig layer
can perform. The C ABI has no host validator callback, so C/Python/Rust
applications that require full semantic JSON-Schema validation must apply
their chosen validator after the result.

Parse and validation failures return `NoObjectGeneratedError` with
diagnostics containing response text, usage, response metadata, finish reason,
and a cause message where available.
