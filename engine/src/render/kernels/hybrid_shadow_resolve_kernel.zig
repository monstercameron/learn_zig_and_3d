//! Implements the Hybrid Shadow Resolve kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

/// blendCoverage blends intermediate values for Hybrid Shadow Resolve Kernel.
pub fn blendCoverage(coarse: f32, refined: f32, blend: f32) f32 {
    const t = std.math.clamp(blend, 0.0, 1.0);
    return refined * (1.0 - t) + coarse * t;
}

const std = @import("std");