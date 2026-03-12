//! Implements the Shadow Resolve kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const math = @import("../../core/math.zig");
const cpu_features = @import("../../core/cpu_features.zig");
const shadow_sample_kernel = @import("shadow_sample_kernel.zig");

/// Clamps a scalar channel value to the byte range `[0, 255]`.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn clampByte(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

/// Returns the SIMD lane count selected for the current runtime target.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn runtimeLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

/// Applies shadow scale batch simd.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn applyShadowScaleBatchSimd(comptime lanes: usize, pixels: *const [lanes]u32, scales: *const [lanes]f32) [lanes]u32 {
    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    const max_channel: FloatVec = @splat(255.0);
    const min_channel: FloatVec = @splat(0.0);

    var alpha: [lanes]u32 = undefined;
    var r_arr: [lanes]f32 = undefined;
    var g_arr: [lanes]f32 = undefined;
    var b_arr: [lanes]f32 = undefined;

    inline for (0..lanes) |lane| {
        const pixel = pixels[lane];
        alpha[lane] = pixel & 0xFF000000;
        r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
        g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
        b_arr[lane] = @floatFromInt(pixel & 0xFF);
    }

    const scale_vec: FloatVec = @bitCast(scales.*);
    const r_scaled = @max(min_channel, @min(max_channel, @as(FloatVec, @bitCast(r_arr)) * scale_vec));
    const g_scaled = @max(min_channel, @min(max_channel, @as(FloatVec, @bitCast(g_arr)) * scale_vec));
    const b_scaled = @max(min_channel, @min(max_channel, @as(FloatVec, @bitCast(b_arr)) * scale_vec));
    const r_out: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(r_scaled)));
    const g_out: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(g_scaled)));
    const b_out: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(b_scaled)));

    var result: [lanes]u32 = undefined;
    inline for (0..lanes) |lane| {
        result[lane] = alpha[lane] |
            (@as(u32, clampByte(r_out[lane])) << 16) |
            (@as(u32, clampByte(g_out[lane])) << 8) |
            @as(u32, clampByte(b_out[lane]));
    }
    return result;
}

/// Runs this kernel over a `[start_row, end_row)` span.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
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
    const lanes = runtimeLanes();

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const row_end = row_start + width;

        var idx = row_start;
        while (idx + lanes <= row_end and lanes > 1) : (idx += lanes) {
            // Fixed-size scratch keeps the hot loop stack layout stable across AVX512/AVX2/SSE widths.
            var scales: [32]f32 = [_]f32{1.0} ** 32;
            var pixels_in: [32]u32 = [_]u32{0} ** 32;
            var active_count: usize = 0;

            var lane_i: usize = 0;
            while (lane_i < lanes) : (lane_i += 1) {
                const pidx = idx + lane_i;
                pixels_in[lane_i] = pixels[pidx];
                const camera_pos = camera_buffer[pidx];
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
                scales[lane_i] = 1.0 - darkness_scale * occlusion;
                active_count += 1;
            }

            // Skip SIMD writeback entirely when no lane receives shadow attenuation.
            if (active_count == 0) continue;
            switch (lanes) {
                8 => {
                    const out = applyShadowScaleBatchSimd(8, @ptrCast(&pixels_in), @ptrCast(&scales));
                    @memcpy(pixels[idx .. idx + 8], out[0..8]);
                },
                16 => {
                    const out = applyShadowScaleBatchSimd(16, @ptrCast(&pixels_in), @ptrCast(&scales));
                    @memcpy(pixels[idx .. idx + 16], out[0..16]);
                },
                32 => {
                    const out = applyShadowScaleBatchSimd(32, @ptrCast(&pixels_in), @ptrCast(&scales));
                    @memcpy(pixels[idx .. idx + 32], out[0..32]);
                },
                else => {},
            }
        }

        // Scalar cleanup handles tail pixels when width is not a multiple of the active SIMD lane width.
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
