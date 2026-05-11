const std = @import("std");
const math = @import("../../core/math.zig");
const direct_batch = @import("../direct/batch.zig");
const direct_backend = @import("direct_backend.zig");
const shading_stage = @import("../stages/shading_stage.zig");

pub fn execute(
    renderer: anytype,
    mesh: anytype,
    transform: math.Mat4,
    light_dir: math.Vec3,
    pump: anytype,
    projection: anytype,
    noop_job_fn: *const fn (*anyopaque) void,
) !u64 {
    _ = light_dir;
    _ = pump;
    _ = projection;
    _ = noop_job_fn;
    _ = transform;

    const camera: direct_batch.Camera = .{
        .position = renderer.camera_position,
        .yaw = renderer.rotation_angle,
        .pitch = renderer.rotation_x,
        .fov_deg = renderer.camera_fov_deg,
        .aspect = @as(f32, @floatFromInt(renderer.bitmap.width)) / @as(f32, @floatFromInt(renderer.bitmap.height)),
    };

    // Build the deferred lighting config from the scene's primary light
    // so the rendered shading actually matches the visible light source.
    // light_soa.dir_cam_* is already "direction toward light source" in
    // camera space (the existing forward shading uses it that way), so
    // no negation is needed.
    const fov_y_tan_half = std.math.tan(std.math.degreesToRadians(renderer.camera_fov_deg) * 0.5);
    const aspect = @as(f32, @floatFromInt(renderer.bitmap.width)) / @as(f32, @floatFromInt(renderer.bitmap.height));
    const deferred_cfg: ?shading_stage.DeferredConfig = if (renderer.lights.items.len > 0) blk: {
        const primary = renderer.lights.items[0];
        break :blk .{
            .light_dir_camera = math.Vec3.new(
                renderer.light_soa.dir_cam_x[0],
                renderer.light_soa.dir_cam_y[0],
                renderer.light_soa.dir_cam_z[0],
            ),
            .light_color = primary.color,
            .fov_y_tan_half = fov_y_tan_half,
            .aspect = aspect,
        };
    } else null;

    // Build a slice of all scene lights' camera-space directions so
    // screen_shadows can cast a separate shadow ray-march per light.
    var light_dirs_buf: [4]math.Vec3 = undefined;
    var light_dirs_count: usize = 0;
    const max_lights = @min(renderer.lights.items.len, light_dirs_buf.len);
    while (light_dirs_count < max_lights) : (light_dirs_count += 1) {
        light_dirs_buf[light_dirs_count] = math.Vec3.new(
            renderer.light_soa.dir_cam_x[light_dirs_count],
            renderer.light_soa.dir_cam_y[light_dirs_count],
            renderer.light_soa.dir_cam_z[light_dirs_count],
        );
    }
    try renderer.direct_backend.renderSceneMesh(
        renderer.directFrameResources(),
        camera,
        mesh,
        renderer.job_system,
        .{
            .raster_mode = .worker_tiles,
            .transform = math.Mat4.identity(),
            .material_override = null,
            .clear_color = 0xFF0B1220,
            .enable_shading = false,
            .deferred_lighting = deferred_cfg,
            .scene_light_dirs_cam = light_dirs_buf[0..light_dirs_count],
        },
    );

    return 0;
}
