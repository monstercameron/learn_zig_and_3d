const std = @import("std");
const job_system = @import("job_system");
const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const Config = struct {
    clear_color: u32 = 0xFF0B1220,
    background_color: u32 = 0xFF0B1220,
    scene_alpha: u8 = 232,
};

pub const Result = struct {
    composed_rect: ?direct_primitives.Rect2i = null,
    composed_pixels: usize = 0,
};

pub fn execute(
    resources: frame_resources.FrameResources,
    shaded_rect: ?direct_primitives.Rect2i,
    config: Config,
    job_sys: ?*JobSystem,
) Result {
    const rect = shaded_rect orelse return .{};
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    if (bounds.min_x > bounds.max_x or bounds.min_y > bounds.max_y) return .{};
    if (config.scene_alpha >= 255) {
        return .{ .composed_rect = bounds, .composed_pixels = 0 };
    }
    if (config.scene_alpha == 0) {
        direct_primitives.clearRect(resources.target, bounds, .{ .color = config.background_color });
        const width: usize = @intCast(bounds.max_x - bounds.min_x + 1);
        const height: usize = @intCast(bounds.max_y - bounds.min_y + 1);
        return .{ .composed_rect = bounds, .composed_pixels = width * height };
    }

    if (shouldParallelCompose(job_sys, bounds)) {
        return executeParallel(resources, bounds, config, job_sys.?);
    }

    return .{
        .composed_rect = bounds,
        .composed_pixels = composeRows(resources, bounds, config),
    };
}

fn executeParallel(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    job_sys: *JobSystem,
) Result {
    const total_rows: usize = @intCast(bounds.max_y - bounds.min_y + 1);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]ComposeJobContext = undefined;
    var parent_job = Job.init(noopComposeJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var composed_pixels: usize = 0;
    var row_start = bounds.min_y;

    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const remaining_rows = @as(usize, @intCast(bounds.max_y - row_start + 1));
        const remaining_chunks = chunk_count - chunk_index;
        const chunk_rows = @max(remaining_rows / remaining_chunks, 1);
        const row_end = @min(bounds.max_y, row_start + @as(i32, @intCast(chunk_rows)) - 1);
        contexts[chunk_index] = .{
            .resources = resources,
            .bounds = .{
                .min_x = bounds.min_x,
                .min_y = row_start,
                .max_x = bounds.max_x,
                .max_y = row_end,
            },
            .config = config,
            .composed_pixels = 0,
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(composeRowsJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                composeRowsJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }

    if (main_chunk) |idx| composeRowsJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);
    for (contexts[0..chunk_count]) |ctx| composed_pixels += ctx.composed_pixels;
    return .{ .composed_rect = bounds, .composed_pixels = composed_pixels };
}

fn composeRows(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
) usize {
    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    const inv_alpha: u32 = 255 - config.scene_alpha;
    const alpha: u32 = config.scene_alpha;
    const bg = config.background_color;
    var composed_pixels: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const pixel = color[idx];
            if (pixel == config.clear_color) continue;
            color[idx] = blendOverBackground(pixel, bg, alpha, inv_alpha);
            composed_pixels += 1;
        }
    }
    return composed_pixels;
}

inline fn blendOverBackground(src: u32, bg: u32, alpha: u32, inv_alpha: u32) u32 {
    const a = src & 0xFF000000;
    const sr = (src >> 16) & 0xFF;
    const sg = (src >> 8) & 0xFF;
    const sb = src & 0xFF;
    const br = (bg >> 16) & 0xFF;
    const bgc = (bg >> 8) & 0xFF;
    const bb = bg & 0xFF;
    const r = (sr * alpha + br * inv_alpha + 127) / 255;
    const g = (sg * alpha + bgc * inv_alpha + 127) / 255;
    const b = (sb * alpha + bb * inv_alpha + 127) / 255;
    return a | (r << 16) | (g << 8) | b;
}

const ComposeJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    config: Config,
    composed_pixels: usize,
};

fn noopComposeJob(_: *anyopaque) void {}

fn composeRowsJob(ctx_ptr: *anyopaque) void {
    const ctx: *ComposeJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.composed_pixels = composeRows(ctx.resources, ctx.bounds, ctx.config);
}

inline fn shouldParallelCompose(job_sys: ?*JobSystem, bounds: direct_primitives.Rect2i) bool {
    if (job_sys == null or job_sys.?.worker_count <= 1) return false;
    const area = @as(usize, @intCast(bounds.max_x - bounds.min_x + 1)) *
        @as(usize, @intCast(bounds.max_y - bounds.min_y + 1));
    return area >= 48 * 1024;
}

test "composition stage blends shaded pixels over background" {
    var color = [_]u32{
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
        0xFF0B1220, 0xFFFF0000, 0xFF00FF00, 0xFF0B1220,
        0xFF0B1220, 0xFF0000FF, 0xFFFFFFFF, 0xFF0B1220,
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
    };
    const resources: frame_resources.FrameResources = .{
        .target = .{
            .width = 4,
            .height = 4,
            .color = color[0..],
        },
        .aux = .{
            .scene_camera = &.{},
            .scene_normal = &.{},
            .scene_surface = &.{},
        },
    };

    const result = execute(resources, .{
        .min_x = 1,
        .min_y = 1,
        .max_x = 2,
        .max_y = 2,
    }, .{ .scene_alpha = 128 }, null);

    try std.testing.expectEqual(@as(usize, 4), result.composed_pixels);
    try std.testing.expect(color[5] != 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0B1220), color[0]);
}
