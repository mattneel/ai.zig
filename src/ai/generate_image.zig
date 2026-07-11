//! `generateImage` orchestration over ImageModel V4.

const std = @import("std");
const builtin = @import("builtin");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const generated_file = @import("generated_file.zig");
const logger = @import("logger.zig");
const media_data = @import("media_data.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

pub const GenerateImagePrompt = union(enum) {
    text: []const u8,
    images: ImagePrompt,

    pub const ImagePrompt = struct {
        images: []const media_data.DataContent,
        text: ?[]const u8 = null,
        mask: ?media_data.DataContent = null,
    };
};

pub const GenerateImageOptions = struct {
    model: registry.ImageModelRef,
    prompt: GenerateImagePrompt,
    n: u32 = 1,
    max_images_per_call: ?u32 = null,
    size: ?[]const u8 = null,
    aspect_ratio: ?[]const u8 = null,
    seed: ?i64 = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
    diag: ?*provider.Diagnostics = null,
};

pub const GenerateImageResult = struct {
    arena_state: std.heap.ArenaAllocator,
    image: *generated_file.GeneratedFile,
    images: []generated_file.GeneratedFile,
    warnings: []const provider.Warning,
    responses: []const provider.ImageResponseInfo,
    provider_metadata: provider.ProviderMetadata,
    usage: provider.ImageUsage,

    pub fn deinit(self: *GenerateImageResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn generateImage(
    io: std.Io,
    gpa: Allocator,
    options: GenerateImageOptions,
) anyerror!GenerateImageResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = try registry.resolveImageModel(options.model, options.diag);
    const headers = try provider_utils.withUserAgentSuffix(
        arena,
        options.headers orelse &.{},
        &.{"ai/0.0.0"},
    );
    const max_per_call = options.max_images_per_call orelse model.maxImagesPerCall(io) orelse 1;
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
        const remaining = options.n - generated_before;
        job.* = Job.init(gpa, .{
            .model = model,
            .prompt = options.prompt,
            .n = @min(remaining, max_per_call),
            .size = options.size,
            .aspect_ratio = options.aspect_ratio,
            .seed = options.seed,
            .provider_options = options.provider_options orelse .{ .object = .empty },
            .headers = headers,
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

    var images: std.ArrayList(generated_file.GeneratedFile) = .empty;
    defer images.deinit(arena);
    var warnings: std.ArrayList(provider.Warning) = .empty;
    defer warnings.deinit(arena);
    var responses: std.ArrayList(provider.ImageResponseInfo) = .empty;
    defer responses.deinit(arena);
    var metadata: std.json.Value = .{ .object = .empty };
    var usage: provider.ImageUsage = .{};

    for (jobs) |*job| {
        if (job.err) |err| {
            media_data.copyDiagnostics(options.diag, &job.diagnostics);
            return err;
        }
        const result = job.result.?;
        for (result.images) |data| {
            const owned = switch (data) {
                .bytes => |bytes| provider.BinaryData{ .bytes = try arena.dupe(u8, bytes) },
                .base64 => |encoded| provider.BinaryData{ .base64 = try arena.dupe(u8, encoded) },
            };
            const media_type = (try provider_utils.detectMediaType(
                arena,
                switch (owned) {
                    .bytes => |bytes| .{ .bytes = bytes },
                    .base64 => |encoded| .{ .base64 = encoded },
                },
                "image",
            )) orelse "image/png";
            try images.append(arena, generated_file.GeneratedFile.init(owned, media_type));
        }
        for (result.warnings) |warning| {
            try warnings.append(arena, try media_data.cloneWarning(arena, warning));
        }
        try responses.append(arena, try cloneResponse(arena, result.response));
        if (result.usage) |reported| usage = addUsage(usage, reported);
        try media_data.mergeImageProviderMetadata(arena, &metadata, result.provider_metadata);
    }

    const owned_images = try images.toOwnedSlice(arena);
    const owned_warnings = try warnings.toOwnedSlice(arena);
    const owned_responses = try responses.toOwnedSlice(arena);
    logger.logWarnings(arena, .{
        .warnings = owned_warnings,
        .provider_name = model.provider(),
        .model = model.modelId(),
    });
    if (owned_images.len == 0) {
        const responses_json = provider.wire.stringifyAlloc(arena, owned_responses) catch "[]";
        provider.Diagnostics.set(options.diag, if (options.diag) |diag| diag.allocator else arena, .{
            .no_image_generated = .{
                .message = "No image generated.",
                .responses_json = responses_json,
            },
        });
        return error.NoImageGeneratedError;
    }

    return .{
        .arena_state = arena_state,
        .image = &owned_images[0],
        .images = owned_images,
        .warnings = owned_warnings,
        .responses = owned_responses,
        .provider_metadata = metadata,
        .usage = usage,
    };
}

const JobOptions = struct {
    model: provider.ImageModel,
    prompt: GenerateImagePrompt,
    n: u32,
    size: ?[]const u8,
    aspect_ratio: ?[]const u8,
    seed: ?i64,
    provider_options: provider.ProviderOptions,
    headers: provider.Headers,
    max_retries: u32,
};

const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    options: JobOptions,
    result: ?provider.ImageResult = null,
    err: ?anyerror = null,

    fn init(gpa: Allocator, options: JobOptions) Job {
        return .{
            .arena_state = .init(gpa),
            .diagnostics = .init(gpa),
            .options = options,
        };
    }

    fn deinit(self: *Job) void {
        self.diagnostics.deinit();
        self.arena_state.deinit();
    }

    fn run(self: *Job, io: std.Io) void {
        var attempt: Attempt = .{ .job = self };
        self.result = provider_utils.retry(
            provider.ImageResult,
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
    ) provider.image_model.CallError!provider.ImageResult {
        const job = self.job;
        const arena = job.arena_state.allocator();
        var files: ?[]const provider.ImageFile = null;
        var mask: ?provider.ImageFile = null;
        const prompt: ?[]const u8 = switch (job.options.prompt) {
            .text => |text| text,
            .images => |input| blk: {
                const normalized = try arena.alloc(provider.ImageFile, input.images.len);
                for (input.images, normalized) |content, *destination| {
                    destination.* = try media_data.normalizeImageFile(arena, content, diag);
                }
                files = normalized;
                if (input.mask) |content| mask = try media_data.normalizeImageFile(arena, content, diag);
                break :blk input.text;
            },
        };
        return job.options.model.doGenerate(io, arena, &.{
            .prompt = prompt,
            .n = job.options.n,
            .size = job.options.size,
            .aspect_ratio = job.options.aspect_ratio,
            .seed = job.options.seed,
            .files = files,
            .mask = mask,
            .provider_options = job.options.provider_options,
            .headers = job.options.headers,
        }, diag);
    }
};

fn addUsage(left: provider.ImageUsage, right: provider.ImageUsage) provider.ImageUsage {
    return .{
        .input_tokens = addOptional(left.input_tokens, right.input_tokens),
        .output_tokens = addOptional(left.output_tokens, right.output_tokens),
        .total_tokens = addOptional(left.total_tokens, right.total_tokens),
    };
}

fn addOptional(left: ?u64, right: ?u64) ?u64 {
    if (left == null and right == null) return null;
    return (left orelse 0) +| (right orelse 0);
}

fn cloneResponse(arena: Allocator, value: provider.ImageResponseInfo) Allocator.Error!provider.ImageResponseInfo {
    return .{
        .timestamp_ms = value.timestamp_ms,
        .model_id = try arena.dupe(u8, value.model_id),
        .headers = try media_data.cloneHeaders(arena, value.headers),
    };
}

fn invalidMaximum(diag: ?*provider.Diagnostics) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{
            .message = "maxImagesPerCall must be greater than zero",
            .parameter = "maxImagesPerCall",
        },
    });
    return error.InvalidArgumentError;
}

test "generateImage fans out with per-call retries and merges usage and metadata" {
    const Mock = struct {
        calls_one: std.atomic.Value(u32) = .init(0),
        calls_two: std.atomic.Value(u32) = .init(0),

        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "image";
        }
        fn maximum(_: *anyopaque, _: std.Io) ?u32 {
            return 2;
        }
        fn generate(
            raw: *anyopaque,
            _: std.Io,
            arena: Allocator,
            call_options: *const provider.ImageCallOptions,
            diag: ?*provider.Diagnostics,
        ) provider.image_model.CallError!provider.ImageResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const counter = if (call_options.n == 1) &self.calls_one else &self.calls_two;
            const call = counter.fetchAdd(1, .monotonic);
            if (call == 0) {
                provider.Diagnostics.set(diag, diag.?.allocator, .{ .api_call = .{
                    .message = "temporary",
                    .url = "https://example.test/images",
                    .is_retryable = true,
                } });
                return error.APICallError;
            }
            const images = try arena.alloc(provider.ImageData, call_options.n);
            for (images) |*image| image.* = .{ .base64 = "iVBORw==" };
            var image_metadata = std.json.Array.init(arena);
            for (0..call_options.n) |_| try image_metadata.append(.null);
            var provider_metadata: std.json.ObjectMap = .empty;
            try provider_metadata.put(arena, "images", .{ .array = image_metadata });
            try provider_metadata.put(arena, "ignored", .{ .string = "not-image-metadata" });
            var metadata: std.json.ObjectMap = .empty;
            try metadata.put(arena, "mock", .{ .object = provider_metadata });
            return .{
                .images = images,
                .warnings = &.{},
                .provider_metadata = .{ .object = metadata },
                .response = .{ .timestamp_ms = 1, .model_id = "image" },
                .usage = .{
                    .input_tokens = call_options.n,
                    .output_tokens = call_options.n * 2,
                    .total_tokens = call_options.n * 3,
                },
            };
        }
    };
    var mock: Mock = .{};
    const model: provider.ImageModel = .{ .ctx = &mock, .vtable = &.{
        .provider = Mock.providerName,
        .modelId = Mock.modelId,
        .maxImagesPerCall = Mock.maximum,
        .doGenerate = Mock.generate,
    } };
    var result = try generateImage(std.testing.io, std.testing.allocator, .{
        .model = .{ .model = model },
        .prompt = .{ .text = "three images" },
        .n = 3,
    });
    defer result.deinit();
    try std.testing.expectEqual(3, result.images.len);
    try std.testing.expectEqual(2, mock.calls_one.load(.monotonic));
    try std.testing.expectEqual(2, mock.calls_two.load(.monotonic));
    try std.testing.expectEqual(3, result.usage.input_tokens.?);
    try std.testing.expectEqual(9, result.usage.total_tokens.?);
    try std.testing.expectEqual(3, result.provider_metadata.object.get("mock").?.object.get("images").?.array.items.len);
    try std.testing.expect(result.provider_metadata.object.get("mock").?.object.get("ignored") == null);
}

test "generateImage reports response diagnostics when every call is empty" {
    const Mock = struct {
        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn modelId(_: *anyopaque) []const u8 {
            return "empty";
        }
        fn maximum(_: *anyopaque, _: std.Io) ?u32 {
            return 1;
        }
        fn generate(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: *const provider.ImageCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.image_model.CallError!provider.ImageResult {
            return .{
                .images = &.{},
                .warnings = &.{},
                .response = .{ .timestamp_ms = 7, .model_id = "empty" },
            };
        }
    };
    var marker: u8 = 0;
    const model: provider.ImageModel = .{ .ctx = &marker, .vtable = &.{
        .provider = Mock.providerName,
        .modelId = Mock.modelId,
        .maxImagesPerCall = Mock.maximum,
        .doGenerate = Mock.generate,
    } };
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.NoImageGeneratedError, generateImage(
        std.testing.io,
        std.testing.allocator,
        .{ .model = .{ .model = model }, .prompt = .{ .text = "none" }, .diag = &diagnostics },
    ));
    try std.testing.expect(diagnostics.payload == .no_image_generated);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.payload.no_image_generated.responses_json.?, "empty") != null);
}
