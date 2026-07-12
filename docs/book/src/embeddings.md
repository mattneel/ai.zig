# Embeddings

`ai.embed` handles one byte string; `ai.embedMany` batches many values across
the provider's advertised per-call limit while preserving input order.
Embedding values are byte slices rather than assumed UTF-8-only strings at
the core boundary.

## Single value

```zig
var result = try ai.embed(io, gpa, .{
    .model = .{ .model = embedding_model },
    .value = "The quick brown fox",
});
defer result.deinit();

std.debug.print("dimensions={d} tokens={?d}\n", .{
    result.embedding.len,
    result.usage.tokens,
});
```

The result owns an arena and includes the original value, vector, optional
token usage, warnings, provider metadata, and response metadata. Calls default
to two retries and accept headers, provider options, callbacks, telemetry, and
diagnostics.

## Many values

```zig
const values = [_][]const u8{ "alpha", "beta", "gamma" };
var result = try ai.embedMany(io, gpa, .{
    .model = .{ .model = embedding_model },
    .values = &values,
    .max_parallel_calls = 4,
});
defer result.deinit();

for (result.values, result.embeddings) |value, vector| {
    std.debug.print("{s}: {d} dimensions\n", .{ value, vector.len });
}
```

`embedMany` splits input into provider-sized chunks. If the provider supports
parallel calls, chunks run in waves up to `max_parallel_calls`; otherwise
each wave contains one call. Results from a wave are appended in chunk order,
not task completion order. Every returned vector count must match its input
chunk or the operation fails with `InvalidResponseDataError`.

Token usage is summed when reported. If every chunk omits usage, the aggregate
remains `null` rather than inventing a number.

## Provider support and limits

| Provider surface | Model example | Maximum values per call | Parallel chunks |
| --- | --- | ---: | --- |
| OpenAI native | `text-embedding-3-small` | 2048 | yes |
| Google native | `gemini-embedding-001` | 100 | yes |
| Generic OpenAI-compatible | vendor model id | 2048 by default | yes by default |
| Mistral preset | vendor model id | 32 | no |
| Together AI preset | vendor model id | 2048 default | yes |
| Fireworks preset | vendor model id | 2048 default | yes |
| OpenRouter wrapper | routed model id | 2048 default | yes |

The Groq and DeepSeek presets intentionally return `NoSuchModelError` for
embeddings. Anthropic exposes no embedding model. Provider support is a
factory capability, not inferred from a model-id string.

At the provider layer, `EmbeddingModel.maxEmbeddingsPerCall(io)` and
`supportsParallelCalls(io)` drive orchestration. An oversized direct provider
call returns `TooManyEmbeddingValuesForCallError` with provider, model, limit,
and values in diagnostics; `ai.embedMany` avoids that error by batching.

The C ABI exposes `ai_embed` and `ai_embed_many`; both Python and Rust wrappers
return parsed/canonical result documents. See [Providers](providers/index.md)
for authentication and factory construction.

