const std = @import("std");
const math = @import("../core/math.zig");
const direct_batch = @import("direct_batch.zig");
const direct_mesh = @import("direct_mesh.zig");
const rasterization_stage = @import("stages/rasterization_stage.zig");
const scene_submission_stage = @import("stages/scene_submission_stage.zig");

pub const Plan = struct {
    camera: direct_batch.Camera,
    raster_mode: rasterization_stage.RasterMode,
    scene_kind: scene_submission_stage.SceneKind,
};

pub fn defaultPlan(
    camera_position: math.Vec3,
    camera_yaw: f32,
    camera_pitch: f32,
    camera_fov_deg: f32,
    viewport_width: i32,
    viewport_height: i32,
    suzanne_mesh: *const direct_mesh.Mesh,
) Plan {
    const active_scene_kind: scene_submission_stage.SceneKind = .suzanne_showcase;
    return switch (active_scene_kind) {
        .suzanne_showcase => suzannePlan(viewport_width, viewport_height, suzanne_mesh),
        else => .{
            .camera = .{
                .position = camera_position,
                .yaw = camera_yaw,
                .pitch = camera_pitch,
                .fov_deg = camera_fov_deg,
            },
            .raster_mode = .worker_tiles,
            .scene_kind = active_scene_kind,
        },
    };
}

fn suzannePlan(viewport_width: i32, viewport_height: i32, mesh: *const direct_mesh.Mesh) Plan {
    const fov_deg: f32 = 40.0;
    const half_fov_y = (fov_deg * (std.math.pi / 180.0)) * 0.5;
    const aspect = @as(f32, @floatFromInt(@max(viewport_width, 1))) / @as(f32, @floatFromInt(@max(viewport_height, 1)));
    const half_fov_x = std.math.atan(@tan(half_fov_y) * aspect);
    const bounds = meshBounds(mesh);
    const extents = math.Vec3.scale(math.Vec3.sub(bounds.max, bounds.min), 0.5);
    const fit_padding: f32 = 1.18;
    const distance_y = extents.y / @tan(half_fov_y);
    const distance_x = extents.x / @tan(half_fov_x);
    const distance = @max(distance_x, distance_y) + extents.z * fit_padding;
    return .{
        .camera = .{
            .position = math.Vec3.new(0.0, 0.0, -distance),
            .yaw = 0.0,
            .pitch = 0.0,
            .fov_deg = fov_deg,
        },
        .raster_mode = .worker_tiles,
        .scene_kind = .suzanne_showcase,
    };
}

const Bounds = struct {
    min: math.Vec3,
    max: math.Vec3,
};

fn meshBounds(mesh: *const direct_mesh.Mesh) Bounds {
    if (mesh.vertices.len == 0) {
        return .{
            .min = math.Vec3.new(-1.0, -1.0, -1.0),
            .max = math.Vec3.new(1.0, 1.0, 1.0),
        };
    }
    var min = mesh.vertices[0];
    var max = mesh.vertices[0];
    for (mesh.vertices[1..]) |vertex| {
        min = math.Vec3.min(min, vertex);
        max = math.Vec3.max(max, vertex);
    }
    return .{ .min = min, .max = max };
}
