pub const WINDOW_TITLE = "Zig 3D CPU Rasterizer";

pub const TARGET_FPS: u32 = 120;
pub const CAMERA_FOV_INITIAL: f32 = 60.0;
pub const CAMERA_FOV_STEP: f32 = 1.5;
pub const CAMERA_FOV_MIN: f32 = 20.0;
pub const CAMERA_FOV_MAX: f32 = 120.0;

pub const LIGHT_DISTANCE_INITIAL: f32 = 3.0;

pub fn targetFrameTimeNs() i128 {
    const numerator: i128 = 1_000_000_000;
    return numerator / @as(i128, @intCast(TARGET_FPS));
}
