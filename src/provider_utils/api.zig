const std = @import("std");
const builtin = @import("builtin");
const provider = @import("provider");
const transport_api = @import("http_transport.zig");
const headers_api = @import("headers.zig");
const sse = @import("sse.zig");
const package_version = @import("version.zig").value;

const Allocator = std.mem.Allocator;

pub const ApiError = transport_api.RequestError;
pub const default_max_response_size: usize = 2 * 1024 * 1024 * 1024;

pub const PostJsonOptions = struct {
    url: []const u8,
    headers: []const provider.Header = &.{},
    body_json: []const u8,
};

pub const GetOptions = struct {
    url: []const u8,
    headers: []const provider.Header = &.{},
};

pub fn ApiResult(comptime T: type) type {
    return struct {
        value: T,
        response_headers: []const provider.Header,
        raw_body: ?[]const u8 = null,
    };
}

pub fn HandlerResult(comptime T: type) type {
    return struct {
        value: T,
        raw_body: ?[]const u8 = null,
        body_transferred: bool = false,
    };
}

pub fn ResponseHandler(comptime T: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        handle_fn: *const fn (
            ctx: ?*anyopaque,
            io: std.Io,
            arena: Allocator,
            response: *transport_api.Response,
            url: []const u8,
            request_body_json: ?[]const u8,
            diag: ?*provider.Diagnostics,
        ) ApiError!HandlerResult(T),

        pub fn handle(
            self: @This(),
            io: std.Io,
            arena: Allocator,
            response: *transport_api.Response,
            url: []const u8,
            request_body_json: ?[]const u8,
            diag: ?*provider.Diagnostics,
        ) ApiError!HandlerResult(T) {
            return self.handle_fn(
                self.ctx,
                io,
                arena,
                response,
                url,
                request_body_json,
                diag,
            );
        }
    };
}

pub const ErrorResponseHandler = struct {
    ctx: ?*anyopaque = null,
    handle_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        response: *transport_api.Response,
        url: []const u8,
        request_body_json: ?[]const u8,
        diag: ?*provider.Diagnostics,
    ) ApiError!void,

    pub fn handle(
        self: ErrorResponseHandler,
        io: std.Io,
        arena: Allocator,
        response: *transport_api.Response,
        url: []const u8,
        request_body_json: ?[]const u8,
        diag: ?*provider.Diagnostics,
    ) ApiError!void {
        return self.handle_fn(
            self.ctx,
            io,
            arena,
            response,
            url,
            request_body_json,
            diag,
        );
    }
};

pub fn Handlers(comptime T: type) type {
    return struct {
        success: ResponseHandler(T),
        failure: ErrorResponseHandler,
    };
}

pub fn postJsonToApi(
    comptime T: type,
    io: std.Io,
    arena: Allocator,
    transport: transport_api.HttpTransport,
    options: PostJsonOptions,
    handlers: Handlers(T),
    diag: ?*provider.Diagnostics,
) ApiError!ApiResult(T) {
    var base_headers = try arena.alloc(provider.Header, options.headers.len + 1);
    var header_start: usize = 0;
    if (headers_api.getHeader(options.headers, "content-type") == null) {
        base_headers[0] = .{ .name = "content-type", .value = "application/json" };
        header_start = 1;
    }
    @memcpy(base_headers[header_start .. header_start + options.headers.len], options.headers);
    base_headers = base_headers[0 .. header_start + options.headers.len];
    const request_headers = try appendSdkUserAgent(arena, base_headers);

    return callApi(T, io, arena, transport, .{
        .method = .POST,
        .url = options.url,
        .headers = request_headers,
        .body = options.body_json,
    }, options.body_json, handlers, diag);
}

pub fn getFromApi(
    comptime T: type,
    io: std.Io,
    arena: Allocator,
    transport: transport_api.HttpTransport,
    options: GetOptions,
    handlers: Handlers(T),
    diag: ?*provider.Diagnostics,
) ApiError!ApiResult(T) {
    const request_headers = try appendSdkUserAgent(arena, options.headers);
    return callApi(T, io, arena, transport, .{
        .method = .GET,
        .url = options.url,
        .headers = request_headers,
    }, null, handlers, diag);
}

fn appendSdkUserAgent(
    arena: Allocator,
    headers: []const provider.Header,
) Allocator.Error![]const provider.Header {
    return headers_api.withUserAgentSuffix(arena, headers, &.{
        "ai-sdk-zig/provider-utils/" ++ package_version,
        "runtime/zig/" ++ builtin.zig_version_string,
    });
}

fn callApi(
    comptime T: type,
    io: std.Io,
    arena: Allocator,
    transport: transport_api.HttpTransport,
    spec: transport_api.RequestSpec,
    request_body_json: ?[]const u8,
    handlers: Handlers(T),
    diag: ?*provider.Diagnostics,
) ApiError!ApiResult(T) {
    var response = try transport.request(io, arena, spec, diag);
    var body_owned = true;
    defer if (body_owned) response.body.deinit(io);

    if (response.status < 200 or response.status >= 300) {
        handlers.failure.handle(
            io,
            arena,
            &response,
            spec.url,
            request_body_json,
            diag,
        ) catch |err| switch (err) {
            error.APICallError, error.Canceled, error.OutOfMemory => return err,
            else => return wrapHandlerError(
                arena,
                &response,
                spec.url,
                request_body_json,
                "Failed to process error response",
                err,
                diag,
            ),
        };
        return wrapHandlerError(
            arena,
            &response,
            spec.url,
            request_body_json,
            "Failed to process error response",
            error.UnexpectedSuccess,
            diag,
        );
    }

    const handled = handlers.success.handle(
        io,
        arena,
        &response,
        spec.url,
        request_body_json,
        diag,
    ) catch |err| switch (err) {
        error.APICallError, error.Canceled, error.OutOfMemory => return err,
        else => return wrapHandlerError(
            arena,
            &response,
            spec.url,
            request_body_json,
            "Failed to process successful response",
            err,
            diag,
        ),
    };
    body_owned = !handled.body_transferred;
    return .{
        .value = handled.value,
        .response_headers = response.headers,
        .raw_body = handled.raw_body,
    };
}

fn wrapHandlerError(
    arena: Allocator,
    response: *const transport_api.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    message: []const u8,
    cause: anyerror,
    diag: ?*provider.Diagnostics,
) ApiError {
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .status_code = response.status,
        .response_headers = response.headers,
        .is_retryable = provider.isRetryableStatus(response.status),
        .request_body_json = request_body_json,
        .cause_message = @errorName(cause),
    } });
    return error.APICallError;
}

pub const ResponseReadOptions = struct {
    max_size: usize = default_max_response_size,
};

pub fn jsonResponseHandler(comptime T: type) ResponseHandler(T) {
    return .{ .handle_fn = JsonHandler(T).handle };
}

pub fn jsonResponseHandlerWithOptions(
    comptime T: type,
    options: *ResponseReadOptions,
) ResponseHandler(T) {
    return .{ .ctx = options, .handle_fn = JsonHandler(T).handle };
}

fn JsonHandler(comptime T: type) type {
    return struct {
        fn handle(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            response: *transport_api.Response,
            url: []const u8,
            request_body_json: ?[]const u8,
            diag: ?*provider.Diagnostics,
        ) ApiError!HandlerResult(T) {
            const options: ResponseReadOptions = if (raw) |ctx|
                @as(*ResponseReadOptions, @ptrCast(@alignCast(ctx))).*
            else
                .{};
            const body = try readResponseBody(arena, response, url, options.max_size, diag);
            const value = std.json.parseFromSliceLeaky(T, arena, body, .{
                .ignore_unknown_fields = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
                        .message = "Invalid JSON response",
                        .url = url,
                        .status_code = response.status,
                        .response_headers = response.headers,
                        .response_body = body,
                        .is_retryable = provider.isRetryableStatus(response.status),
                        .request_body_json = request_body_json,
                        .cause_message = @errorName(err),
                    } });
                    return error.APICallError;
                },
            };
            return .{ .value = value, .raw_body = body };
        }
    };
}

pub fn binaryResponseHandler() ResponseHandler([]const u8) {
    return .{ .handle_fn = BinaryHandler.handle };
}

const BinaryHandler = struct {
    fn handle(
        raw: ?*anyopaque,
        _: std.Io,
        arena: Allocator,
        response: *transport_api.Response,
        url: []const u8,
        request_body_json: ?[]const u8,
        diag: ?*provider.Diagnostics,
    ) ApiError!HandlerResult([]const u8) {
        const options: ResponseReadOptions = if (raw) |ctx|
            @as(*ResponseReadOptions, @ptrCast(@alignCast(ctx))).*
        else
            .{};
        const body = try readResponseBody(arena, response, url, options.max_size, diag);
        if (body.len == 0) {
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
                .message = "Response body is empty",
                .url = url,
                .status_code = response.status,
                .response_headers = response.headers,
                .is_retryable = provider.isRetryableStatus(response.status),
                .request_body_json = request_body_json,
            } });
            return error.APICallError;
        }
        return .{ .value = body };
    }
};

pub fn jsonErrorResponseHandler(
    comptime ErrorShape: type,
    comptime errorToMessage: anytype,
) ErrorResponseHandler {
    return .{ .handle_fn = JsonErrorHandler(ErrorShape, errorToMessage, null).handle };
}

pub fn jsonErrorResponseHandlerWithRetry(
    comptime ErrorShape: type,
    comptime errorToMessage: anytype,
    comptime retryOverride: anytype,
) ErrorResponseHandler {
    return .{ .handle_fn = JsonErrorHandler(ErrorShape, errorToMessage, retryOverride).handle };
}

fn JsonErrorHandler(
    comptime ErrorShape: type,
    comptime errorToMessage: anytype,
    comptime retryOverride: anytype,
) type {
    return struct {
        fn handle(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            response: *transport_api.Response,
            url: []const u8,
            request_body_json: ?[]const u8,
            diag: ?*provider.Diagnostics,
        ) ApiError!void {
            const body = try readResponseBody(
                arena,
                response,
                url,
                default_max_response_size,
                diag,
            );
            const trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (trimmed.len == 0) {
                setErrorResponse(
                    ErrorShape,
                    retryOverride,
                    arena,
                    response,
                    url,
                    request_body_json,
                    body,
                    response.status_text,
                    null,
                    diag,
                );
                return error.APICallError;
            }

            const parsed = std.json.parseFromSliceLeaky(ErrorShape, arena, body, .{
                .ignore_unknown_fields = true,
            }) catch {
                setErrorResponse(
                    ErrorShape,
                    retryOverride,
                    arena,
                    response,
                    url,
                    request_body_json,
                    body,
                    response.status_text,
                    null,
                    diag,
                );
                return error.APICallError;
            };
            setErrorResponse(
                ErrorShape,
                retryOverride,
                arena,
                response,
                url,
                request_body_json,
                body,
                errorToMessage(parsed),
                parsed,
                diag,
            );
            return error.APICallError;
        }
    };
}

fn setErrorResponse(
    comptime ErrorShape: type,
    comptime retryOverride: anytype,
    arena: Allocator,
    response: *const transport_api.Response,
    url: []const u8,
    request_body_json: ?[]const u8,
    body: []const u8,
    message: []const u8,
    parsed: ?ErrorShape,
    diag: ?*provider.Diagnostics,
) void {
    const retryable = if (comptime @TypeOf(retryOverride) == @TypeOf(null))
        provider.isRetryableStatus(response.status)
    else
        retryOverride(response.status, parsed);
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .status_code = response.status,
        .response_headers = response.headers,
        .response_body = body,
        .is_retryable = retryable,
        .request_body_json = request_body_json,
        .data_json = if (parsed != null) body else null,
    } });
}

pub fn statusCodeErrorResponseHandler() ErrorResponseHandler {
    return .{ .handle_fn = StatusCodeErrorHandler.handle };
}

const StatusCodeErrorHandler = struct {
    fn handle(
        _: ?*anyopaque,
        _: std.Io,
        arena: Allocator,
        response: *transport_api.Response,
        url: []const u8,
        request_body_json: ?[]const u8,
        diag: ?*provider.Diagnostics,
    ) ApiError!void {
        const body = try readResponseBody(
            arena,
            response,
            url,
            default_max_response_size,
            diag,
        );
        provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
            .message = response.status_text,
            .url = url,
            .status_code = response.status,
            .response_headers = response.headers,
            .response_body = body,
            .is_retryable = provider.isRetryableStatus(response.status),
            .request_body_json = request_body_json,
        } });
        return error.APICallError;
    }
};

pub fn eventSourceResponseHandler(comptime T: type) ResponseHandler(sse.JsonEventStream(T)) {
    return .{ .handle_fn = EventSourceHandler(T).handle };
}

fn EventSourceHandler(comptime T: type) type {
    return struct {
        const CleanupContext = struct {
            io: std.Io,
            body: transport_api.BodyReader,

            fn cleanup(raw: *anyopaque) void {
                const self: *CleanupContext = @ptrCast(@alignCast(raw));
                self.body.deinit(self.io);
            }
        };

        fn handle(
            _: ?*anyopaque,
            io: std.Io,
            arena: Allocator,
            response: *transport_api.Response,
            _: []const u8,
            _: ?[]const u8,
            diag: ?*provider.Diagnostics,
        ) ApiError!HandlerResult(sse.JsonEventStream(T)) {
            if (!response.has_body) {
                provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .empty_response_body = .{
                    .message = "Response body is empty",
                } });
                return error.EmptyResponseBodyError;
            }

            const cleanup_context = try arena.create(CleanupContext);
            cleanup_context.* = .{ .io = io, .body = response.body };
            var stream = sse.JsonEventStream(T).init(
                arena,
                cleanup_context.body.reader(),
                .{ .diag = diag },
            );
            stream.cleanup = .{
                .ctx = cleanup_context,
                .func = CleanupContext.cleanup,
            };
            return .{ .value = stream, .body_transferred = true };
        }
    };
}

fn readResponseBody(
    arena: Allocator,
    response: *transport_api.Response,
    url: []const u8,
    max_size: usize,
    diag: ?*provider.Diagnostics,
) ApiError![]const u8 {
    if (headers_api.getHeader(response.headers, "content-length")) |value| {
        if (std.fmt.parseInt(u64, value, 10)) |content_length| {
            if (content_length > max_size) {
                setSizeError(arena, response, url, max_size, diag);
                return error.DownloadError;
            }
        } else |_| {}
    }

    return transport_api.readBodyWithLimit(arena, &response.body, max_size) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => {
            setSizeError(arena, response, url, max_size, diag);
            return error.DownloadError;
        },
        error.ReadFailed => {
            provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
                .message = "Failed to read response body",
                .url = url,
                .status_code = response.status,
                .status_text = response.status_text,
                .cause_message = @errorName(err),
            } });
            return error.DownloadError;
        },
    };
}

fn setSizeError(
    arena: Allocator,
    response: *const transport_api.Response,
    url: []const u8,
    max_size: usize,
    diag: ?*provider.Diagnostics,
) void {
    var message_buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "Download of {s} exceeded maximum size of {d} bytes.",
        .{ url, max_size },
    ) catch "Response exceeded maximum size";
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .download = .{
        .message = message,
        .url = url,
        .status_code = response.status,
        .status_text = response.status_text,
    } });
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

test "api handler constructors instantiate configurable and retry override paths" {
    const ErrorShape = struct { message: []const u8 };
    const Callbacks = struct {
        fn message(value: ErrorShape) []const u8 {
            return value.message;
        }

        fn retryable(status: u16, value: ?ErrorShape) bool {
            return status == 418 and value != null;
        }
    };
    var options: ResponseReadOptions = .{ .max_size = 64 };
    _ = jsonResponseHandlerWithOptions(struct { ok: bool }, &options);
    _ = jsonErrorResponseHandlerWithRetry(
        ErrorShape,
        Callbacks.message,
        Callbacks.retryable,
    );
    _ = binaryResponseHandler();
    _ = eventSourceResponseHandler(std.json.Value);
}
