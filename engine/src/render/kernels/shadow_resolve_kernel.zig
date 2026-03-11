const std = @import("std");
const math = @import("../../core/math.zig");
const shadow_sample_kernel = @import("shadow_sample_kernel.zig");

fn clampByte(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

pub fn runRows(
    pixels: []u32,
    camera_buffer: []const math.Vec3,
    width: usize,
    start_row: usize,
    end_row: usize,
    config_value: anytype,
    shadow: anytype,
) void {
    if (!shadow.active) return;
    const darkness_scale = @as(f32, @floatFromInt(config_value.darkness_percent)) / 100.0;

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const row_end = row_start + width;

        var idx = row_start;
        while (idx < row_end) : (idx += 1) {
            const camera_pos = camera_buffer[idx];
            if (!std.math.isFinite(camera_pos.z) or camera_pos.z <= config_value.near_plane) continue;

            const world_pos = math.Vec3.add(
                config_value.camera_position,
                math.Vec3.add(
                    math.Vec3.add(
                        math.Vec3.scale(config_value.basis_right, camera_pos.x),
                        math.Vec3.scale(config_value.basis_up, camera_pos.y),
                    ),
                    math.Vec3.scale(config_value.basis_forward, camera_pos.z),
                ),
            );
            const occlusion = shadow_sample_kernel.sampleOcclusion(shadow, world_pos);
            if (occlusion <= 0.0) continue;

            const shadow_scale = 1.0 - darkness_scale * occlusion;
            const pixel = pixels[idx];
            const alpha = pixel & 0xFF000000;
            const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * shadow_scale));
            const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * shadow_scale));
            const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * shadow_scale));

            pixels[idx] = alpha |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        }
    }
}
