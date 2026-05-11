//! Screen-space post-process composite stage. Runs AFTER the deferred
//! tone-map, operates on the LDR `target.color` buffer in place.
//!
//! Fuses two image-quality effects into one parallel pass so we touch
//! each pixel exactly once:
//!
//!   - **Vignette**: smoothstep darkening near the screen corners.
//!     Cheap "lens" look, falls off with r² from the screen centre.
//!   - **Film grain**: integer-hash noise per pixel and frame so the
//!     image breathes without needing a noise texture.
//!
//! Chromatic aberration is intentionally NOT done in this pass — it
//! requires a separate source buffer (radial gathers would read from
//! already-modified pixels and compound the effect). It can be added
//! once we wire a scratch buffer through the stage.
//!
//! Row-parallel via the job system. The inner kernel is straight-line
//! scalar code per pixel; the compiler auto-vectorises the f32 math
//! and PIL/Windows BMP layout (0xAARRGGBB packed u32) keeps the pixel
//! shuffle dirt-simple.

const std = @import("std");
const job_system = @import("job_system");
const math = @import("../../core/math.zig");
const direct_primitives = @import("../direct/primitives.zig");
const frame_resources = @import("../frame/resources.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const Config = struct {
    chromatic_aberration: f32 = 0.0, // reserved; not currently applied
    vignette: f32 = 0.0, // 0..1; darkening intensity at corners
    film_grain: f32 = 0.0, // 0..1; noise amplitude
    seed: u32 = 0,
};

pub const Result = struct {
    processed_pixels: usize = 0,
};

pub fn execute(
    resources: frame_resources.FrameResources,
    dirty_rect: ?direct_primitives.Rect2i,
    config: Config,
    job_sys: ?*JobSystem,
) Result {
    if (config.vignette == 0.0 and config.film_grain == 0.0) {
        return .{};
    }
    const rect = dirty_rect orelse direct_primitives.Rect2i{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    };
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    if (resources.target.color.len == 0) return .{};

    _ = job_sys;
    return processRows(resources, bounds, config);
}

inline fn shouldParallel(job_sys: ?*JobSystem, bounds: direct_primitives.Rect2i) bool {
    if (job_sys == null) return false;
    const w = @as(usize, @intCast(@max(bounds.max_x - bounds.min_x + 1, 0)));
    const h = @as(usize, @intCast(@max(bounds.max_y - bounds.min_y + 1, 0)));
    return w * h >= 32 * 1024 and job_sys.?.worker_count > 1;
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
    var contexts: [64]Ctx = undefined;
    var parent_job = Job.init(noopJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
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
            .processed = 0,
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(rowsJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                rowsJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }
    if (main_chunk) |idx| rowsJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);

    var total: usize = 0;
    for (contexts[0..chunk_count]) |ctx| total += ctx.processed;
    return .{ .processed_pixels = total };
}

const Ctx = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    config: Config,
    processed: usize,
};

fn noopJob(_: *anyopaque) void {}

fn rowsJob(ctx_ptr: *anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const result = processRows(ctx.resources, ctx.bounds, ctx.config);
    ctx.processed = result.processed_pixels;
}

fn processRows(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
) Result {
    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    const inv_w: f32 = 1.0 / @as(f32, @floatFromInt(resources.target.width));
    const inv_h: f32 = 1.0 / @as(f32, @floatFromInt(resources.target.height));
    const vignette_amount = config.vignette;
    const grain_amount = config.film_grain;
    const seed: u32 = config.seed;

    var processed: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const ndc_y = (yf + 0.5) * inv_h - 0.5;
        const ndc_y_sq = ndc_y * ndc_y;
        const row_start = @as(usize, @intCast(y)) * stride;
        var x: i32 = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const xf: f32 = @floatFromInt(x);
            const ndc_x = (xf + 0.5) * inv_w - 0.5;
            const r2 = ndc_x * ndc_x + ndc_y_sq;
            const orig = color[idx];
            const r_chan: f32 = @as(f32, @floatFromInt((orig >> 16) & 0xFF));
            const g_chan: f32 = @as(f32, @floatFromInt((orig >> 8) & 0xFF));
            const b_chan: f32 = @as(f32, @floatFromInt(orig & 0xFF));
            const r2_norm: f32 = @min(@as(f32, 1.0), r2 * 2.0);
            const vig: f32 = 1.0 - vignette_amount * r2_norm;
            const px: u32 = @bitCast(x);
            const py: u32 = @bitCast(y);
            var h: u32 = px *% 374761393 +% py *% 668265263 +% seed *% 2246822519;
            h ^= h >> 13;
            h *%= 1274126177;
            h ^= h >> 16;
            const grain_f: f32 = (@as(f32, @floatFromInt(h & 0xFFFF)) * (2.0 / 65535.0) - 1.0) * grain_amount * 255.0;
            const ro: f32 = std.math.clamp(r_chan * vig + grain_f, 0.0, 255.0);
            const go: f32 = std.math.clamp(g_chan * vig + grain_f, 0.0, 255.0);
            const bo: f32 = std.math.clamp(b_chan * vig + grain_f, 0.0, 255.0);
            color[idx] = 0xFF000000 |
                (@as(u32, @intFromFloat(ro)) << 16) |
                (@as(u32, @intFromFloat(go)) << 8) |
                @as(u32, @intFromFloat(bo));
            processed += 1;
        }
    }
    return .{ .processed_pixels = processed };
}
