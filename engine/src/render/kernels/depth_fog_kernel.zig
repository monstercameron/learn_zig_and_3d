const std = @import("std");

fn clampByte(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

pub fn applyDepthFogRows(
    pixels: []u32,
    depth_buffer: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    fog: anytype,
) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const row_end = row_start + width;
        var idx = row_start;
        while (idx < row_end) : (idx += 1) {
            const depth = depth_buffer[idx];
            if (!std.math.isFinite(depth) or depth <= fog.near) continue;

            const normalized = std.math.clamp((depth - fog.near) * fog.inv_range, 0.0, 1.0);
            if (normalized <= 0.0) continue;

            const factor = normalized * fog.strength;
            if (factor <= 0.001) continue;

            const pixel = pixels[idx];
            const alpha = pixel & 0xFF000000;
            const inv = 1.0 - factor;

            const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * inv + @as(f32, @floatFromInt(fog.color_r)) * factor));
            const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * inv + @as(f32, @floatFromInt(fog.color_g)) * factor));
            const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * inv + @as(f32, @floatFromInt(fog.color_b)) * factor));

            pixels[idx] = alpha |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        }
    }
}
