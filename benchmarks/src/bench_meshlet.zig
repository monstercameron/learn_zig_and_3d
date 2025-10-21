const std = @import("std");
const math = @import("math3d");
const MeshModule = @import("mesh3d");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;

const NEAR_CLIP: f32 = 0.01;
const NEAR_EPSILON: f32 = 1e-4;

const ProjectionParams = struct {
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    near_plane: f32,
};

const CameraBasis = struct {
    forward: math.Vec3,
    right: math.Vec3,
    up: math.Vec3,
};

pub const MeshletBenchResult = struct {
    meshlet_count: usize,
    triangle_count: usize,
    generation_ns: u64,
    avg_visible_meshlets: f64,
    avg_visible_triangles: f64,
    avg_cull_ns: f64,
    frames: usize,
};

pub fn runMeshletBench(allocator: std.mem.Allocator, grid_resolution: usize, frame_samples: usize) !MeshletBenchResult {
    std.debug.assert(frame_samples > 0);

    var mesh = try buildGridMesh(allocator, grid_resolution);
    defer mesh.deinit();

    const generation_start = std.time.nanoTimestamp();
    try mesh.generateMeshlets(64, 126);
    const generation_ns = @as(u64, @intCast(std.time.nanoTimestamp() - generation_start));

    const meshlet_count = mesh.meshlets.len;
    const triangle_count = mesh.triangles.len;

    const screen_width: i32 = 1280;
    const screen_height: i32 = 720;
    const projection = computeProjection(screen_width, screen_height, 60.0);

    var total_visible_meshlets: usize = 0;
    var total_visible_triangles: usize = 0;
    var cull_time_accum: i128 = 0;

    var frame_index: usize = 0;
    while (frame_index < frame_samples) : (frame_index += 1) {
        const yaw = 0.1 * @as(f32, @floatFromInt(frame_index));
        const pitch = 0.2 * @sin(0.03 * @as(f32, @floatFromInt(frame_index)));
        const basis = computeCameraBasis(yaw, pitch);
        const camera_position = math.Vec3.new(0.0, 1.5, -6.0);

        const cull_start = std.time.nanoTimestamp();
        var visible_meshlets: usize = 0;
        var visible_triangles: usize = 0;
        for (mesh.meshlets) |meshlet| {
            if (meshletVisible(camera_position, &meshlet, basis.right, basis.up, basis.forward, projection)) {
                visible_meshlets += 1;
                visible_triangles += meshlet.triangle_indices.len;
            }
        }
        const cull_end = std.time.nanoTimestamp();
        cull_time_accum += cull_end - cull_start;

        total_visible_meshlets += visible_meshlets;
        total_visible_triangles += visible_triangles;
    }

    const frames_f64 = @as(f64, @floatFromInt(frame_samples));
    const avg_visible_meshlets = @as(f64, @floatFromInt(total_visible_meshlets)) / frames_f64;
    const avg_visible_triangles = @as(f64, @floatFromInt(total_visible_triangles)) / frames_f64;
    const avg_cull_ns = @as(f64, @floatFromInt(cull_time_accum)) / frames_f64;

    return MeshletBenchResult{
        .meshlet_count = meshlet_count,
        .triangle_count = triangle_count,
        .generation_ns = generation_ns,
        .avg_visible_meshlets = avg_visible_meshlets,
        .avg_visible_triangles = avg_visible_triangles,
        .avg_cull_ns = avg_cull_ns,
        .frames = frame_samples,
    };
}

fn computeProjection(width: i32, height: i32, fov_deg: f32) ProjectionParams {
    const width_f = @as(f32, @floatFromInt(width));
    const height_f = @as(f32, @floatFromInt(height));
    const aspect_ratio = if (height_f > 0.0) width_f / height_f else 1.0;
    const fov_rad = fov_deg * (std.math.pi / 180.0);
    const half_fov = fov_rad * 0.5;
    const tan_half = std.math.tan(half_fov);
    const y_scale = if (tan_half > 0.0) 1.0 / tan_half else 1.0;
    const x_scale = y_scale / aspect_ratio;

    return ProjectionParams{
        .center_x = width_f * 0.5,
        .center_y = height_f * 0.5,
        .x_scale = x_scale,
        .y_scale = y_scale,
        .near_plane = NEAR_CLIP,
    };
}

fn computeCameraBasis(yaw: f32, pitch: f32) CameraBasis {
    const cos_pitch = @cos(pitch);
    const sin_pitch = @sin(pitch);
    const cos_yaw = @cos(yaw);
    const sin_yaw = @sin(yaw);

    var forward = math.Vec3.new(sin_yaw * cos_pitch, sin_pitch, cos_yaw * cos_pitch);
    forward = safeNormalize(forward, math.Vec3.new(0.0, 0.0, 1.0));

    const world_up = math.Vec3.new(0.0, 1.0, 0.0);
    var right = math.Vec3.cross(world_up, forward);
    right = safeNormalize(right, math.Vec3.new(1.0, 0.0, 0.0));

    var up = math.Vec3.cross(forward, right);
    up = safeNormalize(up, math.Vec3.new(0.0, 1.0, 0.0));

    return CameraBasis{ .forward = forward, .right = right, .up = up };
}

fn safeNormalize(v: math.Vec3, fallback: math.Vec3) math.Vec3 {
    const length = math.Vec3.length(v);
    if (length < 1e-6) return fallback;
    return math.Vec3.scale(v, 1.0 / length);
}

fn meshletVisible(
    camera_position: math.Vec3,
    meshlet: *const Meshlet,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    projection: ProjectionParams,
) bool {
    const relative_center = math.Vec3.sub(meshlet.bounds_center, camera_position);
    const center_cam = math.Vec3.new(
        math.Vec3.dot(relative_center, right),
        math.Vec3.dot(relative_center, up),
        math.Vec3.dot(relative_center, forward),
    );

    const radius = meshlet.bounds_radius;
    const safety_margin = radius * 0.5 + 1.0;
    const sphere_radius = radius + safety_margin;

    if (center_cam.z + sphere_radius <= projection.near_plane - NEAR_EPSILON) return false;
    if (center_cam.z <= 0.0 and center_cam.z + sphere_radius <= 0.0) return false;

    const tan_half_fov_x = if (projection.x_scale != 0.0) 1.0 / projection.x_scale else std.math.inf(f32);
    const tan_half_fov_y = if (projection.y_scale != 0.0) 1.0 / projection.y_scale else std.math.inf(f32);

    const horizon_limit = (center_cam.z + sphere_radius) * tan_half_fov_x + sphere_radius;
    if (center_cam.x > horizon_limit or center_cam.x < -horizon_limit) return false;

    const vertical_limit = (center_cam.z + sphere_radius) * tan_half_fov_y + sphere_radius;
    if (center_cam.y > vertical_limit or center_cam.y < -vertical_limit) return false;

    return true;
}

fn buildGridMesh(allocator: std.mem.Allocator, resolution: usize) !Mesh {
    // Ensure we have at least a 1x1 grid.
    const safe_resolution: usize = if (resolution < 1) 1 else resolution;
    var mesh = try Mesh.init(allocator);
    errdefer mesh.deinit();

    const vertices_per_side = safe_resolution + 1;
    const vertex_count = vertices_per_side * vertices_per_side;
    mesh.vertices = try allocator.alloc(math.Vec3, vertex_count);
    mesh.tex_coords = try allocator.alloc(math.Vec2, vertex_count);

    var z_idx: usize = 0;
    while (z_idx < vertices_per_side) : (z_idx += 1) {
        var x_idx: usize = 0;
        while (x_idx < vertices_per_side) : (x_idx += 1) {
            const idx = z_idx * vertices_per_side + x_idx;
            const xf = @as(f32, @floatFromInt(x_idx)) / @as(f32, @floatFromInt(safe_resolution));
            const zf = @as(f32, @floatFromInt(z_idx)) / @as(f32, @floatFromInt(safe_resolution));
            const x = (xf - 0.5) * 20.0;
            const z = (zf - 0.5) * 20.0;
            mesh.vertices[idx] = math.Vec3.new(x, 0.0, z);
            mesh.tex_coords[idx] = math.Vec2.new(xf, zf);
        }
    }

    const triangle_count = safe_resolution * safe_resolution * 2;
    mesh.triangles = try allocator.alloc(MeshModule.Triangle, triangle_count);
    mesh.normals = try allocator.alloc(math.Vec3, triangle_count);

    var tri_index: usize = 0;
    var row: usize = 0;
    while (row < safe_resolution) : (row += 1) {
        var col: usize = 0;
        while (col < safe_resolution) : (col += 1) {
            const top_left = row * vertices_per_side + col;
            const top_right = top_left + 1;
            const bottom_left = top_left + vertices_per_side;
            const bottom_right = bottom_left + 1;

            mesh.triangles[tri_index] = MeshModule.Triangle.new(bottom_left, top_left, top_right);
            tri_index += 1;
            mesh.triangles[tri_index] = MeshModule.Triangle.new(bottom_left, top_right, bottom_right);
            tri_index += 1;
        }
    }

    mesh.recalculateNormals();
    return mesh;
}
