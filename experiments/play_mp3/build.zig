const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "play_mp3_experiment",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Create a module for the audio engine and add it to the executable.
    const audio_module = b.createModule(.{
        .root_source_file = b.path("src/audio/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("audio", audio_module);

    // Link system libraries required by the audio engine
    exe.linkSystemLibrary("ole32");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the experiment");
    run_step.dependOn(&run_cmd.step);
}