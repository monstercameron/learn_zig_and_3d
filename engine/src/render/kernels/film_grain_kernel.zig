pub fn grainFactor(x: usize, y: usize, seed: u32, grain_str: f32) f32 {
    var hash = (@as(u32, @intCast(x)) *% 73856093) ^ (@as(u32, @intCast(y)) *% 19349663) ^ (seed *% 83492791);
    hash = (hash ^ (hash >> 16)) *% 2654435769;
    hash = hash ^ (hash >> 16);
    const noise = (@as(f32, @floatFromInt(hash & 0xFF)) / 255.0) - 0.5;
    return 1.0 + (noise * grain_str);
}

pub fn applyToPixel(pixel: u32, factor: f32) u32 {
    const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(pixel & 0xFF));
    const rr = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(r * factor))))));
    const gg = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(g * factor))))));
    const bb = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(b * factor))))));
    return 0xFF000000 | (rr << 16) | (gg << 8) | bb;
}
