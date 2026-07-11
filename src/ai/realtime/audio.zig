//! Pure realtime PCM helpers.
//!
//! Every returned slice is allocated by the caller-provided allocator, even
//! when resampling between equal rates. This gives callers one unambiguous
//! ownership rule across the Zig and future C ABI surfaces.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DecodeError = Allocator.Error || std.base64.Error || error{InvalidPcmLength};
pub const ResampleError = Allocator.Error || error{InvalidSampleRate};

/// Converts normalized floating-point samples to base64-encoded signed PCM16
/// little-endian bytes. Values outside [-1, 1] are clamped; NaN becomes zero,
/// matching JavaScript's DataView integer conversion used upstream.
pub fn encode(allocator: Allocator, samples: []const f32) Allocator.Error![]u8 {
    const pcm = try allocator.alloc(u8, samples.len * 2);
    defer allocator.free(pcm);

    for (samples, 0..) |sample, index| {
        const clamped: f32 = if (std.math.isNan(sample))
            0
        else
            @max(-1, @min(1, sample));
        const scaled = if (clamped < 0) clamped * 32768 else clamped * 32767;
        const value: i16 = @intFromFloat(scaled);
        std.mem.writeInt(i16, pcm[index * 2 ..][0..2], value, .little);
    }

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(pcm.len));
    _ = std.base64.standard.Encoder.encode(encoded, pcm);
    return encoded;
}

/// Converts base64-encoded signed PCM16 little-endian bytes to normalized
/// floating-point samples. The result must be freed with `allocator`.
pub fn decode(allocator: Allocator, encoded: []const u8) DecodeError![]f32 {
    const byte_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const pcm = try allocator.alloc(u8, byte_len);
    defer allocator.free(pcm);
    try std.base64.standard.Decoder.decode(pcm, encoded);
    if (byte_len % 2 != 0) return error.InvalidPcmLength;

    const samples = try allocator.alloc(f32, byte_len / 2);
    errdefer allocator.free(samples);
    for (samples, 0..) |*sample, index| {
        const value = std.mem.readInt(i16, pcm[index * 2 ..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(value)) / 32768.0;
    }
    return samples;
}

/// Resamples with the same linear interpolation and length rounding as the
/// upstream realtime audio helper. The result must be freed with `allocator`.
pub fn resample(
    allocator: Allocator,
    input: []const f32,
    input_rate: u32,
    output_rate: u32,
) ResampleError![]f32 {
    if (input_rate == 0 or output_rate == 0) return error.InvalidSampleRate;
    if (input_rate == output_rate) return allocator.dupe(f32, input);

    const ratio = @as(f64, @floatFromInt(input_rate)) /
        @as(f64, @floatFromInt(output_rate));
    const output_len: usize = @intFromFloat(@round(
        @as(f64, @floatFromInt(input.len)) / ratio,
    ));
    const output = try allocator.alloc(f32, output_len);
    errdefer allocator.free(output);

    for (output, 0..) |*sample, index| {
        const source_index = @as(f64, @floatFromInt(index)) * ratio;
        const source_floor: usize = @intFromFloat(@floor(source_index));
        const source_ceil = @min(source_floor + 1, input.len - 1);
        const fraction = source_index - @as(f64, @floatFromInt(source_floor));
        const interpolated = @as(f64, input[source_floor]) * (1 - fraction) +
            @as(f64, input[source_ceil]) * fraction;
        sample.* = @floatCast(interpolated);
    }
    return output;
}

test "encode clamps and writes asymmetric PCM16 little endian" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, &.{ -1, -0.5, 0, 0.5, 1, 2, -2, std.math.nan(f32) });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("AIAAwAAA/z//f/9/AIAAAA==", encoded);
}

test "decode divides signed PCM16 values by 32768" {
    const allocator = std.testing.allocator;
    const samples = try decode(allocator, "AIAAwAAA/z//fw==");
    defer allocator.free(samples);

    try std.testing.expectEqualSlices(f32, &.{ -1, -0.5, 0, 16383.0 / 32768.0, 32767.0 / 32768.0 }, samples);
}

test "decode rejects invalid base64 and odd PCM byte counts" {
    try std.testing.expectError(error.InvalidCharacter, decode(std.testing.allocator, "!!!!"));
    try std.testing.expectError(error.InvalidPcmLength, decode(std.testing.allocator, "AA=="));
}

test "resample uses linear interpolation for upsampling and downsampling" {
    const allocator = std.testing.allocator;

    const upsampled = try resample(allocator, &.{ 0, 1 }, 2, 4);
    defer allocator.free(upsampled);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.5, 1, 1 }, upsampled);

    const downsampled = try resample(allocator, &.{ 0, 1, 0, -1 }, 4, 3);
    defer allocator.free(downsampled);
    try std.testing.expectApproxEqAbs(@as(f32, 0), downsampled[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), downsampled[1], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0 / 3.0), downsampled[2], 0.00001);
}

test "resample rounds output length and always returns owned storage" {
    const allocator = std.testing.allocator;

    const rounded = try resample(allocator, &.{ 1, 2, 3 }, 4, 2);
    defer allocator.free(rounded);
    try std.testing.expectEqual(@as(usize, 2), rounded.len);
    try std.testing.expectEqualSlices(f32, &.{ 1, 3 }, rounded);

    const same_rate_input = [_]f32{ 0.25, -0.25 };
    const same_rate = try resample(allocator, &same_rate_input, 24_000, 24_000);
    defer allocator.free(same_rate);
    try std.testing.expectEqualSlices(f32, &same_rate_input, same_rate);
    try std.testing.expect(same_rate.ptr != same_rate_input[0..].ptr);
}

test "resample handles empty input and rejects zero rates" {
    const allocator = std.testing.allocator;
    const empty = try resample(allocator, &.{}, 48_000, 24_000);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try std.testing.expectError(error.InvalidSampleRate, resample(allocator, &.{1}, 0, 24_000));
    try std.testing.expectError(error.InvalidSampleRate, resample(allocator, &.{1}, 24_000, 0));
}
