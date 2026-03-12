//! Build configuration for benchmark binaries and benchmark-only dependencies.
//! Benchmark build/runtime integration module.

const std = @import("std");

/// build builds data structures used by Build.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const math_module = b.createModule(.{
        .root_source_file = b.path("../engine/src/core/math.zig"),
        .target = target,
        .optimize = optimize,
    });
    const render_compute_module = b.createModule(.{
        .root_source_file = b.path("../engine/src/render/kernels/compute.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shadow_raster_module = b.createModule(.{
        .root_source_file = b.path("../engine/src/render/kernels/shadow_raster_kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    const chromatic_aberration_module = b.createModule(.{
        .root_source_file = b.path("../engine/src/render/kernels/chromatic_aberration_kernel.zig"),
        .target = target,
        .optimize = optimize,
    });

    root_module.addImport("math3d", math_module);
    root_module.addImport("render_compute", render_compute_module);
    root_module.addImport("shadow_raster_kernel", shadow_raster_module);
    root_module.addImport("chromatic_aberration_kernel", chromatic_aberration_module);

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
