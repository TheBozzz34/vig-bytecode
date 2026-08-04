const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // This module is available to each dependent package. That is the function
    // of this package: the VM and the assembler import the module. They do not
    // copy its tables.
    _ = b.addModule("vig_bytecode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A test executable collects the `test` blocks from its own root file only.
    // Therefore each source file that has tests needs an entry here.
    const test_roots = [_][]const u8{
        "src/root.zig",
        "src/opcode.zig",
        "src/foreign.zig",
        "src/container.zig",
        "src/encode.zig",
        "src/verify.zig",
    };

    const test_step = b.step("test", "Run tests");
    for (test_roots) |root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
