import ctypes, threading

lib = ctypes.CDLL("./zig-out/lib/libai.so.0.1.0")

CHUNK_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p,
                            ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t)

lib.ai_runtime_create.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
lib.ai_runtime_create.restype = ctypes.c_int
lib.ai_runtime_destroy.argtypes = [ctypes.c_void_p]
lib.ai_echo_upper.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
    ctypes.POINTER(ctypes.c_size_t)]
lib.ai_echo_upper.restype = ctypes.c_int
lib.ai_buf_free.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t]
lib.ai_status_name.argtypes = [ctypes.c_int]
lib.ai_status_name.restype = ctypes.c_char_p
lib.ai_stream_blocking.argtypes = [ctypes.c_void_p, CHUNK_CB, ctypes.c_void_p]
lib.ai_stream_blocking.restype = ctypes.c_int

rt = ctypes.c_void_p()
assert lib.ai_runtime_create(ctypes.byref(rt)) == 0
print("runtime handle:", hex(rt.value))

out_ptr = ctypes.POINTER(ctypes.c_ubyte)()
out_len = ctypes.c_size_t()
st = lib.ai_echo_upper(rt, b"hello ffi", 9, ctypes.byref(out_ptr),
                       ctypes.byref(out_len))
assert st == 0
data = bytes(out_ptr[i] for i in range(out_len.value))
print("echo_upper:", data)
assert data == b"HELLO FFI"
lib.ai_buf_free(out_ptr, out_len)

print("status name of 1:", lib.ai_status_name(1))

chunks = []
main_tid = threading.get_ident()
cb_tids = set()

@CHUNK_CB
def on_chunk(user_data, ptr, length):
    cb_tids.add(threading.get_ident())
    chunks.append(bytes(ptr[i] for i in range(length)))

st = lib.ai_stream_blocking(rt, on_chunk, None)
assert st == 0
print("chunks:", chunks)
print("callback ran on main thread?", cb_tids == {main_tid}, cb_tids)
assert chunks == [b"chunk-0", b"chunk-1", b"chunk-2"]

lib.ai_runtime_destroy(rt)
print("OK")
