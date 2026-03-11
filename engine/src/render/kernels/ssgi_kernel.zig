const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");

const near_clip: f32 = 0.01;
const ssgi_sample_offsets = [_][2]f32{ .{ -0.184342, 0.168873 }, .{ 0.030910, -0.352200 }, .{ 0.263462, 0.343639 }, .{ -0.492357, -0.087091 }, .{ 0.471674, -0.300040 }, .{ -0.158975, 0.591377 }, .{ -0.304861, -0.586992 }, .{ 0.664200, 0.242565 }, .{ -0.693259, 0.286167 }, .{ 0.335080, -0.716046 }, .{ 0.248153, 0.791151 }, .{ -0.749295, -0.434232 }, .{ 0.880364, -0.193545 }, .{ -0.537984, 0.765227 }, .{ -0.124430, -0.960217 }, .{ 0.764649, 0.644447 } };

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
    if (math.Vec3.dot(normal, center) > 0.0) {
        normal = math.Vec3.scale(normal, -1.0);
    }
    return normal;
}

pub fn runRows(
    pixels: []const u32,
    out_pixels: []u32,
    camera: []const math.Vec3,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
) void {
    const max_dist = config.POST_SSGI_RADIUS;
    const intensity = config.POST_SSGI_INTENSITY;
    const bounce_decay = config.POST_SSGI_BOUNCE_ATTENUATION;

    var y: usize = start_row;
    while (y < end_row) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = y * width + x;
            const pos = camera[idx];

            if (!validSceneCameraSample(pos)) {
                out_pixels[idx] = pixels[idx];
                continue;
            }

            const normal = estimateSceneNormal(camera, width, height, pos, @intCast(x), @intCast(y), 1);
            const seed = @as(u32, @intCast(x)) *% 73856093 ^ @as(u32, @intCast(y)) *% 19349663;
            var rand = std.Random.DefaultPrng.init(seed);

            var accum_r: f32 = 0;
            var accum_g: f32 = 0;
            var accum_b: f32 = 0;
            var valid_samples: f32 = 0;

            const rand_angle = rand.random().float(f32) * 2.0 * std.math.pi;
            const r_cos = @cos(rand_angle);
            const r_sin = @sin(rand_angle);
            const sample_max_dist = @as(f32, @floatFromInt(max_dist));

            var s: usize = 0;
            const num_samples = @as(usize, @intCast(config.POST_SSGI_SAMPLES));
            while (s < num_samples and s < ssgi_sample_offsets.len) : (s += 1) {
                const jitter_r = 0.8 + 0.4 * rand.random().float(f32);
                const u = ssgi_sample_offsets[s][0] * jitter_r;
                const v = ssgi_sample_offsets[s][1] * jitter_r;
                const rot_u = u * r_cos - v * r_sin;
                const rot_v = u * r_sin + v * r_cos;
                const dx = @as(i32, @intFromFloat(rot_u * sample_max_dist));
                const dy = @as(i32, @intFromFloat(rot_v * sample_max_dist));
                const nx = @as(i32, @intCast(x)) + dx;
                const ny = @as(i32, @intCast(y)) + dy;
                if (nx < 0 or ny < 0 or nx >= width or ny >= height) continue;

                const n_idx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                const n_pos = camera[n_idx];
                if (!validSceneCameraSample(n_pos)) continue;

                const delta = math.Vec3.sub(n_pos, pos);
                const dist_sq = math.Vec3.dot(delta, delta);
                if (dist_sq < 0.001) continue;

                const dist = @sqrt(dist_sq);
                const dir = math.Vec3.scale(delta, 1.0 / dist);
                const ndot = math.Vec3.dot(normal, dir);
                if (ndot <= 0.0) continue;

                const neighbor_color = pixels[n_idx];
                const r_val = @as(f32, @floatFromInt((neighbor_color >> 16) & 0xFF)) / 255.0;
                const g_val = @as(f32, @floatFromInt((neighbor_color >> 8) & 0xFF)) / 255.0;
                const b_val = @as(f32, @floatFromInt(neighbor_color & 0xFF)) / 255.0;
                const falloff = 1.0 / (1.0 + dist_sq * bounce_decay);
                const weight = ndot * falloff;
                accum_r += r_val * weight;
                accum_g += g_val * weight;
                accum_b += b_val * weight;
                valid_samples += 1.0;
            }

            const base_color = pixels[idx];
            if (valid_samples > 0) {
                const avg_r = accum_r / valid_samples * intensity;
                const avg_g = accum_g / valid_samples * intensity;
                const avg_b = accum_b / valid_samples * intensity;
                const br = @as(f32, @floatFromInt((base_color >> 16) & 0xFF)) / 255.0;
                const bg = @as(f32, @floatFromInt((base_color >> 8) & 0xFF)) / 255.0;
                const bb = @as(f32, @floatFromInt(base_color & 0xFF)) / 255.0;
                const fr = std.math.clamp(br + br * avg_r, 0.0, 1.0) * 255.0;
                const fg = std.math.clamp(bg + bg * avg_g, 0.0, 1.0) * 255.0;
                const fb = std.math.clamp(bb + bb * avg_b, 0.0, 1.0) * 255.0;
                out_pixels[idx] = (0xFF << 24) | (@as(u32, @intFromFloat(fr)) << 16) | (@as(u32, @intFromFloat(fg)) << 8) | @as(u32, @intFromFloat(fb));
            } else {
                out_pixels[idx] = base_color;
            }
        }
    }
}
