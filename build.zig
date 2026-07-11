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
    const default_openrouter = b.option(
        bool,
        "default-openrouter",
        "Compile the OpenRouter-backed default language-model resolver",
    ) orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "live", live);
    build_options.addOption(bool, "default_openrouter", default_openrouter);
    const ai_build_options = b.addOptions();
    ai_build_options.addOption(bool, "default_openrouter", default_openrouter);

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
    ai.addImport("openrouter", openrouter);
    ai.addOptions("ai_build_options", ai_build_options);

    const xai = b.addModule("xai", .{
        .root_source_file = b.path("src/xai/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    xai.addImport("provider", provider);
    xai.addImport("provider_utils", provider_utils);
    xai.addImport("openai_compatible", openai_compatible);

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
    mcp.addImport("ai", ai);

    const mcp_test_server_module = b.createModule(.{
        .root_source_file = b.path("src/mcp/test_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp_test_server = b.addExecutable(.{
        .name = "mcp-test-server",
        .root_module = mcp_test_server_module,
    });
    const mcp_test_options = b.addOptions();
    mcp_test_options.addOptionPath("test_server_path", mcp_test_server.getEmittedBin());

    const ffi = b.addModule("ffi", .{
        .root_source_file = b.path("src/ffi/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    ffi.addImport("ai", ai);
    ffi.addImport("provider", provider);
    ffi.addImport("provider_utils", provider_utils);
    ffi.addImport("openai_compatible", openai_compatible);
    ffi.addImport("openrouter", openrouter);
    ffi.addImport("anthropic", anthropic);
    const translated_header = b.addTranslateC(.{
        .root_source_file = b.path("include/ai.h"),
        .target = target,
        .optimize = optimize,
    });
    ffi.addImport("ai_c_header", translated_header.createModule());

    const ffi_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ai",
        .root_module = ffi,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    ffi_shared.installHeader(b.path("include/ai.h"), "ai.h");
    const install_ffi_shared = b.addInstallArtifact(ffi_shared, .{});

    const ffi_static = b.addLibrary(.{
        .linkage = .static,
        .name = "ai",
        .root_module = ffi,
    });
    ffi_static.bundle_compiler_rt = true;
    const install_ffi_static = b.addInstallArtifact(ffi_static, .{});

    b.getInstallStep().dependOn(&install_ffi_shared.step);
    b.getInstallStep().dependOn(&install_ffi_static.step);
    const ffi_build = b.step("ffi", "Build and install the C ABI libraries and header");
    ffi_build.dependOn(&install_ffi_shared.step);
    ffi_build.dependOn(&install_ffi_static.step);

    const test_support = b.createModule(.{
        .root_source_file = b.path("src/test_support/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support.addImport("provider_utils", provider_utils);
    openai.addImport("test_support", test_support);
    ai.addImport("test_support", test_support);
    xai.addImport("test_support", test_support);
    ffi.addImport("test_support", test_support);

    const mcp_tests = b.createModule(.{
        .root_source_file = b.path("src/mcp/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_tests.addImport("provider", provider);
    mcp_tests.addImport("provider_utils", provider_utils);
    mcp_tests.addImport("ai", ai);
    mcp_tests.addImport("test_support", test_support);
    mcp_tests.addOptions("mcp_test_options", mcp_test_options);

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
    integration.addImport("openai", openai);
    integration.addImport("openrouter", openrouter);
    integration.addImport("xai", xai);
    integration.addImport("ai", ai);
    integration.addOptions("build_options", build_options);

    const modules = [_]Module{
        .{ .name = "provider", .test_step = "provider", .module = provider },
        .{ .name = "provider_utils", .test_step = "provider-utils", .module = provider_utils },
        .{ .name = "ai", .test_step = "ai", .module = ai },
        .{ .name = "openai_compatible", .test_step = "openai-compatible", .module = openai_compatible },
        .{ .name = "openrouter", .test_step = "openrouter", .module = openrouter },
        .{ .name = "xai", .test_step = "xai", .module = xai },
        .{ .name = "anthropic", .test_step = "anthropic", .module = anthropic },
        .{ .name = "openai", .test_step = "openai", .module = openai },
        .{ .name = "mcp", .test_step = "mcp", .module = mcp, .test_module = mcp_tests },
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
            .root_module = entry.test_module orelse entry.module,
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
    test_module: ?*std.Build.Module = null,
};
