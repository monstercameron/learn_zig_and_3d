const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const profiler = @import("../../core/profiler.zig");
const renderer_module = @import("../renderer.zig");
const renderer_lights = @import("lights.zig");
const post_dispatch = @import("post_dispatch.zig");
const frame_pipeline = @import("../frame/pipeline.zig");
const frame_executor = @import("../frame/executor.zig");
const frame_resources = @import("../frame/resources.zig");
const frame_plan = @import("../graph/frame_plan.zig");
const frame_graph = @import("../graph/frame_graph.zig");
const pass_graph = @import("../pipeline/pass_graph.zig");
const shadow_map_pass = @import("../passes/shadow_map_pass.zig");
const shadow_resolve_pass = @import("../passes/shadow_resolve_pass.zig");
const adaptive_shadow_tile_pass = @import("../passes/adaptive_shadow_tile_pass.zig");
const hybrid_shadow_pass = @import("../passes/hybrid_shadow_pass.zig");
const direct_primitives = @import("../direct/primitives.zig");
const render_utils = @import("../core/utils.zig");

const Renderer = renderer_module.Renderer;
const Mesh = renderer_module.Mesh;
const ShadowMap = renderer_module.ShadowMap;
const ShadowResolveConfig = renderer_module.ShadowResolveConfig;
const ShadowLightDispatchContext = renderer_module.ShadowLightDispatchContext;
const HybridShadowDispatchContext = renderer_module.HybridShadowDispatchContext;
const CompositionScratchBindings = renderer_module.CompositionScratchBindings;
const PostPassExecutionContext = renderer_module.PostPassExecutionContext;
const TemporalAAViewState = renderer_module.TemporalAAViewState;
const ProjectionParams = renderer_module.ProjectionParams;
const FrameViewCache = renderer_module.FrameViewCache;
const FrameExecutionContext = Renderer.FrameExecutionContext;
const renderer_logger = renderer_module.renderer_logger;
const pipeline_logger = renderer_module.pipeline_logger;
const noopRenderPassJob = renderer_module.noopRenderPassJob;
const chooseShadowBasis = render_utils.chooseShadowBasis;
const texture = @import("../../assets/texture.zig");
const frame_dispatchers = @import("../frame/dispatchers.zig");
const NEAR_CLIP = renderer_module.NEAR_CLIP;
const renderer_orchestrator = @import("orchestrator.zig");
const CameraToLightTransform = renderer_module.CameraToLightTransform;
const renderer_hud = @import("hud.zig");
const shadow_rebuild_dot_threshold = renderer_module.shadow_rebuild_dot_threshold;
/// buildShadowMap builds data structures used by Renderer.
fn buildShadowMap(renderer: *Renderer, mesh: *const Mesh, light_dir_world: math.Vec3, target_shadow_map: *ShadowMap) i128 {
    return shadow_map_pass.runBuild(
        renderer,
        mesh,
        light_dir_world,
        target_shadow_map,
        config.POST_SHADOW_ENABLED,
        config.POST_SHADOW_DEPTH_BIAS,
        chooseShadowBasis,
        renderer_orchestrator.computeStripeCount,
        noopRenderPassJob,
    );
}

/// Applies shadow pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applyShadowPass(
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
    target_shadow_map: *const ShadowMap,
    pass_index: usize,
) void {
    if (!target_shadow_map.*.active or renderer.bitmap.pixels.len == 0 or renderer.scene_depth.len != renderer.bitmap.pixels.len) return;
    const width: usize = @intCast(renderer.bitmap.width);
    const height: usize = @intCast(renderer.bitmap.height);
    const resolve_config = ShadowResolveConfig{
        .camera_position = camera_position,
        .basis_right = basis_right,
        .basis_up = basis_up,
        .basis_forward = basis_forward,
        .center_x = projection.center_x,
        .center_y = projection.center_y,
        .x_scale = projection.x_scale,
        .y_scale = projection.y_scale,
        .near_plane = projection.near_plane,
        .darkness_percent = config.POST_SHADOW_STRENGTH_PERCENT,
    };
    const resolve_elapsed_ns = shadow_map_pass.runPipeline(
        renderer,
        width,
        height,
        resolve_config,
        target_shadow_map,
        noopRenderPassJob,
    );
    if (pass_index < renderer.shadow_resolve_elapsed_ns.len) {
        renderer.shadow_resolve_elapsed_ns[pass_index] = resolve_elapsed_ns;
    }
    renderer.light_work_stats.shadow_resolve_ns += resolve_elapsed_ns;
}

/// Applies adaptive shadow pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applyAdaptiveShadowPass(
    renderer: *Renderer,
    mesh: *const Mesh,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    light_dir_world: math.Vec3,
) void {
    const _z_applyAdaptiveShadowPass = profiler.zone("applyAdaptiveShadowPass");
    defer if (_z_applyAdaptiveShadowPass) |z| z.end();
    if (!config.POST_HYBRID_SHADOW_ENABLED or renderer.bitmap.pixels.len == 0 or renderer.tile_grid == null or renderer.active_tile_flags == null) return;

    const pass_start = std.time.nanoTimestamp();
    renderer.hybrid_shadow_stats = .{};
    const grid = renderer.tile_grid.?;
    const active_flags = renderer.active_tile_flags.?;
    const active_indices = renderer.active_tile_indices.?;
    const shadow_jobs = renderer.shadow_tile_jobs_buffer.?;
    const tile_ranges = renderer.hybrid_shadow_tile_ranges;
    const jobs = renderer.job_buffer.?;
    const darkness_scale = 1.0 - (@as(f32, @floatFromInt(config.POST_SHADOW_STRENGTH_PERCENT)) / 100.0);
    const normalized_light_dir = math.Vec3.normalize(light_dir_world);
    const light_basis = chooseShadowBasis(normalized_light_dir);
    const camera_to_light = CameraToLightTransform.init(
        camera_position,
        basis_right,
        basis_up,
        basis_forward,
        light_basis.right,
        light_basis.up,
        normalized_light_dir,
    );
    hybrid_shadow_pass.runPipeline(
        renderer,
        mesh,
        grid,
        active_flags,
        active_indices,
        shadow_jobs,
        tile_ranges,
        jobs,
        camera_position,
        basis_right,
        basis_up,
        basis_forward,
        normalized_light_dir,
        light_basis.right,
        light_basis.up,
        camera_to_light,
        darkness_scale,
        pass_start,
        shadow_rebuild_dot_threshold,
        noopRenderPassJob,
    );
}

// Empty placeholder; SkyboxJobContext was used by the legacy job
// dispatch which we've now removed. Defined as an opaque to keep the
// field type stable in the Renderer struct until that field is also
// stripped.
pub const SkyboxJobContext = struct {};

pub fn applySkyboxPass(
    renderer: *Renderer,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
) void {
    _ = basis_right;
    _ = basis_up;
    _ = basis_forward;
    _ = projection;
    if (renderer.bitmap.pixels.len == 0) return;
    const pass_start = std.time.nanoTimestamp();
    const iq_scan_runtime = @import("../iq_scan_runtime.zig");
    const passes_v2 = @import("../passes_v2/mod.zig");
    const before_snapshot = if (iq_scan_runtime.isEnabled())
        iq_scan_runtime.snapshot(renderer.allocator, renderer.bitmap.pixels) catch null
    else
        null;
    const sky_v2 = @import("../passes_v2/skybox.zig");
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
    _ = sky_v2.execute(inputs, .{});
    if (before_snapshot) |before| {
        iq_scan_runtime.reportPass("skybox", renderer.bitmap.width, renderer.bitmap.height, before, renderer.bitmap.pixels, renderer.scene_depth);
    }
    renderer.recordRenderPassTiming("skybox", pass_start);
}

pub fn runShadowResolvePass(
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
    shadow_build_elapsed_ns: []const i128,
) void {
    const shadow_ctx = ShadowLightDispatchContext{
        .renderer = renderer,
        .camera_position = camera_position,
        .basis_right = basis_right,
        .basis_up = basis_up,
        .basis_forward = basis_forward,
        .projection = projection,
        .shadow_build_elapsed_ns = shadow_build_elapsed_ns,
    };
    shadow_map_pass.runPerLight(renderer.lights.items.len, shadow_ctx, applyShadowLightFromPass);
    if (renderer.light_work_stats.shadow_resolve_ns > 0) {
        renderer.recordRenderPassDuration("shadow_map_resolve_total", renderer.light_work_stats.shadow_resolve_ns);
    }
}

pub fn runHybridShadowPass(
    renderer: *Renderer,
    mesh: *const Mesh,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    light_dir_world: math.Vec3,
) void {
    const hybrid_ctx = HybridShadowDispatchContext{
        .renderer = renderer,
        .mesh = mesh,
        .camera_position = camera_position,
        .basis_right = basis_right,
        .basis_up = basis_up,
        .basis_forward = basis_forward,
        .light_dir_world = light_dir_world,
    };
    hybrid_shadow_pass.run(hybrid_ctx, applyHybridShadowFromPass);
}

pub fn runPostProcessStage(
    renderer: *Renderer,
    is_editor_mode: bool,
    mesh: *const Mesh,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    current_view: TemporalAAViewState,
    projection: ProjectionParams,
    shadow_map_light_count: usize,
    light_dir_world: math.Vec3,
) void {
    if (is_editor_mode) {
        renderer.scene_item_gizmo.resolvePendingPick(
            renderer.bitmap.width,
            renderer.bitmap.height,
            @as(i32, @intCast(config.WINDOW_WIDTH)),
            @as(i32, @intCast(config.WINDOW_HEIGHT)),
            renderer.scene_surface,
        );
    }
    // Skip the post graph when the scene raster was cache-hit. Post
    // passes are non-idempotent (read/write target.color in place),
    // so running them on already-post-processed pixels compounds the
    // effect and progressively saturates the buffer. The previous
    // miss frame's post output is already in target.color — present
    // will blit that directly.
    if (renderer.direct_backend.lastTimings().scene_was_cached) return;
    applyPostProcessingPasses(renderer,
        mesh,
        renderer.camera_position,
        basis_right,
        basis_up,
        basis_forward,
        current_view,
        projection,
        shadow_map_light_count,
        light_dir_world,
        renderer.shadow_build_elapsed_ns[0..renderer.lights.items.len],
    );
}

/// Applies shadow light from pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applyShadowLightFromPass(ctx: ShadowLightDispatchContext, pass_index: usize) void {
    if (pass_index >= ctx.renderer.lights.items.len) return;
    if (ctx.renderer.lights.items[pass_index].shadow_mode != .shadow_map) return;
    const shadow_map_ptr = &ctx.renderer.lights.items[pass_index].shadow_map;
    _ = ctx.shadow_build_elapsed_ns;
    applyShadowPass(
        ctx.renderer,
        ctx.camera_position,
        ctx.basis_right,
        ctx.basis_up,
        ctx.basis_forward,
        ctx.projection,
        shadow_map_ptr,
        pass_index,
    );
}

/// Applies hybrid shadow from pass.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applyHybridShadowFromPass(ctx: HybridShadowDispatchContext) void {
    applyAdaptiveShadowPass(
        ctx.renderer,
        ctx.mesh,
        ctx.camera_position,
        ctx.basis_right,
        ctx.basis_up,
        ctx.basis_forward,
        ctx.light_dir_world,
    );
}

/// Returns whether i sp os tp as se na bl ed.
/// The check is side-effect free so callers can gate expensive follow-up work cheaply.
fn snapshotScratchBindings(renderer: *Renderer) CompositionScratchBindings {
    return .{
        .ssgi_scratch_pixels = renderer.ssgi_scratch_pixels,
        .ssr_scratch_pixels = renderer.ssr_scratch_pixels,
        .moblur_scratch_pixels = renderer.moblur_scratch_pixels,
        .god_rays_scratch_pixels = renderer.god_rays_scratch_pixels,
        .lens_flare_scratch_pixels = renderer.lens_flare_scratch_pixels,
    };
}

/// Applies composition scratch bindings.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applyCompositionScratchBindings(renderer: *Renderer, scratch_a: []u32, scratch_b: []u32) void {
    const applied = frame_pipeline.applyScratchBindings(.{ .scratch_a = scratch_a, .scratch_b = scratch_b });
    renderer.ssgi_scratch_pixels = applied.scratch_a;
    renderer.ssr_scratch_pixels = applied.scratch_b;
    renderer.moblur_scratch_pixels = applied.scratch_a;
    renderer.god_rays_scratch_pixels = applied.scratch_a;
    renderer.lens_flare_scratch_pixels = applied.scratch_a;
}

fn recordPostPhaseTiming(ctx: *anyopaque, phase: pass_graph.PassPhase, duration_ns: i128) void {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx));
    renderer.recordRenderPassDuration(frame_pipeline.phaseTimingName(phase), duration_ns);
}

fn shouldRecordPostPhaseTimings(renderer: *const Renderer) bool {
    if (renderer.show_render_overlay) return true;
    if (profiler.Profiler.instance) |instance| {
        if (instance.active) return true;
    }
    return renderer.profile_capture_frame != 0 and renderer.total_frames_rendered + 1 == renderer.profile_capture_frame;
}

fn restoreScratchBindings(renderer: *Renderer, saved: CompositionScratchBindings) void {
    renderer.ssgi_scratch_pixels = saved.ssgi_scratch_pixels;
    renderer.ssr_scratch_pixels = saved.ssr_scratch_pixels;
    renderer.moblur_scratch_pixels = saved.moblur_scratch_pixels;
    renderer.god_rays_scratch_pixels = saved.god_rays_scratch_pixels;
    renderer.lens_flare_scratch_pixels = saved.lens_flare_scratch_pixels;
}
pub const post_pass_dispatcher = frame_dispatchers.makePostPassDispatcher(PostPassExecutionContext);
pub const frame_stage_dispatcher = frame_dispatchers.makeFrameStageDispatcher(FrameExecutionContext);

/// Applies post processing passes.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applyPostProcessingPasses(
    renderer: *Renderer,
    mesh: *const Mesh,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    current_view: TemporalAAViewState,
    projection: ProjectionParams,
    shadow_map_light_count: usize,
    light_dir_world: math.Vec3,
    shadow_build_elapsed_ns: []const i128,
) void {
    const compiled_graph = frame_pipeline.compileCachedPostGraph(&renderer.cached_post_graph, .{
        .shadow_map_light_count = shadow_map_light_count,
        // Force valid so the graph compile always includes TAA/MotionBlur.
        // The v2 TAA pass handles the "history not yet populated"
        // case internally (returns no-op on first frame).
        .taa_history_valid = true,
    }) catch |err| {
        pipeline_logger.errorSub("graph", "failed to compile post graph: {s}", .{@errorName(err)});
        return;
    };

    const ctx = PostPassExecutionContext{
        .renderer = renderer,
        .mesh = mesh,
        .camera_position = camera_position,
        .basis_right = basis_right,
        .basis_up = basis_up,
        .basis_forward = basis_forward,
        .current_view = current_view,
        .projection = projection,
        .light_dir_world = light_dir_world,
        .shadow_build_elapsed_ns = shadow_build_elapsed_ns,
    };
    const saved_bindings = snapshotScratchBindings(renderer);
    defer restoreScratchBindings(renderer, saved_bindings);
    applyCompositionScratchBindings(renderer, saved_bindings.moblur_scratch_pixels, saved_bindings.ssr_scratch_pixels);
    frame_executor.executePostGraph(
        PostPassExecutionContext,
        compiled_graph,
        .{
            .front = &renderer.bitmap.pixels,
            .scratch_a = &renderer.moblur_scratch_pixels,
            .scratch_b = &renderer.ssr_scratch_pixels,
        },
        .{
            .enabled = shouldRecordPostPhaseTimings(renderer),
            .ctx = renderer,
            .record = recordPostPhaseTiming,
        },
        ctx,
        post_pass_dispatcher,
    );
}

pub fn stageBuildShadowMaps(renderer: *Renderer, mesh: *const Mesh) void {
    if (!config.POST_SHADOW_ENABLED) return;

    const shadow_budget_ns = renderer_lights.computeShadowBuildBudgetNs(renderer);
    const enforce_shadow_budget = shadow_budget_ns >= 0;
    if (shadow_budget_ns > 0) {
        renderer.light_work_stats.shadow_budget_ns = shadow_budget_ns;
    }
    var shadow_budget_spent_ns: i128 = 0;
    @memset(renderer.shadow_build_elapsed_ns[0..renderer.lights.items.len], 0);
    const frame_number = renderer.total_frames_rendered + 1;
    for (renderer.lights.items, 0..) |*light, light_index| {
        if (light.shadow_mode != .shadow_map) continue;
        const base_cadence = @max(@as(u64, 1), @as(u64, light.shadow_update_interval_frames));
        const cadence_scale = @max(@as(u64, 1), @as(u64, light.shadow_dynamic_interval_scale));
        const cadence = @max(@as(u64, 1), @min(std.math.maxInt(u64), base_cadence * cadence_scale));
        const frames_since_last_build = if (light.shadow_last_build_frame == 0)
            cadence
        else
            frame_number - light.shadow_last_build_frame;
        const should_rebuild = !light.shadow_map.active or frames_since_last_build >= cadence;
        if (!should_rebuild) {
            renderer.light_work_stats.shadow_map_reused_lights += 1;
            continue;
        }
        if (enforce_shadow_budget and light.shadow_map.active) {
            const estimated_build_ns = renderer_lights.estimateShadowBuildCostNs(light);
            if (shadow_budget_spent_ns + estimated_build_ns > shadow_budget_ns) {
                renderer.light_work_stats.shadow_map_reused_lights += 1;
                renderer.light_work_stats.shadow_budget_skipped_lights += 1;
                continue;
            }
        }
        const light_dir_world_for_shadow = math.Vec3.new(
            renderer.light_soa.dir_x[light_index],
            renderer.light_soa.dir_y[light_index],
            renderer.light_soa.dir_z[light_index],
        );
        renderer.shadow_build_elapsed_ns[light_index] = buildShadowMap(renderer, mesh, light_dir_world_for_shadow, &light.shadow_map);
        light.shadow_last_build_frame = frame_number;
        light.shadow_last_build_ns = renderer.shadow_build_elapsed_ns[light_index];
        renderer.light_work_stats.shadow_build_ns += renderer.shadow_build_elapsed_ns[light_index];
        shadow_budget_spent_ns += renderer.shadow_build_elapsed_ns[light_index];
    }
    if (renderer.light_work_stats.shadow_build_ns > 0) {
        renderer.recordRenderPassDuration("shadow_map_build_total", renderer.light_work_stats.shadow_build_ns);
    }
}

pub fn stageRenderScene(
    renderer: *Renderer,
    backend: frame_plan.BackendKind,
    mesh: *const Mesh,
    view_rotation: math.Mat4,
    light_dir: math.Vec3,
    pump: ?*const fn (*Renderer) bool,
    raster_projection: ProjectionParams,
) !void {
    const scene_pass_start = std.time.nanoTimestamp();
    const tri_count = mesh.triangles.len;
    const meshlet_count = mesh.meshlets.len;
    switch (backend) {
        .tiled => {
            pipeline_logger.debugSub("dispatch", "rendering tiled path triangles={} meshlets={}", .{ tri_count, meshlet_count });
            const shadow_pass_elapsed_ns = try renderer.renderTiled(mesh, view_rotation, light_dir, pump, raster_projection);
            const scene_pass_elapsed_ns = std.time.nanoTimestamp() - scene_pass_start;
            renderer.recordRenderPassDuration("meshlet_tiled", scene_pass_elapsed_ns - @as(i128, @intCast(shadow_pass_elapsed_ns)));
            if (config.MESHLET_SHADOWS_ENABLED) {
                renderer.recordRenderPassDuration("meshlet_shadows", @as(i128, @intCast(shadow_pass_elapsed_ns)));
            }
        },
        .direct => {
            pipeline_logger.debugSub("dispatch", "rendering direct path triangles={} meshlets={}", .{ tri_count, meshlet_count });
            try renderer.renderDirect(mesh, view_rotation, light_dir, raster_projection);
            renderer.recordRenderPassTiming("meshlet_direct", scene_pass_start);
        },
    }
}

pub fn stageOverlayAndPresent(
    renderer: *Renderer,
    is_editor_mode: bool,
    light_camera: math.Vec3,
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    cache_projection: ProjectionParams,
) !i128 {
    if (is_editor_mode) {
        renderer.scene_item_gizmo.applyOutline(
            renderer.bitmap.pixels,
            renderer.bitmap.width,
            renderer.bitmap.height,
            renderer.scene_surface,
        );
    }
    try renderer_lights.applyAdaptiveShadowBudgetPolicy(renderer);
    if (renderer.show_light_orb) {
        const light_camera_z = light_camera.z;
        if (light_camera_z > NEAR_CLIP) {
            var glow_color = math.Vec3.new(1.0, 1.0, 1.0);
            var glow_radius: f32 = 0.0;
            var glow_intensity: f32 = 0.0;
            if (renderer.lights.items.len > 0) {
                glow_color = renderer.lights.items[0].color;
                glow_radius = renderer.lights.items[0].glow_radius;
                glow_intensity = renderer.lights.items[0].glow_intensity;
            }
            if (glow_radius > 0.0 and glow_intensity > 0.0) {
                renderer.drawLightGlow(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale, glow_color, glow_radius, glow_intensity);
            }
            renderer.drawLightMarker(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale);
        }
    }
    if (is_editor_mode and renderer.light_gizmo.enabled) {
        renderer.drawLightGizmo(renderer.camera_position, right, up, forward, cache_projection);
    }
    if (is_editor_mode and renderer.scene_item_gizmo.isActive()) {
        renderer.drawSceneItemGizmo(renderer.camera_position, right, up, forward, cache_projection);
    }

    const present_start = std.time.nanoTimestamp();
    const cpu_frame_ns = present_start - renderer.current_frame_start_time;

    if (renderer.usesSoftwareFramePacing() and renderer.last_completed_frame_time > 0) {
        const ideal_present_time = renderer.last_completed_frame_time + renderer.target_frame_time_ns - renderer.present_cost_ema_ns;
        var spin_now = std.time.nanoTimestamp();
        while (spin_now < ideal_present_time) {
            std.atomic.spinLoopHint();
            spin_now = std.time.nanoTimestamp();
        }
    }

    const pre_present_time = std.time.nanoTimestamp();
    renderer_hud.drawBitmap(renderer);
    const present_end = std.time.nanoTimestamp();
    const draw_cost_ns = @max(present_end - pre_present_time, @as(i128, 0));
    renderer.present_cost_ema_ns = @divTrunc(renderer.present_cost_ema_ns * 7 + draw_cost_ns, 8);
    renderer.recordRenderPassTiming("present", present_start);
    pipeline_logger.debugSub("present", "bitmap presented", .{});

    const current_time = present_end;
    const frame_interval_ns = current_time - renderer.last_completed_frame_time;
    renderer.notePresentedFrame(current_time);
    renderer_orchestrator.maybeEmitSingleFrameProfile(renderer);
    renderer.frame_pacing.recordSample(.{
        .total_ms = @as(f32, @floatFromInt(@max(frame_interval_ns, @as(i128, 0)))) / 1_000_000.0,
        .cpu_ms = @as(f32, @floatFromInt(@max(cpu_frame_ns, @as(i128, 0)))) / 1_000_000.0,
        .software_wait_ms = @as(f32, @floatFromInt(@max(renderer.active_software_wait_ns, @as(i128, 0)))) / 1_000_000.0,
        .present_wait_ms = @as(f32, @floatFromInt(@max(present_end - present_start, @as(i128, 0)))) / 1_000_000.0,
        .deadline_error_ms = @as(f32, @floatFromInt(renderer.frame_deadline_error_ns)) / 1_000_000.0,
    }, renderer.effectiveFramePacingTargetNs());
    return current_time;
}