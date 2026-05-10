const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const profiler = @import("../../core/profiler.zig");
const renderer_module = @import("../renderer.zig");
const renderer_lights = @import("lights.zig");
const renderer_hud = @import("hud.zig");
const post_dispatch = @import("post_dispatch.zig");
const direct_backend = @import("../backends/direct_backend.zig");
const direct_primitives = @import("../direct/primitives.zig");
const frame_pipeline = @import("../frame/pipeline.zig");
const frame_executor = @import("../frame/executor.zig");
const frame_dispatchers = @import("../frame/dispatchers.zig");
const frame_plan = @import("../graph/frame_plan.zig");
const frame_graph = @import("../graph/frame_graph.zig");

const Renderer = renderer_module.Renderer;
const Mesh = renderer_module.Mesh;
const RenderPassTiming = renderer_module.RenderPassTiming;
const TemporalAAViewState = renderer_module.TemporalAAViewState;
const ProjectionParams = renderer_module.ProjectionParams;
const ColorGradeProfile = renderer_module.ColorGradeProfile;
const renderer_logger = renderer_module.renderer_logger;
const camera_runtime = @import("../camera/runtime.zig");
const render_utils = @import("../core/utils.zig");
const SetWindowTextW = renderer_module.SetWindowTextW;
const min_rows_per_parallel_job = renderer_module.min_rows_per_parallel_job;
const GroundReason = renderer_module.GroundReason;
const ground_logger = renderer_module.ground_logger;
const FrameExecutionContext = Renderer.FrameExecutionContext;
const taaJitterForFrame = renderer_module.taaJitterForFrame;
const renderer_orchestrator = @This();
const NEAR_CLIP = renderer_module.NEAR_CLIP;
const NEAR_EPSILON = renderer_module.NEAR_EPSILON;
/// Sets s et te xt ur e.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn render3DMesh(renderer: *Renderer, mesh: *const Mesh) !void {
    try renderer.render3DMeshWithPump(mesh, null);
}

/// The main render loop function, with an added callback to process OS messages.
/// This is the heart of the engine, executing the full 3D pipeline each frame.
pub fn render3DMeshWithPump(renderer: *Renderer, mesh: *const Mesh, pump: ?*const fn (*Renderer) bool) !void {
    if (renderer.total_frames_rendered == renderer.profile_capture_frame and profiler.Profiler.instance.?.active) {
        profiler.Profiler.stopCaptureAndSave("profile.json") catch {};
    }
    if (renderer.total_frames_rendered + 1 == renderer.profile_capture_frame) {
        profiler.Profiler.startCapture();
    }
    const _zone = profiler.zone("Renderer.render");
    defer if (_zone) |z| z.end();

    resetRenderPassTimings(renderer);

    const delta_seconds = beginFrame(renderer);
    const simulation_delta_seconds: f32 = if (renderer.hybrid_shadow_debug.enabled) 0.0 else delta_seconds;

    renderer_logger.debugSub(
        "frame",
        "begin frame {} camera=({d:.2},{d:.2},{d:.2}) fov={d:.1}",
        .{
            renderer.frame_count + 1,
            renderer.camera_position.x,
            renderer.camera_position.y,
            renderer.camera_position.z,
            renderer.camera_fov_deg,
        },
    );

    const sweep_half_angle = std.math.pi / 2.0;
    for (renderer.lights.items) |*light| {
        if (!light.manual_direction) {
            light.orbit_x += light.orbit_speed * simulation_delta_seconds;
            const sweep_angle = @sin(light.orbit_x) * sweep_half_angle;
            const horizontal_radius = light.distance * @cos(light.elevation);
            const light_height = @max(0.35, light.distance * @sin(light.elevation));
            const light_pos = math.Vec3.new(
                @sin(sweep_angle) * horizontal_radius,
                light_height,
                @cos(sweep_angle) * horizontal_radius,
            );
            light.direction = math.Vec3.normalize(light_pos);
        }
    }
    renderer_lights.syncLightSoA(renderer);
    const light_distance_0 = if (renderer.lights.items.len > 0) renderer.light_soa.distance[0] else 10.0;
    const light_dir_world = if (renderer.lights.items.len > 0)
        math.Vec3.new(renderer.light_soa.dir_x[0], renderer.light_soa.dir_y[0], renderer.light_soa.dir_z[0])
    else
        math.Vec3.new(0, -1, 0);
    camera_runtime.prepareCameraForFrame(renderer, delta_seconds, simulation_delta_seconds, light_dir_world, light_distance_0);
    const right = renderer.frame_view_cache.state.right;
    const up = renderer.frame_view_cache.state.up;
    const forward = renderer.frame_view_cache.state.forward;

    const resolved_frame_view = if (renderer.frame_view_cache.needsUpdate(
        renderer.camera_position,
        renderer.rotation_angle,
        renderer.rotation_x,
        renderer.camera_fov_deg,
        renderer.bitmap.width,
        renderer.bitmap.height,
        light_dir_world,
        light_distance_0,
    ))
        renderer.frame_view_cache.update(
            renderer.camera_position,
            renderer.rotation_angle,
            renderer.rotation_x,
            renderer.camera_fov_deg,
            renderer.bitmap.width,
            renderer.bitmap.height,
            light_dir_world,
            light_distance_0,
        )
    else
        renderer.frame_view_cache.state;

    const view_rotation = resolved_frame_view.view_rotation;
    const light_camera = resolved_frame_view.light_camera;
    const light_dir = resolved_frame_view.light_dir_camera;
    const center_x = resolved_frame_view.center_x;
    const center_y = resolved_frame_view.center_y;
    const x_scale = resolved_frame_view.x_scale;
    const y_scale = resolved_frame_view.y_scale;
    const taa_jitter = if (config.POST_TAA_ENABLED) taaJitterForFrame(renderer.total_frames_rendered) else math.Vec2.new(0.0, 0.0);
    const raster_projection = ProjectionParams{
        .center_x = center_x,
        .center_y = center_y,
        .x_scale = x_scale,
        .y_scale = y_scale,
        .near_plane = NEAR_CLIP,
        .jitter_x = taa_jitter.x,
        .jitter_y = taa_jitter.y,
    };
    const taa_view = TemporalAAViewState.init(renderer.camera_position, right, up, forward, raster_projection);
    if (config.POST_TAA_ENABLED) try renderer.ensureTemporalMeshVertexCapacity(mesh.vertices.len);
    const shadow_map_light_count = if (config.POST_SHADOW_ENABLED)
        renderer.countLightsWithShadowMode(.shadow_map)
    else
        0;
    const meshlet_shadow_light_count = if (config.MESHLET_SHADOWS_ENABLED)
        renderer.countLightsWithShadowMode(.meshlet_ray)
    else
        0;
    renderer.light_work_stats.active_lights = renderer.lights.items.len;
    renderer.light_work_stats.shadow_map_lights = shadow_map_light_count;
    renderer.light_work_stats.meshlet_shadow_lights = meshlet_shadow_light_count;
    renderer.light_work_stats.shadow_map_reused_lights = 0;
    renderer.light_work_stats.shadow_budget_skipped_lights = 0;
    renderer.light_work_stats.shadow_map_downscaled_lights = 0;
    renderer.light_work_stats.shadow_map_upscaled_lights = 0;
    renderer.light_work_stats.shadow_cadence_increased_lights = 0;
    renderer.light_work_stats.shadow_cadence_decreased_lights = 0;
    renderer.light_work_stats.shadow_queries = renderer.bitmap.pixels.len * shadow_map_light_count;
    renderer.light_work_stats.meshlet_ray_tests = 0;
    renderer.light_work_stats.meshlet_shadow_chunks = 0;
    renderer.light_work_stats.meshlet_shadow_chunk_pixels = 0;
    renderer.light_work_stats.meshlet_shadow_chunk_active_rays = 0;
    renderer.light_work_stats.meshlet_shadow_packets = 0;
    renderer.light_work_stats.meshlet_shadow_packets_skipped = 0;
    renderer.light_work_stats.meshlet_shadow_packet_active_lanes = 0;
    renderer.light_work_stats.meshlet_shadow_packet_occluded_lanes = 0;
    renderer.light_work_stats.meshlet_shadow_trace_us = 0;
    renderer.light_work_stats.meshlet_shadow_apply_us = 0;
    renderer.light_work_stats.triangles_rasterized = 0;
    renderer.light_work_stats.covered_pixels = 0;
    renderer.light_work_stats.depth_tests_passed = 0;
    renderer.light_work_stats.alpha_pixels = 0;
    renderer.light_work_stats.shadow_budget_ns = 0;
    renderer.light_work_stats.shadow_build_ns = 0;
    renderer.light_work_stats.shadow_resolve_ns = 0;
    renderer.light_work_stats.active_tiles = 0;
    renderer.light_work_stats.tile_light_candidates = 0;
    renderer.light_work_stats.tile_light_final = 0;
    renderer.light_work_stats.tile_light_rejected = 0;
    renderer.light_work_stats.tile_light_overflow_tiles = 0;
    @memset(renderer.shadow_resolve_elapsed_ns[0..renderer.lights.items.len], 0);
    const is_editor_mode = renderer.camera_control_mode != .first_person;
    const using_tiled_backend = renderer.use_tiled_rendering and renderer.tile_grid != null and renderer.tile_buffers != null;
    const compiled_frame_plan = frame_pipeline.compileCachedFramePlan(&renderer.cached_frame_plan, .{
        .has_shadow_map_lights = shadow_map_light_count > 0,
        .backend = if (using_tiled_backend) .tiled else .direct,
        .include_post_process = false,
        .include_present = true,
    });
    const frame_exec_ctx = FrameExecutionContext{
        .renderer = renderer,
        .mesh = mesh,
        .view_rotation = view_rotation,
        .light_dir = light_dir,
        .pump = pump,
        .raster_projection = raster_projection,
        .is_editor_mode = is_editor_mode,
        .light_camera = light_camera,
        .center_x = center_x,
        .center_y = center_y,
        .x_scale = x_scale,
        .y_scale = y_scale,
        .basis_right = right,
        .basis_up = up,
        .basis_forward = forward,
        .taa_view = taa_view,
        .shadow_map_light_count = shadow_map_light_count,
        .light_dir_world = light_dir_world,
        .cache_projection = resolved_frame_view.cache_projection,
    };
    const current_time = try frame_executor.executeFramePlan(
        FrameExecutionContext,
        compiled_frame_plan,
        frame_exec_ctx,
        @import("scene_dispatch.zig").frame_stage_dispatcher,
        std.time.nanoTimestamp(),
    );
    finalizeFrame(renderer, current_time);
    renderer.advanceFrameDeadline(current_time);

    renderer_logger.debugSub(
        "frame",
        "finish frame {} delta={d:.3}ms fps={}",
        .{
            renderer.frame_count,
            delta_seconds * 1000.0,
            renderer.current_fps,
        },
    );
}

/// Begins an operation and captures temporary context used until completion.
/// It marks the start of an operation and prepares transient state used until completion.
fn beginFrame(renderer: *Renderer) f32 {
    const now = std.time.nanoTimestamp();
    var delta_ns = now - renderer.last_frame_time;
    if (delta_ns < 0) delta_ns = 0;
    renderer.last_frame_time = now;
    renderer.current_frame_start_time = now;
    renderer.active_software_wait_ns = renderer.pending_software_wait_ns;
    renderer.pending_software_wait_ns = 0;
    renderer.frame_deadline_error_ns = if (renderer.next_frame_time > 0) now - renderer.next_frame_time else 0;

    const delta_ns_f = @as(f64, @floatFromInt(delta_ns));
    var delta_seconds = @as(f32, @floatCast(delta_ns_f / 1_000_000_000.0));
    if (delta_seconds > 0.1) delta_seconds = 0.1;
    if (delta_seconds <= 0.0) delta_seconds = 1.0 / 120.0;
    return delta_seconds;
}

pub fn maybeEmitSingleFrameProfile(renderer: *Renderer) void {
    if (renderer.profile_capture_emitted or renderer.profile_capture_frame == 0) return;
    if (renderer.total_frames_rendered != renderer.profile_capture_frame) return;

    renderer.profile_capture_emitted = true;
    renderer_logger.infoSub("frame_profile", "frame={} exact pass timings follow", .{renderer.total_frames_rendered});

    for (renderer.render_pass_timings[0..renderer.render_pass_count]) |pass| {
        renderer_logger.infoSub("frame_profile", "{s}: {d:.3} ms", .{ pass.name, pass.frame_duration_ms });
    }
    const packet_count = @max(@as(usize, 1), renderer.light_work_stats.meshlet_shadow_packets);
    const avg_active_lanes = @as(f32, @floatFromInt(renderer.light_work_stats.meshlet_shadow_packet_active_lanes)) /
        @as(f32, @floatFromInt(packet_count));
    const avg_occluded_lanes = @as(f32, @floatFromInt(renderer.light_work_stats.meshlet_shadow_packet_occluded_lanes)) /
        @as(f32, @floatFromInt(packet_count));
    renderer_logger.infoSub(
        "frame_profile",
        "light_work active={} shadow_map_lights={} meshlet_shadow_lights={} shadow_map_reused={} shadow_budget_skipped={} shadow_map_downscaled={} shadow_map_upscaled={} shadow_cadence_increased={} shadow_cadence_decreased={} shadow_queries={} meshlet_ray_tests={} meshlet_shadow_chunks={} meshlet_shadow_chunk_pixels={} meshlet_shadow_chunk_active_rays={} meshlet_shadow_packets={} meshlet_shadow_packets_skipped={} meshlet_shadow_avg_active_lanes={d:.2} meshlet_shadow_avg_occluded_lanes={d:.2} meshlet_shadow_trace={d:.3} ms meshlet_shadow_apply={d:.3} ms shadow_budget={d:.3} ms shadow_build={d:.3} ms shadow_resolve={d:.3} ms active_tiles={} tile_light_candidates={} tile_light_final={} tile_light_rejected={} tile_light_overflow_tiles={}",
        .{
            renderer.light_work_stats.active_lights,
            renderer.light_work_stats.shadow_map_lights,
            renderer.light_work_stats.meshlet_shadow_lights,
            renderer.light_work_stats.shadow_map_reused_lights,
            renderer.light_work_stats.shadow_budget_skipped_lights,
            renderer.light_work_stats.shadow_map_downscaled_lights,
            renderer.light_work_stats.shadow_map_upscaled_lights,
            renderer.light_work_stats.shadow_cadence_increased_lights,
            renderer.light_work_stats.shadow_cadence_decreased_lights,
            renderer.light_work_stats.shadow_queries,
            renderer.light_work_stats.meshlet_ray_tests,
            renderer.light_work_stats.meshlet_shadow_chunks,
            renderer.light_work_stats.meshlet_shadow_chunk_pixels,
            renderer.light_work_stats.meshlet_shadow_chunk_active_rays,
            renderer.light_work_stats.meshlet_shadow_packets,
            renderer.light_work_stats.meshlet_shadow_packets_skipped,
            avg_active_lanes,
            avg_occluded_lanes,
            @as(f32, @floatFromInt(renderer.light_work_stats.meshlet_shadow_trace_us)) / 1000.0,
            @as(f32, @floatFromInt(renderer.light_work_stats.meshlet_shadow_apply_us)) / 1000.0,
            render_utils.nanosecondsToMs(renderer.light_work_stats.shadow_budget_ns),
            render_utils.nanosecondsToMs(renderer.light_work_stats.shadow_build_ns),
            render_utils.nanosecondsToMs(renderer.light_work_stats.shadow_resolve_ns),
            renderer.light_work_stats.active_tiles,
            renderer.light_work_stats.tile_light_candidates,
            renderer.light_work_stats.tile_light_final,
            renderer.light_work_stats.tile_light_rejected,
            renderer.light_work_stats.tile_light_overflow_tiles,
        },
    );
    renderer_logger.infoSub(
        "frame_profile",
        "raster_work triangles_rasterized={} covered_pixels={} depth_tests_passed={} alpha_pixels={}",
        .{
            renderer.light_work_stats.triangles_rasterized,
            renderer.light_work_stats.covered_pixels,
            renderer.light_work_stats.depth_tests_passed,
            renderer.light_work_stats.alpha_pixels,
        },
    );
    for (0..renderer.lights.items.len) |light_index| {
        const build_ns = renderer.shadow_build_elapsed_ns[light_index];
        const resolve_ns = renderer.shadow_resolve_elapsed_ns[light_index];
        if (build_ns == 0 and resolve_ns == 0) continue;
        renderer_logger.infoSub(
            "frame_profile",
            "shadow_light {} build={d:.3} ms resolve={d:.3} ms",
            .{
                light_index,
                render_utils.nanosecondsToMs(build_ns),
                render_utils.nanosecondsToMs(resolve_ns),
            },
        );
    }

    if (renderer.hybrid_shadow_stats.job_count != 0) {
        renderer_logger.infoSub(
            "frame_profile",
            "hybrid_shadow detail accel={d:.3} candidate={d:.3} clear={d:.3} execute={d:.3} jobs={} active_tiles={} grid={} unique={} final={}",
            .{
                renderer.hybrid_shadow_stats.accel_rebuild_ms,
                renderer.hybrid_shadow_stats.candidate_ms,
                renderer.hybrid_shadow_stats.cache_clear_ms,
                renderer.hybrid_shadow_stats.execute_ms,
                renderer.hybrid_shadow_stats.job_count,
                renderer.hybrid_shadow_stats.active_tile_count,
                renderer.hybrid_shadow_stats.grid_candidate_count,
                renderer.hybrid_shadow_stats.unique_candidate_count,
                renderer.hybrid_shadow_stats.final_candidate_count,
            },
        );
    }
}

pub fn finalizeFrame(renderer: *Renderer, current_time: i128) void {
    const elapsed_ns = current_time - renderer.last_time;
    if (elapsed_ns < 1_000_000_000 or renderer.frame_count == 0) return;

    const elapsed_us = @divTrunc(elapsed_ns, 1000);
    if (elapsed_us == 0) return;
    renderer.current_fps = @as(u32, @intCast((renderer.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));

    const frame_count_f = @as(f32, @floatFromInt(renderer.frame_count));
    const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const avg_frame_time_ms = if (frame_count_f > 0.0) elapsed_ms / frame_count_f else 0.0;

    sampleRenderPassTimings(renderer, renderer.frame_count);
    renderer.frame_count = 0;
    renderer.last_time = current_time;
    updateWindowTitle(renderer, avg_frame_time_ms);
}

/// updateWindowTitle updates Renderer state for the current tick/frame.
fn updateWindowTitle(renderer: *Renderer, avg_frame_time_ms: f32) void {
    var title_buffer: [256]u8 = undefined;
    const telemetry = renderer.meshlet_telemetry;
    const title = std.fmt.bufPrint(&title_buffer, "{s} | FPS: {} | Frame: {d:.2}ms | Meshlets: {}/{} | Tris: {} | Tiles: {}", .{
        config.WINDOW_TITLE,
        renderer.current_fps,
        avg_frame_time_ms,
        telemetry.visible_meshlets,
        telemetry.total_meshlets,
        telemetry.emitted_triangles,
        telemetry.touched_tiles,
    }) catch config.WINDOW_TITLE;

    var title_wide: [256:0]u16 = undefined;
    const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch 0;
    title_wide[title_len] = 0;
    _ = SetWindowTextW(renderer.hwnd, &title_wide);
}

fn resetRenderPassTimings(renderer: *Renderer) void {
    renderer.render_pass_count = 0;
}

/// Records telemetry/sample data and updates aggregate counters/statistics.
/// It appends telemetry/sample data and updates aggregate counters/statistics.
pub fn recordRenderPassTiming(renderer: *Renderer, name: []const u8, start_ns: i128) void {
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    renderer.recordRenderPassDuration(name, elapsed_ns);
}

/// Computes stripe count.
/// Keeps compute stripe count as the single implementation point so call-site behavior stays consistent.
pub fn computeStripeCount(max_jobs: usize, row_count: usize) usize {
    if (row_count == 0 or max_jobs == 0) return 0;
    const desired = @max(@as(usize, 1), (row_count + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job);
    return @min(max_jobs, desired);
}

/// Records telemetry/sample data and updates aggregate counters/statistics.
/// It appends telemetry/sample data and updates aggregate counters/statistics.
pub fn recordRenderPassDuration(renderer: *Renderer, name: []const u8, elapsed_ns: i128) void {
    if (renderer.render_pass_count >= renderer.render_pass_timings.len) return;
    const elapsed_ms = render_utils.nanosecondsToMs(elapsed_ns);
    var timing = &renderer.render_pass_timings[renderer.render_pass_count];
    if (timing.name.len == 0 or !std.mem.eql(u8, timing.name, name)) {
        timing.* = .{
            .name = name,
            .frame_duration_ms = 0.0,
            .accumulated_ms = 0.0,
            .sampled_ms_per_frame = 0.0,
            .has_sample = false,
        };
    }
    timing.frame_duration_ms = elapsed_ms;
    timing.accumulated_ms += elapsed_ms;
    renderer.render_pass_count += 1;
}

/// renderPassSortMetric renders Renderer output.
pub fn renderPassSortMetric(pass: RenderPassTiming) f32 {
    return if (pass.has_sample) pass.sampled_ms_per_frame else pass.frame_duration_ms;
}

/// sampleRenderPassTimings samples values used by Renderer.
fn sampleRenderPassTimings(renderer: *Renderer, frame_samples: u32) void {
    if (frame_samples == 0) return;
    const sample_count = @as(f32, @floatFromInt(frame_samples));
    for (renderer.render_pass_timings[0..renderer.render_pass_count]) |*pass| {
        pass.sampled_ms_per_frame = pass.accumulated_ms / sample_count;
        pass.accumulated_ms = 0.0;
        pass.has_sample = true;
    }
}

fn debugGroundPlane(renderer: *Renderer, mesh: *const Mesh, transformed_vertices: []math.Vec3, transform: math.Mat4) void {
    if (mesh.triangles.len < 2 or transformed_vertices.len < mesh.vertices.len) return;

    const tri_limit = @min(mesh.triangles.len, @as(usize, 2));
    var mask: u8 = 0;

    const TriDebug = struct {
        index: usize,
        mask: u8,
        z: [3]f32,
        dot: ?f32,
        front: [3]bool,
        crosses: bool,
    };

    var tri_debug: [2]TriDebug = undefined;
    var tri_debug_count: usize = 0;

    var tri_idx: usize = 0;
    while (tri_idx < tri_limit) : (tri_idx += 1) {
        const tri = mesh.triangles[tri_idx];
        const p0 = transformed_vertices[tri.v0];
        const p1 = transformed_vertices[tri.v1];
        const p2 = transformed_vertices[tri.v2];

        const front0 = p0.z >= NEAR_CLIP - NEAR_EPSILON;
        const front1 = p1.z >= NEAR_CLIP - NEAR_EPSILON;
        const front2 = p2.z >= NEAR_CLIP - NEAR_EPSILON;

        var tri_mask: u8 = 0;

        if (!front0 or !front1 or !front2) {
            tri_mask |= GroundReason.near_plane;
        }

        const crosses_near = (front0 or front1 or front2) and !(front0 and front1 and front2);
        if (crosses_near) tri_mask |= GroundReason.cross_near;
        var dot_value: ?f32 = null;

        if (!crosses_near) {
            const normal = mesh.normals[tri_idx];
            const normal_transformed_raw = math.Vec3.new(
                transform.data[0] * normal.x + transform.data[1] * normal.y + transform.data[2] * normal.z,
                transform.data[4] * normal.x + transform.data[5] * normal.y + transform.data[6] * normal.z,
                transform.data[8] * normal.x + transform.data[9] * normal.y + transform.data[10] * normal.z,
            );
            const normal_transformed = normal_transformed_raw.normalize();

            const centroid = math.Vec3.scale(math.Vec3.add(math.Vec3.add(p0, p1), p2), 1.0 / 3.0);
            const view_dir = math.Vec3.scale(centroid, -1.0);
            const view_dir_len = math.Vec3.length(view_dir);
            if (view_dir_len > 1e-6) {
                const view_vector = math.Vec3.scale(view_dir, 1.0 / view_dir_len);
                const view_dot = normal_transformed.dot(view_vector);
                dot_value = view_dot;
                if (view_dot < -1e-4) tri_mask |= GroundReason.backface;
            }
        }

        if (tri_mask != 0 and tri_debug_count < tri_debug.len) {
            tri_debug[tri_debug_count] = TriDebug{
                .index = tri_idx,
                .mask = tri_mask,
                .z = .{ p0.z, p1.z, p2.z },
                .dot = dot_value,
                .front = .{ front0, front1, front2 },
                .crosses = crosses_near,
            };
            tri_debug_count += 1;
        }

        mask |= tri_mask;
    }

    renderer.ground_debug.frames_since_log += 1;
    const first_frame = renderer.frame_count == 0;
    const should_log = first_frame or mask != renderer.ground_debug.last_mask or (mask != 0 and renderer.ground_debug.frames_since_log >= 60);
    if (!should_log) return;

    renderer.ground_debug.frames_since_log = 0;
    renderer.ground_debug.last_mask = mask;

    if (mask == 0) {
        ground_logger.debug("ground plane visible (frame {})", .{renderer.frame_count});
        return;
    }

    for (tri_debug[0..tri_debug_count]) |info| {
        if (info.dot) |d| {
            ground_logger.debug(
                "ground tri {} issue mask {b:0>3} z[{d:.3},{d:.3},{d:.3}] front[{},{},{}] crosses={} dot={d:.4}",
                .{
                    info.index,
                    info.mask,
                    info.z[0],
                    info.z[1],
                    info.z[2],
                    info.front[0],
                    info.front[1],
                    info.front[2],
                    info.crosses,
                    d,
                },
            );
        } else {
            ground_logger.debug(
                "ground tri {} issue mask {b:0>3} z[{d:.3},{d:.3},{d:.3}] front[{},{},{}] crosses={} dot=n/a",
                .{
                    info.index,
                    info.mask,
                    info.z[0],
                    info.z[1],
                    info.z[2],
                    info.front[0],
                    info.front[1],
                    info.front[2],
                    info.crosses,
                },
            );
        }
    }
}