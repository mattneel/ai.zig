const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const api = @import("api.zig");
const config_api = @import("config.zig");

const Allocator = std.mem.Allocator;
const max_provider_id_len = 1024;

pub const ImageModel = struct {
    model_id: []const u8,
    config: config_api.Config,
    provider_id_buffer: [max_provider_id_len]u8 = undefined,
    provider_id_len: usize = 0,

    pub fn init(
        model_id: []const u8,
        config: config_api.Config,
        diag: ?*provider.Diagnostics,
    ) provider.Error!ImageModel {
        if (model_id.len == 0) return invalidArgument(diag, "modelId", "OpenAI image model id is required");
        if (config.provider_name.len == 0) return invalidArgument(diag, "name", "OpenAI provider name is required");

        var result: ImageModel = .{ .model_id = model_id, .config = config };
        const provider_id = std.fmt.bufPrint(&result.provider_id_buffer, "{s}.image", .{config.provider_name}) catch
            return invalidArgument(diag, "name", "OpenAI provider name is too long");
        result.provider_id_len = provider_id.len;
        return result;
    }

    pub fn imageModel(self: *ImageModel) provider.ImageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider.ImageModel.VTable = .{
        .provider = vProvider,
        .modelId = vModelId,
        .maxImagesPerCall = vMaxImagesPerCall,
        .doGenerate = vDoGenerate,
    };

    fn fromRaw(raw: *anyopaque) *ImageModel {
        return @ptrCast(@alignCast(raw));
    }

    fn vProvider(raw: *anyopaque) []const u8 {
        const self = fromRaw(raw);
        return self.provider_id_buffer[0..self.provider_id_len];
    }

    fn vModelId(raw: *anyopaque) []const u8 {
        return fromRaw(raw).model_id;
    }

    fn vMaxImagesPerCall(raw: *anyopaque, _: std.Io) ?u32 {
        return modelMaxImagesPerCall(fromRaw(raw).model_id);
    }

    fn vDoGenerate(
        raw: *anyopaque,
        io: std.Io,
        arena: Allocator,
        options: *const provider.ImageCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.image_model.CallError!provider.ImageResult {
        return fromRaw(raw).doGenerate(io, arena, options, diag);
    }

    fn doGenerate(
        self: *ImageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.ImageCallOptions,
        diag: ?*provider.Diagnostics,
    ) provider.image_model.CallError!provider.ImageResult {
        const warnings = try imageWarnings(arena, options.aspect_ratio, options.seed);
        const timestamp_ms = currentTimeMillis(io);
        const openai_options = try parseImageOptions(
            arena,
            options.provider_options,
            self.config.provider_options_name,
            diag,
        );
        if (options.files != null) {
            return self.doEdit(io, arena, options, warnings, timestamp_ms, openai_options, diag);
        }

        var body: std.json.ObjectMap = .empty;
        try putString(&body, arena, "model", self.model_id);
        if (options.prompt) |prompt| try putString(&body, arena, "prompt", prompt);
        try body.put(arena, "n", .{ .integer = options.n });
        if (options.size) |size| try putString(&body, arena, "size", size);
        if (openai_options.quality) |quality| try putString(&body, arena, "quality", quality);
        if (openai_options.style) |style| try putString(&body, arena, "style", style);
        if (openai_options.background) |background| try putString(&body, arena, "background", background);
        if (openai_options.moderation) |moderation| try putString(&body, arena, "moderation", moderation);
        if (openai_options.output_format) |output_format| try putString(&body, arena, "output_format", output_format);
        if (openai_options.output_compression) |output_compression| {
            try body.put(arena, "output_compression", .{ .integer = output_compression });
        }
        if (openai_options.user) |user| try putString(&body, arena, "user", user);
        if (!hasDefaultResponseFormat(self.model_id)) try putString(&body, arena, "response_format", "b64_json");

        const body_json = try provider_utils.stringifyJsonValueAlloc(arena, .{ .object = body });
        const url = try std.fmt.allocPrint(arena, "{s}/images/generations", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, options.headers, diag);
        const result = try provider_utils.postJsonToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .body_json = body_json },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );
        return mapResponse(
            arena,
            result.value,
            warnings,
            timestamp_ms,
            self.model_id,
            result.response_headers,
            diag,
        );
    }

    fn doEdit(
        self: *ImageModel,
        io: std.Io,
        arena: Allocator,
        options: *const provider.ImageCallOptions,
        warnings: []const provider.Warning,
        timestamp_ms: i64,
        openai_options: ImageOptions,
        diag: ?*provider.Diagnostics,
    ) provider.image_model.CallError!provider.ImageResult {
        var form_data = try provider_utils.FormData.initFromIo(arena, io);
        defer form_data.deinit();
        try form_data.appendText("model", self.model_id);
        if (options.prompt) |prompt| try form_data.appendText("prompt", prompt);

        const files = options.files.?;
        const multipart_files = try arena.alloc(provider_utils.MultipartFile, files.len);
        const jobs = try arena.alloc(MultipartFileJob, files.len);
        var initialized: usize = 0;
        defer for (jobs[0..initialized]) |*job| job.deinit();
        for (files, jobs) |file, *job| {
            job.* = MultipartFileJob.init(self.config.allocator, self, io, file);
            initialized += 1;
        }
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (jobs) |*job| {
            group.concurrent(io, MultipartFileJob.run, .{job}) catch |err| switch (err) {
                error.ConcurrencyUnavailable => group.async(io, MultipartFileJob.run, .{job}),
            };
        }
        try group.await(io);
        for (jobs, multipart_files) |*job, *output| {
            if (job.err) |err| {
                if (job.diagnostics.available) {
                    provider.Diagnostics.set(
                        diag,
                        diagnosticAllocator(diag, arena),
                        job.diagnostics.payload,
                    );
                }
                return err;
            }
            const result = job.result.?;
            output.* = .{
                .filename = try arena.dupe(u8, result.filename),
                .media_type = try arena.dupe(u8, result.media_type),
                .bytes = try arena.dupe(u8, result.bytes),
            };
        }
        try form_data.appendFileArray("image", multipart_files);
        if (options.mask) |mask| {
            const multipart_mask = try self.toMultipartFile(io, arena, mask, diag);
            try form_data.appendFile(
                "mask",
                multipart_mask.filename,
                multipart_mask.media_type,
                multipart_mask.bytes,
            );
        }

        try form_data.appendText("n", try std.fmt.allocPrint(arena, "{d}", .{options.n}));
        if (options.size) |size| try form_data.appendText("size", size);
        if (openai_options.quality) |quality| try form_data.appendText("quality", quality);
        if (openai_options.background) |background| try form_data.appendText("background", background);
        if (openai_options.output_format) |output_format| try form_data.appendText("output_format", output_format);
        if (openai_options.output_compression) |output_compression| {
            try form_data.appendText(
                "output_compression",
                try std.fmt.allocPrint(arena, "{d}", .{output_compression}),
            );
        }
        if (openai_options.input_fidelity) |input_fidelity| try form_data.appendText("input_fidelity", input_fidelity);
        if (openai_options.user) |user| try form_data.appendText("user", user);

        const url = try std.fmt.allocPrint(arena, "{s}/images/edits", .{self.config.base_url});
        const headers = try self.resolveHeaders(arena, options.headers, diag);
        const result = try provider_utils.postFormDataToApi(
            std.json.Value,
            io,
            arena,
            self.config.transport,
            .{ .url = url, .headers = headers, .form_data = &form_data },
            .{
                .success = provider_utils.jsonResponseHandler(std.json.Value),
                .failure = api.failedResponseHandler(),
            },
            diag,
        );
        return mapResponse(
            arena,
            result.value,
            warnings,
            timestamp_ms,
            self.model_id,
            result.response_headers,
            diag,
        );
    }

    fn toMultipartFile(
        self: *const ImageModel,
        io: std.Io,
        arena: Allocator,
        file: provider.ImageFile,
        diag: ?*provider.Diagnostics,
    ) provider.image_model.CallError!provider_utils.MultipartFile {
        return switch (file) {
            .file => |value| .{
                .filename = "blob",
                .media_type = value.media_type,
                .bytes = switch (value.data) {
                    .bytes => |bytes| bytes,
                    .base64 => |encoded| provider_utils.decodeBase64(arena, encoded) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return invalidImageData(arena, diag, "OpenAI image edit file contains invalid base64"),
                    },
                },
            },
            .url => |value| blk: {
                const downloaded = try provider_utils.download(
                    io,
                    arena,
                    self.config.transport,
                    value.url,
                    .{},
                    diag,
                );
                break :blk .{
                    .filename = "blob",
                    .media_type = downloaded.media_type orelse "application/octet-stream",
                    .bytes = downloaded.data,
                };
            },
        };
    }

    fn resolveHeaders(
        self: *const ImageModel,
        arena: Allocator,
        call_headers: ?provider.Headers,
        diag: ?*provider.Diagnostics,
    ) provider.image_model.CallError![]const provider.Header {
        const api_key = try provider_utils.loadApiKey(.{
            .explicit = self.config.api_key,
            .env_var = "OPENAI_API_KEY",
            .description = "OpenAI",
            .env = self.config.env,
        }, arena, diag);
        var configured_storage: [3]provider_utils.HeaderEntry = undefined;
        var configured_len: usize = 0;
        configured_storage[configured_len] = .{
            .name = "authorization",
            .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}),
        };
        configured_len += 1;
        if (self.config.organization) |organization| {
            configured_storage[configured_len] = .{ .name = "OpenAI-Organization", .value = organization };
            configured_len += 1;
        }
        if (self.config.project) |project| {
            configured_storage[configured_len] = .{ .name = "OpenAI-Project", .value = project };
            configured_len += 1;
        }
        const call_entries = try arena.alloc(provider_utils.HeaderEntry, if (call_headers) |value| value.len else 0);
        if (call_headers) |values| for (values, call_entries) |header, *entry| {
            entry.* = .{ .name = header.name, .value = header.value };
        };
        const lists = [_][]const provider_utils.HeaderEntry{
            configured_storage[0..configured_len],
            self.config.headers.resolve(),
            call_entries,
        };
        const combined = try provider_utils.combineHeaders(arena, &lists);
        return provider_utils.withUserAgentSuffix(
            arena,
            combined,
            &.{"ai-sdk-zig/openai/" ++ provider_utils.version},
        );
    }
};

const MultipartFileJob = struct {
    model: *const ImageModel,
    io: std.Io,
    file: provider.ImageFile,
    arena_state: std.heap.ArenaAllocator,
    diagnostics: provider.Diagnostics,
    result: ?provider_utils.MultipartFile = null,
    err: ?provider.image_model.CallError = null,

    fn init(
        allocator: Allocator,
        model: *const ImageModel,
        io: std.Io,
        file: provider.ImageFile,
    ) MultipartFileJob {
        return .{
            .model = model,
            .io = io,
            .file = file,
            .arena_state = .init(allocator),
            .diagnostics = .init(allocator),
        };
    }

    fn run(self: *MultipartFileJob) void {
        self.result = self.model.toMultipartFile(
            self.io,
            self.arena_state.allocator(),
            self.file,
            &self.diagnostics,
        ) catch |err| {
            self.err = err;
            return;
        };
    }

    fn deinit(self: *MultipartFileJob) void {
        self.diagnostics.deinit();
        self.arena_state.deinit();
    }
};

const ImageOptions = struct {
    quality: ?[]const u8 = null,
    background: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    output_compression: ?i64 = null,
    user: ?[]const u8 = null,
    style: ?[]const u8 = null,
    moderation: ?[]const u8 = null,
    input_fidelity: ?[]const u8 = null,
};

fn modelMaxImagesPerCall(model_id: []const u8) u32 {
    if (std.mem.eql(u8, model_id, "dall-e-3")) return 1;
    if (std.mem.eql(u8, model_id, "dall-e-2") or
        std.mem.eql(u8, model_id, "gpt-image-1") or
        std.mem.eql(u8, model_id, "gpt-image-1-mini") or
        std.mem.eql(u8, model_id, "gpt-image-1.5") or
        std.mem.eql(u8, model_id, "gpt-image-2") or
        std.mem.eql(u8, model_id, "chatgpt-image-latest")) return 10;
    return 1;
}

fn hasDefaultResponseFormat(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "chatgpt-image-") or
        std.mem.startsWith(u8, model_id, "gpt-image-1-mini") or
        std.mem.startsWith(u8, model_id, "gpt-image-1.5") or
        std.mem.startsWith(u8, model_id, "gpt-image-1") or
        std.mem.startsWith(u8, model_id, "gpt-image-2");
}

fn imageWarnings(
    arena: Allocator,
    aspect_ratio: ?[]const u8,
    seed: ?i64,
) Allocator.Error![]const provider.Warning {
    const count = @as(usize, @intFromBool(aspect_ratio != null)) + @as(usize, @intFromBool(seed != null));
    const warnings = try arena.alloc(provider.Warning, count);
    var index: usize = 0;
    if (aspect_ratio != null) {
        warnings[index] = .{ .unsupported = .{
            .feature = "aspectRatio",
            .details = "This model does not support aspect ratio. Use `size` instead.",
        } };
        index += 1;
    }
    if (seed != null) warnings[index] = .{ .unsupported = .{ .feature = "seed" } };
    return warnings;
}

fn parseImageOptions(
    arena: Allocator,
    value: provider.ProviderOptions,
    namespace: []const u8,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!ImageOptions {
    if (value == .null) return .{};
    if (value != .object) return invalidOptions(arena, diag, "providerOptions must be a JSON object");
    var result: ImageOptions = .{};
    if (value.object.get("openai")) |canonical| try applyImageOptions(arena, &result, canonical, diag);
    if (!std.mem.eql(u8, namespace, "openai")) {
        if (value.object.get(namespace)) |custom| try applyImageOptions(arena, &result, custom, diag);
    }
    return result;
}

fn applyImageOptions(
    arena: Allocator,
    result: *ImageOptions,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!void {
    if (value == .null) return;
    if (value != .object) return invalidOptions(arena, diag, "OpenAI image options must be an object");
    if (value.object.get("quality")) |item| result.quality = try optionalEnum(arena, item, "quality", &.{ "standard", "hd", "low", "medium", "high", "auto" }, diag);
    if (value.object.get("background")) |item| result.background = try optionalEnum(arena, item, "background", &.{ "transparent", "opaque", "auto" }, diag);
    if (value.object.get("outputFormat")) |item| result.output_format = try optionalEnum(arena, item, "outputFormat", &.{ "png", "jpeg", "webp" }, diag);
    if (value.object.get("outputCompression")) |item| {
        result.output_compression = try optionalInteger(arena, item, "outputCompression", 0, 100, diag);
    }
    if (value.object.get("user")) |item| result.user = try optionalString(arena, item, "user", diag);
    if (value.object.get("style")) |item| result.style = try optionalEnum(arena, item, "style", &.{ "vivid", "natural" }, diag);
    if (value.object.get("moderation")) |item| result.moderation = try optionalEnum(arena, item, "moderation", &.{ "auto", "low" }, diag);
    if (value.object.get("inputFidelity")) |item| result.input_fidelity = try optionalEnum(arena, item, "inputFidelity", &.{ "high", "low" }, diag);
}

fn optionalString(
    arena: Allocator,
    value: std.json.Value,
    field: []const u8,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => invalidOptionField(arena, diag, field, "must be a string"),
    };
}

fn optionalEnum(
    arena: Allocator,
    value: std.json.Value,
    field: []const u8,
    allowed: []const []const u8,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!?[]const u8 {
    const selected = try optionalString(arena, value, field, diag) orelse return null;
    for (allowed) |candidate| if (std.mem.eql(u8, selected, candidate)) return selected;
    return invalidOptionField(arena, diag, field, "contains an unsupported value");
}

fn optionalInteger(
    arena: Allocator,
    value: std.json.Value,
    field: []const u8,
    minimum: i64,
    maximum: i64,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!?i64 {
    if (value == .null) return null;
    const integer = switch (value) {
        .integer => |number| number,
        .float => |number| if (@floor(number) == number and number >= @as(f64, @floatFromInt(minimum)) and number <= @as(f64, @floatFromInt(maximum)))
            @as(i64, @intFromFloat(number))
        else
            return invalidOptionField(arena, diag, field, "must be an integer in range"),
        else => return invalidOptionField(arena, diag, field, "must be an integer in range"),
    };
    if (integer < minimum or integer > maximum) return invalidOptionField(arena, diag, field, "must be an integer in range");
    return integer;
}

fn mapResponse(
    arena: Allocator,
    response: std.json.Value,
    warnings: []const provider.Warning,
    timestamp_ms: i64,
    model_id: []const u8,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!provider.ImageResult {
    if (response != .object) return invalidResponse(arena, diag, "OpenAI image response must be an object");
    const data = response.object.get("data") orelse return invalidResponse(arena, diag, "OpenAI image response data is missing");
    if (data != .array) return invalidResponse(arena, diag, "OpenAI image response data must be an array");

    const images = try arena.alloc(provider.ImageData, data.array.items.len);
    var image_metadata = std.json.Array.init(arena);
    const created = response.object.get("created");
    const size = optionalResponseString(response.object, "size");
    const quality = optionalResponseString(response.object, "quality");
    const background = optionalResponseString(response.object, "background");
    const output_format = optionalResponseString(response.object, "output_format");
    const token_details = responseTokenDetails(response.object);

    for (data.array.items, images, 0..) |item, *image, index| {
        if (item != .object) return invalidResponse(arena, diag, "OpenAI image response item must be an object");
        const encoded = optionalResponseString(item.object, "b64_json") orelse
            return invalidResponse(arena, diag, "OpenAI image response item is missing b64_json");
        image.* = .{ .base64 = encoded };

        var metadata: std.json.ObjectMap = .empty;
        if (optionalResponseString(item.object, "revised_prompt")) |revised_prompt| {
            if (revised_prompt.len != 0) try putString(&metadata, arena, "revisedPrompt", revised_prompt);
        }
        if (created) |value| if (value != .null) try metadata.put(arena, "created", value);
        if (size) |value| try putString(&metadata, arena, "size", value);
        if (quality) |value| try putString(&metadata, arena, "quality", value);
        if (background) |value| try putString(&metadata, arena, "background", value);
        if (output_format) |value| try putString(&metadata, arena, "outputFormat", value);
        try appendDistributedTokenDetails(&metadata, arena, token_details, index, data.array.items.len, diag);
        try image_metadata.append(.{ .object = metadata });
    }

    var openai_metadata: std.json.ObjectMap = .empty;
    try openai_metadata.put(arena, "images", .{ .array = image_metadata });
    var provider_metadata: std.json.ObjectMap = .empty;
    try provider_metadata.put(arena, "openai", .{ .object = openai_metadata });

    return .{
        .images = images,
        .warnings = warnings,
        .provider_metadata = .{ .object = provider_metadata },
        .response = .{
            .timestamp_ms = timestamp_ms,
            .model_id = model_id,
            .headers = response_headers,
        },
        .usage = responseUsage(response.object),
    };
}

const TokenDetails = struct {
    image_tokens: ?u64 = null,
    text_tokens: ?u64 = null,
};

fn responseTokenDetails(root: std.json.ObjectMap) ?TokenDetails {
    const usage = root.get("usage") orelse return null;
    if (usage != .object) return null;
    const details = usage.object.get("input_tokens_details") orelse return null;
    if (details != .object) return null;
    return .{
        .image_tokens = optionalU64(details.object.get("image_tokens")),
        .text_tokens = optionalU64(details.object.get("text_tokens")),
    };
}

fn appendDistributedTokenDetails(
    metadata: *std.json.ObjectMap,
    arena: Allocator,
    details: ?TokenDetails,
    index: usize,
    total: usize,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!void {
    const value = details orelse return;
    if (value.image_tokens) |tokens| try putDistributedToken(metadata, arena, "imageTokens", tokens, index, total, diag);
    if (value.text_tokens) |tokens| try putDistributedToken(metadata, arena, "textTokens", tokens, index, total, diag);
}

fn putDistributedToken(
    metadata: *std.json.ObjectMap,
    arena: Allocator,
    key: []const u8,
    tokens: u64,
    index: usize,
    total: usize,
    diag: ?*provider.Diagnostics,
) provider.image_model.CallError!void {
    if (total == 0) return;
    const base = tokens / total;
    const distributed = if (index + 1 == total) tokens - base * (total - 1) else base;
    if (distributed > std.math.maxInt(i64)) return invalidResponse(arena, diag, "OpenAI image token details exceed JSON integer range");
    try metadata.put(arena, key, .{ .integer = @intCast(distributed) });
}

fn responseUsage(root: std.json.ObjectMap) ?provider.ImageUsage {
    const usage = root.get("usage") orelse return null;
    if (usage != .object) return null;
    return .{
        .input_tokens = optionalU64(usage.object.get("input_tokens")),
        .output_tokens = optionalU64(usage.object.get("output_tokens")),
        .total_tokens = optionalU64(usage.object.get("total_tokens")),
    };
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0 and @floor(number) == number) @intFromFloat(number) else null,
        else => null,
    };
}

fn optionalResponseString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn currentTimeMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn invalidResponse(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .invalid_response_data = .{ .message = message },
    });
    return error.InvalidResponseDataError;
}

fn invalidOptions(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .type_validation = .{ .message = message },
    });
    return error.TypeValidationError;
}

fn invalidImageData(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{
        .invalid_data_content = .{ .message = message },
    });
    return error.InvalidDataContentError;
}

fn invalidOptionField(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    field: []const u8,
    details: []const u8,
) provider.image_model.CallError {
    const message = std.fmt.allocPrint(arena, "OpenAI image option {s} {s}", .{ field, details }) catch
        return error.OutOfMemory;
    return invalidOptions(arena, diag, message);
}

fn invalidArgument(diag: ?*provider.Diagnostics, parameter: []const u8, message: []const u8) provider.Error {
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .invalid_argument = .{ .message = message, .parameter = parameter },
    });
    return error.InvalidArgumentError;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

fn recordedHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "OpenAI image generation maps settings warnings usage and per-image metadata" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "x-request-id", .value = "image-request" }},
        .body = .{ .text =
        \\{"created":1733837122,"data":[{"b64_json":"image-1","revised_prompt":"revised"},{"b64_json":"image-2"},{"b64_json":"image-3"}],"size":"1024x1024","quality":"high","background":"transparent","output_format":"webp","usage":{"input_tokens":30,"output_tokens":900,"total_tokens":930,"input_tokens_details":{"image_tokens":194,"text_tokens":28}}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ImageModel.init("dall-e-3", .{
        .allocator = allocator,
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = client.transport(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const openai_options = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"openai":{"quality":"high","background":"transparent","moderation":"low","outputFormat":"webp","outputCompression":80,"style":"vivid","user":"user-123"}}
    , .{});
    const result = try model.imageModel().doGenerate(io, arena_state.allocator(), &.{
        .prompt = "A cute baby sea otter",
        .n = 3,
        .size = "1024x1024",
        .aspect_ratio = "1:1",
        .seed = 123,
        .provider_options = openai_options,
    }, null);

    try std.testing.expectEqual(1, model.imageModel().maxImagesPerCall(io).?);
    try std.testing.expectEqual(3, result.images.len);
    try std.testing.expectEqualStrings("image-1", result.images[0].base64);
    try std.testing.expectEqual(2, result.warnings.len);
    try std.testing.expectEqualStrings("aspectRatio", result.warnings[0].unsupported.feature);
    try std.testing.expectEqualStrings(
        "This model does not support aspect ratio. Use `size` instead.",
        result.warnings[0].unsupported.details.?,
    );
    try std.testing.expectEqualStrings("seed", result.warnings[1].unsupported.feature);
    try std.testing.expectEqual(30, result.usage.?.input_tokens.?);
    try std.testing.expectEqualStrings("image-request", recordedHeader(result.response.headers.?, "x-request-id").?);
    const metadata_images = result.provider_metadata.?.object.get("openai").?.object.get("images").?.array.items;
    try std.testing.expectEqual(64, metadata_images[0].object.get("imageTokens").?.integer);
    try std.testing.expectEqual(64, metadata_images[1].object.get("imageTokens").?.integer);
    try std.testing.expectEqual(66, metadata_images[2].object.get("imageTokens").?.integer);
    try std.testing.expectEqual(9, metadata_images[0].object.get("textTokens").?.integer);
    try std.testing.expectEqual(10, metadata_images[2].object.get("textTokens").?.integer);

    const requests = server.recordedRequests();
    try std.testing.expectEqualStrings("/images/generations", requests[0].target);
    const request_body = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), requests[0].body, .{});
    try std.testing.expectEqualStrings("dall-e-3", request_body.object.get("model").?.string);
    try std.testing.expectEqualStrings("b64_json", request_body.object.get("response_format").?.string);
    try std.testing.expectEqualStrings("webp", request_body.object.get("output_format").?.string);
    try std.testing.expectEqual(80, request_body.object.get("output_compression").?.integer);
    try std.testing.expectEqualStrings("vivid", request_body.object.get("style").?.string);
    try std.testing.expectEqualStrings("low", request_body.object.get("moderation").?.string);
    try std.testing.expectEqualStrings("application/json", recordedHeader(requests[0].headers, "content-type").?);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI image max-per-call and response-format tables match upstream" {
    try std.testing.expectEqual(10, modelMaxImagesPerCall("dall-e-2"));
    try std.testing.expectEqual(10, modelMaxImagesPerCall("gpt-image-1.5"));
    try std.testing.expectEqual(1, modelMaxImagesPerCall("unknown-model"));
    try std.testing.expect(hasDefaultResponseFormat("gpt-image-1"));
    try std.testing.expect(hasDefaultResponseFormat("gpt-image-1.5-2025-12-16"));
    try std.testing.expect(hasDefaultResponseFormat("chatgpt-image-latest"));
    try std.testing.expect(!hasDefaultResponseFormat("dall-e-3"));
}

test "OpenAI image edit posts multi-image and mask multipart fields" {
    const test_support = @import("test_support");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const server = try test_support.MockServer.start(allocator, io);
    defer server.deinit();
    try server.enqueue(.{
        .content_type = "application/json",
        .body = .{ .text =
        \\{"created":1770935251,"background":"opaque","data":[{"b64_json":"edited-image"}],"output_format":"png","quality":"high","size":"1024x1024","usage":{"input_tokens":25,"output_tokens":0,"total_tokens":25}}
        },
    });

    var client = provider_utils.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    var base_buffer: [64]u8 = undefined;
    var model = try ImageModel.init("gpt-image-1", .{
        .allocator = allocator,
        .base_url = server.baseUrl(&base_buffer),
        .api_key = "test-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = client.transport(),
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const openai_options = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"openai":{"quality":"high","background":"transparent","inputFidelity":"high","outputFormat":"webp","outputCompression":80,"user":"user-123"}}
    , .{});
    const files = [_]provider.ImageFile{
        .{ .file = .{ .media_type = "image/png", .data = .{ .bytes = &.{ 0x89, 0x50, 0x4e, 0x47 } } } },
        .{ .file = .{ .media_type = "image/jpeg", .data = .{ .base64 = "/9j/4A==" } } },
        .{ .url = .{ .url = "data:image/gif;base64,R0lGODlh" } },
    };
    const result = try model.imageModel().doGenerate(io, arena, &.{
        .prompt = "Edit this image",
        .files = &files,
        .mask = .{ .file = .{ .media_type = "image/png", .data = .{ .bytes = "mask-data" } } },
        .n = 1,
        .size = "1024x1024",
        .provider_options = openai_options,
    }, null);

    try std.testing.expectEqualStrings("edited-image", result.images[0].base64);
    try std.testing.expectEqual(25, result.usage.?.input_tokens.?);
    const metadata = result.provider_metadata.?.object.get("openai").?.object.get("images").?.array.items[0].object;
    try std.testing.expectEqualStrings("opaque", metadata.get("background").?.string);
    try std.testing.expectEqualStrings("png", metadata.get("outputFormat").?.string);

    const requests = server.recordedRequests();
    try std.testing.expectEqual(1, requests.len);
    try std.testing.expectEqualStrings("/images/edits", requests[0].target);
    const content_type = recordedHeader(requests[0].headers, "content-type").?;
    try std.testing.expect(std.mem.startsWith(u8, content_type, "multipart/form-data; boundary=ai-zig-boundary-"));
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"model\"\r\n\r\ngpt-image-1\r\n") != null);
    try std.testing.expectEqual(3, std.mem.count(u8, requests[0].body, "name=\"image[]\"; filename=\"blob\""));
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"mask\"; filename=\"blob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "Content-Type: image/jpeg\r\n\r\n\xff\xd8\xff\xe0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "Content-Type: image/gif\r\n\r\nGIF89a\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"input_fidelity\"\r\n\r\nhigh\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[0].body, "name=\"output_compression\"\r\n\r\n80\r\n") != null);
    try std.testing.expectEqual(0, server.serveErrorCount());
}

test "OpenAI image edit overlaps independent URL downloads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const BarrierTransport = struct {
        active_downloads: std.atomic.Value(u32) = .init(0),
        saw_overlap: std.atomic.Value(bool) = .init(false),

        const BodyState = struct {
            reader: std.Io.Reader,

            fn deinit(_: *anyopaque, _: std.Io) void {}
        };

        fn request(
            raw: *anyopaque,
            request_io: std.Io,
            arena: Allocator,
            spec: provider_utils.RequestSpec,
            _: ?*provider.Diagnostics,
        ) provider_utils.RequestError!provider_utils.Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const is_download = spec.method == .GET;
            if (is_download) {
                const active = self.active_downloads.fetchAdd(1, .acq_rel) + 1;
                defer _ = self.active_downloads.fetchSub(1, .acq_rel);
                if (active >= 2) self.saw_overlap.store(true, .release);

                var attempts: usize = 0;
                while (!self.saw_overlap.load(.acquire) and attempts < 500) : (attempts += 1) {
                    try request_io.sleep(.fromMilliseconds(1), .awake);
                }
                if (!self.saw_overlap.load(.acquire)) return error.APICallError;
            }

            const body = if (is_download)
                "\x89PNG"
            else
                "{\"data\":[{\"b64_json\":\"edited\"}]}";
            const state = try arena.create(BodyState);
            state.* = .{ .reader = std.Io.Reader.fixed(body) };
            return .{
                .status = 200,
                .status_text = "OK",
                .headers = if (is_download)
                    &.{.{ .name = "content-type", .value = "image/png" }}
                else
                    &.{.{ .name = "content-type", .value = "application/json" }},
                .body = .{
                    .ctx = state,
                    .reader_ptr = &state.reader,
                    .deinit_fn = BodyState.deinit,
                },
            };
        }
    };

    var transport_state: BarrierTransport = .{};
    const transport: provider_utils.HttpTransport = .{
        .ctx = &transport_state,
        .vtable = &.{ .request = BarrierTransport.request },
    };
    var model = try ImageModel.init("gpt-image-1", .{
        .allocator = allocator,
        .base_url = "https://api.example.test/v1",
        .api_key = "test-key",
        .organization = null,
        .project = null,
        .env = .empty,
        .headers = .{ .static = &.{} },
        .transport = transport,
        .provider_name = "openai",
        .provider_options_name = "openai",
    }, null);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const files = [_]provider.ImageFile{
        .{ .url = .{ .url = "https://example.com/first.png" } },
        .{ .url = .{ .url = "https://example.com/second.png" } },
    };
    const result = try model.imageModel().doGenerate(io, arena_state.allocator(), &.{
        .prompt = "Edit concurrently",
        .files = &files,
        .n = 1,
        .provider_options = .{ .object = .empty },
    }, null);

    try std.testing.expect(transport_state.saw_overlap.load(.acquire));
    try std.testing.expectEqualStrings("edited", result.images[0].base64);
}
