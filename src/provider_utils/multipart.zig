//! In-memory multipart/form-data encoding for provider API requests.

const std = @import("std");
const id_api = @import("id.zig");

const Allocator = std.mem.Allocator;

pub const boundary_prefix = "ai-zig-boundary";
pub const boundary_token_size = 16;

pub const File = struct {
    filename: []const u8,
    media_type: []const u8,
    bytes: []const u8,
};

pub const Encoded = struct {
    content_type: []const u8,
    body: []const u8,
};

/// A FormData-equivalent builder whose field values are borrowed until
/// `encode` returns. The boundary and part list are owned by `allocator`.
pub const FormData = struct {
    allocator: Allocator,
    boundary: []const u8,
    parts: std.ArrayList(Part) = .empty,

    pub const Error = Allocator.Error || error{InvalidArgumentError};

    /// `generator` must use the multipart boundary contract: prefix
    /// `ai-zig-boundary` and a 16-character generated suffix.
    pub fn init(allocator: Allocator, generator: *id_api.IdGenerator) Error!FormData {
        if (generator.prefix == null or
            !std.mem.eql(u8, generator.prefix.?, boundary_prefix) or
            generator.separator != '-' or
            generator.size != boundary_token_size)
        {
            return error.InvalidArgumentError;
        }

        return .{
            .allocator = allocator,
            .boundary = try generator.nextAlloc(allocator),
        };
    }

    pub fn initFromSeed(allocator: Allocator, seed: u64) Allocator.Error!FormData {
        var generator = id_api.IdGenerator.init(seed, .{
            .prefix = boundary_prefix,
            .size = boundary_token_size,
        }, null) catch unreachable;
        return init(allocator, &generator) catch |err| switch (err) {
            error.InvalidArgumentError => unreachable,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    pub fn initFromIo(allocator: Allocator, io: std.Io) Allocator.Error!FormData {
        var generator = id_api.IdGenerator.initFromIo(io, .{
            .prefix = boundary_prefix,
            .size = boundary_token_size,
        }, null) catch unreachable;
        return init(allocator, &generator) catch |err| switch (err) {
            error.InvalidArgumentError => unreachable,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    pub fn deinit(self: *FormData) void {
        self.parts.deinit(self.allocator);
        self.allocator.free(self.boundary);
        self.* = undefined;
    }

    pub fn appendText(
        self: *FormData,
        name: []const u8,
        value: []const u8,
    ) Allocator.Error!void {
        try self.appendTextPart(name, value, false);
    }

    pub fn appendFile(
        self: *FormData,
        name: []const u8,
        filename: []const u8,
        media_type: []const u8,
        bytes: []const u8,
    ) Error!void {
        try self.appendFilePart(name, .{
            .filename = filename,
            .media_type = media_type,
            .bytes = bytes,
        }, false);
    }

    /// Mirrors convertToFormData's default array convention: empty arrays add
    /// no parts, one item uses `name`, and multiple items use `name[]`.
    pub fn appendTextArray(
        self: *FormData,
        name: []const u8,
        values: []const []const u8,
    ) Allocator.Error!void {
        const array_brackets = values.len > 1;
        for (values) |value| try self.appendTextPart(name, value, array_brackets);
    }

    /// File-array counterpart to `appendTextArray`.
    pub fn appendFileArray(
        self: *FormData,
        name: []const u8,
        files: []const File,
    ) Error!void {
        const array_brackets = files.len > 1;
        for (files) |file| try self.appendFilePart(name, file, array_brackets);
    }

    pub fn encode(self: *const FormData, arena: Allocator) Allocator.Error!Encoded {
        var output: std.Io.Writer.Allocating = .init(arena);
        defer output.deinit();

        for (self.parts.items) |part| {
            write(&output.writer, "--") catch return error.OutOfMemory;
            write(&output.writer, self.boundary) catch return error.OutOfMemory;
            write(&output.writer, "\r\nContent-Disposition: form-data; name=\"") catch
                return error.OutOfMemory;
            writeDispositionParameter(&output.writer, part.name) catch return error.OutOfMemory;
            if (part.array_brackets) write(&output.writer, "[]") catch
                return error.OutOfMemory;

            switch (part.value) {
                .text => |value| {
                    write(&output.writer, "\"\r\n\r\n") catch return error.OutOfMemory;
                    write(&output.writer, value) catch return error.OutOfMemory;
                },
                .file => |file| {
                    write(&output.writer, "\"; filename=\"") catch return error.OutOfMemory;
                    writeDispositionParameter(&output.writer, file.filename) catch return error.OutOfMemory;
                    write(&output.writer, "\"\r\nContent-Type: ") catch return error.OutOfMemory;
                    write(&output.writer, file.media_type) catch return error.OutOfMemory;
                    write(&output.writer, "\r\n\r\n") catch return error.OutOfMemory;
                    write(&output.writer, file.bytes) catch return error.OutOfMemory;
                },
            }
            write(&output.writer, "\r\n") catch return error.OutOfMemory;
        }

        write(&output.writer, "--") catch return error.OutOfMemory;
        write(&output.writer, self.boundary) catch return error.OutOfMemory;
        write(&output.writer, "--\r\n") catch return error.OutOfMemory;

        return .{
            .content_type = try std.fmt.allocPrint(
                arena,
                "multipart/form-data; boundary={s}",
                .{self.boundary},
            ),
            .body = try output.toOwnedSlice(),
        };
    }

    /// Produces an error-safe request summary. Text values are preserved like
    /// upstream FormData diagnostics; binary payloads are represented only by
    /// filename, media type, and byte count.
    pub fn diagnosticJson(self: *const FormData, arena: Allocator) Allocator.Error![]const u8 {
        var output: std.Io.Writer.Allocating = .init(arena);
        defer output.deinit();
        write(&output.writer, "{\"parts\":[") catch return error.OutOfMemory;
        for (self.parts.items, 0..) |part, index| {
            if (index != 0) write(&output.writer, ",") catch return error.OutOfMemory;
            write(&output.writer, "{\"name\":") catch return error.OutOfMemory;
            const effective_name = if (part.array_brackets)
                try std.fmt.allocPrint(arena, "{s}[]", .{part.name})
            else
                part.name;
            writeJsonString(&output.writer, effective_name) catch return error.OutOfMemory;
            switch (part.value) {
                .text => |value| {
                    write(&output.writer, ",\"value\":") catch return error.OutOfMemory;
                    writeJsonString(&output.writer, value) catch return error.OutOfMemory;
                },
                .file => |file| {
                    write(&output.writer, ",\"file\":{\"filename\":") catch return error.OutOfMemory;
                    writeJsonString(&output.writer, file.filename) catch return error.OutOfMemory;
                    write(&output.writer, ",\"mediaType\":") catch return error.OutOfMemory;
                    writeJsonString(&output.writer, file.media_type) catch return error.OutOfMemory;
                    output.writer.print(",\"size\":{d}}}", .{file.bytes.len}) catch return error.OutOfMemory;
                },
            }
            write(&output.writer, "}") catch return error.OutOfMemory;
        }
        write(&output.writer, "]}") catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    fn appendTextPart(
        self: *FormData,
        name: []const u8,
        value: []const u8,
        array_brackets: bool,
    ) Allocator.Error!void {
        try self.parts.append(self.allocator, .{
            .name = name,
            .array_brackets = array_brackets,
            .value = .{ .text = value },
        });
    }

    fn appendFilePart(
        self: *FormData,
        name: []const u8,
        file: File,
        array_brackets: bool,
    ) Error!void {
        if (std.mem.indexOfAny(u8, file.media_type, "\r\n") != null) {
            return error.InvalidArgumentError;
        }
        try self.parts.append(self.allocator, .{
            .name = name,
            .array_brackets = array_brackets,
            .value = .{ .file = file },
        });
    }
};

const Part = struct {
    name: []const u8,
    array_brackets: bool,
    value: union(enum) {
        text: []const u8,
        file: File,
    },
};

fn write(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(bytes);
}

fn writeDispositionParameter(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| switch (byte) {
        '\r' => try writer.writeAll("%0D"),
        '\n' => try writer.writeAll("%0A"),
        '"' => try writer.writeAll("%22"),
        '\\' => try writer.writeAll("%5C"),
        else => try writer.writeByte(byte),
    };
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.value(std.json.Value{ .string = value }, .{}, writer);
}

fn expectedBody(
    arena: Allocator,
    boundary: []const u8,
    body: []const u8,
) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, arena, body, "{s}", boundary);
}

test "multipart text-only body is byte exact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var form = try FormData.initFromSeed(arena, 1);
    try std.testing.expectEqualStrings("ai-zig-boundary-ok6kBazW58vL4O59", form.boundary);
    try form.appendText("model", "gpt-image-1");
    try form.appendText("prompt", "A cute cat");
    const encoded = try form.encode(arena);

    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{form.boundary}),
        encoded.content_type,
    );
    try std.testing.expectEqualStrings(try expectedBody(
        arena,
        form.boundary,
        "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"model\"\r\n\r\n" ++
            "gpt-image-1\r\n" ++
            "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n" ++
            "A cute cat\r\n" ++
            "--{s}--\r\n",
    ), encoded.body);
}

test "multipart file body includes filename and content type byte exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var form = try FormData.initFromSeed(arena, 2);
    try std.testing.expectEqualStrings("ai-zig-boundary-lXeIUlKjTrVgfsyS", form.boundary);
    try form.appendFile("file", "audio.wav", "audio/wav", &.{ 0x00, 0xff, 0x41 });
    const encoded = try form.encode(arena);
    try std.testing.expectEqualStrings(try expectedBody(
        arena,
        form.boundary,
        "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n" ++
            "Content-Type: audio/wav\r\n\r\n" ++
            "\x00\xffA\r\n" ++
            "--{s}--\r\n",
    ), encoded.body);
}

test "multipart single-element array uses the plain key byte exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var form = try FormData.initFromSeed(arena, 3);
    try std.testing.expectEqualStrings("ai-zig-boundary-3erqc6BcY1ZCLS3U", form.boundary);
    try form.appendTextArray("include", &.{"logprobs"});
    const encoded = try form.encode(arena);
    try std.testing.expectEqualStrings(try expectedBody(
        arena,
        form.boundary,
        "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"include\"\r\n\r\n" ++
            "logprobs\r\n" ++
            "--{s}--\r\n",
    ), encoded.body);
    try std.testing.expect(std.mem.indexOf(u8, encoded.body, "name=\"include[]\"") == null);
}

test "multipart multi-element array uses key brackets for every item byte exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var form = try FormData.initFromSeed(arena, 4);
    try std.testing.expectEqualStrings("ai-zig-boundary-gbFi9ldxQBCkbg3p", form.boundary);
    try form.appendTextArray("timestamp_granularities", &.{ "word", "segment" });
    const encoded = try form.encode(arena);
    try std.testing.expectEqualStrings(try expectedBody(
        arena,
        form.boundary,
        "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n" ++
            "word\r\n" ++
            "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n" ++
            "segment\r\n" ++
            "--{s}--\r\n",
    ), encoded.body);
}

test "multipart escapes disposition parameters rejects header injection and redacts file bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var form = try FormData.initFromSeed(arena, 5);
    try form.appendText("line\r\n\"\\name", "safe text");
    try form.appendFile("file", "bad\r\n\"\\name.png", "image/png", "secret-binary");
    try std.testing.expectError(
        error.InvalidArgumentError,
        form.appendFile("file", "audio.wav", "audio/wav\r\nx-injected: yes", "audio"),
    );

    const encoded = try form.encode(arena);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded.body,
        "name=\"line%0D%0A%22%5Cname\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded.body,
        "filename=\"bad%0D%0A%22%5Cname.png\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded.body, "x-injected") == null);

    const summary = try form.diagnosticJson(arena);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, summary, .{});
    try std.testing.expectEqual(2, parsed.object.get("parts").?.array.items.len);
    const file = parsed.object.get("parts").?.array.items[1].object.get("file").?.object;
    try std.testing.expectEqual(13, file.get("size").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, summary, "secret-binary") == null);
}

test "multipart rejects a boundary generator with the wrong contract" {
    var generator = try id_api.IdGenerator.init(1, .{}, null);
    try std.testing.expectError(
        error.InvalidArgumentError,
        FormData.init(std.testing.allocator, &generator),
    );
}
