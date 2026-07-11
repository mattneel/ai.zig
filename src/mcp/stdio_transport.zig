//! Newline-delimited JSON-RPC over a Zig 0.16 child process.

const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const transport_api = @import("transport.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const EnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const StderrBehavior = enum { inherit, pipe };

pub const Config = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    /// Zig 0.16 has no global environment. Pass `init.environ_map` here to
    /// inherit the upstream whitelist; null intentionally means no inherited
    /// variables rather than silently inheriting the whole process environment.
    parent_environ: ?*const std.process.Environ.Map = null,
    env: []const EnvEntry = &.{},
    cwd: ?[]const u8 = null,
    stderr: StderrBehavior = .inherit,
    close_grace_ms: u64 = 1000,
};

pub const StdioTransport = struct {
    gpa: Allocator,
    argv: []const []const u8,
    env: []const EnvEntry,
    parent_environ: ?*const std.process.Environ.Map,
    cwd: ?[]const u8,
    stderr_behavior: StderrBehavior,
    close_grace_ms: u64,
    child: ?std.process.Child = null,
    callbacks: transport_api.Callbacks = .{},
    protocol_version: []u8,
    started: bool = false,
    closing: std.atomic.Value(bool) = .init(false),
    close_notified: std.atomic.Value(bool) = .init(false),
    write_mutex: std.Io.Mutex = .init,
    reader_future: ?std.Io.Future(void) = null,
    reader_done: std.Io.Event = .unset,
    inline_mode: bool = false,
    read_buffer: [4096]u8 = undefined,
    file_reader: ?std.Io.File.Reader = null,
    line: std.Io.Writer.Allocating,

    pub fn init(gpa: Allocator, config: Config) Allocator.Error!StdioTransport {
        const argv = try gpa.alloc([]const u8, config.args.len + 1);
        errdefer gpa.free(argv);
        argv[0] = try gpa.dupe(u8, config.command);
        errdefer gpa.free(argv[0]);
        var argv_initialized: usize = 1;
        errdefer for (argv[1..argv_initialized]) |arg| gpa.free(arg);
        for (config.args, argv[1..]) |arg, *owned| {
            owned.* = try gpa.dupe(u8, arg);
            argv_initialized += 1;
        }

        const env = try gpa.alloc(EnvEntry, config.env.len);
        errdefer gpa.free(env);
        var env_initialized: usize = 0;
        errdefer for (env[0..env_initialized]) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.value);
        };
        for (config.env, env) |entry, *owned| {
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            const value = try gpa.dupe(u8, entry.value);
            owned.* = .{
                .name = name,
                .value = value,
            };
            env_initialized += 1;
        }

        const cwd = if (config.cwd) |value| try gpa.dupe(u8, value) else null;
        errdefer if (cwd) |value| gpa.free(value);
        const protocol_version = try gpa.dupe(u8, types.LATEST_PROTOCOL_VERSION);

        return .{
            .gpa = gpa,
            .argv = argv,
            .env = env,
            .parent_environ = config.parent_environ,
            .cwd = cwd,
            .stderr_behavior = config.stderr,
            .close_grace_ms = config.close_grace_ms,
            .protocol_version = protocol_version,
            .line = .init(gpa),
        };
    }

    pub fn deinit(self: *StdioTransport) void {
        std.debug.assert(self.child == null);
        for (self.argv) |arg| self.gpa.free(arg);
        self.gpa.free(self.argv);
        for (self.env) |entry| {
            self.gpa.free(entry.name);
            self.gpa.free(entry.value);
        }
        self.gpa.free(self.env);
        if (self.cwd) |cwd| self.gpa.free(cwd);
        self.gpa.free(self.protocol_version);
        self.line.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *StdioTransport) transport_api.MCPTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn start(self: *StdioTransport, io: std.Io) anyerror!void {
        if (self.started) return error.TransportAlreadyStarted;
        self.closing.store(false, .release);
        self.close_notified.store(false, .release);
        self.reader_done = .unset;

        var environment = try self.buildEnvironment();
        defer environment.deinit();
        var child = std.process.spawn(io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = switch (self.stderr_behavior) {
                .inherit => .inherit,
                .pipe => .pipe,
            },
            .cwd = if (self.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = &environment,
        }) catch |err| {
            self.callbacks.errorInfo(.{ .err = err, .message = "failed to spawn MCP stdio server" });
            return err;
        };
        errdefer child.kill(io);
        self.child = child;
        self.file_reader = child.stdout.?.readerStreaming(io, &self.read_buffer);
        self.started = true;

        self.reader_future = io.concurrent(readerMain, .{ self, io }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                // In constrained/single-threaded runtimes, send() pumps one
                // response after each write. Server-initiated traffic cannot
                // arrive independently in this documented degraded mode.
                self.inline_mode = true;
                return;
            },
        };
    }

    pub fn send(self: *StdioTransport, io: std.Io, message: json_rpc.Message) anyerror!void {
        if (!self.started or self.child == null or self.child.?.stdin == null) {
            return error.TransportNotConnected;
        }

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const encoded = try json_rpc.serialize(arena_state.allocator(), message);

        try self.write_mutex.lock(io);
        defer self.write_mutex.unlock(io);
        try self.child.?.stdin.?.writeStreamingAll(io, encoded);
        try self.child.?.stdin.?.writeStreamingAll(io, "\n");

        if (self.inline_mode and message.hasId()) {
            _ = try self.readOne(io);
        }
    }

    pub fn close(self: *StdioTransport, io: std.Io) anyerror!void {
        if (!self.started) return;
        self.closing.store(true, .release);

        if (self.child) |*child| {
            if (child.stdin) |stdin| {
                stdin.close(io);
                child.stdin = null;
            }

            if (self.inline_mode) {
                _ = child.wait(io) catch {
                    child.kill(io);
                };
            } else {
                self.reader_done.waitTimeout(io, .{
                    .duration = .{
                        .raw = .fromMilliseconds(@intCast(@min(self.close_grace_ms, @as(u64, std.math.maxInt(i64))))),
                        .clock = .awake,
                    },
                }) catch {
                    child.kill(io);
                };
                if (self.reader_future) |*future| {
                    future.cancel(io);
                    self.reader_future = null;
                }
                if (child.id != null) {
                    _ = child.wait(io) catch child.kill(io);
                }
            }
        }

        self.child = null;
        self.file_reader = null;
        self.started = false;
        self.inline_mode = false;
        self.line.clearRetainingCapacity();
        self.notifyClose();
    }

    fn buildEnvironment(self: *StdioTransport) Allocator.Error!std.process.Environ.Map {
        var result = std.process.Environ.Map.init(self.gpa);
        errdefer result.deinit();

        const inherited = switch (@import("builtin").os.tag) {
            .windows => &.{
                "APPDATA",                "HOMEDRIVE",   "HOMEPATH",   "LOCALAPPDATA", "PATH",
                "PROCESSOR_ARCHITECTURE", "SYSTEMDRIVE", "SYSTEMROOT", "TEMP",         "USERNAME",
                "USERPROFILE",
            },
            else => &.{ "HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER" },
        };
        if (self.parent_environ) |parent| {
            inline for (inherited) |name| {
                if (parent.get(name)) |value| {
                    if (!std.mem.startsWith(u8, value, "()")) {
                        try result.put(name, value);
                    }
                }
            }
        }
        for (self.env) |entry| try result.put(entry.name, entry.value);
        return result;
    }

    fn readerMain(self: *StdioTransport, io: std.Io) void {
        defer self.reader_done.set(io);
        while (!self.closing.load(.acquire)) {
            const more = self.readOne(io) catch |err| {
                if (!self.closing.load(.acquire)) {
                    self.callbacks.errorInfo(.{ .err = err, .message = "MCP stdio read failed" });
                }
                return;
            };
            if (!more) return;
        }
    }

    fn readOne(self: *StdioTransport, _: std.Io) anyerror!bool {
        var reader = &(self.file_reader orelse return error.TransportNotConnected).interface;
        self.line.clearRetainingCapacity();
        _ = reader.streamDelimiterEnding(&self.line.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };

        const delimiter_found = if (reader.takeByte()) |byte| blk: {
            std.debug.assert(byte == '\n');
            break :blk true;
        } else |err| switch (err) {
            error.EndOfStream => false,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!delimiter_found) return false;

        const line = std.mem.trimEnd(u8, self.line.written(), "\r");
        if (line.len == 0) return true;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const message = json_rpc.parse(arena_state.allocator(), line) catch |err| {
            self.callbacks.errorInfo(.{ .err = err, .message = "failed to parse MCP stdio message" });
            return true;
        };
        self.callbacks.message(message);
        return true;
    }

    fn notifyClose(self: *StdioTransport) void {
        if (!self.close_notified.swap(true, .acq_rel)) self.callbacks.closed();
    }

    fn setCallbacks(raw: *anyopaque, callbacks: transport_api.Callbacks) void {
        const self: *StdioTransport = @ptrCast(@alignCast(raw));
        self.callbacks = callbacks;
    }

    fn getProtocolVersion(raw: *anyopaque) ?[]const u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(raw));
        return self.protocol_version;
    }

    fn setProtocolVersion(raw: *anyopaque, version: []const u8) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(raw));
        const owned = try self.gpa.dupe(u8, version);
        self.gpa.free(self.protocol_version);
        self.protocol_version = owned;
    }

    fn startAdapter(raw: *anyopaque, io: std.Io) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(raw));
        return self.start(io);
    }

    fn sendAdapter(raw: *anyopaque, io: std.Io, message: json_rpc.Message) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(raw));
        return self.send(io, message);
    }

    fn closeAdapter(raw: *anyopaque, io: std.Io) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(raw));
        return self.close(io);
    }

    const vtable: transport_api.VTable = .{
        .start = startAdapter,
        .send = sendAdapter,
        .close = closeAdapter,
        .set_callbacks = setCallbacks,
        .get_protocol_version = getProtocolVersion,
        .set_protocol_version = setProtocolVersion,
    };
};

test "stdio environment is whitelist-only and custom values override inherited values" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/parent/bin");
    try parent.put("SECRET", "must-not-leak");

    var value = try StdioTransport.init(std.testing.allocator, .{
        .command = "/bin/true",
        .parent_environ = &parent,
        .env = &.{
            .{ .name = "PATH", .value = "/custom/bin" },
            .{ .name = "CUSTOM", .value = "yes" },
        },
    });
    defer value.deinit();
    var environment = try value.buildEnvironment();
    defer environment.deinit();
    try std.testing.expectEqualStrings("/custom/bin", environment.get("PATH").?);
    try std.testing.expectEqualStrings("yes", environment.get("CUSTOM").?);
    try std.testing.expect(environment.get("SECRET") == null);
}
