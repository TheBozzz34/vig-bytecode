const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Exposed to dependents, which is the whole point of this package: the VM
    // and the assembler both import it instead of copying its tables.
    _ = b.addModule("vig_bytecode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A test executable only collects `test` blocks from its own root file, so
    // every source file holding tests needs its own entry here.
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
