//! Mirrors the upstream AI SDK test-server infrastructure.

const std = @import("std");

pub const mock_server = @import("mock_server.zig");
pub const MockServer = mock_server.MockServer;
pub const CannedResponse = mock_server.CannedResponse;
pub const Body = mock_server.Body;
pub const SseEvent = mock_server.SseEvent;
pub const Header = mock_server.Header;
pub const RecordedRequest = mock_server.RecordedRequest;
pub const ServeErrorReport = mock_server.ServeErrorReport;
pub const websocket_server = @import("websocket_server.zig");
pub const WebSocketScriptServer = websocket_server.ScriptServer;
pub const WebSocketScriptHandler = websocket_server.Handler;

comptime {
    _ = mock_server.MockServer;
    _ = websocket_server.ScriptServer;
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}
