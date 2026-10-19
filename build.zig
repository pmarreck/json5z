const std = @import("std");

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
        .file = b.path("cj5.c"),
        .flags = &.{"-std=c99"},
    });

    // Add include path so @cImport can find cj5.h
    lib.root_module.addIncludePath(b.path("."));
    lib.installHeader(b.path("cj5.h"), "cj5.h");

    b.installArtifact(lib);

    // Create the Zig module that wraps the C library
    const cj5_mod = b.addModule("cj5", .{
        .root_source_file = b.path("cj5.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the C library to the module
    cj5_mod.linkLibrary(lib);

    // Add tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cj5.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkLibrary(lib);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run cj5 tests");
    test_step.dependOn(&run_tests.step);

    // Differential control: live parser (token and validate-only modes) against
    // a frozen pre-refactor copy of cj5.h kept under tests/oracle.
    const diff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/differential.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    diff_tests.root_module.linkLibrary(lib);
    diff_tests.root_module.addIncludePath(b.path("."));
    diff_tests.root_module.addIncludePath(b.path("tests/oracle"));
    diff_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/oracle/cj5_reference.c"),
        .flags = &.{"-std=c99"},
    });
    test_step.dependOn(&b.addRunArtifact(diff_tests).step);
}
