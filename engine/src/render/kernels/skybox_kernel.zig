//! Implements the Skybox kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const math = @import("../../core/math.zig");

/// Applies this effect over a `[start_row, end_row)` span.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn applyRows(
    pixels: []u32,
    scene_depth: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    projection: anytype,
    hdri_map: anytype,
) void {
    const center_x = projection.center_x;
    const center_y = projection.center_y;

    var y: usize = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const py_f = @as(f32, @floatFromInt(y));
        const ndc_y = (center_y - py_f) / center_y;
        const camera_y = ndc_y / projection.y_scale;

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            if (scene_depth[idx] < std.math.inf(f32)) continue;

            const px_f = @as(f32, @floatFromInt(x));
            const ndc_x = (px_f - center_x) / center_x;
            const camera_x = ndc_x / projection.x_scale;

            const dir_local = math.Vec3.normalize(math.Vec3.new(camera_x, camera_y, 1.0));
            const right_term = math.Vec3.scale(right, dir_local.x);
            const up_term = math.Vec3.scale(up, dir_local.y);
            const fwd_term = math.Vec3.scale(forward, dir_local.z);
            const dir_world = math.Vec3.normalize(math.Vec3.add(right_term, math.Vec3.add(up_term, fwd_term)));
            const hdr_color = hdri_map.sampleEquirectangularFast(dir_world);

            const exposure: f32 = 2.5;
            const r_ldr = (hdr_color.x * exposure) / (1.0 + (hdr_color.x * exposure));
            const g_ldr = (hdr_color.y * exposure) / (1.0 + (hdr_color.y * exposure));
            const b_ldr = (hdr_color.z * exposure) / (1.0 + (hdr_color.z * exposure));

            const r_gamma = std.math.sqrt(r_ldr);
            const g_gamma = std.math.sqrt(g_ldr);
            const b_gamma = std.math.sqrt(b_ldr);

            const r = @as(u32, @intFromFloat(std.math.clamp(r_gamma * 255.0, 0.0, 255.0)));
            const g = @as(u32, @intFromFloat(std.math.clamp(g_gamma * 255.0, 0.0, 255.0)));
            const b = @as(u32, @intFromFloat(std.math.clamp(b_gamma * 255.0, 0.0, 255.0)));
            pixels[idx] = (0xFF << 24) | (r << 16) | (g << 8) | b;
        }
    }
}
