//! OpenTelemetry `gen_ai` exporter for ai.zig.
//!
//! This module implements `ai.Telemetry` and exports completed spans as
//! OTLP/HTTP JSON. Attribute choices follow the OpenTelemetry conventions
//! pinned by Phase 12 rather than the newer names used by the vendored
//! `@ai-sdk/otel` package:
//!
//! - operation/provider identity uses `gen_ai.operation.name` and the pinned
//!   `gen_ai.system`; upstream now spells the latter
//!   `gen_ai.provider.name`;
//! - request attributes use `gen_ai.request.*`, with instructions and tool
//!   arguments included only when `Meta.record_inputs` is true;
//! - response and usage attributes use `gen_ai.response.*` and
//!   `gen_ai.usage.*`, with generated text and tool results included only
//!   when `Meta.record_outputs` is true;
//! - tool spans use the stable `gen_ai.tool.*` group plus
//!   `gen_ai.execute_tool.duration`.
//!
//! The exporter is intentionally an OTLP/HTTP-JSON client, not an OTel SDK:
//! it emits `resourceSpans/scopeSpans/spans` directly through
//! `provider_utils.HttpTransport`. Batches flush explicitly through
//! `Exporter.flush` or synchronously when `Config.max_batch_size` is reached.
//! Version 1 has no timer or background thread.
//!
//! Generate/object lifecycle events carry stable call IDs, so their spans are
//! correlated without ambient context. Tool spans use the last model span in
//! the same call as parent; the tool enter hook's missing tool ID affects only
//! exact hook-to-tool timing assignment. Embed/rerank callbacks expose no
//! outer operation lifetime, so those model-call spans are exported as roots.

const std = @import("std");

pub const otlp = @import("otlp.zig");
pub const exporter = @import("exporter.zig");

pub const Config = exporter.Config;
pub const Exporter = exporter.Exporter;
pub const Registration = exporter.Registration;
pub const InitError = exporter.InitError;
pub const FlushError = exporter.FlushError;
pub const register = exporter.register;
pub const encodeOtlpJson = otlp.encode;

test {
    std.testing.refAllDecls(@This());
    _ = @import("exporter_test.zig");
}
