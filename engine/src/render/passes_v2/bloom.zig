//! Bloom (v2). Clean rewrite — no separable blur, no 1/4-res
//! down/up-sample stack. Each above-threshold seed pixel stamps a
//! soft additive radial glow directly onto the output buffer. The
//! v1 pipeline's stride/alignment bugs (the horizontal smears) and
//! threshold-curve-clamping artifacts come from that architecture;
//! a direct stamp is cheaper at low seed density and impossible to
//! mis-index.
//!
//! Requires scratch because the seed scan reads the source while
//! the stamp writes the destination.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "bloom",
    .idempotent = false,
    .requires_scratch = true,
    .reads_gbuffer = false,
    .summary = "Bright-pixel extract + additive radial glow stamp.",
};

pub const Config = struct {
    /// Luminance threshold (0..255). Pixels at or above seed bloom.
    threshold: u8 = 220,
    /// Glow intensity, 0..1. Scales each contribution before clamp.
    intensity: f32 = 0.20,
    /// Glow radius in pixels.
    radius_px: i32 = 12,
    /// Stride: sample every N pixels for seeds. Bright sources cluster
    /// so 4-8 catches them and the scan is much cheaper.
    seed_stride: usize = 4,
};

inline fn lumi(p: u32) u8 {
    const r: u32 = (p >> 16) & 0xFF;
    const g: u32 = (p >> 8) & 0xFF;
    const b: u32 = p & 0xFF;
    return @intCast(@min(255, (r * 77 + g * 150 + b * 29) >> 8));
}

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.intensity <= 0.0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (inputs.in_color.ptr == inputs.out_color.ptr) return result;

    // Start out = in.
    @memcpy(inputs.out_color, inputs.in_color);

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const r: i32 = config.radius_px;
    const r_sq = r * r;
    const intensity = config.intensity;
    const stride = config.seed_stride;

    var modified: usize = 0;
    var idx: usize = 0;
    while (idx < inputs.in_color.len) : (idx += stride) {
        const seed = inputs.in_color[idx];
        if (lumi(seed) < config.threshold) continue;
        const sx: i32 = @intCast(idx % w_us);
        const sy: i32 = @intCast(idx / w_us);
        const sr: f32 = @floatFromInt((seed >> 16) & 0xFF);
        const sg: f32 = @floatFromInt((seed >> 8) & 0xFF);
        const sb: f32 = @floatFromInt(seed & 0xFF);
        var dy: i32 = -r;
        while (dy <= r) : (dy += 1) {
            const py = sy + dy;
            if (py < 0 or py >= h) continue;
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                const d2 = dx * dx + dy * dy;
                if (d2 > r_sq) continue;
                const px = sx + dx;
                if (px < 0 or px >= w) continue;
                const falloff: f32 = 1.0 - @as(f32, @floatFromInt(d2)) / @as(f32, @floatFromInt(r_sq));
                const k = falloff * falloff * intensity;
                const pidx = @as(usize, @intCast(py)) * w_us + @as(usize, @intCast(px));
                const dst = inputs.out_color[pidx];
                const dr: f32 = @floatFromInt((dst >> 16) & 0xFF);
                const dg: f32 = @floatFromInt((dst >> 8) & 0xFF);
                const db: f32 = @floatFromInt(dst & 0xFF);
                const or_: u32 = @intFromFloat(std.math.clamp(dr + sr * k, 0.0, 255.0));
                const og: u32 = @intFromFloat(std.math.clamp(dg + sg * k, 0.0, 255.0));
                const ob: u32 = @intFromFloat(std.math.clamp(db + sb * k, 0.0, 255.0));
                inputs.out_color[pidx] = (dst & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
                modified += 1;
            }
        }
    }
    result.pixels_modified = modified;
    return result;
}
