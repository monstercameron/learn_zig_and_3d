const std = @import("std");
const job_system = @import("job_system");
const app_config = @import("../../core/app_config.zig");
const obj_loader = @import("../../assets/obj_loader.zig");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_batch = @import("../direct/batch.zig");
const direct_draw_list = @import("../direct/draw_list.zig");
const direct_mesh = @import("../direct/mesh.zig");
const direct_scene_packets = @import("../direct/scene_packets.zig");
const direct_meshlets = @import("../direct/meshlets.zig");
const direct_primitives = @import("../direct/primitives.zig");
const gouraud_kernel = @import("../kernels/gouraud_kernel.zig");
const frame_resources = @import("../frame/resources.zig");
const frame_setup_stage = @import("../stages/frame_setup_stage.zig");
const scene_submission_stage = @import("../stages/scene_submission_stage.zig");
const visibility_culling_stage = @import("../stages/visibility_culling_stage.zig");
const primitive_expansion_stage = @import("../stages/primitive_expansion_stage.zig");
const screen_binning_stage = @import("../stages/screen_binning_stage.zig");
const rasterization_stage = @import("../stages/rasterization_stage.zig");
const shading_stage = @import("../stages/shading_stage.zig");
const hdr_post_stage = @import("../stages/hdr_post_stage.zig");
const hdr_bloom_pass = @import("../passes/hdr_bloom_pass.zig");
const hiz_stage = @import("../stages/hiz_stage.zig");
const screen_post_stage = @import("../stages/screen_post_stage.zig");
const composition_stage = @import("../stages/composition_stage.zig");
const post_process_stage = @import("../stages/post_process_stage.zig");
const visible_scene = @import("../scene/visible.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const RenderConfig = struct {
    raster_mode: rasterization_stage.RasterMode = .single_thread,
    scene_kind: scene_submission_stage.SceneKind = .triangle,
};

pub const SceneMeshConfig = struct {
    raster_mode: rasterization_stage.RasterMode = .worker_tiles,
    transform: @import("../../core/math.zig").Mat4 = @import("../../core/math.zig").Mat4.identity(),
    material_override: ?direct_batch.SurfaceMaterial = .{
        .fill_color = 0xFFD8C3A5,
        .outline_color = null,
        .depth = 1.0,
    },
    clear_color: u32 = 0xFF0B1220,
    enable_shading: bool = true,
    /// Deferred lighting override. When null the default lighting config
    /// (a baked camera-space key light) is used. backend_glue populates
    /// this from the scene's actual primary light so the deferred shade
    /// matches the visible light source. (ROADMAP §H6.)
    deferred_lighting: ?shading_stage.DeferredConfig = null,
};

pub const FrameTimings = struct {
    clear_ns: i128 = 0,
    build_batch_ns: i128 = 0,
    compile_draw_list_ns: i128 = 0,
    binning_ns: i128 = 0,
    raster_ns: i128 = 0,
    shading_ns: i128 = 0,
    lighting_ns: i128 = 0, // Deferred lighting pass (ROADMAP §H4).
    hdr_post_ns: i128 = 0, // HDR post-process slot (ROADMAP §H6).
    tonemap_ns: i128 = 0, // HDR -> LDR tone-map pass (ROADMAP §H5).
    composition_ns: i128 = 0,
    post_process_ns: i128 = 0,
    present_ns: i128 = 0,
    primitive_count: usize = 0,
    touched_tiles: usize = 0,
    lit_pixel_count: usize = 0, // Pixels shaded by the deferred lighting stage.
    tonemapped_pixel_count: usize = 0, // Pixels processed by the tone-map stage.
    hdr_avg_luminance: f32 = 0.0, // Mean linear luminance over lit pixels.
    hdr_max_luminance: f32 = 0.0, // Peak linear luminance over lit pixels.
    tonemap_exposure: f32 = 1.0, // Auto-exposure multiplier applied this frame.
    bloom_ns: i128 = 0, // HDR bloom pass time (ROADMAP §H6).
    bloom_bright_pixels: usize = 0, // Downsampled bright-pass cell count.
    hiz_build_ns: i128 = 0, // Hi-Z pyramid build cost (ROADMAP §H7).
    hiz_tile_count: usize = 0, // Tiles in the Hi-Z pyramid.
};

pub const State = struct {
    allocator: std.mem.Allocator,
    scene_packets: direct_scene_packets.PacketList,
    visible_scene: visible_scene.VisibleScene,
    batch: direct_batch.PrimitiveBatch,
    draw_list: direct_draw_list.DrawList,
    showcase_mesh: direct_meshlets.Mesh,
    suzanne_mesh: direct_mesh.Mesh,
    visible_meshlets: direct_meshlets.VisibleMeshlets,
    tile_counts: std.ArrayListUnmanaged(usize) = .{},
    tile_cursors: std.ArrayListUnmanaged(usize) = .{},
    tile_ranges: std.ArrayListUnmanaged(screen_binning_stage.TileRange) = .{},
    tile_command_indices: std.ArrayListUnmanaged(usize) = .{},
    tile_spans: std.ArrayListUnmanaged(?screen_binning_stage.TileSpan) = .{},
    cached_prepared_tile_ranges: std.ArrayListUnmanaged(screen_binning_stage.TileRange) = .{},
    cached_prepared_tile_counts: std.ArrayListUnmanaged(usize) = .{},
    cached_prepared_triangles: std.ArrayListUnmanaged(direct_primitives.Triangle2i) = .{},
    cached_prepared_setups: std.ArrayListUnmanaged(direct_primitives.PreparedGouraudTriangle) = .{},
    cached_prepared_depths: std.ArrayListUnmanaged(?f32) = .{},
    cached_prepared_vertex_depths: std.ArrayListUnmanaged(?[3]f32) = .{},
    active_tile_indices: std.ArrayListUnmanaged(usize) = .{},
    active_tile_command_counts: std.ArrayListUnmanaged(usize) = .{},
    tile_chunk_jobs: std.ArrayListUnmanaged(Job) = .{},
    tile_chunk_job_contexts: std.ArrayListUnmanaged(rasterization_stage.RasterTileChunkJobContext) = .{},
    /// Per-worker scratch draw lists used by the parallel compile path
    /// (ROADMAP §H6 follow-up: parallelize the projection loop). Sized
    /// to `worker_count + 1` so the main thread and every worker each
    /// have their own output buffer; freed in deinit.
    compile_chunk_draw_lists: []direct_draw_list.DrawList = &.{},
    /// Static-scene draw-list cache. When the camera + mesh haven't
    /// changed frame-to-frame we skip submission/visibility/expansion/
    /// projection entirely — that's ~60 ms saved on the 1.5M-tri
    /// scenes (acura/wolf). Reset whenever the scene mesh or camera
    /// differs from the cached one.
    cached_scene_mesh: ?*const direct_mesh.Mesh = null,
    cached_scene_camera: ?direct_batch.Camera = null,
    cached_scene_binning: ?screen_binning_stage.Result = null,
    cached_scene_primitive_count: usize = 0,
    /// Last-seen mesh.version. When the mesh was rewritten by physics
    /// (or any other vertex animation), version is bumped upstream
    /// and we cache-miss so the new geometry actually renders.
    cached_scene_mesh_version: u64 = 0,
    present_dirty_rect: ?screen_binning_stage.DirtyRect = null,
    previous_fast_path_bounds: ?direct_primitives.Rect2i = null,
    /// Smoothed average HDR luminance from the previous frame's probe.
    /// Drives auto-exposure on this frame's tone-map pass (ROADMAP §H6).
    auto_exposure_avg_luminance: f32 = 0.0,
    cached_static_scene_valid: bool = false,
    cached_static_scene_kind: scene_submission_stage.SceneKind = .triangle,
    cached_static_width: i32 = 0,
    cached_static_height: i32 = 0,
    cached_static_camera: direct_batch.Camera = .{
        .position = std.mem.zeroes(@import("../../core/math.zig").Vec3),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 0.0,
    },
    cached_static_dirty_rect: ?screen_binning_stage.DirtyRect = null,
    cached_static_primitive_count: usize = 0,
    cached_static_touched_tiles: usize = 0,
    timings: FrameTimings = .{},

    pub fn init(allocator: std.mem.Allocator) State {
        var showcase_mesh = direct_meshlets.Mesh.cube(allocator) catch @panic("cube mesh init failed");
        direct_meshlets.ensureMeshlets(&showcase_mesh, allocator) catch @panic("cube meshlet init failed");
        var suzanne_mesh = obj_loader.load(allocator, "assets/models/suzanne.obj") catch @panic("suzanne obj load failed");
        suzanne_mesh.centerToOrigin();
        return .{
            .allocator = allocator,
            .scene_packets = direct_scene_packets.PacketList.init(allocator),
            .visible_scene = visible_scene.VisibleScene.init(allocator),
            .batch = direct_batch.PrimitiveBatch.init(allocator),
            .draw_list = direct_draw_list.DrawList.init(allocator),
            .showcase_mesh = showcase_mesh,
            .suzanne_mesh = suzanne_mesh,
            .visible_meshlets = direct_meshlets.VisibleMeshlets.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.scene_packets.deinit();
        self.visible_scene.deinit();
        self.batch.deinit();
        self.draw_list.deinit();
        self.showcase_mesh.deinit();
        self.suzanne_mesh.deinit();
        self.visible_meshlets.deinit();
        self.tile_counts.deinit(self.allocator);
        self.tile_cursors.deinit(self.allocator);
        self.tile_ranges.deinit(self.allocator);
        self.tile_command_indices.deinit(self.allocator);
        self.tile_spans.deinit(self.allocator);
        self.cached_prepared_tile_ranges.deinit(self.allocator);
        self.cached_prepared_tile_counts.deinit(self.allocator);
        self.cached_prepared_triangles.deinit(self.allocator);
        self.cached_prepared_setups.deinit(self.allocator);
        self.cached_prepared_depths.deinit(self.allocator);
        self.cached_prepared_vertex_depths.deinit(self.allocator);
        self.active_tile_indices.deinit(self.allocator);
        self.active_tile_command_counts.deinit(self.allocator);
        self.tile_chunk_jobs.deinit(self.allocator);
        self.tile_chunk_job_contexts.deinit(self.allocator);
        for (self.compile_chunk_draw_lists) |*dl| dl.deinit();
        self.allocator.free(self.compile_chunk_draw_lists);
        self.* = undefined;
    }

    fn ensureCompileChunkScratch(self: *State, worker_count: usize) !void {
        const want = worker_count + 1;
        if (self.compile_chunk_draw_lists.len >= want) return;
        // Free the old (empty) array if any.
        if (self.compile_chunk_draw_lists.len > 0) {
            for (self.compile_chunk_draw_lists) |*dl| dl.deinit();
            self.allocator.free(self.compile_chunk_draw_lists);
        }
        const slice = try self.allocator.alloc(direct_draw_list.DrawList, want);
        for (slice) |*dl| dl.* = direct_draw_list.DrawList.init(self.allocator);
        self.compile_chunk_draw_lists = slice;
    }

    pub fn notePresentTime(self: *State, present_ns: i128) void {
        self.timings.present_ns = @max(present_ns, @as(i128, 0));
    }

    pub fn lastTimings(self: *const State) FrameTimings {
        return self.timings;
    }

    pub fn lastDirtyRect(self: *const State) ?screen_binning_stage.DirtyRect {
        return self.present_dirty_rect;
    }

    pub fn renderPrimitiveShowcase(
        self: *State,
        resources: frame_resources.FrameResources,
        camera: direct_batch.Camera,
        job_sys: ?*JobSystem,
        config: RenderConfig,
    ) !void {
        const width = resources.target.width;
        const height = resources.target.height;

        const static_cache_hit = canReuseStaticScene(self, config, camera, width, height);
        var raster_plan: rasterization_stage.ExecutionPlan = undefined;
        if (static_cache_hit) {
            self.timings.build_batch_ns = 0;
            self.timings.compile_draw_list_ns = 0;
            self.timings.binning_ns = 0;
            self.timings.primitive_count = self.cached_static_primitive_count;
            self.timings.touched_tiles = self.cached_static_touched_tiles;
            self.present_dirty_rect = self.cached_static_dirty_rect;
            raster_plan = .{
                .mode = .tiled,
                .bounds = null,
                .touched_tiles = self.cached_static_touched_tiles,
            };
        } else {
            const build_start = std.time.nanoTimestamp();
            const submission = try scene_submission_stage.execute(&self.scene_packets, &self.showcase_mesh, &self.suzanne_mesh, config.scene_kind);
            std.debug.assert(submission.packet_count == self.scene_packets.items().len);
            _ = try visibility_culling_stage.execute(&self.scene_packets, &self.visible_scene, &self.visible_meshlets, camera, job_sys);
            const compile_job_system = if (config.raster_mode != .single_thread) job_sys else null;
            const expansion = try primitive_expansion_stage.execute(&self.visible_scene, &self.batch, compile_job_system);
            self.timings.build_batch_ns = @max(std.time.nanoTimestamp() - build_start, @as(i128, 0));
            self.timings.primitive_count = expansion.primitive_count;

            const compile_start = std.time.nanoTimestamp();
            // Forward path bakes Gouraud colours into the batch up front.
            // Deferred path (ROADMAP §H) skips this — lighting moves to a
            // screen-space stage that consumes the G-buffer after raster.
            if (!app_config.DEFERRED_SHADING_ENABLED) {
                gouraud_kernel.applyBatchLighting(&self.batch, .{ .camera_position = camera.position });
            }
            try direct_batch.compileToDrawList(&self.batch, &self.draw_list, camera, width, height);
            self.timings.compile_draw_list_ns = @max(std.time.nanoTimestamp() - compile_start, @as(i128, 0));

            raster_plan = rasterization_stage.analyze(&self.draw_list, .{
                .allow_direct_fast_path = true,
                .width = width,
                .height = height,
                .raster_mode = config.raster_mode,
            });
        }
        self.timings.shading_ns = 0;
        self.timings.composition_ns = 0;
        self.timings.post_process_ns = 0;
        if (raster_plan.mode == .direct) {
            const clear_start = std.time.nanoTimestamp();
            const clear_config = direct_primitives.ClearConfig{
                .color = 0xFF0B1220,
                .depth = null,
            };
            if (raster_plan.bounds) |current_bounds| {
                if (self.previous_fast_path_bounds) |previous_bounds| {
                    direct_primitives.clearRect(resources.target, direct_primitives.unionRect(previous_bounds, current_bounds), clear_config);
                } else {
                    direct_primitives.clear(resources.target, clear_config);
                }
                self.previous_fast_path_bounds = current_bounds;
                self.timings.touched_tiles = raster_plan.touched_tiles;
            } else {
                if (self.previous_fast_path_bounds) |previous_bounds| {
                    direct_primitives.clearRect(resources.target, previous_bounds, clear_config);
                }
                self.previous_fast_path_bounds = null;
                self.timings.touched_tiles = 0;
            }
            self.timings.clear_ns = @max(std.time.nanoTimestamp() - clear_start, @as(i128, 0));
            self.present_dirty_rect = null;
            self.timings.binning_ns = 0;

            const raster_start = std.time.nanoTimestamp();
            _ = rasterization_stage.executeDirect(resources, &self.draw_list);
            self.timings.raster_ns = @max(std.time.nanoTimestamp() - raster_start, @as(i128, 0));
            const shaded_rect = raster_plan.bounds;
            const shading_start = std.time.nanoTimestamp();
            const shading = shading_stage.execute(resources, shaded_rect, .{
                .clear_color = 0xFF0B1220,
                .enabled = config.scene_kind != .perf_showcase,
            }, job_sys);
            self.timings.shading_ns = @max(std.time.nanoTimestamp() - shading_start, @as(i128, 0));

            const composition_start = std.time.nanoTimestamp();
            const composition = composition_stage.execute(resources, shading.shaded_rect, .{
                .clear_color = 0xFF0B1220,
                .background_color = 0xFF0B1220,
                .scene_alpha = 255,
            }, job_sys);
            self.timings.composition_ns = @max(std.time.nanoTimestamp() - composition_start, @as(i128, 0));

            const post_start = std.time.nanoTimestamp();
            const post = post_process_stage.execute(resources, composition.composed_rect, .{
                .clear_color = 0xFF0B1220,
                .enabled = false,
            });
            self.timings.post_process_ns = @max(std.time.nanoTimestamp() - post_start, @as(i128, 0));
            self.present_dirty_rect = if (post.present_rect) |rect| .{
                .min_x = rect.min_x,
                .min_y = rect.min_y,
                .max_x = rect.max_x,
                .max_y = rect.max_y,
            } else null;
            return;
        }

        const previous_dirty_rect = self.present_dirty_rect;
        self.previous_fast_path_bounds = null;

        var binning: screen_binning_stage.Result = undefined;
        if (static_cache_hit) {
            binning = .{
                .tile_cols = @max(@divTrunc(width + TileRenderer.TILE_SIZE - 1, TileRenderer.TILE_SIZE), 1),
                .tile_rows = @max(@divTrunc(height + TileRenderer.TILE_SIZE - 1, TileRenderer.TILE_SIZE), 1),
                .tile_count = @as(usize, @intCast(@max(@divTrunc(width + TileRenderer.TILE_SIZE - 1, TileRenderer.TILE_SIZE), 1) * @max(@divTrunc(height + TileRenderer.TILE_SIZE - 1, TileRenderer.TILE_SIZE), 1))),
                .touched_tiles = self.cached_static_touched_tiles,
                .dirty_rect = self.cached_static_dirty_rect,
            };
        } else {
            const binning_start = std.time.nanoTimestamp();
            binning = try screen_binning_stage.executeParallel(
                self.allocator,
                &self.draw_list,
                width,
                height,
                &self.tile_counts,
                &self.tile_cursors,
                &self.tile_ranges,
                &self.tile_command_indices,
                &self.tile_spans,
                &self.active_tile_indices,
                &self.active_tile_command_counts,
                job_sys,
            );
            self.timings.touched_tiles = binning.touched_tiles;
            self.present_dirty_rect = binning.dirty_rect;
            self.timings.binning_ns = @max(std.time.nanoTimestamp() - binning_start, @as(i128, 0));
            self.updateStaticSceneCache(config, camera, width, height, binning);
        }

        const clear_start = std.time.nanoTimestamp();
        const clear_config = direct_primitives.ClearConfig{
            .color = 0xFF0B1220,
            .depth = if (config.scene_kind == .triangle) null else std.math.inf(f32),
        };
        if (previous_dirty_rect) |previous_rect| {
            if (binning.dirty_rect) |current_rect| {
                direct_primitives.clearRect(resources.target, unionDirtyRects(previous_rect, current_rect), clear_config);
            } else {
                direct_primitives.clearRect(resources.target, dirtyRectToRect(previous_rect), clear_config);
            }
        } else if (binning.dirty_rect) |current_rect| {
            _ = frame_setup_stage.execute(resources, .{
                .clear_color = 0xFF0B1220,
                .clear_depth = clear_config.depth,
                .clear_auxiliary = false,
            });
            self.present_dirty_rect = current_rect;
        } else {
            _ = frame_setup_stage.execute(resources, .{
                .clear_color = 0xFF0B1220,
                .clear_depth = clear_config.depth,
                .clear_auxiliary = false,
            });
        }
        self.timings.clear_ns = @max(std.time.nanoTimestamp() - clear_start, @as(i128, 0));

        const raster_start = std.time.nanoTimestamp();
        const raster = try rasterization_stage.execute(.{
            .allocator = self.allocator,
            .tile_ranges = &self.tile_ranges,
            .tile_command_indices = &self.tile_command_indices,
            .cached_prepared_tile_ranges = if (static_cache_hit) &self.cached_prepared_tile_ranges else null,
            .cached_prepared_tile_counts = if (static_cache_hit) &self.cached_prepared_tile_counts else null,
            .cached_prepared_triangles = if (static_cache_hit) &self.cached_prepared_triangles else null,
            .cached_prepared_setups = if (static_cache_hit) &self.cached_prepared_setups else null,
            .cached_prepared_depths = if (static_cache_hit) &self.cached_prepared_depths else null,
            .cached_prepared_vertex_depths = if (static_cache_hit) &self.cached_prepared_vertex_depths else null,
            .active_tile_indices = &self.active_tile_indices,
            .active_tile_command_counts = &self.active_tile_command_counts,
            .tile_chunk_jobs = &self.tile_chunk_jobs,
            .tile_chunk_job_contexts = &self.tile_chunk_job_contexts,
        }, resources, &self.draw_list, width, height, if (config.raster_mode != .single_thread) job_sys else null, config.raster_mode);
        _ = raster;
        self.timings.raster_ns = @max(std.time.nanoTimestamp() - raster_start, @as(i128, 0));

        const shading_start = std.time.nanoTimestamp();
        const shading = shading_stage.execute(resources, if (binning.dirty_rect) |rect| .{
            .min_x = rect.min_x,
            .min_y = rect.min_y,
            .max_x = rect.max_x,
            .max_y = rect.max_y,
        } else null, .{
            .clear_color = 0xFF0B1220,
            .enabled = config.scene_kind != .perf_showcase,
        }, job_sys);
        self.timings.shading_ns = @max(std.time.nanoTimestamp() - shading_start, @as(i128, 0));

        const composition_start = std.time.nanoTimestamp();
        const composition = composition_stage.execute(resources, shading.shaded_rect, .{
            .clear_color = 0xFF0B1220,
            .background_color = 0xFF0B1220,
            .scene_alpha = 255,
        }, job_sys);
        self.timings.composition_ns = @max(std.time.nanoTimestamp() - composition_start, @as(i128, 0));

        const post_start = std.time.nanoTimestamp();
        const post = post_process_stage.execute(resources, composition.composed_rect, .{
            .clear_color = 0xFF0B1220,
            .enabled = false,
        });
        self.timings.post_process_ns = @max(std.time.nanoTimestamp() - post_start, @as(i128, 0));
        self.present_dirty_rect = if (post.present_rect) |rect| .{
            .min_x = rect.min_x,
            .min_y = rect.min_y,
            .max_x = rect.max_x,
            .max_y = rect.max_y,
        } else null;
    }

    pub fn renderSceneMesh(
        self: *State,
        resources: frame_resources.FrameResources,
        camera: direct_batch.Camera,
        mesh: *const direct_mesh.Mesh,
        job_sys: ?*JobSystem,
        config: SceneMeshConfig,
    ) !void {
        const width = resources.target.width;
        const height = resources.target.height;
        if (width <= 0 or height <= 0 or resources.target.color.len == 0) {
            self.timings = .{};
            return;
        }

        // Static-scene fast path: when the camera and mesh haven't
        // changed since the previous frame, every output of
        // submission/visibility/expansion/projection is identical to
        // last frame's. Reuse self.batch and self.draw_list as-is and
        // skip the 60ms of redundant work. This is the dominant win on
        // the heavy benchmark scenes (acura, wolf) where the user
        // hasn't moved the camera.
        //
        // ZIG_DISABLE_RENDER_CACHE=1 forces every frame through the
        // full pipeline — used for measuring cold-frame stage costs
        // without rebooting the app.
        const cache_disabled = std.process.hasEnvVarConstant("ZIG_DISABLE_RENDER_CACHE");
        const cache_hit = !cache_disabled and
            self.cached_scene_mesh != null and
            self.cached_scene_mesh.? == mesh and
            self.cached_scene_mesh_version == mesh.version and
            self.cached_scene_camera != null and
            sameCamera(self.cached_scene_camera.?, camera) and
            self.draw_list.items().len > 0;

        if (!cache_hit) {
            const build_start = std.time.nanoTimestamp();
            const submission = try scene_submission_stage.executeMeshScene(
                &self.scene_packets,
                mesh,
                config.transform,
                config.material_override,
            );
            std.debug.assert(submission.packet_count == self.scene_packets.items().len);
            _ = try visibility_culling_stage.execute(&self.scene_packets, &self.visible_scene, &self.visible_meshlets, camera, job_sys);
            const compile_job_system = if (config.raster_mode != .single_thread) job_sys else null;
            const expansion = try primitive_expansion_stage.execute(&self.visible_scene, &self.batch, compile_job_system);
            self.timings.build_batch_ns = @max(std.time.nanoTimestamp() - build_start, @as(i128, 0));
            self.timings.primitive_count = expansion.primitive_count;

            const compile_start = std.time.nanoTimestamp();
            // applyBatchLighting bakes vertex_colors that the deferred
            // pipeline never reads (drawPacket bypasses Gouraud in
            // deferred mode). Skip the 1.5M-triangle Gouraud pass when
            // we're going through the G-buffer path.
            if (!app_config.DEFERRED_SHADING_ENABLED) {
                gouraud_kernel.applyBatchLighting(&self.batch, .{ .camera_position = camera.position });
            }
            if (job_sys) |js| {
                try self.ensureCompileChunkScratch(@as(usize, js.worker_count));
                try direct_batch.compileToDrawListParallel(&self.batch, &self.draw_list, camera, width, height, js, self.compile_chunk_draw_lists);
            } else {
                try direct_batch.compileToDrawList(&self.batch, &self.draw_list, camera, width, height);
            }
            self.timings.compile_draw_list_ns = @max(std.time.nanoTimestamp() - compile_start, @as(i128, 0));

            self.cached_scene_mesh = mesh;
            self.cached_scene_mesh_version = mesh.version;
            self.cached_scene_camera = camera;
            self.cached_scene_primitive_count = expansion.primitive_count;
        } else {
            // Cache hit: zero out the build/compile timings since we
            // skipped that work, but keep last frame's primitive_count
            // for telemetry continuity.
            self.timings.build_batch_ns = 0;
            self.timings.compile_draw_list_ns = 0;
            self.timings.primitive_count = self.cached_scene_primitive_count;
        }

        self.timings.shading_ns = 0;
        self.timings.composition_ns = 0;
        self.timings.post_process_ns = 0;
        self.previous_fast_path_bounds = null;
        const previous_dirty_rect = self.present_dirty_rect;

        if (self.draw_list.items().len == 0) {
            const clear_start = std.time.nanoTimestamp();
            if (previous_dirty_rect) |previous_rect| {
                direct_primitives.clearRect(resources.target, dirtyRectToRect(previous_rect), .{
                    .color = config.clear_color,
                    .depth = std.math.inf(f32),
                });
            } else {
                _ = frame_setup_stage.execute(resources, .{
                    .clear_color = config.clear_color,
                    .clear_depth = std.math.inf(f32),
                    .clear_auxiliary = false,
                });
            }
            self.timings.clear_ns = @max(std.time.nanoTimestamp() - clear_start, @as(i128, 0));
            self.timings.binning_ns = 0;
            self.timings.raster_ns = 0;
            self.timings.touched_tiles = 0;
            self.present_dirty_rect = null;
            return;
        }

        const binning_start = std.time.nanoTimestamp();
        var binning: screen_binning_stage.Result = undefined;
        if (cache_hit and self.cached_scene_binning != null) {
            binning = self.cached_scene_binning.?;
            self.timings.binning_ns = 0;
        } else {
            binning = try screen_binning_stage.executeParallel(
                self.allocator,
                &self.draw_list,
                width,
                height,
                &self.tile_counts,
                &self.tile_cursors,
                &self.tile_ranges,
                &self.tile_command_indices,
                &self.tile_spans,
                &self.active_tile_indices,
                &self.active_tile_command_counts,
                job_sys,
            );
            self.timings.binning_ns = @max(std.time.nanoTimestamp() - binning_start, @as(i128, 0));
            self.cached_scene_binning = binning;
        }
        self.timings.touched_tiles = binning.touched_tiles;
        self.present_dirty_rect = binning.dirty_rect;

        // Full-frame skip — on a cache hit we know the inputs haven't
        // changed, so every render output (depth, G-buffer, scene_hdr,
        // target.color) is bit-for-bit identical to last frame's.
        // Skip clear + raster + lighting + bloom + tonemap entirely
        // and let present re-display the existing target.color.
        // Render budget on cache-hit frames drops from ~7 ms to ~0.
        if (cache_hit) {
            self.timings.clear_ns = 0;
            self.timings.raster_ns = 0;
            self.timings.hiz_build_ns = 0;
            self.timings.lighting_ns = 0;
            self.timings.hdr_post_ns = 0;
            self.timings.bloom_ns = 0;
            self.timings.tonemap_ns = 0;
            self.timings.lit_pixel_count = 0;
            self.timings.tonemapped_pixel_count = 0;
            self.timings.bloom_bright_pixels = 0;
            self.timings.hiz_tile_count = 0;
            return;
        }

        const clear_start = std.time.nanoTimestamp();
        const clear_config = direct_primitives.ClearConfig{
            .color = config.clear_color,
            .depth = std.math.inf(f32),
        };
        if (previous_dirty_rect) |previous_rect| {
            if (binning.dirty_rect) |current_rect| {
                direct_primitives.clearRect(resources.target, unionDirtyRects(previous_rect, current_rect), clear_config);
            } else {
                direct_primitives.clearRect(resources.target, dirtyRectToRect(previous_rect), clear_config);
            }
        } else {
            _ = frame_setup_stage.execute(resources, .{
                .clear_color = config.clear_color,
                .clear_depth = clear_config.depth,
                .clear_auxiliary = false,
            });
        }
        self.timings.clear_ns = @max(std.time.nanoTimestamp() - clear_start, @as(i128, 0));

        const raster_start = std.time.nanoTimestamp();
        _ = try rasterization_stage.execute(.{
            .allocator = self.allocator,
            .tile_ranges = &self.tile_ranges,
            .tile_command_indices = &self.tile_command_indices,
            .active_tile_indices = &self.active_tile_indices,
            .active_tile_command_counts = &self.active_tile_command_counts,
            .tile_chunk_jobs = &self.tile_chunk_jobs,
            .tile_chunk_job_contexts = &self.tile_chunk_job_contexts,
        }, resources, &self.draw_list, width, height, if (config.raster_mode != .single_thread) job_sys else null, config.raster_mode);
        self.timings.raster_ns = @max(std.time.nanoTimestamp() - raster_start, @as(i128, 0));

        // H7: rebuild the Hi-Z pyramid from this frame's depth buffer
        // so the next frame can early-reject occluded primitives. Build
        // cost is paid once per frame; reject cost is paid per
        // candidate primitive only when the binning stage opts in.
        if (resources.target.depth) |depth_buf| {
            const hiz_start = std.time.nanoTimestamp();
            const hiz_result = hiz_stage.buildPyramid(
                depth_buf,
                resources.target.width,
                resources.target.height,
                resources.aux.hiz_pyramid,
                job_sys,
            );
            self.timings.hiz_build_ns = @max(std.time.nanoTimestamp() - hiz_start, @as(i128, 0));
            self.timings.hiz_tile_count = hiz_result.tile_count;
        }

        // The deferred path always runs (it's the real shading step
        // once G-buffer is written). The forward "fake shading" helper
        // only runs when explicitly enabled (config.enable_shading).
        if (!app_config.DEFERRED_SHADING_ENABLED and !config.enable_shading) {
            self.present_dirty_rect = binning.dirty_rect;
            return;
        }

        // Deferred lighting path consumes the G-buffer surfaces just
        // produced by the rasterizer and writes the lit colour back to
        // target.color. The forward shading helper (a screen-space
        // darken) only runs when deferred is off.
        if (app_config.DEFERRED_SHADING_ENABLED) {
            const lighting_start = std.time.nanoTimestamp();
            const lighting_cfg = config.deferred_lighting orelse shading_stage.DeferredConfig{};
            const lighting = shading_stage.executeDeferred(resources, if (binning.dirty_rect) |rect| .{
                .min_x = rect.min_x,
                .min_y = rect.min_y,
                .max_x = rect.max_x,
                .max_y = rect.max_y,
            } else null, lighting_cfg, job_sys);
            self.timings.lighting_ns = @max(std.time.nanoTimestamp() - lighting_start, @as(i128, 0));
            self.timings.lit_pixel_count = lighting.lit_pixels;

            // H6: HDR post-process slot. Runs on the linear HDR buffer
            // before tone-map so passes (bloom, exposure, eye-adapt)
            // get full dynamic range. Today this is just a luminance
            // probe that feeds telemetry and auto-exposure; future
            // bloom hooks here.
            const hdr_post_start = std.time.nanoTimestamp();
            const luminance = hdr_post_stage.executeLuminanceProbe(resources, lighting.bounds, job_sys);
            self.timings.hdr_post_ns = @max(std.time.nanoTimestamp() - hdr_post_start, @as(i128, 0));
            self.timings.hdr_avg_luminance = luminance.avg_luminance;
            self.timings.hdr_max_luminance = luminance.max_luminance;

            // H6: HDR bloom — extracts bright pixels, blurs them at
            // 1/4 res, composites back. Runs before tone-map so the
            // bloom contribution sees full HDR magnitudes. Behind a
            // config gate (HDR_BLOOM_ENABLED) while edge artifacts
            // are diagnosed.
            if (app_config.HDR_BLOOM_ENABLED and resources.aux.bloom_hdr_ping.len > 0) {
                const bloom_start = std.time.nanoTimestamp();
                const bloom_result = hdr_bloom_pass.execute(resources, .{
                    .width = resources.aux.bloom_hdr_width,
                    .height = resources.aux.bloom_hdr_height,
                    .ping = resources.aux.bloom_hdr_ping,
                    .pong = resources.aux.bloom_hdr_pong,
                }, .{}, job_sys);
                self.timings.bloom_ns = @max(std.time.nanoTimestamp() - bloom_start, @as(i128, 0));
                self.timings.bloom_bright_pixels = bloom_result.bright_pixels;
            }

            // Auto-exposure: low-pass the probed average and aim for
            // a target middle-grey of 0.5. Smoothing factor 0.1 mimics
            // 100ms eye adaptation at 60Hz — fast enough to be useful
            // for a benchmark, slow enough to avoid frame-to-frame
            // flashing. (ROADMAP §H6 auto-exposure piece.)
            const probe_avg = if (luminance.sampled_pixels > 0) luminance.avg_luminance else 0.0;
            if (self.auto_exposure_avg_luminance <= 0.0) {
                self.auto_exposure_avg_luminance = probe_avg;
            } else {
                self.auto_exposure_avg_luminance = self.auto_exposure_avg_luminance * 0.9 + probe_avg * 0.1;
            }
            const exposure = if (self.auto_exposure_avg_luminance > 0.001)
                0.5 / self.auto_exposure_avg_luminance
            else
                1.0;

            // H5: tone-map the HDR scene buffer that lighting just
            // wrote into target.color. Operates over the same dirty
            // rect that lighting touched.
            const tonemap_start = std.time.nanoTimestamp();
            const tonemap = shading_stage.executeTonemap(resources, lighting.bounds, .{ .exposure = exposure }, job_sys);
            self.timings.tonemap_ns = @max(std.time.nanoTimestamp() - tonemap_start, @as(i128, 0));
            self.timings.tonemapped_pixel_count = tonemap.mapped_pixels;
            self.timings.tonemap_exposure = exposure;

            // Screen-space post: vignette + film grain applied in-place
            // to the LDR target.color buffer. We constrain the bounds to
            // the lighting dirty rect (the area touched by raster +
            // tonemap this frame) so cached pixels outside the gun area
            // don't get re-modified each miss frame (the post pass is
            // not idempotent — running it twice doubles the grain and
            // squares the vignette).
            const post_full_rect: ?direct_primitives.Rect2i = if (lighting.bounds) |rect| .{
                .min_x = rect.min_x,
                .min_y = rect.min_y,
                .max_x = rect.max_x,
                .max_y = rect.max_y,
            } else null;
            // Always-on inline IQ stage. Strengths come straight from
            // the config values; gating via the legacy [passes] toggles
            // is bypassed deliberately so we don't double-disable this
            // alongside the unrelated legacy CA/vignette path.
            const ca_strength: f32 = app_config.POST_CHROMATIC_ABERRATION_STRENGTH;
            const vig_strength: f32 = app_config.POST_VIGNETTE_STRENGTH;
            const grain_strength: f32 = app_config.POST_FILM_GRAIN_STRENGTH;
            _ = screen_post_stage.execute(resources, post_full_rect, .{
                .chromatic_aberration = ca_strength,
                .vignette = vig_strength,
                .film_grain = grain_strength,
                .seed = @as(u32, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))),
            }, job_sys);

            // Present rect stays bound to the dirty rect we actually
            // wrote to this frame — preserving the cache invariant that
            // pixels outside present_dirty_rect equal last frame's
            // pixels exactly.
            self.present_dirty_rect = binning.dirty_rect;
        } else {
            const shading_start = std.time.nanoTimestamp();
            const shading = shading_stage.execute(resources, if (binning.dirty_rect) |rect| .{
                .min_x = rect.min_x,
                .min_y = rect.min_y,
                .max_x = rect.max_x,
                .max_y = rect.max_y,
            } else null, .{
                .clear_color = config.clear_color,
                .enabled = config.enable_shading,
            }, job_sys);
            self.timings.shading_ns = @max(std.time.nanoTimestamp() - shading_start, @as(i128, 0));
            self.present_dirty_rect = if (shading.shaded_rect) |rect| .{
                .min_x = rect.min_x,
                .min_y = rect.min_y,
                .max_x = rect.max_x,
                .max_y = rect.max_y,
            } else null;
        }
    }

    fn canReuseStaticScene(
        self: *const State,
        config: RenderConfig,
        camera: direct_batch.Camera,
        width: i32,
        height: i32,
    ) bool {
        return self.cached_static_scene_valid and
            config.scene_kind == .suzanne_showcase and
            config.raster_mode == .worker_tiles and
            self.cached_static_scene_kind == config.scene_kind and
            self.cached_static_width == width and
            self.cached_static_height == height and
            sameCamera(self.cached_static_camera, camera);
    }

    fn updateStaticSceneCache(
        self: *State,
        config: RenderConfig,
        camera: direct_batch.Camera,
        width: i32,
        height: i32,
        binning: screen_binning_stage.Result,
    ) void {
        self.cached_static_scene_valid = config.scene_kind == .suzanne_showcase and config.raster_mode == .worker_tiles;
        if (!self.cached_static_scene_valid) return;
        self.cached_static_scene_kind = config.scene_kind;
        self.cached_static_width = width;
        self.cached_static_height = height;
        self.cached_static_camera = camera;
        self.cached_static_dirty_rect = binning.dirty_rect;
        self.cached_static_primitive_count = self.timings.primitive_count;
        self.cached_static_touched_tiles = binning.touched_tiles;
        rebuildCachedPreparedTileBlocks(
            self.allocator,
            &self.cached_prepared_tile_ranges,
            &self.cached_prepared_tile_counts,
            &self.cached_prepared_triangles,
            &self.cached_prepared_setups,
            &self.cached_prepared_depths,
            &self.cached_prepared_vertex_depths,
            &self.draw_list,
            &self.tile_ranges,
            &self.tile_command_indices,
        ) catch {
            self.cached_prepared_tile_ranges.clearRetainingCapacity();
            self.cached_prepared_tile_counts.clearRetainingCapacity();
            self.cached_prepared_triangles.clearRetainingCapacity();
            self.cached_prepared_setups.clearRetainingCapacity();
            self.cached_prepared_depths.clearRetainingCapacity();
            self.cached_prepared_vertex_depths.clearRetainingCapacity();
        };
    }
};

inline fn sameCamera(a: direct_batch.Camera, b: direct_batch.Camera) bool {
    return a.position.x == b.position.x and
        a.position.y == b.position.y and
        a.position.z == b.position.z and
        a.yaw == b.yaw and
        a.pitch == b.pitch and
        a.fov_deg == b.fov_deg;
}

fn countNonBackground(color: []const u32, background: u32) usize {
    var count: usize = 0;
    for (color) |pixel| {
        if (pixel != background) count += 1;
    }
    return count;
}

inline fn dirtyRectToRect(rect: screen_binning_stage.DirtyRect) direct_primitives.Rect2i {
    return .{
        .min_x = rect.min_x,
        .min_y = rect.min_y,
        .max_x = rect.max_x,
        .max_y = rect.max_y,
    };
}

inline fn unionDirtyRects(a: screen_binning_stage.DirtyRect, b: screen_binning_stage.DirtyRect) direct_primitives.Rect2i {
    return direct_primitives.unionRect(dirtyRectToRect(a), dirtyRectToRect(b));
}

fn rebuildCachedPreparedTileBlocks(
    allocator: std.mem.Allocator,
    cached_tile_ranges: *std.ArrayListUnmanaged(screen_binning_stage.TileRange),
    cached_tile_counts: *std.ArrayListUnmanaged(usize),
    cached_triangles: *std.ArrayListUnmanaged(direct_primitives.Triangle2i),
    cached_setups: *std.ArrayListUnmanaged(direct_primitives.PreparedGouraudTriangle),
    cached_depths: *std.ArrayListUnmanaged(?f32),
    cached_vertex_depths: *std.ArrayListUnmanaged(?[3]f32),
    draw_list: *const direct_draw_list.DrawList,
    tile_ranges: *const std.ArrayListUnmanaged(screen_binning_stage.TileRange),
    tile_command_indices: *const std.ArrayListUnmanaged(usize),
) !void {
    cached_tile_ranges.clearRetainingCapacity();
    cached_tile_counts.clearRetainingCapacity();
    cached_triangles.clearRetainingCapacity();
    cached_setups.clearRetainingCapacity();
    cached_depths.clearRetainingCapacity();
    cached_vertex_depths.clearRetainingCapacity();
    try cached_tile_ranges.resize(allocator, tile_ranges.items.len);
    try cached_tile_counts.resize(allocator, tile_ranges.items.len);
    const prepared = draw_list.preparedGouraud();
    for (tile_ranges.items, 0..) |range, tile_index| {
        const start = cached_triangles.items.len;
        var prepared_count: usize = 0;
        const command_indices = tile_command_indices.items[range.start .. range.start + range.len];
        for (command_indices) |command_index| {
            const entry = prepared[command_index] orelse continue;
            try cached_triangles.append(allocator, entry.triangle);
            try cached_setups.append(allocator, entry.prepared);
            try cached_depths.append(allocator, entry.depth_value);
            try cached_vertex_depths.append(allocator, entry.vertex_depths);
            prepared_count += 1;
        }
        cached_tile_ranges.items[tile_index] = .{
            .start = start,
            .len = cached_triangles.items.len - start,
        };
        cached_tile_counts.items[tile_index] = prepared_count;
    }
}

test "direct backend prepares tile bins for showcase" {
    var backend = State.init(std.testing.allocator);
    defer backend.deinit();

    var color = [_]u32{0} ** (128 * 128);
    var depth = [_]f32{0} ** (128 * 128);
    var scene_camera = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (128 * 128);
    var scene_normal = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (128 * 128);
    var scene_surface = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (128 * 128);

    try backend.renderPrimitiveShowcase(.{
        .target = .{
            .width = 128,
            .height = 128,
            .color = color[0..],
            .depth = depth[0..],
        },
        .aux = .{
            .scene_camera = scene_camera[0..],
            .scene_normal = scene_normal[0..],
            .scene_surface = scene_surface[0..],
        },
    }, .{
        .position = @import("../../core/math.zig").Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, null, .{});

    try std.testing.expect(backend.lastTimings().touched_tiles > 0);
    try std.testing.expect(backend.lastTimings().primitive_count > 0);
}

test "direct backend tile refs are deterministic across runs" {
    var backend = State.init(std.testing.allocator);
    defer backend.deinit();

    var color = [_]u32{0} ** (160 * 90);
    var depth = [_]f32{0} ** (160 * 90);
    var scene_camera = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (160 * 90);
    var scene_normal = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (160 * 90);
    var scene_surface = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (160 * 90);
    const resources: frame_resources.FrameResources = .{
        .target = .{ .width = 160, .height = 90, .color = color[0..], .depth = depth[0..] },
        .aux = .{ .scene_camera = scene_camera[0..], .scene_normal = scene_normal[0..], .scene_surface = scene_surface[0..] },
    };
    const camera: direct_batch.Camera = .{ .position = @import("../../core/math.zig").Vec3.new(0.0, 0.0, -3.0), .yaw = 0.0, .pitch = 0.0, .fov_deg = 60.0 };

    try backend.renderPrimitiveShowcase(resources, camera, null, .{});
    const first_refs = try std.testing.allocator.dupe(usize, backend.tile_command_indices.items);
    defer std.testing.allocator.free(first_refs);
    const first_ranges = try std.testing.allocator.dupe(screen_binning_stage.TileRange, backend.tile_ranges.items);
    defer std.testing.allocator.free(first_ranges);

    try backend.renderPrimitiveShowcase(resources, camera, null, .{});
    try std.testing.expectEqualSlices(usize, first_refs, backend.tile_command_indices.items);
    try std.testing.expectEqualSlices(screen_binning_stage.TileRange, first_ranges, backend.tile_ranges.items);
}

test "direct backend single-thread and worker tiles produce identical color output" {
    var backend_single = State.init(std.testing.allocator);
    defer backend_single.deinit();
    var backend_worker = State.init(std.testing.allocator);
    defer backend_worker.deinit();
    var js = try JobSystem.init(std.testing.allocator);
    defer js.deinit();

    var color_single = [_]u32{0} ** (256 * 144);
    var color_worker = [_]u32{0} ** (256 * 144);
    var depth_single = [_]f32{0} ** (256 * 144);
    var depth_worker = [_]f32{0} ** (256 * 144);
    var scene_camera_single = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_camera_worker = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_normal_single = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_normal_worker = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_surface_single = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (256 * 144);
    var scene_surface_worker = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (256 * 144);
    const camera: direct_batch.Camera = .{ .position = @import("../../core/math.zig").Vec3.new(0.0, 0.0, -3.0), .yaw = 0.0, .pitch = 0.0, .fov_deg = 60.0 };

    try backend_single.renderPrimitiveShowcase(.{
        .target = .{ .width = 256, .height = 144, .color = color_single[0..], .depth = depth_single[0..] },
        .aux = .{ .scene_camera = scene_camera_single[0..], .scene_normal = scene_normal_single[0..], .scene_surface = scene_surface_single[0..] },
    }, camera, null, .{ .raster_mode = .single_thread });
    try backend_worker.renderPrimitiveShowcase(.{
        .target = .{ .width = 256, .height = 144, .color = color_worker[0..], .depth = depth_worker[0..] },
        .aux = .{ .scene_camera = scene_camera_worker[0..], .scene_normal = scene_normal_worker[0..], .scene_surface = scene_surface_worker[0..] },
    }, camera, js, .{ .raster_mode = .worker_tiles });

    try std.testing.expectEqualSlices(u32, color_single[0..], color_worker[0..]);
    try std.testing.expect(countNonBackground(color_single[0..], 0xFF0B1220) > 0);
}

test "scene mesh path applies gouraud lighting before draw-list compile" {
    var backend = State.init(std.testing.allocator);
    defer backend.deinit();

    var mesh = try direct_mesh.Mesh.triangle(std.testing.allocator);
    defer mesh.deinit();

    var color = [_]u32{0} ** (128 * 128);
    var depth = [_]f32{0} ** (128 * 128);
    var scene_camera = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (128 * 128);
    var scene_normal = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (128 * 128);
    var scene_surface = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (128 * 128);

    try backend.renderSceneMesh(.{
        .target = .{
            .width = 128,
            .height = 128,
            .color = color[0..],
            .depth = depth[0..],
        },
        .aux = .{
            .scene_camera = scene_camera[0..],
            .scene_normal = scene_normal[0..],
            .scene_surface = scene_surface[0..],
        },
    }, .{
        .position = @import("../../core/math.zig").Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, &mesh, null, .{
        .raster_mode = .single_thread,
        .enable_shading = false,
    });

    try std.testing.expect(backend.draw_list.items().len > 0);
    try std.testing.expect(backend.draw_list.items()[0].payload == .triangle);
    try std.testing.expect(backend.draw_list.items()[0].payload.triangle.vertex_colors != null);
    try std.testing.expect(backend.draw_list.items()[0].payload.triangle.gouraud_setup != null);
    try std.testing.expect(backend.draw_list.preparedGouraud()[0] != null);
}
