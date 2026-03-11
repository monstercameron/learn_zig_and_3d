const std = @import("std");
const cpu_features = @import("../../core/cpu_features.zig");

fn clampByte(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

fn runtimeLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

pub fn applyDepthFogRows(
    pixels: []u32,
    depth_buffer: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    fog: anytype,
) void {
    const lanes = runtimeLanes();
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const row_end = row_start + width;
        var idx = row_start;
        while (lanes > 1 and idx + lanes <= row_end) : (idx += lanes) {
            switch (lanes) {
                8 => blendFogBlock(8, pixels, depth_buffer, idx, fog),
                16 => blendFogBlock(16, pixels, depth_buffer, idx, fog),
                32 => blendFogBlock(32, pixels, depth_buffer, idx, fog),
                else => break,
            }
        }
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

fn blendFogBlock(
    comptime lanes: usize,
    pixels: []u32,
    depth_buffer: []const f32,
    start_idx: usize,
    fog: anytype,
) void {
    var alpha: [lanes]u32 = undefined;
    var r_arr: [lanes]f32 = undefined;
    var g_arr: [lanes]f32 = undefined;
    var b_arr: [lanes]f32 = undefined;
    var factor_arr: [lanes]f32 = undefined;
    var valid: [lanes]bool = undefined;

    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
        const idx = start_idx + lane;
        valid[lane] = false;
        const depth = depth_buffer[idx];
        if (!std.math.isFinite(depth) or depth <= fog.near) continue;
        const normalized = std.math.clamp((depth - fog.near) * fog.inv_range, 0.0, 1.0);
        if (normalized <= 0.0) continue;
        const factor = normalized * fog.strength;
        if (factor <= 0.001) continue;
        const pixel = pixels[idx];
        alpha[lane] = pixel & 0xFF000000;
        r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
        g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
        b_arr[lane] = @floatFromInt(pixel & 0xFF);
        factor_arr[lane] = factor;
        valid[lane] = true;
    }

    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    const ones: FloatVec = @splat(1.0);
    const minv: FloatVec = @splat(0.0);
    const maxv: FloatVec = @splat(255.0);
    const factor: FloatVec = @as(FloatVec, @bitCast(factor_arr));
    const inv = ones - factor;
    const fog_r: FloatVec = @splat(@floatFromInt(fog.color_r));
    const fog_g: FloatVec = @splat(@floatFromInt(fog.color_g));
    const fog_b: FloatVec = @splat(@floatFromInt(fog.color_b));

    const r_out: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(r_arr)) * inv + fog_r * factor)))));
    const g_out: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(g_arr)) * inv + fog_g * factor)))));
    const b_out: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(b_arr)) * inv + fog_b * factor)))));

    var write_lane: usize = 0;
    while (write_lane < lanes) : (write_lane += 1) {
        if (!valid[write_lane]) continue;
        const idx = start_idx + write_lane;
        pixels[idx] = alpha[write_lane] |
            (@as(u32, clampByte(r_out[write_lane])) << 16) |
            (@as(u32, clampByte(g_out[write_lane])) << 8) |
            @as(u32, clampByte(b_out[write_lane]));
    }
}
