fn clampByte(value: i32) u8 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return @intCast(value);
}

pub fn applyRange(
    pixels: []u32,
    start_index: usize,
    end_index: usize,
    grade: anytype,
) void {
    var i = start_index;
    while (i < end_index) : (i += 1) {
        const pixel = pixels[i];
        const a: u32 = pixel & 0xFF000000;

        const r0: u8 = grade.base_curve[@intCast((pixel >> 16) & 0xFF)];
        const g0: u8 = grade.base_curve[@intCast((pixel >> 8) & 0xFF)];
        const b0: u8 = grade.base_curve[@intCast(pixel & 0xFF)];

        const luma_index: usize = @intCast((@as(u32, r0) * 77 + @as(u32, g0) * 150 + @as(u32, b0) * 29) >> 8);
        var r: i32 = @as(i32, r0) + grade.tone_add_r[luma_index];
        var g: i32 = @as(i32, g0) + grade.tone_add_g[luma_index];
        var b: i32 = @as(i32, b0) + grade.tone_add_b[luma_index];

        const mean = @divTrunc(r + g + b, 3);
        r = mean + @divTrunc((r - mean) * 110, 100);
        g = mean + @divTrunc((g - mean) * 104, 100);
        b = mean + @divTrunc((b - mean) * 96, 100);

        pixels[i] = a |
            (@as(u32, clampByte(r)) << 16) |
            (@as(u32, clampByte(g)) << 8) |
            @as(u32, clampByte(b));
    }
}
