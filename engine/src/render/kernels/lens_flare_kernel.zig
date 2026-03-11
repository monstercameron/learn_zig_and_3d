const cpu_features = @import("../../core/cpu_features.zig");

fn runtimeLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

pub fn applyRows(
    src_pixels: []const u32,
    dst_pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    threshold: i32,
    intensity: f32,
) void {
    const lanes = runtimeLanes();
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (lanes > 1 and x + lanes <= width) : (x += lanes) {
            switch (lanes) {
                8 => applyBlock(8, src_pixels, dst_pixels, row_start, x, y, width, threshold, intensity),
                16 => applyBlock(16, src_pixels, dst_pixels, row_start, x, y, width, threshold, intensity),
                32 => applyBlock(32, src_pixels, dst_pixels, row_start, x, y, width, threshold, intensity),
                else => break,
            }
        }
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const current_px = src_pixels[idx];

            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;

            const signed_x = @as(i32, @intCast(x));
            const min_sx = @max(0, signed_x - 60);
            const max_sx = @min(@as(i32, @intCast(width)) - 1, signed_x + 60);

            var s_x: i32 = min_sx;
            if (@rem((s_x - (signed_x - 60)), @as(i32, 4)) != 0) {
                s_x += @as(i32, 4) - @rem((s_x - (signed_x - 60)), @as(i32, 4));
            }
            while (s_x <= max_sx) : (s_x += 4) {
                const s_idx = y * width + @as(usize, @intCast(s_x));
                const px = src_pixels[s_idx];
                const pr = @as(i32, @intCast((px >> 16) & 0xFF));
                const pg = @as(i32, @intCast((px >> 8) & 0xFF));
                const pb = @as(i32, @intCast(px & 0xFF));

                const lumen = @divTrunc(pr * 299 + pg * 587 + pb * 114, 1000);
                if (lumen > threshold) {
                    const dist = @abs(s_x - signed_x);
                    const falloff = 1.0 - (@as(f32, @floatFromInt(dist)) * 0.0166666);
                    const base_w = falloff * 0.1 * intensity;
                    const factor_r = base_w * (if (pr > pb) @as(f32, 1.2) else 0.5);
                    r_sum += @as(f32, @floatFromInt(pr)) * factor_r;
                    g_sum += @as(f32, @floatFromInt(pg)) * base_w * 0.8;
                    b_sum += @as(f32, @floatFromInt(pb)) * base_w * 1.5;
                }
            }

            const orig_r = @as(f32, @floatFromInt((current_px >> 16) & 0xFF));
            const orig_g = @as(f32, @floatFromInt((current_px >> 8) & 0xFF));
            const orig_b = @as(f32, @floatFromInt(current_px & 0xFF));
            const final_r = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(orig_r + r_sum))))));
            const final_g = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(orig_g + g_sum))))));
            const final_b = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(orig_b + b_sum))))));
            dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
        }
    }
}

fn applyBlock(
    comptime lanes: usize,
    src_pixels: []const u32,
    dst_pixels: []u32,
    row_start: usize,
    x_start: usize,
    y: usize,
    width: usize,
    threshold: i32,
    intensity: f32,
) void {
    var orig_r: [lanes]f32 = undefined;
    var orig_g: [lanes]f32 = undefined;
    var orig_b: [lanes]f32 = undefined;
    var add_r: [lanes]f32 = undefined;
    var add_g: [lanes]f32 = undefined;
    var add_b: [lanes]f32 = undefined;

    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
        const x = x_start + lane;
        const idx = row_start + x;
        const current_px = src_pixels[idx];
        orig_r[lane] = @as(f32, @floatFromInt((current_px >> 16) & 0xFF));
        orig_g[lane] = @as(f32, @floatFromInt((current_px >> 8) & 0xFF));
        orig_b[lane] = @as(f32, @floatFromInt(current_px & 0xFF));

        var r_sum: f32 = 0;
        var g_sum: f32 = 0;
        var b_sum: f32 = 0;

        const signed_x = @as(i32, @intCast(x));
        const min_sx = @max(0, signed_x - 60);
        const max_sx = @min(@as(i32, @intCast(width)) - 1, signed_x + 60);

        var s_x: i32 = min_sx;
        if (@rem((s_x - (signed_x - 60)), @as(i32, 4)) != 0) {
            s_x += @as(i32, 4) - @rem((s_x - (signed_x - 60)), @as(i32, 4));
        }
        while (s_x <= max_sx) : (s_x += 4) {
            const s_idx = y * width + @as(usize, @intCast(s_x));
            const px = src_pixels[s_idx];
            const pr = @as(i32, @intCast((px >> 16) & 0xFF));
            const pg = @as(i32, @intCast((px >> 8) & 0xFF));
            const pb = @as(i32, @intCast(px & 0xFF));

            const lumen = @divTrunc(pr * 299 + pg * 587 + pb * 114, 1000);
            if (lumen > threshold) {
                const dist = @abs(s_x - signed_x);
                const falloff = 1.0 - (@as(f32, @floatFromInt(dist)) * 0.0166666);
                const base_w = falloff * 0.1 * intensity;
                const factor_r = base_w * (if (pr > pb) @as(f32, 1.2) else 0.5);
                r_sum += @as(f32, @floatFromInt(pr)) * factor_r;
                g_sum += @as(f32, @floatFromInt(pg)) * base_w * 0.8;
                b_sum += @as(f32, @floatFromInt(pb)) * base_w * 1.5;
            }
        }

        add_r[lane] = r_sum;
        add_g[lane] = g_sum;
        add_b[lane] = b_sum;
    }

    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    const minv: FloatVec = @splat(0.0);
    const maxv: FloatVec = @splat(255.0);
    const r_final: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(orig_r)) + @as(FloatVec, @bitCast(add_r)))))));
    const g_final: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(orig_g)) + @as(FloatVec, @bitCast(add_g)))))));
    const b_final: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(orig_b)) + @as(FloatVec, @bitCast(add_b)))))));

    var write_lane: usize = 0;
    while (write_lane < lanes) : (write_lane += 1) {
        const idx = row_start + x_start + write_lane;
        const rr: u32 = @intCast(@max(0, @min(255, r_final[write_lane])));
        const gg: u32 = @intCast(@max(0, @min(255, g_final[write_lane])));
        const bb: u32 = @intCast(@max(0, @min(255, b_final[write_lane])));
        dst_pixels[idx] = 0xFF000000 | (rr << 16) | (gg << 8) | bb;
    }
}
