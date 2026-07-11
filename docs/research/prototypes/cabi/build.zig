const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module definition shared by both artifacts.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // c_allocator + host expects libc anyway
        .pic = true,
    });

    const shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ai",
        .root_module = capi_mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    shared.installHeader(b.path("include/ai.h"), "ai.h");
    b.installArtifact(shared);

    const static = b.addLibrary(.{
        .linkage = .static,
        .name = "ai",
        .root_module = capi_mod,
    });
    static.bundle_compiler_rt = true;
    b.installArtifact(static);
}
