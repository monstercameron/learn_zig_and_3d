const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const cpu_features = @import("../../core/cpu_features.zig");
const log = @import("../../core/log.zig");
const job_system_module = @import("job_system");
const post_dispatch = @import("post_dispatch.zig");
const present_state = @import("../present/state.zig");
const bloom_pass = @import("../passes/bloom_pass.zig");
const max_render_passes = renderer_module.max_render_passes;
const buildBlockbusterGradeProfile = Renderer.buildBlockbusterGradeProfile;
const TemporalAAViewState = renderer_module.TemporalAAViewState;
const NEAR_CLIP = renderer_module.NEAR_CLIP;
const HybridShadowCasterBounds = renderer_module.HybridShadowCasterBounds;
const hybrid_shadow_grid_cells = renderer_module.hybrid_shadow_grid_cells;
const hybrid_shadow_grid_dim = renderer_module.hybrid_shadow_grid_dim;
const INVALID_PROJECTED_COORD = renderer_module.INVALID_PROJECTED_COORD;
const ProjectionParams = renderer_module.ProjectionParams;
const Mesh = renderer_module.Mesh;
const initLightInfo = Renderer.initLightInfo;
const defaultLightColor = Renderer.defaultLightColor;
const defaultLightShadowMode = Renderer.defaultLightShadowMode;
const Job = job_system_module.Job;
const JobSystem = job_system_module.JobSystem;
const renderer_module = @import("../renderer.zig");
const Bitmap = @import("../../assets/bitmap.zig").Bitmap;
const TileRenderer = @import("../core/tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const AdaptiveShadowTileJob = renderer_module.AdaptiveShadowTileJob;
const HybridShadowTileRange = renderer_module.HybridShadowTileRange;
const LightInfo = renderer_module.LightInfo;
const LightSoA = renderer_module.LightSoA;
const TileLightRange = renderer_module.TileLightRange;
const FrameViewCache = renderer_module.FrameViewCache;
const HybridShadowDebugState = renderer_module.HybridShadowDebugState;
const HybridShadowGrid = renderer_module.HybridShadowGrid;
const LoadingOverlayState = renderer_module.LoadingOverlayState;
const LightGizmoState = renderer_module.LightGizmoState;
const SSGIJobContext = renderer_module.SSGIJobContext;
const SSRJobContext = renderer_module.SSRJobContext;
const AOJobContext = renderer_module.AOJobContext;
const AOScratch = renderer_module.AOScratch;
const BloomJobContext = renderer_module.BloomJobContext;
const SkyboxJobContext = @import("scene_dispatch.zig").SkyboxJobContext;
const TAAJobContext = renderer_module.TAAJobContext;
const CompositeJobContext = renderer_module.CompositeJobContext;
const ShadowResolveJobContext = renderer_module.ShadowResolveJobContext;
const ShadowRasterJobContext = renderer_module.ShadowRasterJobContext;
const DepthOfFieldJobContext = renderer_module.DepthOfFieldJobContext;
const ColorGradeJobContext = renderer_module.ColorGradeJobContext;
const ColorGradeProfile = renderer_module.ColorGradeProfile;
const ShadowMap = renderer_module.ShadowMap;
const ShadowResolveConfig = renderer_module.ShadowResolveConfig;
const DepthFogConfig = renderer_module.DepthFogConfig;
const RenderPassTiming = renderer_module.RenderPassTiming;
const HybridShadowStats = renderer_module.HybridShadowStats;
const LightWorkStats = renderer_module.LightWorkStats;
const MeshletTelemetry = renderer_module.MeshletTelemetry;

const BinningStage = @import("../core/tile_binning.zig");
const shadow_system = @import("../core/shadow_system.zig");
const lighting = @import("../core/lighting.zig");
const meshlet_builder = @import("../core/meshlets/meshlet_builder.zig");
const meshlet_cache = @import("../core/meshlets/meshlet_cache.zig");
const direct_backend = @import("../backends/direct_backend.zig");
const present_d3d11 = @import("../present/present_d3d11.zig");
const frame_pacing = @import("../frame/pacing.zig");
const frame_pacing_hud = @import("../frame/pacing_hud.zig");

const Renderer = renderer_module.Renderer;
const renderer_logger = renderer_module.renderer_logger;

const windows = std.os.windows;
const CreateCompatibleDC = renderer_module.CreateCompatibleDC;
const DeleteDC = renderer_module.DeleteDC;
const SelectObject = renderer_module.SelectObject;
const CreateWaitableTimerExW = renderer_module.CreateWaitableTimerExW;
const TIMER_MODIFY_STATE = renderer_module.TIMER_MODIFY_STATE;
const SYNCHRONIZE_ACCESS = renderer_module.SYNCHRONIZE_ACCESS;
const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = renderer_module.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION;

/// init initializes Renderer state and returns the configured value.
pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
    var bitmap = try Bitmap.init(width, height);
    errdefer bitmap.deinit();
    const hdc_mem = CreateCompatibleDC(null) orelse return error.MemoryDCCreationFailed;
    errdefer _ = DeleteDC(hdc_mem);
    const hdc_mem_old_bitmap = SelectObject(hdc_mem, bitmap.hbitmap);
    var present_backend = try present_d3d11.Backend.init(hwnd, width, height);
    errdefer present_backend.deinit();
    const current_time = std.time.nanoTimestamp();
    const tile_grid = try TileGrid.init(width, height, allocator);

    const tile_buffers = try allocator.alloc(TileBuffer, tile_grid.tiles.len);
    errdefer allocator.free(tile_buffers);
    for (tile_buffers, tile_grid.tiles) |*buf, *tile| {
        buf.* = try TileBuffer.init(tile.width, tile.height, allocator);
    }

    const tile_count = tile_grid.tiles.len;
    const shadow_chunk_job_capacity = tile_count * 4;
    const shadow_tile_jobs_buffer = try allocator.alloc(AdaptiveShadowTileJob, tile_count);
    errdefer allocator.free(shadow_tile_jobs_buffer);
    const hybrid_shadow_tile_ranges = try allocator.alloc(HybridShadowTileRange, tile_count);
    errdefer allocator.free(hybrid_shadow_tile_ranges);
    const job_buffer = try allocator.alloc(Job, tile_count);
    errdefer allocator.free(job_buffer);
    const shadow_job_buffer = try allocator.alloc(Job, shadow_chunk_job_capacity);
    errdefer allocator.free(shadow_job_buffer);
    const composite_job_contexts = try allocator.alloc(CompositeJobContext, tile_count);
    errdefer allocator.free(composite_job_contexts);
    const job_completion_buffer = try allocator.alloc(bool, tile_count);
    errdefer allocator.free(job_completion_buffer);
    @memset(job_completion_buffer, false);
    const tile_triangle_lists = try BinningStage.createTileTriangleLists(&tile_grid, allocator);
    errdefer BinningStage.freeTileTriangleLists(tile_triangle_lists, allocator);
    const active_tile_flags = try allocator.alloc(bool, tile_count);
    errdefer allocator.free(active_tile_flags);
    @memset(active_tile_flags, false);
    const active_tile_indices = try allocator.alloc(usize, tile_count);
    errdefer allocator.free(active_tile_indices);
    const tile_light_ranges = try allocator.alloc(TileLightRange, tile_count);
    errdefer allocator.free(tile_light_ranges);
    @memset(tile_light_ranges, .{});

    const job_system = try JobSystem.init(allocator);
    const color_grade_job_count = @max(@as(usize, 1), @as(usize, @intCast(job_system.worker_count * 2)));
    const color_grade_job_contexts = try allocator.alloc(ColorGradeJobContext, color_grade_job_count);
    errdefer allocator.free(color_grade_job_contexts);
    const moblur_job_contexts = try allocator.alloc(post_dispatch.MotionBlurJobContext, color_grade_job_count);
    errdefer allocator.free(moblur_job_contexts);
    const moblur_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(moblur_scratch_pixels);

    const god_rays_job_contexts = try allocator.alloc(post_dispatch.GodRaysJobContext, color_grade_job_count);
    errdefer allocator.free(god_rays_job_contexts);
    const god_rays_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(god_rays_scratch_pixels);

    const chromatic_aberration_job_contexts = try allocator.alloc(post_dispatch.ChromaticAberrationJobContext, color_grade_job_count);
    errdefer allocator.free(chromatic_aberration_job_contexts);

    const film_grain_job_contexts = try allocator.alloc(post_dispatch.FilmGrainVignetteJobContext, color_grade_job_count);
    errdefer allocator.free(film_grain_job_contexts);

    const lens_flare_job_contexts = try allocator.alloc(post_dispatch.LensFlareJobContext, color_grade_job_count);
    errdefer allocator.free(lens_flare_job_contexts);
    const lens_flare_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(lens_flare_scratch_pixels);
    const ao_job_contexts = try allocator.alloc(AOJobContext, color_grade_job_count);
    errdefer allocator.free(ao_job_contexts);
    const skybox_job_contexts = try allocator.alloc(SkyboxJobContext, color_grade_job_count);
    errdefer allocator.free(skybox_job_contexts);
    const taa_job_contexts = try allocator.alloc(TAAJobContext, color_grade_job_count);
    errdefer allocator.free(taa_job_contexts);
    const shadow_resolve_job_contexts = try allocator.alloc(ShadowResolveJobContext, color_grade_job_count);
    errdefer allocator.free(shadow_resolve_job_contexts);
    const shadow_raster_job_contexts = try allocator.alloc(ShadowRasterJobContext, color_grade_job_count);
    errdefer allocator.free(shadow_raster_job_contexts);
    const bloom_job_contexts = try allocator.alloc(BloomJobContext, color_grade_job_count);
    errdefer allocator.free(bloom_job_contexts);
    const fb_pix_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    const dof_scratch_pixels = try allocator.alloc(u32, fb_pix_count);
    errdefer allocator.free(dof_scratch_pixels);
    const ssr_scratch_pixels = try allocator.alloc(u32, fb_pix_count);
    errdefer allocator.free(ssr_scratch_pixels);
    const ssgi_scratch_pixels = try allocator.alloc(u32, fb_pix_count);
    errdefer allocator.free(ssgi_scratch_pixels);
    const ssgi_job_contexts = try allocator.alloc(SSGIJobContext, color_grade_job_count);
    errdefer allocator.free(ssgi_job_contexts);
    const dof_job_contexts = try allocator.alloc(DepthOfFieldJobContext, color_grade_job_count);
    const ssr_job_contexts = try allocator.alloc(SSRJobContext, color_grade_job_count);
    errdefer allocator.free(ssr_job_contexts);
    errdefer allocator.free(dof_job_contexts);
    const color_grade_jobs = try allocator.alloc(Job, color_grade_job_count);
    errdefer allocator.free(color_grade_jobs);
    const scene_depth = try allocator.alignedAlloc(f32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_depth);
    const scene_camera = try allocator.alignedAlloc(math.Vec3, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_camera);
    const scene_normal = try allocator.alignedAlloc(math.Vec3, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_normal);
    const scene_surface = try allocator.alignedAlloc(TileRenderer.SurfaceHandle, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_surface);
    const scene_base_color = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_base_color);
    const scene_material = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_material);
    // The deferred rasterizer hot loop skips per-pixel material writes
    // (it would be a constant store), so prime the buffer to the
    // default material once. PBR reads roughness/metallic from these
    // bytes. Layout: byte0=roughness, byte1=metallic, byte2=ao, byte3=id.
    @memset(scene_material, 0x00_FF_00_30);
    const scene_hdr = try allocator.alignedAlloc(math.Vec4, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(scene_hdr);
    const hdr_bloom_pass = @import("../passes/hdr_bloom_pass.zig");
    const bloom_w_i = @max(@as(i32, 1), @divTrunc(width + hdr_bloom_pass.DOWNSAMPLE - 1, hdr_bloom_pass.DOWNSAMPLE));
    const bloom_h_i = @max(@as(i32, 1), @divTrunc(height + hdr_bloom_pass.DOWNSAMPLE - 1, hdr_bloom_pass.DOWNSAMPLE));
    const bloom_pixel_count_v4 = @as(usize, @intCast(bloom_w_i)) * @as(usize, @intCast(bloom_h_i));
    const bloom_hdr_ping = try allocator.alignedAlloc(math.Vec4, std.mem.Alignment.@"64", bloom_pixel_count_v4);
    errdefer allocator.free(bloom_hdr_ping);
    const bloom_hdr_pong = try allocator.alignedAlloc(math.Vec4, std.mem.Alignment.@"64", bloom_pixel_count_v4);
    errdefer allocator.free(bloom_hdr_pong);
    // Plain alloc (not alignedAlloc) — the renderer's []f32 field would
    // drop alignment metadata, causing the GPA's free-alignment check
    // to panic later. The pyramid is scalar-accessed; no SIMD load.
    const hiz_pyramid = try allocator.alloc(f32, tile_count);
    errdefer allocator.free(hiz_pyramid);
    @memset(hiz_pyramid, std.math.inf(f32));
    const taa_history_pixels = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(taa_history_pixels);
    const taa_resolve_pixels = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(taa_resolve_pixels);
    const taa_history_depth = try allocator.alignedAlloc(f32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(taa_history_depth);
    const taa_history_surface_tags = try allocator.alignedAlloc(u64, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(taa_history_surface_tags);
    const taa_history_normals = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer allocator.free(taa_history_normals);
    const hybrid_shadow_coarse_downsample = @max(1, config.POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE);
    const hybrid_shadow_coarse_cache_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + hybrid_shadow_coarse_downsample - 1, hybrid_shadow_coarse_downsample))));
    const hybrid_shadow_coarse_cache_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + hybrid_shadow_coarse_downsample - 1, hybrid_shadow_coarse_downsample))));
    const hybrid_shadow_coarse_cache = try allocator.alloc(u8, hybrid_shadow_coarse_cache_width * hybrid_shadow_coarse_cache_height);
    errdefer allocator.free(hybrid_shadow_coarse_cache);
    const hybrid_shadow_edge_downsample = @max(1, config.POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE);
    const hybrid_shadow_edge_cache_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + hybrid_shadow_edge_downsample - 1, hybrid_shadow_edge_downsample))));
    const hybrid_shadow_edge_cache_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + hybrid_shadow_edge_downsample - 1, hybrid_shadow_edge_downsample))));
    const hybrid_shadow_edge_cache = try allocator.alloc(u8, hybrid_shadow_edge_cache_width * hybrid_shadow_edge_cache_height);
    errdefer allocator.free(hybrid_shadow_edge_cache);
    var lights = std.ArrayList(LightInfo){};
    for (0..2) |light_idx| {
        try lights.append(allocator, try initLightInfo(allocator, light_idx));
    }
    const light_dir_x = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_dir_x);
    const light_dir_y = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_dir_y);
    const light_dir_z = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_dir_z);
    const light_dir_cam_x = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_dir_cam_x);
    const light_dir_cam_y = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_dir_cam_y);
    const light_dir_cam_z = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_dir_cam_z);
    const light_distance = try allocator.alloc(f32, lights.items.len);
    errdefer allocator.free(light_distance);
    const light_shadow_mode = try allocator.alloc(u8, lights.items.len);
    errdefer allocator.free(light_shadow_mode);
    for (lights.items, 0..) |light, i| {
        light_dir_x[i] = light.direction.x;
        light_dir_y[i] = light.direction.y;
        light_dir_z[i] = light.direction.z;
        light_dir_cam_x[i] = light.direction.x;
        light_dir_cam_y[i] = light.direction.y;
        light_dir_cam_z[i] = light.direction.z;
        light_distance[i] = light.distance;
        light_shadow_mode[i] = @intFromEnum(light.shadow_mode);
    }
    const shadow_build_elapsed_ns = try allocator.alloc(i128, lights.items.len);
    errdefer allocator.free(shadow_build_elapsed_ns);
    @memset(shadow_build_elapsed_ns, 0);
    const shadow_resolve_elapsed_ns = try allocator.alloc(i128, lights.items.len);
    errdefer allocator.free(shadow_resolve_elapsed_ns);
    @memset(shadow_resolve_elapsed_ns, 0);
    const tile_light_index_capacity = @max(@as(usize, 1), tile_count * lights.items.len);
    const tile_light_indices = try allocator.alloc(usize, tile_light_index_capacity);
    errdefer allocator.free(tile_light_indices);
    const ao_downsample = @max(1, config.POST_SSAO_DOWNSAMPLE);
    const ao_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + ao_downsample - 1, ao_downsample))));
    const ao_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + ao_downsample - 1, ao_downsample))));
    const ao_pixel_count = ao_width * ao_height;
    const ao_ping = try allocator.alloc(u8, ao_pixel_count);
    errdefer allocator.free(ao_ping);
    const ao_pong = try allocator.alloc(u8, ao_pixel_count);
    errdefer allocator.free(ao_pong);
    const ao_depth = try allocator.alloc(f32, ao_pixel_count);
    errdefer allocator.free(ao_depth);
    const bloom_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + 3, 4))));
    const bloom_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + 3, 4))));
    const bloom_pixel_count = bloom_width * bloom_height;
    const bloom_ping = try allocator.alloc(u32, bloom_pixel_count);
    errdefer allocator.free(bloom_ping);
    const bloom_pong = try allocator.alloc(u32, bloom_pixel_count);
    errdefer allocator.free(bloom_pong);

    renderer_logger.infoSub(
        "init",
        "initialized renderer {d}x{d} tiles={} grid={}x{} workers={}",
        .{
            width,
            height,
            tile_count,
            tile_grid.cols,
            tile_grid.rows,
            job_system.worker_count,
        },
    );

    const profile_capture_frame = try parseProfileCaptureFrame(allocator);
    const frame_pacing_timer = createFramePacingTimer();
    const configured_target_frame_time_ns = config.targetFrameTimeNs();
    const pacing_mode = frame_pacing.resolveMode(config.WINDOW_VSYNC, configured_target_frame_time_ns);

    if (config.WINDOW_VSYNC and configured_target_frame_time_ns > 0) {
        renderer_logger.warnSub(
            "pacing",
            "vsync=true with fps_limit={} keeps compositor pacing active; software cap is disabled",
            .{config.TARGET_FPS},
        );
    } else {
        renderer_logger.infoSub(
            "pacing",
            "mode={s} target_fps={} target_ms={d:.3}",
            .{
                pacing_mode.label(),
                config.TARGET_FPS,
                if (configured_target_frame_time_ns > 0)
                    @as(f32, @floatFromInt(configured_target_frame_time_ns)) / 1_000_000.0
                else
                    @as(f32, 0.0),
            },
        );
    }

    return Renderer{
        .hwnd = hwnd,
        .bitmap = bitmap,
        .hdc_mem = hdc_mem,
        .hdc_mem_old_bitmap = hdc_mem_old_bitmap,
        .present_backend = present_backend,
        .allocator = allocator,
        .rotation_angle = 0,
        .rotation_x = 0,
        .camera_position = math.Vec3.new(0.0, 1.5, -5.0),
        .camera_move_speed = 6.0,
        .mouse_state = .{
            .sensitivity = config.CAMERA_MOUSE_SENSITIVITY,
        },
        .mouse_input = .{},
        .fps_body_state = .{},
        .lights = lights,
        .light_soa = .{
            .dir_x = light_dir_x,
            .dir_y = light_dir_y,
            .dir_z = light_dir_z,
            .dir_cam_x = light_dir_cam_x,
            .dir_cam_y = light_dir_cam_y,
            .dir_cam_z = light_dir_cam_z,
            .distance = light_distance,
            .shadow_mode = light_shadow_mode,
        },
        .shadow_build_elapsed_ns = shadow_build_elapsed_ns,
        .shadow_resolve_elapsed_ns = shadow_resolve_elapsed_ns,
        .sys_shadows = shadow_system.ShadowSystem.init(allocator),
        .camera_fov_deg = config.CAMERA_FOV_INITIAL,
        .keys_pressed = .{},
        .frame_count = 0,
        .total_frames_rendered = 0,
        .last_time = current_time,
        .last_frame_time = current_time,
        .next_frame_time = current_time,
        .last_completed_frame_time = current_time,
        .current_frame_start_time = current_time,
        .current_fps = 0,
        .target_frame_time_ns = configured_target_frame_time_ns,
        .frame_pacing_timer = frame_pacing_timer,
        .last_brightness_min = 0,
        .last_brightness_max = 0,
        .last_brightness_avg = 0,
        .last_reported_fov_deg = config.CAMERA_FOV_INITIAL,
        .light_marker_visible_last_frame = true,
        .pending_fov_delta = 0.0,
        .profile_capture_frame = profile_capture_frame,
        .profile_capture_emitted = false,
        .tile_grid = tile_grid,
        .tile_buffers = tile_buffers,
        .single_texture_binding = .{null},
        .textures = &.{},
        .use_tiled_rendering = true,
        .job_system = job_system,
        .shadow_tile_jobs_buffer = shadow_tile_jobs_buffer,
        .job_buffer = job_buffer,
        .shadow_job_buffer = shadow_job_buffer,
        .composite_job_contexts = composite_job_contexts,
        .job_completion_buffer = job_completion_buffer,
        .tile_triangle_lists = tile_triangle_lists,
        .active_tile_flags = active_tile_flags,
        .active_tile_indices = active_tile_indices,
        .tile_light_ranges = tile_light_ranges,
        .tile_light_indices = tile_light_indices,
        .direct_backend = direct_backend.State.init(allocator),
        .present_state = present_state.State.init(width, height),
        .render_pass_timings = [_]RenderPassTiming{.{
            .name = "",
            .frame_duration_ms = 0.0,
            .accumulated_ms = 0.0,
            .sampled_ms_per_frame = 0.0,
            .has_sample = false,
        }} ** max_render_passes,
        .render_pass_count = 0,
        .color_grade_profile = buildBlockbusterGradeProfile(),
        .ambient_occlusion_config = .{
            .downsample = @intCast(ao_downsample),
            .radius = config.POST_SSAO_RADIUS,
            .strength = @as(f32, @floatFromInt(config.POST_SSAO_STRENGTH_PERCENT)) / 100.0,
            .bias = config.POST_SSAO_BIAS,
            .blur_depth_threshold = config.POST_SSAO_BLUR_DEPTH_THRESHOLD,
        },
        .temporal_aa_config = .{
            .history_weight = @as(f32, @floatFromInt(config.POST_TAA_HISTORY_PERCENT)) / 100.0,
            .depth_threshold = config.POST_TAA_DEPTH_THRESHOLD,
        },
        .depth_fog_config = .{
            .near = config.POST_DEPTH_FOG_NEAR,
            .far = config.POST_DEPTH_FOG_FAR,
            .inv_range = 1.0 / @max(0.001, config.POST_DEPTH_FOG_FAR - config.POST_DEPTH_FOG_NEAR),
            .strength = @as(f32, @floatFromInt(config.POST_DEPTH_FOG_STRENGTH_PERCENT)) / 100.0,
            .color_r = config.POST_DEPTH_FOG_COLOR_R,
            .color_g = config.POST_DEPTH_FOG_COLOR_G,
            .color_b = config.POST_DEPTH_FOG_COLOR_B,
        },
        .scene_depth = scene_depth,
        .scene_camera = scene_camera,
        .scene_normal = scene_normal,
        .scene_surface = scene_surface,
        .scene_base_color = scene_base_color,
        .scene_material = scene_material,
        .scene_hdr = scene_hdr,
        .bloom_hdr_ping = bloom_hdr_ping,
        .bloom_hdr_pong = bloom_hdr_pong,
        .bloom_hdr_width = bloom_w_i,
        .bloom_hdr_height = bloom_h_i,
        .hiz_pyramid = hiz_pyramid,
        .taa_scratch = .{
            .history_pixels = taa_history_pixels,
            .resolve_pixels = taa_resolve_pixels,
            .history_depth = taa_history_depth,
            .history_surface_tags = taa_history_surface_tags,
            .history_normals = taa_history_normals,
            .valid = false,
        },
        .taa_previous_view = TemporalAAViewState.init(
            math.Vec3.new(0.0, 1.5, -5.0),
            math.Vec3.new(1.0, 0.0, 0.0),
            math.Vec3.new(0.0, 1.0, 0.0),
            math.Vec3.new(0.0, 0.0, 1.0),
            .{
                .center_x = 0.0,
                .center_y = 0.0,
                .x_scale = 1.0,
                .y_scale = 1.0,
                .near_plane = NEAR_CLIP,
                .jitter_x = 0.0,
                .jitter_y = 0.0,
            },
        ),
        .taa_previous_mesh_vertices = &[_]math.Vec3{},
        .taa_previous_mesh_vertex_count = 0,
        .taa_previous_mesh_triangle_count = 0,
        .taa_previous_mesh_valid = false,
        .hybrid_shadow_coarse_cache = hybrid_shadow_coarse_cache,
        .hybrid_shadow_coarse_cache_width = hybrid_shadow_coarse_cache_width,
        .hybrid_shadow_coarse_cache_height = hybrid_shadow_coarse_cache_height,
        .hybrid_shadow_edge_cache = hybrid_shadow_edge_cache,
        .hybrid_shadow_edge_cache_width = hybrid_shadow_edge_cache_width,
        .hybrid_shadow_edge_cache_height = hybrid_shadow_edge_cache_height,
        .hybrid_shadow_caster_indices = &[_]usize{},
        .hybrid_shadow_caster_bounds = &[_]HybridShadowCasterBounds{},
        .hybrid_shadow_caster_count = 0,
        .hybrid_shadow_tile_ranges = hybrid_shadow_tile_ranges,
        .hybrid_shadow_tile_candidates = &[_]usize{},
        .hybrid_shadow_grid = .{},
        .hybrid_shadow_grid_ranges = [_]HybridShadowTileRange{.{}} ** hybrid_shadow_grid_cells,
        .hybrid_shadow_grid_candidates = &[_]usize{},
        .hybrid_shadow_candidate_marks = &[_]u32{},
        .hybrid_shadow_candidate_mark_generation = 0,
        .hybrid_shadow_accel_valid = false,
        .hybrid_shadow_cached_light_dir = math.Vec3.new(0.0, 0.0, 0.0),
        .hybrid_shadow_cached_meshlet_count = 0,
        .hybrid_shadow_cached_meshlet_vertex_count = 0,
        .hybrid_shadow_cached_meshlet_primitive_count = 0,
        .hybrid_shadow_stats = .{},
        .meshlet_ray_tests_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_chunk_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_chunk_pixels_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_chunk_active_rays_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_packet_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_packet_skipped_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_packet_active_lanes_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_packet_occluded_lanes_counter = std.atomic.Value(usize).init(0),
        .meshlet_shadow_trace_ns_counter = std.atomic.Value(u64).init(0),
        .meshlet_shadow_apply_ns_counter = std.atomic.Value(u64).init(0),
        .triangles_rasterized_counter = std.atomic.Value(usize).init(0),
        .covered_pixels_counter = std.atomic.Value(usize).init(0),
        .depth_tests_passed_counter = std.atomic.Value(usize).init(0),
        .alpha_pixels_counter = std.atomic.Value(usize).init(0),
        .hybrid_shadow_debug = .{},
        .ao_scratch = .{
            .width = ao_width,
            .height = ao_height,
            .ping = ao_ping,
            .pong = ao_pong,
            .depth = ao_depth,
        },
        .bloom_scratch = .{
            .width = bloom_width,
            .height = bloom_height,
            .ping = bloom_ping,
            .pong = bloom_pong,
        },
        .ao_job_contexts = ao_job_contexts,
        .bloom_threshold_curve = bloom_pass.buildThresholdCurve(config.POST_BLOOM_THRESHOLD),
        .bloom_intensity_lut = bloom_pass.buildIntensityLut(config.POST_BLOOM_INTENSITY_PERCENT),
        .skybox_job_contexts = skybox_job_contexts,
        .shadow_resolve_job_contexts = shadow_resolve_job_contexts,
        .shadow_raster_job_contexts = shadow_raster_job_contexts,
        .bloom_job_contexts = bloom_job_contexts,
        .dof_scratch = .{ .pixels = dof_scratch_pixels, .width = @intCast(width), .height = @intCast(height) },
        .dof_job_contexts = dof_job_contexts,
        .ssr_job_contexts = ssr_job_contexts,
        .ssr_scratch_pixels = ssr_scratch_pixels,
        .ssgi_scratch_pixels = ssgi_scratch_pixels,
        .ssgi_job_contexts = ssgi_job_contexts,
        .dof_focal_distance = config.POST_DOF_FOCAL_DISTANCE,
        .dof_target_focal_distance = config.POST_DOF_FOCAL_DISTANCE,
        .taa_job_contexts = taa_job_contexts,
        .color_grade_job_contexts = color_grade_job_contexts,
        .moblur_job_contexts = moblur_job_contexts,
        .moblur_scratch_pixels = moblur_scratch_pixels,
        .god_rays_job_contexts = god_rays_job_contexts,
        .god_rays_scratch_pixels = god_rays_scratch_pixels,
        .chromatic_aberration_job_contexts = chromatic_aberration_job_contexts,
        .film_grain_job_contexts = film_grain_job_contexts,
        .lens_flare_job_contexts = lens_flare_job_contexts,
        .lens_flare_scratch_pixels = lens_flare_scratch_pixels,
        .color_grade_jobs = color_grade_jobs,
    };
}

/// Parses p ar se pr of il ec ap tu re fr am e into typed runtime values.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn parseProfileCaptureFrame(allocator: std.mem.Allocator) !u64 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_PROFILE_FRAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return 0,
        else => return err,
    };
    defer allocator.free(raw_value);
    return std.fmt.parseUnsigned(u64, raw_value, 10) catch 0;
}

/// createFramePacingTimer creates a new value used by Renderer.
fn createFramePacingTimer() ?windows.HANDLE {
    const desired_access = TIMER_MODIFY_STATE | SYNCHRONIZE_ACCESS;
    return CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, desired_access) orelse
        CreateWaitableTimerExW(null, null, 0, desired_access);
}