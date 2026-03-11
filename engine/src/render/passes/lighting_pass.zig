const core_lighting = @import("../core/lighting.zig");

pub const AMBIENT_LIGHT: f32 = core_lighting.AMBIENT_LIGHT;
pub const DEFAULT_BASE_COLOR: u32 = core_lighting.DEFAULT_BASE_COLOR;

pub fn computeIntensity(brightness: f32) f32 {
    return core_lighting.computeIntensity(brightness);
}

pub fn applyIntensity(color: u32, intensity: f32) u32 {
    return core_lighting.applyIntensity(color, intensity);
}

pub fn shadeSolid(brightness: f32) u32 {
    return core_lighting.shadeSolid(brightness);
}
