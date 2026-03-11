pub fn vignetteFactor(x: usize, y: usize, width: usize, height: usize, vig_str: f32) f32 {
    const cx = @as(f32, @floatFromInt(width)) * 0.5;
    const cy = @as(f32, @floatFromInt(height)) * 0.5;
    const dx = (@as(f32, @floatFromInt(x)) - cx) / cx;
    const dy = (@as(f32, @floatFromInt(y)) - cy) / cy;
    const dist = @sqrt(dx * dx + dy * dy);
    return 1.0 - @max(0, @min(1.0, dist * vig_str));
}

pub fn applyToPixel(pixel: u32, factor: f32) u32 {
    var r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
    var g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
    var b = @as(f32, @floatFromInt(pixel & 0xFF));
    r *= factor;
    g *= factor;
    b *= factor;
    const rr = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(r))))));
    const gg = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(g))))));
    const bb = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(b))))));
    return 0xFF000000 | (rr << 16) | (gg << 8) | bb;
}
