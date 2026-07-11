const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const providers = @import("providers.zig");
const result_api = @import("result.zig");
const runtime_api = @import("runtime.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const ImageOptions = struct {
    prompt: []const u8,
    n: u32 = 1,
    max_images_per_call: ?u32 = null,
    size: ?[]const u8 = null,
    aspect_ratio: ?[]const u8 = null,
    seed: ?i64 = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
};

const SpeechOptions = struct {
    text: []const u8,
    voice: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    speed: ?f64 = null,
    language: ?[]const u8 = null,
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
};

const TranscribeOptions = struct {
    provider_options: ?provider.ProviderOptions = null,
    max_retries: u32 = 2,
    headers: ?provider.Headers = null,
};

const ImageInfo = struct { media_type: []const u8 };

const ImageDocument = struct {
    images: []const ImageInfo,
    warnings: []const provider.Warning,
    responses: []const provider.ImageResponseInfo,
    provider_metadata: provider.ProviderMetadata,
    usage: provider.ImageUsage,
};

const SpeechDocument = struct {
    media_type: []const u8,
    format: []const u8,
    warnings: []const provider.Warning,
    responses: []const provider.SpeechResponseInfo,
    provider_metadata: provider.ProviderMetadata,
};

const TranscribeDocument = struct {
    text: []const u8,
    segments: []const provider.TranscriptionSegment,
    language: ?[]const u8,
    duration_seconds: ?f64,
    warnings: []const provider.Warning,
    responses: []const provider.TranscriptionResponseInfo,
    provider_metadata: provider.ProviderMetadata,
};

pub export fn ai_generate_image(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_image_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.imageModelFromHandle(value) else return runtime.invalid("image model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    model.retain();
    defer model.release();

    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const options = parseOptions(ImageOptions, arena, options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    if (options.prompt.len == 0) return runtime.invalid("prompt is required", "prompt");
    var generated = ai.generateImage(runtime.io(), allocator, .{
        .model = .{ .model = model.interface },
        .prompt = .{ .text = options.prompt },
        .n = options.n,
        .max_images_per_call = options.max_images_per_call,
        .size = options.size,
        .aspect_ratio = options.aspect_ratio,
        .seed = options.seed,
        .provider_options = options.provider_options,
        .max_retries = options.max_retries,
        .headers = options.headers,
        .diag = &diagnostics,
    }) catch |err| return runtime.fail(err, &diagnostics);
    defer generated.deinit();
    const result_arena = generated.arena_state.allocator();
    const blobs = result_arena.alloc(result_api.BlobSource, generated.images.len) catch |err|
        return runtime.fail(err, null);
    const image_info = result_arena.alloc(ImageInfo, generated.images.len) catch |err|
        return runtime.fail(err, null);
    for (generated.images, blobs, image_info) |*image, *blob, *info| {
        const bytes = image.bytes(result_arena) catch |err| return runtime.fail(err, &diagnostics);
        blob.* = .{ .bytes = bytes, .media_type = image.media_type };
        info.* = .{ .media_type = image.media_type };
    }
    const document: ImageDocument = .{
        .images = image_info,
        .warnings = generated.warnings,
        .responses = generated.responses,
        .provider_metadata = generated.provider_metadata,
        .usage = generated.usage,
    };
    const result = result_api.create(runtime, document, "", "", generated.usage.total_tokens orelse 0, blobs) catch |err|
        return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

pub export fn ai_generate_speech(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_speech_model,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.speechModelFromHandle(value) else return runtime.invalid("speech model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    model.retain();
    defer model.release();

    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const options = parseOptions(SpeechOptions, arena, options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    if (options.text.len == 0) return runtime.invalid("text is required", "text");
    var generated = ai.generateSpeech(runtime.io(), allocator, .{
        .model = .{ .model = model.interface },
        .text = options.text,
        .voice = options.voice,
        .output_format = options.output_format,
        .instructions = options.instructions,
        .speed = options.speed,
        .language = options.language,
        .provider_options = options.provider_options,
        .max_retries = options.max_retries,
        .headers = options.headers,
        .diag = &diagnostics,
    }) catch |err| return runtime.fail(err, &diagnostics);
    defer generated.deinit();
    const result_arena = generated.arena_state.allocator();
    const bytes = generated.audio.bytes(result_arena) catch |err| return runtime.fail(err, &diagnostics);
    const document: SpeechDocument = .{
        .media_type = generated.audio.media_type,
        .format = generated.audio.format,
        .warnings = generated.warnings,
        .responses = generated.responses,
        .provider_metadata = generated.provider_metadata,
    };
    const blobs = [_]result_api.BlobSource{.{
        .bytes = bytes,
        .media_type = generated.audio.media_type,
    }};
    const result = result_api.create(runtime, document, "", "", 0, &blobs) catch |err|
        return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

pub export fn ai_transcribe(
    runtime_handle: ?*types.ai_runtime,
    model_handle: ?*types.ai_transcription_model,
    audio_ptr: [*c]const u8,
    audio_len: usize,
    options_json: [*c]const u8,
    options_json_len: usize,
    out: [*c]?*types.ai_result,
) types.Status {
    if (out == null) return .invalid_argument;
    out.* = null;
    const runtime = runtime_api.optionalFromHandle(runtime_handle) orelse return .invalid_argument;
    const model = if (model_handle) |value| providers.transcriptionModelFromHandle(value) else return runtime.invalid("transcription model is required", "model");
    if (model.owner.runtime != runtime) return runtime.invalid("model belongs to a different runtime", "model");
    const audio = providers.requiredSlice(audio_ptr, audio_len) catch
        return runtime.invalid("audio bytes are required", "audio");
    model.retain();
    defer model.release();

    const allocator = runtime.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = provider.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const options = parseOptions(TranscribeOptions, arena, options_json, options_json_len, &diagnostics) catch |err|
        return runtime.fail(err, &diagnostics);
    var generated = ai.transcribe(runtime.io(), allocator, .{
        .model = .{ .model = model.interface },
        .audio = .{ .data = .{ .bytes = audio } },
        .provider_options = options.provider_options,
        .max_retries = options.max_retries,
        .headers = options.headers,
        .diag = &diagnostics,
    }) catch |err| return runtime.fail(err, &diagnostics);
    defer generated.deinit();
    const document: TranscribeDocument = .{
        .text = generated.text,
        .segments = generated.segments,
        .language = generated.language,
        .duration_seconds = generated.duration_seconds,
        .warnings = generated.warnings,
        .responses = generated.responses,
        .provider_metadata = generated.provider_metadata,
    };
    const result = result_api.create(runtime, document, generated.text, "", 0, &.{}) catch |err|
        return runtime.fail(err, null);
    out.* = @ptrCast(result);
    return .ok;
}

fn parseOptions(
    comptime T: type,
    arena: Allocator,
    ptr: [*c]const u8,
    len: usize,
    diagnostics: *provider.Diagnostics,
) provider.CallError!T {
    const text = providers.optionalSlice(ptr, len) catch {
        setInvalid(diagnostics, "optionsJson pointer is null", "optionsJson");
        return error.InvalidArgumentError;
    };
    const source = if (text.len == 0) "{}" else text;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setInvalid(diagnostics, "optionsJson is not valid JSON", "optionsJson");
            return error.InvalidArgumentError;
        },
    };
    return provider.wire.parse(T, arena, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setInvalid(diagnostics, "optionsJson does not match media options", "optionsJson");
            return error.InvalidArgumentError;
        },
    };
}

fn setInvalid(diagnostics: *provider.Diagnostics, message: []const u8, parameter: []const u8) void {
    provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .invalid_argument = .{
        .message = message,
        .parameter = parameter,
    } });
}
