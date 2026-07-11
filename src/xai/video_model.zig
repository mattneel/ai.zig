//! xAI deferred-job video generation provider.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const openai_compatible = @import("openai_compatible");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    allocator: Allocator,
    provider: []const u8,
    base_url: []const u8,
    api_key: ?[]const u8,
    env: provider_utils.EnvLookup,
    headers: openai_compatible.HeaderSource,
    transport: provider_utils.HttpTransport,
};

pub const VideoModel = struct {
    model_id: []const u8,
    config: Config,

    pub fn init(
        model_id: []const u8,
        config: Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!VideoModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "xAI video model id is required");
        if (config.provider.len == 0) return invalidArgument(diag, "name", "xAI provider name is required");
        if (config.base_url.len == 0) return invalidArgument(diag, "baseURL", "xAI base URL is required");
        return .{ .model_id = model_id, .config = config };
    }

    pub fn videoModel(self: *VideoModel) provider.VideoModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.VideoModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .maxVideosPerCall = vMaxVideosPerCall,
        .doGenerate = vDoGenerate,
    };

    fn fromRaw(raw: *anyopaque) *VideoModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        return fromRaw(raw).config.provider;
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vMaxVideosPerCall(_: *anyopaque, _: std.Io) ?u32 {
        return 1;
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.VideoCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.video_model.CallError!provider.VideoResult {
        return fromRaw(raw).doGenerate(io, arena, options, diag);
    }

    pub fn doGenerate(
        self: *VideoModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.VideoCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.video_model.CallError!provider.VideoResult {
        const response_timestamp_ms = timestampMilliseconds(io, .real);
        var warnings: std.ArrayList(provider.Warning) = .empty;
        defer warnings.deinit(arena);

        const xai_options = try parseOptions(arena, options.provider_options, diag);
        const mode = resolveMode(options, xai_options);
        const is_edit = mode == .edit_video;
        const is_extension = mode == .extend_video;
        const has_reference_images = mode == .reference_to_video;

        if (options.fps != null) try appendUnsupported(
            &warnings,
            arena,
            "fps",
            "xAI video models do not support custom FPS.",
        );
        if (options.seed != null) try appendUnsupported(
            &warnings,
            arena,
            "seed",
            "xAI video models do not support seed.",
        );
        if (options.n > 1) try appendUnsupported(
            &warnings,
            arena,
            "n",
            "xAI video models do not support generating multiple videos per call. Only 1 video will be generated.",
        );

        if (is_edit and options.duration_seconds != null) try appendUnsupported(
            &warnings,
            arena,
            "duration",
            "xAI video editing does not support custom duration.",
        );
        if (is_edit and options.aspect_ratio != null) try appendUnsupported(
            &warnings,
            arena,
            "aspectRatio",
            "xAI video editing does not support custom aspect ratio.",
        );
        if (is_edit and (xai_options.resolution != null or options.resolution != null)) try appendUnsupported(
            &warnings,
            arena,
            "resolution",
            "xAI video editing does not support custom resolution.",
        );
        if (is_extension and options.aspect_ratio != null) try appendUnsupported(
            &warnings,
            arena,
            "aspectRatio",
            "xAI video extension does not support custom aspect ratio.",
        );
        if (is_extension and (xai_options.resolution != null or options.resolution != null)) try appendUnsupported(
            &warnings,
            arena,
            "resolution",
            "xAI video extension does not support custom resolution.",
        );

        var body: std.json.ObjectMap = .empty;
        try putString(&body, arena, "model", self.model_id);
        if (options.prompt) |prompt| try putString(&body, arena, "prompt", prompt);

        if (!is_edit) if (options.duration_seconds) |duration| {
            try body.put(arena, "duration", jsonNumber(duration));
        };
        if (!is_edit and !is_extension) if (options.aspect_ratio) |aspect_ratio| {
            try putString(&body, arena, "aspect_ratio", aspect_ratio);
        };
        if (!is_edit and !is_extension) {
            if (xai_options.resolution) |resolution| {
                try putString(&body, arena, "resolution", resolution);
            } else if (options.resolution) |resolution| {
                if (mappedResolution(resolution)) |mapped| {
                    try putString(&body, arena, "resolution", mapped);
                } else {
                    try appendUnsupported(
                        &warnings,
                        arena,
                        "resolution",
                        try std.fmt.allocPrint(
                            arena,
                            "Unrecognized resolution \"{s}\". Use providerOptions.xai.resolution with \"480p\" or \"720p\" instead.",
                            .{resolution},
                        ),
                    );
                }
            }
        }

        if (is_edit or is_extension) if (xai_options.video_url) |video_url| {
            var video: std.json.ObjectMap = .empty;
            try putString(&video, arena, "url", video_url);
            try body.put(arena, "video", .{ .object = video });
        };

        if (resolveStartImage(options)) |start_image| {
            if (isVideoFile(start_image)) {
                try appendUnsupported(
                    &warnings,
                    arena,
                    if (firstFrameImage(options) != null) "frameImages" else "image",
                    "xAI does not accept a video as a start/frame image. The video was ignored. Use providerOptions.xai.mode \"extend-video\" to continue from a video instead.",
                );
            } else {
                var image: std.json.ObjectMap = .empty;
                try putString(&image, arena, "url", try fileToXaiUrl(arena, start_image));
                try body.put(arena, "image", .{ .object = image });
            }
        }

        if (lastFrameImage(options)) |last_frame| {
            try appendUnsupported(
                &warnings,
                arena,
                "frameImages",
                if (isVideoFile(last_frame))
                    "xAI does not accept a video as a start/frame image. The video last frame was ignored. Use providerOptions.xai.mode \"extend-video\" to continue from a video instead."
                else
                    "xAI video models do not support last_frame. Use providerOptions.xai.mode \"extend-video\" to continue from a video's last frame. The last frame image was ignored.",
            );
        }

        if (has_reference_images) {
            if (options.input_references) |references| {
                if (references.len != 0) {
                    var reference_images = std.json.Array.init(arena);
                    for (references) |reference| {
                        if (isVideoFile(reference)) {
                            try appendUnsupported(
                                &warnings,
                                arena,
                                "inputReferences",
                                "xAI reference-to-video accepts image references only. The video reference was ignored. Use providerOptions.xai.mode \"extend-video\" to continue from a video.",
                            );
                            continue;
                        }
                        var item: std.json.ObjectMap = .empty;
                        try putString(&item, arena, "url", try fileToXaiUrl(arena, reference));
                        try reference_images.append(.{ .object = item });
                    }
                    try body.put(arena, "reference_images", .{ .array = reference_images });
                } else if (xai_options.reference_image_urls) |urls| {
                    try putReferenceUrls(&body, arena, urls);
                }
            } else if (xai_options.reference_image_urls) |urls| {
                try putReferenceUrls(&body, arena, urls);
            }
        }

        if (options.input_references) |references| if (references.len != 0 and !has_reference_images) {
            try appendUnsupported(
                &warnings,
                arena,
                "inputReferences",
                "xAI only supports inputReferences for reference-to-video generation. The reference images were ignored.",
            );
        };

        var unknown_iterator = xai_options.unknown.iterator();
        while (unknown_iterator.next()) |entry| {
            try body.put(
                arena,
                try arena.dupe(u8, entry.key_ptr.*),
                try provider_utils.cloneJsonValue(arena, entry.value_ptr.*),
            );
        }

        const endpoint_name: []const u8 = if (is_edit)
            "edits"
        else if (is_extension)
            "extensions"
        else
            "generations";
        const create_url = try std.fmt.allocPrint(arena, "{s}/videos/{s}", .{ self.config.base_url, endpoint_name });
        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, .{ .object = body });
        const create_headers = try self.resolveHeaders(arena, options.headers, diag);
        const create_result = try provider_utils.postJsonToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = create_url, .headers = create_headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = xaiFailureResponseHandler(),
            },
            diag,
        );
        const request_id = try requestId(arena, create_result.value, diag);
        const poll_url = try std.fmt.allocPrint(arena, "{s}/videos/{s}", .{ self.config.base_url, request_id });
        const poll_started = std.Io.Timestamp.now(io, .real);
        var poll_arena_state = std.heap.ArenaAllocator.init(self.config.allocator);
        defer poll_arena_state.deinit();

        while (true) {
            try sleepMilliseconds(io, xai_options.poll_interval_ms);
            const elapsed_ms = elapsedMilliseconds(poll_started, std.Io.Timestamp.now(io, .real));
            if (elapsed_ms > xai_options.poll_timeout_ms) {
                const message = try std.fmt.allocPrint(
                    arena,
                    "Video generation timed out after {d}ms",
                    .{xai_options.poll_timeout_ms},
                );
                return jobFailure(
                    arena,
                    diag,
                    poll_url,
                    message,
                    "XAI_VIDEO_GENERATION_TIMEOUT",
                    &.{},
                    null,
                );
            }

            _ = poll_arena_state.reset(.retain_capacity);
            const poll_arena = poll_arena_state.allocator();
            const poll_headers = try self.resolveHeaders(poll_arena, options.headers, diag);
            const poll_result = try provider_utils.getFromApi(
                std.json.Value,
                io,
                poll_arena,
                self.config.transport,
                .{ .url = poll_url, .headers = poll_headers },
                .{
                    .success = provider_utils.jsonResponseHandler(std.json.Value),
                    .failure = xaiFailureResponseHandler(),
                },
                diag,
            );
            const status = try parseStatus(poll_arena, poll_result.value, diag);

            if (statusIs(status.status, "done") or (status.status == null and status.video_url != null)) {
                if (status.respect_moderation == false) {
                    return jobFailure(
                        arena,
                        diag,
                        poll_url,
                        "Video generation was blocked due to a content policy violation.",
                        "XAI_VIDEO_MODERATION_ERROR",
                        poll_result.response_headers,
                        poll_result.raw_body,
                    );
                }
                const video_url = status.video_url orelse return jobFailure(
                    arena,
                    diag,
                    poll_url,
                    "Video generation completed but no video URL was returned.",
                    "XAI_VIDEO_GENERATION_ERROR",
                    poll_result.response_headers,
                    poll_result.raw_body,
                );
                if (video_url.len == 0) return jobFailure(
                    arena,
                    diag,
                    poll_url,
                    "Video generation completed but no video URL was returned.",
                    "XAI_VIDEO_GENERATION_ERROR",
                    poll_result.response_headers,
                    poll_result.raw_body,
                );

                const videos = try arena.alloc(provider.VideoData, 1);
                videos[0] = .{ .url = .{
                    .url = try arena.dupe(u8, video_url),
                    .media_type = "video/mp4",
                } };
                return .{
                    .videos = videos,
                    .warnings = try warnings.toOwnedSlice(arena),
                    .response = .{
                        .timestamp_ms = response_timestamp_ms,
                        .model_id = try arena.dupe(u8, self.model_id),
                        .headers = try cloneHeaders(arena, poll_result.response_headers),
                    },
                    .provider_metadata = try buildMetadata(arena, request_id, video_url, status),
                };
            }

            if (statusIs(status.status, "expired")) return jobFailure(
                arena,
                diag,
                poll_url,
                "Video generation request expired.",
                "XAI_VIDEO_GENERATION_EXPIRED",
                poll_result.response_headers,
                poll_result.raw_body,
            );
            if (statusIs(status.status, "failed")) return jobFailure(
                arena,
                diag,
                poll_url,
                "Video generation failed.",
                "XAI_VIDEO_GENERATION_FAILED",
                poll_result.response_headers,
                poll_result.raw_body,
            );
        }
    }

    fn resolveHeaders(
        self: *const VideoModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
        diag: ?*provider.Diagnostics,
    ) provider.video_model.CallError![]const provider.Header {
        const api_key = try provider_utils.loadApiKey(.{
            .explicit = self.config.api_key,
            .env_var = "XAI_API_KEY",
            .description = "xAI",
            .env = self.config.env,
        }, arena, diag);
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key});
        const auth = [_]provider_utils.HeaderEntry{.{
            .name = "authorization",
            .value = authorization,
        }};
        const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |headers| headers.len else 0);
        if (call_headers) |headers| for (headers, call_entries) |header, *entry| {
            entry.* = .{ .name = header.name, .value = header.value };
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            &auth,
            self.config.headers.resolve(),
            call_entries,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(
            arena,
            combined,
            &.{"ai-sdk-zig/xai/" ++ provider_utils.version},
        );
    }
};

const Mode = enum {
    edit_video,
    extend_video,
    reference_to_video,
};

const ParsedOptions = struct {
    mode: ?Mode = null,
    poll_interval_ms: f64 = 5000,
    poll_timeout_ms: f64 = 600_000,
    resolution: ?[]const u8 = null,
    video_url: ?[]const u8 = null,
    reference_image_urls: ?[]const []const u8 = null,
    unknown: std.json.ObjectMap = .empty,
};

fn parseOptions(
    arena: Allocator,
    value: provider.ProviderOptions,
    diag: ?*provider.Diagnostics,
) provider.video_model.CallError!ParsedOptions {
    var result: ParsedOptions = .{};
    const root = switch (value) {
        .object => |object| object,
        .null => return result,
        else => return invalidArgument(diag, "providerOptions", "providerOptions must be a JSON object"),
    };
    const namespace = root.get("xai") orelse return result;
    if (namespace == .null) return result;
    if (namespace != .object) return invalidArgument(diag, "providerOptions.xai", "providerOptions.xai must be a JSON object");

    var iterator = namespace.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const item = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "mode")) {
            result.mode = try parseMode(item, diag);
        } else if (std.mem.eql(u8, name, "pollIntervalMs")) {
            if (item != .null) result.poll_interval_ms = try positiveNumber(item, diag, name);
        } else if (std.mem.eql(u8, name, "pollTimeoutMs")) {
            if (item != .null) result.poll_timeout_ms = try positiveNumber(item, diag, name);
        } else if (std.mem.eql(u8, name, "resolution")) {
            if (item != .null) {
                if (item != .string or
                    (!std.mem.eql(u8, item.string, "480p") and !std.mem.eql(u8, item.string, "720p")))
                {
                    return invalidArgument(diag, name, "providerOptions.xai.resolution must be '480p' or '720p'");
                }
                result.resolution = item.string;
            }
        } else if (std.mem.eql(u8, name, "videoUrl")) {
            if (item != .null) result.video_url = try nonEmptyString(item, diag, name);
        } else if (std.mem.eql(u8, name, "referenceImageUrls")) {
            if (item != .null) result.reference_image_urls = try referenceImageUrls(arena, item, diag);
        } else {
            try result.unknown.put(
                arena,
                try arena.dupe(u8, name),
                try provider_utils.cloneJsonValue(arena, item),
            );
        }
    }
    return result;
}

fn parseMode(value: std.json.Value, diag: ?*provider.Diagnostics) provider.Error!?Mode {
    if (value == .null) return invalidArgument(diag, "mode", "providerOptions.xai.mode must be a string");
    if (value != .string) return invalidArgument(diag, "mode", "providerOptions.xai.mode must be a string");
    if (std.mem.eql(u8, value.string, "edit-video")) return .edit_video;
    if (std.mem.eql(u8, value.string, "extend-video")) return .extend_video;
    if (std.mem.eql(u8, value.string, "reference-to-video")) return .reference_to_video;
    return invalidArgument(diag, "mode", "providerOptions.xai.mode is unsupported");
}

fn positiveNumber(value: std.json.Value, diag: ?*provider.Diagnostics, name: []const u8) provider.Error!f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return invalidArgument(diag, name, "xAI polling options must be positive numbers"),
    };
    if (!std.math.isFinite(number) or number <= 0 or number > @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
        return invalidArgument(diag, name, "xAI polling options must be positive finite numbers");
    }
    return number;
}

fn nonEmptyString(value: std.json.Value, diag: ?*provider.Diagnostics, name: []const u8) provider.Error![]const u8 {
    if (value != .string or value.string.len == 0) return invalidArgument(diag, name, "xAI video URL values must be non-empty strings");
    return value.string;
}

fn referenceImageUrls(
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.video_model.CallError![]const []const u8 {
    if (value != .array or value.array.items.len == 0 or value.array.items.len > 7) {
        return invalidArgument(diag, "referenceImageUrls", "providerOptions.xai.referenceImageUrls must contain 1 through 7 URLs");
    }
    const result = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, result) |item, *destination| {
        destination.* = try nonEmptyString(item, diag, "referenceImageUrls");
    }
    return result;
}

fn resolveMode(options: *const provider.VideoCallOptions, xai: ParsedOptions) ?Mode {
    if (xai.mode) |mode| return mode;
    if (xai.video_url != null) return .edit_video;
    const has_frames = if (options.frame_images) |images| images.len != 0 else false;
    const has_input_references = if (options.input_references) |references| references.len != 0 else false;
    const has_legacy_references = if (xai.reference_image_urls) |references| references.len != 0 else false;
    if (!has_frames and (has_input_references or has_legacy_references)) return .reference_to_video;
    return null;
}

fn firstFrameImage(options: *const provider.VideoCallOptions) ?provider.VideoFile {
    const frames = options.frame_images orelse return null;
    for (frames) |frame| if (frame.frame_type == .first_frame) return frame.image;
    return null;
}

fn lastFrameImage(options: *const provider.VideoCallOptions) ?provider.VideoFile {
    const frames = options.frame_images orelse return null;
    for (frames) |frame| if (frame.frame_type == .last_frame) return frame.image;
    return null;
}

fn resolveStartImage(options: *const provider.VideoCallOptions) ?provider.VideoFile {
    return firstFrameImage(options) orelse options.image;
}

fn isVideoFile(file: provider.VideoFile) bool {
    const media_type = switch (file) {
        .file => |item| item.media_type,
        .url => |item| item.media_type orelse return false,
    };
    return std.mem.eql(u8, provider_utils.getTopLevelMediaType(media_type), "video");
}

fn fileToXaiUrl(arena: Allocator, file: provider.VideoFile) Allocator.Error![]const u8 {
    return switch (file) {
        .url => |item| arena.dupe(u8, item.url),
        .file => |item| blk: {
            const encoded = switch (item.data) {
                .bytes => |bytes| try provider_utils.encodeBase64(arena, bytes),
                .base64 => |base64| base64,
            };
            break :blk std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ item.media_type, encoded });
        },
    };
}

fn mappedResolution(resolution: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, resolution, "1280x720")) return "720p";
    if (std.mem.eql(u8, resolution, "854x480")) return "480p";
    if (std.mem.eql(u8, resolution, "640x480")) return "480p";
    return null;
}

fn putReferenceUrls(body: *std.json.ObjectMap, arena: Allocator, urls: []const []const u8) Allocator.Error!void {
    var reference_images = std.json.Array.init(arena);
    for (urls) |url| {
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "url", url);
        try reference_images.append(.{ .object = item });
    }
    try body.put(arena, "reference_images", .{ .array = reference_images });
}

fn requestId(
    arena: Allocator,
    response: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.video_model.CallError![]const u8 {
    if (response == .object) if (response.object.get("request_id")) |value| {
        if (value == .string and value.string.len != 0) return value.string;
    };
    const response_json = try provider_utils.stringifyJsonValueAlloc(arena, response);
    const message = try std.fmt.allocPrint(
        arena,
        "No request_id returned from xAI API. Response: {s}",
        .{response_json},
    );
    return invalidResponse(arena, diag, message, response_json);
}

const ParsedStatus = struct {
    status: ?[]const u8 = null,
    video_url: ?[]const u8 = null,
    duration: ?std.json.Value = null,
    respect_moderation: ?bool = null,
    cost_in_usd_ticks: ?std.json.Value = null,
    progress: ?std.json.Value = null,
};

fn parseStatus(
    arena: Allocator,
    response: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.video_model.CallError!ParsedStatus {
    if (response != .object) return invalidResponseValue(arena, diag, "xAI video status response must be an object", response);
    var result: ParsedStatus = .{};
    if (response.object.get("status")) |value| switch (value) {
        .null => {},
        .string => |status| result.status = status,
        else => return invalidResponseValue(arena, diag, "xAI video status must be a string or null", response),
    };
    if (response.object.get("video")) |value| switch (value) {
        .null => {},
        .object => |video| {
            if (video.get("url")) |url| switch (url) {
                .string => |text| result.video_url = text,
                else => return invalidResponseValue(arena, diag, "xAI video URL must be a string", response),
            };
            if (video.get("duration")) |duration| {
                if (duration != .null and !isJsonNumber(duration)) return invalidResponseValue(arena, diag, "xAI video duration must be numeric", response);
                if (duration != .null) result.duration = duration;
            }
            if (video.get("respect_moderation")) |moderation| switch (moderation) {
                .null => {},
                .bool => |allowed| result.respect_moderation = allowed,
                else => return invalidResponseValue(arena, diag, "xAI moderation result must be a boolean", response),
            };
        },
        else => return invalidResponseValue(arena, diag, "xAI video status video must be an object or null", response),
    };
    if (response.object.get("usage")) |value| switch (value) {
        .null => {},
        .object => |usage| if (usage.get("cost_in_usd_ticks")) |cost| {
            if (cost != .null and !isJsonNumber(cost)) return invalidResponseValue(arena, diag, "xAI video cost must be numeric", response);
            if (cost != .null) result.cost_in_usd_ticks = cost;
        },
        else => return invalidResponseValue(arena, diag, "xAI video usage must be an object or null", response),
    };
    if (response.object.get("progress")) |progress| {
        if (progress != .null and !isJsonNumber(progress)) return invalidResponseValue(arena, diag, "xAI video progress must be numeric", response);
        if (progress != .null) result.progress = progress;
    }
    return result;
}

fn buildMetadata(
    arena: Allocator,
    request_id: []const u8,
    video_url: []const u8,
    status: ParsedStatus,
) Allocator.Error!provider.ProviderMetadata {
    var xai: std.json.ObjectMap = .empty;
    try putString(&xai, arena, "requestId", request_id);
    try putString(&xai, arena, "videoUrl", video_url);
    if (status.duration) |value| try xai.put(arena, "duration", try provider_utils.cloneJsonValue(arena, value));
    if (status.cost_in_usd_ticks) |value| try xai.put(arena, "costInUsdTicks", try provider_utils.cloneJsonValue(arena, value));
    if (status.progress) |value| try xai.put(arena, "progress", try provider_utils.cloneJsonValue(arena, value));
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "xai", .{ .object = xai });
    return .{ .object = root };
}

fn cloneHeaders(arena: Allocator, headers: []const provider.Header) Allocator.Error![]const provider.Header {
    const result = try arena.alloc(provider.Header, headers.len);
    for (headers, result) |header, *copy| {
        copy.* = .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        };
    }
    return result;
}

fn isJsonNumber(value: std.json.Value) bool {
    return value == .integer or value == .float or value == .number_string;
}

fn statusIs(actual: ?[]const u8, expected: []const u8) bool {
    return if (actual) |value| std.mem.eql(u8, value, expected) else false;
}

fn sleepMilliseconds(io: std.Io, milliseconds: f64) std.Io.Cancelable!void {
    const nanoseconds_float = @ceil(milliseconds * @as(f64, std.time.ns_per_ms));
    const nanoseconds: i96 = @intFromFloat(nanoseconds_float);
    return io.sleep(.fromNanoseconds(nanoseconds), .awake);
}

fn elapsedMilliseconds(start: std.Io.Timestamp, finish: std.Io.Timestamp) f64 {
    const elapsed_ns = finish.nanoseconds - start.nanoseconds;
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
}

fn timestampMilliseconds(io: std.Io, clock: std.Io.Clock) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, clock).nanoseconds, std.time.ns_per_ms));
}

fn jsonNumber(value: f64) std.json.Value {
    return .{ .float = value };
}

fn appendUnsupported(
    warnings: *std.ArrayList(provider.Warning),
    arena: Allocator,
    feature: []const u8,
    details: []const u8,
) Allocator.Error!void {
    try warnings.append(arena, .{ .unsupported = .{
        .feature = feature,
        .details = details,
    } });
}

fn putString(
    object: *std.json.ObjectMap,
    arena: Allocator,
    key: []const u8,
    value: []const u8,
) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn invalidArgument(
    diag: ?*provider.Diagnostics,
    parameter: []const u8,
    message: []const u8,
) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{ .invalid_argument = .{
        .message = message,
        .parameter = parameter,
    } });
    return error.InvalidArgumentError;
}

fn invalidResponseValue(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    message: []const u8,
    value: std.json.Value,
) provider.Error {
    const data_json = provider_utils.stringifyJsonValueAlloc(arena, value) catch null;
    return invalidResponse(arena, diag, message, data_json);
}

fn invalidResponse(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    message: []const u8,
    data_json: ?[]const u8,
) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .invalid_response_data = .{
        .message = message,
        .data_json = data_json,
    } });
    return error.InvalidResponseDataError;
}

fn jobFailure(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    url: []const u8,
    message: []const u8,
    code: []const u8,
    response_headers: []const provider.Header,
    response_body: ?[]const u8,
) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .response_headers = response_headers,
        .response_body = response_body,
        .is_retryable = false,
        .data_json = response_body,
        .cause_message = code,
    } });
    return error.APICallError;
}

fn xaiFailureResponseHandler() provider_utils.ErrorResponseHandler {
    return .{ .handle_fn = handleXaiFailure };
}

fn handleXaiFailure(
    _: ?*anyopaque,
    _: std.Io,
    arena: Allocator,
    response: *provider_utils.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    diag: ?*provider.Diagnostics,
) provider_utils.RequestError!void {
    const body = provider_utils.http_transport.readBodyWithLimit(
        arena,
        &response.body,
        provider_utils.api.default_max_response_size,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setApiFailure(arena, response, url, request_body_json, null, "Failed to read xAI error response", diag);
            return error.APICallError;
        },
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch null;
    const message = if (parsed) |value|
        try xaiErrorMessage(arena, value, response.status_text)
    else
        response.status_text;
    setApiFailure(arena, response, url, request_body_json, body, message, diag);
    return error.APICallError;
}

fn xaiErrorMessage(arena: Allocator, value: std.json.Value, fallback: []const u8) Allocator.Error![]const u8 {
    if (value != .object) return fallback;
    if (value.object.get("code")) |code| {
        if (value.object.get("error")) |error_value| if (error_value == .string) {
            return switch (code) {
                .string => |text| std.fmt.allocPrint(arena, "{s}: {s}", .{ text, error_value.string }),
                .integer => |number| std.fmt.allocPrint(arena, "{d}: {s}", .{ number, error_value.string }),
                else => fallback,
            };
        };
    }
    if (value.object.get("error")) |error_value| if (error_value == .object) {
        if (error_value.object.get("message")) |message| if (message == .string) return message.string;
    };
    return fallback;
}

fn setApiFailure(
    arena: Allocator,
    response: *const provider_utils.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    response_body: ?[]const u8,
    message: []const u8,
    diag: ?*provider.Diagnostics,
) void {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .status_code = response.status,
        .response_headers = response.headers,
        .response_body = response_body,
        .is_retryable = provider.isRetryableStatus(response.status),
        .request_body_json = request_body_json,
        .data_json = response_body,
    } });
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    return null;
}

fn makeModel(
    server: *const @import("test_support").MockServer,
    client: *provider_utils.HttpClientTransport,
    base_buffer: []u8,
) !VideoModel {
    return VideoModel.init("grok-imagine-video", .{
        .allocator = std.testing.allocator,
        .provider = "xai.video",
        .base_url = server.baseUrl(base_buffer),
        .api_key = "test-key",
        .env = .empty,
        .headers = .{ .static = &.{.{ .name = "x-static", .value = "configured" }} },
        .transport = client.transport(),
    }, null);
}

test "xAI video polls pending jobs to completion and preserves request and metadata" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();

    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"request_id\":\"req-123\"}" } });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"status\":\"pending\",\"model\":\"grok-imagine-video\"}" } });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"status\":\"pending\",\"model\":\"grok-imagine-video\"}" } });
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "poll-3" }},
        .body = .{ .text = "{\"status\":\"done\",\"video\":{\"url\":\"https://vidgen.x.ai/output/video-001.mp4\",\"duration\":5,\"respect_moderation\":true},\"usage\":{\"cost_in_usd_ticks\":42},\"progress\":100}" },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try makeModel(server, &client, &base_buffer);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"xai\":{\"pollIntervalMs\":1,\"pollTimeoutMs\":1000,\"customFlag\":true}}",
        .{},
    );
    const call_headers = [_]provider.Header{.{ .name = "x-call", .value = "call" }};
    const result = try model.videoModel().doGenerate(io, arena, &.{
        .prompt = "A chicken flying into the sunset",
        .n = 1,
        .aspect_ratio = "16:9",
        .resolution = "1280x720",
        .duration_seconds = 5,
        .image = .{ .url = .{ .url = "https://example.com/start.png" } },
        .provider_options = provider_options,
        .headers = &call_headers,
    }, null);

    try std.testing.expectEqual(1, result.videos.len);
    try std.testing.expectEqualStrings("https://vidgen.x.ai/output/video-001.mp4", result.videos[0].url.url);
    try std.testing.expectEqualStrings("video/mp4", result.videos[0].url.media_type);
    try std.testing.expectEqualStrings("poll-3", recordedHeader(result.response.headers.?, "x-request-id").?);
    const metadata = result.provider_metadata.?.object.get("xai").?.object;
    try std.testing.expectEqualStrings("req-123", metadata.get("requestId").?.string);
    try std.testing.expectEqual(42, metadata.get("costInUsdTicks").?.integer);
    try std.testing.expectEqual(100, metadata.get("progress").?.integer);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(4, requests.len);
    try std.testing.expectEqual(.POST, requests[0].method);
    try std.testing.expectEqualStrings("/videos/generations", requests[0].target);
    try std.testing.expectEqualStrings("/videos/req-123", requests[1].target);
    try std.testing.expectEqualStrings("/videos/req-123", requests[2].target);
    try std.testing.expectEqualStrings("/videos/req-123", requests[3].target);
    try std.testing.expectEqualStrings("Bearer test-key", recordedHeader(requests[0].headers, "authorization").?);
    try std.testing.expectEqualStrings("configured", recordedHeader(requests[0].headers, "x-static").?);
    try std.testing.expectEqualStrings("call", recordedHeader(requests[0].headers, "x-call").?);
    const request_body = try std.json.parseFromSliceLeaky(std.json.Value, arena, requests[0].body, .{});
    try std.testing.expectEqualStrings("grok-imagine-video", request_body.object.get("model").?.string);
    try std.testing.expectEqualStrings("720p", request_body.object.get("resolution").?.string);
    try std.testing.expectEqualStrings("16:9", request_body.object.get("aspect_ratio").?.string);
    try std.testing.expect(request_body.object.get("customFlag").?.bool);
    try std.testing.expectEqualStrings(
        "https://example.com/start.png",
        request_body.object.get("image").?.object.get("url").?.string,
    );
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "xAI video failed status returns terminal diagnostics" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"request_id\":\"req-failed\"}" } });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"status\":\"failed\",\"progress\":0}" } });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try makeModel(server, &client, &base_buffer);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"xai\":{\"pollIntervalMs\":1}}", .{});
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.APICallError, model.videoModel().doGenerate(io, arena, &.{
        .prompt = "fail",
        .n = 1,
        .provider_options = options,
    }, &diagnostics));
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings("Video generation failed.", diagnostics.payload.api_call.message);
    try std.testing.expectEqualStrings("XAI_VIDEO_GENERATION_FAILED", diagnostics.payload.api_call.cause_message.?);
}

test "xAI video selects edit and extension endpoints with mode-specific fields" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"request_id\":\"req-edit\"}" } });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"status\":\"done\",\"video\":{\"url\":\"https://example.com/edit.mp4\"}}" } });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"request_id\":\"req-extend\"}" } });
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"status\":\"done\",\"video\":{\"url\":\"https://example.com/extend.mp4\"}}" } });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try makeModel(server, &client, &base_buffer);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edit_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"xai\":{\"mode\":\"edit-video\",\"videoUrl\":\"https://example.com/source.mp4\",\"pollIntervalMs\":1,\"resolution\":\"720p\"}}",
        .{},
    );
    const edited = try model.videoModel().doGenerate(io, arena, &.{
        .prompt = "edit",
        .n = 1,
        .duration_seconds = 5,
        .aspect_ratio = "16:9",
        .resolution = "1280x720",
        .provider_options = edit_options,
    }, null);
    try std.testing.expectEqual(3, edited.warnings.len);

    const extension_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"xai\":{\"mode\":\"extend-video\",\"videoUrl\":\"https://example.com/source.mp4\",\"pollIntervalMs\":1}}",
        .{},
    );
    const extended = try model.videoModel().doGenerate(io, arena, &.{
        .prompt = "extend",
        .n = 1,
        .duration_seconds = 5,
        .aspect_ratio = "16:9",
        .resolution = "1280x720",
        .provider_options = extension_options,
    }, null);
    try std.testing.expectEqual(2, extended.warnings.len);

    const requests = server.recordedRequests();
    try std.testing.expectEqualStrings("/videos/edits", requests[0].target);
    try std.testing.expectEqualStrings("/videos/extensions", requests[2].target);
    const edit_body = try std.json.parseFromSliceLeaky(std.json.Value, arena, requests[0].body, .{});
    try std.testing.expectEqualStrings("https://example.com/source.mp4", edit_body.object.get("video").?.object.get("url").?.string);
    try std.testing.expect(edit_body.object.get("duration") == null);
    try std.testing.expect(edit_body.object.get("aspect_ratio") == null);
    try std.testing.expect(edit_body.object.get("resolution") == null);
    const extension_body = try std.json.parseFromSliceLeaky(std.json.Value, arena, requests[2].body, .{});
    try std.testing.expect(extension_body.object.get("duration") != null);
    try std.testing.expect(extension_body.object.get("aspect_ratio") == null);
    try std.testing.expect(extension_body.object.get("resolution") == null);
}

test "xAI video poll timeout uses elapsed wall clock" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"request_id\":\"req-timeout\"}" } });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try makeModel(server, &client, &base_buffer);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"xai\":{\"pollIntervalMs\":4,\"pollTimeoutMs\":1}}",
        .{},
    );
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const started = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.APICallError, model.videoModel().doGenerate(io, arena, &.{
        .prompt = "timeout",
        .n = 1,
        .provider_options = options,
    }, &diagnostics));
    const elapsed_ms = elapsedMilliseconds(started, std.Io.Timestamp.now(io, .awake));
    try std.testing.expect(elapsed_ms >= 1);
    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectEqualStrings("XAI_VIDEO_GENERATION_TIMEOUT", diagnostics.payload.api_call.cause_message.?);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.payload.api_call.message, "timed out") != null);
}

test "xAI video cancellation interrupts the polling sleep promptly" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{ .content_type = "application/json", .body = .{ .text = "{\"request_id\":\"req-cancel\"}" } });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try makeModel(server, &client, &base_buffer);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_options = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"xai\":{\"pollIntervalMs\":5000,\"pollTimeoutMs\":600000}}",
        .{},
    );
    const call_options: provider.VideoCallOptions = .{
        .prompt = "cancel",
        .n = 1,
        .provider_options = provider_options,
    };
    const Context = struct {
        model: *VideoModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.VideoCallOptions,

        fn run(self: *@This()) provider.video_model.CallError!provider.VideoResult {
            return self.model.doGenerate(self.io, self.arena, self.options, null);
        }
    };
    var context: Context = .{ .model = &model, .io = io, .arena = arena, .options = &call_options };
    var future = io.concurrent(Context.run, .{&context}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    for (0..250) |_| {
        if (server.recordedRequests().len != 0) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try io.sleep(.fromMilliseconds(10), .awake);
    const cancel_started = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    const cancel_elapsed_ms = elapsedMilliseconds(cancel_started, std.Io.Timestamp.now(io, .awake));
    try std.testing.expect(cancel_elapsed_ms < 250);
    try std.testing.expectEqual(1, server.recordedRequests().len);
}
