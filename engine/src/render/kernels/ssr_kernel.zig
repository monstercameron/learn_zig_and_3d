const std = @import("std");
const math = @import("../../core/math.zig");

const near_clip: f32 = 0.01;
const near_epsilon: f32 = 1e-4;

fn validSceneCameraSample(camera_pos: math.Vec3) bool {
    return std.math.isFinite(camera_pos.x) and
        std.math.isFinite(camera_pos.y) and
        std.math.isFinite(camera_pos.z) and
        camera_pos.z > near_clip;
}

fn sampleSceneCameraClamped(scene_camera: []const math.Vec3, width: usize, height: usize, x: i32, y: i32) math.Vec3 {
    const clamped_x: usize = @intCast(@min(@as(i32, @intCast(width - 1)), @max(0, x)));
    const clamped_y: usize = @intCast(@min(@as(i32, @intCast(height - 1)), @max(0, y)));
    return scene_camera[clamped_y * width + clamped_x];
}

fn estimateSceneNormal(scene_camera: []const math.Vec3, width: usize, height: usize, center: math.Vec3, x: i32, y: i32, step: i32) math.Vec3 {
    const left = sampleSceneCameraClamped(scene_camera, width, height, x - step, y);
    const right = sampleSceneCameraClamped(scene_camera, width, height, x + step, y);
    const up = sampleSceneCameraClamped(scene_camera, width, height, x, y - step);
    const down = sampleSceneCameraClamped(scene_camera, width, height, x, y + step);

    const tangent_x = if (validSceneCameraSample(left) and validSceneCameraSample(right))
        math.Vec3.sub(right, left)
    else if (validSceneCameraSample(right))
        math.Vec3.sub(right, center)
    else if (validSceneCameraSample(left))
        math.Vec3.sub(center, left)
    else
        math.Vec3.new(0.0, 0.0, 0.0);

    const tangent_y = if (validSceneCameraSample(up) and validSceneCameraSample(down))
        math.Vec3.sub(down, up)
    else if (validSceneCameraSample(down))
        math.Vec3.sub(down, center)
    else if (validSceneCameraSample(up))
        math.Vec3.sub(center, up)
    else
        math.Vec3.new(0.0, 0.0, 0.0);

    var normal = math.Vec3.cross(tangent_x, tangent_y);
    if (math.Vec3.length(normal) <= 1e-4) {
        normal = math.Vec3.scale(center, -1.0);
        if (math.Vec3.length(normal) <= 1e-4) return math.Vec3.new(0.0, 0.0, -1.0);
    }

    normal = math.Vec3.normalize(normal);
    if (math.Vec3.dot(normal, center) > 0.0) normal = math.Vec3.scale(normal, -1.0);
    return normal;
}

fn projectCameraPositionFloat(position: math.Vec3, projection: anytype) math.Vec2 {
    const clamped_z = if (position.z < projection.near_plane + near_epsilon)
        projection.near_plane + near_epsilon
    else
        position.z;
    const inv_z = 1.0 / clamped_z;
    const ndc_x = position.x * inv_z * projection.x_scale;
    const ndc_y = position.y * inv_z * projection.y_scale;
    return .{
        .x = ndc_x * projection.center_x + projection.center_x + projection.jitter_x,
        .y = -ndc_y * projection.center_y + projection.center_y + projection.jitter_y,
    };
}

pub fn runRows(
    scene_pixels: []const u32,
    scratch_pixels: []u32,
    scene_camera: []const math.Vec3,
    scene_depth: []const f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    projection: anytype,
    max_samples: i32,
    step_size: f32,
    max_distance: f32,
    thickness: f32,
    intensity: f32,
) void {
    for (start_row..end_row) |y| {
        for (0..width) |x| {
            const idx = y * width + x;
            const p = scene_camera[idx];
            scratch_pixels[idx] = scene_pixels[idx];
            if (!validSceneCameraSample(p)) continue;
            if (scene_depth[idx] > 1000.0) continue;

            const n = estimateSceneNormal(scene_camera, width, height, p, @intCast(x), @intCast(y), 2);
            if (n.x == 0.0 and n.y == 0.0 and n.z == 0.0) continue;
            const v = math.Vec3.normalize(p);
            const dot_vn = math.Vec3.dot(v, n);
            if (dot_vn > 0.0) continue;

            const r = math.Vec3.normalize(math.Vec3.sub(v, math.Vec3.scale(n, 2.0 * dot_vn)));
            var ray_pos = p;
            var hit = false;
            var hit_color: u32 = 0;
            const step = math.Vec3.scale(r, step_size);
            var edge_blend: f32 = 1.0;

            var s: i32 = 0;
            while (s < max_samples) : (s += 1) {
                ray_pos = math.Vec3.add(ray_pos, step);
                if (ray_pos.z < 0.1) break;
                if (@as(f32, @floatFromInt(s + 1)) * step_size > max_distance) break;
                const proj = projectCameraPositionFloat(ray_pos, projection);
                const sx_float = proj.x;
                const sy_float = proj.y;
                if (sx_float < 0 or sx_float >= @as(f32, @floatFromInt(width)) or sy_float < 0 or sy_float >= @as(f32, @floatFromInt(height))) break;

                const sx: usize = @intFromFloat(sx_float);
                const sy: usize = @intFromFloat(sy_float);
                const hit_idx = sy * width + sx;
                const sampled_depth = scene_depth[hit_idx];
                if (!std.math.isFinite(sampled_depth) or sampled_depth > 1000.0) continue;
                if (ray_pos.z > sampled_depth) {
                    const depth_diff = ray_pos.z - sampled_depth;
                    if (depth_diff < thickness) {
                        hit = true;
                        hit_color = scene_pixels[hit_idx];
                        const edge_x = @min(sx_float, @as(f32, @floatFromInt(width)) - sx_float) / @as(f32, @floatFromInt(width));
                        const edge_y = @min(sy_float, @as(f32, @floatFromInt(height)) - sy_float) / @as(f32, @floatFromInt(height));
                        const edge_dist = @min(edge_x, edge_y) * 4.0;
                        edge_blend = @max(0.0, @min(1.0, edge_dist));
                        const facing_ratio = @max(0.0, -r.z);
                        edge_blend *= @max(0.0, @min(1.0, 1.0 - facing_ratio * 0.8));
                        break;
                    }
                }
            }

            if (hit and edge_blend > 0.0) {
                const base_c = scene_pixels[idx];
                const r_r = @as(f32, @floatFromInt((hit_color >> 16) & 0xFF));
                const r_g = @as(f32, @floatFromInt((hit_color >> 8) & 0xFF));
                const r_b = @as(f32, @floatFromInt(hit_color & 0xFF));
                const b_r = @as(f32, @floatFromInt((base_c >> 16) & 0xFF));
                const b_g = @as(f32, @floatFromInt((base_c >> 8) & 0xFF));
                const b_b = @as(f32, @floatFromInt(base_c & 0xFF));
                const fresnel = @max(0.0, @min(1.0, std.math.pow(f32, 1.0 + dot_vn, 3.0)));
                const reflectivity = intensity * fresnel * edge_blend;
                const final_r = @as(u32, @intFromFloat(@max(0.0, @min(255.0, b_r * (1.0 - reflectivity) + r_r * reflectivity))));
                const final_g = @as(u32, @intFromFloat(@max(0.0, @min(255.0, b_g * (1.0 - reflectivity) + r_g * reflectivity))));
                const final_b = @as(u32, @intFromFloat(@max(0.0, @min(255.0, b_b * (1.0 - reflectivity) + r_b * reflectivity))));
                scratch_pixels[idx] = (final_r << 16) | (final_g << 8) | final_b | 0xFF000000;
            }
        }
    }
}
