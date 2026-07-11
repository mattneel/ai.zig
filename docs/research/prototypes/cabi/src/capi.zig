//! Prototype C ABI layer validating patterns for ai.zig FFI research.
const std = @import("std");
const Io = std.Io;

// ---- error codes: explicit extern-compatible enum ----
pub const AiStatus = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_argument = 2,
    canceled = 3,
    network = 4,
    unknown = -1,
};

// ---- opaque handle backed by a real Zig struct ----
const Runtime = struct {
    gpa_state: std.heap.DebugAllocator(.{}),
    threaded: Io.Threaded,

    fn create() !*Runtime {
        const rt = try std.heap.c_allocator.create(Runtime);
        errdefer std.heap.c_allocator.destroy(rt);
        rt.gpa_state = .{};
        rt.threaded = Io.Threaded.init(rt.gpa_state.allocator(), .{});
        return rt;
    }

    fn destroy(rt: *Runtime) void {
        rt.threaded.deinit();
        _ = rt.gpa_state.deinit();
        std.heap.c_allocator.destroy(rt);
    }
};

/// Opaque C-side handle.
pub const ai_runtime = opaque {};

fn fromHandle(h: *ai_runtime) *Runtime {
    return @ptrCast(@alignCast(h));
}

export fn ai_runtime_create(out: *?*ai_runtime) AiStatus {
    const rt = Runtime.create() catch return .out_of_memory;
    out.* = @ptrCast(rt);
    return .ok;
}

export fn ai_runtime_destroy(h: *ai_runtime) void {
    Runtime.destroy(fromHandle(h));
}

// ---- string passing: ptr+len in, callee-allocated out + free fn ----
export fn ai_echo_upper(
    h: *ai_runtime,
    text_ptr: [*]const u8,
    text_len: usize,
    out_ptr: *?[*]u8,
    out_len: *usize,
) AiStatus {
    _ = fromHandle(h);
    const text = text_ptr[0..text_len];
    const buf = std.heap.c_allocator.alloc(u8, text.len) catch return .out_of_memory;
    for (text, buf) |c, *d| d.* = std.ascii.toUpper(c);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return .ok;
}

export fn ai_buf_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| std.heap.c_allocator.free(p[0..len]);
}

// ---- error name lookup for diagnostics ----
export fn ai_status_name(status: AiStatus) [*:0]const u8 {
    return @tagName(status);
}

// ---- callback + user_data driven from an Io.Threaded worker ----
pub const ai_chunk_cb = *const fn (
    user_data: ?*anyopaque,
    chunk_ptr: [*]const u8,
    chunk_len: usize,
) callconv(.c) void;

fn streamWorker(io: Io, cb: ai_chunk_cb, user_data: ?*anyopaque) void {
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        io.sleep(.fromMilliseconds(5), .awake) catch return;
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "chunk-{d}", .{i}) catch unreachable;
        cb(user_data, s.ptr, s.len);
    }
}

/// Blocking streaming call: worker runs concurrently, caller thread awaits.
export fn ai_stream_blocking(
    h: *ai_runtime,
    cb: ai_chunk_cb,
    user_data: ?*anyopaque,
) AiStatus {
    const rt = fromHandle(h);
    const io = rt.threaded.io();
    var future = io.concurrent(streamWorker, .{ io, cb, user_data }) catch
        return .unknown;
    future.await(io);
    return .ok;
}

// ---- pull-based stream: opaque handle over Io.Queue + Future ----
const Chunk = struct { ptr: [*]u8, len: usize };

const Stream = struct {
    rt: *Runtime,
    buffer: [8]Chunk,
    queue: Io.Queue(Chunk),
    future: Io.Future(void),

    fn producer(s: *Stream, io: Io) void {
        var i: u8 = 0;
        while (i < 100) : (i += 1) {
            io.sleep(.fromMilliseconds(2), .awake) catch break;
            var buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "part-{d}", .{i}) catch unreachable;
            const heap_copy = std.heap.c_allocator.dupe(u8, text) catch break;
            s.queue.putOne(io, .{ .ptr = heap_copy.ptr, .len = heap_copy.len }) catch {
                std.heap.c_allocator.free(heap_copy);
                break;
            };
        }
        s.queue.close(io);
    }
};

pub const ai_stream = opaque {};

export fn ai_stream_open(h: *ai_runtime, out: *?*ai_stream) AiStatus {
    const rt = fromHandle(h);
    const io = rt.threaded.io();
    const s = std.heap.c_allocator.create(Stream) catch return .out_of_memory;
    s.rt = rt;
    s.queue = .init(&s.buffer);
    s.future = io.concurrent(Stream.producer, .{ s, io }) catch {
        std.heap.c_allocator.destroy(s);
        return .unknown;
    };
    out.* = @ptrCast(s);
    return .ok;
}

/// Blocks until the next chunk. Returns .ok with a chunk the caller must
/// free via ai_buf_free, or .canceled when the stream ends.
export fn ai_stream_next(
    handle: *ai_stream,
    out_ptr: *?[*]u8,
    out_len: *usize,
) AiStatus {
    const s: *Stream = @ptrCast(@alignCast(handle));
    const io = s.rt.threaded.io();
    const chunk = s.queue.getOne(io) catch {
        out_ptr.* = null;
        out_len.* = 0;
        return .canceled;
    };
    out_ptr.* = chunk.ptr;
    out_len.* = chunk.len;
    return .ok;
}

export fn ai_stream_close(handle: *ai_stream) void {
    const s: *Stream = @ptrCast(@alignCast(handle));
    const io = s.rt.threaded.io();
    _ = s.future.cancel(io);
    // Drain anything the producer had already queued.
    while (s.queue.getOne(io)) |chunk| {
        std.heap.c_allocator.free(chunk.ptr[0..chunk.len]);
    } else |_| {}
    std.heap.c_allocator.destroy(s);
}
