//! Experimental realtime model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for realtime-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors realtime-model-v4-tool-definition.ts.
pub const RealtimeToolDefinition = union(enum) {
    function: Function,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .function, "function" },
    };

    /// Mirrors realtime-model-v4-tool-definition.ts function payload.
    pub const Function = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        parameters: shared.JsonValue,
    };
};

/// Mirrors realtime-model-v4-session-config.ts output modalities.
pub const OutputModality = enum { text, audio };

/// Mirrors realtime-model-v4-session-config.ts audio format.
pub const AudioFormat = struct {
    type: []const u8,
    rate: ?u32 = null,
};

/// Mirrors realtime-model-v4-session-config.ts transcription settings.
pub const AudioTranscriptionConfig = struct {
    model: ?[]const u8 = null,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};

/// Mirrors realtime-model-v4-session-config.ts VAD types.
pub const TurnDetectionType = enum {
    server_vad,
    semantic_vad,
    disabled,

    pub const wire_values = .{
        .{ .server_vad, "server-vad" },
        .{ .semantic_vad, "semantic-vad" },
        .{ .disabled, "disabled" },
    };
};

/// Mirrors realtime-model-v4-session-config.ts turnDetection. Upstream `null`
/// is normalized to absent by the provider-wide null policy; the explicit
/// `disabled` type preserves push-to-talk configuration.
pub const TurnDetection = struct {
    type: TurnDetectionType,
    threshold: ?f64 = null,
    silence_duration_ms: ?u64 = null,
    prefix_padding_ms: ?u64 = null,
};

/// Mirrors realtime-model-v4-session-config.ts.
pub const SessionConfig = struct {
    instructions: ?[]const u8 = null,
    voice: ?[]const u8 = null,
    output_modalities: ?[]const OutputModality = null,
    input_audio_format: ?AudioFormat = null,
    input_audio_transcription: ?AudioTranscriptionConfig = null,
    output_audio_transcription: ?AudioTranscriptionConfig = null,
    output_audio_format: ?AudioFormat = null,
    turn_detection: ?TurnDetection = null,
    tools: ?[]const RealtimeToolDefinition = null,
    provider_options: ?shared.ProviderOptions = null,
};

/// Mirrors the fixed `role:'user'` in realtime-model-v4-conversation-item.ts.
pub const UserRole = enum { user };

/// Mirrors realtime-model-v4-conversation-item.ts.
pub const ConversationItem = union(enum) {
    text_message: TextMessage,
    audio_message: AudioMessage,
    function_call_output: FunctionCallOutput,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text_message, "text-message" },
        .{ .audio_message, "audio-message" },
        .{ .function_call_output, "function-call-output" },
    };

    /// Mirrors realtime-model-v4-conversation-item.ts text message.
    pub const TextMessage = struct {
        role: UserRole,
        text: []const u8,
    };
    /// Mirrors realtime-model-v4-conversation-item.ts audio message.
    pub const AudioMessage = struct {
        role: UserRole,
        audio: []const u8,
    };
    /// Mirrors realtime-model-v4-conversation-item.ts function-call output.
    pub const FunctionCallOutput = struct {
        call_id: []const u8,
        name: ?[]const u8 = null,
        output: []const u8,
    };
};

/// Mirrors realtime-model-v4-client-event.ts response-create options.
pub const ResponseCreateOptions = struct {
    modalities: ?[]const []const u8 = null,
    instructions: ?[]const u8 = null,
    metadata: ?shared.JsonValue = null,
};

/// Mirrors all eight variants of realtime-model-v4-client-event.ts.
pub const ClientEvent = union(enum) {
    session_update: SessionUpdate,
    input_audio_append: InputAudioAppend,
    input_audio_commit: Empty,
    input_audio_clear: Empty,
    conversation_item_create: ConversationItemCreate,
    conversation_item_truncate: ConversationItemTruncate,
    response_create: ResponseCreate,
    response_cancel: Empty,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .session_update, "session-update" },
        .{ .input_audio_append, "input-audio-append" },
        .{ .input_audio_commit, "input-audio-commit" },
        .{ .input_audio_clear, "input-audio-clear" },
        .{ .conversation_item_create, "conversation-item-create" },
        .{ .conversation_item_truncate, "conversation-item-truncate" },
        .{ .response_create, "response-create" },
        .{ .response_cancel, "response-cancel" },
    };

    /// Mirrors empty payloads in realtime-model-v4-client-event.ts.
    pub const Empty = struct {};
    /// Mirrors realtime-model-v4-client-event.ts session-update payload.
    pub const SessionUpdate = struct { config: SessionConfig };
    /// Mirrors realtime-model-v4-client-event.ts input-audio-append payload.
    pub const InputAudioAppend = struct { audio: []const u8 };
    /// Mirrors realtime-model-v4-client-event.ts conversation-item-create payload.
    pub const ConversationItemCreate = struct { item: ConversationItem };
    /// Mirrors realtime-model-v4-client-event.ts truncate payload.
    pub const ConversationItemTruncate = struct {
        item_id: []const u8,
        content_index: u32,
        audio_end_ms: u64,
    };
    /// Mirrors realtime-model-v4-client-event.ts response-create payload.
    pub const ResponseCreate = struct { options: ?ResponseCreateOptions = null };
};

/// Common raw-only realtime server event payload.
pub const RawServerEvent = struct { raw: shared.JsonValue };

/// Mirrors all 23 variants of realtime-model-v4-server-event.ts. Every
/// payload includes the original provider event in `raw`.
pub const ServerEvent = union(enum) {
    session_created: SessionCreated,
    session_updated: RawServerEvent,
    speech_started: SpeechEvent,
    speech_stopped: SpeechEvent,
    audio_committed: AudioCommitted,
    conversation_item_added: ConversationItemAdded,
    input_transcription_completed: InputTranscriptionCompleted,
    response_created: ResponseCreated,
    response_done: ResponseDone,
    output_item_added: ItemEvent,
    output_item_done: ItemEvent,
    content_part_added: ItemEvent,
    content_part_done: ItemEvent,
    audio_delta: DeltaEvent,
    audio_done: ItemEvent,
    audio_transcript_delta: DeltaEvent,
    audio_transcript_done: AudioTranscriptDone,
    text_delta: DeltaEvent,
    text_done: TextDone,
    function_call_arguments_delta: FunctionArgumentsDelta,
    function_call_arguments_done: FunctionArgumentsDone,
    err: ErrorEvent,
    custom: CustomEvent,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .session_created, "session-created" },
        .{ .session_updated, "session-updated" },
        .{ .speech_started, "speech-started" },
        .{ .speech_stopped, "speech-stopped" },
        .{ .audio_committed, "audio-committed" },
        .{ .conversation_item_added, "conversation-item-added" },
        .{ .input_transcription_completed, "input-transcription-completed" },
        .{ .response_created, "response-created" },
        .{ .response_done, "response-done" },
        .{ .output_item_added, "output-item-added" },
        .{ .output_item_done, "output-item-done" },
        .{ .content_part_added, "content-part-added" },
        .{ .content_part_done, "content-part-done" },
        .{ .audio_delta, "audio-delta" },
        .{ .audio_done, "audio-done" },
        .{ .audio_transcript_delta, "audio-transcript-delta" },
        .{ .audio_transcript_done, "audio-transcript-done" },
        .{ .text_delta, "text-delta" },
        .{ .text_done, "text-done" },
        .{ .function_call_arguments_delta, "function-call-arguments-delta" },
        .{ .function_call_arguments_done, "function-call-arguments-done" },
        .{ .err, "error" },
        .{ .custom, "custom" },
    };

    /// Mirrors realtime-model-v4-server-event.ts session-created payload.
    pub const SessionCreated = struct {
        session_id: ?[]const u8 = null,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts speech event payloads.
    pub const SpeechEvent = struct {
        item_id: ?[]const u8 = null,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts audio-committed payload.
    pub const AudioCommitted = struct {
        item_id: ?[]const u8 = null,
        previous_item_id: ?[]const u8 = null,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts conversation-item-added payload.
    pub const ConversationItemAdded = struct {
        item_id: []const u8,
        item: shared.JsonValue,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts transcription payload.
    pub const InputTranscriptionCompleted = struct {
        item_id: []const u8,
        transcript: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts response-created payload.
    pub const ResponseCreated = struct {
        response_id: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts response-done payload.
    pub const ResponseDone = struct {
        response_id: []const u8,
        status: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts item/content/audio-done payloads.
    pub const ItemEvent = struct {
        response_id: []const u8,
        item_id: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts audio/text delta payloads.
    pub const DeltaEvent = struct {
        response_id: []const u8,
        item_id: []const u8,
        delta: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts audio-transcript-done payload.
    pub const AudioTranscriptDone = struct {
        response_id: []const u8,
        item_id: []const u8,
        transcript: ?[]const u8 = null,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts text-done payload.
    pub const TextDone = struct {
        response_id: []const u8,
        item_id: []const u8,
        text: ?[]const u8 = null,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts function arguments delta.
    pub const FunctionArgumentsDelta = struct {
        response_id: []const u8,
        item_id: []const u8,
        call_id: []const u8,
        delta: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts function arguments done.
    pub const FunctionArgumentsDone = struct {
        response_id: []const u8,
        item_id: []const u8,
        call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts error payload.
    pub const ErrorEvent = struct {
        message: []const u8,
        code: ?[]const u8 = null,
        raw: shared.JsonValue,
    };
    /// Mirrors realtime-model-v4-server-event.ts custom payload.
    pub const CustomEvent = struct {
        raw_type: []const u8,
        raw: shared.JsonValue,
    };
};

/// Mirrors realtime-model-v4-client-secret.ts options.
pub const ClientSecretOptions = struct {
    expires_after_seconds: ?u64 = null,
    session_config: ?SessionConfig = null,
};

/// Mirrors realtime-model-v4-client-secret.ts result.
pub const ClientSecretResult = struct {
    token: []const u8,
    url: []const u8,
    expires_at: ?u64 = null,
};

/// Mirrors realtime-model-v4.ts getWebSocketConfig options.
pub const WebSocketOptions = struct {
    token: []const u8,
    url: []const u8,
};

/// Mirrors realtime-model-v4.ts getWebSocketConfig result.
pub const WebSocketConfig = struct {
    url: []const u8,
    protocols: ?[]const []const u8 = null,
};

/// Mirrors realtime-factory-v4.ts getToken options.
pub const FactoryGetTokenOptions = struct {
    model: []const u8,
    expires_after_seconds: ?u64 = null,
    session_config: ?SessionConfig = null,
};

/// Mirrors realtime-factory-v4.ts getToken result.
pub const FactoryGetTokenResult = ClientSecretResult;

/// Mirrors realtime-factory-v4.ts callable factory as a Zig fat pointer.
pub const RealtimeFactory = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors realtime-factory-v4.ts operations.
    pub const VTable = struct {
        model: *const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!RealtimeModel,
        getToken: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const FactoryGetTokenOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!FactoryGetTokenResult,
    };

    pub fn model(
        self: RealtimeFactory,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!RealtimeModel {
        return self.vtable.model(self.ctx, model_id, diag);
    }

    pub fn getToken(
        self: RealtimeFactory,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const FactoryGetTokenOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!FactoryGetTokenResult {
        return self.vtable.getToken(self.ctx, io, arena, options, diag);
    }
};

/// Mirrors realtime-model-v4.ts as a pure codec/configuration fat-pointer
/// interface. It owns no WebSocket transport.
pub const RealtimeModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors realtime-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        doCreateClientSecret: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const ClientSecretOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!ClientSecretResult,
        getWebSocketConfig: *const fn (
            ctx: *anyopaque,
            arena: std.mem.Allocator,
            options: *const WebSocketOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!WebSocketConfig,
        parseServerEvent: *const fn (
            ctx: *anyopaque,
            arena: std.mem.Allocator,
            raw: *const shared.JsonValue,
            diag: ?*errors.Diagnostics,
        ) CallError![]const ServerEvent,
        serializeClientEvent: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            event: *const ClientEvent,
            diag: ?*errors.Diagnostics,
        ) CallError!shared.JsonValue,
        buildSessionConfig: *const fn (
            ctx: *anyopaque,
            arena: std.mem.Allocator,
            config: *const SessionConfig,
            diag: ?*errors.Diagnostics,
        ) CallError!shared.JsonValue,
        getHealthCheckResponse: ?*const fn (
            ctx: *anyopaque,
            arena: std.mem.Allocator,
            raw: *const shared.JsonValue,
            diag: ?*errors.Diagnostics,
        ) CallError!?shared.JsonValue,
    };

    pub fn provider(self: RealtimeModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: RealtimeModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn doCreateClientSecret(
        self: RealtimeModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const ClientSecretOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!ClientSecretResult {
        return self.vtable.doCreateClientSecret(self.ctx, io, arena, options, diag);
    }

    pub fn getWebSocketConfig(
        self: RealtimeModel,
        arena: std.mem.Allocator,
        options: *const WebSocketOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!WebSocketConfig {
        return self.vtable.getWebSocketConfig(self.ctx, arena, options, diag);
    }

    pub fn parseServerEvent(
        self: RealtimeModel,
        arena: std.mem.Allocator,
        raw: *const shared.JsonValue,
        diag: ?*errors.Diagnostics,
    ) CallError![]const ServerEvent {
        return self.vtable.parseServerEvent(self.ctx, arena, raw, diag);
    }

    pub fn serializeClientEvent(
        self: RealtimeModel,
        io: std.Io,
        arena: std.mem.Allocator,
        event: *const ClientEvent,
        diag: ?*errors.Diagnostics,
    ) CallError!shared.JsonValue {
        return self.vtable.serializeClientEvent(self.ctx, io, arena, event, diag);
    }

    pub fn buildSessionConfig(
        self: RealtimeModel,
        arena: std.mem.Allocator,
        config: *const SessionConfig,
        diag: ?*errors.Diagnostics,
    ) CallError!shared.JsonValue {
        return self.vtable.buildSessionConfig(self.ctx, arena, config, diag);
    }

    pub fn getHealthCheckResponse(
        self: RealtimeModel,
        arena: std.mem.Allocator,
        raw: *const shared.JsonValue,
        diag: ?*errors.Diagnostics,
    ) CallError!?shared.JsonValue {
        const function = self.vtable.getHealthCheckResponse orelse return null;
        return function(self.ctx, arena, raw, diag);
    }
};
