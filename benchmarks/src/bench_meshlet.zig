const std = @import("std");
const math = @import("math3d");
const MeshModule = @import("mesh3d.zig");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;

const NEAR_CLIP: f32 = 0.01;
const NEAR_EPSILON: f32 = 1e-4;
const ENABLE_MESHLET_CONE_CULL = false;

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
    packed_vertex_count: usize,
    packed_primitive_count: usize,
    generation_ns: u64,
    avg_vertices_per_meshlet: f64,
    avg_primitives_per_meshlet: f64,
    vertex_reuse_ratio: f64,
    avg_visible_meshlets: f64,
    avg_visible_triangles: f64,
    visible_triangle_ratio: f64,
    avg_cull_ns: f64,
    avg_legacy_visible_triangles: f64,
    avg_legacy_stage_ns: f64,
    meshlet_stage_speedup: f64,
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
    const packed_vertex_count = mesh.meshlet_vertices.len;
    const packed_primitive_count = mesh.meshlet_primitives.len;
    var total_vertices_in_meshlets: usize = 0;
    var total_primitives_in_meshlets: usize = 0;
    for (mesh.meshlets) |meshlet| {
        total_vertices_in_meshlets += meshlet.vertex_count;
        total_primitives_in_meshlets += meshlet.primitive_count;
    }

    const screen_width: i32 = 1280;
    const screen_height: i32 = 720;
    const projection = computeProjection(screen_width, screen_height, 60.0);

    var total_visible_meshlets: usize = 0;
    var total_visible_triangles: usize = 0;
    var cull_time_accum: i128 = 0;
    var total_legacy_visible_triangles: usize = 0;
    var legacy_stage_time_accum: i128 = 0;

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
                visible_triangles += meshlet.primitive_count;
            }
        }
        const cull_end = std.time.nanoTimestamp();
        cull_time_accum += cull_end - cull_start;

        const legacy_start = std.time.nanoTimestamp();
        var legacy_visible_triangles: usize = 0;
        for (mesh.triangles, 0..) |tri, tri_idx| {
            if (triangleVisible(&mesh, tri_idx, tri, camera_position, basis.right, basis.up, basis.forward, projection)) {
                legacy_visible_triangles += 1;
            }
        }
        const legacy_end = std.time.nanoTimestamp();
        legacy_stage_time_accum += legacy_end - legacy_start;

        total_visible_meshlets += visible_meshlets;
        total_visible_triangles += visible_triangles;
        total_legacy_visible_triangles += legacy_visible_triangles;
    }

    const frames_f64 = @as(f64, @floatFromInt(frame_samples));
    const avg_visible_meshlets = @as(f64, @floatFromInt(total_visible_meshlets)) / frames_f64;
    const avg_visible_triangles = @as(f64, @floatFromInt(total_visible_triangles)) / frames_f64;
    const avg_cull_ns = @as(f64, @floatFromInt(cull_time_accum)) / frames_f64;
    const avg_vertices_per_meshlet = if (meshlet_count == 0) 0.0 else @as(f64, @floatFromInt(total_vertices_in_meshlets)) / @as(f64, @floatFromInt(meshlet_count));
    const avg_primitives_per_meshlet = if (meshlet_count == 0) 0.0 else @as(f64, @floatFromInt(total_primitives_in_meshlets)) / @as(f64, @floatFromInt(meshlet_count));
    const vertex_reuse_ratio = if (total_vertices_in_meshlets == 0) 0.0 else @as(f64, @floatFromInt(total_primitives_in_meshlets * 3)) / @as(f64, @floatFromInt(total_vertices_in_meshlets));
    const visible_triangle_ratio = if (triangle_count == 0) 0.0 else avg_visible_triangles / @as(f64, @floatFromInt(triangle_count));
    const avg_legacy_visible_triangles = @as(f64, @floatFromInt(total_legacy_visible_triangles)) / frames_f64;
    const avg_legacy_stage_ns = @as(f64, @floatFromInt(legacy_stage_time_accum)) / frames_f64;
    const meshlet_stage_speedup = if (avg_cull_ns <= 0.0) 0.0 else avg_legacy_stage_ns / avg_cull_ns;

    return MeshletBenchResult{
        .meshlet_count = meshlet_count,
        .triangle_count = triangle_count,
        .packed_vertex_count = packed_vertex_count,
        .packed_primitive_count = packed_primitive_count,
        .generation_ns = generation_ns,
        .avg_vertices_per_meshlet = avg_vertices_per_meshlet,
        .avg_primitives_per_meshlet = avg_primitives_per_meshlet,
        .vertex_reuse_ratio = vertex_reuse_ratio,
        .avg_visible_meshlets = avg_visible_meshlets,
        .avg_visible_triangles = avg_visible_triangles,
        .visible_triangle_ratio = visible_triangle_ratio,
        .avg_cull_ns = avg_cull_ns,
        .avg_legacy_visible_triangles = avg_legacy_visible_triangles,
        .avg_legacy_stage_ns = avg_legacy_stage_ns,
        .meshlet_stage_speedup = meshlet_stage_speedup,
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
    if (projection.x_scale <= 0.0 or projection.y_scale <= 0.0) return true;

    const side_plane_x_len = @sqrt(projection.x_scale * projection.x_scale + 1.0);
    const side_plane_y_len = @sqrt(projection.y_scale * projection.y_scale + 1.0);
    if (projection.x_scale * center_cam.x - center_cam.z > sphere_radius * side_plane_x_len) return false;
    if (-projection.x_scale * center_cam.x - center_cam.z > sphere_radius * side_plane_x_len) return false;
    if (projection.y_scale * center_cam.y - center_cam.z > sphere_radius * side_plane_y_len) return false;
    if (-projection.y_scale * center_cam.y - center_cam.z > sphere_radius * side_plane_y_len) return false;

    if (ENABLE_MESHLET_CONE_CULL and meshlet.normal_cone_cutoff > -1.0) {
        const axis_cam = transformNormalFromBasis(right, up, forward, meshlet.normal_cone_axis);
        const view_to_camera = math.Vec3.scale(center_cam, -1.0);
        const view_len = math.Vec3.length(view_to_camera);
        if (view_len > 1e-6) {
            const view_dir = math.Vec3.scale(view_to_camera, 1.0 / view_len);
            const cone_sine = @sqrt(@max(0.0, 1.0 - meshlet.normal_cone_cutoff * meshlet.normal_cone_cutoff));
            if (math.Vec3.dot(axis_cam, view_dir) < -cone_sine) return false;
        }
    }

    return true;
}

fn transformVertexToCamera(
    position: math.Vec3,
    camera_position: math.Vec3,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
) math.Vec3 {
    const relative = math.Vec3.sub(position, camera_position);
    return math.Vec3.new(
        math.Vec3.dot(relative, right),
        math.Vec3.dot(relative, up),
        math.Vec3.dot(relative, forward),
    );
}

fn transformNormalFromBasis(basis_right: math.Vec3, basis_up: math.Vec3, basis_forward: math.Vec3, normal: math.Vec3) math.Vec3 {
    const transformed = math.Vec3.new(
        math.Vec3.dot(normal, basis_right),
        math.Vec3.dot(normal, basis_up),
        math.Vec3.dot(normal, basis_forward),
    );
    const len = math.Vec3.length(transformed);
    if (len < 1e-6) return math.Vec3.new(0.0, 0.0, 1.0);
    return math.Vec3.scale(transformed, 1.0 / len);
}

fn triangleVisible(
    mesh: *const Mesh,
    tri_idx: usize,
    tri: MeshModule.Triangle,
    camera_position: math.Vec3,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    projection: ProjectionParams,
) bool {
    _ = projection;
    const p0_cam = transformVertexToCamera(mesh.vertices[tri.v0], camera_position, right, up, forward);
    const p1_cam = transformVertexToCamera(mesh.vertices[tri.v1], camera_position, right, up, forward);
    const p2_cam = transformVertexToCamera(mesh.vertices[tri.v2], camera_position, right, up, forward);

    const front0 = p0_cam.z >= NEAR_CLIP - NEAR_EPSILON;
    const front1 = p1_cam.z >= NEAR_CLIP - NEAR_EPSILON;
    const front2 = p2_cam.z >= NEAR_CLIP - NEAR_EPSILON;
    if (!front0 and !front1 and !front2) return false;

    const crosses_near = (front0 or front1 or front2) and !(front0 and front1 and front2);

    var normal_cam = math.Vec3.new(0.0, 0.0, 1.0);
    if (tri_idx < mesh.normals.len) {
        normal_cam = transformNormalFromBasis(right, up, forward, mesh.normals[tri_idx]);
    } else {
        const edge0 = math.Vec3.sub(p1_cam, p0_cam);
        const edge1 = math.Vec3.sub(p2_cam, p0_cam);
        const fallback = math.Vec3.cross(edge0, edge1);
        const len = math.Vec3.length(fallback);
        if (len > 1e-6) normal_cam = math.Vec3.scale(fallback, 1.0 / len);
    }

    if (!crosses_near) {
        var centroid = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
        centroid = math.Vec3.scale(centroid, 1.0 / 3.0);
        const view_dir = math.Vec3.scale(centroid, -1.0);
        const view_len = math.Vec3.length(view_dir);
        if (view_len > 1e-6) {
            const view_vector = math.Vec3.scale(view_dir, 1.0 / view_len);
            if (math.Vec3.dot(normal_cam, view_vector) < -1e-4) return false;
        }
    }

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

            mesh.triangles[tri_index] = MeshModule.Triangle.new(top_left, bottom_left, top_right);
            tri_index += 1;
            mesh.triangles[tri_index] = MeshModule.Triangle.new(top_right, bottom_left, bottom_right);
            tri_index += 1;
        }
    }

    mesh.recalculateNormals();
    return mesh;
}
