const std = @import("std");
const AMBIENT_LIGHT: f32 = 0.25;

const VecF32 = @Vector(4, f32);
const VecU32 = @Vector(4, u32);

pub fn applyIntensityBatch(
    colors: []const u32,
    intensities: []const f32,
    out: []u32,
) void {
    std.debug.assert(colors.len == intensities.len and colors.len == out.len);
    const lane_count: comptime_int = 4;
    const ambient: VecF32 = @splat(AMBIENT_LIGHT);
    const max_intensity: VecF32 = @splat(1.0);
    const zero: VecF32 = @splat(0.0);
    const clamp255: VecF32 = @splat(255.0);
    const mask_ff: VecU32 = @splat(0xFF);
    const shift8: VecU32 = @splat(8);
    const shift16: VecU32 = @splat(16);

    var index: usize = 0;
    const vec_limit = colors.len - colors.len % lane_count;
    while (index < vec_limit) : (index += lane_count) {
        const color_vec = VecU32{
            colors[index + 0],
            colors[index + 1],
            colors[index + 2],
            colors[index + 3],
        };
        const intensity_vec = VecF32{
            intensities[index + 0],
            intensities[index + 1],
            intensities[index + 2],
            intensities[index + 3],
        };

        const clamped_intensity = @min(@max(intensity_vec, ambient), max_intensity);

        const r_int = (color_vec >> shift16) & mask_ff;
        const g_int = (color_vec >> shift8) & mask_ff;
        const b_int = color_vec & mask_ff;

        const r = @as(VecF32, @floatFromInt(r_int));
        const g = @as(VecF32, @floatFromInt(g_int));
        const b = @as(VecF32, @floatFromInt(b_int));

        const r_scaled = @min(@max(r * clamped_intensity, zero), clamp255);
        const g_scaled = @min(@max(g * clamped_intensity, zero), clamp255);
        const b_scaled = @min(@max(b * clamped_intensity, zero), clamp255);

        const r_packed = @as(VecU32, @intFromFloat(r_scaled)) << shift16;
        const g_packed = @as(VecU32, @intFromFloat(g_scaled)) << shift8;
        const b_packed = @as(VecU32, @intFromFloat(b_scaled));

        const rgba: VecU32 = @as(VecU32, @splat(0xFF000000)) | r_packed | g_packed | b_packed;

        out[index + 0] = rgba[0];
        out[index + 1] = rgba[1];
        out[index + 2] = rgba[2];
        out[index + 3] = rgba[3];
    }

    var tail = vec_limit;
    while (tail < colors.len) : (tail += 1) {
        out[tail] = applyIntensityScalar(colors[tail], intensities[tail]);
    }
}

pub fn applyIntensityScalar(color: u32, intensity: f32) u32 {
    const clamped_intensity = std.math.clamp(intensity, AMBIENT_LIGHT, 1.0);
    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(color & 0xFF));

    const r_val = std.math.clamp(r * clamped_intensity, 0.0, 255.0);
    const g_val = std.math.clamp(g * clamped_intensity, 0.0, 255.0);
    const b_val = std.math.clamp(b * clamped_intensity, 0.0, 255.0);

    return 0xFF000000 | (@as(u32, @intFromFloat(r_val)) << 16) | (@as(u32, @intFromFloat(g_val)) << 8) | @as(u32, @intFromFloat(b_val));
}
