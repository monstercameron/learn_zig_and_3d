//! Shared lighting pass interface for scalar and SIMD CPU shading helpers.
//! Exposes intensity/shading entry points used by deferred and forward-style lighting paths.
//! Keeps lighting math centralized so render passes call one consistent implementation.


const core_lighting = @import("../core/lighting.zig");

pub const AMBIENT_LIGHT: f32 = core_lighting.AMBIENT_LIGHT;
pub const DEFAULT_BASE_COLOR: u32 = core_lighting.DEFAULT_BASE_COLOR;

/// Computes intensity.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn computeIntensity(brightness: f32) f32 {
    return core_lighting.computeIntensity(brightness);
}

/// Applies intensity.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn applyIntensity(color: u32, intensity: f32) u32 {
    return core_lighting.applyIntensity(color, intensity);
}

/// Shades s ha de so li d.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn shadeSolid(brightness: f32) u32 {
    return core_lighting.shadeSolid(brightness);
}
