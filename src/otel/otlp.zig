//! Minimal OTLP trace JSON encoding.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const SpanKind = enum(u8) {
    internal = 1,
    client = 3,
};

pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    double: f64,
    boolean: bool,
    string_array: []const []const u8,
};

pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
};

pub const StatusCode = enum(u8) {
    unset = 0,
    ok = 1,
    error_status = 2,
};

pub const Status = struct {
    code: StatusCode = .unset,
    message: ?[]const u8 = null,
};

pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,
    name: []const u8,
    kind: SpanKind,
    start_time_unix_nano: u64,
    end_time_unix_nano: u64,
    attributes: []const Attribute = &.{},
    status: ?Status = null,
};

pub const EncodeOptions = struct {
    service_name: []const u8,
    scope_name: []const u8 = "ai.zig.otel",
    scope_version: ?[]const u8 = null,
    spans: []const Span,
};

/// Encodes the protobuf-JSON form accepted by OTLP/HTTP `/v1/traces`.
/// Int64/fixed64 fields are JSON strings, matching protobuf JSON mapping.
pub fn encode(allocator: Allocator, options: EncodeOptions) Allocator.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{},
    };

    json.beginObject() catch return error.OutOfMemory;
    json.objectField("resourceSpans") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;

    json.objectField("resource") catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("attributes") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    writeAttribute(&json, .{
        .key = "service.name",
        .value = .{ .string = options.service_name },
    }) catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;

    json.objectField("scopeSpans") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("scope") catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("name") catch return error.OutOfMemory;
    json.write(options.scope_name) catch return error.OutOfMemory;
    if (options.scope_version) |version| {
        json.objectField("version") catch return error.OutOfMemory;
        json.write(version) catch return error.OutOfMemory;
    }
    json.endObject() catch return error.OutOfMemory;

    json.objectField("spans") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    for (options.spans) |span| writeSpan(&json, span) catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;

    return output.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSpan(json: *std.json.Stringify, span: Span) std.Io.Writer.Error!void {
    const trace_id = std.fmt.bytesToHex(span.trace_id, .lower);
    const span_id = std.fmt.bytesToHex(span.span_id, .lower);

    try json.beginObject();
    try json.objectField("traceId");
    try json.write(&trace_id);
    try json.objectField("spanId");
    try json.write(&span_id);
    if (span.parent_span_id) |parent| {
        const parent_id = std.fmt.bytesToHex(parent, .lower);
        try json.objectField("parentSpanId");
        try json.write(&parent_id);
    }
    try json.objectField("name");
    try json.write(span.name);
    try json.objectField("kind");
    try json.write(@intFromEnum(span.kind));
    try json.objectField("startTimeUnixNano");
    try writeUint64String(json, span.start_time_unix_nano);
    try json.objectField("endTimeUnixNano");
    try writeUint64String(json, span.end_time_unix_nano);
    if (span.attributes.len != 0) {
        try json.objectField("attributes");
        try json.beginArray();
        for (span.attributes) |attribute| try writeAttribute(json, attribute);
        try json.endArray();
    }
    if (span.status) |status| {
        try json.objectField("status");
        try json.beginObject();
        if (status.message) |message| {
            try json.objectField("message");
            try json.write(message);
        }
        try json.objectField("code");
        try json.write(@intFromEnum(status.code));
        try json.endObject();
    }
    try json.endObject();
}

fn writeAttribute(json: *std.json.Stringify, attribute: Attribute) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("key");
    try json.write(attribute.key);
    try json.objectField("value");
    try writeAnyValue(json, attribute.value);
    try json.endObject();
}

fn writeAnyValue(json: *std.json.Stringify, value: AttributeValue) std.Io.Writer.Error!void {
    try json.beginObject();
    switch (value) {
        .string => |item| {
            try json.objectField("stringValue");
            try json.write(item);
        },
        .int => |item| {
            try json.objectField("intValue");
            var buffer: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{item}) catch unreachable;
            try json.write(text);
        },
        .double => |item| {
            try json.objectField("doubleValue");
            try json.write(item);
        },
        .boolean => |item| {
            try json.objectField("boolValue");
            try json.write(item);
        },
        .string_array => |items| {
            try json.objectField("arrayValue");
            try json.beginObject();
            try json.objectField("values");
            try json.beginArray();
            for (items) |item| {
                try json.beginObject();
                try json.objectField("stringValue");
                try json.write(item);
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
        },
    }
    try json.endObject();
}

fn writeUint64String(json: *std.json.Stringify, value: u64) std.Io.Writer.Error!void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try json.write(text);
}

test "OTLP JSON encoder emits resource scope spans and protobuf scalar shapes" {
    const attributes = [_]Attribute{
        .{ .key = "gen_ai.system", .value = .{ .string = "openai" } },
        .{ .key = "gen_ai.usage.input_tokens", .value = .{ .int = 12 } },
        .{ .key = "gen_ai.response.finish_reasons", .value = .{ .string_array = &.{"stop"} } },
    };
    const spans = [_]Span{.{
        .trace_id = [_]u8{0x11} ** 16,
        .span_id = [_]u8{0x22} ** 8,
        .parent_span_id = [_]u8{0x33} ** 8,
        .name = "chat gpt-test",
        .kind = .client,
        .start_time_unix_nano = 100,
        .end_time_unix_nano = 200,
        .attributes = &attributes,
        .status = .{ .code = .ok },
    }};

    const encoded = try encode(std.testing.allocator, .{
        .service_name = "otel-test",
        .scope_name = "ai.zig.test",
        .scope_version = "1",
        .spans = &spans,
    });
    defer std.testing.allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    const resource_span = parsed.value.object.get("resourceSpans").?.array.items[0].object;
    const resource_attr = resource_span.get("resource").?.object.get("attributes").?.array.items[0].object;
    try std.testing.expectEqualStrings("service.name", resource_attr.get("key").?.string);
    try std.testing.expectEqualStrings(
        "otel-test",
        resource_attr.get("value").?.object.get("stringValue").?.string,
    );

    const scope_span = resource_span.get("scopeSpans").?.array.items[0].object;
    try std.testing.expectEqualStrings("ai.zig.test", scope_span.get("scope").?.object.get("name").?.string);
    const span = scope_span.get("spans").?.array.items[0].object;
    try std.testing.expectEqualStrings("11111111111111111111111111111111", span.get("traceId").?.string);
    try std.testing.expectEqualStrings("2222222222222222", span.get("spanId").?.string);
    try std.testing.expectEqualStrings("3333333333333333", span.get("parentSpanId").?.string);
    try std.testing.expectEqualStrings("100", span.get("startTimeUnixNano").?.string);
    try std.testing.expectEqualStrings("200", span.get("endTimeUnixNano").?.string);
    try std.testing.expectEqual(3, span.get("attributes").?.array.items.len);
    try std.testing.expectEqualStrings(
        "12",
        span.get("attributes").?.array.items[1].object.get("value").?.object.get("intValue").?.string,
    );
}
