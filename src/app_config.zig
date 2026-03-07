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

// Enables the first post-processing stage layered over the meshlet render output.
pub const POST_COLOR_CORRECTION_ENABLED = true;
pub const POST_BLOOM_ENABLED = true;
pub const POST_DEPTH_FOG_ENABLED = true;
pub const POST_SHADOW_ENABLED = false;
pub const POST_SHADOW_MAP_SIZE: usize = 1024;
pub const POST_SHADOW_STRENGTH_PERCENT: i32 = 38;
pub const POST_SHADOW_DEPTH_BIAS: f32 = 0.07;
pub const POST_HYBRID_SHADOW_ENABLED = true;
pub const POST_HYBRID_SHADOW_MIN_BLOCK_SIZE: i32 = 24;
pub const POST_HYBRID_SHADOW_MAX_DEPTH: u32 = 1;
pub const POST_HYBRID_SHADOW_RAY_BIAS: f32 = 0.03;
pub const POST_HYBRID_SHADOW_SAMPLE_STRIDE: i32 = 12;
pub const POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE: i32 = 4;
pub const POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE: i32 = 1;
pub const POST_HYBRID_SHADOW_EDGE_MIN_COVERAGE: f32 = 0.22;
pub const POST_HYBRID_SHADOW_EDGE_MAX_COVERAGE: f32 = 0.78;
pub const POST_HYBRID_SHADOW_EDGE_BLEND: f32 = 0.4;
pub const POST_SSAO_ENABLED = true;
pub const POST_SSAO_DOWNSAMPLE: i32 = 4;
pub const POST_SSAO_RADIUS: f32 = 0.85;
pub const POST_SSAO_STRENGTH_PERCENT: i32 = 52;
pub const POST_SSAO_BIAS: f32 = 0.08;
pub const POST_SSAO_BLUR_DEPTH_THRESHOLD: f32 = 0.55;
pub const POST_TAA_ENABLED = false;
pub const POST_TAA_HISTORY_PERCENT: i32 = 92;
pub const POST_TAA_DEPTH_THRESHOLD: f32 = 0.2;
pub const POST_DEPTH_FOG_NEAR: f32 = 5.5;
pub const POST_DEPTH_FOG_FAR: f32 = 16.0;
pub const POST_DEPTH_FOG_COLOR_R: u8 = 92;
pub const POST_DEPTH_FOG_COLOR_G: u8 = 118;
pub const POST_DEPTH_FOG_COLOR_B: u8 = 142;
pub const POST_DEPTH_FOG_STRENGTH_PERCENT: i32 = 72;
pub const POST_BLOOM_THRESHOLD: i32 = 168;
pub const POST_BLOOM_INTENSITY_PERCENT: i32 = 55;

// A simple blockbuster-style teal/orange grade tuned for the current CPU renderer.
pub const POST_COLOR_PROFILE_NAME = "blockbuster_teal_orange";
pub const POST_COLOR_BRIGHTNESS_BIAS: i32 = 4;
pub const POST_COLOR_CONTRAST_PERCENT: i32 = 112;

/// Calculates the target time per frame in nanoseconds, based on the TARGET_FPS.
/// This is used for frame rate limiting.
pub fn targetFrameTimeNs() i128 {
    const numerator: i128 = 1_000_000_000; // 1 second in nanoseconds
    return numerator / @as(i128, @intCast(TARGET_FPS));
}
