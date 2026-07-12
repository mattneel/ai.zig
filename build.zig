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

    const otel = b.addModule("otel", .{
        .root_source_file = b.path("src/otel/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel.addImport("provider", provider);
    otel.addImport("provider_utils", provider_utils);
    otel.addImport("ai", ai);

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

    const google = b.addModule("google", .{
        .root_source_file = b.path("src/google/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    google.addImport("provider", provider);
    google.addImport("provider_utils", provider_utils);

    const conformance_runner_module = b.createModule(.{
        .root_source_file = b.path("src/conformance/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_runner_module.addImport("provider", provider);
    conformance_runner_module.addImport("provider_utils", provider_utils);
    conformance_runner_module.addImport("ai", ai);
    conformance_runner_module.addImport("openai", openai);
    conformance_runner_module.addImport("anthropic", anthropic);
    conformance_runner_module.addImport("openai_compatible", openai_compatible);
    const conformance_runner = b.addExecutable(.{
        .name = "conformance-runner",
        .root_module = conformance_runner_module,
    });
    const install_conformance_runner = b.addInstallArtifact(conformance_runner, .{});
    const conformance_runner_step = b.step(
        "conformance-runner",
        "Build and install the differential conformance runner",
    );
    conformance_runner_step.dependOn(&install_conformance_runner.step);

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
    ffi.addImport("openai", openai);
    ffi.addImport("xai", xai);
    const ffi_artifact = b.createModule(.{
        .root_source_file = b.path("src/ffi/root.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        .link_libc = true,
        .pic = true,
    });
    ffi_artifact.addImport("ai", ai);
    ffi_artifact.addImport("provider", provider);
    ffi_artifact.addImport("provider_utils", provider_utils);
    ffi_artifact.addImport("openai_compatible", openai_compatible);
    ffi_artifact.addImport("openrouter", openrouter);
    ffi_artifact.addImport("anthropic", anthropic);
    ffi_artifact.addImport("openai", openai);
    ffi_artifact.addImport("xai", xai);
    const translated_header = b.addTranslateC(.{
        .root_source_file = b.path("include/ai.h"),
        .target = target,
        .optimize = optimize,
    });
    ffi.addImport("ai_c_header", translated_header.createModule());

    const ffi_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ai",
        .root_module = ffi_artifact,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    });
    var ffi_symbol_check_step: ?*std.Build.Step = null;
    if (target.result.os.tag == .linux) {
        ffi_shared.setVersionScript(b.path("src/ffi/ai.map"));
        const check_symbols = b.addSystemCommand(&.{ "sh", "scripts/check-ffi-symbols.sh" });
        check_symbols.addFileArg(ffi_shared.getEmittedBin());
        ffi_symbol_check_step = &check_symbols.step;
    }
    ffi_shared.installHeader(b.path("include/ai.h"), "ai.h");
    const install_ffi_shared = b.addInstallArtifact(ffi_shared, .{});

    const ffi_static = b.addLibrary(.{
        .linkage = .static,
        .name = "ai",
        .root_module = ffi_artifact,
    });
    ffi_static.bundle_compiler_rt = true;
    const install_ffi_static = b.addInstallArtifact(ffi_static, .{
        // COFF uses ai.lib for both a static library and a DLL import library.
        // Keep the import library at its platform name and install the static
        // archive under the cross-platform release name instead.
        .dest_sub_path = if (target.result.os.tag == .windows) "libai.a" else null,
    });

    const header_smoke_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    header_smoke_module.addIncludePath(b.path("include"));
    header_smoke_module.addCSourceFile(.{
        .file = b.path("src/ffi/header_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    header_smoke_module.linkLibrary(ffi_shared);
    const header_smoke = b.addExecutable(.{
        .name = "ffi-header-smoke",
        .root_module = header_smoke_module,
    });
    const run_header_smoke = b.addRunArtifact(header_smoke);

    const abi_v1_client_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_v1_client_module.addCSourceFile(.{
        .file = b.path("src/ffi/abi_v1_snapshot_client.c"),
        .flags = &.{"-std=c11"},
    });
    abi_v1_client_module.linkLibrary(ffi_shared);
    const abi_v1_client = b.addExecutable(.{
        .name = "ffi-abi-v1-client",
        .root_module = abi_v1_client_module,
    });
    const run_abi_v1_client = b.addRunArtifact(abi_v1_client);
    const ffi_abi_check = b.step("ffi-abi-check", "Compile and run C11 header and ABI-v1 client checks");
    ffi_abi_check.dependOn(&run_header_smoke.step);
    ffi_abi_check.dependOn(&run_abi_v1_client.step);

    b.getInstallStep().dependOn(&install_ffi_shared.step);
    b.getInstallStep().dependOn(&install_ffi_static.step);
    const ffi_build = b.step("ffi", "Build and install the C ABI libraries and header");
    ffi_build.dependOn(&install_ffi_shared.step);
    ffi_build.dependOn(&install_ffi_static.step);
    ffi_build.dependOn(ffi_abi_check);
    if (ffi_symbol_check_step) |step| ffi_build.dependOn(step);

    const test_support = b.createModule(.{
        .root_source_file = b.path("src/test_support/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support.addImport("provider_utils", provider_utils);
    openai_compatible.addImport("test_support", test_support);
    openai.addImport("test_support", test_support);
    google.addImport("test_support", test_support);
    ai.addImport("test_support", test_support);
    otel.addImport("test_support", test_support);
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
    integration.addImport("google", google);
    integration.addImport("openrouter", openrouter);
    integration.addImport("xai", xai);
    integration.addImport("ai", ai);
    integration.addOptions("build_options", build_options);

    const modules = [_]Module{
        .{ .name = "provider", .test_step = "provider", .module = provider },
        .{ .name = "provider_utils", .test_step = "provider-utils", .module = provider_utils },
        .{ .name = "ai", .test_step = "ai", .module = ai },
        .{ .name = "otel", .test_step = "otel", .module = otel },
        .{ .name = "openai_compatible", .test_step = "openai-compatible", .module = openai_compatible },
        .{ .name = "openrouter", .test_step = "openrouter", .module = openrouter },
        .{ .name = "xai", .test_step = "xai", .module = xai },
        .{ .name = "anthropic", .test_step = "anthropic", .module = anthropic },
        .{ .name = "openai", .test_step = "openai", .module = openai },
        .{ .name = "google", .test_step = "google", .module = google },
        .{ .name = "mcp", .test_step = "mcp", .module = mcp, .test_module = mcp_tests },
        .{ .name = "ffi", .test_step = "ffi", .module = ffi },
        .{ .name = "test_support", .test_step = "support", .module = test_support },
        .{ .name = "integration", .test_step = "integration", .module = integration },
    };

    const test_all = b.step("test", "Run all module tests");
    test_all.dependOn(ffi_abi_check);
    if (ffi_symbol_check_step) |step| test_all.dependOn(step);
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
