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

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
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
                if (sx >= 0 and sx < @as(i32, @intCast(width)) and sy >= 0 and sy < @as(i32, @intCast(height))) {
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
