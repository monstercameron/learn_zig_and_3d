const std = @import("std");
const job_system = @import("job_system");
const obj_loader = @import("../../assets/obj_loader.zig");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_batch = @import("../direct_batch.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_mesh = @import("../direct_mesh.zig");
const direct_scene_packets = @import("../direct_scene_packets.zig");
const direct_meshlets = @import("../direct_meshlets.zig");
const direct_primitives = @import("../direct_primitives.zig");
const gouraud_kernel = @import("../kernels/gouraud_kernel.zig");
const frame_resources = @import("../frame_resources.zig");
const frame_setup_stage = @import("../stages/frame_setup_stage.zig");
const scene_submission_stage = @import("../stages/scene_submission_stage.zig");
const visibility_culling_stage = @import("../stages/visibility_culling_stage.zig");
const primitive_expansion_stage = @import("../stages/primitive_expansion_stage.zig");
const screen_binning_stage = @import("../stages/screen_binning_stage.zig");
const rasterization_stage = @import("../stages/rasterization_stage.zig");
const shading_stage = @import("../stages/shading_stage.zig");
const composition_stage = @import("../stages/composition_stage.zig");
const post_process_stage = @import("../stages/post_process_stage.zig");
const visible_scene = @import("../visible_scene.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const RenderConfig = struct {
    raster_mode: rasterization_stage.RasterMode = .single_thread,
    scene_kind: scene_submission_stage.SceneKind = .triangle,
};

pub const FrameTimings = struct {
    clear_ns: i128 = 0,
    build_batch_ns: i128 = 0,
    compile_draw_list_ns: i128 = 0,
    binning_ns: i128 = 0,
    raster_ns: i128 = 0,
    shading_ns: i128 = 0,
    composition_ns: i128 = 0,
    post_process_ns: i128 = 0,
    present_ns: i128 = 0,
    primitive_count: usize = 0,
    touched_tiles: usize = 0,
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
    active_tile_indices: std.ArrayListUnmanaged(usize) = .{},
    active_tile_command_counts: std.ArrayListUnmanaged(usize) = .{},
    tile_chunk_jobs: std.ArrayListUnmanaged(Job) = .{},
    tile_chunk_job_contexts: std.ArrayListUnmanaged(rasterization_stage.RasterTileChunkJobContext) = .{},
    present_dirty_rect: ?screen_binning_stage.DirtyRect = null,
    previous_fast_path_bounds: ?direct_primitives.Rect2i = null,
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
        self.active_tile_indices.deinit(self.allocator);
        self.active_tile_command_counts.deinit(self.allocator);
        self.tile_chunk_jobs.deinit(self.allocator);
        self.tile_chunk_job_contexts.deinit(self.allocator);
        self.* = undefined;
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
            _ = try visibility_culling_stage.execute(&self.scene_packets, &self.visible_scene, &self.visible_meshlets, camera);
            const compile_job_system = if (config.raster_mode != .single_thread) job_sys else null;
            const expansion = try primitive_expansion_stage.execute(&self.visible_scene, &self.batch, compile_job_system);
            self.timings.build_batch_ns = @max(std.time.nanoTimestamp() - build_start, @as(i128, 0));
            self.timings.primitive_count = expansion.primitive_count;

            const compile_start = std.time.nanoTimestamp();
            gouraud_kernel.applyBatchLighting(&self.batch, .{});
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
            binning = try screen_binning_stage.execute(
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
            &self.draw_list,
            &self.tile_ranges,
            &self.tile_command_indices,
        ) catch {
            self.cached_prepared_tile_ranges.clearRetainingCapacity();
            self.cached_prepared_tile_counts.clearRetainingCapacity();
            self.cached_prepared_triangles.clearRetainingCapacity();
            self.cached_prepared_setups.clearRetainingCapacity();
            self.cached_prepared_depths.clearRetainingCapacity();
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
    draw_list: *const direct_draw_list.DrawList,
    tile_ranges: *const std.ArrayListUnmanaged(screen_binning_stage.TileRange),
    tile_command_indices: *const std.ArrayListUnmanaged(usize),
) !void {
    cached_tile_ranges.clearRetainingCapacity();
    cached_tile_counts.clearRetainingCapacity();
    cached_triangles.clearRetainingCapacity();
    cached_setups.clearRetainingCapacity();
    cached_depths.clearRetainingCapacity();
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
