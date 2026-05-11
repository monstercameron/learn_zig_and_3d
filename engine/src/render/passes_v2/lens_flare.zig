//! Lens flare (v2). Detects above-threshold bright pixels, mirrors
//! them about the screen centre (the classic "ghost" position), and
//! adds a soft point glow at the ghost coordinates.
//!
//! Clean rewrite — the v1 pass used a wide LDR blur that flooded
//! the whole frame to white whenever any pixel was bright. This
//! version only writes at the ghost coordinate(s), so the maximum
//! affected area is bounded by `ghost_count * radius²`.
//!
//! Idempotent: ghosts are computed from the source threshold mask,
//! not from prior frame state — re-running on its own output adds
//! more glow (intentional for stacking), but the *source-derived*
//! ghost positions are stable.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "lens_flare",
    .idempotent = false,
    .requires_scratch = false,
    .reads_gbuffer = false,
    .summary = "Point-mirrored bright-pixel ghosts about screen centre.",
};

pub const Config = struct {
    /// Luminance threshold (0..255). Pixels at or above seed ghosts.
    threshold: u8 = 220,
    /// Glow intensity, 0..1. Below ~0.05 = invisible; above ~0.5 = blown.
    intensity: f32 = 0.25,
    /// Ghost radius in pixels.
    radius_px: i32 = 16,
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
    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const cx = @divTrunc(w, 2);
    const cy = @divTrunc(h, 2);
    const r: i32 = config.radius_px;
    const r_sq = r * r;
    const intensity = config.intensity;

    // Pass-through: copy in -> out first, then add ghosts on top.
    if (inputs.in_color.ptr != inputs.out_color.ptr) {
        @memcpy(inputs.out_color, inputs.in_color);
    }

    // Scan for bright seeds and stamp ghosts. To keep cost bounded we
    // sample every 8th pixel — bright sources tend to be cluster-sized
    // so this still catches them and is dirt cheap.
    var modified: usize = 0;
    var idx: usize = 0;
    while (idx < inputs.in_color.len) : (idx += 8) {
        if (lumi(inputs.in_color[idx]) < config.threshold) continue;
        const w_us: usize = @intCast(w);
        const src_x: i32 = @intCast(idx % w_us);
        const src_y: i32 = @intCast(idx / w_us);
        // Mirror about centre: ghost_pos = 2*cx - src_x, etc.
        const gx = 2 * cx - src_x;
        const gy = 2 * cy - src_y;
        if (gx < 0 or gx >= w or gy < 0 or gy >= h) continue;
        const src = inputs.in_color[idx];
        const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
        const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
        const sb: f32 = @floatFromInt(src & 0xFF);
        // Stamp a circular soft glow at (gx, gy).
        var dy: i32 = -r;
        while (dy <= r) : (dy += 1) {
            const py = gy + dy;
            if (py < 0 or py >= h) continue;
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                const d2 = dx * dx + dy * dy;
                if (d2 > r_sq) continue;
                const px = gx + dx;
                if (px < 0 or px >= w) continue;
                const falloff: f32 = 1.0 - @as(f32, @floatFromInt(d2)) / @as(f32, @floatFromInt(r_sq));
                const k = falloff * falloff * intensity;
                const pidx = @as(usize, @intCast(py)) * @as(usize, @intCast(w)) + @as(usize, @intCast(px));
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
