const std = @import("std");

const BaseColor = struct {
    r: f32,
    g: f32,
    b: f32,
}{
    .r = 255.0,
    .g = 220.0,
    .b = 40.0,
};

pub const AMBIENT_LIGHT: f32 = 0.25;

pub fn computeLitColor(brightness: f32) u32 {
    const clamped_brightness = std.math.clamp(brightness, 0.0, 1.0);
    const intensity = AMBIENT_LIGHT + clamped_brightness * (1.0 - AMBIENT_LIGHT);

    const r_val = std.math.clamp(BaseColor.r * intensity, 0.0, 255.0);
    const g_val = std.math.clamp(BaseColor.g * intensity, 0.0, 255.0);
    const b_val = std.math.clamp(BaseColor.b * intensity, 0.0, 255.0);

    const r = @as(u32, @intFromFloat(r_val)) << 16;
    const g = @as(u32, @intFromFloat(g_val)) << 8;
    const b = @as(u32, @intFromFloat(b_val));
    return 0xFF000000 | r | g | b;
}
