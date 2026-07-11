//! Output strategies shared by `generateText`/`streamText` and the standalone
//! structured-output APIs.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const types = @import("generate_text_types.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { text, object, array, choice, json };

pub const ParseContext = struct {
    response: types.ResponseMetadata,
    usage: provider.Usage,
    finish_reason: provider.FinishReason,
};

pub const Options = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const PartialValidationContext = struct {
    value: std.json.Value,
    text_delta: []const u8,
    latest: ?types.OutputValue,
    is_first_delta: bool,
    is_final_delta: bool,
};

pub const PartialValidationResult = struct {
    partial: types.OutputValue,
    text_delta: []const u8,
};

pub const Output = struct {
    kind: Kind,
    schema: ?provider_utils.Schema = null,
    choices: []const []const u8 = &.{},
    schema_name: ?[]const u8 = null,
    schema_description: ?[]const u8 = null,

    pub fn name(self: Output) []const u8 {
        return @tagName(self.kind);
    }

    pub fn responseFormat(
        self: Output,
        io: std.Io,
        arena: Allocator,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!provider.ResponseFormat {
        _ = io;
        return switch (self.kind) {
            .text => .{ .text = .{} },
            .object => .{ .json = .{
                .schema = try schemaValue(arena, self.schema.?, diag),
                .name = self.schema_name,
                .description = self.schema_description,
            } },
            .array => .{ .json = .{
                .schema = try arraySchema(arena, self.schema.?, diag),
                .name = self.schema_name,
                .description = self.schema_description,
            } },
            .choice => .{ .json = .{
                .schema = try choiceSchema(arena, self.choices),
                .name = self.schema_name,
                .description = self.schema_description,
            } },
            .json => .{ .json = .{
                .name = self.schema_name,
                .description = self.schema_description,
            } },
        };
    }

    pub fn parseComplete(
        self: Output,
        arena: Allocator,
        text_value: []const u8,
        context: *const ParseContext,
        diag: ?*provider.Diagnostics,
    ) provider.CallError!types.OutputValue {
        if (self.kind == .text) return .{ .text = text_value };

        const parsed = switch (provider_utils.safeParseJson(std.json.Value, arena, text_value)) {
            .success => |success| success.value,
            .failure => |failure| return noObjectGenerated(
                arena,
                diag,
                "No object generated: could not parse the response.",
                text_value,
                context,
                failure.message,
            ),
        };

        return switch (self.kind) {
            .text => unreachable,
            .object => blk: {
                validateSchema(self.schema.?, arena, parsed) catch |err| {
                    return noObjectGenerated(
                        arena,
                        diag,
                        "No object generated: response did not match schema.",
                        text_value,
                        context,
                        @errorName(err),
                    );
                };
                break :blk .{ .json = parsed };
            },
            .array => .{ .json = try completeArray(self, arena, parsed, text_value, context, diag) },
            .choice => .{ .text = try completeChoice(self, arena, parsed, text_value, context, diag) },
            .json => .{ .json = parsed },
        };
    }

    /// Parses accumulated text for `streamText`'s partial-output transform.
    /// Repaired arrays intentionally omit the last element; a successful parse
    /// validates every element. Repaired choices publish only unambiguous
    /// candidates, while a successful parse requires an exact option.
    pub fn parsePartial(
        self: Output,
        arena: Allocator,
        text_value: []const u8,
    ) Allocator.Error!?types.OutputValue {
        if (self.kind == .text) return .{ .text = text_value };
        const result = try provider_utils.parsePartialJson(arena, text_value);
        const value = result.value orelse return null;
        return switch (self.kind) {
            .text => unreachable,
            .object, .json => .{ .json = value },
            .array => self.partialArray(arena, value, result.state),
            .choice => self.partialChoice(value, result.state),
        };
    }

    /// Validates a parsed partial for standalone `streamObject`. Object and
    /// JSON modes deliberately leave partials unvalidated, matching upstream.
    pub fn validatePartial(
        self: Output,
        arena: Allocator,
        context: PartialValidationContext,
    ) Allocator.Error!?PartialValidationResult {
        return switch (self.kind) {
            .text => .{
                .partial = .{ .text = context.text_delta },
                .text_delta = context.text_delta,
            },
            .object, .json => .{
                .partial = .{ .json = context.value },
                .text_delta = try arena.dupe(u8, context.text_delta),
            },
            .choice => blk: {
                const result = self.choicePrefix(context.value) orelse break :blk null;
                break :blk .{
                    .partial = .{ .text = result },
                    .text_delta = try arena.dupe(u8, context.text_delta),
                };
            },
            .array => self.validatePartialArray(arena, context),
        };
    }

    pub fn hasElementStream(self: Output) bool {
        return self.kind == .array;
    }

    fn partialArray(
        self: Output,
        arena: Allocator,
        value: std.json.Value,
        state: provider_utils.parse_partial_json.State,
    ) Allocator.Error!?types.OutputValue {
        const elements = elementsArray(value) orelse return null;
        const limit = if (state == .repaired_parse and elements.len != 0)
            elements.len - 1
        else
            elements.len;
        var output = std.json.Array.init(arena);
        for (elements[0..limit]) |element| {
            validateSchema(self.schema.?, arena, element) catch continue;
            try output.append(element);
        }
        return .{ .json = .{ .array = output } };
    }

    fn partialChoice(
        self: Output,
        value: std.json.Value,
        state: provider_utils.parse_partial_json.State,
    ) ?types.OutputValue {
        const result = resultString(value) orelse return null;
        var matches: usize = 0;
        var only: []const u8 = "";
        var exact = false;
        for (self.choices) |candidate| {
            if (std.mem.eql(u8, candidate, result)) exact = true;
            if (std.mem.startsWith(u8, candidate, result)) {
                matches += 1;
                only = candidate;
            }
        }
        return switch (state) {
            .successful_parse => if (exact) .{ .text = result } else null,
            .repaired_parse => if (result.len != 0 and matches == 1) .{ .text = only } else null,
            .undefined_input, .failed_parse => null,
        };
    }

    fn choicePrefix(self: Output, value: std.json.Value) ?[]const u8 {
        const result = resultString(value) orelse return null;
        if (result.len == 0) return null;
        var count: usize = 0;
        var only: []const u8 = "";
        for (self.choices) |candidate| if (std.mem.startsWith(u8, candidate, result)) {
            count += 1;
            only = candidate;
        };
        if (count == 0) return null;
        return if (count == 1) only else result;
    }

    fn validatePartialArray(
        self: Output,
        arena: Allocator,
        context: PartialValidationContext,
    ) Allocator.Error!?PartialValidationResult {
        const elements = elementsArray(context.value) orelse return null;
        var result = std.json.Array.init(arena);
        for (elements, 0..) |element, index| {
            if (index + 1 == elements.len and !context.is_final_delta) continue;
            validateSchema(self.schema.?, arena, element) catch return null;
            try result.append(element);
        }

        const published_count = if (context.latest) |latest| switch (latest) {
            .json => |value| if (value == .array) value.array.items.len else 0,
            .text => 0,
        } else 0;

        var delta: std.Io.Writer.Allocating = .init(arena);
        defer delta.deinit();
        if (context.is_first_delta) delta.writer.writeByte('[') catch return error.OutOfMemory;
        if (published_count != 0 and result.items.len > published_count) {
            delta.writer.writeByte(',') catch return error.OutOfMemory;
        }
        for (result.items[published_count..], 0..) |element, index| {
            if (index != 0) delta.writer.writeByte(',') catch return error.OutOfMemory;
            std.json.Stringify.value(element, .{}, &delta.writer) catch return error.OutOfMemory;
        }
        if (context.is_final_delta) delta.writer.writeByte(']') catch return error.OutOfMemory;

        return .{
            .partial = .{ .json = .{ .array = result } },
            .text_delta = try delta.toOwnedSlice(),
        };
    }
};

pub fn text() Output {
    return .{ .kind = .text };
}

pub fn object(schema: provider_utils.Schema) Output {
    return objectWithOptions(schema, .{});
}

pub fn objectWithOptions(schema: provider_utils.Schema, options: Options) Output {
    return .{
        .kind = .object,
        .schema = schema,
        .schema_name = options.name,
        .schema_description = options.description,
    };
}

pub fn array(element_schema: provider_utils.Schema) Output {
    return arrayWithOptions(element_schema, .{});
}

pub fn arrayWithOptions(element_schema: provider_utils.Schema, options: Options) Output {
    return .{
        .kind = .array,
        .schema = element_schema,
        .schema_name = options.name,
        .schema_description = options.description,
    };
}

pub fn choice(values: []const []const u8) Output {
    return choiceWithOptions(values, .{});
}

pub fn choiceWithOptions(values: []const []const u8, options: Options) Output {
    return .{
        .kind = .choice,
        .choices = values,
        .schema_name = options.name,
        .schema_description = options.description,
    };
}

pub fn json() Output {
    return jsonWithOptions(.{});
}

pub fn jsonWithOptions(options: Options) Output {
    return .{
        .kind = .json,
        .schema_name = options.name,
        .schema_description = options.description,
    };
}

fn schemaValue(
    arena: Allocator,
    schema: provider_utils.Schema,
    diag: ?*provider.Diagnostics,
) provider.CallError!std.json.Value {
    return switch (schema.document) {
        .text => |document| provider_utils.parseJson(std.json.Value, arena, document, diag),
        .value => |value| provider_utils.cloneJsonValue(arena, value),
    };
}

fn arraySchema(
    arena: Allocator,
    schema: provider_utils.Schema,
    diag: ?*provider.Diagnostics,
) provider.CallError!std.json.Value {
    var item = try schemaValue(arena, schema, diag);
    if (item == .object) _ = item.object.orderedRemove("$schema");

    var elements: std.json.ObjectMap = .empty;
    try elements.put(arena, "type", .{ .string = "array" });
    try elements.put(arena, "items", item);
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "elements", .{ .object = elements });
    var required = std.json.Array.init(arena);
    try required.append(.{ .string = "elements" });
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "$schema", .{ .string = "http://json-schema.org/draft-07/schema#" });
    try root.put(arena, "type", .{ .string = "object" });
    try root.put(arena, "properties", .{ .object = properties });
    try root.put(arena, "required", .{ .array = required });
    try root.put(arena, "additionalProperties", .{ .bool = false });
    return .{ .object = root };
}

fn choiceSchema(arena: Allocator, choices: []const []const u8) Allocator.Error!std.json.Value {
    var values = std.json.Array.init(arena);
    for (choices) |value| try values.append(.{ .string = try arena.dupe(u8, value) });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "type", .{ .string = "string" });
    try result.put(arena, "enum", .{ .array = values });
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "result", .{ .object = result });
    var required = std.json.Array.init(arena);
    try required.append(.{ .string = "result" });
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "$schema", .{ .string = "http://json-schema.org/draft-07/schema#" });
    try root.put(arena, "type", .{ .string = "object" });
    try root.put(arena, "properties", .{ .object = properties });
    try root.put(arena, "required", .{ .array = required });
    try root.put(arena, "additionalProperties", .{ .bool = false });
    return .{ .object = root };
}

fn validateSchema(
    schema: provider_utils.Schema,
    arena: Allocator,
    value: std.json.Value,
) error{TypeValidationError}!void {
    if (schema.validator) |validator| try validator.validate(arena, value, null);
}

fn elementsArray(value: std.json.Value) ?[]const std.json.Value {
    if (value != .object) return null;
    const elements = value.object.get("elements") orelse return null;
    if (elements != .array) return null;
    return elements.array.items;
}

fn resultString(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const result = value.object.get("result") orelse return null;
    if (result != .string) return null;
    return result.string;
}

fn completeArray(
    self: Output,
    arena: Allocator,
    value: std.json.Value,
    text_value: []const u8,
    context: *const ParseContext,
    diag: ?*provider.Diagnostics,
) provider.CallError!std.json.Value {
    const elements = elementsArray(value) orelse return noObjectGenerated(
        arena,
        diag,
        "No object generated: response did not match schema.",
        text_value,
        context,
        "response must be an object with an elements array",
    );
    var result = std.json.Array.init(arena);
    for (elements) |element| {
        validateSchema(self.schema.?, arena, element) catch |err| {
            return noObjectGenerated(
                arena,
                diag,
                "No object generated: response did not match schema.",
                text_value,
                context,
                @errorName(err),
            );
        };
        try result.append(element);
    }
    return .{ .array = result };
}

fn completeChoice(
    self: Output,
    arena: Allocator,
    value: std.json.Value,
    text_value: []const u8,
    context: *const ParseContext,
    diag: ?*provider.Diagnostics,
) provider.CallError![]const u8 {
    const result = resultString(value) orelse return noObjectGenerated(
        arena,
        diag,
        "No object generated: response did not match schema.",
        text_value,
        context,
        "response must be an object that contains a choice value",
    );
    for (self.choices) |candidate| if (std.mem.eql(u8, result, candidate)) return result;
    return noObjectGenerated(
        arena,
        diag,
        "No object generated: response did not match schema.",
        text_value,
        context,
        "value must be a string in the enum",
    );
}

fn noObjectGenerated(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    message: []const u8,
    text_value: []const u8,
    context: *const ParseContext,
    cause_message: []const u8,
) provider.Error {
    const Response = struct {
        id: ?[]const u8 = null,
        timestamp_ms: ?i64 = null,
        model_id: ?[]const u8 = null,
        headers: ?provider.Headers = null,

        pub const wire_field_names = .{.{ "timestamp_ms", "timestamp" }};
    };
    const response_json = provider.wire.stringifyAlloc(arena, Response{
        .id = context.response.id,
        .timestamp_ms = context.response.timestamp_ms,
        .model_id = context.response.model_id,
        .headers = context.response.headers,
    }) catch null;
    const usage_json = provider.wire.stringifyAlloc(arena, context.usage) catch null;
    if (diag) |diagnostics| provider.Diagnostics.set(diag, diagnostics.allocator, .{
        .no_object_generated = .{
            .message = message,
            .text = text_value,
            .response_json = response_json,
            .usage_json = usage_json,
            .finish_reason = context.finish_reason,
            .cause_message = cause_message,
        },
    });
    return error.NoObjectGeneratedError;
}

test "output strategies build provider response formats" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Shape = struct { name: []const u8 };

    const object_format = try objectWithOptions(
        provider_utils.schemaFromType(Shape),
        .{ .name = "shape", .description = "A shape" },
    ).responseFormat(std.testing.io, arena, null);
    try std.testing.expect(object_format == .json);
    try std.testing.expectEqualStrings("shape", object_format.json.name.?);
    try std.testing.expect(object_format.json.schema.?.object.get("properties") != null);

    const array_format = try array(provider_utils.schemaFromType(Shape)).responseFormat(
        std.testing.io,
        arena,
        null,
    );
    const item = array_format.json.schema.?.object
        .get("properties").?.object
        .get("elements").?.object
        .get("items").?;
    try std.testing.expect(item.object.get("$schema") == null);

    const choices = [_][]const u8{ "sunny", "rainy" };
    const choice_format = try choice(&choices).responseFormat(std.testing.io, arena, null);
    try std.testing.expectEqual(2, choice_format.json.schema.?.object
        .get("properties").?.object
        .get("result").?.object
        .get("enum").?.array.items.len);
    try std.testing.expect((try json().responseFormat(std.testing.io, arena, null)).json.schema == null);
}

test "array and choice partial strategies follow completion boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Element = struct { value: []const u8 };
    const array_output = array(provider_utils.schemaFromType(Element));

    const repaired = (try array_output.parsePartial(
        arena,
        "{\"elements\":[{\"value\":\"a\"},{\"value\":\"b\"}",
    )).?.json;
    try std.testing.expectEqual(1, repaired.array.items.len);

    const complete = (try array_output.parsePartial(
        arena,
        "{\"elements\":[{\"value\":\"a\"},{\"value\":\"b\"}]}",
    )).?.json;
    try std.testing.expectEqual(2, complete.array.items.len);

    const values = [_][]const u8{ "foobar", "foobar2", "other" };
    try std.testing.expect((try choice(&values).parsePartial(arena, "{\"result\":\"")) == null);
    try std.testing.expect((try choice(&values).parsePartial(arena, "{\"result\":\"foo")) == null);
    try std.testing.expect((try choice(&values).parsePartial(arena, "{\"result\":\"missing")) == null);
    try std.testing.expect((try choice(&values).parsePartial(arena, "{\"result\":\"foo\"}")) == null);
    const unique = (try choice(&values).parsePartial(arena, "{\"result\":\"o")).?;
    try std.testing.expectEqualStrings("other", unique.text);
    const exact = (try choice(&values).parsePartial(arena, "{\"result\":\"foobar\"}")).?;
    try std.testing.expectEqualStrings("foobar", exact.text);

    var ambiguous_object: std.json.ObjectMap = .empty;
    try ambiguous_object.put(arena, "result", .{ .string = "foo" });
    const ambiguous = (try choice(&values).validatePartial(arena, .{
        .value = .{ .object = ambiguous_object },
        .text_delta = "foo",
        .latest = null,
        .is_first_delta = true,
        .is_final_delta = false,
    })).?;
    try std.testing.expectEqualStrings("foo", ambiguous.partial.text);

    var unique_object: std.json.ObjectMap = .empty;
    try unique_object.put(arena, "result", .{ .string = "oth" });
    const early_complete = (try choice(&values).validatePartial(arena, .{
        .value = .{ .object = unique_object },
        .text_delta = "oth",
        .latest = null,
        .is_first_delta = true,
        .is_final_delta = false,
    })).?;
    try std.testing.expectEqualStrings("other", early_complete.partial.text);
}
