//! # Scanline Rasterization Helpers
//!
//! This module provides low-level utility functions used in scanline-based
//! triangle rasterization algorithms. Scanline rasterization works by iterating
//! through a triangle's pixel rows (scanlines) and filling the pixels between the
//! left and right edges.
//!
//! ## JavaScript Analogy
//!
//! There isn't a direct analogy in high-level JavaScript, as this is part of the
//! native code that would implement `ctx.fillRect()` or `ctx.fill()` on a canvas.
//! These are the small, mathematical building blocks for drawing a filled shape.

/// Returns the minimum of two 32-bit integers.
/// JS Analogy: `Math.min(a, b)`
pub fn minI32(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

/// Returns the maximum of two 32-bit integers.
/// JS Analogy: `Math.max(a, b)`
pub fn maxI32(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}

/// Clamps an integer value to be within a specified range [min, max].
/// JS Analogy: `Math.max(min_value, Math.min(max_value, value))`
pub fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    return maxI32(min_value, minI32(max_value, value));
}

/// Given a line segment from (x1, y1) to (x2, y2), this function calculates the
/// x-coordinate where a horizontal line at `y` intersects that segment.
/// This is the core of a scanline rasterizer, used to find the start and end
/// points of the horizontal line to draw for each row of a triangle.
/// It uses integer-based linear interpolation.
pub fn lineIntersectionX(x1: i32, y1: i32, x2: i32, y2: i32, y: i32) i32 {
    // If the line is horizontal, the intersection is simply the line's x-coordinate.
    if (y1 == y2) return x1;

    const dy = y2 - y1;
    const dx = x2 - x1;
    const t_num = y - y1;
    
    // Using the formula for linear interpolation: x = x1 + t * (x2 - x1)
    // where t = (y - y1) / (y2 - y1). To avoid floating point math, we rearrange:
    // x = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
    return x1 + @divTrunc(t_num * dx, dy);
}