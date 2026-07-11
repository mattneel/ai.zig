const std = @import("std");
const provider = @import("provider");

const Allocator = std.mem.Allocator;

pub const RequestError = provider.Error || std.Io.Cancelable || Allocator.Error;

pub const RequestSpec = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const provider.Header = &.{},
    body: ?[]const u8 = null,
    redirect_behavior: ?std.http.Client.Request.RedirectBehavior = null,
};

pub const BodyReader = struct {
    ctx: *anyopaque,
    reader_ptr: *std.Io.Reader,
    deinit_fn: *const fn (ctx: *anyopaque, io: std.Io) void,

    pub fn reader(self: *BodyReader) *std.Io.Reader {
        return self.reader_ptr;
    }

    pub fn deinit(self: *BodyReader, io: std.Io) void {
        self.deinit_fn(self.ctx, io);
        self.* = undefined;
    }
};

pub const Response = struct {
    status: u16,
    status_text: []const u8,
    headers: []const provider.Header,
    has_body: bool = true,
    body: BodyReader,
};

pub const VTable = struct {
    request: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        arena: Allocator,
        spec: RequestSpec,
        diag: ?*provider.Diagnostics,
    ) RequestError!Response,
};

pub const HttpTransport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn request(
        self: HttpTransport,
        io: std.Io,
        arena: Allocator,
        spec: RequestSpec,
        diag: ?*provider.Diagnostics,
    ) RequestError!Response {
        return self.vtable.request(self.ctx, io, arena, spec, diag);
    }
};

pub const HttpClientTransport = struct {
    client: std.http.Client,

    pub fn init(gpa: Allocator, io: std.Io) HttpClientTransport {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *HttpClientTransport) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *HttpClientTransport) HttpTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const State = struct {
        request: std.http.Client.Request,
        decompress: std.http.Decompress = undefined,
        deinitialized: bool = false,

        fn deinit(raw: *anyopaque, _: std.Io) void {
            const self: *State = @ptrCast(@alignCast(raw));
            if (self.deinitialized) return;
            self.request.deinit();
            self.deinitialized = true;
        }
    };

    const vtable: VTable = .{ .request = request };

    fn request(
        raw: *anyopaque,
        _: std.Io,
        arena: Allocator,
        spec: RequestSpec,
        diag: ?*provider.Diagnostics,
    ) RequestError!Response {
        const self: *HttpClientTransport = @ptrCast(@alignCast(raw));
        const uri = std.Uri.parse(spec.url) catch |err|
            return apiFailure(arena, diag, spec.url, err, false, "Invalid API URL");

        const extra_headers = try arena.alloc(std.http.Header, spec.headers.len);
        for (spec.headers, extra_headers) |header, *extra| {
            extra.* = .{
                .name = try arena.dupe(u8, header.name),
                .value = try arena.dupe(u8, header.value),
            };
        }

        const state = try arena.create(State);
        state.* = .{
            .request = self.client.request(spec.method, uri, .{
                .redirect_behavior = spec.redirect_behavior orelse @enumFromInt(3),
                .headers = .{
                    .host = if (hasHeader(spec.headers, "host")) .omit else .default,
                    .authorization = if (hasHeader(spec.headers, "authorization")) .omit else .default,
                    .user_agent = if (hasHeader(spec.headers, "user-agent")) .omit else .default,
                    .connection = if (hasHeader(spec.headers, "connection")) .omit else .default,
                    .accept_encoding = if (hasHeader(spec.headers, "accept-encoding")) .omit else .default,
                    .content_type = if (hasHeader(spec.headers, "content-type")) .omit else .default,
                },
                .extra_headers = extra_headers,
            }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => |request_error| return apiFailure(
                    arena,
                    diag,
                    spec.url,
                    request_error,
                    true,
                    "Cannot connect to API",
                ),
            },
        };
        errdefer state.request.deinit();

        if (spec.method.requestHasBody()) {
            const body = spec.body orelse "";
            state.request.transfer_encoding = .{ .content_length = body.len };
            var writer = state.request.sendBodyUnflushed(&.{}) catch |err|
                return writeFailure(arena, diag, spec.url, err);
            writer.writer.writeAll(body) catch |err|
                return writeFailure(arena, diag, spec.url, err);
            writer.end() catch |err|
                return writeFailure(arena, diag, spec.url, err);
            state.request.connection.?.flush() catch |err|
                return writeFailure(arena, diag, spec.url, err);
        } else {
            state.request.sendBodiless() catch |err|
                return writeFailure(arena, diag, spec.url, err);
        }

        const redirect_buffer = try arena.alloc(u8, 8192);
        var response = state.request.receiveHead(redirect_buffer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => |receive_error| return apiFailure(
                arena,
                diag,
                spec.url,
                receive_error,
                isConnectionFailure(receive_error),
                "API request failed",
            ),
        };

        var copied_headers: std.ArrayList(provider.Header) = .empty;
        defer copied_headers.deinit(arena);
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            try copied_headers.append(arena, .{
                .name = try arena.dupe(u8, header.name),
                .value = try arena.dupe(u8, header.value),
            });
        }
        const response_headers = try copied_headers.toOwnedSlice(arena);
        const status: u16 = @intCast(@intFromEnum(response.head.status));
        const status_text = try arena.dupe(u8, response.head.reason);

        const transfer_buffer = try arena.alloc(u8, 16 * 1024);
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return apiFailure(
                arena,
                diag,
                spec.url,
                error.HttpContentEncodingUnsupported,
                false,
                "API response compression is unsupported",
            ),
        };
        const reader = response.readerDecompressing(
            transfer_buffer,
            &state.decompress,
            decompress_buffer,
        );
        const has_body = spec.method.responseHasBody() and
            response.head.status.class() != .informational and
            response.head.status != .no_content and
            response.head.status != .not_modified;
        return .{
            .status = status,
            .status_text = status_text,
            .headers = response_headers,
            .has_body = has_body,
            .body = .{
                .ctx = state,
                .reader_ptr = reader,
                .deinit_fn = State.deinit,
            },
        };
    }
};

pub fn readBodyWithLimit(
    arena: Allocator,
    body: *BodyReader,
    max_size: usize,
) (Allocator.Error || std.Io.Reader.ShortError || std.Io.Cancelable || error{StreamTooLong})![]u8 {
    return body.reader().allocRemaining(arena, .limited(max_size));
}

fn writeFailure(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    url: []const u8,
    err: anyerror,
) RequestError {
    if (err == error.Canceled) return error.Canceled;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return apiFailure(arena, diag, url, err, true, "Cannot connect to API");
}

fn apiFailure(
    arena: Allocator,
    diag: ?*provider.Diagnostics,
    url: []const u8,
    cause: anyerror,
    retryable: bool,
    prefix: []const u8,
) RequestError {
    const message = std.fmt.allocPrint(arena, "{s}: {s}", .{ prefix, @errorName(cause) }) catch
        return error.OutOfMemory;
    provider.Diagnostics.set(diag, diagnosticAllocator(diag, arena), .{ .api_call = .{
        .message = message,
        .url = url,
        .is_retryable = retryable,
        .cause_message = @errorName(cause),
    } });
    return error.APICallError;
}

fn diagnosticAllocator(diag: ?*provider.Diagnostics, fallback: Allocator) Allocator {
    return if (diag) |diagnostics| diagnostics.allocator else fallback;
}

fn isConnectionFailure(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.indexOf(u8, name, "Connection") != null or
        std.mem.indexOf(u8, name, "Network") != null or
        std.mem.indexOf(u8, name, "Host") != null or
        std.mem.indexOf(u8, name, "NameServer") != null or
        std.mem.eql(u8, name, "ReadFailed") or
        std.mem.eql(u8, name, "WriteFailed") or
        std.mem.eql(u8, name, "BrokenPipe");
}

fn hasHeader(headers: []const provider.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}
