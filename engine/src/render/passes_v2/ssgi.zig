//! Screen-space global illumination (v2). For each lit pixel, sample
//! a small ring of neighbours from the G-buffer; if their normal
//! roughly faces this pixel, treat their colour as bounce light and
//! add a fraction of it back.
//!
//! Coarse and screen-space-bound — won't catch indirect light from
//! off-screen surfaces. Adds soft colour bleeding between adjacent
//! coloured surfaces (e.g. red wall bouncing pink onto a white floor).

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "ssgi",
    .idempotent = false,
    .requires_scratch = true,
    .reads_gbuffer = true,
    .summary = "Screen-space single-bounce GI via neighbour-normal sampling.",
};

pub const Config = struct {
    intensity: f32 = 0.15,
    /// Ring sample radius in pixels.
    radius_px: i32 = 8,
};

const RING: [8][2]i32 = .{
    .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 },
    .{ 1, 1 }, .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 },
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.intensity <= 0.0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (inputs.in_color.ptr == inputs.out_color.ptr) return result;
    const gbuf = inputs.gbuf orelse return result;

    @memcpy(inputs.out_color, inputs.in_color);

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const r = config.radius_px;
    var modified: usize = 0;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            if (!std.math.isFinite(gbuf.depth[idx])) continue;
            const n_here = gbuf.normal[idx];
            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;
            var weight_total: f32 = 0;
            for (RING) |off| {
                const sx = x + off[0] * r;
                const sy = y + off[1] * r;
                if (sx < 0 or sx >= w or sy < 0 or sy >= h) continue;
                const sidx = @as(usize, @intCast(sy)) * w_us + @as(usize, @intCast(sx));
                if (!std.math.isFinite(gbuf.depth[sidx])) continue;
                // Weight by how anti-parallel the neighbour normal is
                // to this pixel's — surfaces facing each other bounce.
                const n_n = gbuf.normal[sidx];
                const dot = -(n_here.x * n_n.x + n_here.y * n_n.y + n_here.z * n_n.z);
                if (dot <= 0) continue;
                const w_s = dot;
                const p = inputs.in_color[sidx];
                r_sum += @as(f32, @floatFromInt((p >> 16) & 0xFF)) * w_s;
                g_sum += @as(f32, @floatFromInt((p >> 8) & 0xFF)) * w_s;
                b_sum += @as(f32, @floatFromInt(p & 0xFF)) * w_s;
                weight_total += w_s;
            }
            if (weight_total < 0.05) continue;
            const inv_w = 1.0 / weight_total;
            const k = config.intensity;
            const src = inputs.out_color[idx];
            const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
            const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
            const sb: f32 = @floatFromInt(src & 0xFF);
            const or_: u32 = @intFromFloat(std.math.clamp(sr + r_sum * inv_w * k, 0.0, 255.0));
            const og: u32 = @intFromFloat(std.math.clamp(sg + g_sum * inv_w * k, 0.0, 255.0));
            const ob: u32 = @intFromFloat(std.math.clamp(sb + b_sum * inv_w * k, 0.0, 255.0));
            inputs.out_color[idx] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
