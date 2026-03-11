const std = @import("std");

pub const TemporalResolveParams = struct {
    history_weight: f32,
};

pub fn resolvePixel(current_pixel: u32, history_pixel: u32, params: TemporalResolveParams) u32 {
    const w = std.math.clamp(params.history_weight, 0.0, 1.0);
    const cw = 1.0 - w;

    const Float3 = @Vector(3, f32);
    const cur: Float3 = .{
        @floatFromInt((current_pixel >> 16) & 0xFF),
        @floatFromInt((current_pixel >> 8) & 0xFF),
        @floatFromInt(current_pixel & 0xFF),
    };
    const hist: Float3 = .{
        @floatFromInt((history_pixel >> 16) & 0xFF),
        @floatFromInt((history_pixel >> 8) & 0xFF),
        @floatFromInt(history_pixel & 0xFF),
    };
    const mixed = cur * @as(Float3, @splat(cw)) + hist * @as(Float3, @splat(w));
    const clamped = @max(@as(Float3, @splat(0.0)), @min(@as(Float3, @splat(255.0)), mixed));
    const out_r: u32 = @intFromFloat(clamped[0]);
    const out_g: u32 = @intFromFloat(clamped[1]);
    const out_b: u32 = @intFromFloat(clamped[2]);

    return 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
}

pub fn resolvePixelBatch(current_pixels: []const u32, history_pixels: []const u32, params: TemporalResolveParams, out_pixels: []u32) void {
    const len = @min(current_pixels.len, @min(history_pixels.len, out_pixels.len));
    var i: usize = 0;
    while (i + 8 <= len) : (i += 8) {
        inline for (0..8) |lane| {
            out_pixels[i + lane] = resolvePixel(current_pixels[i + lane], history_pixels[i + lane], params);
        }
    }
    while (i < len) : (i += 1) {
        out_pixels[i] = resolvePixel(current_pixels[i], history_pixels[i], params);
    }
}
