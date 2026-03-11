pub fn blendCoverage(coarse: f32, refined: f32, blend: f32) f32 {
    const t = std.math.clamp(blend, 0.0, 1.0);
    return refined * (1.0 - t) + coarse * t;
}

const std = @import("std");
