# Getting Started

This guide builds a small Anthropic `generateText` program using the same
`std.Io`, `HttpClientTransport`, arena-owned result, and `Diagnostics`
patterns exercised by the repository's integration tests.

## Requirements

- Zig **0.16.0**, the minimum version pinned in `build.zig.zon`.
- A C toolchain supported by Zig when building the C ABI artifacts.
- A provider key for a live request. The example reads
  `ANTHROPIC_API_KEY` in the application and passes the value explicitly.

The repository uses [anyzig](https://github.com/marler8997/anyzig), so running
`zig` from a checkout resolves the compiler from `build.zig.zon`. Consumers
may use anyzig or install Zig 0.16.0 directly. `zig env` identifies the exact
compiler and its `std_dir`; for Zig 0.16's new I/O APIs, that standard-library
source is the authoritative reference.

The packages are not published to package indexes. Once the reviewer publishes
v0.1.0, prefer its pruned source asset; it contains exactly the package paths
declared by `build.zig.zon`:

```sh
zig fetch --save=ai_zig \
  https://github.com/mattneel/ai.zig/releases/download/v0.1.0/ai_zig-0.1.0.tar.gz
```

Before that asset exists, or when deliberately following development, the
master archive remains the secondary beta option. Zig writes a content hash
into `build.zig.zon`, so later builds remain pinned until the dependency is
deliberately refreshed:

```sh
zig fetch --save=ai_zig \
  https://github.com/mattneel/ai.zig/archive/refs/heads/master.tar.gz
```

The [v0.1.0 release page](https://github.com/mattneel/ai.zig/releases/tag/v0.1.0)
also carries `ai-0.1.0-<target>` archives for x86_64 and arm64 Linux, macOS,
and Windows. Each archive contains the platform C libraries, `include/ai.h`,
and the license, notice, and README files; these are separate from the
unpublished Python and Rust wrapper packages.

## Wire the modules into `build.zig`

The package's actual module names come from its root `build.zig`. A complete
small executable build can use:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ai_dep = b.dependency("ai_zig", .{
        .target = target,
        .optimize = optimize,
    });
    app.addImport("ai", ai_dep.module("ai"));
    app.addImport("provider", ai_dep.module("provider"));
    app.addImport("provider_utils", ai_dep.module("provider_utils"));
    app.addImport("anthropic", ai_dep.module("anthropic"));

    const exe = b.addExecutable(.{ .name = "hello-ai", .root_module = app });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the example").dependOn(&run.step);
}
```

Other exported modules are `google`, `openai`, `openai_compatible`,
`openrouter`, `xai`, `mcp`, `otel`, and `ffi`. Add only the imports the
application uses.

## First `generateText` program

Create `src/main.zig`:

```zig
const std = @import("std");
const ai = @import("ai");
const anthropic = @import("anthropic");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

pub fn main(init: std.process.Init) !void {
    const api_key = init.environ_map.get("ANTHROPIC_API_KEY") orelse {
        std.log.err("ANTHROPIC_API_KEY is required", .{});
        return error.MissingApiKey;
    };

    var transport = provider_utils.HttpClientTransport.init(init.gpa, init.io);
    defer transport.deinit();

    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key,
        .transport = transport.transport(),
    });
    var model = try factory.messages("claude-haiku-4-5-20251001", null);

    var diagnostics = provider.Diagnostics.init(init.gpa);
    defer diagnostics.deinit();

    var result = ai.generateText(init.io, init.gpa, .{
        .model = .{ .model = model.languageModel() },
        .prompt = .{ .text = "Say hello from Zig in one short sentence." },
        .max_output_tokens = 64,
        .diag = &diagnostics,
    }) catch |err| {
        if (diagnostics.available) {
            const detail = diagnostics.message(init.arena.allocator())
                catch @errorName(err);
            std.log.err("{s}: {s}", .{ @errorName(err), detail });
        }
        return err;
    };
    defer result.deinit();

    std.debug.print("{s}\n", .{result.text()});
}
```

The provider factory and model are lightweight views. `generateText` creates
an owned result arena; every returned slice remains valid until
`result.deinit()`. `Diagnostics` owns a separate arena, so its payload remains
readable while reporting a failed call.

Run it with an application-supplied key:

```sh
export ANTHROPIC_API_KEY='...'
zig build run
```

Provider factories do not inspect the process environment by themselves.
This program reads `init.environ_map` and passes the key explicitly. Zig
applications that want provider-side named lookups can instead inject
`provider_utils.EnvLookup.fromMap(init.environ_map)`; see
[Providers](providers/index.md#environment-name-reference).

Next, read [Text Generation & Streaming](text-generation.md) for the pull
stream and [Tools & Tool Loops](tools.md) for multi-step calls.
