//! # Application Configuration
//!
//! This file contains global constants and configuration settings for the application.
//! It's a centralized place to tweak rendering parameters and other settings.
//!
//! ## JavaScript Analogy
//!
//! Think of this as a `config.js` or `constants.js` file where you export
//! all the magic numbers and settings for your application.
//!
//! ```javascript
//! export const WINDOW_TITLE = 'My Awesome App';
//! export const TARGET_FPS = 120;
//! export const INITIAL_FOV = 60.0;
//! ```

// The title that will appear in the window's title bar.
pub const WINDOW_TITLE = "Zig 3D CPU Rasterizer";

// The target frames per second. The renderer will try to match this rate.
pub const TARGET_FPS: u32 = 120;

// The initial vertical field of view for the camera, in degrees.
pub const CAMERA_FOV_INITIAL: f32 = 60.0;

// The amount the FOV changes with each key press, in degrees.
pub const CAMERA_FOV_STEP: f32 = 1.5;

// The minimum allowed camera field of view.
pub const CAMERA_FOV_MIN: f32 = 20.0;

// The maximum allowed camera field of view.
pub const CAMERA_FOV_MAX: f32 = 120.0;

// The initial distance of the dynamic light source from the origin.
pub const LIGHT_DISTANCE_INITIAL: f32 = 3.0;

/// Calculates the target time per frame in nanoseconds, based on the TARGET_FPS.
/// This is used for frame rate limiting.
pub fn targetFrameTimeNs() i128 {
    const numerator: i128 = 1_000_000_000; // 1 second in nanoseconds
    return numerator / @as(i128, @intCast(TARGET_FPS));
}
