//! Build configuration for benchmark binaries and benchmark-only dependencies.
//! Benchmark build/runtime integration module.

const std = @import("std");

/// build builds data structures used by Build.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const math_module = b.createModule(.{
        .root_source_file = b.path("../engine/src/core/math.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_bench_module = b.createModule(.{
        .root_source_file = b.path("../engine/src/bench_exports.zig"),
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

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
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

    const raster_module = b.createModule(.{
        .root_source_file = b.path("rasterize-triangle-microbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    raster_module.addImport("engine_bench", engine_bench_module);

    const raster_exe = b.addExecutable(.{
        .name = "rasterize_triangle_microbench",
        .root_module = raster_module,
    });
    const run_raster_cmd = b.addRunArtifact(raster_exe);
    if (b.args) |args| {
        if (args.len > 0) {
            run_raster_cmd.addArgs(args);
        }
    }
    const run_raster_step = b.step("run-raster-microbench", "Run rasterize-triangle microbench");
    run_raster_step.dependOn(&run_raster_cmd.step);

    const phase15_module = b.createModule(.{
        .root_source_file = b.path("phase15-microbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    phase15_module.addImport("engine_bench", engine_bench_module);

    const phase15_exe = b.addExecutable(.{
        .name = "phase15_microbench",
        .root_module = phase15_module,
    });
    const run_phase15_cmd = b.addRunArtifact(phase15_exe);
    if (b.args) |args| {
        if (args.len > 0) {
            run_phase15_cmd.addArgs(args);
        }
    }
    const run_phase15_step = b.step("run-phase15-microbench", "Run Phase 15 microbench suite");
    run_phase15_step.dependOn(&run_phase15_cmd.step);

    const perf_uplift_module = b.createModule(.{
        .root_source_file = b.path("perf-uplift-microbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    perf_uplift_module.addImport("engine_bench", engine_bench_module);

    const perf_uplift_exe = b.addExecutable(.{
        .name = "perf_uplift_microbench",
        .root_module = perf_uplift_module,
    });
    const run_perf_uplift_cmd = b.addRunArtifact(perf_uplift_exe);
    if (b.args) |args| {
        if (args.len > 0) {
            run_perf_uplift_cmd.addArgs(args);
        }
    }
    const run_perf_uplift_step = b.step("run-perf-uplift-microbench", "Run performance uplift microbench suite");
    run_perf_uplift_step.dependOn(&run_perf_uplift_cmd.step);
}
