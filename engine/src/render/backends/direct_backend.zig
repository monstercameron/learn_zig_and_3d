const std = @import("std");
const job_system = @import("job_system");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_batch = @import("../direct_batch.zig");
const direct_demo = @import("../direct_demo.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_scene_packets = @import("../direct_scene_packets.zig");
const direct_meshlets = @import("../direct_meshlets.zig");
const direct_packets = @import("../direct_packets.zig");
const direct_primitives = @import("../direct_primitives.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const RasterMode = enum {
    single_thread,
    worker_tiles,
};

pub const RenderConfig = struct {
    raster_mode: RasterMode = .single_thread,
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

const TileRange = struct {
    start: usize = 0,
    len: usize = 0,
};

const Rect2i = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    scene_packets: direct_scene_packets.PacketList,
    batch: direct_batch.PrimitiveBatch,
    draw_list: direct_draw_list.DrawList,
    showcase_mesh: direct_meshlets.Mesh,
    visible_meshlets: direct_meshlets.VisibleMeshlets,
    tile_counts: std.ArrayListUnmanaged(usize) = .{},
    tile_cursors: std.ArrayListUnmanaged(usize) = .{},
    tile_ranges: std.ArrayListUnmanaged(TileRange) = .{},
    tile_command_indices: std.ArrayListUnmanaged(usize) = .{},
    tile_jobs: std.ArrayListUnmanaged(Job) = .{},
    tile_job_contexts: std.ArrayListUnmanaged(RasterTileJobContext) = .{},
    timings: FrameTimings = .{},

    pub fn init(allocator: std.mem.Allocator) State {
        var showcase_mesh = direct_meshlets.Mesh.cube(allocator) catch @panic("cube mesh init failed");
        direct_meshlets.ensureMeshlets(&showcase_mesh, allocator) catch @panic("cube meshlet init failed");
        return .{
            .allocator = allocator,
            .scene_packets = direct_scene_packets.PacketList.init(allocator),
            .batch = direct_batch.PrimitiveBatch.init(allocator),
            .draw_list = direct_draw_list.DrawList.init(allocator),
            .showcase_mesh = showcase_mesh,
            .visible_meshlets = direct_meshlets.VisibleMeshlets.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.scene_packets.deinit();
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

    pub fn renderPrimitiveShowcase(
        self: *State,
        resources: direct_demo.FrameResources,
        camera: direct_batch.Camera,
        job_sys: ?*JobSystem,
        config: RenderConfig,
    ) !void {
        const width = resources.target.width;
        const height = resources.target.height;

        const clear_start = std.time.nanoTimestamp();
        direct_demo.clearFrame(resources, .{ .color = 0xFF0B1220, .depth = std.math.inf(f32) });
        self.timings.clear_ns = @max(std.time.nanoTimestamp() - clear_start, @as(i128, 0));

        const build_start = std.time.nanoTimestamp();
        try buildShowcaseScenePackets(&self.scene_packets, &self.showcase_mesh);
        const compile_job_system = if (config.raster_mode == .worker_tiles) job_sys else null;
        try direct_scene_packets.compileToPrimitiveBatch(&self.scene_packets, &self.batch, camera, &self.visible_meshlets, compile_job_system);
        self.timings.build_batch_ns = @max(std.time.nanoTimestamp() - build_start, @as(i128, 0));
        self.timings.primitive_count = self.batch.items().len;

        const compile_start = std.time.nanoTimestamp();
        try direct_batch.compileToDrawList(&self.batch, &self.draw_list, camera, width, height);
        self.timings.compile_draw_list_ns = @max(std.time.nanoTimestamp() - compile_start, @as(i128, 0));

        const binning_start = std.time.nanoTimestamp();
        try self.prepareTileBins(width, height);
        self.timings.binning_ns = @max(std.time.nanoTimestamp() - binning_start, @as(i128, 0));

        const raster_start = std.time.nanoTimestamp();
        const active_job_system = if (config.raster_mode == .worker_tiles) job_sys else null;
        try self.rasterTiles(resources, width, height, active_job_system);
        self.timings.raster_ns = @max(std.time.nanoTimestamp() - raster_start, @as(i128, 0));
    }

    fn prepareTileBins(self: *State, width: i32, height: i32) !void {
        const tile_size = TileRenderer.TILE_SIZE;
        const cols = @max(@divTrunc(width + tile_size - 1, tile_size), 1);
        const rows = @max(@divTrunc(height + tile_size - 1, tile_size), 1);
        const tile_count: usize = @intCast(cols * rows);

        try self.tile_counts.resize(self.allocator, tile_count);
        try self.tile_cursors.resize(self.allocator, tile_count);
        try self.tile_ranges.resize(self.allocator, tile_count);
        @memset(self.tile_counts.items, 0);

        for (self.draw_list.items(), 0..) |command, command_index| {
            _ = command_index;
            const bounds = commandBounds(command) orelse continue;
            const min_col = clampTileCoord(@divTrunc(bounds.min_x, tile_size), cols);
            const max_col = clampTileCoord(@divTrunc(bounds.max_x, tile_size), cols);
            const min_row = clampTileCoord(@divTrunc(bounds.min_y, tile_size), rows);
            const max_row = clampTileCoord(@divTrunc(bounds.max_y, tile_size), rows);
            var row = min_row;
            while (row <= max_row) : (row += 1) {
                var col = min_col;
                while (col <= max_col) : (col += 1) {
                    const tile_index: usize = @intCast(row * cols + col);
                    self.tile_counts.items[tile_index] += 1;
                }
            }
        }

        var total_refs: usize = 0;
        var touched_tiles: usize = 0;
        for (self.tile_counts.items, self.tile_ranges.items) |count, *range| {
            range.* = .{ .start = total_refs, .len = count };
            total_refs += count;
            if (count != 0) touched_tiles += 1;
        }
        try self.tile_command_indices.resize(self.allocator, total_refs);
        self.timings.touched_tiles = touched_tiles;

        for (self.tile_counts.items, self.tile_ranges.items, self.tile_cursors.items) |*count, range, *cursor| {
            cursor.* = range.start;
            count.* = range.len;
        }

        for (self.draw_list.items(), 0..) |command, command_index| {
            const bounds = commandBounds(command) orelse continue;
            const min_col = clampTileCoord(@divTrunc(bounds.min_x, tile_size), cols);
            const max_col = clampTileCoord(@divTrunc(bounds.max_x, tile_size), cols);
            const min_row = clampTileCoord(@divTrunc(bounds.min_y, tile_size), rows);
            const max_row = clampTileCoord(@divTrunc(bounds.max_y, tile_size), rows);
            var row = min_row;
            while (row <= max_row) : (row += 1) {
                var col = min_col;
                while (col <= max_col) : (col += 1) {
                    const tile_index: usize = @intCast(row * cols + col);
                    const write_index = self.tile_cursors.items[tile_index];
                    self.tile_command_indices.items[write_index] = command_index;
                    self.tile_cursors.items[tile_index] = write_index + 1;
                }
            }
        }

        deterministicSortTileRefs(self.tile_command_indices.items, self.tile_ranges.items, self.draw_list.items());
    }

    fn rasterTiles(self: *State, resources: direct_demo.FrameResources, width: i32, _: i32, job_sys: ?*JobSystem) !void {
        const tile_size = TileRenderer.TILE_SIZE;
        const cols = @max(@divTrunc(width + tile_size - 1, tile_size), 1);
        const tile_count = self.tile_ranges.items.len;

        if (job_sys) |js| {
            try self.tile_jobs.resize(self.allocator, tile_count);
            try self.tile_job_contexts.resize(self.allocator, tile_count);
            var parent_job = Job.init(noopTileJob, @ptrFromInt(1), null);
            var main_tile: ?usize = null;

            for (self.tile_ranges.items, 0..) |range, tile_index| {
                if (range.len == 0) continue;
                self.tile_job_contexts.items[tile_index] = .{
                    .state = self,
                    .resources = resources,
                    .tile_index = tile_index,
                    .tile_cols = cols,
                    .tile_size = tile_size,
                };
                if (main_tile == null) {
                    main_tile = tile_index;
                    continue;
                }

                self.tile_jobs.items[tile_index] = Job.init(rasterTileJob, @ptrCast(&self.tile_job_contexts.items[tile_index]), &parent_job);
                if (!js.submitJobWithClass(&self.tile_jobs.items[tile_index], .high)) {
                    rasterTileJob(@ptrCast(&self.tile_job_contexts.items[tile_index]));
                }
            }

            if (main_tile) |tile_index| {
                rasterTile(&self.tile_job_contexts.items[tile_index]);
            }
            parent_job.complete();
            js.waitFor(&parent_job);
            return;
        }

        var tile_index: usize = 0;
        while (tile_index < tile_count) : (tile_index += 1) {
            if (self.tile_ranges.items[tile_index].len == 0) continue;
            var ctx = RasterTileJobContext{
                .state = self,
                .resources = resources,
                .tile_index = tile_index,
                .tile_cols = cols,
                .tile_size = tile_size,
            };
            rasterTile(&ctx);
        }
    }
};

fn buildShowcaseScenePackets(
    packets: *direct_scene_packets.PacketList,
    showcase_mesh: *direct_meshlets.Mesh,
) !void {
    packets.clearRetainingCapacity();

    try packets.append(.{
        .source = .{ .line = .{
            .line = .{
                .start = @import("../../core/math.zig").Vec3.new(-2.4, 1.4, 0.0),
                .end = @import("../../core/math.zig").Vec3.new(-1.1, 0.2, 0.0),
            },
            .material = .{ .color = 0xFF7FDBFF },
        } },
    });
    try packets.append(.{
        .source = .{ .triangle = .{
            .triangle = .{
                .a = @import("../../core/math.zig").Vec3.new(0.0, 1.35, 0.0),
                .b = @import("../../core/math.zig").Vec3.new(-1.0, -0.25, 0.0),
                .c = @import("../../core/math.zig").Vec3.new(1.0, -0.25, 0.0),
            },
            .material = .{ .fill_color = 0xFFFF8A3D, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
        } },
    });
    const polygon_points = [_]@import("../../core/math.zig").Vec3{
        @import("../../core/math.zig").Vec3.new(1.2, 1.3, 0.0),
        @import("../../core/math.zig").Vec3.new(1.9, 1.55, 0.0),
        @import("../../core/math.zig").Vec3.new(2.45, 1.05, 0.0),
        @import("../../core/math.zig").Vec3.new(2.25, 0.25, 0.0),
        @import("../../core/math.zig").Vec3.new(1.45, 0.05, 0.0),
        @import("../../core/math.zig").Vec3.new(0.95, 0.65, 0.0),
    };
    try packets.append(.{
        .source = .{ .polygon = .{
            .polygon = try direct_batch.WorldPolygon.fromSlice(polygon_points[0..]),
            .material = .{ .fill_color = 0xFF38D39F, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
        } },
    });
    try packets.append(.{
        .source = .{ .circle = .{
            .circle = .{
                .center = @import("../../core/math.zig").Vec3.new(1.65, -1.15, 0.0),
                .radius = 0.72,
            },
            .material = .{ .fill_color = 0xFFB95CFF, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
        } },
    });
    try packets.append(.{
        .transform = @import("../../core/math.zig").Mat4.multiply(
            @import("../../core/math.zig").Mat4.translate(0.0, 0.0, 5.5),
            @import("../../core/math.zig").Mat4.scale(0.8, 0.8, 0.8),
        ),
        .source = .{ .meshlets = .{
            .mesh = showcase_mesh,
            .material_override = .{ .fill_color = 0xFFD9D3C7, .outline_color = 0xFF1F2937, .depth = 1.0 },
        } },
    });
}

const RasterTileJobContext = struct {
    state: *const State,
    resources: direct_demo.FrameResources,
    tile_index: usize,
    tile_cols: i32,
    tile_size: i32,
};

fn noopTileJob(_: *anyopaque) void {}

fn rasterTileJob(ctx_ptr: *anyopaque) void {
    const ctx: *RasterTileJobContext = @ptrCast(@alignCast(ctx_ptr));
    rasterTile(ctx);
}

fn rasterTile(ctx: *const RasterTileJobContext) void {
    const row: i32 = @intCast(@divTrunc(@as(i32, @intCast(ctx.tile_index)), ctx.tile_cols));
    const col: i32 = @intCast(@mod(@as(i32, @intCast(ctx.tile_index)), ctx.tile_cols));
    const min_x = col * ctx.tile_size;
    const min_y = row * ctx.tile_size;
    const max_x = @min(min_x + ctx.tile_size - 1, ctx.resources.target.width - 1);
    const max_y = @min(min_y + ctx.tile_size - 1, ctx.resources.target.height - 1);
    const clipped_target = direct_primitives.FrameTarget{
        .width = ctx.resources.target.width,
        .height = ctx.resources.target.height,
        .color = ctx.resources.target.color,
        .depth = ctx.resources.target.depth,
        .clip = .{
            .min_x = min_x,
            .min_y = min_y,
            .max_x = max_x,
            .max_y = max_y,
        },
    };
    const range = ctx.state.tile_ranges.items[ctx.tile_index];
    for (ctx.state.tile_command_indices.items[range.start .. range.start + range.len]) |command_index| {
        direct_primitives.drawPacket(clipped_target, ctx.state.draw_list.items()[command_index]);
    }
}

fn clampTileCoord(value: i32, axis_count: i32) i32 {
    return std.math.clamp(value, 0, axis_count - 1);
}

fn commandBounds(packet: direct_packets.DrawPacket) ?Rect2i {
    return switch (packet.payload) {
        .line => |line| .{
            .min_x = @min(line.start.x, line.end.x),
            .min_y = @min(line.start.y, line.end.y),
            .max_x = @max(line.start.x, line.end.x),
            .max_y = @max(line.start.y, line.end.y),
        },
        .triangle => |triangle| .{
            .min_x = @min(triangle.a.x, @min(triangle.b.x, triangle.c.x)),
            .min_y = @min(triangle.a.y, @min(triangle.b.y, triangle.c.y)),
            .max_x = @max(triangle.a.x, @max(triangle.b.x, triangle.c.x)),
            .max_y = @max(triangle.a.y, @max(triangle.b.y, triangle.c.y)),
        },
        .polygon => |polygon| polygonBounds(polygon.points),
        .circle => |circle| .{
            .min_x = circle.center.x - circle.radius,
            .min_y = circle.center.y - circle.radius,
            .max_x = circle.center.x + circle.radius,
            .max_y = circle.center.y + circle.radius,
        },
    };
}

fn deterministicSortTileRefs(
    refs: []usize,
    ranges: []const TileRange,
    commands: []const direct_packets.DrawPacket,
) void {
    for (ranges) |range| {
        if (range.len <= 1) continue;
        std.sort.insertion(usize, refs[range.start .. range.start + range.len], commands, lessThanCommandRef);
    }
}

fn lessThanCommandRef(commands: []const direct_packets.DrawPacket, lhs: usize, rhs: usize) bool {
    const lhs_key = commands[lhs].sort_key;
    const rhs_key = commands[rhs].sort_key;
    if (lhs_key == rhs_key) return lhs < rhs;
    return lhs_key < rhs_key;
}

fn countNonBackground(color: []const u32, background: u32) usize {
    var count: usize = 0;
    for (color) |pixel| {
        if (pixel != background) count += 1;
    }
    return count;
}

fn polygonBounds(points: []const direct_primitives.Point2i) ?Rect2i {
    if (points.len == 0) return null;
    var bounds = Rect2i{
        .min_x = points[0].x,
        .min_y = points[0].y,
        .max_x = points[0].x,
        .max_y = points[0].y,
    };
    for (points[1..]) |point| {
        bounds.min_x = @min(bounds.min_x, point.x);
        bounds.min_y = @min(bounds.min_y, point.y);
        bounds.max_x = @max(bounds.max_x, point.x);
        bounds.max_y = @max(bounds.max_y, point.y);
    }
    return bounds;
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
    const resources: direct_demo.FrameResources = .{
        .target = .{ .width = 160, .height = 90, .color = color[0..], .depth = depth[0..] },
        .aux = .{ .scene_camera = scene_camera[0..], .scene_normal = scene_normal[0..], .scene_surface = scene_surface[0..] },
    };
    const camera: direct_batch.Camera = .{ .position = @import("../../core/math.zig").Vec3.new(0.0, 0.0, -3.0), .yaw = 0.0, .pitch = 0.0, .fov_deg = 60.0 };

    try backend.renderPrimitiveShowcase(resources, camera, null, .{});
    const first_refs = try std.testing.allocator.dupe(usize, backend.tile_command_indices.items);
    defer std.testing.allocator.free(first_refs);
    const first_ranges = try std.testing.allocator.dupe(TileRange, backend.tile_ranges.items);
    defer std.testing.allocator.free(first_ranges);

    try backend.renderPrimitiveShowcase(resources, camera, null, .{});
    try std.testing.expectEqualSlices(usize, first_refs, backend.tile_command_indices.items);
    try std.testing.expectEqualSlices(TileRange, first_ranges, backend.tile_ranges.items);
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
