const std = @import("std");
const job_system = @import("job_system");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_batch = @import("../direct_batch.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_packets = @import("../direct_packets.zig");
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
    tile_jobs: std.ArrayListUnmanaged(Job) = .{},
    tile_job_contexts: std.ArrayListUnmanaged(rasterization_stage.RasterTileJobContext) = .{},
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
        self.tile_jobs.deinit(self.allocator);
        self.tile_job_contexts.deinit(self.allocator);
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
        const compile_job_system = if (config.raster_mode == .worker_tiles) job_sys else null;
        const expansion = try primitive_expansion_stage.execute(&self.visible_scene, &self.batch, compile_job_system);
        self.timings.build_batch_ns = @max(std.time.nanoTimestamp() - build_start, @as(i128, 0));
        self.timings.primitive_count = expansion.primitive_count;

        const compile_start = std.time.nanoTimestamp();
        try direct_batch.compileToDrawList(&self.batch, &self.draw_list, camera, width, height);
        self.timings.compile_draw_list_ns = @max(std.time.nanoTimestamp() - compile_start, @as(i128, 0));

        const fast_path = analyzeDirectFastPath(config, &self.draw_list, width, height);
        if (fast_path.enabled) {
            const clear_start = std.time.nanoTimestamp();
            const clear_config = direct_primitives.ClearConfig{
                .color = 0xFF0B1220,
                .depth = null,
            };
            if (fast_path.bounds) |current_bounds| {
                if (self.previous_fast_path_bounds) |previous_bounds| {
                    direct_primitives.clearRect(resources.target, direct_primitives.unionRect(previous_bounds, current_bounds), clear_config);
                } else {
                    direct_primitives.clear(resources.target, clear_config);
                }
                self.previous_fast_path_bounds = current_bounds;
                self.timings.touched_tiles = fast_path.touched_tiles;
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

        const clear_start = std.time.nanoTimestamp();
        _ = frame_setup_stage.execute(resources, .{
            .clear_color = 0xFF0B1220,
            .clear_depth = if (config.scene_kind == .triangle) null else std.math.inf(f32),
            .clear_auxiliary = false,
        });
        self.timings.clear_ns = @max(std.time.nanoTimestamp() - clear_start, @as(i128, 0));
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
        );
        self.timings.touched_tiles = binning.touched_tiles;
        self.present_dirty_rect = binning.dirty_rect;
        self.timings.binning_ns = @max(std.time.nanoTimestamp() - binning_start, @as(i128, 0));

        const raster_start = std.time.nanoTimestamp();
        const active_job_system = if (config.raster_mode == .worker_tiles) job_sys else null;
        const raster = try rasterization_stage.execute(.{
            .allocator = self.allocator,
            .tile_ranges = &self.tile_ranges,
            .tile_command_indices = &self.tile_command_indices,
            .tile_jobs = &self.tile_jobs,
            .tile_job_contexts = &self.tile_job_contexts,
        }, resources, &self.draw_list, width, height, active_job_system, config.raster_mode);
        _ = raster;
        self.timings.raster_ns = @max(std.time.nanoTimestamp() - raster_start, @as(i128, 0));
    }
};

const FastPathAnalysis = struct {
    enabled: bool = false,
    bounds: ?direct_primitives.Rect2i = null,
    touched_tiles: usize = 0,
};

fn packetDepthValue(packet: direct_packets.DrawPacket) ?f32 {
    return switch (packet.material) {
        .stroke => |stroke| stroke.depth,
        .surface => |surface| surface.depth,
    };
}

fn analyzeDirectFastPath(
    config: RenderConfig,
    draw_list: *const direct_draw_list.DrawList,
    width: i32,
    height: i32,
) FastPathAnalysis {
    if (config.raster_mode != .single_thread) return .{};
    const items = draw_list.items();
    if (items.len > 8) return .{};
    if (items.len == 0) return .{ .enabled = true };
    if (items.len == 1) {
        const packet = items[0];
        if ((packet.flags.depth_test or packet.flags.depth_write) and packetDepthValue(packet) != null) return .{};
        const bounds = direct_primitives.packetBounds(packet);
        return .{
            .enabled = true,
            .bounds = bounds,
            .touched_tiles = if (bounds) |rect| tileCoverageForRect(rect, width, height) else 0,
        };
    }

    var bounds: ?direct_primitives.Rect2i = null;
    for (items) |packet| {
        if ((packet.flags.depth_test or packet.flags.depth_write) and packetDepthValue(packet) != null) {
            return .{};
        }
        const packet_bounds = direct_primitives.packetBounds(packet) orelse continue;
        bounds = if (bounds) |existing|
            direct_primitives.unionRect(existing, packet_bounds)
        else
            packet_bounds;
    }
    return .{
        .enabled = true,
        .bounds = bounds,
        .touched_tiles = if (bounds) |rect| tileCoverageForRect(rect, width, height) else 0,
    };
}

fn tileCoverageForRect(rect: direct_primitives.Rect2i, width: i32, height: i32) usize {
    if (width <= 0 or height <= 0) return 0;
    const clamped = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = width - 1,
        .max_y = height - 1,
    }) orelse return 0;
    const tile_size = TileRenderer.TILE_SIZE;
    const min_col, const max_col, const min_row, const max_row = blk: {
        const shift = comptime std.math.log2_int(u32, tile_size);
        if (comptime std.math.isPowerOfTwo(tile_size)) {
            break :blk .{
                @as(i32, @intCast(@as(u32, @bitCast(clamped.min_x)) >> shift)),
                @as(i32, @intCast(@as(u32, @bitCast(clamped.max_x)) >> shift)),
                @as(i32, @intCast(@as(u32, @bitCast(clamped.min_y)) >> shift)),
                @as(i32, @intCast(@as(u32, @bitCast(clamped.max_y)) >> shift)),
            };
        }
        break :blk .{
            @divTrunc(clamped.min_x, tile_size),
            @divTrunc(clamped.max_x, tile_size),
            @divTrunc(clamped.min_y, tile_size),
            @divTrunc(clamped.max_y, tile_size),
        };
    };
    return @as(usize, @intCast(max_col - min_col + 1)) * @as(usize, @intCast(max_row - min_row + 1));
}

fn countNonBackground(color: []const u32, background: u32) usize {
    var count: usize = 0;
    for (color) |pixel| {
        if (pixel != background) count += 1;
    }
    return count;
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
