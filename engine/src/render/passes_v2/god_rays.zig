//! God rays / volumetric scattering (v2). Radial accumulation from a
//! light's screen-space projected position, sampling occlusion along
//! the ray and adding it back as a glow.
//!
//! Each pixel walks toward the light over N samples, decaying with
//! distance, accumulating contribution from bright pixels along the
//! ray. Adds to the source, doesn't replace.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "god_rays",
    .idempotent = false,
    .requires_scratch = false,
    .reads_gbuffer = false,
    .summary = "Radial light shafts from a screen-space light position.",
};

pub const Config = struct {
    /// Light position in screen pixels.
    light_x: f32 = 0.5,
    light_y: f32 = 0.5,
    samples: u32 = 16,
    density: f32 = 1.0, // step length scale
    decay: f32 = 0.92, // multiplicative attenuation per step
    weight: f32 = 0.04, // per-sample weight
    exposure: f32 = 0.8, // final multiplier
};

inline fn lumi(p: u32) f32 {
    const r: f32 = @floatFromInt((p >> 16) & 0xFF);
    const g: f32 = @floatFromInt((p >> 8) & 0xFF);
    const b: f32 = @floatFromInt(p & 0xFF);
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.exposure <= 0.0 or config.weight <= 0.0 or config.samples == 0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const samples = config.samples;
    const inv_samples_f: f32 = 1.0 / @as(f32, @floatFromInt(samples));
    const exposure = config.exposure;

    if (inputs.in_color.ptr != inputs.out_color.ptr) @memcpy(inputs.out_color, inputs.in_color);
    var modified: usize = 0;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            // Vector from pixel to light, stepped over samples.
            const dx = (config.light_x - @as(f32, @floatFromInt(x))) * inv_samples_f * config.density;
            const dy = (config.light_y - @as(f32, @floatFromInt(y))) * inv_samples_f * config.density;
            var illum: f32 = 0;
            var decay: f32 = 1.0;
            var s: u32 = 0;
            var sx: f32 = @floatFromInt(x);
            var sy: f32 = @floatFromInt(y);
            while (s < samples) : (s += 1) {
                sx += dx;
                sy += dy;
                if (sx < 0 or sx >= @as(f32, @floatFromInt(w)) or sy < 0 or sy >= @as(f32, @floatFromInt(h))) break;
                const ix: usize = @intFromFloat(sx);
                const iy: usize = @intFromFloat(sy);
                const p = inputs.in_color[iy * w_us + ix];
                illum += lumi(p) * decay * config.weight;
                decay *= config.decay;
            }
            if (illum < 1.0) continue;
            const add: u32 = @intFromFloat(@min(255.0, illum * exposure));
            const dst = inputs.out_color[idx];
            const dr: u32 = (dst >> 16) & 0xFF;
            const dg: u32 = (dst >> 8) & 0xFF;
            const db: u32 = dst & 0xFF;
            const or_: u32 = @min(255, dr + add);
            const og: u32 = @min(255, dg + add);
            const ob: u32 = @min(255, db + add);
            inputs.out_color[idx] = (dst & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
