import ctypes, time

lib = ctypes.CDLL("./zig-out/lib/libai.so.0.1.0")
lib.ai_runtime_create.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
lib.ai_runtime_create.restype = ctypes.c_int
lib.ai_runtime_destroy.argtypes = [ctypes.c_void_p]
lib.ai_stream_open.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
lib.ai_stream_open.restype = ctypes.c_int
lib.ai_stream_next.argtypes = [ctypes.c_void_p,
                               ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
                               ctypes.POINTER(ctypes.c_size_t)]
lib.ai_stream_next.restype = ctypes.c_int
lib.ai_stream_close.argtypes = [ctypes.c_void_p]
lib.ai_buf_free.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t]

rt = ctypes.c_void_p()
assert lib.ai_runtime_create(ctypes.byref(rt)) == 0
st = ctypes.c_void_p()
assert lib.ai_stream_open(rt, ctypes.byref(st)) == 0

got = []
for _ in range(5):  # consume only 5 of 100, then cancel mid-stream
    ptr = ctypes.POINTER(ctypes.c_ubyte)()
    n = ctypes.c_size_t()
    status = lib.ai_stream_next(st, ctypes.byref(ptr), ctypes.byref(n))
    if status != 0:
        break
    got.append(bytes(ptr[i] for i in range(n.value)))
    lib.ai_buf_free(ptr, n)

print("pulled:", got)
t0 = time.time()
lib.ai_stream_close(st)  # cancels producer mid-flight
print("close latency: %.1f ms" % ((time.time() - t0) * 1000))
lib.ai_runtime_destroy(rt)
assert got == [b"part-0", b"part-1", b"part-2", b"part-3", b"part-4"]
print("STREAM OK")
