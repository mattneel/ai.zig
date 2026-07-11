//! Framework-neutral chat/UI message protocol.

const std = @import("std");

pub const messages = @import("ui_messages.zig");
pub const chunks = @import("ui_chunks.zig");
pub const chunk_stream = @import("chunk_stream.zig");
pub const sse = @import("ui_sse.zig");
pub const to_ui_chunks = @import("to_ui_chunks.zig");
pub const ui_stream = @import("ui_stream.zig");
pub const agent_ui = @import("agent_ui.zig");
pub const process_ui_stream = @import("process_ui_stream.zig");
pub const convert_ui_messages = @import("convert_ui_messages.zig");
pub const handle_ui_stream_finish = @import("handle_ui_stream_finish.zig");
pub const create_ui_stream = @import("create_ui_stream.zig");
pub const transports = @import("transports.zig");
pub const chat = @import("chat.zig");

pub const UIMessage = messages.UIMessage;
pub const UIMessagePart = messages.UIMessagePart;
pub const UIMessageChunk = chunks.UIMessageChunk;
pub const UIMessageChunkStream = chunk_stream.ChunkStream;
pub const UI_MESSAGE_STREAM_HEADERS = sse.UI_MESSAGE_STREAM_HEADERS;
pub const toUIMessageChunk = to_ui_chunks.toUIMessageChunk;
pub const toUIMessageStreamRaw = to_ui_chunks.toUIMessageStream;
pub const toUIMessageStream = ui_stream.toUIMessageStream;
pub const StreamingUIMessageState = process_ui_stream.StreamingState;
pub const processUIMessageStream = process_ui_stream.processUIMessageStream;
pub const readUIMessageStream = process_ui_stream.readUIMessageStream;
pub const convertToModelMessages = convert_ui_messages.convertToModelMessages;
pub const validateUIMessages = convert_ui_messages.validateUIMessages;
pub const safeValidateUIMessages = convert_ui_messages.safeValidateUIMessages;
pub const handleUIMessageStreamFinish = handle_ui_stream_finish.handleUIMessageStreamFinish;
pub const createUIMessageStream = create_ui_stream.createUIMessageStream;
pub const ChatTransport = transports.ChatTransport;
pub const HttpChatTransport = transports.HttpChatTransport;
pub const DefaultChatTransport = transports.DefaultChatTransport;
pub const TextStreamChatTransport = transports.TextStreamChatTransport;
pub const DirectChatTransport = agent_ui.DirectChatTransport;
pub const Chat = chat.Chat;
pub const ChatState = chat.ChatState;
pub const MemoryChatState = chat.MemoryChatState;
pub const ChatStatus = chat.Status;
pub const lastAssistantMessageIsCompleteWithToolCalls = chat.lastAssistantMessageIsCompleteWithToolCalls;
pub const lastAssistantMessageIsCompleteWithApprovalResponses = chat.lastAssistantMessageIsCompleteWithApprovalResponses;
pub const createAgentUIStream = agent_ui.createAgentUIStream;
pub const writeUIMessageStreamResponse = agent_ui.writeUIMessageStreamResponse;
pub const writeAgentUIStreamResponse = agent_ui.writeAgentUIStreamResponse;

test "module declarations" {
    std.testing.refAllDecls(@This());
}
