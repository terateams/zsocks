const std = @import("std");

// Single source of truth for the release version: `build.zig.zon`'s `.version`.
// It is injected into the binary via the `build_options` module below, so the
// string is never duplicated in source. Bump it there before tagging; the
// release workflow asserts the git tag matches it.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the package version to the code as `@import("build_options")`.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "zsocks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zsocks");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", build_options);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build release` -> static binaries for the architectures RouterOS's
    // container feature supports (arm64/arm/x86_64). Others can be built ad-hoc
    // with `zig build -Dtarget=<triple>`.
    const release_step = b.step("release", "Build static binaries for deployment targets");
    const triples = [_][]const u8{
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "arm-linux-musleabihf",
    };
    for (triples) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = triple,
        }) catch @panic("bad triple"));
        const rel = b.addExecutable(.{
            .name = "zsocks",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSmall,
                .link_libc = true,
                .strip = true,
            }),
        });
        rel.root_module.addOptions("build_options", build_options);
        // Statically link libc so the artifact is a single self-contained binary.
        rel.linkage = .static;
        const install = b.addInstallArtifact(rel, .{
            .dest_dir = .{ .override = .{ .custom = triple } },
        });
        release_step.dependOn(&install.step);
    }
}
