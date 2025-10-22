const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const iface_mod = b.createModule(.{
        .root_source_file = b.path("plugin_interface.zig"),
        .target = target,
        .optimize = optimize,
    });

    const host = b.addExecutable(.{
        .name = "hotreload_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    host.root_module.link_libc = true;
    host.root_module.addImport("iface", iface_mod);
    b.installArtifact(host);

    const plugin_names = [_][]const u8{ "plugin_a", "plugin_b" };
    inline for (plugin_names) |name| {
        const lib = b.addLibrary(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(std.fmt.comptimePrint("plugins/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
            .version = .{ .major = 0, .minor = 0, .patch = 1 },
            .linkage = .dynamic,
        });
        lib.root_module.link_libc = true;
        lib.root_module.addImport("iface", iface_mod);
        b.installArtifact(lib);
    }
}
