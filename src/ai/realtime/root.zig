//! Framework-neutral realtime session primitives.

const std = @import("std");

pub const audio = @import("audio.zig");
pub const reducer = @import("reducer.zig");
pub const session = @import("session.zig");

pub const RealtimeStatus = reducer.Status;
pub const RealtimeState = reducer.State;
pub const RealtimeStateChanges = reducer.Changes;
pub const RealtimeReducerEffect = reducer.Effect;
pub const RealtimeToolOutput = reducer.ToolOutput;
pub const RealtimeEventReducer = reducer.Reducer;
pub const RealtimeSession = session.RealtimeSession;
pub const RealtimeSessionOptions = session.Options;
pub const RealtimeTransport = session.RealtimeTransport;
pub const RealtimeAudio = session.RealtimeAudio;
pub const RealtimeStateCallbacks = session.StateCallbacks;
pub const DeferredLifecycleAction = session.DeferredLifecycleAction;
pub const NullRealtimeAudio = session.null_audio;
pub const createInitialRealtimeState = reducer.createInitialRealtimeState;
pub const default_max_events = reducer.default_max_events;

pub const encodeRealtimeAudio = audio.encode;
pub const decodeRealtimeAudio = audio.decode;
pub const resampleAudio = audio.resample;

test "module declarations" {
    std.testing.refAllDecls(@This());
}
