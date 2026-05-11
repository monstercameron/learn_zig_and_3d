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
    saturation: f32 = 1.0, // 1.0 = unchanged; >1 punchier, <1 desaturate
    contrast: f32 = 0.0, // 0 = unchanged; positive = S-curve steeper
    rim_light: f32 = 0.0, // 0..1; Fresnel rim boost using G-buffer normal
    rim_color_rgb: [3]f32 = .{ 1.0, 0.95, 0.85 }, // warm white default
    edge_darken: f32 = 0.0, // 0..1; depth-gradient edge darkening
    edge_threshold: f32 = 0.05, // depth delta that counts as an edge
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
    const any_effect = config.vignette != 0.0 or config.film_grain != 0.0 or
        config.saturation != 1.0 or config.contrast != 0.0 or
        config.rim_light != 0.0 or config.edge_darken != 0.0;
    if (!any_effect) return .{};
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
    const depth = resources.target.depth;
    const normals = resources.aux.scene_normal;
    const stride: usize = @intCast(resources.target.width);
    const width_i = resources.target.width;
    const height_i = resources.target.height;
    const inv_w: f32 = 1.0 / @as(f32, @floatFromInt(width_i));
    const inv_h: f32 = 1.0 / @as(f32, @floatFromInt(height_i));
    const vignette_amount = config.vignette;
    const grain_amount = config.film_grain;
    const sat = config.saturation;
    const contrast = config.contrast;
    const rim_amount = config.rim_light;
    const rim_r = config.rim_color_rgb[0];
    const rim_g = config.rim_color_rgb[1];
    const rim_b = config.rim_color_rgb[2];
    const edge_amount = config.edge_darken;
    const edge_threshold = config.edge_threshold;
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
            // Silhouette mask — only modify pixels with real depth.
            const has_depth: bool = if (depth) |dbuf| std.math.isFinite(dbuf[idx]) else true;
            if (!has_depth) {
                processed += 1;
                continue;
            }
            const xf: f32 = @floatFromInt(x);
            const ndc_x = (xf + 0.5) * inv_w - 0.5;
            const r2 = ndc_x * ndc_x + ndc_y_sq;
            const orig = color[idx];
            var rf: f32 = @as(f32, @floatFromInt((orig >> 16) & 0xFF));
            var gf: f32 = @as(f32, @floatFromInt((orig >> 8) & 0xFF));
            var bf: f32 = @as(f32, @floatFromInt(orig & 0xFF));

            // ---- Saturation: chroma scale around luminance ----
            if (sat != 1.0) {
                const lum = 0.299 * rf + 0.587 * gf + 0.114 * bf;
                rf = lum + (rf - lum) * sat;
                gf = lum + (gf - lum) * sat;
                bf = lum + (bf - lum) * sat;
            }

            // ---- Contrast: S-curve around 127.5 ----
            if (contrast != 0.0) {
                const c = 1.0 + contrast;
                rf = (rf - 127.5) * c + 127.5;
                gf = (gf - 127.5) * c + 127.5;
                bf = (bf - 127.5) * c + 127.5;
            }

            // ---- Rim light: Fresnel-style boost where the camera-space
            // normal points perpendicular to the view direction. Uses
            // G-buffer normal directly; view dir reconstructed from NDC.
            if (rim_amount > 0.0 and normals.len > 0) {
                const n = normals[idx];
                // Camera-space view direction toward the surface; assume
                // a unit-z forward camera, scaled to NDC.
                const view_x = ndc_x * 2.0;
                const view_y = ndc_y * 2.0;
                const view_z: f32 = 1.0;
                const v_len = @sqrt(view_x * view_x + view_y * view_y + view_z * view_z);
                const vx = view_x / v_len;
                const vy = view_y / v_len;
                const vz = view_z / v_len;
                const n_dot_v = @max(0.0, n.x * vx + n.y * vy + n.z * vz);
                const fresnel = std.math.pow(f32, 1.0 - n_dot_v, 4.0);
                const rim = fresnel * rim_amount * 255.0;
                rf += rim * rim_r;
                gf += rim * rim_g;
                bf += rim * rim_b;
            }

            // ---- Edge darken: depth-gradient outline.
            if (edge_amount > 0.0) {
                if (depth) |dbuf| {
                    const dc = dbuf[idx];
                    var grad: f32 = 0.0;
                    if (x > 0) {
                        const dl = dbuf[idx - 1];
                        if (std.math.isFinite(dl)) grad = @max(grad, @abs(dc - dl));
                    }
                    if (x + 1 < width_i) {
                        const dr = dbuf[idx + 1];
                        if (std.math.isFinite(dr)) grad = @max(grad, @abs(dc - dr));
                    }
                    if (y > 0) {
                        const du = dbuf[idx - stride];
                        if (std.math.isFinite(du)) grad = @max(grad, @abs(dc - du));
                    }
                    if (y + 1 < height_i) {
                        const dd = dbuf[idx + stride];
                        if (std.math.isFinite(dd)) grad = @max(grad, @abs(dc - dd));
                    }
                    if (grad > edge_threshold) {
                        const edge_factor = 1.0 - edge_amount;
                        rf *= edge_factor;
                        gf *= edge_factor;
                        bf *= edge_factor;
                    }
                }
            }

            // ---- Vignette: smoothstep darkening near corners.
            if (vignette_amount > 0.0) {
                const r2_norm: f32 = @min(@as(f32, 1.0), r2 * 2.0);
                const vig: f32 = 1.0 - vignette_amount * r2_norm;
                rf *= vig;
                gf *= vig;
                bf *= vig;
            }

            // ---- Film grain: integer hash → [-1, 1] noise ----
            if (grain_amount > 0.0) {
                const px: u32 = @bitCast(x);
                const py: u32 = @bitCast(y);
                var h: u32 = px *% 374761393 +% py *% 668265263 +% seed *% 2246822519;
                h ^= h >> 13;
                h *%= 1274126177;
                h ^= h >> 16;
                const grain_f: f32 = (@as(f32, @floatFromInt(h & 0xFFFF)) * (2.0 / 65535.0) - 1.0) * grain_amount * 255.0;
                rf += grain_f;
                gf += grain_f;
                bf += grain_f;
            }

            const ro: f32 = std.math.clamp(rf, 0.0, 255.0);
            const go: f32 = std.math.clamp(gf, 0.0, 255.0);
            const bo: f32 = std.math.clamp(bf, 0.0, 255.0);
            color[idx] = 0xFF000000 |
                (@as(u32, @intFromFloat(ro)) << 16) |
                (@as(u32, @intFromFloat(go)) << 8) |
                @as(u32, @intFromFloat(bo));
            processed += 1;
        }
    }
    return .{ .processed_pixels = processed };
}
