const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;
const ParseError = provider.Error || Allocator.Error;

pub const LanguageOptions = struct {
    response_modalities: ?std.json.Value = null,
    thinking_config: ?std.json.Value = null,
    cached_content: ?[]const u8 = null,
    structured_outputs: ?bool = null,
    safety_settings: ?std.json.Value = null,
    threshold: ?[]const u8 = null,
    audio_timestamp: ?bool = null,
    labels: ?std.json.Value = null,
    media_resolution: ?[]const u8 = null,
    image_config: ?std.json.Value = null,
    retrieval_config: ?std.json.Value = null,
    stream_function_call_arguments: ?bool = null,
    service_tier: ?[]const u8 = null,
    shared_request_type: ?[]const u8 = null,
    request_type: ?[]const u8 = null,
};

pub const EmbeddingOptions = struct {
    output_dimensionality: ?std.json.Value = null,
    task_type: ?[]const u8 = null,
    content: ?std.json.Value = null,
};

pub fn parseLanguage(
    arena: Allocator,
    provider_options: ?provider.ProviderOptions,
    diag: ?*provider.Diagnostics,
) ParseError!LanguageOptions {
    const object = try googleNamespace(arena, provider_options, diag) orelse return .{};
    var result: LanguageOptions = .{};

    if (object.get("responseModalities")) |value| {
        if (value != .null) result.response_modalities = try stringArray(
            arena,
            value,
            &.{ "TEXT", "IMAGE" },
            "responseModalities",
            diag,
        );
    }
    if (object.get("thinkingConfig")) |value| {
        if (value != .null) result.thinking_config = try thinkingConfig(arena, value, diag);
    }
    if (object.get("cachedContent")) |value| result.cached_content = try optionalString(arena, value, "cachedContent", diag);
    if (object.get("structuredOutputs")) |value| result.structured_outputs = try optionalBool(arena, value, "structuredOutputs", diag);
    if (object.get("safetySettings")) |value| {
        if (value != .null) result.safety_settings = try safetySettings(arena, value, diag);
    }
    if (object.get("threshold")) |value| result.threshold = try optionalEnumString(
        arena,
        value,
        "threshold",
        safety_thresholds,
        diag,
    );
    if (object.get("audioTimestamp")) |value| result.audio_timestamp = try optionalBool(arena, value, "audioTimestamp", diag);
    if (object.get("labels")) |value| {
        if (value != .null) result.labels = try stringMap(arena, value, "labels", diag);
    }
    if (object.get("mediaResolution")) |value| result.media_resolution = try optionalEnumString(
        arena,
        value,
        "mediaResolution",
        &.{
            "MEDIA_RESOLUTION_UNSPECIFIED",
            "MEDIA_RESOLUTION_LOW",
            "MEDIA_RESOLUTION_MEDIUM",
            "MEDIA_RESOLUTION_HIGH",
        },
        diag,
    );
    if (object.get("imageConfig")) |value| {
        if (value != .null) result.image_config = try imageConfig(arena, value, diag);
    }
    if (object.get("retrievalConfig")) |value| {
        if (value != .null) result.retrieval_config = try retrievalConfig(arena, value, diag);
    }
    if (object.get("streamFunctionCallArguments")) |value| result.stream_function_call_arguments = try optionalBool(
        arena,
        value,
        "streamFunctionCallArguments",
        diag,
    );
    if (object.get("serviceTier")) |value| result.service_tier = try optionalEnumString(
        arena,
        value,
        "serviceTier",
        &.{ "standard", "flex", "priority" },
        diag,
    );
    if (object.get("sharedRequestType")) |value| result.shared_request_type = try optionalEnumString(
        arena,
        value,
        "sharedRequestType",
        &.{ "priority", "flex", "standard" },
        diag,
    );
    if (object.get("requestType")) |value| result.request_type = try optionalEnumString(
        arena,
        value,
        "requestType",
        &.{"shared"},
        diag,
    );
    return result;
}

pub fn parseEmbedding(
    arena: Allocator,
    provider_options: ?provider.ProviderOptions,
    diag: ?*provider.Diagnostics,
) ParseError!EmbeddingOptions {
    const object = try googleNamespace(arena, provider_options, diag) orelse return .{};
    var result: EmbeddingOptions = .{};
    if (object.get("outputDimensionality")) |value| {
        if (value != .null) {
            if (!isNumber(value)) return invalid(arena, diag, "outputDimensionality must be a number");
            result.output_dimensionality = try provider_utils.cloneJsonValue(arena, value);
        }
    }
    if (object.get("taskType")) |value| result.task_type = try optionalEnumString(
        arena,
        value,
        "taskType",
        &.{
            "SEMANTIC_SIMILARITY",
            "CLASSIFICATION",
            "CLUSTERING",
            "RETRIEVAL_DOCUMENT",
            "RETRIEVAL_QUERY",
            "QUESTION_ANSWERING",
            "FACT_VERIFICATION",
            "CODE_RETRIEVAL_QUERY",
        },
        diag,
    );
    if (object.get("content")) |value| {
        if (value != .null) result.content = try embeddingContent(arena, value, diag);
    }
    return result;
}

fn googleNamespace(
    arena: Allocator,
    provider_options: ?provider.ProviderOptions,
    diag: ?*provider.Diagnostics,
) ParseError!?std.json.ObjectMap {
    const root = provider_options orelse return null;
    if (root == .null) return null;
    if (root != .object) return invalid(arena, diag, "providerOptions must be an object");
    const value = root.object.get("google") orelse return null;
    if (value == .null) return null;
    if (value != .object) return invalid(arena, diag, "Google provider options must be an object");
    return value.object;
}

fn thinkingConfig(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!std.json.Value {
    if (value != .object) return invalid(arena, diag, "thinkingConfig must be an object");
    var output: std.json.ObjectMap = .empty;
    if (value.object.get("thinkingBudget")) |item| if (item != .null) {
        if (!isNumber(item)) return invalid(arena, diag, "thinkingConfig.thinkingBudget must be a number");
        try output.put(arena, "thinkingBudget", try provider_utils.cloneJsonValue(arena, item));
    };
    if (value.object.get("includeThoughts")) |item| if (try optionalBool(arena, item, "thinkingConfig.includeThoughts", diag)) |enabled| {
        try output.put(arena, "includeThoughts", .{ .bool = enabled });
    };
    if (value.object.get("thinkingLevel")) |item| if (try optionalEnumString(
        arena,
        item,
        "thinkingConfig.thinkingLevel",
        &.{ "minimal", "low", "medium", "high" },
        diag,
    )) |level| try putString(&output, arena, "thinkingLevel", level);
    return .{ .object = output };
}

const safety_categories = &.{
    "HARM_CATEGORY_UNSPECIFIED",
    "HARM_CATEGORY_HATE_SPEECH",
    "HARM_CATEGORY_DANGEROUS_CONTENT",
    "HARM_CATEGORY_HARASSMENT",
    "HARM_CATEGORY_SEXUALLY_EXPLICIT",
    "HARM_CATEGORY_CIVIC_INTEGRITY",
};

const safety_thresholds = &.{
    "HARM_BLOCK_THRESHOLD_UNSPECIFIED",
    "BLOCK_LOW_AND_ABOVE",
    "BLOCK_MEDIUM_AND_ABOVE",
    "BLOCK_ONLY_HIGH",
    "BLOCK_NONE",
    "OFF",
};

fn safetySettings(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!std.json.Value {
    if (value != .array) return invalid(arena, diag, "safetySettings must be an array");
    var output = std.json.Array.init(arena);
    for (value.array.items) |item| {
        if (item != .object) return invalid(arena, diag, "safetySettings entries must be objects");
        const category_value = item.object.get("category") orelse
            return invalid(arena, diag, "safetySettings.category is required");
        const threshold_value = item.object.get("threshold") orelse
            return invalid(arena, diag, "safetySettings.threshold is required");
        const category = (try optionalEnumString(arena, category_value, "safetySettings.category", safety_categories, diag)) orelse
            return invalid(arena, diag, "safetySettings.category is required");
        const threshold = (try optionalEnumString(arena, threshold_value, "safetySettings.threshold", safety_thresholds, diag)) orelse
            return invalid(arena, diag, "safetySettings.threshold is required");
        var entry: std.json.ObjectMap = .empty;
        try putString(&entry, arena, "category", category);
        try putString(&entry, arena, "threshold", threshold);
        try output.append(.{ .object = entry });
    }
    return .{ .array = output };
}

fn stringMap(
    arena: Allocator,
    value: std.json.Value,
    name: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!std.json.Value {
    if (value != .object) return invalidField(arena, diag, name, "must be an object of strings");
    var output: std.json.ObjectMap = .empty;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return invalidField(arena, diag, name, "must be an object of strings");
        try putString(&output, arena, entry.key_ptr.*, entry.value_ptr.string);
    }
    return .{ .object = output };
}

fn imageConfig(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!std.json.Value {
    if (value != .object) return invalid(arena, diag, "imageConfig must be an object");
    var output: std.json.ObjectMap = .empty;
    if (value.object.get("aspectRatio")) |item| if (try optionalEnumString(
        arena,
        item,
        "imageConfig.aspectRatio",
        &.{ "1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9", "1:8", "8:1", "1:4", "4:1" },
        diag,
    )) |selected| try putString(&output, arena, "aspectRatio", selected);
    if (value.object.get("imageSize")) |item| if (try optionalEnumString(
        arena,
        item,
        "imageConfig.imageSize",
        &.{ "1K", "2K", "4K", "512" },
        diag,
    )) |selected| try putString(&output, arena, "imageSize", selected);
    return .{ .object = output };
}

fn retrievalConfig(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!std.json.Value {
    if (value != .object) return invalid(arena, diag, "retrievalConfig must be an object");
    var output: std.json.ObjectMap = .empty;
    if (value.object.get("latLng")) |lat_lng| if (lat_lng != .null) {
        if (lat_lng != .object) return invalid(arena, diag, "retrievalConfig.latLng must be an object");
        const latitude = lat_lng.object.get("latitude") orelse return invalid(arena, diag, "retrievalConfig.latLng.latitude is required");
        const longitude = lat_lng.object.get("longitude") orelse return invalid(arena, diag, "retrievalConfig.latLng.longitude is required");
        if (!isNumber(latitude) or !isNumber(longitude)) return invalid(arena, diag, "retrievalConfig latitude and longitude must be numbers");
        var coordinates: std.json.ObjectMap = .empty;
        try coordinates.put(arena, "latitude", try provider_utils.cloneJsonValue(arena, latitude));
        try coordinates.put(arena, "longitude", try provider_utils.cloneJsonValue(arena, longitude));
        try output.put(arena, "latLng", .{ .object = coordinates });
    };
    return .{ .object = output };
}

fn embeddingContent(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!std.json.Value {
    if (value != .array) return invalid(arena, diag, "content must be an array");
    var entries = std.json.Array.init(arena);
    for (value.array.items) |entry| {
        if (entry == .null) {
            try entries.append(.null);
            continue;
        }
        if (entry != .array) return invalid(arena, diag, "content entries must be arrays or null");
        var parts = std.json.Array.init(arena);
        for (entry.array.items) |part| try parts.append(try embeddingPart(arena, part, diag));
        try entries.append(.{ .array = parts });
    }
    return .{ .array = entries };
}

fn embeddingPart(arena: Allocator, value: std.json.Value, diag: ?*provider.Diagnostics) ParseError!std.json.Value {
    if (value != .object) return invalid(arena, diag, "embedding content parts must be objects");
    var output: std.json.ObjectMap = .empty;
    if (value.object.get("text")) |text| {
        if (text != .string) return invalid(arena, diag, "embedding text content must be a string");
        try putString(&output, arena, "text", text.string);
        return .{ .object = output };
    }
    if (value.object.get("inlineData")) |data| {
        if (data != .object) return invalid(arena, diag, "inlineData must be an object");
        const mime = data.object.get("mimeType") orelse return invalid(arena, diag, "inlineData.mimeType is required");
        const bytes = data.object.get("data") orelse return invalid(arena, diag, "inlineData.data is required");
        if (mime != .string or bytes != .string) return invalid(arena, diag, "inlineData fields must be strings");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "mimeType", mime.string);
        try putString(&item, arena, "data", bytes.string);
        try output.put(arena, "inlineData", .{ .object = item });
        return .{ .object = output };
    }
    if (value.object.get("fileData")) |data| {
        if (data != .object) return invalid(arena, diag, "fileData must be an object");
        const uri = data.object.get("fileUri") orelse return invalid(arena, diag, "fileData.fileUri is required");
        const mime = data.object.get("mimeType") orelse return invalid(arena, diag, "fileData.mimeType is required");
        if (uri != .string or mime != .string) return invalid(arena, diag, "fileData fields must be strings");
        var item: std.json.ObjectMap = .empty;
        try putString(&item, arena, "fileUri", uri.string);
        try putString(&item, arena, "mimeType", mime.string);
        try output.put(arena, "fileData", .{ .object = item });
        return .{ .object = output };
    }
    return invalid(arena, diag, "embedding content part has an unsupported shape");
}

fn stringArray(
    arena: Allocator,
    value: std.json.Value,
    allowed: []const []const u8,
    name: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!std.json.Value {
    if (value != .array) return invalidField(arena, diag, name, "must be an array");
    var output = std.json.Array.init(arena);
    for (value.array.items) |item| {
        if (item != .string or !contains(allowed, item.string)) return invalidField(arena, diag, name, "contains an unsupported value");
        try output.append(.{ .string = try arena.dupe(u8, item.string) });
    }
    return .{ .array = output };
}

fn optionalString(
    arena: Allocator,
    value: std.json.Value,
    name: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!?[]const u8 {
    return switch (value) {
        .string => |text| try arena.dupe(u8, text),
        .null => null,
        else => invalidField(arena, diag, name, "must be a string"),
    };
}

fn optionalBool(
    arena: Allocator,
    value: std.json.Value,
    name: []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        .null => null,
        else => invalidField(arena, diag, name, "must be a boolean"),
    };
}

fn optionalEnumString(
    arena: Allocator,
    value: std.json.Value,
    name: []const u8,
    allowed: []const []const u8,
    diag: ?*provider.Diagnostics,
) ParseError!?[]const u8 {
    const selected = try optionalString(arena, value, name, diag) orelse return null;
    if (!contains(allowed, selected)) return invalidField(arena, diag, name, "has an unsupported value");
    return selected;
}

fn contains(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn isNumber(value: std.json.Value) bool {
    return value == .integer or value == .float or value == .number_string;
}

fn putString(object: *std.json.ObjectMap, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn invalidField(arena: Allocator, diag: ?*provider.Diagnostics, name: []const u8, suffix: []const u8) ParseError {
    const message = try std.fmt.allocPrint(arena, "{s} {s}", .{ name, suffix });
    return invalid(arena, diag, message);
}

fn invalid(arena: Allocator, diag: ?*provider.Diagnostics, message: []const u8) provider.Error {
    provider.Diagnostics.set(diag, if (diag) |diagnostics| diagnostics.allocator else arena, .{
        .type_validation = .{ .message = message },
    });
    return error.TypeValidationError;
}

test "Google language options sanitize safety, thinking, and structured output fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"google":{"foo":"ignored","responseModalities":["TEXT","IMAGE"],"thinkingConfig":{"thinkingBudget":999,"includeThoughts":true,"ignored":1},"structuredOutputs":false,"threshold":"BLOCK_NONE","serviceTier":"flex"}}
    , .{});
    const parsed = try parseLanguage(arena, value, null);
    try std.testing.expectEqual(false, parsed.structured_outputs.?);
    try std.testing.expectEqualStrings("BLOCK_NONE", parsed.threshold.?);
    try std.testing.expectEqualStrings("flex", parsed.service_tier.?);
    try std.testing.expect(parsed.thinking_config.?.object.get("ignored") == null);
    try std.testing.expectEqual(2, parsed.response_modalities.?.array.items.len);
}

test "Google embedding options preserve supported multimodal content and reject invalid task types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"google":{"outputDimensionality":64,"taskType":"SEMANTIC_SIMILARITY","content":[[{"inlineData":{"mimeType":"image/png","data":"abc"}}],null]}}
    , .{});
    const parsed = try parseEmbedding(arena, value, null);
    try std.testing.expectEqual(64, parsed.output_dimensionality.?.integer);
    try std.testing.expectEqualStrings("SEMANTIC_SIMILARITY", parsed.task_type.?);
    try std.testing.expectEqual(2, parsed.content.?.array.items.len);

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"google\":{\"taskType\":\"NOPE\"}}", .{});
    try std.testing.expectError(error.TypeValidationError, parseEmbedding(arena, bad, null));
}
