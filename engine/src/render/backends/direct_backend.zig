const std = @import("std");
const job_system = @import("job_system");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_batch = @import("../direct_batch.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_scene_packets = @import("../direct_scene_packets.zig");
const direct_meshlets = @import("../direct_meshlets.zig");
const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");
const frame_setup_stage = @import("../stages/frame_setup_stage.zig");
const scene_submission_stage = @import("../stages/scene_submission_stage.zig");
const visibility_culling_stage = @import("../stages/visibility_culling_stage.zig");
const primitive_expansion_stage = @import("../stages/primitive_expansion_stage.zig");
const screen_binning_stage = @import("../stages/screen_binning_stage.zig");
const rasterization_stage = @import("../stages/rasterization_stage.zig");
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
    visible_meshlets: direct_meshlets.VisibleMeshlets,
    tile_counts: std.ArrayListUnmanaged(usize) = .{},
    tile_cursors: std.ArrayListUnmanaged(usize) = .{},
    tile_ranges: std.ArrayListUnmanaged(screen_binning_stage.TileRange) = .{},
    tile_command_indices: std.ArrayListUnmanaged(usize) = .{},
    tile_spans: std.ArrayListUnmanaged(?screen_binning_stage.TileSpan) = .{},
    active_tile_indices: std.ArrayListUnmanaged(usize) = .{},
    active_tile_command_counts: std.ArrayListUnmanaged(usize) = .{},
    tile_chunk_jobs: std.ArrayListUnmanaged(Job) = .{},
    tile_chunk_job_contexts: std.ArrayListUnmanaged(rasterization_stage.RasterTileChunkJobContext) = .{},
    present_dirty_rect: ?screen_binning_stage.DirtyRect = null,
    previous_fast_path_bounds: ?direct_primitives.Rect2i = null,
    timings: FrameTimings = .{},

    pub fn init(allocator: std.mem.Allocator) State {
        var showcase_mesh = direct_meshlets.Mesh.cube(allocator) catch @panic("cube mesh init failed");
        direct_meshlets.ensureMeshlets(&showcase_mesh, allocator) catch @panic("cube meshlet init failed");
        return .{
            .allocator = allocator,
            .scene_packets = direct_scene_packets.PacketList.init(allocator),
            .visible_scene = visible_scene.VisibleScene.init(allocator),
            .batch = direct_batch.PrimitiveBatch.init(allocator),
            .draw_list = direct_draw_list.DrawList.init(allocator),
            .showcase_mesh = showcase_mesh,
            .visible_meshlets = direct_meshlets.VisibleMeshlets.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.scene_packets.deinit();
        self.visible_scene.deinit();
        self.batch.deinit();
        self.draw_list.deinit();
        self.showcase_mesh.deinit();
        self.visible_meshlets.deinit();
        self.tile_counts.deinit(self.allocator);
        self.tile_cursors.deinit(self.allocator);
        self.tile_ranges.deinit(self.allocator);
        self.tile_command_indices.deinit(self.allocator);
        self.tile_spans.deinit(self.allocator);
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

        const build_start = std.time.nanoTimestamp();
        const submission = try scene_submission_stage.execute(&self.scene_packets, &self.showcase_mesh, config.scene_kind);
        std.debug.assert(submission.packet_count == self.scene_packets.items().len);
        _ = try visibility_culling_stage.execute(&self.scene_packets, &self.visible_scene, &self.visible_meshlets, camera);
        const compile_job_system = if (config.raster_mode != .single_thread) job_sys else null;
        const expansion = try primitive_expansion_stage.execute(&self.visible_scene, &self.batch, compile_job_system);
        self.timings.build_batch_ns = @max(std.time.nanoTimestamp() - build_start, @as(i128, 0));
        self.timings.primitive_count = expansion.primitive_count;

        const compile_start = std.time.nanoTimestamp();
        try direct_batch.compileToDrawList(&self.batch, &self.draw_list, camera, width, height);
        self.timings.compile_draw_list_ns = @max(std.time.nanoTimestamp() - compile_start, @as(i128, 0));

        const raster_plan = rasterization_stage.analyze(&self.draw_list, .{
            .allow_direct_fast_path = true,
            .width = width,
            .height = height,
            .raster_mode = config.raster_mode,
        });
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
            return;
        }

        const previous_dirty_rect = self.present_dirty_rect;
        self.previous_fast_path_bounds = null;

        const binning_start = std.time.nanoTimestamp();
        const binning = try screen_binning_stage.execute(
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
            .active_tile_indices = &self.active_tile_indices,
            .active_tile_command_counts = &self.active_tile_command_counts,
            .tile_chunk_jobs = &self.tile_chunk_jobs,
            .tile_chunk_job_contexts = &self.tile_chunk_job_contexts,
        }, resources, &self.draw_list, width, height, if (config.raster_mode != .single_thread) job_sys else null, config.raster_mode);
        _ = raster;
        self.timings.raster_ns = @max(std.time.nanoTimestamp() - raster_start, @as(i128, 0));
    }
};

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
