const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const HeaderEntry = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Combines and normalizes header lists. Names are lowercased, later entries
/// win case-insensitively, and a null value removes an earlier entry.
pub fn combineHeaders(
    arena: Allocator,
    lists: []const []const HeaderEntry,
) Allocator.Error![]const provider.Header {
    var combined: std.ArrayList(HeaderEntry) = .empty;
    defer combined.deinit(arena);

    for (lists) |list| {
        for (list) |entry| {
            const existing = findEntry(combined.items, entry.name);
            if (entry.value) |value| {
                const normalized_name = try lowercaseAlloc(arena, entry.name);
                const normalized_value = try arena.dupe(u8, value);
                if (existing) |index| {
                    combined.items[index] = .{
                        .name = normalized_name,
                        .value = normalized_value,
                    };
                } else {
                    try combined.append(arena, .{
                        .name = normalized_name,
                        .value = normalized_value,
                    });
                }
            } else if (existing) |index| {
                _ = combined.orderedRemove(index);
            }
        }
    }

    const result = try arena.alloc(provider.Header, combined.items.len);
    for (combined.items, result) |entry, *header| {
        header.* = .{ .name = entry.name, .value = entry.value.? };
    }
    return result;
}

pub fn normalizeHeaders(
    arena: Allocator,
    entries: []const HeaderEntry,
) Allocator.Error![]const provider.Header {
    const lists = [_][]const HeaderEntry{entries};
    return combineHeaders(arena, &lists);
}

/// Returns normalized arena-owned headers with the suffixes appended to the
/// existing user-agent value, separated by one space.
pub fn withUserAgentSuffix(
    arena: Allocator,
    headers: []const provider.Header,
    suffixes: []const []const u8,
) Allocator.Error![]const provider.Header {
    const entries = try arena.alloc(HeaderEntry, headers.len);
    for (headers, entries) |header, *entry| {
        entry.* = .{ .name = header.name, .value = header.value };
    }
    const normalized = try normalizeHeaders(arena, entries);

    var suffix_len: usize = 0;
    var suffix_count: usize = 0;
    for (suffixes) |suffix| {
        if (suffix.len == 0) continue;
        suffix_len += suffix.len;
        suffix_count += 1;
    }

    const existing_index = findHeader(normalized, "user-agent");
    const existing = if (existing_index) |index| normalized[index].value else "";
    const separator_count = if (existing.len == 0)
        if (suffix_count == 0) 0 else suffix_count - 1
    else
        suffix_count;
    const user_agent = try arena.alloc(u8, existing.len + suffix_len + separator_count);

    var cursor: usize = 0;
    if (existing.len != 0) {
        @memcpy(user_agent[cursor..][0..existing.len], existing);
        cursor += existing.len;
    }
    for (suffixes) |suffix| {
        if (suffix.len == 0) continue;
        if (cursor != 0) {
            user_agent[cursor] = ' ';
            cursor += 1;
        }
        @memcpy(user_agent[cursor..][0..suffix.len], suffix);
        cursor += suffix.len;
    }

    if (existing_index) |index| {
        const result = try arena.alloc(provider.Header, normalized.len);
        @memcpy(result, normalized);
        result[index].value = user_agent;
        return result;
    }

    const result = try arena.alloc(provider.Header, normalized.len + 1);
    @memcpy(result[0..normalized.len], normalized);
    result[normalized.len] = .{ .name = "user-agent", .value = user_agent };
    return result;
}

pub fn getHeader(headers: []const provider.Header, name: []const u8) ?[]const u8 {
    const index = findHeader(headers, name) orelse return null;
    return headers[index].value;
}

fn findEntry(entries: []const HeaderEntry, name: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return index;
    }
    return null;
}

fn findHeader(headers: []const provider.Header, name: []const u8) ?usize {
    for (headers, 0..) |header, index| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return index;
    }
    return null;
}

fn lowercaseAlloc(arena: Allocator, name: []const u8) Allocator.Error![]u8 {
    const result = try arena.alloc(u8, name.len);
    for (name, result) |source, *destination| destination.* = std.ascii.toLower(source);
    return result;
}

test "headers combine later wins and null removes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = [_]HeaderEntry{
        .{ .name = "Authorization", .value = "first" },
        .{ .name = "X-Remove", .value = "present" },
    };
    const second = [_]HeaderEntry{
        .{ .name = "authorization", .value = "second" },
        .{ .name = "x-remove", .value = null },
        .{ .name = "X-New", .value = "new" },
    };
    const lists = [_][]const HeaderEntry{ &first, &second };
    const result = try combineHeaders(arena, &lists);

    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqualStrings("second", getHeader(result, "AUTHORIZATION").?);
    try std.testing.expectEqualStrings("new", getHeader(result, "x-new").?);
    try std.testing.expectEqual(null, getHeader(result, "x-remove"));
}

test "headers user-agent suffix creates and appends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const created = try withUserAgentSuffix(arena, &.{}, &.{ "ai-sdk-zig/0", "runtime/zig/0.16.0" });
    try std.testing.expectEqualStrings(
        "ai-sdk-zig/0 runtime/zig/0.16.0",
        getHeader(created, "user-agent").?,
    );

    const appended = try withUserAgentSuffix(
        arena,
        &.{.{ .name = "User-Agent", .value = "custom/1" }},
        &.{"suffix/2"},
    );
    try std.testing.expectEqualStrings("custom/1 suffix/2", getHeader(appended, "USER-AGENT").?);
}
