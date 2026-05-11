//! HDR post-process stage (ROADMAP §H6).
//!
//! Runs between deferred lighting and the tone-map stage. Operates on
//! the linear HDR scene buffer (Vec4 per pixel). Today it's a single
//! luminance probe that the agent can read to understand the HDR
//! range produced by the lighting pass — necessary groundwork for
//! auto-exposure, HDR bloom, eye adaptation, and downstream filmic
//! tone-mapping curves.
//!
//! Adding more passes here (bloom, ssao-in-linear, etc.) wires through
//! the same call site in direct_backend. The stage budget is reported
//! via `hdr_post_ns` in the introspection snapshot.

const std = @import("std");
const job_system = @import("job_system");
const math = @import("../../core/math.zig");
const cpu_features = @import("../../core/cpu_features.zig");
const direct_primitives = @import("../direct/primitives.zig");
const frame_resources = @import("../frame/resources.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const LuminanceProbeResult = struct {
    /// Number of lit pixels (hdr.w != 0) considered.
    sampled_pixels: usize = 0,
    /// Average linear luminance (Rec. 709) across sampled pixels.
    avg_luminance: f32 = 0.0,
    /// Maximum linear luminance observed.
    max_luminance: f32 = 0.0,
    /// Sum of luminance values — useful for downstream weighted blending.
    sum_luminance: f64 = 0.0,
};

pub fn executeLuminanceProbe(
    resources: frame_resources.FrameResources,
    dirty_rect: ?direct_primitives.Rect2i,
    job_sys: ?*JobSystem,
) LuminanceProbeResult {
    const rect = dirty_rect orelse return .{};
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    if (resources.aux.scene_hdr.len == 0) return .{};

    if (shouldParallel(job_sys, bounds)) {
        return probeParallel(resources, bounds, job_sys.?);
    }
    return probeRows(resources, bounds);
}

fn probeParallel(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    job_sys: *JobSystem,
) LuminanceProbeResult {
    const total_rows: usize = @intCast(bounds.max_y - bounds.min_y + 1);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]ProbeJobContext = undefined;
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
            .result = .{},
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(probeRowsJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                probeRowsJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }
    if (main_chunk) |idx| probeRowsJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);

    var merged = LuminanceProbeResult{};
    for (contexts[0..chunk_count]) |ctx| {
        merged.sampled_pixels += ctx.result.sampled_pixels;
        merged.sum_luminance += ctx.result.sum_luminance;
        if (ctx.result.max_luminance > merged.max_luminance) merged.max_luminance = ctx.result.max_luminance;
    }
    merged.avg_luminance = if (merged.sampled_pixels > 0)
        @as(f32, @floatCast(merged.sum_luminance / @as(f64, @floatFromInt(merged.sampled_pixels))))
    else
        0.0;
    return merged;
}

const ProbeJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    result: LuminanceProbeResult,
};

fn noopJob(_: *anyopaque) void {}

fn probeRowsJob(ctx_ptr: *anyopaque) void {
    const ctx: *ProbeJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.result = probeRows(ctx.resources, ctx.bounds);
}

fn probeRows(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
) LuminanceProbeResult {
    // ISA-portable SIMD probe. Lane count = SIMD_F32_LANES (4/8/16
    // depending on target SSE2/AVX/AVX-512, NEON, SVE). Compute
    // Rec.709 luminance for N pixels per iteration; reduce sum + max
    // across lanes outside the inner loop. Masked write pattern keeps
    // unlit pixels out of the sums.
    const lanes: usize = cpu_features.SIMD_F32_LANES;
    const VecF = @Vector(lanes, f32);

    const hdr = resources.aux.scene_hdr;
    const stride: usize = @intCast(resources.target.width);
    const wr_v: VecF = @splat(0.2126);
    const wg_v: VecF = @splat(0.7152);
    const wb_v: VecF = @splat(0.0722);
    const zero_v: VecF = @splat(0.0);
    var result = LuminanceProbeResult{};
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        var x = bounds.min_x;
        // Vectorized body — accumulate 8 lanes per iteration.
        while (x + @as(i32, @intCast(lanes)) <= bounds.max_x + 1) : (x += @as(i32, @intCast(lanes))) {
            const base_idx = row_start + @as(usize, @intCast(x));
            var rv: VecF = undefined;
            var gv: VecF = undefined;
            var bv: VecF = undefined;
            var wv: VecF = undefined;
            comptime var lane: usize = 0;
            inline while (lane < lanes) : (lane += 1) {
                rv[lane] = hdr[base_idx + lane].x;
                gv[lane] = hdr[base_idx + lane].y;
                bv[lane] = hdr[base_idx + lane].z;
                wv[lane] = hdr[base_idx + lane].w;
            }
            const lum_v = rv * wr_v + gv * wg_v + bv * wb_v;
            // Mask out unlit lanes by replacing with zero before sum
            // and -inf before max-reduce — keeps math branchless.
            const lit_mask = wv != zero_v;
            const masked_lum = @select(f32, lit_mask, lum_v, zero_v);
            const neg_inf: VecF = @splat(-std.math.inf(f32));
            const masked_for_max = @select(f32, lit_mask, lum_v, neg_inf);
            result.sum_luminance += @as(f64, @reduce(.Add, masked_lum));
            const block_max = @reduce(.Max, masked_for_max);
            if (block_max > result.max_luminance) result.max_luminance = block_max;
            // Count lit pixels in the 8-lane block.
            const ones: @Vector(lanes, u32) = @splat(1);
            const zeros: @Vector(lanes, u32) = @splat(0);
            const lit_counts = @select(u32, lit_mask, ones, zeros);
            result.sampled_pixels += @reduce(.Add, lit_counts);
        }
        // Scalar tail.
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const v = hdr[idx];
            if (v.w == 0.0) continue;
            const lum = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z;
            result.sum_luminance += @as(f64, lum);
            if (lum > result.max_luminance) result.max_luminance = lum;
            result.sampled_pixels += 1;
        }
    }
    if (result.sampled_pixels > 0) {
        result.avg_luminance = @as(f32, @floatCast(result.sum_luminance / @as(f64, @floatFromInt(result.sampled_pixels))));
    }
    return result;
}

inline fn shouldParallel(job_sys: ?*JobSystem, bounds: direct_primitives.Rect2i) bool {
    if (job_sys == null) return false;
    const w = @as(usize, @intCast(@max(bounds.max_x - bounds.min_x + 1, 0)));
    const h = @as(usize, @intCast(@max(bounds.max_y - bounds.min_y + 1, 0)));
    return w * h >= 32 * 1024 and job_sys.?.worker_count > 1;
}
