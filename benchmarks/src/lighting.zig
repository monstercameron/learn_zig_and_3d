const std = @import("std");

pub const AMBIENT_LIGHT: f32 = 0.25;

pub fn applyIntensity(color: u32, intensity: f32) u32 {
    const clamped_intensity = std.math.clamp(intensity, AMBIENT_LIGHT, 1.0);
    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(color & 0xFF));

    const r_val = std.math.clamp(r * clamped_intensity, 0.0, 255.0);
    const g_val = std.math.clamp(g * clamped_intensity, 0.0, 255.0);
    const b_val = std.math.clamp(b * clamped_intensity, 0.0, 255.0);

    return (255 << 24) | (@as(u32, @intFromFloat(r_val)) << 16) | (@as(u32, @intFromFloat(g_val)) << 8) | @as(u32, @intFromFloat(b_val));
}
