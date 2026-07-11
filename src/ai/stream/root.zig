//! Phase 5 streaming primitives and pipeline stages.

pub const part_stream = @import("part_stream.zig");
pub const parts = @import("parts.zig");
pub const broadcast = @import("broadcast.zig");
pub const stitchable = @import("stitchable.zig");
pub const model_call = @import("model_call.zig");
pub const tool_callbacks = @import("tool_callbacks.zig");
pub const tool_execution = @import("tool_execution.zig");
pub const transform = @import("transform.zig");
pub const smooth_stream = @import("smooth_stream.zig");

pub const PartStream = part_stream.PartStream;
pub const TextStreamPart = parts.TextStreamPart;
pub const LanguageModelStreamPart = parts.LanguageModelStreamPart;
pub const Broadcast = broadcast.Broadcast;
pub const ChildStream = stitchable.ChildStream;
pub const Stitchable = stitchable.Stitchable;
pub const streamLanguageModelCall = model_call.streamLanguageModelCall;
pub const invokeToolCallbacksFromStream = tool_callbacks.invokeToolCallbacksFromStream;
pub const executeToolsFromStream = tool_execution.executeToolsFromStream;
pub const StreamTransform = transform.StreamTransform;
pub const StopStreamFn = transform.StopStreamFn;
pub const SmoothStreamOptions = smooth_stream.Options;
pub const SmoothStreamChunking = smooth_stream.Chunking;
pub const smoothStream = smooth_stream.smoothStream;

test {
    _ = part_stream;
    _ = parts;
    _ = broadcast;
    _ = stitchable;
    _ = model_call;
    _ = tool_callbacks;
    _ = tool_execution;
    _ = transform;
    _ = smooth_stream;
}
