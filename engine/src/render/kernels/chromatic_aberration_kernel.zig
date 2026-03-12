//! Implements the Chromatic Aberration kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");

/// Returns the SIMD lane count selected for the current runtime target.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn runtimeLanes() usize {
    // Keep benchmark module dependency-free by using a conservative fixed lane width.
    return 8;
}

/// Applies a vectorized chromatic-aberration block.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn applyBlock(
    comptime lanes: usize,
    src_pixels: []const u32,
    dst_pixels: []u32,
    row_start: usize,
    x_start: usize,
    width_i32: i32,
    cx: f32,
    dy_sq: f32,
    strength: f32,
) void {
    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);

    var x_lane_f: [lanes]f32 = undefined;
    inline for (0..lanes) |lane| {
        x_lane_f[lane] = @floatFromInt(x_start + lane);
    }

    const x_vec: FloatVec = @bitCast(x_lane_f);
    const dx = (x_vec - @as(FloatVec, @splat(cx))) / @as(FloatVec, @splat(cx));
    const dist = dx * dx + @as(FloatVec, @splat(dy_sq));
    const shift = dist * @as(FloatVec, @splat(strength));

    const r_idx_raw: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(x_vec + shift)));
    const b_idx_raw: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(x_vec - shift)));

    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
            const r_clamped = @max(0, @min(width_i32 - 1, r_idx_raw[lane]));
            const b_clamped = @max(0, @min(width_i32 - 1, b_idx_raw[lane]));
        const idx = row_start + x_start + lane;
        const r_idx = row_start + @as(usize, @intCast(r_clamped));
        const b_idx = row_start + @as(usize, @intCast(b_clamped));

        const px_r = src_pixels[r_idx];
        const px_g = src_pixels[idx];
        const px_b = src_pixels[b_idx];

        const final_r = (px_r >> 16) & 0xFF;
        const final_g = (px_g >> 8) & 0xFF;
        const final_b = px_b & 0xFF;
        dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
    }
}

/// Applies this effect over a `[start_row, end_row)` span.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn applyRows(
    src_pixels: []const u32,
    dst_pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    strength: f32,
) void {
    const cx = @as(f32, @floatFromInt(width)) * 0.5;
    const cy = @as(f32, @floatFromInt(height)) * 0.5;
    const width_i32 = @as(i32, @intCast(width));
    const lanes = runtimeLanes();

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const y_f = @as(f32, @floatFromInt(y));
        const dy = (y_f - cy) / cy;
        const dy_sq = dy * dy;
        var x: usize = 0;
        while (lanes > 1 and x + lanes <= width) : (x += lanes) {
            switch (lanes) {
                8 => applyBlock(8, src_pixels, dst_pixels, row_start, x, width_i32, cx, dy_sq, strength),
                16 => applyBlock(16, src_pixels, dst_pixels, row_start, x, width_i32, cx, dy_sq, strength),
                32 => applyBlock(32, src_pixels, dst_pixels, row_start, x, width_i32, cx, dy_sq, strength),
                else => break,
            }
        }
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const x_f = @as(f32, @floatFromInt(x));
            const dx = (x_f - cx) / cx;
            const dist = dx * dx + dy_sq;
            const shift = dist * strength;

            const r_x = @as(i32, @intFromFloat(x_f + shift));
            const b_x = @as(i32, @intFromFloat(x_f - shift));

            const safe_r_x = @max(0, @min(width_i32 - 1, r_x));
            const safe_b_x = @max(0, @min(width_i32 - 1, b_x));
            const safe_r_x_usize = @as(usize, @intCast(safe_r_x));
            const safe_b_x_usize = @as(usize, @intCast(safe_b_x));
            const r_idx = row_start + safe_r_x_usize;
            const b_idx = row_start + safe_b_x_usize;

            const px_r = src_pixels[r_idx];
            const px_g = src_pixels[idx];
            const px_b = src_pixels[b_idx];

            const final_r = (px_r >> 16) & 0xFF;
            const final_g = (px_g >> 8) & 0xFF;
            const final_b = px_b & 0xFF;

            dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
        }
    }
}
