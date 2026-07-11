const std = @import("std");
const provider = @import("provider");
const transport_api = @import("http_transport.zig");
const headers_api = @import("headers.zig");
const base64 = @import("base64.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    max_size: usize = 2 * 1024 * 1024 * 1024,
    max_redirects: u16 = 10,
    headers: []const provider.Header = &.{},
};

pub const Result = struct {
    data: []const u8,
    media_type: ?[]const u8 = null,
};

pub fn validateDownloadUrl(url: []const u8) error{DownloadError}!void {
    const uri = std.Uri.parse(url) catch return error.DownloadError;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "data")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        return error.DownloadError;
    }

    const host_component = uri.host orelse return error.DownloadError;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var host = host_component.toRaw(&host_buffer) catch return error.DownloadError;
    if (host.len == 0) return error.DownloadError;

    if (host[0] == '[') {
        if (host.len < 2 or host[host.len - 1] != ']') return error.DownloadError;
        if (isPrivateIpv6(host[1 .. host.len - 1])) return error.DownloadError;
        return;
    }

    while (host.len != 0 and host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0) return error.DownloadError;

    var lowercase_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const lowercase = lowercase_buffer[0..host.len];
    for (host, lowercase) |source, *destination| destination.* = std.ascii.toLower(source);
    if (std.mem.eql(u8, lowercase, "localhost") or
        std.mem.endsWith(u8, lowercase, ".local") or
        std.mem.endsWith(u8, lowercase, ".localhost"))
    {
        return error.DownloadError;
    }

    if (parseIpv4Url(lowercase)) |address| {
        if (isPrivateIpv4(address)) return error.DownloadError;
    }
}

pub fn download(
    io: std.Io,
    arena: Allocator,
    transport: transport_api.HttpTransport,
    url: []const u8,
    options: Options,
    diag: ?*provider.Diagnostics,
) transport_api.RequestError!Result {
    try validateWithDiagnostics(arena, url, diag);
    if (std.ascii.startsWithIgnoreCase(url, "data:")) {
        return decodeDataUrl(arena, url, options.max_size, diag);
    }

    const request_headers = try headers_api.withUserAgentSuffix(arena, options.headers, &.{
        "ai-sdk-zig/provider-utils/0.0.0",
        "runtime/zig/" ++ @import("builtin").zig_version_string,
    });

    var current_url: []const u8 = try arena.dupe(u8, url);
    var redirect_count: u16 = 0;
    while (redirect_count <= options.max_redirects) : (redirect_count += 1) {
        try validateWithDiagnostics(arena, current_url, diag);
        var response = try transport.request(io, arena, .{
            .method = .GET,
            .url = current_url,
            .headers = request_headers,
            .redirect_behavior = .unhandled,
        }, diag);
        var body_owned = true;
        defer if (body_owned) response.body.deinit(io);

        if (response.status >= 300 and response.status < 400) {
            if (headers_api.getHeader(response.headers, "location")) |location| {
                response.body.deinit(io);
                body_owned = false;
                current_url = resolveRedirect(arena, current_url, location) catch |err| {
                    setDownloadError(
                        arena,
                        diag,
                        url,
                        response.status,
                        response.status_text,
                        @errorName(err),
                    );
                    return error.DownloadError;
                };
                continue;
            }
        }

        if (response.status < 200 or response.status >= 300) {
            setDownloadError(
                arena,
                diag,
                current_url,
                response.status,
                response.status_text,
                null,
            );
            return error.DownloadError;
        }

        if (headers_api.getHeader(response.headers, "content-length")) |value| {
            if (std.fmt.parseInt(u64, value, 10)) |content_length| {
                if (content_length > options.max_size) {
                    setSizeError(arena, diag, current_url, options.max_size);
                    return error.DownloadError;
                }
            } else |_| {}
        }

        const data = transport_api.readBodyWithLimit(
            arena,
            &response.body,
            options.max_size,
        ) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => {
                setSizeError(arena, diag, current_url, options.max_size);
                return error.DownloadError;
            },
            error.ReadFailed => {
                setDownloadError(
                    arena,
                    diag,
                    current_url,
                    response.status,
                    response.status_text,
                    @errorName(err),
                );
                return error.DownloadError;
            },
        };
        return .{
            .data = data,
            .media_type = headers_api.getHeader(response.headers, "content-type"),
        };
    }

    var message_buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "Too many redirects (max {d})",
        .{options.max_redirects},
    ) catch "Too many redirects";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
        .message = message,
        .url = url,
    } });
    return error.DownloadError;
}

fn decodeDataUrl(
    arena: Allocator,
    url: []const u8,
    max_size: usize,
    diag: ?*provider.Diagnostics,
) transport_api.RequestError!Result {
    const comma = std.mem.findScalar(u8, url, ',') orelse {
        setDownloadError(arena, diag, url, null, null, "Invalid data URL");
        return error.DownloadError;
    };
    const header = url["data:".len..comma];
    const payload = url[comma + 1 ..];
    const semicolon = std.mem.findScalar(u8, header, ';') orelse header.len;
    const media_type = if (semicolon == 0)
        null
    else
        try arena.dupe(u8, header[0..semicolon]);
    const is_base64 = std.mem.indexOf(u8, header[semicolon..], ";base64") != null;
    const data = if (is_base64)
        base64.decode(arena, payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                setDownloadError(arena, diag, url, null, null, "Invalid base64 data URL");
                return error.DownloadError;
            },
        }
    else
        try percentDecode(arena, payload);
    if (data.len > max_size) {
        setSizeError(arena, diag, url, max_size);
        return error.DownloadError;
    }
    return .{ .data = data, .media_type = media_type };
}

fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error![]u8 {
    const result = try arena.alloc(u8, text.len);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < text.len) {
        if (text[input_index] == '%' and input_index + 2 < text.len) {
            const byte = std.fmt.parseInt(u8, text[input_index + 1 .. input_index + 3], 16) catch {
                result[output_index] = text[input_index];
                input_index += 1;
                output_index += 1;
                continue;
            };
            result[output_index] = byte;
            input_index += 3;
            output_index += 1;
        } else {
            result[output_index] = text[input_index];
            input_index += 1;
            output_index += 1;
        }
    }
    return result[0..output_index];
}

fn resolveRedirect(
    arena: Allocator,
    current_url: []const u8,
    location: []const u8,
) ![]const u8 {
    if (std.Uri.parse(location)) |_| return arena.dupe(u8, location) else |_| {}
    const base = try std.Uri.parse(current_url);
    const auxiliary = try arena.alloc(u8, current_url.len + location.len + 8192);
    @memcpy(auxiliary[0..location.len], location);
    var unused = auxiliary;
    const resolved = try base.resolveInPlace(location.len, &unused);
    return std.fmt.allocPrint(arena, "{f}", .{&resolved});
}

fn validateWithDiagnostics(
    arena: Allocator,
    url: []const u8,
    diag: ?*provider.Diagnostics,
) transport_api.RequestError!void {
    validateDownloadUrl(url) catch {
        provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
            .message = "URL is not allowed for download",
            .url = url,
        } });
        return error.DownloadError;
    };
}

fn setDownloadError(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    url: []const u8,
    status_code: ?u16,
    status_text: ?[]const u8,
    cause: ?[]const u8,
) void {
    const message = status_text orelse cause orelse "Download failed";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
        .message = message,
        .url = url,
        .status_code = status_code,
        .status_text = status_text,
        .cause_message = cause,
    } });
}

fn setSizeError(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    url: []const u8,
    max_size: usize,
) void {
    var message_buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "Download of {s} exceeded maximum size of {d} bytes.",
        .{ url, max_size },
    ) catch "Download exceeded maximum size";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
        .message = message,
        .url = url,
    } });
}

fn parseIpv4Url(host: []const u8) ?[4]u8 {
    var parts: [4]u64 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, host, '.');
    while (iterator.next()) |part| {
        if (count == parts.len or part.len == 0) return null;
        parts[count] = parseIpv4Part(part) orelse return null;
        count += 1;
    }
    if (count == 0) return null;

    for (parts[0 .. count - 1]) |part| if (part > 255) return null;
    const last_bits: u6 = @intCast(8 * (5 - count));
    const last_max: u64 = if (last_bits == 32)
        std.math.maxInt(u32)
    else
        (@as(u64, 1) << last_bits) - 1;
    if (parts[count - 1] > last_max) return null;

    var address: u32 = 0;
    for (parts[0 .. count - 1], 0..) |part, index| {
        address |= @as(u32, @intCast(part)) << @intCast(24 - 8 * index);
    }
    address |= @intCast(parts[count - 1]);
    return .{
        @intCast(address >> 24),
        @intCast((address >> 16) & 0xff),
        @intCast((address >> 8) & 0xff),
        @intCast(address & 0xff),
    };
}

fn parseIpv4Part(part: []const u8) ?u64 {
    if (part.len > 2 and part[0] == '0' and (part[1] == 'x' or part[1] == 'X')) {
        return std.fmt.parseInt(u64, part[2..], 16) catch null;
    }
    if (part.len > 1 and part[0] == '0') {
        return std.fmt.parseInt(u64, part[1..], 8) catch null;
    }
    return std.fmt.parseInt(u64, part, 10) catch null;
}

fn isPrivateIpv4(address: [4]u8) bool {
    const a = address[0];
    const b = address[1];
    const c = address[2];
    if (a == 0 or a == 10 or a == 127 or a >= 240) return true;
    if (a == 100 and b >= 64 and b <= 127) return true;
    if (a == 169 and b == 254) return true;
    if (a == 172 and b >= 16 and b <= 31) return true;
    if (a == 192 and b == 0 and c == 0) return true;
    if (a == 192 and b == 168) return true;
    if (a == 198 and (b == 18 or b == 19)) return true;
    return false;
}

fn isPrivateIpv6(input: []const u8) bool {
    const zone = std.mem.findScalar(u8, input, '%') orelse input.len;
    const parsed = std.Io.net.Ip6Address.parse(input[0..zone], 0) catch return true;
    const bytes = parsed.bytes;

    var first_fifteen_zero = true;
    for (bytes[0..15]) |byte| first_fifteen_zero = first_fifteen_zero and byte == 0;
    if (first_fifteen_zero and (bytes[15] == 0 or bytes[15] == 1)) return true;
    if ((bytes[0] & 0xfe) == 0xfc) return true;
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return true;
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0xc0) return true;
    if (bytes[0] == 0xff) return true;

    const compatible = allZero(bytes[0..12]);
    const mapped = allZero(bytes[0..10]) and bytes[10] == 0xff and bytes[11] == 0xff;
    const translated = allZero(bytes[0..8]) and bytes[8] == 0xff and bytes[9] == 0xff and
        bytes[10] == 0 and bytes[11] == 0;
    const nat64_well_known = std.mem.eql(u8, bytes[0..4], &.{ 0x00, 0x64, 0xff, 0x9b }) and
        allZero(bytes[4..12]);
    const nat64_local = std.mem.eql(u8, bytes[0..6], &.{ 0x00, 0x64, 0xff, 0x9b, 0x00, 0x01 });
    if (compatible or mapped or translated or nat64_well_known or nat64_local) {
        return isPrivateIpv4(bytes[12..16].*);
    }
    return false;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

test "download validateDownloadUrl SSRF table" {
    const blocked = [_][]const u8{
        "file:///etc/passwd",
        "ftp://example.com/file",
        "http://localhost/file",
        "http://localhost./file",
        "http://host.local/file",
        "http://app.localhost/file",
        "http://10.0.0.1/file",
        "http://172.16.0.1/file",
        "http://172.31.255.255/file",
        "http://192.168.1.1/file",
        "http://169.254.169.254/file",
        "http://100.64.0.1/file",
        "http://192.0.0.1/file",
        "http://198.18.0.1/file",
        "http://240.0.0.1/file",
        "http://2130706433/file",
        "http://0x7f000001/file",
        "http://0177.0.0.1/file",
        "http://[::1]/file",
        "http://[fe80::1]/file",
        "http://[fc00::1]/file",
        "http://[fec0::1]/file",
        "http://[ff02::1]/file",
        "http://[::ffff:10.0.0.1]/file",
        "http://[64:ff9b::169.254.169.254]/file",
    };
    for (blocked) |url| try std.testing.expectError(error.DownloadError, validateDownloadUrl(url));

    const allowed = [_][]const u8{
        "https://example.com/file",
        "http://203.0.113.1/file",
        "http://172.15.0.1/file",
        "http://172.32.0.1/file",
        "http://[2001:db8::1]/file",
        "http://[::ffff:203.0.113.1]/file",
        "data:text/plain;base64,aGVsbG8=",
    };
    for (allowed) |url| try validateDownloadUrl(url);
}

test "download data URL decodes base64 and percent encoding" {
    const Noop = struct {
        fn request(
            _: *anyopaque,
            _: std.Io,
            _: Allocator,
            _: transport_api.RequestSpec,
            _: ?*provider.Diagnostics,
        ) transport_api.RequestError!transport_api.Response {
            unreachable;
        }
    };
    var context: u8 = 0;
    const transport: transport_api.HttpTransport = .{
        .ctx = &context,
        .vtable = &.{ .request = Noop.request },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const encoded = try download(
        std.testing.io,
        arena,
        transport,
        "data:text/plain;base64,aGVsbG8=",
        .{},
        null,
    );
    try std.testing.expectEqualStrings("hello", encoded.data);
    try std.testing.expectEqualStrings("text/plain", encoded.media_type.?);

    const percent = try download(
        std.testing.io,
        arena,
        transport,
        "data:text/plain,hello%20world",
        .{},
        null,
    );
    try std.testing.expectEqualStrings("hello world", percent.data);
}
