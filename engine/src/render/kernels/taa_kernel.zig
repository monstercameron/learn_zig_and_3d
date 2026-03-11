const std = @import("std");

pub const TemporalResolveParams = struct {
    history_weight: f32,
};

pub fn resolvePixel(current_pixel: u32, history_pixel: u32, params: TemporalResolveParams) u32 {
    const w = std.math.clamp(params.history_weight, 0.0, 1.0);
    const cw = 1.0 - w;

    const cr = @as(f32, @floatFromInt((current_pixel >> 16) & 0xFF));
    const cg = @as(f32, @floatFromInt((current_pixel >> 8) & 0xFF));
    const cb = @as(f32, @floatFromInt(current_pixel & 0xFF));

    const hr = @as(f32, @floatFromInt((history_pixel >> 16) & 0xFF));
    const hg = @as(f32, @floatFromInt((history_pixel >> 8) & 0xFF));
    const hb = @as(f32, @floatFromInt(history_pixel & 0xFF));

    const out_r = @as(u32, @intFromFloat(std.math.clamp(cr * cw + hr * w, 0.0, 255.0)));
    const out_g = @as(u32, @intFromFloat(std.math.clamp(cg * cw + hg * w, 0.0, 255.0)));
    const out_b = @as(u32, @intFromFloat(std.math.clamp(cb * cw + hb * w, 0.0, 255.0)));

    return 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
}
