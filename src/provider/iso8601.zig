//! ISO-8601 UTC timestamps used by provider V4 wire payloads.

const std = @import("std");

pub const Error = error{InvalidIso8601};

const milliseconds_per_second: i64 = 1_000;
const seconds_per_day: i64 = 86_400;

/// Parses the JavaScript `Date.toJSON()` subset used by the provider wire
/// format. Whole seconds and one to nine fractional digits are accepted; the
/// fraction is truncated or right-padded to epoch milliseconds.
pub fn parse(text: []const u8) Error!i64 {
    if (text.len < 20 or text[text.len - 1] != 'Z') return error.InvalidIso8601;
    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':') return error.InvalidIso8601;

    const year = parseDigits(text[0..4]) catch return error.InvalidIso8601;
    const month = parseDigits(text[5..7]) catch return error.InvalidIso8601;
    const day = parseDigits(text[8..10]) catch return error.InvalidIso8601;
    const hour = parseDigits(text[11..13]) catch return error.InvalidIso8601;
    const minute = parseDigits(text[14..16]) catch return error.InvalidIso8601;
    const second = parseDigits(text[17..19]) catch return error.InvalidIso8601;

    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59) return error.InvalidIso8601;

    var fraction_ms: i64 = 0;
    if (text.len != 20) {
        if (text.len < 22 or text[19] != '.') return error.InvalidIso8601;
        const fraction = text[20 .. text.len - 1];
        if (fraction.len == 0 or fraction.len > 9) return error.InvalidIso8601;
        const consumed = @min(fraction.len, 3);
        var digits: usize = 0;
        while (digits < consumed) : (digits += 1) {
            const byte = fraction[digits];
            if (byte < '0' or byte > '9') return error.InvalidIso8601;
            fraction_ms = fraction_ms * 10 + @as(i64, byte - '0');
        }
        while (digits < 3) : (digits += 1) fraction_ms *= 10;
        for (fraction[consumed..]) |byte| {
            if (byte < '0' or byte > '9') return error.InvalidIso8601;
        }
    }

    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const seconds = days * seconds_per_day +
        @as(i64, @intCast(hour)) * 3_600 +
        @as(i64, @intCast(minute)) * 60 +
        @as(i64, @intCast(second));
    return seconds * milliseconds_per_second + fraction_ms;
}

/// Formats epoch milliseconds with exactly three fractional digits and `Z`.
/// The returned slice points into `buffer`.
pub fn format(timestamp_ms: i64, buffer: *[24]u8) []const u8 {
    const seconds = @divFloor(timestamp_ms, milliseconds_per_second);
    const millis: u16 = @intCast(@mod(timestamp_ms, milliseconds_per_second));
    const days = @divFloor(seconds, seconds_per_day);
    const second_of_day: u32 = @intCast(@mod(seconds, seconds_per_day));
    const civil = civilFromDays(days);
    std.debug.assert(civil.year >= 0 and civil.year <= 9999);

    writeFour(buffer[0..4], @intCast(civil.year));
    buffer[4] = '-';
    writeTwo(buffer[5..7], civil.month);
    buffer[7] = '-';
    writeTwo(buffer[8..10], civil.day);
    buffer[10] = 'T';
    writeTwo(buffer[11..13], @intCast(second_of_day / 3_600));
    buffer[13] = ':';
    writeTwo(buffer[14..16], @intCast((second_of_day % 3_600) / 60));
    buffer[16] = ':';
    writeTwo(buffer[17..19], @intCast(second_of_day % 60));
    buffer[19] = '.';
    buffer[20] = @intCast('0' + millis / 100);
    buffer[21] = @intCast('0' + (millis / 10) % 10);
    buffer[22] = @intCast('0' + millis % 10);
    buffer[23] = 'Z';
    return buffer;
}

fn parseDigits(text: []const u8) error{InvalidIso8601}!u32 {
    var value: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidIso8601;
        value = value * 10 + byte - '0';
    }
    return value;
}

fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

// Howard Hinnant's civil calendar algorithms, with 1970-01-01 as day zero.
fn daysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    var year = year_input;
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

const Civil = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days_input: i64) Civil {
    const z = days_input + 719_468;
    const era = @divFloor(z, 146_097);
    const day_of_era = z - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1_460) +
            @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

fn writeTwo(destination: []u8, value: u8) void {
    destination[0] = '0' + value / 10;
    destination[1] = '0' + value % 10;
}

fn writeFour(destination: []u8, value: u16) void {
    destination[0] = @intCast('0' + (value / 1_000) % 10);
    destination[1] = @intCast('0' + (value / 100) % 10);
    destination[2] = @intCast('0' + (value / 10) % 10);
    destination[3] = @intCast('0' + value % 10);
}

test "wire iso8601 parses whole and fractional seconds" {
    try std.testing.expectEqual(@as(i64, 0), try parse("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1_741_177_696_789), try parse("2025-03-05T12:28:16.789Z"));
    try std.testing.expectEqual(@as(i64, 1_741_177_696_700), try parse("2025-03-05T12:28:16.7Z"));
    try std.testing.expectEqual(@as(i64, 1_741_177_696_789), try parse("2025-03-05T12:28:16.789123Z"));
}

test "wire iso8601 formats exact milliseconds" {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2025-03-05T12:28:16.789Z",
        format(try parse("2025-03-05T12:28:16.789Z"), &buffer),
    );
    try std.testing.expectEqualStrings(
        "1969-12-31T23:59:59.999Z",
        format(-1, &buffer),
    );
    try std.testing.expectEqualStrings(
        "2025-03-05T12:34:56.000Z",
        format(try parse("2025-03-05T12:34:56Z"), &buffer),
    );
}
