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

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const dx = (@as(f32, @floatFromInt(x)) - cx) / cx;
            const dy = (@as(f32, @floatFromInt(y)) - cy) / cy;
            const dist = dx * dx + dy * dy;
            const shift = dist * strength;

            const r_x = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x)) + shift));
            const b_x = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x)) - shift));

            const safe_r_x = @max(0, @min(@as(i32, @intCast(width)) - 1, r_x));
            const safe_b_x = @max(0, @min(@as(i32, @intCast(width)) - 1, b_x));

            const px_r = src_pixels[y * width + @as(usize, @intCast(safe_r_x))];
            const px_g = src_pixels[idx];
            const px_b = src_pixels[y * width + @as(usize, @intCast(safe_b_x))];

            const final_r = (px_r >> 16) & 0xFF;
            const final_g = (px_g >> 8) & 0xFF;
            const final_b = px_b & 0xFF;

            dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
        }
    }
}
