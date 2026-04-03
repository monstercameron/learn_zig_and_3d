const std = @import("std");
const job_system = @import("job_system");
const math = @import("../../core/math.zig");
const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const Config = struct {
    clear_color: u32 = 0xFF0B1220,
    enabled: bool = true,
    ambient: f32 = 0.62,
    diffuse: f32 = 0.38,
    light_dir: math.Vec3 = math.Vec3.new(-0.35, -0.45, 0.82),
};

pub const Result = struct {
    shaded_rect: ?direct_primitives.Rect2i = null,
    shaded_pixels: usize = 0,
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
    const width = bounds.max_x - bounds.min_x + 1;
    const height = bounds.max_y - bounds.min_y + 1;
    if (width <= 0 or height <= 0 or resources.target.color.len == 0) return .{};
    if (!config.enabled or config.diffuse == 0.0) {
        return .{ .shaded_rect = bounds, .shaded_pixels = 0 };
    }

    const normalized_light = normalizeLight(config.light_dir);
    const frame_width_f = @as(f32, @floatFromInt(@max(resources.target.width - 1, 1)));
    const frame_height_f = @as(f32, @floatFromInt(@max(resources.target.height - 1, 1)));
    const x_step = if (resources.target.width > 1) 2.0 / frame_width_f else 0.0;
    const delta_intensity = intensityToFixed(-(config.diffuse * 0.22 * normalized_light.x * x_step));
    if (shouldParallelShade(job_sys, width, height)) {
        return executeParallel(resources, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity, job_sys.?);
    }

    return .{
        .shaded_rect = bounds,
        .shaded_pixels = shadeRows(resources, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity),
    };
}

fn executeParallel(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
    job_sys: *JobSystem,
) Result {
    const total_rows: usize = @intCast(bounds.max_y - bounds.min_y + 1);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]ShadeJobContext = undefined;
    var parent_job = Job.init(noopShadeJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var shaded_pixels: usize = 0;
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
            .normalized_light = normalized_light,
            .frame_width_f = frame_width_f,
            .frame_height_f = frame_height_f,
            .delta_intensity = delta_intensity,
            .shaded_pixels = 0,
        };

        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(shadeRowsJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                shadeRowsJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }

    if (main_chunk) |idx| shadeRowsJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);

    for (contexts[0..chunk_count]) |ctx| shaded_pixels += ctx.shaded_pixels;
    return .{
        .shaded_rect = bounds,
        .shaded_pixels = shaded_pixels,
    };
}

fn shadeRows(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
) usize {
    if (resources.target.depth) |depth_buffer| {
        return shadeRowsDepth(resources, depth_buffer, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity);
    }
    return shadeRowsColorOnly(resources, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity);
}

fn shadeRowsDepth(
    resources: frame_resources.FrameResources,
    depth_buffer: []f32,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
) usize {
    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    const clear_color = config.clear_color;
    var shaded_pixels: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        const screen_y = if (resources.target.height > 1)
            (@as(f32, @floatFromInt(y)) / frame_height_f) * 2.0 - 1.0
        else
            0.0;
        var intensity = shadeIntensityStart(bounds.min_x, frame_width_f, screen_y, normalized_light, config);
        var x = bounds.min_x;
        while (x + 3 <= bounds.max_x) : (x += 4) {
            inline for (0..4) |lane| {
                const idx = row_start + @as(usize, @intCast(x + @as(i32, @intCast(lane))));
                const pixel = color[idx];
                if (pixel != clear_color and std.math.isFinite(depth_buffer[idx])) {
                    color[idx] = shadeColorFixed(pixel, intensity);
                    shaded_pixels += 1;
                }
                intensity = clampIntensityFixed(intensity + delta_intensity);
            }
        }
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const pixel = color[idx];
            if (pixel != clear_color and std.math.isFinite(depth_buffer[idx])) {
                color[idx] = shadeColorFixed(pixel, intensity);
                shaded_pixels += 1;
            }
            intensity = clampIntensityFixed(intensity + delta_intensity);
        }
    }
    return shaded_pixels;
}

fn shadeRowsColorOnly(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
) usize {
    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    const clear_color = config.clear_color;
    var shaded_pixels: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        const screen_y = if (resources.target.height > 1)
            (@as(f32, @floatFromInt(y)) / frame_height_f) * 2.0 - 1.0
        else
            0.0;
        var intensity = shadeIntensityStart(bounds.min_x, frame_width_f, screen_y, normalized_light, config);
        var x = bounds.min_x;
        while (x + 3 <= bounds.max_x) : (x += 4) {
            inline for (0..4) |lane| {
                const idx = row_start + @as(usize, @intCast(x + @as(i32, @intCast(lane))));
                const pixel = color[idx];
                if (pixel != clear_color) {
                    color[idx] = shadeColorFixed(pixel, intensity);
                    shaded_pixels += 1;
                }
                intensity = clampIntensityFixed(intensity + delta_intensity);
            }
        }
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const pixel = color[idx];
            if (pixel != clear_color) {
                color[idx] = shadeColorFixed(pixel, intensity);
                shaded_pixels += 1;
            }
            intensity = clampIntensityFixed(intensity + delta_intensity);
        }
    }
    return shaded_pixels;
}

const ShadeJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
    shaded_pixels: usize,
};

fn noopShadeJob(_: *anyopaque) void {}

fn shadeRowsJob(ctx_ptr: *anyopaque) void {
    const ctx: *ShadeJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.shaded_pixels = shadeRows(
        ctx.resources,
        ctx.bounds,
        ctx.config,
        ctx.normalized_light,
        ctx.frame_width_f,
        ctx.frame_height_f,
        ctx.delta_intensity,
    );
}

inline fn shouldParallelShade(job_sys: ?*JobSystem, width: i32, height: i32) bool {
    if (job_sys == null) return false;
    const area = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    return area >= 32 * 1024 and job_sys.?.worker_count > 1;
}

inline fn normalizeLight(light: math.Vec3) math.Vec3 {
    const length_sq = light.x * light.x + light.y * light.y + light.z * light.z;
    if (length_sq <= 0.0) return math.Vec3.new(0.0, 0.0, 1.0);
    const inv_len = 1.0 / std.math.sqrt(length_sq);
    return math.Vec3.new(light.x * inv_len, light.y * inv_len, light.z * inv_len);
}

inline fn shadeIntensityStart(min_x: i32, frame_width_f: f32, screen_y: f32, light_dir: math.Vec3, config: Config) i32 {
    const screen_x = if (frame_width_f > 0.0)
        (@as(f32, @floatFromInt(min_x)) / frame_width_f) * 2.0 - 1.0
    else
        0.0;
    return intensityToFixed(shadeIntensity(screen_x, screen_y, light_dir, config));
}

inline fn intensityToFixed(intensity: f32) i32 {
    return @as(i32, @intFromFloat(@round(std.math.clamp(intensity, 0.0, 1.0) * 256.0)));
}

inline fn clampIntensityFixed(intensity: i32) i32 {
    return std.math.clamp(intensity, 0, 256);
}

inline fn shadeIntensity(screen_x: f32, screen_y: f32, light_dir: math.Vec3, config: Config) f32 {
    const directional = light_dir.z - (screen_x * 0.22 * light_dir.x) - (screen_y * 0.28 * light_dir.y);
    const diffuse = std.math.clamp(directional, 0.0, 1.0);
    return std.math.clamp(config.ambient + config.diffuse * diffuse, 0.0, 1.0);
}

inline fn shadeColorFixed(color: u32, intensity_fixed: i32) u32 {
    if (intensity_fixed >= 256) return color;
    if (intensity_fixed <= 0) return color & 0xFF000000;
    const a: u32 = color & 0xFF000000;
    const factor: u32 = @intCast(intensity_fixed);
    const r = (((color >> 16) & 0xFF) * factor + 128) >> 8;
    const g = (((color >> 8) & 0xFF) * factor + 128) >> 8;
    const b = (((color) & 0xFF) * factor + 128) >> 8;
    return a | (r << 16) | (g << 8) | b;
}

test "shading stage shades non-clear pixels in dirty rect" {
    var color = [_]u32{
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
        0xFF0B1220, 0xFFFF0000, 0xFF00FF00, 0xFF0B1220,
        0xFF0B1220, 0xFF0000FF, 0xFFFFFFFF, 0xFF0B1220,
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
    };
    var depth = [_]f32{
        std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), std.math.inf(f32),
        std.math.inf(f32), 1.0, 1.0, std.math.inf(f32),
        std.math.inf(f32), 1.0, 1.0, std.math.inf(f32),
        std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), std.math.inf(f32),
    };
    const resources: frame_resources.FrameResources = .{
        .target = .{
            .width = 4,
            .height = 4,
            .color = color[0..],
            .depth = depth[0..],
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
        .max_y = 3,
    }, .{}, null);

    try std.testing.expectEqual(@as(usize, 4), result.shaded_pixels);
    try std.testing.expect(color[5] != 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0B1220), color[0]);
}
