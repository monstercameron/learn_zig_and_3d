const std = @import("std");
const job_system = @import("job_system");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");
const screen_binning_stage = @import("screen_binning_stage.zig");

const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const RasterMode = enum {
    single_thread,
    worker_tiles,
};

pub const TileRasterState = struct {
    allocator: std.mem.Allocator,
    tile_ranges: *const std.ArrayListUnmanaged(screen_binning_stage.TileRange),
    tile_command_indices: *const std.ArrayListUnmanaged(usize),
    tile_jobs: *std.ArrayListUnmanaged(Job),
    tile_job_contexts: *std.ArrayListUnmanaged(RasterTileJobContext),
};

pub const Result = struct {
    rasterized_tiles: usize,
};

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
    const tile_count = state.tile_ranges.items.len;

    if (raster_mode == .worker_tiles and job_sys != null) {
        const js = job_sys.?;
        try state.tile_jobs.resize(state.allocator, tile_count);
        try state.tile_job_contexts.resize(state.allocator, tile_count);
        var parent_job = Job.init(noopTileJob, @ptrFromInt(1), null);
        var main_tile: ?usize = null;
        var rasterized_tiles: usize = 0;

        for (state.tile_ranges.items, 0..) |range, tile_index| {
            if (range.len == 0) continue;
            rasterized_tiles += 1;
            state.tile_job_contexts.items[tile_index] = .{
                .resources = resources,
                .draw_list = draw_list,
                .tile_ranges = state.tile_ranges.items,
                .tile_command_indices = state.tile_command_indices.items,
                .tile_index = tile_index,
                .tile_cols = cols,
                .tile_size = tile_size,
            };
            if (main_tile == null) {
                main_tile = tile_index;
                continue;
            }

            state.tile_jobs.items[tile_index] = Job.init(rasterTileJob, @ptrCast(&state.tile_job_contexts.items[tile_index]), &parent_job);
            if (!js.submitJobWithClass(&state.tile_jobs.items[tile_index], .high)) {
                rasterTileJob(@ptrCast(&state.tile_job_contexts.items[tile_index]));
            }
        }

        if (main_tile) |tile_index| {
            rasterTile(&state.tile_job_contexts.items[tile_index]);
        }
        parent_job.complete();
        js.waitFor(&parent_job);
        return .{ .rasterized_tiles = rasterized_tiles };
    }

    var rasterized_tiles: usize = 0;
    var tile_index: usize = 0;
    while (tile_index < tile_count) : (tile_index += 1) {
        if (state.tile_ranges.items[tile_index].len == 0) continue;
        rasterized_tiles += 1;
        var ctx = RasterTileJobContext{
            .resources = resources,
            .draw_list = draw_list,
            .tile_ranges = state.tile_ranges.items,
            .tile_command_indices = state.tile_command_indices.items,
            .tile_index = tile_index,
            .tile_cols = cols,
            .tile_size = tile_size,
        };
        rasterTile(&ctx);
    }
    _ = height;
    return .{ .rasterized_tiles = rasterized_tiles };
}

pub const RasterTileJobContext = struct {
    resources: frame_resources.FrameResources,
    draw_list: *const direct_draw_list.DrawList,
    tile_ranges: []const screen_binning_stage.TileRange,
    tile_command_indices: []const usize,
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
    const range = ctx.tile_ranges[ctx.tile_index];
    for (ctx.tile_command_indices[range.start .. range.start + range.len]) |command_index| {
        direct_primitives.drawPacket(clipped_target, ctx.draw_list.items()[command_index]);
    }
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
    _ = try screen_binning_stage.execute(
        std.testing.allocator,
        &draw_list,
        256,
        144,
        &tile_counts,
        &tile_cursors,
        &tile_ranges,
        &tile_command_indices,
    );

    var tile_jobs_single: std.ArrayListUnmanaged(Job) = .{};
    defer tile_jobs_single.deinit(std.testing.allocator);
    var tile_ctx_single: std.ArrayListUnmanaged(RasterTileJobContext) = .{};
    defer tile_ctx_single.deinit(std.testing.allocator);
    var tile_jobs_worker: std.ArrayListUnmanaged(Job) = .{};
    defer tile_jobs_worker.deinit(std.testing.allocator);
    var tile_ctx_worker: std.ArrayListUnmanaged(RasterTileJobContext) = .{};
    defer tile_ctx_worker.deinit(std.testing.allocator);
    var js = try JobSystem.init(std.testing.allocator);
    defer js.deinit();

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
        .tile_jobs = &tile_jobs_single,
        .tile_job_contexts = &tile_ctx_single,
    }, resources_single, &draw_list, 256, 144, null, .single_thread);
    _ = try execute(.{
        .allocator = std.testing.allocator,
        .tile_ranges = &tile_ranges,
        .tile_command_indices = &tile_command_indices,
        .tile_jobs = &tile_jobs_worker,
        .tile_job_contexts = &tile_ctx_worker,
    }, resources_worker, &draw_list, 256, 144, js, .worker_tiles);

    try std.testing.expectEqualSlices(u32, color_single[0..], color_worker[0..]);
    try std.testing.expect(countNonBackground(color_single[0..], 0xFF0B1220) > 0);
}
