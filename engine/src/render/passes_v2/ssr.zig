//! Screen-space reflections (v2). For each lit pixel, reflect the
//! view ray off the surface normal, march in screen space toward the
//! reflection direction, and if we hit a closer surface, mix that
//! pixel's colour in proportional to roughness.
//!
//! Cheap, screen-space-only — misses reflections off-screen. Good
//! enough as a baseline; a hierarchical SSR would extend it.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "ssr",
    .idempotent = false,
    .requires_scratch = true,
    .reads_gbuffer = true,
    .summary = "Screen-space reflections via short ray-march in NDC.",
};

pub const Config = struct {
    /// 0..1; how much of the reflected colour to mix in.
    intensity: f32 = 0.4,
    /// Number of march steps along the reflection ray.
    steps: u32 = 8,
    /// Pixel step length per march iteration.
    step_px: f32 = 4.0,
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.intensity <= 0.0 or config.steps == 0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (inputs.in_color.ptr == inputs.out_color.ptr) return result;
    const gbuf = inputs.gbuf orelse return result;

    @memcpy(inputs.out_color, inputs.in_color);

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    var modified: usize = 0;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            const d = gbuf.depth[idx];
            if (!std.math.isFinite(d)) continue;
            const n = gbuf.normal[idx];
            // March along screen-space direction biased by the normal's
            // XY projection — surfaces facing the camera reflect "up";
            // tilted ones reflect along the tilt.
            const dir_x = n.x;
            const dir_y = -n.y;
            const len = @sqrt(dir_x * dir_x + dir_y * dir_y);
            if (len < 1.0e-3) continue;
            const sx_step = (dir_x / len) * config.step_px;
            const sy_step = (dir_y / len) * config.step_px;
            var step: u32 = 1;
            var hit: ?u32 = null;
            while (step <= config.steps) : (step += 1) {
                const fx = @as(f32, @floatFromInt(x)) + sx_step * @as(f32, @floatFromInt(step));
                const fy = @as(f32, @floatFromInt(y)) + sy_step * @as(f32, @floatFromInt(step));
                if (fx < 0 or fx >= @as(f32, @floatFromInt(w)) or fy < 0 or fy >= @as(f32, @floatFromInt(h))) break;
                const ix: usize = @intFromFloat(fx);
                const iy: usize = @intFromFloat(fy);
                const sidx = iy * w_us + ix;
                const sd = gbuf.depth[sidx];
                if (std.math.isFinite(sd) and sd < d - 0.01) {
                    hit = inputs.in_color[sidx];
                    break;
                }
            }
            if (hit == null) continue;
            const src = inputs.out_color[idx];
            const k = config.intensity;
            const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
            const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
            const sb: f32 = @floatFromInt(src & 0xFF);
            const hr: f32 = @floatFromInt((hit.? >> 16) & 0xFF);
            const hg: f32 = @floatFromInt((hit.? >> 8) & 0xFF);
            const hb: f32 = @floatFromInt(hit.? & 0xFF);
            const or_: u32 = @intFromFloat(std.math.clamp(sr * (1.0 - k) + hr * k, 0.0, 255.0));
            const og: u32 = @intFromFloat(std.math.clamp(sg * (1.0 - k) + hg * k, 0.0, 255.0));
            const ob: u32 = @intFromFloat(std.math.clamp(sb * (1.0 - k) + hb * k, 0.0, 255.0));
            inputs.out_color[idx] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
