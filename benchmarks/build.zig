const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "math_benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the main project's math.zig as a module so benchmarks can import it
    const math_module = b.createModule(.{
        .root_source_file = b.path("../src/math.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("math", math_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        if (args.len > 0) {
            run_cmd.addArgs(args);
        }
    }

    const run_step = b.step("run", "Run the math benchmarks");
    run_step.dependOn(&run_cmd.step);
}