const std = @import("std");

// --- Window & Display Settings ---
/// The text displayed in the title bar of the application window.
pub var WINDOW_TITLE: []const u8 = "Zig 3D CPU Rasterizer";
/// The horizontal resolution of the application window (in pixels).
pub var WINDOW_WIDTH: u32 = 640;
/// The vertical resolution of the application window (in pixels).
pub var WINDOW_HEIGHT: u32 = 360;
/// Whether the application starts in fullscreen mode.
pub var WINDOW_FULLSCREEN: bool = false;
/// Synchronize frame presentation with monitor refresh rate to prevent screen tearing.
pub var WINDOW_VSYNC: bool = true;

// --- Rendering & Camera Settings ---
/// The percentage scale of the window resolution to use for the internal rendering backbuffer (e.g., 50 for 50% width/height). Maintains aspect ratio.
pub var RENDER_RESOLUTION_SCALE_PERCENT: u32 = 50;
/// The desired maximum frame rate. Used to calculate targetFrameTimeNs.
pub var TARGET_FPS: u32 = 120;
/// The initial Field of View (FOV) for the camera in degrees.
pub var CAMERA_FOV_INITIAL: f32 = 60.0;
/// How much the FOV changes per zoom control step.
pub var CAMERA_FOV_STEP: f32 = 1.5;
/// The minimum allowed FOV in degrees (highest zoom level).
pub var CAMERA_FOV_MIN: f32 = 20.0;
/// The maximum allowed FOV in degrees (lowest zoom level/widest angle).
pub var CAMERA_FOV_MAX: f32 = 120.0;
/// The initial distance of the light source from the camera/center.
pub var LIGHT_DISTANCE_INITIAL: f32 = 3.0;

// --- Debug & Development Information ---
/// Renders a visible border around rasterization screen tiles to help debug tile logic.
pub var DEBUG_SHOW_TILE_BORDERS: bool = false;
/// Forces all rendered geometry to draw as wireframes instead of solid surfaces.
pub var DEBUG_SHOW_WIREFRAME: bool = false;

// --- Texture Rendering Parameters ---
/// Enables bilinear interpolation for texture sampling to smooth out pixelated textures.
pub var TEXTURE_FILTERING_BILINEAR: bool = true;

// --- Post-Processing Render Pipeline ---
/// Enables a color grading pass on the final image.
pub var POST_COLOR_CORRECTION_ENABLED: bool = true;
/// Enables the bloom effect for overly bright pixels simulating glowing lights.
pub var POST_BLOOM_ENABLED: bool = false;
/// Enables depth-aware atmospheric fog to simulate distance.
pub var POST_DEPTH_FOG_ENABLED: bool = false;
/// Enables HDR skybox rendering
pub var POST_SKYBOX_ENABLED: bool = true;
/// Enables the primary generic shadow mapping pass.
pub var POST_SHADOW_ENABLED: bool = false;
/// Square dimension resolution of the shadow depth map target.
pub var POST_SHADOW_MAP_SIZE: usize = 1024;
/// Controls the opacity intensity of standard shadows (0-100).
pub var POST_SHADOW_STRENGTH_PERCENT: i32 = 38;
/// A depth offset to prevent shadow acne artifacts on lit surfaces.
pub var POST_SHADOW_DEPTH_BIAS: f32 = 0.07;
/// Enables the advanced hybrid ray-traced shadow pass for high fidelity shadows.
pub var POST_HYBRID_SHADOW_ENABLED: bool = false;
/// Tile dimension constraint used during hybrid shadow evaluation.
pub var POST_HYBRID_SHADOW_MIN_BLOCK_SIZE: i32 = 24;
/// The maximum recursion or ray bounce depth for hybrid shadows.
pub var POST_HYBRID_SHADOW_MAX_DEPTH: u32 = 1;
/// The collision bias for intercepting geometry during shadow raycasts.
pub var POST_HYBRID_SHADOW_RAY_BIAS: f32 = 0.03;
/// Distance per step during bounding volume traversal.
pub var POST_HYBRID_SHADOW_SAMPLE_STRIDE: i32 = 12;
/// Downsampling factor for coarse early-z shadow cull testing.
pub var POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE: i32 = 4;
/// Downsampling factor specifically for resolving shadow edges.
pub var POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE: i32 = 1;
/// The minimum coverage fraction required to trigger an edge resolution check.
pub var POST_HYBRID_SHADOW_EDGE_MIN_COVERAGE: f32 = 0.22;
/// The maximum coverage fraction permitted before clamping shadow bounds.
pub var POST_HYBRID_SHADOW_EDGE_MAX_COVERAGE: f32 = 0.78;
/// The interpolation blend mapping for hybrid shadow penumbras.
pub var POST_HYBRID_SHADOW_EDGE_BLEND: f32 = 0.4;
/// Enables Screen Space Ambient Occlusion for realistic corner shading.
/// Screen Space Reflections (SSR)

pub var POST_SSGI_ENABLED: bool = false;
pub var POST_SSGI_SAMPLES: i32 = 16;
pub var POST_SSGI_RADIUS: i32 = 12; // Pixel radius
pub var POST_SSGI_INTENSITY: f32 = 1.2;
pub var POST_SSGI_BOUNCE_ATTENUATION: f32 = 0.5;
pub var POST_SSR_ENABLED: bool = false;
pub var POST_SSR_MAX_SAMPLES: i32 = 16;
pub var POST_SSR_STEP: f32 = 0.1;
pub var POST_SSR_MAX_DISTANCE: f32 = 100.0;
pub var POST_SSR_THICKNESS: f32 = 0.5;
pub var POST_SSR_INTENSITY: f32 = 0.8;

pub var POST_SSAO_ENABLED: bool = false;
/// SSAO rendering resolution divisor (higher = lower res & faster).
pub var POST_SSAO_DOWNSAMPLE: i32 = 4;
/// The sampling spread radius in screen space for SSAO.
pub var POST_SSAO_RADIUS: f32 = 0.85;
/// Intensity magnitude for the ambient occlusion effect (0-100).
pub var POST_SSAO_STRENGTH_PERCENT: i32 = 52;
/// Depth bias used in SSAO samples to prevent self-occlusion artifacts.
pub var POST_SSAO_BIAS: f32 = 0.08;
/// Blurring threshold difference between sampling depths.
pub var POST_SSAO_BLUR_DEPTH_THRESHOLD: f32 = 0.55;
/// Enables Temporal Anti-Aliasing (TAA) to smooth out jagged edges across frames.
pub var POST_TAA_ENABLED: bool = false;
/// Percentage mix of historic frame data blended into current image.
pub var POST_TAA_HISTORY_PERCENT: i32 = 92;
/// A depth threshold allowing TAA to discard historic data to prevent ghosting.
pub var POST_TAA_DEPTH_THRESHOLD: f32 = 2.0;
/// The near viewing plane at which fog starts appearing.
pub var POST_DEPTH_FOG_NEAR: f32 = 5.5;
/// The distant viewing place at which fog fully obscures vision.
pub var POST_DEPTH_FOG_FAR: f32 = 16.0;
/// The Red color channel value of the atmospheric fog (0-255).
pub var POST_DEPTH_FOG_COLOR_R: u8 = 92;
/// The Green color channel value of the atmospheric fog (0-255).
pub var POST_DEPTH_FOG_COLOR_G: u8 = 118;
/// The Blue color channel value of the atmospheric fog (0-255).
pub var POST_DEPTH_FOG_COLOR_B: u8 = 142;
/// Maximum visual opacity of the atmospheric fog effect.
pub var POST_DEPTH_FOG_STRENGTH_PERCENT: i32 = 72;
/// Luma brightness threshold to isolate bright spots for the bloom effect.
pub var POST_BLOOM_THRESHOLD: i32 = 168;
/// Multiplying intensifier for the resulting bloom blur overlay.
pub var POST_BLOOM_INTENSITY_PERCENT: i32 = 55;

/// Enables Depth of Field (DoF) to blur background and foreground objects outside the focal range.
pub var POST_DOF_ENABLED: bool = false;
/// The distance from the camera that is perfectly in focus.
pub var POST_DOF_FOCAL_DISTANCE: f32 = 4.0;
/// The depth range around the focal distance that remains in focus.
pub var POST_DOF_FOCAL_RANGE: f32 = 2.0;
/// The maximum scatter/blur radius for out-of-focus pixels.
pub var POST_DOF_BLUR_RADIUS: i32 = 1;

/// Enables Motion Blur based on pixel velocity from previous frames.
pub var POST_MOTION_BLUR_ENABLED: bool = false;
/// The number of samples gathered along the velocity vector for motion blur.
pub var POST_MOTION_BLUR_SAMPLES: i32 = 6;
/// The intensity multiplier for motion blur trail length. (0.5 simulates a cinematic 180-degree shutter)
pub var POST_MOTION_BLUR_INTENSITY: f32 = 0.5;


// --- Cinematic Effects ---
pub var POST_LENS_FLARE_ENABLED: bool = false;
pub var POST_LENS_FLARE_THRESHOLD: i32 = 200;
pub var POST_LENS_FLARE_INTENSITY_PERCENT: i32 = 40;

pub var POST_CHROMATIC_ABERRATION_ENABLED: bool = false;
pub var POST_CHROMATIC_ABERRATION_STRENGTH: f32 = 1.0; 

pub var POST_FILM_GRAIN_VIGNETTE_ENABLED: bool = false;
pub var POST_FILM_GRAIN_STRENGTH: f32 = 0.10;
pub var POST_VIGNETTE_STRENGTH: f32 = 0.10;

pub var POST_GOD_RAYS_ENABLED: bool = false;
pub var POST_GOD_RAYS_SAMPLES: i32 = 16;
pub var POST_GOD_RAYS_DENSITY: f32 = 1.0;
pub var POST_GOD_RAYS_WEIGHT: f32 = 0.02;
pub var POST_GOD_RAYS_DECAY: f32 = 0.90;
pub var POST_GOD_RAYS_EXPOSURE: f32 = 0.8;

// --- Global Color Profile ---
/// The name of the LUT or graded preset mapped onto the final output color.
pub var POST_COLOR_PROFILE_NAME: []const u8 = "blockbuster_teal_orange";
/// Overall brightness adjustment scalar added directly to final colors.
pub var POST_COLOR_BRIGHTNESS_BIAS: i32 = 4;
/// Percentile adjustment of color contrast stretching values relative to midpoint.
pub var POST_COLOR_CONTRAST_PERCENT: i32 = 112;

pub fn targetFrameTimeNs() i128 {
    const numerator: i128 = 1_000_000_000;
    return @divTrunc(numerator, @as(i128, @intCast(TARGET_FPS)));
}

const ConfigFile = struct {
    window: struct {
        title: ?[]const u8 = null,
        width: ?u32 = null,
        height: ?u32 = null,
        fullscreen: ?bool = null,
        vsync: ?bool = null,
    } = .{},
    rendering: struct {
        renderResolutionScalePercent: ?u32 = null,
        fpsLimit: ?u32 = null,
        textureFilteringBilinear: ?bool = null,
    } = .{},
    camera: struct {
        initialFovDegrees: ?f32 = null,
        fovStep: ?f32 = null,
        minFov: ?f32 = null,
        maxFov: ?f32 = null,
    } = .{},
    debug: struct {
        showTileBorders: ?bool = null,
        showWireframe: ?bool = null,
    } = .{},
    postProcessing: struct {
        colorCorrectionEnabled: ?bool = null,
        bloomEnabled: ?bool = null,
        depthFogEnabled: ?bool = null,
        shadowEnabled: ?bool = null,
        shadowMapSize: ?usize = null,
        shadowStrengthPercent: ?i32 = null,
        shadowDepthBias: ?f32 = null,
        hybridShadowEnabled: ?bool = null,
        hybridShadowMinBlockSize: ?i32 = null,
        hybridShadowMaxDepth: ?u32 = null,
        hybridShadowRayBias: ?f32 = null,
        hybridShadowSampleStride: ?i32 = null,
        hybridShadowCoarseDownsample: ?i32 = null,
        hybridShadowEdgeDownsample: ?i32 = null,
        hybridShadowEdgeMinCoverage: ?f32 = null,
        hybridShadowEdgeMaxCoverage: ?f32 = null,
        hybridShadowEdgeBlend: ?f32 = null,
        ssaoEnabled: ?bool = null,
        ssaoDownsample: ?i32 = null,
        ssaoRadius: ?f32 = null,
        ssaoStrengthPercent: ?i32 = null,
        ssaoBias: ?f32 = null,
        ssaoBlurDepthThreshold: ?f32 = null,
        taaEnabled: ?bool = null,
        taaHistoryPercent: ?i32 = null,
        taaDepthThreshold: ?f32 = null,
        depthFogNear: ?f32 = null,
        depthFogFar: ?f32 = null,
        depthFogColorR: ?u8 = null,
        depthFogColorG: ?u8 = null,
        depthFogColorB: ?u8 = null,
        depthFogStrengthPercent: ?i32 = null,
        bloomThreshold: ?i32 = null,
        bloomIntensityPercent: ?i32 = null,
        colorProfileName: ?[]const u8 = null,
        colorBrightnessBias: ?i32 = null,
        colorContrastPercent: ?i32 = null,
    } = .{},
};

// Global arena just for the config so parsed strings stay alive
var config_arena: ?std.heap.ArenaAllocator = null;

pub fn load(allocator: std.mem.Allocator, filepath: []const u8) !void {
    if (config_arena == null) {
        config_arena = std.heap.ArenaAllocator.init(allocator);
    }
    const arena = config_arena.?.allocator();

    const file_contents = std.fs.cwd().readFileAlloc(arena, filepath, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read config {s}: {any}, using defaults\n", .{ filepath, err });
        return;
    };

    const parsed = std.json.parseFromSlice(ConfigFile, arena, file_contents, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse config json {s}: {any}\n", .{ filepath, err });
        return;
    };

    const c = parsed.value;

    if (c.window.title) |v| WINDOW_TITLE = v;
    if (c.window.width) |v| WINDOW_WIDTH = v;
    if (c.window.height) |v| WINDOW_HEIGHT = v;
    if (c.window.fullscreen) |v| WINDOW_FULLSCREEN = v;
    if (c.window.vsync) |v| WINDOW_VSYNC = v;

    if (c.rendering.renderResolutionScalePercent) |v| RENDER_RESOLUTION_SCALE_PERCENT = v;
    if (c.rendering.fpsLimit) |v| TARGET_FPS = v;
    if (c.rendering.textureFilteringBilinear) |v| TEXTURE_FILTERING_BILINEAR = v;

    if (c.camera.initialFovDegrees) |v| CAMERA_FOV_INITIAL = v;
    if (c.camera.fovStep) |v| CAMERA_FOV_STEP = v;
    if (c.camera.minFov) |v| CAMERA_FOV_MIN = v;
    if (c.camera.maxFov) |v| CAMERA_FOV_MAX = v;

    if (c.debug.showTileBorders) |v| DEBUG_SHOW_TILE_BORDERS = v;
    if (c.debug.showWireframe) |v| DEBUG_SHOW_WIREFRAME = v;

    if (c.postProcessing.colorCorrectionEnabled) |v| POST_COLOR_CORRECTION_ENABLED = v;
    if (c.postProcessing.bloomEnabled) |v| POST_BLOOM_ENABLED = v;
    if (c.postProcessing.depthFogEnabled) |v| POST_DEPTH_FOG_ENABLED = v;
    if (c.postProcessing.shadowEnabled) |v| POST_SHADOW_ENABLED = v;
    if (c.postProcessing.shadowMapSize) |v| POST_SHADOW_MAP_SIZE = v;
    if (c.postProcessing.shadowStrengthPercent) |v| POST_SHADOW_STRENGTH_PERCENT = v;
    if (c.postProcessing.shadowDepthBias) |v| POST_SHADOW_DEPTH_BIAS = v;

    if (c.postProcessing.hybridShadowEnabled) |v| POST_HYBRID_SHADOW_ENABLED = v;
    if (c.postProcessing.hybridShadowMinBlockSize) |v| POST_HYBRID_SHADOW_MIN_BLOCK_SIZE = v;
    if (c.postProcessing.hybridShadowMaxDepth) |v| POST_HYBRID_SHADOW_MAX_DEPTH = v;
    if (c.postProcessing.hybridShadowRayBias) |v| POST_HYBRID_SHADOW_RAY_BIAS = v;
    if (c.postProcessing.hybridShadowSampleStride) |v| POST_HYBRID_SHADOW_SAMPLE_STRIDE = v;
    if (c.postProcessing.hybridShadowCoarseDownsample) |v| POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE = v;
    if (c.postProcessing.hybridShadowEdgeDownsample) |v| POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE = v;
    if (c.postProcessing.hybridShadowEdgeMinCoverage) |v| POST_HYBRID_SHADOW_EDGE_MIN_COVERAGE = v;
    if (c.postProcessing.hybridShadowEdgeMaxCoverage) |v| POST_HYBRID_SHADOW_EDGE_MAX_COVERAGE = v;
    if (c.postProcessing.hybridShadowEdgeBlend) |v| POST_HYBRID_SHADOW_EDGE_BLEND = v;

    if (c.postProcessing.ssaoEnabled) |v| POST_SSAO_ENABLED = v;
    if (c.postProcessing.ssaoDownsample) |v| POST_SSAO_DOWNSAMPLE = v;
    if (c.postProcessing.ssaoRadius) |v| POST_SSAO_RADIUS = v;
    if (c.postProcessing.ssaoStrengthPercent) |v| POST_SSAO_STRENGTH_PERCENT = v;
    if (c.postProcessing.ssaoBias) |v| POST_SSAO_BIAS = v;
    if (c.postProcessing.ssaoBlurDepthThreshold) |v| POST_SSAO_BLUR_DEPTH_THRESHOLD = v;

    if (c.postProcessing.taaEnabled) |v| POST_TAA_ENABLED = v;
    if (c.postProcessing.taaHistoryPercent) |v| POST_TAA_HISTORY_PERCENT = v;
    if (c.postProcessing.taaDepthThreshold) |v| POST_TAA_DEPTH_THRESHOLD = v;

    if (c.postProcessing.depthFogNear) |v| POST_DEPTH_FOG_NEAR = v;
    if (c.postProcessing.depthFogFar) |v| POST_DEPTH_FOG_FAR = v;
    if (c.postProcessing.depthFogColorR) |v| POST_DEPTH_FOG_COLOR_R = v;
    if (c.postProcessing.depthFogColorG) |v| POST_DEPTH_FOG_COLOR_G = v;
    if (c.postProcessing.depthFogColorB) |v| POST_DEPTH_FOG_COLOR_B = v;
    if (c.postProcessing.depthFogStrengthPercent) |v| POST_DEPTH_FOG_STRENGTH_PERCENT = v;

    if (c.postProcessing.bloomThreshold) |v| POST_BLOOM_THRESHOLD = v;
    if (c.postProcessing.bloomIntensityPercent) |v| POST_BLOOM_INTENSITY_PERCENT = v;

    if (c.postProcessing.colorProfileName) |v| POST_COLOR_PROFILE_NAME = v;
    if (c.postProcessing.colorBrightnessBias) |v| POST_COLOR_BRIGHTNESS_BIAS = v;
    if (c.postProcessing.colorContrastPercent) |v| POST_COLOR_CONTRAST_PERCENT = v;
}
pub fn deinit() void {
    if (config_arena) |*arena| {
        arena.deinit();
        config_arena = null;
    }
}
