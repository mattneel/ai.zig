//! Mirrors the `@ai-sdk/provider@4.0.3` V4 provider specification.

const std = @import("std");

pub const specification_version = "v4";

pub const errors = @import("errors.zig");
pub const shared = @import("shared.zig");
pub const iso8601 = @import("iso8601.zig");
pub const language_model = @import("language_model.zig");
pub const embedding_model = @import("embedding_model.zig");
pub const image_model = @import("image_model.zig");
pub const speech_model = @import("speech_model.zig");
pub const transcription_model = @import("transcription_model.zig");
pub const reranking_model = @import("reranking_model.zig");
pub const video_model = @import("video_model.zig");
pub const files_module = @import("files.zig");
pub const skills_module = @import("skills.zig");
pub const realtime_model = @import("realtime_model.zig");
pub const provider_module = @import("provider.zig");
pub const wire = @import("wire.zig");

pub const Error = errors.Error;
pub const Diagnostics = errors.Diagnostics;
pub const Payload = errors.Payload;
pub const Header = errors.Header;
pub const ModelType = errors.ModelType;
pub const RetryReason = errors.RetryReason;
pub const FinishReason = errors.FinishReason;
pub const FinishReasonUnified = errors.FinishReasonUnified;
pub const TypeValidationContext = errors.TypeValidationContext;
pub const isRetryableStatus = errors.isRetryableStatus;

pub const JsonValue = shared.JsonValue;
pub const ProviderOptions = shared.ProviderOptions;
pub const ProviderMetadata = shared.ProviderMetadata;
pub const ProviderReference = shared.ProviderReference;
pub const Headers = shared.Headers;
pub const BinaryData = shared.BinaryData;
pub const FileData = shared.FileData;
pub const GeneratedFileData = shared.GeneratedFileData;
pub const UploadFileData = shared.UploadFileData;
pub const Warning = shared.Warning;
pub const isValidKind = shared.isValidKind;
pub const parseSize = shared.parseSize;
pub const parseAspectRatio = shared.parseAspectRatio;

pub const CallError = language_model.CallError;
pub const NextError = language_model.NextError;
pub const LanguageModel = language_model.LanguageModel;
pub const CallOptions = language_model.CallOptions;
pub const Prompt = language_model.Prompt;
pub const Message = language_model.Message;
pub const UserContentPart = language_model.UserContentPart;
pub const AssistantContentPart = language_model.AssistantContentPart;
pub const ToolContentPart = language_model.ToolContentPart;
pub const TextPart = language_model.TextPart;
pub const FilePart = language_model.FilePart;
pub const ReasoningPart = language_model.ReasoningPart;
pub const ReasoningFilePart = language_model.ReasoningFilePart;
pub const CustomPart = language_model.CustomPart;
pub const ToolCallPart = language_model.ToolCallPart;
pub const ToolResultPart = language_model.ToolResultPart;
pub const ToolApprovalResponsePart = language_model.ToolApprovalResponsePart;
pub const ToolResultOutput = language_model.ToolResultOutput;
pub const ToolResultContentPart = language_model.ToolResultContentPart;
pub const FunctionTool = language_model.FunctionTool;
pub const ProviderTool = language_model.ProviderTool;
pub const Tool = language_model.Tool;
pub const ToolChoice = language_model.ToolChoice;
pub const ResponseFormat = language_model.ResponseFormat;
pub const ReasoningEffort = language_model.ReasoningEffort;
pub const Usage = language_model.Usage;
pub const InputTokens = language_model.InputTokens;
pub const OutputTokens = language_model.OutputTokens;
pub const TextContent = language_model.TextContent;
pub const ReasoningContent = language_model.ReasoningContent;
pub const CustomContent = language_model.CustomContent;
pub const GeneratedFile = language_model.GeneratedFile;
pub const GeneratedReasoningFile = language_model.GeneratedReasoningFile;
pub const ToolApprovalRequest = language_model.ToolApprovalRequest;
pub const GeneratedToolCall = language_model.GeneratedToolCall;
pub const GeneratedToolResult = language_model.GeneratedToolResult;
pub const Source = language_model.Source;
pub const Content = language_model.Content;
pub const StreamPart = language_model.StreamPart;
pub const GenerateResult = language_model.GenerateResult;
pub const RequestInfo = language_model.RequestInfo;
pub const ResponseInfo = language_model.ResponseInfo;
pub const StreamResponseInfo = language_model.StreamResponseInfo;
pub const PartStream = language_model.PartStream;
pub const StreamResult = language_model.StreamResult;

pub const EmbeddingModel = embedding_model.EmbeddingModel;
pub const EmbeddingCallOptions = embedding_model.CallOptions;
pub const EmbeddingResult = embedding_model.Result;
pub const EmbeddingUsage = embedding_model.Usage;
pub const EmbeddingResponseInfo = embedding_model.ResponseInfo;

pub const ImageModel = image_model.ImageModel;
pub const ImageCallOptions = image_model.CallOptions;
pub const ImageFile = image_model.ImageFile;
pub const ImageData = image_model.ImageData;
pub const ImageResult = image_model.Result;
pub const ImageUsage = image_model.Usage;
pub const ImageResponseInfo = image_model.ResponseInfo;

pub const SpeechModel = speech_model.SpeechModel;
pub const SpeechCallOptions = speech_model.CallOptions;
pub const SpeechResult = speech_model.Result;
pub const SpeechRequestInfo = speech_model.RequestInfo;
pub const SpeechResponseInfo = speech_model.ResponseInfo;

pub const TranscriptionModel = transcription_model.TranscriptionModel;
pub const TranscriptionCallOptions = transcription_model.CallOptions;
pub const TranscriptionResult = transcription_model.Result;
pub const TranscriptionSegment = transcription_model.Segment;
pub const TranscriptionStreamOptions = transcription_model.StreamOptions;
pub const TranscriptionStreamPart = transcription_model.StreamPart;
pub const TranscriptionPartStream = transcription_model.PartStream;
pub const TranscriptionStreamResult = transcription_model.StreamResult;

pub const RerankingModel = reranking_model.RerankingModel;
pub const RerankingCallOptions = reranking_model.CallOptions;
pub const RerankingDocuments = reranking_model.Documents;
pub const RerankingResult = reranking_model.Result;
pub const Ranking = reranking_model.Ranking;

pub const VideoModel = video_model.VideoModel;
pub const VideoCallOptions = video_model.CallOptions;
pub const VideoFile = video_model.VideoFile;
pub const VideoFrameType = video_model.FrameType;
pub const VideoFrameImage = video_model.FrameImage;
pub const VideoData = video_model.VideoData;
pub const VideoResult = video_model.Result;

pub const Files = files_module.Files;
pub const UploadFileCallOptions = files_module.UploadFileCallOptions;
pub const UploadFileResult = files_module.UploadFileResult;
pub const Skills = skills_module.Skills;
pub const SkillFile = skills_module.SkillFile;
pub const UploadSkillCallOptions = skills_module.UploadSkillCallOptions;
pub const UploadSkillResult = skills_module.UploadSkillResult;

pub const RealtimeModel = realtime_model.RealtimeModel;
pub const RealtimeFactory = realtime_model.RealtimeFactory;
pub const RealtimeFactoryGetTokenOptions = realtime_model.FactoryGetTokenOptions;
pub const RealtimeFactoryGetTokenResult = realtime_model.FactoryGetTokenResult;
pub const RealtimeToolDefinition = realtime_model.RealtimeToolDefinition;
pub const SessionConfig = realtime_model.SessionConfig;
pub const ClientEvent = realtime_model.ClientEvent;
pub const ServerEvent = realtime_model.ServerEvent;
pub const ConversationItem = realtime_model.ConversationItem;
pub const ClientSecretOptions = realtime_model.ClientSecretOptions;
pub const ClientSecretResult = realtime_model.ClientSecretResult;
pub const WebSocketOptions = realtime_model.WebSocketOptions;
pub const WebSocketConfig = realtime_model.WebSocketConfig;

pub const Provider = provider_module.Provider;

pub const parseStreamPart = wire.parseStreamPart;
pub const writeStreamPart = wire.writeStreamPart;
pub const parseCallOptions = wire.parseCallOptions;
pub const writeCallOptions = wire.writeCallOptions;
pub const parsePrompt = wire.parsePrompt;
pub const writePrompt = wire.writePrompt;
pub const parseMessage = wire.parseMessage;
pub const writeMessage = wire.writeMessage;
pub const parseContent = wire.parseContent;
pub const writeContent = wire.writeContent;
pub const parseGenerateResult = wire.parseGenerateResult;
pub const writeGenerateResult = wire.writeGenerateResult;
pub const parseClientEvent = wire.parseClientEvent;
pub const writeClientEvent = wire.writeClientEvent;
pub const parseServerEvent = wire.parseServerEvent;
pub const writeServerEvent = wire.writeServerEvent;
pub const parseTranscriptionStreamPart = wire.parseTranscriptionStreamPart;
pub const writeTranscriptionStreamPart = wire.writeTranscriptionStreamPart;

// TODO(phase-4): language/embedding/image middleware V4 types.

comptime {
    _ = errors.Error;
    _ = shared.FileData;
    _ = language_model.LanguageModel;
    _ = embedding_model.EmbeddingModel;
    _ = image_model.ImageModel;
    _ = speech_model.SpeechModel;
    _ = transcription_model.TranscriptionModel;
    _ = reranking_model.RerankingModel;
    _ = video_model.VideoModel;
    _ = files_module.Files;
    _ = skills_module.Skills;
    _ = realtime_model.RealtimeModel;
    _ = provider_module.Provider;
    _ = wire.parse;
}

test "module declarations" {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("wire_test.zig");
    _ = @import("wire_realtime_test.zig");
    _ = @import("wire_models_test.zig");
}
