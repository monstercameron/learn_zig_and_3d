//! Depth of field (v2). Variable-radius box blur driven by the
//! G-buffer depth's distance from the focal plane. Pixels near
//! `focal_distance` get blur radius 0 (sharp); pixels at the edges
//! of `focal_range` blur up to `max_blur_px`.
//!
//! Requires scratch — the box gather reads source pixels that the
//! pass is writing.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "depth_of_field",
    .idempotent = false,
    .requires_scratch = true,
    .reads_gbuffer = true,
    .summary = "Depth-driven variable box blur (circle of confusion).",
};

pub const Config = struct {
    focal_distance: f32 = 4.0,
    focal_range: f32 = 2.0,
    max_blur_px: i32 = 6,
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.max_blur_px <= 0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (inputs.in_color.ptr == inputs.out_color.ptr) return result;
    const gbuf = inputs.gbuf orelse return result;
    if (gbuf.depth.len != inputs.in_color.len) return result;

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const inv_range: f32 = 1.0 / @max(0.001, config.focal_range);
    const max_r_f: f32 = @floatFromInt(config.max_blur_px);

    var modified: usize = 0;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            const d = gbuf.depth[idx];
            const src = inputs.in_color[idx];
            if (!std.math.isFinite(d)) {
                inputs.out_color[idx] = src;
                continue;
            }
            // Circle of confusion: 0 at focal plane, 1 at focal_range away.
            const coc: f32 = @min(1.0, @abs(d - config.focal_distance) * inv_range);
            const radius: i32 = @intFromFloat(coc * max_r_f);
            if (radius <= 0) {
                inputs.out_color[idx] = src;
                continue;
            }
            // Simple box average within radius.
            var r_sum: u32 = 0;
            var g_sum: u32 = 0;
            var b_sum: u32 = 0;
            var n: u32 = 0;
            var dy: i32 = -radius;
            while (dy <= radius) : (dy += 1) {
                const py = y + dy;
                if (py < 0 or py >= h) continue;
                var dx: i32 = -radius;
                while (dx <= radius) : (dx += 1) {
                    const px = x + dx;
                    if (px < 0 or px >= w) continue;
                    const sidx = @as(usize, @intCast(py)) * w_us + @as(usize, @intCast(px));
                    const p = inputs.in_color[sidx];
                    r_sum += (p >> 16) & 0xFF;
                    g_sum += (p >> 8) & 0xFF;
                    b_sum += p & 0xFF;
                    n += 1;
                }
            }
            const r_out: u32 = r_sum / n;
            const g_out: u32 = g_sum / n;
            const b_out: u32 = b_sum / n;
            inputs.out_color[idx] = (src & 0xFF000000) | (r_out << 16) | (g_out << 8) | b_out;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
