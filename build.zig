const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Run tests whose names contain any of these substrings",
    ) orelse &.{};
    const live = b.option(bool, "live", "Run live provider smoke tests") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "live", live);

    const provider = b.addModule("provider", .{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const provider_utils = b.addModule("provider_utils", .{
        .root_source_file = b.path("src/provider_utils/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_utils.addImport("provider", provider);

    const ai = b.addModule("ai", .{
        .root_source_file = b.path("src/ai/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai.addImport("provider", provider);
    ai.addImport("provider_utils", provider_utils);

    const openai_compatible = b.addModule("openai_compatible", .{
        .root_source_file = b.path("src/openai_compatible/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    openai_compatible.addImport("provider", provider);
    openai_compatible.addImport("provider_utils", provider_utils);

    const openrouter = b.addModule("openrouter", .{
        .root_source_file = b.path("src/openrouter/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    openrouter.addImport("provider", provider);
    openrouter.addImport("provider_utils", provider_utils);
    openrouter.addImport("openai_compatible", openai_compatible);

    const anthropic = b.addModule("anthropic", .{
        .root_source_file = b.path("src/anthropic/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    anthropic.addImport("provider", provider);
    anthropic.addImport("provider_utils", provider_utils);

    const openai = b.addModule("openai", .{
        .root_source_file = b.path("src/openai/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    openai.addImport("provider", provider);
    openai.addImport("provider_utils", provider_utils);

    const mcp = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp.addImport("provider", provider);
    mcp.addImport("provider_utils", provider_utils);

    const ffi = b.addModule("ffi", .{
        .root_source_file = b.path("src/ffi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi.addImport("ai", ai);
    ffi.addImport("provider", provider);
    ffi.addImport("provider_utils", provider_utils);

    const test_support = b.createModule(.{
        .root_source_file = b.path("src/test_support/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support.addImport("provider_utils", provider_utils);

    const integration = b.createModule(.{
        .root_source_file = b.path("src/integration/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration.addImport("provider", provider);
    integration.addImport("provider_utils", provider_utils);
    integration.addImport("test_support", test_support);
    integration.addImport("openai_compatible", openai_compatible);
    integration.addImport("anthropic", anthropic);
    integration.addImport("openrouter", openrouter);
    integration.addOptions("build_options", build_options);

    const modules = [_]Module{
        .{ .name = "provider", .test_step = "provider", .module = provider },
        .{ .name = "provider_utils", .test_step = "provider-utils", .module = provider_utils },
        .{ .name = "ai", .test_step = "ai", .module = ai },
        .{ .name = "openai_compatible", .test_step = "openai-compatible", .module = openai_compatible },
        .{ .name = "openrouter", .test_step = "openrouter", .module = openrouter },
        .{ .name = "anthropic", .test_step = "anthropic", .module = anthropic },
        .{ .name = "openai", .test_step = "openai", .module = openai },
        .{ .name = "mcp", .test_step = "mcp", .module = mcp },
        .{ .name = "ffi", .test_step = "ffi", .module = ffi },
        .{ .name = "test_support", .test_step = "support", .module = test_support },
        .{ .name = "integration", .test_step = "integration", .module = integration },
    };

    const test_all = b.step("test", "Run all module tests");
    for (modules) |entry| {
        const object = b.addObject(.{
            .name = b.fmt("{s}-module", .{entry.name}),
            .root_module = entry.module,
        });
        b.getInstallStep().dependOn(&object.step);

        const tests = b.addTest(.{
            .name = b.fmt("{s}-tests", .{entry.name}),
            .root_module = entry.module,
            .filters = filters,
        });
        const run_tests = b.addRunArtifact(tests);
        const module_test = b.step(
            b.fmt("test-{s}", .{entry.test_step}),
            b.fmt("Run {s} module tests", .{entry.name}),
        );
        module_test.dependOn(&run_tests.step);
        test_all.dependOn(&run_tests.step);
    }
}

const Module = struct {
    name: []const u8,
    test_step: []const u8,
    module: *std.Build.Module,
};
