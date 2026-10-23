const std = @import("std");

// Interim library: cj5 with our grammar fixes and validate-only mode. It is
// replaced, and this directory deleted, once the Zig validator lands.
const interim = "interim/cj5_modified";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the C library as an artifact
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cj5",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addCSourceFile(.{
        .file = b.path(interim ++ "/cj5.c"),
        .flags = &.{"-std=c99"},
    });

    // Add include path so @cImport can find cj5.h
    lib.root_module.addIncludePath(b.path(interim));
    lib.installHeader(b.path(interim ++ "/cj5.h"), "cj5.h");

    b.installArtifact(lib);

    // Create the Zig module that wraps the C library
    const cj5_mod = b.addModule("cj5", .{
        .root_source_file = b.path(interim ++ "/cj5.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the C library to the module
    cj5_mod.linkLibrary(lib);

    // Add tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(interim ++ "/cj5.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkLibrary(lib);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    // Refactoring regression check: the interim parser (token and validate-only
    // modes) against its own frozen pre-refactor copy. Not a JSON5 oracle.
    const diff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(interim ++ "/tests/differential.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    diff_tests.root_module.linkLibrary(lib);
    diff_tests.root_module.addIncludePath(b.path(interim));
    diff_tests.root_module.addIncludePath(b.path(interim ++ "/tests/oracle"));
    diff_tests.root_module.addCSourceFile(.{
        .file = b.path(interim ++ "/tests/oracle/cj5_reference.c"),
        .flags = &.{"-std=c99"},
    });
    test_step.dependOn(&b.addRunArtifact(diff_tests).step);

    // Degraded oracle: unmodified upstream cj5 (hash-checked), judged through
    // a wrapper that compiles it with every symbol static.
    const upstream_cj5 = b.createModule(.{
        .root_source_file = b.path("tests/upstream_cj5/upstream_cj5_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    upstream_cj5.addIncludePath(b.path("tests/upstream_cj5"));
    upstream_cj5.addCSourceFile(.{
        .file = b.path("tests/upstream_cj5/upstream_cj5_judge.c"),
        .flags = &.{"-std=c11"},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = upstream_cj5 })).step);
}
