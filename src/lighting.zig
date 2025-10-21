//! # Basic Lighting Module
//!
//! This module handles simple lighting calculations for the 3D scene. It implements
//! a basic "flat shading" model, where each triangle has a single, uniform color
//! based on its angle to a light source.
//!
//! ## Key Concepts
//!
//! - **Diffuse Light**: The brightness of a surface depends on the angle at which light
//!   hits it. A surface directly facing a light source is bright; a surface at a steep
//!   angle is dim. This is calculated using the dot product of the surface normal and
//!   the light direction.
//! - **Ambient Light**: A constant amount of light that is added to the entire scene.
//!   This ensures that even surfaces facing away from the light are not pure black,
//!   simulating indirect light bouncing around the environment.

const std = @import("std");

/// The minimum amount of light a surface receives, even if it's facing away from the light source.
/// A value of 0.25 means that surfaces will have at least 25% of their full brightness.
pub const AMBIENT_LIGHT: f32 = 0.25;

/// The default color of objects before lighting is applied. This is a yellowish color.
/// The format is 0xAARRGGBB (Alpha, Red, Green, Blue), but Windows bitmaps use BGRA order in memory,
/// so the hex literal is written with components in 0xRRGGBB order and then packed.
pub const DEFAULT_BASE_COLOR: u32 = 0xFFFFDC28; // 255,220,40 in BGRA packing

/// Calculates the final light intensity for a surface.
/// - `brightness`: The raw brightness from the dot product, typically from -1.0 to 1.0.
/// Returns a final intensity value, including ambient light, from `AMBIENT_LIGHT` to 1.0.
pub fn computeIntensity(brightness: f32) f32 {
    // Clamp the dot product result to be between 0.0 (facing 90 degrees away) and 1.0 (facing light directly).
    const clamped = std.math.clamp(brightness, 0.0, 1.0);

    // Combine the diffuse light with the ambient light.
    // The diffuse portion is scaled to fit in the remaining range (1.0 - AMBIENT_LIGHT).
    return AMBIENT_LIGHT + clamped * (1.0 - AMBIENT_LIGHT);
}

/// Applies a calculated light intensity to a given base color.
/// - `color`: The original 32-bit integer color of the object (in 0xAARRGGBB format).
/// - `intensity`: The light intensity to apply, from 0.0 to 1.0.
/// Returns the new 32-bit integer color after applying the lighting.
// TODO(SIMD): This function is a prime candidate for SIMD. Multiple pixels (4 or 8) could be processed at once.
// The process of unpacking a u32 to four u8/f32 components, multiplying, and repacking is a classic use case for PSHUFB, PMUL, etc.
pub fn applyIntensity(color: u32, intensity: f32) u32 {
    const clamped_intensity = std.math.clamp(intensity, AMBIENT_LIGHT, 1.0);

    // Extract the Red, Green, and Blue components from the 32-bit integer color.
    // JS Analogy: This is manual bit manipulation to do what `(color >> 16) & 0xFF` does.
    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(color & 0xFF));

    // Multiply each color component by the intensity and clamp to the valid 0-255 range.
    const r_val = std.math.clamp(r * clamped_intensity, 0.0, 255.0);
    const g_val = std.math.clamp(g * clamped_intensity, 0.0, 255.0);
    const b_val = std.math.clamp(b * clamped_intensity, 0.0, 255.0);

    // Re-pack the components into a single 32-bit integer, with full alpha (0xFF).
    return 0xFF000000 | (@as(u32, @intFromFloat(r_val)) << 16) | (@as(u32, @intFromFloat(g_val)) << 8) | @as(u32, @intFromFloat(b_val));
}

/// A convenience function to shade the `DEFAULT_BASE_COLOR` with a given brightness.
pub fn shadeSolid(brightness: f32) u32 {
    return applyIntensity(DEFAULT_BASE_COLOR, computeIntensity(brightness));
}