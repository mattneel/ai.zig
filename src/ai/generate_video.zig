//! `generateVideo` orchestration over VideoModel V4.

const std = @import("std");
const builtin = @import("builtin");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const generated_file = @import("generated_file.zig");
const logger = @import("logger.zig");
const media_data = @import("media_data.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

pub const GenerateVideoPrompt = union(enum) {
    text: []const u8,
    image: ImagePrompt,

    pub const ImagePrompt = struct {
        image: media_data.DataContent,
        text: ?[]const u8 = null,
    };
};

pub const FrameImage = struct {
    image: media_data.DataContent,
    frame_type: provider.VideoFrameType,
};

pub const InputReference = union(enum) {
    data: media_data.DataContent,
    typed: Typed,

    pub const Typed = struct {
        data: media_data.DataContent,
        media_type: ?[]const u8 = null,
    };
};

pub const GenerateVideoOptions = struct {
    model: registry.VideoModelRef,
    prompt: GenerateVideoPrompt,
    n: u32 = 1,
    max_videos_per_call: ?u32 = null,
    aspect_ratio: ?[]const u8 = null,
    resolution: ?[]const u8 = null,
    duration_seconds: ?f64 = null,
    fps: ?f64 = null,
    seed: ?i64 = null,
    frame_images: ?[]const FrameImage = null,
    input_references: ?[]const InputReference = null,
    generate_audio: ?bool = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    download_transport: ?provider_utils.HttpTransport = null,
    download_options: provider_utils.DownloadOptions = .{},
    diag: ?*provider.Diagnostics = null,
};

pub const ResponseInfo = struct {
    timestamp_ms: i64,
    model_id: []const u8,
    headers: ?provider.Headers = null,
    provider_metadata: ?provider.ProviderMetadata = null,
};

pub const GenerateVideoResult = struct {
    arena_state: std.heap.ArenaAllocator,
    video: *generated_file.GeneratedFile,
    videos: []generated_file.GeneratedFile,
    warnings: []const provider.Warning,
    responses: []const ResponseInfo,
    provider_metadata: provider.ProviderMetadata,

    pub fn deinit(self: *GenerateVideoResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn generateVideo(
    io: std.Io,
    gpa: Allocator,
    options: GenerateVideoOptions,
) anyerror!GenerateVideoResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveVideoModel(options.model, options.diag);
    const headers = try provider_utils.withUserAgentSuffix(
        arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );
    var default_download_client: ?provider_utils.HttpClientTransport = if (options.download_transport == null)
        provider_utils.HttpClientTransport.init(gpa, io)
    else
        null;
    defer if (default_download_client) |*client| client.deinit();
    const download_transport = options.download_transport orelse default_download_client.?.transport();

    var prompt_text: ?[]const u8 = null;
    var prompt_image: ?provider.VideoFile = null;
    switch (options.prompt) {
        .text => |text| prompt_text = text,
        .image => |input| {
            prompt_text = input.text;
            prompt_image = try media_data.normalizeVideoFile(arena, input.image, true, null, options.diag);
        },
    }
    const normalized_frames = if (options.frame_images) |frames| blk: {
        const output = try arena.alloc(provider.VideoFrameImage, frames.len);
        for (frames, output) |frame, *destination| destination.* = .{
            .image = try media_data.normalizeVideoFile(arena, frame.image, true, null, options.diag),
            .frame_type = frame.frame_type,
        };
        break :blk output;
    } else null;
    const normalized_references = if (options.input_references) |references| blk: {
        const output = try arena.alloc(provider.VideoFile, references.len);
        for (references, output) |reference, *destination| destination.* = switch (reference) {
            .data => |content| try media_data.normalizeVideoFile(arena, content, false, null, options.diag),
            .typed => |typed| try media_data.normalizeVideoFile(
                arena,
                typed.data,
                false,
                typed.media_type,
                options.diag,
            ),
        };
        break :blk output;
    } else null;

    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    const frames_present = if (normalized_frames) |frames| frames.len != 0 else false;
    const references_present = if (normalized_references) |references| references.len != 0 else false;
    const effective_references = if (frames_present) null else normalized_references;
    if (frames_present and references_present) try warnings.append(arena, .{ .other = .{
        .message = try arena.dupe(u8, "inputReferences were ignored because frameImages were provided; " ++
            "frameImages and inputReferences cannot be combined."),
    } });
    var first_frame: ?provider.VideoFile = null;
    if (normalized_frames) |frames| for (frames) |frame| {
        if (frame.frame_type == .first_frame) {
            first_frame = frame.image;
            break;
        }
    };
    if (prompt_image != null and first_frame != null) try warnings.append(arena, .{ .other = .{
        .message = try arena.dupe(u8, "prompt.image was ignored because a first_frame frameImage was provided; " ++
            "the first_frame frameImage takes precedence as the start image."),
    } });
    const resolved_image = first_frame orelse prompt_image;

    const max_per_call = options.max_videos_per_call orelse model.maxVideosPerCall(io) orelse 1;
    if (max_per_call == 0) return invalidMaximum(options.diag);
    const call_count: usize = if (options.n == 0)
        0
    else
        @intCast((options.n + max_per_call - 1) / max_per_call);
    const jobs = try gpa.alloc(Job, call_count);
    defer gpa.free(jobs);
    var initialized: usize = 0;
    defer for (jobs[0..initialized]) |*job| job.deinit();
    for (jobs, 0..) |*job, index| {
        const generated_before: u32 = @intCast(index * @as(usize, max_per_call));
        job.* = Job.init(gpa, .{
            .model = model,
            .call_options = .{
                .prompt = prompt_text,
                .n = @min(options.n - generated_before, max_per_call),
                .aspect_ratio = options.aspect_ratio,
                .resolution = options.resolution,
                .duration_seconds = options.duration_seconds,
                .fps = options.fps,
                .seed = options.seed,
                .image = resolved_image,
                .frame_images = normalized_frames,
                .input_references = effective_references,
                .generate_audio = options.generate_audio,
                .provider_options = options.provider_options orelse .{ .object = .empty },
                .headers = headers,
            },
            .max_retries = options.max_retries,
        });
        initialized += 1;
    }
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (jobs) |*job| {
        group.concurrent(io, Job.run, .{ job, io }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => group.async(io, Job.run, .{ job, io }),
        };
    }
    try group.await(io);

    var videos: std.ArrayList(generated_file.GeneratedFile) = .empty;
    defer videos.deinit(arena);
    var responses: std.ArrayList(ResponseInfo) = .empty;
    defer responses.deinit(arena);
    var metadata: std.json.Value = .{ .object = .empty };
    for (jobs) |*job| {
        if (job.err) |err| {
            media_data.copyDiagnostics(options.diag, &job.diagnostics);
            return err;
        }
        const result = job.result.?;
        for (result.videos) |video| switch (video) {
            .url => |url_video| {
                const downloaded = try provider_utils.download(
                    io,
                    arena,
                    download_transport,
                    url_video.url,
                    options.download_options,
                    options.diag,
                );
                const media_type = usableMediaType(url_video.media_type) orelse
                    usableMediaType(downloaded.media_type orelse "") orelse
                    (try provider_utils.detectMediaType(arena, .{ .bytes = downloaded.data }, "video")) orelse
                    "video/mp4";
                try videos.append(arena, generated_file.GeneratedFile.initBytes(
                    try arena.dupe(u8, downloaded.data),
                    try arena.dupe(u8, media_type),
                ));
            },
            .base64 => |base64_video| try videos.append(arena, generated_file.GeneratedFile.initBase64(
                try arena.dupe(u8, base64_video.data),
                try arena.dupe(
                    u8,
                    if (base64_video.media_type.len == 0) "video/mp4" else base64_video.media_type,
                ),
            )),
            .bytes => |binary_video| {
                const bytes = try arena.dupe(u8, binary_video.data);
                const media_type = if (binary_video.media_type.len != 0)
                    binary_video.media_type
                else
                    (try provider_utils.detectMediaType(arena, .{ .bytes = bytes }, "video")) orelse "video/mp4";
                try videos.append(arena, generated_file.GeneratedFile.initBytes(
                    bytes,
                    try arena.dupe(u8, media_type),
                ));
            },
        };
        for (result.warnings) |warning| try warnings.append(arena, try media_data.cloneWarning(arena, warning));
        try responses.append(arena, .{
            .timestamp_ms = result.response.timestamp_ms,
            .model_id = try arena.dupe(u8, result.response.model_id),
            .headers = try media_data.cloneHeaders(arena, result.response.headers),
            .provider_metadata = if (result.provider_metadata) |value|
                try provider_utils.cloneJsonValue(arena, value)
            else
                null,
        });
        try media_data.mergeProviderMetadata(arena, &metadata, result.provider_metadata, "videos");
    }

    const owned_videos = try videos.toOwnedSlice(arena);
    const owned_warnings = try warnings.toOwnedSlice(arena);
    const owned_responses = try responses.toOwnedSlice(arena);
    if (owned_videos.len == 0) {
        const responses_json = provider.wire.stringifyAlloc(arena, owned_responses) catch "[]";
        provider.Diagnostics.set(options.diag, if (options.diag) |diag| diag.allocator else arena, .{
            .no_video_generated = .{
                .message = "No video generated.",
                .responses_json = responses_json,
            },
        });
        return error.NoVideoGeneratedError;
    }
    logger.logWarnings(arena, .{
        .warnings = owned_warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });
    return .{
        .arena_state = arena_state,
        .video = &owned_videos[0],
        .videos = owned_videos,
        .warnings = owned_warnings,
        .responses = owned_responses,
        .provider_metadata = metadata,
    };
}

const JobOptions = struct {
    model: provider.VideoModel,
    call_options: provider.VideoCallOptions,
    max_retries: u32,
};

const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    options: JobOptions,
    result: ?provider.VideoResult = null,
    err: ?anyerror = null,

    fn init(gpa: Allocator, options: JobOptions) Job {
        return .{ .arena_state = .init(gpa), .diagnostics = .init(gpa), .options = options };
    }
    fn deinit(self: *Job) void {
        self.diagnostics.deinit();
        self.arena_state.deinit();
    }
    fn run(self: *Job, io: std.Io) void {
        var attempt: Attempt = .{ .job = self };
        self.result = provider_utils.retry(
            provider.VideoResult,
            io,
            .{
                .max_retries = self.options.max_retries,
                .initial_delay_ms = if (builtin.is_test) 1 else 2000,
            },
            &attempt,
            Attempt.call,
            &self.diagnostics,
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

const Attempt = struct {
    job: *Job,
    fn call(
        self: *Attempt,
        io: std.Io,
        _: u32,
        diag: ?*provider.Diagnostics,
    ) provider.video_model.CallError!provider.VideoResult {
        return self.job.options.model.doGenerate(
            io,
            self.job.arena_state.allocator(),
            &self.job.options.call_options,
            diag,
        );
    }
};

fn usableMediaType(value: []const u8) ?[]const u8 {
    if (value.len == 0 or std.mem.eql(u8, value, "application/octet-stream")) return null;
    return value;
}

fn invalidMaximum(diag: ?*provider.Diagnostics) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{
            .message = "maxVideosPerCall must be greater than zero",
            .parameter = "maxVideosPerCall",
        },
    });
    return error.InvalidArgumentError;
}

test "generateVideo applies exact precedence warnings and batches calls" {
    logger.setWarningLogger(.disabled);
    defer logger.setWarningLogger(.default);
    const Mock = struct {
        calls: std.atomic.Value(u32) = .init(0),
        total_n: std.atomic.Value(u32) = .init(0),
        saw_references: std.atomic.Value(bool) = .init(false),

        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "video";
        }
        fn maximum(_: *anyopaque, _: std.Io) ?u32 {
            return 2;
        }
        fn generate(
            raw: *anyopaque,
            _: std.Io,
            arena: Allocator,
            options: *const provider.VideoCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.video_model.CallError!provider.VideoResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.calls.fetchAdd(1, .monotonic);
            _ = self.total_n.fetchAdd(options.n, .monotonic);
            self.saw_references.store(options.input_references != null, .monotonic);
            const videos = try arena.alloc(provider.VideoData, options.n);
            for (videos) |*video| video.* = .{ .base64 = .{ .data = "AAAA", .media_type = "video/mp4" } };
            return .{
                .videos = videos,
                .warnings = &.{},
                .response = .{ .timestamp_ms = 1, .model_id = "video" },
            };
        }
    };
    var mock: Mock = .{};
    const model: provider.VideoModel = .{ .ctx = &mock, .vtable = &.{
        .provider = Mock.providerName,
        .modelId = Mock.modelId,
        .maxVideosPerCall = Mock.maximum,
        .doGenerate = Mock.generate,
    } };
    var result = try generateVideo(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model },
        .prompt = .{ .image = .{ .text = "clip", .image = .{ .string = "https://example.test/prompt.png" } } },
        .n = 3,
        .frame_images = &.{.{
            .image = .{ .string = "https://example.test/first.png" },
            .frame_type = .first_frame,
        }},
        .input_references = &.{.{ .data = .{ .string = "https://example.test/ref.png" } }},
    });
    defer result.deinit();
    try std.testing.expectEqual(3, result.videos.len);
    try std.testing.expectEqual(2, mock.calls.load(.monotonic));
    try std.testing.expectEqual(3, mock.total_n.load(.monotonic));
    try std.testing.expect(!mock.saw_references.load(.monotonic));
    try std.testing.expectEqual(2, result.warnings.len);
    try std.testing.expectEqualStrings(
        "inputReferences were ignored because frameImages were provided; frameImages and inputReferences cannot be combined.",
        result.warnings[0].other.message,
    );
    try std.testing.expectEqualStrings(
        "prompt.image was ignored because a first_frame frameImage was provided; the first_frame frameImage takes precedence as the start image.",
        result.warnings[1].other.message,
    );
}

test "generateVideo URL download infers media type after octet-stream fallthrough" {
    const test_support = @import("test_support");
    const Mock = struct {
        url: []const u8,
        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "video";
        }
        fn maximum(_: *anyopaque, _: std.Io) ?u32 {
            return 1;
        }
        fn generate(
            raw: *anyopaque,
            _: std.Io,
            arena: Allocator,
            _: *const provider.VideoCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.video_model.CallError!provider.VideoResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const videos = try arena.alloc(provider.VideoData, 1);
            videos[0] = .{ .url = .{ .url = self.url, .media_type = "application/octet-stream" } };
            return .{ .videos = videos, .warnings = &.{}, .response = .{ .timestamp_ms = 1, .model_id = "video" } };
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/octet-stream",
        .body = .{ .text = &.{ 0, 0, 0, 0x18, 'f', 't', 'y', 'p' } },
    });
    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/video", .{server.baseUrl(&base_buffer)});
    var mock: Mock = .{ .url = url };
    const model: provider.VideoModel = .{ .ctx = &mock, .vtable = &.{
        .provider = Mock.providerName,
        .modelId = Mock.modelId,
        .maxVideosPerCall = Mock.maximum,
        .doGenerate = Mock.generate,
    } };
    var result = try generateVideo(io, allocator, .{
        .model = .{ .model = model },
        .prompt = .{ .text = "clip" },
        .download_transport = client.transport(),
        .download_options = .{ .allow_private_networks = true },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("video/mp4", result.video.media_type);
}
