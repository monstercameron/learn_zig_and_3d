const std = @import("std");

// This is the build script for our Zig Windows API application.
// It sets up the executable, links necessary Windows system libraries,
// and installs the artifact for running.

pub fn build(b: *std.Build) void {
    // Define the target platform (e.g., x86_64-windows)
    const target = b.standardTargetOptions(.{});

    // Define the optimization level (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)
    const optimize = b.standardOptimizeOption(.{});

    // Create an executable with the specified name and root source file
    const exe = b.addExecutable(.{
        .name = "zig-windows-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link against Windows system libraries for GUI and graphics
    exe.linkSystemLibrary("user32"); // For window management functions
    exe.linkSystemLibrary("gdi32"); // For graphics device interface functions
    exe.linkSystemLibrary("kernel32"); // For kernel functions

    // Install the executable so it can be run with 'zig build run'
    b.installArtifact(exe);

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

    const run_benchmarks_step = b.step("run-benchmarks", "Run the math benchmarks");
    const benchmarks_run_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build", "run" });
    benchmarks_run_cmd.cwd = b.path("benchmarks");
    run_benchmarks_step.dependOn(&benchmarks_run_cmd.step);
}
