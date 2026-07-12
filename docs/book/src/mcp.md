# MCP Client

The MCP module implements JSON-RPC request correlation, initialization,
capability discovery, tools/resources/prompts, elicitation, three transports,
and conversion of server tools into `ai.NamedTool` values.

## Create a client

The stdio form launches a child process and performs the initialize handshake
before returning:

```zig
var client = try mcp.createMcpClient(gpa, io, .{
    .transport = .{ .stdio = .{
        .command = "mcp-server",
        .args = &.{"--stdio"},
        .parent_environ = init.environ_map,
    } },
});
defer client.deinit(io);

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const definitions = try client.listTools(io, arena, null);
const tools = try client.toolsFromDefinitions(arena, definitions, .{});
_ = tools;
```

The client sends the latest supported protocol version, client identity, and
capabilities; validates the server's selected version; stores server info and
instructions; updates the transport's negotiated version; then sends
`notifications/initialized`.

## Three transports

| Transport | Config tag | Behavior |
| --- | --- | --- |
| Stdio | `.stdio` | newline-delimited JSON-RPC over a Zig 0.16 child process |
| Legacy SSE | `.sse` | long-lived GET receives an endpoint event; POST sends messages |
| Streamable HTTP | `.http` | POST JSON/SSE responses plus optional resumable inbound GET |

Stdio does not silently inherit the whole process environment. Passing
`parent_environ` enables the implementation's whitelist; explicit `env`
entries override inherited values. With no concurrent I/O, stdio can pump one
response immediately after an id-bearing send, but independent server traffic
is unavailable in that documented degraded mode.

Legacy SSE requires real concurrency for its reader. It resolves relative
endpoint events against the configured server URL and accepts only message
events as JSON-RPC input.

Streamable HTTP remains useful when an optional standing GET cannot start:
POST request/response traffic still works. It accepts JSON, SSE, or 202
responses and owns concurrent POST-SSE readers when needed.

## Authentication seam

Full OAuth is not implemented. Both HTTP transports accept an `AuthHook` that
is called once after a 401. If it authorizes successfully, the transport
retries the request. This is an intentional integration seam, not a claim of
OAuth discovery, browser authorization, token refresh, or secure credential
storage.

## Streamable HTTP sessions

The transport captures `Mcp-Session-Id` from initialization and attaches it to
later POST/GET/DELETE requests. Applications can supply an initial session and
receive session-changed/expired callbacks. A 404 tied to an active session
expires it and clears state.

Inbound SSE records `Last-Event-ID`, reconnects with bounded exponential
backoff, and resumes with the last id. Closing can send DELETE for the active
session (`terminate_session_on_close = true` by default). Protocol version and
session state are protected independently from request tasks.

## Client APIs and tool bridging

The client exposes paginated `listTools`, `listResources`, `readResource`,
`listResourceTemplates`, `listPrompts`, `getPrompt`, completion, raw requests,
tool calls, and an elicitation handler. Pending request ids are correlated
across concurrent calls and are completed as connection-closed on teardown.

`client.tools(...)` lists and converts definitions automatically. Automatic
schemas become dynamic tools and are normalized with
`additionalProperties: false`; explicit schemas select named tools and can
validate structured output. MCP text/image/unknown content converts into the
core tool-result vocabulary, while `isError` results become model-visible tool
errors.

MCP is beta. Stdio has a live child-process integration gate; SSE and
streamable HTTP are covered with canned transport fixtures. MCP is not exposed
through C ABI v1, Python, or Rust today.

