//! Mirrors the Vercel AI SDK `@ai-sdk/mcp` package.

const std = @import("std");

pub const json_rpc = @import("json_rpc.zig");
pub const types = @import("types.zig");
pub const transport = @import("transport.zig");
pub const stdio_transport = @import("stdio_transport.zig");
pub const sse_transport = @import("sse_transport.zig");
pub const http_transport = @import("http_transport.zig");
pub const client = @import("client.zig");
pub const tools = @import("tools.zig");

pub const JSONRPCMessage = json_rpc.Message;
pub const JSONRPCId = json_rpc.Id;
pub const parseJSONRPCMessage = json_rpc.parse;
pub const validateJSONRPCMessage = json_rpc.validate;
pub const serializeJSONRPCMessage = json_rpc.serialize;

pub const LATEST_PROTOCOL_VERSION = types.LATEST_PROTOCOL_VERSION;
pub const SUPPORTED_PROTOCOL_VERSIONS = types.SUPPORTED_PROTOCOL_VERSIONS;
pub const MCPTransport = transport.MCPTransport;
pub const TransportCallbacks = transport.Callbacks;
pub const StdioMCPTransport = stdio_transport.StdioTransport;
pub const StdioTransportConfig = stdio_transport.Config;
pub const SseMCPTransport = sse_transport.SseTransport;
pub const SseTransportConfig = sse_transport.Config;
pub const HttpMCPTransport = http_transport.HttpTransport;
pub const HttpTransportConfig = http_transport.Config;
pub const MCPClient = client.Client;
pub const MCPClientOptions = client.Options;
pub const createMcpClient = client.createMcpClient;
pub const McpToolSchemas = tools.Schemas;
pub const McpExplicitToolSchema = tools.ExplicitSchema;

test "module declarations" {
    std.testing.refAllDecls(@This());
    _ = @import("integration_test.zig");
    _ = @import("transport_test.zig");
    _ = @import("client_contract_test.zig");
}
