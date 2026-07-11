const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

const Allocator = std.mem.Allocator;

pub fn failedResponseHandler() provider_utils.ErrorResponseHandler {
    return .{ .handle_fn = handleFailure };
}

pub fn streamError(
    arena: Allocator,
    frame: std.json.Value,
    url: []const u8,
    request_body_json: []const u8,
    response_headers: []const provider.Header,
    diag: ?*provider.Diagnostics,
) (provider.Error || Allocator.Error)!void {
    const parsed = parseStreamError(frame);
    const status = if (parsed) |item| inferStatus(item.code, item.error_type) else 500;
    const response_body = try provider_utils.stringifyJsonValueAlloc(arena, frame);
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = if (parsed) |item| item.message else "OpenAI stream failed before any output was generated",
        .url = url,
        .status_code = status,
        .response_headers = response_headers,
        .response_body = response_body,
        .is_retryable = provider.isRetryableStatus(status),
        .request_body_json = request_body_json,
        .data_json = response_body,
    } });
    return error.APICallError;
}

const StreamError = struct {
    message: []const u8,
    code: ?std.json.Value = null,
    error_type: ?[]const u8 = null,
};

fn parseStreamError(frame: std.json.Value) ?StreamError {
    if (frame != .object) return null;
    if (optionalString(frame.object, "type")) |frame_type| {
        if (std.mem.eql(u8, frame_type, "response.failed")) {
            const response = objectField(frame.object, "response") orelse return null;
            const response_error = objectField(response, "error") orelse return null;
            return .{
                .message = optionalString(response_error, "message") orelse return null,
                .code = response_error.get("code"),
                .error_type = "response.failed",
            };
        }
    }
    const error_object = objectField(frame.object, "error") orelse frame.object;
    const message = optionalString(error_object, "message") orelse return null;
    if (objectField(frame.object, "error") == null and
        optionalString(error_object, "type") == null and
        error_object.get("code") == null and
        error_object.get("param") == null)
    {
        return null;
    }
    return .{
        .message = message,
        .code = error_object.get("code"),
        .error_type = optionalString(error_object, "type"),
    };
}

fn inferStatus(code: ?std.json.Value, error_type: ?[]const u8) u16 {
    if (code) |value| switch (value) {
        .integer => |number| if (number >= 400 and number <= 599) return @intCast(number),
        .float => |number| if (number >= 400 and number <= 599 and @floor(number) == number) return @intFromFloat(number),
        .string => |text| if (text.len == 3) {
            const parsed = std.fmt.parseInt(u16, text, 10) catch 0;
            if (parsed >= 400 and parsed <= 599) return parsed;
        },
        else => {},
    };

    var code_buffer: [32]u8 = undefined;
    const code_text = if (code) |value| switch (value) {
        .string => |text| text,
        .integer => |number| std.fmt.bufPrint(&code_buffer, "{d}", .{number}) catch "",
        else => "",
    } else "";
    const type_text = error_type orelse "";
    var buffer: [512]u8 = undefined;
    const discriminator = std.fmt.bufPrint(&buffer, "{s} {s}", .{ code_text, type_text }) catch type_text;
    var lowercase: [512]u8 = undefined;
    const length = @min(discriminator.len, lowercase.len);
    for (discriminator[0..length], lowercase[0..length]) |source, *destination| destination.* = std.ascii.toLower(source);
    const text = lowercase[0..length];
    if (containsAny(text, &.{ "insufficient_quota", "rate_limit" })) return 429;
    if (std.mem.indexOf(u8, text, "authentication") != null) return 401;
    if (std.mem.indexOf(u8, text, "permission") != null) return 403;
    if (std.mem.indexOf(u8, text, "not_found") != null) return 404;
    if (containsAny(text, &.{ "invalid", "bad_request", "context_length" })) return 400;
    if (std.mem.indexOf(u8, text, "overload") != null) return 503;
    if (std.mem.indexOf(u8, text, "timeout") != null) return 504;
    return 500;
}

fn handleFailure(
    _: ?*anyopaque,
    _: std.Io,
    arena: Allocator,
    response: *provider_utils.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    diag: ?*provider.Diagnostics,
) provider_utils.RequestError!void {
    const body = provider_utils.http_transport.readBodyWithLimit(
        arena,
        &response.body,
        provider_utils.api.default_max_response_size,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setDiagnostic(arena, response, url, request_body_json, null, "Failed to read OpenAI error response", diag);
            return error.APICallError;
        },
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch null;
    const message = if (parsed) |value|
        if (value == .object)
            if (objectField(value.object, "error")) |error_object|
                optionalString(error_object, "message") orelse response.status_text
            else
                response.status_text
        else
            response.status_text
    else
        response.status_text;
    setDiagnostic(arena, response, url, request_body_json, body, message, diag);
    return error.APICallError;
}

fn setDiagnostic(
    arena: Allocator,
    response: *const provider_utils.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    response_body: ?[]const u8,
    message: []const u8,
    diag: ?*provider.Diagnostics,
) void {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .status_code = response.status,
        .response_headers = response.headers,
        .response_body = response_body,
        .is_retryable = provider.isRetryableStatus(response.status),
        .request_body_json = request_body_json,
        .data_json = response_body,
    } });
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

test "OpenAI early stream errors infer status codes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const auth = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"error\":{\"message\":\"bad key\",\"type\":\"authentication_error\"}}", .{});
    const rate = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"error\":{\"message\":\"slow down\",\"code\":\"rate_limit_exceeded\"}}", .{});
    try std.testing.expectEqual(401, inferStatus(parseStreamError(auth).?.code, parseStreamError(auth).?.error_type));
    try std.testing.expectEqual(429, inferStatus(parseStreamError(rate).?.code, parseStreamError(rate).?.error_type));
}
