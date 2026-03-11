const std = @import("std");

// This is the build script for our Zig Windows API application.
// It sets up the executable, links necessary Windows system libraries,
// and installs the artifact for running.

pub fn build(b: *std.Build) void {
    // Define the target platform (e.g., x86_64-windows)
    const target = b.standardTargetOptions(.{});

    // Define the optimization level (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Enable frame pointers for native sampling profilers") orelse false;

    // Create an executable with the specified name and root source file
    const zphysics_dep = b.dependency("zphysics", .{
        .target = target,
        .optimize = optimize,
    });

    // Create an executable with the specified name and root source file
    const app_module = b.createModule(.{
        .root_source_file = b.path("app/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = if (profile) false else null,
    });
    const engine_main_module = b.createModule(.{
        .root_source_file = b.path("engine/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = if (profile) false else null,
    });
    app_module.addImport("engine_main", engine_main_module);
    engine_main_module.addImport("zphysics", zphysics_dep.module("root"));

    const exe = b.addExecutable(.{
        .name = "zig-windows-app",
        .root_module = app_module,
    });

    // Link against Windows system libraries for GUI and graphics
    exe.linkSystemLibrary("user32"); // For window management functions
    exe.linkSystemLibrary("gdi32"); // For graphics device interface functions
    exe.linkSystemLibrary("kernel32"); // For kernel functions
    exe.linkSystemLibrary("winmm"); // For timer resolution control
    exe.linkSystemLibrary("dwmapi"); // For compositor-backed frame pacing
    exe.root_module.addImport("zphysics", zphysics_dep.module("root"));
    exe.linkLibrary(zphysics_dep.artifact("joltc"));

    // Install the executable so it can be run with 'zig build run'
    b.installArtifact(exe);

    const check_step = b.step("check", "Compile the main renderer without running it");
    check_step.dependOn(&exe.step);

    const validate_step = b.step("validate", "Build the main app and supported subprojects");
    validate_step.dependOn(check_step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/smoke_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
    validate_step.dependOn(&run_unit_tests.step);

    // Add a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Optional benchmark subproject
    const benchmarks_step = b.step("benchmarks", "Build the math benchmark suite");
    const benchmarks_build_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build" });
    benchmarks_build_cmd.cwd = b.path("benchmarks");
    benchmarks_step.dependOn(&benchmarks_build_cmd.step);
    validate_step.dependOn(&benchmarks_build_cmd.step);

    const run_benchmarks_step = b.step("run-benchmarks", "Run the math benchmarks");
    const benchmarks_run_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build", "run" });
    benchmarks_run_cmd.cwd = b.path("benchmarks");
    run_benchmarks_step.dependOn(&benchmarks_run_cmd.step);

    const hotreload_demo_step = b.step("hotreload-demo", "Build the hot reload experiment");
    const hotreload_demo_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build" });
    hotreload_demo_cmd.cwd = b.path("experiments/hotreload_demo");
    hotreload_demo_step.dependOn(&hotreload_demo_cmd.step);
    validate_step.dependOn(&hotreload_demo_cmd.step);
}
