const std = @import("std");
const profiler = @import("../../core/profiler.zig");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const Renderer = renderer_module.Renderer;
const ProjectionParams = renderer_module.ProjectionParams;
const TemporalAAViewState = renderer_module.TemporalAAViewState;
const Mesh = renderer_module.Mesh;

const depth_fog_v2 = @import("../passes_v2/depth_fog.zig");
const passes_v2 = @import("../passes_v2/mod.zig");
const iq_scan_runtime = @import("../iq_scan_runtime.zig");

const noopRenderPassJob = renderer_module.noopRenderPassJob;
const projectCameraPositionFloat = renderer_module.projectCameraPositionFloat;
const tryApplyTemporalAAMeshletBatch = renderer_module.tryApplyTemporalAAMeshletBatch;
const validSceneCameraSample = renderer_module.validSceneCameraSample;
const cameraToWorldPosition = renderer_module.cameraToWorldPosition;
const NEAR_EPSILON = renderer_module.NEAR_EPSILON;

/// Applies ssgi pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applySSGIPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const ssgi_v2 = @import("../passes_v2/ssgi.zig");
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
    _ = ssgi_v2.execute(inputs, .{ .intensity = config.POST_SSGI_INTENSITY });
    const tmp = renderer.bitmap.pixels;
    renderer.bitmap.pixels = renderer.moblur_scratch_pixels;
    renderer.moblur_scratch_pixels = tmp;
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass("ssgi", renderer.bitmap.width, renderer.bitmap.height, before, renderer.bitmap.pixels, renderer.scene_depth);
    }
    renderer.recordRenderPassTiming("ssgi", pass_start);
}
/// Applies ambient occlusion pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyAmbientOcclusionPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const ssao_v2 = @import("../passes_v2/ssao.zig");
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
    _ = ssao_v2.execute(inputs, .{
        .radius_px = 4,
        .strength = @as(f32, @floatFromInt(config.POST_SSAO_STRENGTH_PERCENT)) / 100.0,
    });
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "ssao",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
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
    _ = mesh;
    _ = current_view;
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const taa_v2 = @import("../passes_v2/taa.zig");
    if (renderer.taa_scratch.history_pixels.len != renderer.bitmap.pixels.len) return;
    const inputs: passes_v2.Inputs = .{
        .width = renderer.bitmap.width,
        .height = renderer.bitmap.height,
        .in_color = renderer.bitmap.pixels,
        .out_color = renderer.bitmap.pixels,
    };
    _ = taa_v2.execute(inputs, renderer.taa_scratch.history_pixels, .{
        .history_weight = @as(f32, @floatFromInt(config.POST_TAA_HISTORY_PERCENT)) / 100.0,
        .history_valid = renderer.taa_scratch.valid,
    });
    // Write current pixels to history for the next frame.
    if (renderer.taa_scratch.history_pixels.len == renderer.bitmap.pixels.len) {
        @memcpy(renderer.taa_scratch.history_pixels, renderer.bitmap.pixels);
        renderer.taa_scratch.valid = true;
    }
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass("taa", renderer.bitmap.width, renderer.bitmap.height, before, renderer.bitmap.pixels, renderer.scene_depth);
    }
    renderer.recordRenderPassTiming("taa", pass_start);
}

pub fn applySSRPass(renderer: *Renderer, projection: ProjectionParams) void {
    _ = projection;
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const ssr_v2 = @import("../passes_v2/ssr.zig");
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
        .out_color = renderer.ssr_scratch_pixels,
        .gbuf = gbuf,
    };
    _ = ssr_v2.execute(inputs, .{ .intensity = config.POST_SSR_INTENSITY });
    const tmp = renderer.bitmap.pixels;
    renderer.bitmap.pixels = renderer.ssr_scratch_pixels;
    renderer.ssr_scratch_pixels = tmp;
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass("ssr", renderer.bitmap.width, renderer.bitmap.height, before, renderer.bitmap.pixels, renderer.scene_depth);
    }
    renderer.recordRenderPassTiming("ssr", pass_start);
}

pub fn applyDepthOfFieldPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const dof_v2 = @import("../passes_v2/depth_of_field.zig");
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
        .out_color = renderer.dof_scratch.pixels,
        .gbuf = gbuf,
    };
    _ = dof_v2.execute(inputs, .{
        .focal_distance = config.POST_DOF_FOCAL_DISTANCE,
        .focal_range = config.POST_DOF_FOCAL_RANGE,
        .max_blur_px = 4,
    });
    // Copy DOF result back to bitmap.
    if (renderer.dof_scratch.pixels.len == renderer.bitmap.pixels.len) {
        @memcpy(renderer.bitmap.pixels, renderer.dof_scratch.pixels);
    }
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass("depth_of_field", renderer.bitmap.width, renderer.bitmap.height, before, renderer.bitmap.pixels, renderer.scene_depth);
    }
    renderer.recordRenderPassTiming("dof", pass_start);
}

/// Applies bloom pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn applyBloomPass(renderer: *Renderer) void {
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const bloom_v2 = @import("../passes_v2/bloom.zig");
    const inputs: passes_v2.Inputs = .{
        .width = renderer.bitmap.width,
        .height = renderer.bitmap.height,
        .in_color = renderer.bitmap.pixels,
        .out_color = renderer.moblur_scratch_pixels,
    };
    _ = bloom_v2.execute(inputs, .{
        .threshold = @intCast(@max(0, @min(255, config.POST_BLOOM_THRESHOLD))),
        .intensity = @as(f32, @floatFromInt(config.POST_BLOOM_INTENSITY_PERCENT)) / 100.0,
    });
    const tmp = renderer.bitmap.pixels;
    renderer.bitmap.pixels = renderer.moblur_scratch_pixels;
    renderer.moblur_scratch_pixels = tmp;
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass(
            "bloom",
            renderer.bitmap.width,
            renderer.bitmap.height,
            before,
            renderer.bitmap.pixels,
            renderer.scene_depth,
        );
    }
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