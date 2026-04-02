const std = @import("std");
const job_system = @import("job_system");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_packets = @import("../direct_packets.zig");
const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");
const screen_binning_stage = @import("screen_binning_stage.zig");

const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const RasterMode = enum {
    single_thread,
    worker_tiles,
    auto,
};

pub const TileRasterState = struct {
    allocator: std.mem.Allocator,
    tile_ranges: *const std.ArrayListUnmanaged(screen_binning_stage.TileRange),
    tile_command_indices: *const std.ArrayListUnmanaged(usize),
    cached_prepared_tile_ranges: ?*const std.ArrayListUnmanaged(screen_binning_stage.TileRange) = null,
    cached_prepared_tile_counts: ?*const std.ArrayListUnmanaged(usize) = null,
    cached_prepared_triangles: ?*const std.ArrayListUnmanaged(direct_primitives.Triangle2i) = null,
    cached_prepared_setups: ?*const std.ArrayListUnmanaged(direct_primitives.PreparedGouraudTriangle) = null,
    cached_prepared_depths: ?*const std.ArrayListUnmanaged(?f32) = null,
    active_tile_indices: *const std.ArrayListUnmanaged(usize),
    active_tile_command_counts: *const std.ArrayListUnmanaged(usize),
    tile_chunk_jobs: *std.ArrayListUnmanaged(Job),
    tile_chunk_job_contexts: *std.ArrayListUnmanaged(RasterTileChunkJobContext),
};

pub const Result = struct {
    rasterized_tiles: usize,
};

pub const ExecutionPlan = struct {
    mode: Mode,
    bounds: ?direct_primitives.Rect2i = null,
    touched_tiles: usize = 0,

    pub const Mode = enum {
        direct,
        tiled,
    };
};

pub const AnalysisConfig = struct {
    allow_direct_fast_path: bool = true,
    width: i32,
    height: i32,
    raster_mode: RasterMode,
};

pub fn analyze(draw_list: *const direct_draw_list.DrawList, config: AnalysisConfig) ExecutionPlan {
    if (!config.allow_direct_fast_path or config.raster_mode == .worker_tiles) {
        return .{ .mode = .tiled };
    }

    const items = draw_list.items();
    if (items.len > 8) return .{ .mode = .tiled };
    if (items.len == 0) return .{ .mode = .direct };
    if (items.len == 1) {
        const packet = items[0];
        if ((packet.flags.depth_test or packet.flags.depth_write) and packetDepthValue(packet) != null) {
            return .{ .mode = .tiled };
        }
        const bounds = direct_primitives.packetBounds(packet);
        return .{
            .mode = .direct,
            .bounds = bounds,
            .touched_tiles = if (bounds) |rect| tileCoverageForRect(rect, config.width, config.height) else 0,
        };
    }

    var bounds: ?direct_primitives.Rect2i = null;
    for (items) |packet| {
        if ((packet.flags.depth_test or packet.flags.depth_write) and packetDepthValue(packet) != null) {
            return .{ .mode = .tiled };
        }
        const packet_bounds = direct_primitives.packetBounds(packet) orelse continue;
        bounds = if (bounds) |existing|
            direct_primitives.unionRect(existing, packet_bounds)
        else
            packet_bounds;
    }
    return .{
        .mode = .direct,
        .bounds = bounds,
        .touched_tiles = if (bounds) |rect| tileCoverageForRect(rect, config.width, config.height) else 0,
    };
}

pub fn executeDirect(
    resources: frame_resources.FrameResources,
    draw_list: *const direct_draw_list.DrawList,
) Result {
    if (draw_list.items().len == 0) return .{ .rasterized_tiles = 0 };
    const target = direct_primitives.FrameTarget{
        .width = resources.target.width,
        .height = resources.target.height,
        .color = resources.target.color,
        .depth = resources.target.depth,
    };
    if (draw_list.items().len == 1) {
        direct_primitives.drawPacket(target, draw_list.items()[0]);
        return .{ .rasterized_tiles = 1 };
    }
    for (draw_list.items()) |packet| {
        direct_primitives.drawPacket(target, packet);
    }
    return .{ .rasterized_tiles = 1 };
}

pub fn execute(
    state: TileRasterState,
    resources: frame_resources.FrameResources,
    draw_list: *const direct_draw_list.DrawList,
    width: i32,
    height: i32,
    job_sys: ?*JobSystem,
    raster_mode: RasterMode,
) !Result {
    const tile_size = TileRenderer.TILE_SIZE;
    const cols = @max(@divTrunc(width + tile_size - 1, tile_size), 1);
    const active_tiles = state.active_tile_indices.items;
    const active_tile_command_counts = state.active_tile_command_counts.items;

    if (shouldUseWorkerTiles(raster_mode, job_sys, active_tiles.len)) {
        const js = job_sys.?;
        const chunk_count = computeChunkCount(js, active_tiles.len);
        try state.tile_chunk_jobs.resize(state.allocator, chunk_count);
        try state.tile_chunk_job_contexts.resize(state.allocator, chunk_count);
        var parent_job = Job.init(noopTileJob, @ptrFromInt(1), null);
        var main_chunk: ?usize = null;
        const target_commands = targetCommandsPerChunk(js, active_tile_command_counts);

        var chunk_index: usize = 0;
        var start: usize = 0;
        while (chunk_index < chunk_count and start < active_tiles.len) : (chunk_index += 1) {
            const end = nextChunkEnd(start, active_tile_command_counts, target_commands, chunk_count - chunk_index, active_tiles.len);
            state.tile_chunk_job_contexts.items[chunk_index] = .{
                .resources = resources,
                .draw_items = draw_list.items(),
                .prepared_gouraud = draw_list.preparedGouraud(),
                .cached_prepared_tile_ranges = if (state.cached_prepared_tile_ranges) |ranges| ranges.items else null,
                .cached_prepared_tile_counts = if (state.cached_prepared_tile_counts) |counts| counts.items else null,
                .cached_prepared_triangles = if (state.cached_prepared_triangles) |items| items.items else null,
                .cached_prepared_setups = if (state.cached_prepared_setups) |items| items.items else null,
                .cached_prepared_depths = if (state.cached_prepared_depths) |items| items.items else null,
                .tile_ranges = state.tile_ranges.items,
                .tile_command_indices = state.tile_command_indices.items,
                .active_tile_indices = active_tiles,
                .start = start,
                .end = end,
                .tile_cols = cols,
                .tile_size = tile_size,
            };
            if (main_chunk == null) {
                main_chunk = chunk_index;
                start = end;
                continue;
            }
            state.tile_chunk_jobs.items[chunk_index] = Job.init(rasterTileChunkJob, @ptrCast(&state.tile_chunk_job_contexts.items[chunk_index]), &parent_job);
            if (!js.submitJobWithClass(&state.tile_chunk_jobs.items[chunk_index], .high)) {
                rasterTileChunk(&state.tile_chunk_job_contexts.items[chunk_index]);
            }
            start = end;
        }

        if (main_chunk) |idx| rasterTileChunk(&state.tile_chunk_job_contexts.items[idx]);
        parent_job.complete();
        js.waitFor(&parent_job);
        return .{ .rasterized_tiles = active_tiles.len };
    }

    for (active_tiles) |tile_index| {
        var ctx = RasterTileJobContext{
            .resources = resources,
            .draw_items = draw_list.items(),
            .prepared_gouraud = draw_list.preparedGouraud(),
            .cached_prepared_tile_ranges = if (state.cached_prepared_tile_ranges) |ranges| ranges.items else null,
            .cached_prepared_tile_counts = if (state.cached_prepared_tile_counts) |counts| counts.items else null,
            .cached_prepared_triangles = if (state.cached_prepared_triangles) |items| items.items else null,
            .cached_prepared_setups = if (state.cached_prepared_setups) |items| items.items else null,
            .cached_prepared_depths = if (state.cached_prepared_depths) |items| items.items else null,
            .tile_ranges = state.tile_ranges.items,
            .tile_command_indices = state.tile_command_indices.items,
            .tile_index = tile_index,
            .tile_cols = cols,
            .tile_size = tile_size,
        };
        rasterTileWithItems(&ctx, draw_list.items());
    }
    _ = height;
    return .{ .rasterized_tiles = active_tiles.len };
}

fn packetDepthValue(packet: direct_packets.DrawPacket) ?f32 {
    return switch (packet.material) {
        .stroke => |stroke| stroke.depth,
        .surface => |surface| surface.depth,
    };
}

pub fn tileCoverageForRect(rect: direct_primitives.Rect2i, width: i32, height: i32) usize {
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
                clamped.min_x >> shift,
                clamped.max_x >> shift,
                clamped.min_y >> shift,
                clamped.max_y >> shift,
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

pub const RasterTileJobContext = struct {
    resources: frame_resources.FrameResources,
    draw_items: []const direct_packets.DrawPacket,
    prepared_gouraud: []const ?direct_draw_list.DrawList.PreparedGouraudEntry,
    cached_prepared_tile_ranges: ?[]const screen_binning_stage.TileRange = null,
    cached_prepared_tile_counts: ?[]const usize = null,
    cached_prepared_triangles: ?[]const direct_primitives.Triangle2i = null,
    cached_prepared_setups: ?[]const direct_primitives.PreparedGouraudTriangle = null,
    cached_prepared_depths: ?[]const ?f32 = null,
    tile_ranges: []const screen_binning_stage.TileRange,
    tile_command_indices: []const usize,
    tile_index: usize,
    tile_cols: i32,
    tile_size: i32,
};

pub const RasterTileChunkJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    draw_items: []const direct_packets.DrawPacket,
    prepared_gouraud: []const ?direct_draw_list.DrawList.PreparedGouraudEntry,
    cached_prepared_tile_ranges: ?[]const screen_binning_stage.TileRange = null,
    cached_prepared_tile_counts: ?[]const usize = null,
    cached_prepared_triangles: ?[]const direct_primitives.Triangle2i = null,
    cached_prepared_setups: ?[]const direct_primitives.PreparedGouraudTriangle = null,
    cached_prepared_depths: ?[]const ?f32 = null,
    tile_ranges: []const screen_binning_stage.TileRange,
    tile_command_indices: []const usize,
    active_tile_indices: []const usize,
    start: usize,
    end: usize,
    tile_cols: i32,
    tile_size: i32,
};

const max_tile_gouraud_batch = 256;

const TilePreparedGouraudBatch = struct {
    triangles: [max_tile_gouraud_batch]direct_primitives.Triangle2i = undefined,
    prepared_setups: [max_tile_gouraud_batch]direct_primitives.PreparedGouraudTriangle = undefined,
    depth_values: [max_tile_gouraud_batch]?f32 = undefined,
    len: usize = 0,

    inline fn clear(self: *TilePreparedGouraudBatch) void {
        self.len = 0;
    }

    inline fn triangleSlice(self: *const TilePreparedGouraudBatch) []const direct_primitives.Triangle2i {
        return self.triangles[0..self.len];
    }

    inline fn preparedSlice(self: *const TilePreparedGouraudBatch) []const direct_primitives.PreparedGouraudTriangle {
        return self.prepared_setups[0..self.len];
    }

    inline fn depthSlice(self: *const TilePreparedGouraudBatch) []const ?f32 {
        return self.depth_values[0..self.len];
    }
};

fn noopTileJob(_: *anyopaque) void {}

fn rasterTileJob(ctx_ptr: *anyopaque) void {
    const ctx: *RasterTileJobContext = @ptrCast(@alignCast(ctx_ptr));
    rasterTileWithItems(ctx, ctx.draw_items);
}

fn rasterTileChunkJob(ctx_ptr: *anyopaque) void {
    const ctx: *RasterTileChunkJobContext = @ptrCast(@alignCast(ctx_ptr));
    rasterTileChunk(ctx);
}

fn rasterTileChunk(ctx: *const RasterTileChunkJobContext) void {
    var index = ctx.start;
    while (index < ctx.end) : (index += 1) {
        var tile_ctx = RasterTileJobContext{
            .resources = ctx.resources,
            .draw_items = ctx.draw_items,
            .prepared_gouraud = ctx.prepared_gouraud,
            .cached_prepared_tile_ranges = ctx.cached_prepared_tile_ranges,
            .cached_prepared_tile_counts = ctx.cached_prepared_tile_counts,
            .cached_prepared_triangles = ctx.cached_prepared_triangles,
            .cached_prepared_setups = ctx.cached_prepared_setups,
            .cached_prepared_depths = ctx.cached_prepared_depths,
            .tile_ranges = ctx.tile_ranges,
            .tile_command_indices = ctx.tile_command_indices,
            .tile_index = ctx.active_tile_indices[index],
            .tile_cols = ctx.tile_cols,
            .tile_size = ctx.tile_size,
        };
        rasterTileWithItems(&tile_ctx, ctx.draw_items);
    }
}

fn rasterTileWithItems(ctx: *const RasterTileJobContext, draw_items: []const direct_packets.DrawPacket) void {
    const clipped_target = makeClippedTarget(ctx);
    if (ctx.cached_prepared_tile_ranges) |prepared_tile_ranges| {
        const range = prepared_tile_ranges[ctx.tile_index];
        if (range.len > 0) {
            direct_primitives.drawPreparedGouraudTriangleBlock(
                clipped_target,
                ctx.cached_prepared_triangles.?[range.start .. range.start + range.len],
                ctx.cached_prepared_setups.?[range.start .. range.start + range.len],
                ctx.cached_prepared_depths.?[range.start .. range.start + range.len],
            );
        }
        if (ctx.cached_prepared_tile_counts.?[ctx.tile_index] == ctx.tile_ranges[ctx.tile_index].len) return;
    }
    const range = ctx.tile_ranges[ctx.tile_index];
    const command_indices = ctx.tile_command_indices[range.start .. range.start + range.len];
    var gouraud_batch = TilePreparedGouraudBatch{};
    for (command_indices, 0..) |command_index, command_offset| {
        if (command_offset + 1 < command_indices.len) {
            @prefetch(&draw_items[command_indices[command_offset + 1]], .{ .rw = .read, .locality = 3, .cache = .data });
        }
        if (ctx.cached_prepared_tile_ranges != null and ctx.prepared_gouraud[command_index] != null) continue;
        if (tryAppendPreparedGouraud(&gouraud_batch, ctx.prepared_gouraud[command_index])) continue;
        const packet = draw_items[command_index];
        flushPreparedGouraudBatch(clipped_target, &gouraud_batch);
        direct_primitives.drawPacket(clipped_target, packet);
    }
    flushPreparedGouraudBatch(clipped_target, &gouraud_batch);
}

inline fn tryAppendPreparedGouraud(batch: *TilePreparedGouraudBatch, prepared_entry: ?direct_draw_list.DrawList.PreparedGouraudEntry) bool {
    const entry = prepared_entry orelse return false;
    if (batch.len >= max_tile_gouraud_batch) return false;
    batch.triangles[batch.len] = entry.triangle;
    batch.prepared_setups[batch.len] = entry.prepared;
    batch.depth_values[batch.len] = entry.depth_value;
    batch.len += 1;
    return true;
}

inline fn flushPreparedGouraudBatch(
    target: direct_primitives.FrameTarget,
    batch: *TilePreparedGouraudBatch,
) void {
    direct_primitives.drawPreparedGouraudTriangleBlock(target, batch.triangleSlice(), batch.preparedSlice(), batch.depthSlice());
    batch.clear();
}

inline fn shouldUseWorkerTiles(raster_mode: RasterMode, job_sys: ?*JobSystem, active_tile_count: usize) bool {
    if (job_sys == null or active_tile_count == 0) return false;
    return switch (raster_mode) {
        .single_thread => false,
        .worker_tiles => true,
        .auto => active_tile_count >= autoParallelTileThreshold(job_sys.?),
    };
}

inline fn autoParallelTileThreshold(job_sys: *const JobSystem) usize {
    return @max(@as(usize, job_sys.worker_count), 4);
}

inline fn computeChunkCount(job_sys: *const JobSystem, active_tile_count: usize) usize {
    const workers = @max(@as(usize, job_sys.worker_count), 1);
    return @max(std.math.divCeil(usize, active_tile_count, workers * 2) catch 1, 1);
}

inline fn targetCommandsPerChunk(job_sys: *const JobSystem, active_tile_command_counts: []const usize) usize {
    var total_commands: usize = 0;
    for (active_tile_command_counts) |count| total_commands += count;
    const workers = @max(@as(usize, job_sys.worker_count), 1);
    return @max(std.math.divCeil(usize, total_commands, workers * 2) catch 1, 1);
}

inline fn nextChunkEnd(
    start: usize,
    active_tile_command_counts: []const usize,
    target_commands: usize,
    remaining_chunks: usize,
    total_tiles: usize,
) usize {
    if (remaining_chunks <= 1) return total_tiles;
    var end = start;
    var accumulated: usize = 0;
    const max_end = total_tiles - (remaining_chunks - 1);
    while (end < max_end) : (end += 1) {
        accumulated += active_tile_command_counts[end];
        if (accumulated >= target_commands) return end + 1;
    }
    return max_end;
}

inline fn makeClippedTarget(ctx: *const RasterTileJobContext) direct_primitives.FrameTarget {
    const row: i32 = @intCast(@divTrunc(@as(i32, @intCast(ctx.tile_index)), ctx.tile_cols));
    const col: i32 = @intCast(@mod(@as(i32, @intCast(ctx.tile_index)), ctx.tile_cols));
    const min_x = col * ctx.tile_size;
    const min_y = row * ctx.tile_size;
    return .{
        .width = ctx.resources.target.width,
        .height = ctx.resources.target.height,
        .color = ctx.resources.target.color,
        .depth = ctx.resources.target.depth,
        .clip = .{
            .min_x = min_x,
            .min_y = min_y,
            .max_x = @min(min_x + ctx.tile_size - 1, ctx.resources.target.width - 1),
            .max_y = @min(min_y + ctx.tile_size - 1, ctx.resources.target.height - 1),
        },
    };
}

fn countNonBackground(color: []const u32, background: u32) usize {
    var count: usize = 0;
    for (color) |pixel| {
        if (pixel != background) count += 1;
    }
    return count;
}

test "rasterization stage single-thread and worker tiles match" {
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    try draw_list.appendTriangle(.{
        .a = .{ .x = 24, .y = 24 },
        .b = .{ .x = 120, .y = 28 },
        .c = .{ .x = 60, .y = 100 },
    }, .{ .fill_color = 0xFFFFAA33, .depth = 0.1 });
    try draw_list.appendCircle(.{
        .center = .{ .x = 164, .y = 80 },
        .radius = 24,
    }, .{ .fill_color = 0xFF44CCFF, .depth = 0.2 });

    var tile_counts: std.ArrayListUnmanaged(usize) = .{};
    defer tile_counts.deinit(std.testing.allocator);
    var tile_cursors: std.ArrayListUnmanaged(usize) = .{};
    defer tile_cursors.deinit(std.testing.allocator);
    var tile_ranges: std.ArrayListUnmanaged(screen_binning_stage.TileRange) = .{};
    defer tile_ranges.deinit(std.testing.allocator);
    var tile_command_indices: std.ArrayListUnmanaged(usize) = .{};
    defer tile_command_indices.deinit(std.testing.allocator);
    var tile_spans: std.ArrayListUnmanaged(?screen_binning_stage.TileSpan) = .{};
    defer tile_spans.deinit(std.testing.allocator);
    var active_tiles_single: std.ArrayListUnmanaged(usize) = .{};
    defer active_tiles_single.deinit(std.testing.allocator);
    var active_tile_command_counts_single: std.ArrayListUnmanaged(usize) = .{};
    defer active_tile_command_counts_single.deinit(std.testing.allocator);
    var tile_chunk_jobs_single: std.ArrayListUnmanaged(Job) = .{};
    defer tile_chunk_jobs_single.deinit(std.testing.allocator);
    var tile_chunk_ctx_single: std.ArrayListUnmanaged(RasterTileChunkJobContext) = .{};
    defer tile_chunk_ctx_single.deinit(std.testing.allocator);
    var active_tiles_worker: std.ArrayListUnmanaged(usize) = .{};
    defer active_tiles_worker.deinit(std.testing.allocator);
    var active_tile_command_counts_worker: std.ArrayListUnmanaged(usize) = .{};
    defer active_tile_command_counts_worker.deinit(std.testing.allocator);
    var tile_chunk_jobs_worker: std.ArrayListUnmanaged(Job) = .{};
    defer tile_chunk_jobs_worker.deinit(std.testing.allocator);
    var tile_chunk_ctx_worker: std.ArrayListUnmanaged(RasterTileChunkJobContext) = .{};
    defer tile_chunk_ctx_worker.deinit(std.testing.allocator);
    var js = try JobSystem.init(std.testing.allocator);
    defer js.deinit();

    _ = try screen_binning_stage.execute(
        std.testing.allocator,
        &draw_list,
        256,
        144,
        &tile_counts,
        &tile_cursors,
        &tile_ranges,
        &tile_command_indices,
        &tile_spans,
        &active_tiles_single,
        &active_tile_command_counts_single,
    );

    var color_single = [_]u32{0xFF0B1220} ** (256 * 144);
    var color_worker = [_]u32{0xFF0B1220} ** (256 * 144);
    var depth_single = [_]f32{std.math.inf(f32)} ** (256 * 144);
    var depth_worker = [_]f32{std.math.inf(f32)} ** (256 * 144);
    var scene_camera_single = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_camera_worker = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_normal_single = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_normal_worker = [_]@import("../../core/math.zig").Vec3{@import("../../core/math.zig").Vec3.new(0.0, 0.0, 0.0)} ** (256 * 144);
    var scene_surface_single = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (256 * 144);
    var scene_surface_worker = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.invalid()} ** (256 * 144);

    const resources_single: frame_resources.FrameResources = .{
        .target = .{ .width = 256, .height = 144, .color = color_single[0..], .depth = depth_single[0..] },
        .aux = .{ .scene_camera = scene_camera_single[0..], .scene_normal = scene_normal_single[0..], .scene_surface = scene_surface_single[0..] },
    };
    const resources_worker: frame_resources.FrameResources = .{
        .target = .{ .width = 256, .height = 144, .color = color_worker[0..], .depth = depth_worker[0..] },
        .aux = .{ .scene_camera = scene_camera_worker[0..], .scene_normal = scene_normal_worker[0..], .scene_surface = scene_surface_worker[0..] },
    };

    _ = try execute(.{
        .allocator = std.testing.allocator,
        .tile_ranges = &tile_ranges,
        .tile_command_indices = &tile_command_indices,
        .active_tile_indices = &active_tiles_single,
        .active_tile_command_counts = &active_tile_command_counts_single,
        .tile_chunk_jobs = &tile_chunk_jobs_single,
        .tile_chunk_job_contexts = &tile_chunk_ctx_single,
    }, resources_single, &draw_list, 256, 144, null, .single_thread);
    try active_tiles_worker.appendSlice(std.testing.allocator, active_tiles_single.items);
    try active_tile_command_counts_worker.appendSlice(std.testing.allocator, active_tile_command_counts_single.items);
    _ = try execute(.{
        .allocator = std.testing.allocator,
        .tile_ranges = &tile_ranges,
        .tile_command_indices = &tile_command_indices,
        .active_tile_indices = &active_tiles_worker,
        .active_tile_command_counts = &active_tile_command_counts_worker,
        .tile_chunk_jobs = &tile_chunk_jobs_worker,
        .tile_chunk_job_contexts = &tile_chunk_ctx_worker,
    }, resources_worker, &draw_list, 256, 144, js, .worker_tiles);

    try std.testing.expectEqualSlices(u32, color_single[0..], color_worker[0..]);
    try std.testing.expect(countNonBackground(color_single[0..], 0xFF0B1220) > 0);
}

test "rasterization analysis selects direct fast path for color-only single packet" {
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    try draw_list.appendTriangle(.{
        .a = .{ .x = 12, .y = 12 },
        .b = .{ .x = 96, .y = 18 },
        .c = .{ .x = 40, .y = 80 },
    }, .{ .fill_color = 0xFFFF8844, .depth = null });

    const plan = analyze(&draw_list, .{
        .width = 128,
        .height = 128,
        .raster_mode = .single_thread,
    });

    try std.testing.expectEqual(ExecutionPlan.Mode.direct, plan.mode);
    try std.testing.expect(plan.bounds != null);
    try std.testing.expect(plan.touched_tiles > 0);
}

test "rasterization auto mode uses workers for large active tile sets" {
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    try draw_list.appendTriangle(.{
        .a = .{ .x = 8, .y = 8 },
        .b = .{ .x = 248, .y = 12 },
        .c = .{ .x = 120, .y = 132 },
    }, .{ .fill_color = 0xFFFF8844, .depth = 1.0 });

    const plan = analyze(&draw_list, .{
        .width = 256,
        .height = 144,
        .raster_mode = .auto,
    });

    try std.testing.expectEqual(ExecutionPlan.Mode.tiled, plan.mode);
}
