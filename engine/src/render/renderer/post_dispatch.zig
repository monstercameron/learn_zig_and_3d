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
const bloom_pass = @import("../passes/bloom_pass.zig");
const bloom_rows = @import("../passes/bloom_rows.zig");
const depth_of_field_pass = @import("../passes/depth_of_field_pass.zig");
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

// --- God Rays (v2) ---
pub fn applyGodRaysPass(renderer: *Renderer, projection: ProjectionParams, light_dir_world: math.Vec3) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    // Project the light direction onto the camera basis to get a
    // screen-space point. Use any active view basis (taa_previous_view
    // is always populated).
    const lv = math.Vec3.new(
        math.Vec3.dot(light_dir_world, renderer.taa_previous_view.basis_right),
        math.Vec3.dot(light_dir_world, renderer.taa_previous_view.basis_up),
        math.Vec3.dot(light_dir_world, renderer.taa_previous_view.basis_forward),
    );
    var lx: f32 = -1000;
    var ly: f32 = -1000;
    if (lv.z > 0.0) {
        const lp = projectCameraPositionFloat(math.Vec3.scale(lv, 1000.0), projection);
        lx = lp.x;
        ly = lp.y;
    }
    const gr_v2 = @import("../passes_v2/god_rays.zig");
    const inputs: passes_v2.Inputs = .{
        .width = renderer.bitmap.width,
        .height = renderer.bitmap.height,
        .in_color = renderer.bitmap.pixels,
        .out_color = renderer.bitmap.pixels,
    };
    _ = gr_v2.execute(inputs, .{
        .light_x = lx,
        .light_y = ly,
        .samples = @intCast(config.POST_GOD_RAYS_SAMPLES),
        .density = config.POST_GOD_RAYS_DENSITY,
        .decay = config.POST_GOD_RAYS_DECAY,
        .weight = config.POST_GOD_RAYS_WEIGHT,
        .exposure = config.POST_GOD_RAYS_EXPOSURE,
    });
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "god_rays",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
    renderer.recordRenderPassTiming("god_rays", pass_start);
}

// --- Lens Flare (v2) ---
pub fn applyLensFlarePass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const lf_v2 = @import("../passes_v2/lens_flare.zig");
    const inputs: passes_v2.Inputs = .{
        .width = renderer.bitmap.width,
        .height = renderer.bitmap.height,
        .in_color = renderer.bitmap.pixels,
        .out_color = renderer.bitmap.pixels,
    };
    _ = lf_v2.execute(inputs, .{
        .threshold = @intCast(@max(0, @min(255, config.POST_LENS_FLARE_THRESHOLD))),
        .intensity = @as(f32, @floatFromInt(config.POST_LENS_FLARE_INTENSITY_PERCENT)) / 100.0,
    });
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "lens_flare",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
    renderer.recordRenderPassTiming("lens_flare", pass_start);
}

// --- Chromatic Aberration ---
pub fn applyChromaticAberrationPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    // CA requires scratch — radial gather reads can't be in-place.
    const ca_v2 = @import("../passes_v2/chromatic_aberration.zig");
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
        .out_color = renderer.moblur_scratch_pixels,
        .gbuf = gbuf,
    };
    _ = ca_v2.execute(inputs, .{ .strength_px = config.POST_CHROMATIC_ABERRATION_STRENGTH });
    // Swap front/scratch so subsequent passes see the CA output.
    const tmp = renderer.bitmap.pixels;
    renderer.bitmap.pixels = renderer.moblur_scratch_pixels;
    renderer.moblur_scratch_pixels = tmp;
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "chromatic_aberration",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
    renderer.recordRenderPassTiming("chromatic_aberration", pass_start);
}

// --- Film Grain & Vignette ---
pub fn applyFilmGrainVignettePass(renderer: *Renderer) void {
    // Removed — replaced by stages/screen_post_stage which already
    // applies vignette + film grain on the deferred LDR buffer,
    // silhouette-masked via G-buffer depth. The post-graph dispatcher
    // still routes here so the toggle stays harmless; we just no-op.
    _ = renderer;
}

/// Applies motion blur pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyMotionBlurPass(renderer: *Renderer, current_view: TemporalAAViewState) void {
    if (renderer.bitmap.pixels.len == 0) return;
    if (!renderer.taa_scratch.valid) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    // Camera-velocity estimate from the basis-forward delta between
    // the current and previous view. Projects to a screen-space
    // (vx, vy) for the v2 motion blur kernel.
    const fwd_now = current_view.basis_forward;
    const fwd_prev = renderer.taa_previous_view.basis_forward;
    const dvx = fwd_now.x - fwd_prev.x;
    const dvy = fwd_now.y - fwd_prev.y;
    const scale: f32 = @as(f32, @floatFromInt(renderer.bitmap.width)) * config.POST_MOTION_BLUR_INTENSITY;
    const mb_v2 = @import("../passes_v2/motion_blur.zig");
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
        .out_color = renderer.moblur_scratch_pixels,
        .gbuf = gbuf,
    };
    _ = mb_v2.execute(inputs, .{
        .vx = dvx * scale,
        .vy = dvy * scale,
        .samples = @intCast(config.POST_MOTION_BLUR_SAMPLES),
        .intensity = config.POST_MOTION_BLUR_INTENSITY,
    });
    const tmp = renderer.bitmap.pixels;
    renderer.bitmap.pixels = renderer.moblur_scratch_pixels;
    renderer.moblur_scratch_pixels = tmp;
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "motion_blur",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
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

pub fn applyBlockbusterColorGradePass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const cg_v2 = @import("../passes_v2/color_grade.zig");
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
    _ = cg_v2.execute(inputs, .{
        .brightness = config.POST_COLOR_GRADE_BRIGHTNESS,
        .contrast = config.POST_COLOR_GRADE_CONTRAST,
        .saturation = config.POST_COLOR_GRADE_SATURATION,
        .gamma = config.POST_COLOR_GRADE_GAMMA,
    });
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "color_grade",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
    renderer.recordRenderPassTiming(config.POST_COLOR_PROFILE_NAME, pass_start);
}