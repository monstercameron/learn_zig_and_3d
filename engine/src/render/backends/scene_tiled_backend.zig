const std = @import("std");
const math = @import("../../core/math.zig");
const direct_batch = @import("../direct_batch.zig");
const direct_backend = @import("direct_backend.zig");

pub inline fn usesLegacyMeshWork() bool {
    return false;
}

pub fn execute(
    renderer: anytype,
    mesh: anytype,
    transform: math.Mat4,
    light_dir: math.Vec3,
    pump: anytype,
    projection: anytype,
    mesh_work: anytype,
    noop_job_fn: *const fn (*anyopaque) void,
) !u64 {
    _ = light_dir;
    _ = pump;
    _ = projection;
    _ = mesh_work;
    _ = noop_job_fn;
    _ = transform;

    const camera: direct_batch.Camera = .{
        .position = renderer.camera_position,
        .yaw = renderer.rotation_angle,
        .pitch = renderer.rotation_x,
        .fov_deg = renderer.camera_fov_deg,
    };

    try renderer.direct_backend.renderSceneMesh(
        renderer.directFrameResources(),
        camera,
        mesh,
        renderer.job_system,
        .{
            .raster_mode = .worker_tiles,
            .transform = math.Mat4.identity(),
            .material_override = .{
                .fill_color = 0xFFD8C3A5,
                .outline_color = null,
                .depth = 1.0,
            },
            .clear_color = 0xFF0B1220,
            .enable_shading = true,
        },
    );

    return 0;
}
