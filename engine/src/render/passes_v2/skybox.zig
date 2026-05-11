//! Skybox / environment background (v2). Fills pixels where the
//! G-buffer depth is non-finite (no geometry) with an environment
//! colour derived from the screen-space coordinate. Caller can pass
//! a horizon gradient or just sample an HDRI cubemap by direction.
//!
//! Minimal implementation: a vertical gradient from `horizon` (at
//! y = height/2) to `zenith` (at y = 0). Real HDRI sampling is left
//! for when the environment-map cubemap interface lands.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "skybox",
    .idempotent = true,
    .requires_scratch = false,
    .reads_gbuffer = true,
    .summary = "Background fill (gradient) for pixels with no geometry.",
};

pub const Config = struct {
    zenith: [3]u8 = .{ 26, 36, 56 },
    horizon: [3]u8 = .{ 88, 96, 112 },
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    const gbuf = inputs.gbuf orelse return result;

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const inv_h_half: f32 = 2.0 / @as(f32, @floatFromInt(h));
    var modified: usize = 0;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        // 0 at top, 1 at horizon line. Clamp below horizon.
        const t: f32 = @min(1.0, @max(0.0, @as(f32, @floatFromInt(y)) * inv_h_half));
        const r: u32 = @intFromFloat(@as(f32, @floatFromInt(config.zenith[0])) * (1.0 - t) + @as(f32, @floatFromInt(config.horizon[0])) * t);
        const g: u32 = @intFromFloat(@as(f32, @floatFromInt(config.zenith[1])) * (1.0 - t) + @as(f32, @floatFromInt(config.horizon[1])) * t);
        const b: u32 = @intFromFloat(@as(f32, @floatFromInt(config.zenith[2])) * (1.0 - t) + @as(f32, @floatFromInt(config.horizon[2])) * t);
        const px: u32 = 0xFF000000 | (r << 16) | (g << 8) | b;
        const row_start = @as(usize, @intCast(y)) * w_us;
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            if (!std.math.isFinite(gbuf.depth[idx])) {
                inputs.out_color[idx] = px;
                modified += 1;
            } else if (inputs.out_color.ptr != inputs.in_color.ptr) {
                inputs.out_color[idx] = inputs.in_color[idx];
            }
        }
    }
    result.pixels_modified = modified;
    return result;
}
