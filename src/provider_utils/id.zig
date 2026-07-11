const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

pub const IdGenerator = struct {
    pub const Options = struct {
        prefix: ?[]const u8 = null,
        separator: u8 = '-',
        size: usize = 16,
    };

    pub const InitError = error{InvalidArgumentError};

    prng: std.Random.DefaultPrng,
    prefix: ?[]const u8,
    separator: u8,
    size: usize,

    pub fn init(seed: u64, options: Options, diag: ?*provider.Diagnostics) InitError!IdGenerator {
        if (std.mem.indexOfScalar(u8, alphabet, options.separator) != null) {
            if (diag) |diagnostics| {
                var message_buffer: [192]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &message_buffer,
                    "The separator \"{c}\" must not be part of the ID alphabet.",
                    .{options.separator},
                ) catch "The separator must not be part of the ID alphabet.";
                const value_json = [_]u8{ '"', options.separator, '"' };
                provider.Diagnostics.set(diagnostics, diagnostics.allocator, .{ .invalid_argument = .{
                    .message = message,
                    .parameter = "separator",
                    .value_json = &value_json,
                } });
            }
            return error.InvalidArgumentError;
        }

        return .{
            .prng = .init(seed),
            .prefix = options.prefix,
            .separator = options.separator,
            .size = options.size,
        };
    }

    pub fn initFromIo(io: std.Io, options: Options, diag: ?*provider.Diagnostics) InitError!IdGenerator {
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        return init(seed, options, diag);
    }

    pub fn outputLen(self: *const IdGenerator) usize {
        return self.size + if (self.prefix) |prefix| prefix.len + 1 else 0;
    }

    pub fn next(self: *IdGenerator, buffer: []u8) []const u8 {
        const length = self.outputLen();
        std.debug.assert(buffer.len >= length);

        var cursor: usize = 0;
        if (self.prefix) |prefix| {
            @memcpy(buffer[0..prefix.len], prefix);
            cursor += prefix.len;
            buffer[cursor] = self.separator;
            cursor += 1;
        }

        const random = self.prng.random();
        for (buffer[cursor..length]) |*byte| {
            byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        }
        return buffer[0..length];
    }

    pub fn nextAlloc(self: *IdGenerator, allocator: Allocator) Allocator.Error![]u8 {
        const result = try allocator.alloc(u8, self.outputLen());
        _ = self.next(result);
        return result;
    }
};

test "IdGenerator emits prefixed IDs from the expected alphabet" {
    var generator = try IdGenerator.init(0x1234, .{ .prefix = "msg", .size = 12 }, null);
    var buffer: [32]u8 = undefined;
    const generated = generator.next(&buffer);

    try std.testing.expectEqual(16, generated.len);
    try std.testing.expectEqualStrings("msg-", generated[0..4]);
    for (generated[4..]) |byte| {
        try std.testing.expect(std.mem.indexOfScalar(u8, alphabet, byte) != null);
    }

    const allocated = try generator.nextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(allocated);
    try std.testing.expectEqual(16, allocated.len);

    var default_generator = try IdGenerator.init(0x1234, .{}, null);
    try std.testing.expectEqual(16, default_generator.next(&buffer).len);
}

test "IdGenerator rejects separators in the alphabet with diagnostics" {
    var diagnostics = provider.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.InvalidArgumentError,
        IdGenerator.init(1, .{ .prefix = "msg", .separator = 'a' }, &diagnostics),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings("separator", diagnostics.payload.invalid_argument.parameter);
    try std.testing.expectEqualStrings("\"a\"", diagnostics.payload.invalid_argument.value_json.?);
}
