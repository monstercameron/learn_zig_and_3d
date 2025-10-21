const std = @import("std");

pub const AMBIENT_LIGHT: f32 = 0.25;
pub const DEFAULT_BASE_COLOR: u32 = 0xFFFFDC28; // 255,220,40 in BGRA packing

pub fn computeIntensity(brightness: f32) f32 {
    const clamped = std.math.clamp(brightness, 0.0, 1.0);
    return AMBIENT_LIGHT + clamped * (1.0 - AMBIENT_LIGHT);
}

pub fn applyIntensity(color: u32, intensity: f32) u32 {
    const clamped_intensity = std.math.clamp(intensity, AMBIENT_LIGHT, 1.0);

    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(color & 0xFF));

    const r_val = std.math.clamp(r * clamped_intensity, 0.0, 255.0);
    const g_val = std.math.clamp(g * clamped_intensity, 0.0, 255.0);
    const b_val = std.math.clamp(b * clamped_intensity, 0.0, 255.0);

    return 0xFF000000 | (@as(u32, @intFromFloat(r_val)) << 16) | (@as(u32, @intFromFloat(g_val)) << 8) | @as(u32, @intFromFloat(b_val));
}

pub fn shadeSolid(brightness: f32) u32 {
    return applyIntensity(DEFAULT_BASE_COLOR, computeIntensity(brightness));
}
