const std = @import("std");
const profiler = @import("../../core/profiler.zig");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const Renderer = renderer_module.Renderer;
const ProjectionParams = renderer_module.ProjectionParams;
const TemporalAAViewState = renderer_module.TemporalAAViewState;
const Mesh = renderer_module.Mesh;

const skybox_pass = @import("../passes/skybox_pass.zig");
const ssgi_pass = @import("../passes/ssgi_pass.zig");
const ssao_pass = @import("../passes/ssao_pass.zig");
const ssao_rows = @import("../passes/ssao_rows.zig");
const depth_fog_v2 = @import("../passes_v2/depth_fog.zig");
const passes_v2 = @import("../passes_v2/mod.zig");
const iq_scan_runtime = @import("../iq_scan_runtime.zig");
const taa_pass = @import("../passes/taa_pass.zig");
const taa_helpers = @import("../passes/taa_helpers.zig");
const motion_blur_pass = @import("../passes/motion_blur_pass.zig");
const god_rays_pass = @import("../passes/god_rays_pass.zig");
const lens_flare_pass = @import("../passes/lens_flare_pass.zig");
const bloom_pass = @import("../passes/bloom_pass.zig");
const bloom_rows = @import("../passes/bloom_rows.zig");
const depth_of_field_pass = @import("../passes/depth_of_field_pass.zig");
const chromatic_aberration_pass = @import("../passes/chromatic_aberration_pass.zig");
const film_grain_vignette_pass = @import("../passes/film_grain_vignette_pass.zig");
const color_grade_pass = @import("../passes/color_grade_pass.zig");
const ssr_pass = @import("../passes/ssr_pass.zig");

const noopRenderPassJob = renderer_module.noopRenderPassJob;
const projectCameraPositionFloat = renderer_module.projectCameraPositionFloat;
const tryApplyTemporalAAMeshletBatch = renderer_module.tryApplyTemporalAAMeshletBatch;
const renderAmbientOcclusionRows = renderer_module.renderAmbientOcclusionRows;
const validSceneCameraSample = renderer_module.validSceneCameraSample;
const blurAmbientOcclusionHorizontalRows = renderer_module.blurAmbientOcclusionHorizontalRows;
const blurAmbientOcclusionVerticalRows = renderer_module.blurAmbientOcclusionVerticalRows;
const cameraToWorldPosition = renderer_module.cameraToWorldPosition;
const compositeAmbientOcclusionRows = renderer_module.compositeAmbientOcclusionRows;
const NEAR_EPSILON = renderer_module.NEAR_EPSILON;

/// Applies ssgi pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applySSGIPass(renderer: *Renderer) void {
    const pass_start = std.time.nanoTimestamp();
    const height: usize = @intCast(renderer.bitmap.height);
    ssgi_pass.runPipeline(renderer, height, noopRenderPassJob);
    renderer.recordRenderPassTiming("ssgi", pass_start);
}
/// Applies ambient occlusion pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyAmbientOcclusionPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_camera.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const scene_width: usize = @intCast(renderer.bitmap.width);
    const scene_height: usize = @intCast(renderer.bitmap.height);
    ssao_pass.runPipeline(
        renderer,
        scene_width,
        scene_height,
        noopRenderPassJob,
        renderAmbientOcclusionRows,
        blurAmbientOcclusionHorizontalRows,
        blurAmbientOcclusionVerticalRows,
        compositeAmbientOcclusionRows,
    );
    renderer.recordRenderPassTiming("ssao", pass_start);
}

/// Applies depth fog pass via the modern passes_v2 implementation.
/// In-place safe; reads silhouette mask from the G-buffer depth so
/// background pixels are never modified.
pub fn applyDepthFogPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const gbuf: passes_v2.GBufferView = .{
        .width = renderer.bitmap.width,
        .height = renderer.bitmap.height,
        .depth = renderer.scene_depth,
        .normal = @ptrCast(renderer.scene_normal),
        .base_color = renderer.scene_base_color,
        .material = renderer.scene_material,
    };
    const inputs: passes_v2.Inputs = .{
        .width = renderer.bitmap.width,
        .height = renderer.bitmap.height,
        .in_color = renderer.bitmap.pixels,
        .out_color = renderer.bitmap.pixels,
        .gbuf = gbuf,
    };
    _ = depth_fog_v2.execute(inputs, .{
        .near = config.POST_DEPTH_FOG_NEAR,
        .far = config.POST_DEPTH_FOG_FAR,
        .strength = @as(f32, @floatFromInt(config.POST_DEPTH_FOG_STRENGTH_PERCENT)) / 100.0,
        .color = .{ config.POST_DEPTH_FOG_COLOR_R, config.POST_DEPTH_FOG_COLOR_G, config.POST_DEPTH_FOG_COLOR_B },
    });
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "depth_fog",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
    renderer.recordRenderPassTiming("depth_fog", pass_start);
}

/// Applies temporal aa rows.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyTemporalAARows(
    renderer: *Renderer,
    mesh: *const Mesh,
    current_view: TemporalAAViewState,
    previous_view: TemporalAAViewState,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
) void {
    taa_pass.runRows(
        renderer,
        mesh,
        current_view,
        previous_view,
        start_row,
        end_row,
        width,
        height,
        tryApplyTemporalAAMeshletBatch,
        validSceneCameraSample,
        cameraToWorldPosition,
        projectCameraPositionFloat,
        NEAR_EPSILON,
    );
}

pub const GodRaysJobContext = struct {
    renderer: *Renderer,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    light_screen_pos: math.Vec2,

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *GodRaysJobContext = @ptrCast(@alignCast(ctx_ptr));
        god_rays_pass.runRows(
            ctx.renderer.bitmap.pixels,
            ctx.renderer.god_rays_scratch_pixels,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            ctx.height,
            ctx.light_screen_pos.x,
            ctx.light_screen_pos.y,
            config.POST_GOD_RAYS_SAMPLES,
            config.POST_GOD_RAYS_DECAY,
            config.POST_GOD_RAYS_DENSITY,
            config.POST_GOD_RAYS_WEIGHT,
            config.POST_GOD_RAYS_EXPOSURE,
        );
    }
};

pub const ChromaticAberrationJobContext = struct {
    renderer: *Renderer,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *ChromaticAberrationJobContext = @ptrCast(@alignCast(ctx_ptr));
        chromatic_aberration_pass.runRows(
            ctx.renderer.bitmap.pixels,
            ctx.renderer.moblur_scratch_pixels,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            ctx.height,
            config.POST_CHROMATIC_ABERRATION_STRENGTH,
        );
    }
};

pub const FilmGrainVignetteJobContext = struct {
    renderer: *Renderer,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *FilmGrainVignetteJobContext = @ptrCast(@alignCast(ctx_ptr));
        film_grain_vignette_pass.runRows(
            ctx.renderer.bitmap.pixels,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            ctx.height,
            config.POST_FILM_GRAIN_STRENGTH,
            config.POST_VIGNETTE_STRENGTH,
            @as(u32, @intCast(ctx.renderer.total_frames_rendered % 1000)),
        );
    }
};

pub const LensFlareJobContext = struct {
    renderer: *Renderer,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *LensFlareJobContext = @ptrCast(@alignCast(ctx_ptr));
        _ = ctx.height;
        lens_flare_pass.runRows(
            ctx.renderer.bitmap.pixels,
            ctx.renderer.lens_flare_scratch_pixels,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            config.POST_LENS_FLARE_THRESHOLD,
            @as(f32, @floatFromInt(config.POST_LENS_FLARE_INTENSITY_PERCENT)) / 100.0,
        );
    }
};

pub const MotionBlurJobContext = struct {
    renderer: *Renderer,
    current_view: TemporalAAViewState,
    previous_view: TemporalAAViewState,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *MotionBlurJobContext = @ptrCast(@alignCast(ctx_ptr));
        motion_blur_pass.runRows(
            ctx.renderer.bitmap.pixels,
            ctx.renderer.moblur_scratch_pixels,
            ctx.renderer.scene_camera,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            ctx.height,
            ctx.current_view,
            ctx.previous_view,
        );
    }
};

// --- God Rays ---
pub fn applyGodRaysPass(renderer: *Renderer, projection: ProjectionParams, light_dir_world: math.Vec3) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);

    // actually we can just project the light_dir_world as a point relative to camera since it's directional.
    // Actually, we already have renderer.scene_camera setup, so we know our view.
    // But for god rays we usually just want a screen coordinate where the light is. Let's simplify.
    const light_pos_view = math.Vec3.new(math.Vec3.dot(light_dir_world, renderer.taa_previous_view.basis_right), // just using any active view basis
        math.Vec3.dot(light_dir_world, renderer.taa_previous_view.basis_up), math.Vec3.dot(light_dir_world, renderer.taa_previous_view.basis_forward));

    var light_screen_pos = math.Vec2.new(-1000, -1000);
    if (light_pos_view.z > 0.0) {
        // Light is in front
        const light_proj = projectCameraPositionFloat(math.Vec3.scale(light_pos_view, 1000.0), projection);
        light_screen_pos = math.Vec2.new(light_proj.x, light_proj.y);
    }
    god_rays_pass.runPipeline(
        renderer,
        width,
        height,
        light_screen_pos.x,
        light_screen_pos.y,
        config.POST_GOD_RAYS_SAMPLES,
        config.POST_GOD_RAYS_DECAY,
        config.POST_GOD_RAYS_DENSITY,
        config.POST_GOD_RAYS_WEIGHT,
        config.POST_GOD_RAYS_EXPOSURE,
        noopRenderPassJob,
    );
    renderer.recordRenderPassTiming("god_rays", pass_start);
}

// --- Lens Flare ---
pub fn applyLensFlarePass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);
    lens_flare_pass.runPipeline(
        renderer,
        width,
        height,
        config.POST_LENS_FLARE_THRESHOLD,
        @as(f32, @floatFromInt(config.POST_LENS_FLARE_INTENSITY_PERCENT)) / 100.0,
        noopRenderPassJob,
    );
    renderer.recordRenderPassTiming("lens_flare", pass_start);
}

// --- Chromatic Aberration ---
pub fn applyChromaticAberrationPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);
    chromatic_aberration_pass.runPipeline(
        renderer,
        width,
        height,
        config.POST_CHROMATIC_ABERRATION_STRENGTH,
        noopRenderPassJob,
    );
    renderer.recordRenderPassTiming("chromatic_aberration", pass_start);
}

// --- Film Grain & Vignette ---
pub fn applyFilmGrainVignettePass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);
    film_grain_vignette_pass.runPipeline(
        renderer,
        width,
        height,
        config.POST_FILM_GRAIN_STRENGTH,
        config.POST_VIGNETTE_STRENGTH,
        @as(u32, @intCast(renderer.total_frames_rendered % 1000)),
        noopRenderPassJob,
    );
    renderer.recordRenderPassTiming("film_grain_vignette", pass_start);
}

/// Applies motion blur pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyMotionBlurPass(renderer: *Renderer, current_view: TemporalAAViewState) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_camera.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);

    // If TAA isn't populated, we can't reliably do motion blur
    if (!renderer.taa_scratch.valid) return;

    motion_blur_pass.runPipeline(renderer, current_view, height, width, noopRenderPassJob);
    renderer.recordRenderPassTiming("motion_blur", pass_start);
}

/// Applies temporal aa pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyTemporalAAPass(renderer: *Renderer, mesh: *const Mesh, current_view: TemporalAAViewState) void {
    const _zone = profiler.zone("applyTemporalAAPass");
    defer if (_zone) |z| z.end();
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_camera.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);
    taa_pass.runPipeline(
        renderer,
        mesh,
        current_view,
        width,
        height,
        noopRenderPassJob,
        taa_helpers.surfaceTagForHandle,
        taa_helpers.packHistoryNormal,
    );
    renderer.recordRenderPassTiming("taa", pass_start);
}

/// Applies ssr pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applySSRPass(renderer: *Renderer, projection: ProjectionParams) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();

    const scene_height: usize = @intCast(renderer.bitmap.height);
    ssr_pass.runPipeline(renderer, projection, scene_height, noopRenderPassJob);
    renderer.recordRenderPassTiming("ssr", pass_start);
}

/// Applies depth of field pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyDepthOfFieldPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();

    const scene_width: usize = @intCast(renderer.bitmap.width);
    const scene_height: usize = @intCast(renderer.bitmap.height);
    depth_of_field_pass.runPipeline(renderer, scene_width, scene_height, noopRenderPassJob);

    renderer.recordRenderPassTiming("dof", pass_start);
}

/// Applies bloom pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyBloomPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const scene_width: usize = @intCast(renderer.bitmap.width);
    const scene_height: usize = @intCast(renderer.bitmap.height);
    bloom_pass.runPipeline(
        renderer,
        scene_width,
        scene_height,
        config.POST_BLOOM_THRESHOLD,
        config.POST_BLOOM_INTENSITY_PERCENT,
        noopRenderPassJob,
        bloom_rows.extractDownsampleRows,
        bloom_rows.blurHorizontalRows,
        bloom_rows.blurVerticalRows,
        bloom_rows.compositeRows,
    );
    renderer.recordRenderPassTiming("bloom", pass_start);
}

/// Applies blockbuster color grade pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyBlockbusterColorGradePass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);
    color_grade_pass.runPipeline(renderer, width, height, noopRenderPassJob);

    renderer.recordRenderPassTiming(config.POST_COLOR_PROFILE_NAME, pass_start);
}