//! Motion blur (v2). Camera-velocity-driven directional blur. Each
//! pixel samples along the screen-space velocity vector projected
//! from the previous frame's view matrix.
//!
//! Minimal but correct: takes a screen-space velocity `(vx, vy)` per
//! pixel (or a uniform velocity for global camera shake), and samples
//! `samples` pixels along that direction.
//!
//! Requires scratch because the directional gather needs unmodified
//! source pixels.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "motion_blur",
    .idempotent = false,
    .requires_scratch = true,
    .reads_gbuffer = true,
    .summary = "Directional blur along screen-space velocity.",
};

pub const Config = struct {
    /// Uniform velocity (px/frame). If a velocity G-buffer is added
    /// later, this becomes the fallback for invalid samples.
    vx: f32 = 0.0,
    vy: f32 = 0.0,
    /// Sample count along the velocity ray. 3..16 reasonable.
    samples: u32 = 6,
    /// 0..1; how much blur to mix back in. 0 = passthrough.
    intensity: f32 = 0.5,
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.intensity <= 0.0 or config.samples == 0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (inputs.in_color.ptr == inputs.out_color.ptr) return result;
    const speed = @sqrt(config.vx * config.vx + config.vy * config.vy);
    if (speed < 0.5) {
        // Below half a pixel — nothing to do; passthrough.
        @memcpy(inputs.out_color, inputs.in_color);
        return result;
    }

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const samples = config.samples;
    const inv_samples: f32 = 1.0 / @as(f32, @floatFromInt(samples));
    const dx_step = config.vx * inv_samples;
    const dy_step = config.vy * inv_samples;
    const depth = if (inputs.gbuf) |g| g.depth else null;
    var modified: usize = 0;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            if (depth) |dbuf| {
                if (!std.math.isFinite(dbuf[idx])) {
                    inputs.out_color[idx] = inputs.in_color[idx];
                    continue;
                }
            }
            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;
            var s: u32 = 0;
            while (s < samples) : (s += 1) {
                const t: f32 = @floatFromInt(s);
                const sx = @as(f32, @floatFromInt(x)) - t * dx_step;
                const sy = @as(f32, @floatFromInt(y)) - t * dy_step;
                const ix: i32 = @intFromFloat(std.math.clamp(sx, 0.0, @as(f32, @floatFromInt(w - 1))));
                const iy: i32 = @intFromFloat(std.math.clamp(sy, 0.0, @as(f32, @floatFromInt(h - 1))));
                const sidx = @as(usize, @intCast(iy)) * w_us + @as(usize, @intCast(ix));
                const p = inputs.in_color[sidx];
                r_sum += @floatFromInt((p >> 16) & 0xFF);
                g_sum += @floatFromInt((p >> 8) & 0xFF);
                b_sum += @floatFromInt(p & 0xFF);
            }
            const ra = r_sum * inv_samples;
            const ga = g_sum * inv_samples;
            const ba = b_sum * inv_samples;
            const src = inputs.in_color[idx];
            const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
            const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
            const sb: f32 = @floatFromInt(src & 0xFF);
            const k = config.intensity;
            const or_: u32 = @intFromFloat(std.math.clamp(sr * (1.0 - k) + ra * k, 0.0, 255.0));
            const og: u32 = @intFromFloat(std.math.clamp(sg * (1.0 - k) + ga * k, 0.0, 255.0));
            const ob: u32 = @intFromFloat(std.math.clamp(sb * (1.0 - k) + ba * k, 0.0, 255.0));
            inputs.out_color[idx] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
