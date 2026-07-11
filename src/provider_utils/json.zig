const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub fn SafeParseResult(comptime T: type) type {
    return union(enum) {
        success: struct {
            value: T,
            raw: []const u8,
        },
        failure: struct {
            raw: []const u8,
            message: []const u8,
        },
    };
}

pub fn SafeValidationResult(comptime T: type) type {
    return union(enum) {
        success: struct {
            value: T,
            raw: std.json.Value,
        },
        failure: struct {
            raw: std.json.Value,
            message: []const u8,
        },
    };
}

/// Zig has no prototype chain, so the upstream secure-json-parse prototype
/// pollution guard is intentionally unnecessary (fidelity ledger item 2).
pub fn parseJson(
    comptime T: type,
    arena: Allocator,
    text: []const u8,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .json_parse = .{
                .message = "Failed to parse JSON",
                .text = text,
                .cause_message = @errorName(err),
            } });
            return error.JSONParseError;
        },
    };
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

pub fn safeParseJson(
    comptime T: type,
    arena: Allocator,
    text: []const u8,
) SafeParseResult(T) {
    const value = std.json.parseFromSliceLeaky(T, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch |err| return .{ .failure = .{
        .raw = text,
        .message = @errorName(err),
    } };
    return .{ .success = .{ .value = value, .raw = text } };
}

pub fn validateTypes(
    comptime T: type,
    arena: Allocator,
    value: std.json.Value,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!T {
    return std.json.parseFromValueLeaky(T, arena, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .type_validation = .{
                .message = "Type validation failed",
                .cause_message = @errorName(err),
            } });
            return error.TypeValidationError;
        },
    };
}

pub fn safeValidateTypes(
    comptime T: type,
    arena: Allocator,
    value: std.json.Value,
) SafeValidationResult(T) {
    const parsed = std.json.parseFromValueLeaky(T, arena, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| return .{ .failure = .{
        .raw = value,
        .message = @errorName(err),
    } };
    return .{ .success = .{ .value = parsed, .raw = value } };
}

pub fn isParsableJson(input: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, input, .{}) catch
        return false;
    parsed.deinit();
    return true;
}

test "json parse safe and diagnostic paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Shape = struct { foo: []const u8 };
    const parsed = try parseJson(Shape, arena, "{\"foo\":\"bar\",\"extra\":1}", null);
    try std.testing.expectEqualStrings("bar", parsed.foo);

    switch (safeParseJson(Shape, arena, "invalid")) {
        .failure => |failure| try std.testing.expectEqualStrings("invalid", failure.raw),
        .success => return error.UnexpectedSuccess,
    }
    try std.testing.expect(isParsableJson("[1,2,3]"));
    try std.testing.expect(!isParsableJson("[1,"));

    const dynamic = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"foo\":\"typed\"}",
        .{},
    );
    const validated = try validateTypes(Shape, arena, dynamic, null);
    try std.testing.expectEqualStrings("typed", validated.foo);
}
