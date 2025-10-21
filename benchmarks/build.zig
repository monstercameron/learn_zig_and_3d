const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const math_module = b.createModule(.{
        .root_source_file = b.path("../src/math.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lighting_module = b.createModule(.{
        .root_source_file = b.path("../src/lighting.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mesh_module = b.createModule(.{
        .root_source_file = b.path("../src/mesh.zig"),
        .target = target,
        .optimize = optimize,
    });

    mesh_module.addImport("math.zig", math_module);

    root_module.addImport("math3d", math_module);
    root_module.addImport("mesh3d", mesh_module);
    root_module.addImport("lighting", lighting_module);

    const exe = b.addExecutable(.{
        .name = "math_benchmarks",
        .root_module = root_module,
    });

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
