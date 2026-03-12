//! Implements the God Rays kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const cpu_features = @import("../../core/cpu_features.zig");

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

/// Applies this effect over a `[start_row, end_row)` span.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn applyRows(
    src_pixels: []const u32,
    dst_pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    light_screen_pos_x: f32,
    light_screen_pos_y: f32,
    samples: i32,
    decay: f32,
    density: f32,
    weight: f32,
    exposure: f32,
) void {
    if (light_screen_pos_x == -1000) {
        const start_idx = start_row * width;
        const end_idx = end_row * width;
        @memcpy(dst_pixels[start_idx..end_idx], src_pixels[start_idx..end_idx]);
        return;
    }

    const lanes = runtimeLanes();
    const width_i32 = @as(i32, @intCast(width));
    const height_i32 = @as(i32, @intCast(height));

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (lanes > 1 and x + lanes <= width) : (x += lanes) {
            switch (lanes) {
                8 => applyBlock(8, src_pixels, dst_pixels, row_start, x, y, width, height, width_i32, height_i32, light_screen_pos_x, light_screen_pos_y, samples, decay, density, weight, exposure),
                16 => applyBlock(16, src_pixels, dst_pixels, row_start, x, y, width, height, width_i32, height_i32, light_screen_pos_x, light_screen_pos_y, samples, decay, density, weight, exposure),
                32 => applyBlock(32, src_pixels, dst_pixels, row_start, x, y, width, height, width_i32, height_i32, light_screen_pos_x, light_screen_pos_y, samples, decay, density, weight, exposure),
                else => break,
            }
        }
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const original_px = src_pixels[idx];
            const delta_x = (@as(f32, @floatFromInt(x)) - light_screen_pos_x);
            const delta_y = (@as(f32, @floatFromInt(y)) - light_screen_pos_y);
            const vec_x = delta_x * density / @as(f32, @floatFromInt(samples));
            const vec_y = delta_y * density / @as(f32, @floatFromInt(samples));

            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;
            var illumination_decay: f32 = 1.0;
            var cur_x = @as(f32, @floatFromInt(x));
            var cur_y = @as(f32, @floatFromInt(y));

            var s: i32 = 0;
            while (s < samples) : (s += 1) {
                cur_x -= vec_x;
                cur_y -= vec_y;
                const sx = @as(i32, @intFromFloat(cur_x));
                const sy = @as(i32, @intFromFloat(cur_y));
                if (sx >= 0 and sx < width_i32 and sy >= 0 and sy < height_i32) {
                    const s_idx = @as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx));
                    const px = src_pixels[s_idx];
                    r_sum += @as(f32, @floatFromInt((px >> 16) & 0xFF)) * illumination_decay * weight;
                    g_sum += @as(f32, @floatFromInt((px >> 8) & 0xFF)) * illumination_decay * weight;
                    b_sum += @as(f32, @floatFromInt(px & 0xFF)) * illumination_decay * weight;
                }
                illumination_decay *= decay;
            }

            const orig_r = @as(f32, @floatFromInt((original_px >> 16) & 0xFF));
            const orig_g = @as(f32, @floatFromInt((original_px >> 8) & 0xFF));
            const orig_b = @as(f32, @floatFromInt(original_px & 0xFF));
            const final_r = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(orig_r + r_sum * exposure))))));
            const final_g = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(orig_g + g_sum * exposure))))));
            const final_b = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(orig_b + b_sum * exposure))))));
            dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
        }
    }
}

/// Applies this effect to a single block/tile region.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn applyBlock(
    comptime lanes: usize,
    src_pixels: []const u32,
    dst_pixels: []u32,
    row_start: usize,
    x_start: usize,
    y: usize,
    width: usize,
    height: usize,
    width_i32: i32,
    height_i32: i32,
    light_screen_pos_x: f32,
    light_screen_pos_y: f32,
    samples: i32,
    decay: f32,
    density: f32,
    weight: f32,
    exposure: f32,
) void {
    _ = height;
    var orig_r: [lanes]f32 = undefined;
    var orig_g: [lanes]f32 = undefined;
    var orig_b: [lanes]f32 = undefined;
    var sum_r: [lanes]f32 = undefined;
    var sum_g: [lanes]f32 = undefined;
    var sum_b: [lanes]f32 = undefined;

    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
        const x = x_start + lane;
        const idx = row_start + x;
        const original_px = src_pixels[idx];
        orig_r[lane] = @floatFromInt((original_px >> 16) & 0xFF);
        orig_g[lane] = @floatFromInt((original_px >> 8) & 0xFF);
        orig_b[lane] = @floatFromInt(original_px & 0xFF);

        const delta_x = (@as(f32, @floatFromInt(x)) - light_screen_pos_x);
        const delta_y = (@as(f32, @floatFromInt(y)) - light_screen_pos_y);
        const vec_x = delta_x * density / @as(f32, @floatFromInt(samples));
        const vec_y = delta_y * density / @as(f32, @floatFromInt(samples));

        var r_sum: f32 = 0;
        var g_sum: f32 = 0;
        var b_sum: f32 = 0;
        var illumination_decay: f32 = 1.0;
        var cur_x = @as(f32, @floatFromInt(x));
        var cur_y = @as(f32, @floatFromInt(y));

        var s: i32 = 0;
        while (s < samples) : (s += 1) {
            cur_x -= vec_x;
            cur_y -= vec_y;
            const sx = @as(i32, @intFromFloat(cur_x));
            const sy = @as(i32, @intFromFloat(cur_y));
            if (sx >= 0 and sx < width_i32 and sy >= 0 and sy < height_i32) {
                const s_idx = @as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx));
                const px = src_pixels[s_idx];
                r_sum += @as(f32, @floatFromInt((px >> 16) & 0xFF)) * illumination_decay * weight;
                g_sum += @as(f32, @floatFromInt((px >> 8) & 0xFF)) * illumination_decay * weight;
                b_sum += @as(f32, @floatFromInt(px & 0xFF)) * illumination_decay * weight;
            }
            illumination_decay *= decay;
        }

        sum_r[lane] = r_sum;
        sum_g[lane] = g_sum;
        sum_b[lane] = b_sum;
    }

    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    const minv: FloatVec = @splat(0.0);
    const maxv: FloatVec = @splat(255.0);
    const exposure_v: FloatVec = @splat(exposure);
    const r_final: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(orig_r)) + @as(FloatVec, @bitCast(sum_r)) * exposure_v)))));
    const g_final: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(orig_g)) + @as(FloatVec, @bitCast(sum_g)) * exposure_v)))));
    const b_final: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(orig_b)) + @as(FloatVec, @bitCast(sum_b)) * exposure_v)))));

    var write_lane: usize = 0;
    while (write_lane < lanes) : (write_lane += 1) {
        const idx = row_start + x_start + write_lane;
        const rr: u32 = @intCast(@max(0, @min(255, r_final[write_lane])));
        const gg: u32 = @intCast(@max(0, @min(255, g_final[write_lane])));
        const bb: u32 = @intCast(@max(0, @min(255, b_final[write_lane])));
        dst_pixels[idx] = 0xFF000000 | (rr << 16) | (gg << 8) | bb;
    }
}
