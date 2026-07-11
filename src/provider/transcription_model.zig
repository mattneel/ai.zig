//! Transcription model V4 provider specification.

const std = @import("std");
const errors = @import("errors.zig");
const shared = @import("shared.zig");

/// Error boundary for transcription-model-v4.ts calls.
pub const CallError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;
/// Error boundary for transcription-model-v4 stream pulls.
pub const NextError = errors.Error || std.Io.Cancelable || std.mem.Allocator.Error;

/// Mirrors transcription-model-v4-call-options.ts.
pub const CallOptions = struct {
    audio: shared.BinaryData,
    media_type: []const u8,
    provider_options: ?shared.ProviderOptions = null,
    headers: ?shared.Headers = null,
};

/// Mirrors the segment shape in transcription-model-v4-result.ts.
pub const Segment = struct {
    text: []const u8,
    start_second: f64,
    end_second: f64,
};

/// Mirrors transcription-model-v4-result.ts request information.
pub const RequestInfo = struct { body: ?[]const u8 = null };

/// Mirrors transcription-model-v4-result.ts response information.
pub const ResponseInfo = struct {
    timestamp_ms: i64,
    model_id: []const u8,
    headers: ?shared.Headers = null,
    body: ?shared.JsonValue = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors transcription-model-v4-result.ts.
pub const Result = struct {
    text: []const u8,
    segments: []const Segment,
    language: ?[]const u8 = null,
    duration_in_seconds: ?f64 = null,
    warnings: []const shared.Warning,
    request: ?RequestInfo = null,
    response: ResponseInfo,
    provider_metadata: ?shared.ProviderMetadata = null,
};

/// Pull source for the `ReadableStream<Uint8Array|string>` in
/// transcription-model-v4-stream-options.ts. Chunk slices are borrowed until
/// the next `next()` call or `deinit()`.
pub const AudioStream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors transcription-model-v4-stream-options.ts input stream operations.
    pub const VTable = struct {
        next: *const fn (ctx: *anyopaque, io: std.Io) NextError!?shared.BinaryData,
        deinit: *const fn (ctx: *anyopaque, io: std.Io) void,
    };

    pub fn next(self: AudioStream, io: std.Io) NextError!?shared.BinaryData {
        return self.vtable.next(self.ctx, io);
    }

    pub fn deinit(self: AudioStream, io: std.Io) void {
        self.vtable.deinit(self.ctx, io);
    }
};

/// Mirrors transcription-model-v4-stream-options.ts inputAudioFormat.
pub const InputAudioFormat = struct {
    type: []const u8,
    rate: ?u32 = null,
};

/// Mirrors transcription-model-v4-stream-options.ts.
pub const StreamOptions = struct {
    audio: AudioStream,
    input_audio_format: InputAudioFormat,
    provider_options: ?shared.ProviderOptions = null,
    headers: ?shared.Headers = null,
    include_raw_chunks: ?bool = null,
};

/// Mirrors transcription-model-v4-stream-part.ts transcript-delta.
pub const TranscriptDelta = struct {
    id: ?[]const u8 = null,
    delta: []const u8,
    provider_metadata: ?shared.ProviderMetadata = null,
};

/// Mirrors transcription-model-v4-stream-part.ts transcript-partial.
pub const TranscriptPartial = struct {
    id: ?[]const u8 = null,
    text: []const u8,
    start_second: ?f64 = null,
    duration_in_seconds: ?f64 = null,
    channel_index: ?u32 = null,
    provider_metadata: ?shared.ProviderMetadata = null,
};

/// Mirrors transcription-model-v4-stream-part.ts transcript-final.
pub const TranscriptFinal = struct {
    id: ?[]const u8 = null,
    text: []const u8,
    start_second: ?f64 = null,
    end_second: ?f64 = null,
    channel_index: ?u32 = null,
    provider_metadata: ?shared.ProviderMetadata = null,
};

/// Mirrors transcription-model-v4-stream-part.ts response-metadata.
pub const StreamResponseMetadata = struct {
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,
    headers: ?shared.Headers = null,
    body: ?shared.JsonValue = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors transcription-model-v4-stream-part.ts finish.
pub const FinishPart = struct {
    text: []const u8,
    segments: []const Segment,
    language: ?[]const u8 = null,
    duration_in_seconds: ?f64 = null,
    provider_metadata: ?shared.ProviderMetadata = null,
};

/// Mirrors transcription-model-v4-stream-part.ts raw.
pub const RawPart = struct { raw_value: shared.JsonValue };

/// Mirrors transcription-model-v4-stream-part.ts error.
pub const ErrorPart = struct {
    error_value: shared.JsonValue,

    pub const wire_field_names = .{
        .{ "error_value", "error" },
    };
};

/// Mirrors all eight variants of transcription-model-v4-stream-part.ts.
pub const StreamPart = union(enum) {
    stream_start: StreamStart,
    transcript_delta: TranscriptDelta,
    transcript_partial: TranscriptPartial,
    transcript_final: TranscriptFinal,
    response_metadata: StreamResponseMetadata,
    finish: FinishPart,
    raw: RawPart,
    err: ErrorPart,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .stream_start, "stream-start" },
        .{ .transcript_delta, "transcript-delta" },
        .{ .transcript_partial, "transcript-partial" },
        .{ .transcript_final, "transcript-final" },
        .{ .response_metadata, "response-metadata" },
        .{ .finish, "finish" },
        .{ .raw, "raw" },
        .{ .err, "error" },
    };

    /// Mirrors transcription-model-v4-stream-part.ts stream-start payload.
    pub const StreamStart = struct { warnings: []const shared.Warning };
};

/// Pull-based replacement for the transcription ReadableStream. Returned
/// parts and slices are valid until the next `next()` call or `deinit()`.
pub const PartStream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors transcription-model-v4-stream-result.ts stream operations.
    pub const VTable = struct {
        next: *const fn (ctx: *anyopaque, io: std.Io) NextError!?StreamPart,
        deinit: *const fn (ctx: *anyopaque, io: std.Io) void,
    };

    pub fn next(self: PartStream, io: std.Io) NextError!?StreamPart {
        return self.vtable.next(self.ctx, io);
    }

    pub fn deinit(self: PartStream, io: std.Io) void {
        self.vtable.deinit(self.ctx, io);
    }
};

/// Mirrors transcription-model-v4-stream-result.ts request information.
pub const StreamRequestInfo = struct { body: ?shared.JsonValue = null };

/// Mirrors transcription-model-v4-stream-result.ts response information.
pub const StreamResponseInfo = struct {
    timestamp_ms: ?i64 = null,
    model_id: ?[]const u8 = null,
    headers: ?shared.Headers = null,
    body: ?shared.JsonValue = null,

    pub const wire_field_names = .{
        .{ "timestamp_ms", "timestamp" },
    };
};

/// Mirrors transcription-model-v4-stream-result.ts.
pub const StreamResult = struct {
    stream: PartStream,
    request: ?StreamRequestInfo = null,
    response: ?StreamResponseInfo = null,
};

/// Mirrors transcription-model-v4.ts as a Zig fat-pointer interface.
pub const TranscriptionModel = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors transcription-model-v4.ts operations.
    pub const VTable = struct {
        provider: *const fn (ctx: *anyopaque) []const u8,
        modelId: *const fn (ctx: *anyopaque) []const u8,
        doGenerate: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const CallOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!Result,
        doStream: ?*const fn (
            ctx: *anyopaque,
            io: std.Io,
            arena: std.mem.Allocator,
            options: *const StreamOptions,
            diag: ?*errors.Diagnostics,
        ) CallError!StreamResult,
    };

    pub fn provider(self: TranscriptionModel) []const u8 {
        return self.vtable.provider(self.ctx);
    }

    pub fn modelId(self: TranscriptionModel) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn doGenerate(
        self: TranscriptionModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const CallOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!Result {
        return self.vtable.doGenerate(self.ctx, io, arena, options, diag);
    }

    pub fn doStream(
        self: TranscriptionModel,
        io: std.Io,
        arena: std.mem.Allocator,
        options: *const StreamOptions,
        diag: ?*errors.Diagnostics,
    ) CallError!StreamResult {
        const function = self.vtable.doStream orelse {
            errors.Diagnostics.set(diag, if (diag) |value| value.allocator else arena, .{
                .unsupported_functionality = .{
                    .message = "streaming transcription is not supported",
                    .functionality = "doStream",
                },
            });
            return error.UnsupportedFunctionalityError;
        };
        return function(self.ctx, io, arena, options, diag);
    }
};
