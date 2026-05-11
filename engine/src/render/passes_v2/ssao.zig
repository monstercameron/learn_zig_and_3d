//! Screen-space ambient occlusion (v2). At each lit pixel, sample
//! the G-buffer depth at a small radial pattern. Count how many of
//! those samples are closer to the camera than the current pixel —
//! that's the occlusion fraction. Darken the pixel proportionally.
//!
//! Reads `depth` and `normal` from the G-buffer. Skips pixels without
//! finite depth (silhouette-correct). Idempotent: re-running doesn't
//! compound because the occlusion is computed from `depth`, not from
//! the current pixel value.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "ssao",
    .idempotent = true,
    .requires_scratch = false,
    .reads_gbuffer = true,
    .summary = "Depth-based ambient occlusion using G-buffer normals + depth.",
};

pub const Config = struct {
    /// Sample radius in pixels.
    radius_px: i32 = 4,
    /// 0..1; how dark the most-occluded pixel gets. 1.0 = pitch black.
    strength: f32 = 0.55,
    /// Depth delta below this is ignored (anti-self-occlusion).
    bias: f32 = 0.01,
};

const SAMPLE_OFFSETS: [12][2]i32 = .{
    .{ 1, 0 },   .{ -1, 0 },  .{ 0, 1 },   .{ 0, -1 },
    .{ 1, 1 },   .{ -1, -1 }, .{ 1, -1 },  .{ -1, 1 },
    .{ 2, 0 },   .{ -2, 0 },  .{ 0, 2 },   .{ 0, -2 },
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.strength <= 0.0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    const gbuf = inputs.gbuf orelse return result;
    if (gbuf.depth.len != inputs.in_color.len) return result;

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const radius = config.radius_px;
    const strength = config.strength;
    const bias = config.bias;
    var modified: usize = 0;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            const d_here = gbuf.depth[idx];
            if (!std.math.isFinite(d_here)) {
                if (inputs.out_color.ptr != inputs.in_color.ptr) inputs.out_color[idx] = inputs.in_color[idx];
                continue;
            }
            // Count occluding neighbours.
            var occluded: u32 = 0;
            var valid: u32 = 0;
            for (SAMPLE_OFFSETS) |off| {
                const sx = x + off[0] * radius;
                const sy = y + off[1] * radius;
                if (sx < 0 or sx >= w or sy < 0 or sy >= h) continue;
                const sidx = @as(usize, @intCast(sy)) * w_us + @as(usize, @intCast(sx));
                const d_n = gbuf.depth[sidx];
                if (!std.math.isFinite(d_n)) continue;
                valid += 1;
                // Sample is "in front of" the centre pixel — counts as occluder.
                if (d_n + bias < d_here) occluded += 1;
            }
            if (valid == 0) {
                if (inputs.out_color.ptr != inputs.in_color.ptr) inputs.out_color[idx] = inputs.in_color[idx];
                continue;
            }
            const frac = @as(f32, @floatFromInt(occluded)) / @as(f32, @floatFromInt(valid));
            const factor = 1.0 - frac * strength;
            if (factor >= 0.999) {
                if (inputs.out_color.ptr != inputs.in_color.ptr) inputs.out_color[idx] = inputs.in_color[idx];
                continue;
            }
            const src = inputs.in_color[idx];
            const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
            const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
            const sb: f32 = @floatFromInt(src & 0xFF);
            const or_: u32 = @intFromFloat(std.math.clamp(sr * factor, 0.0, 255.0));
            const og: u32 = @intFromFloat(std.math.clamp(sg * factor, 0.0, 255.0));
            const ob: u32 = @intFromFloat(std.math.clamp(sb * factor, 0.0, 255.0));
            inputs.out_color[idx] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
