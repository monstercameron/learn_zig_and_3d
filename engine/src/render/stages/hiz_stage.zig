//! Hi-Z pyramid build + reject (ROADMAP §H7).
//!
//! Single-level pyramid keyed by the tile grid (16×16 tiles by default).
//! After raster, walk the depth buffer once and store the MAX depth
//! observed in each tile — that's the FARTHEST surface in that tile.
//! Next frame, before screen binning, a primitive whose MIN depth is
//! greater than every touched tile's MAX depth would fail the depth
//! test everywhere → cull it.
//!
//! Conservative semantics: the pyramid is from frame N-1 so culling is
//! valid only when the scene is roughly static. Moving objects are
//! handled by the normal depth test, never by Hi-Z (we just stop
//! culling things we shouldn't). The build cost is one linear scan of
//! the depth buffer per frame; the reject is O(tiles_touched) per
//! primitive.

const std = @import("std");
const job_system = @import("job_system");
const direct_primitives = @import("../direct/primitives.zig");
const TileRenderer = @import("../core/tile_renderer.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

// Match the renderer's tile grid so the pyramid is keyed the same way
// the binning stage indexes tiles (16×16 vs 64×64 mismatch was a real
// bug here — the pyramid early-returned because lengths didn't agree).
pub const TILE_SIZE: i32 = TileRenderer.TILE_SIZE;

pub const BuildResult = struct {
    tile_count: usize = 0,
};

/// Walks the depth buffer and writes the MAX depth per tile into
/// `pyramid`. `pyramid.len` must equal tile_cols * tile_rows. Skips
/// the work entirely if depth is null.
pub fn buildPyramid(
    depth: []const f32,
    width: i32,
    height: i32,
    pyramid: []f32,
    job_sys: ?*JobSystem,
) BuildResult {
    if (depth.len == 0 or pyramid.len == 0 or width <= 0 or height <= 0) return .{};
    const tile_cols: i32 = @divTrunc(width + TILE_SIZE - 1, TILE_SIZE);
    const tile_rows: i32 = @divTrunc(height + TILE_SIZE - 1, TILE_SIZE);
    const total_tiles: usize = @as(usize, @intCast(tile_cols)) * @as(usize, @intCast(tile_rows));
    if (total_tiles != pyramid.len) return .{};

    if (shouldParallel(job_sys, total_tiles)) {
        buildParallel(depth, width, height, pyramid, tile_cols, tile_rows, job_sys.?);
    } else {
        buildRows(depth, width, height, pyramid, tile_cols, 0, @intCast(tile_rows));
    }
    return .{ .tile_count = total_tiles };
}

fn buildRows(
    depth: []const f32,
    width: i32,
    height: i32,
    pyramid: []f32,
    tile_cols: i32,
    tile_row_start: usize,
    tile_row_end: usize,
) void {
    // Explicit SIMD: process LANES depths per inner iteration with
    // vmaxps (or vmaxss-equivalent on the target). Infinities are
    // filtered by replacing them with -inf before the reduce, so the
    // tile-max is "max of all finite depths" or +inf if none.
    const stride: usize = @intCast(width);
    const LANES: usize = @import("../../core/cpu_features.zig").SIMD_F32_LANES;
    const VF = @Vector(LANES, f32);
    const neg_inf_v: VF = @splat(-std.math.inf(f32));
    const far_thresh_v: VF = @splat(1.0e30);

    var ty: usize = tile_row_start;
    while (ty < tile_row_end) : (ty += 1) {
        const py_start: i32 = @as(i32, @intCast(ty)) * TILE_SIZE;
        const py_end: i32 = @min(py_start + TILE_SIZE, height);
        var tx: i32 = 0;
        while (tx < tile_cols) : (tx += 1) {
            const px_start = tx * TILE_SIZE;
            const px_end = @min(px_start + TILE_SIZE, width);
            const px_count = px_end - px_start;
            var max_v: VF = neg_inf_v;
            var max_d_scalar: f32 = -std.math.inf(f32);
            var has_finite = false;
            var y: i32 = py_start;
            while (y < py_end) : (y += 1) {
                const row = @as(usize, @intCast(y)) * stride;
                var x: i32 = px_start;
                // Vectorized inner: load LANES depths, mask infinities
                // to -inf, vmaxps into accumulator.
                while (x + @as(i32, @intCast(LANES)) <= px_end) : (x += @as(i32, @intCast(LANES))) {
                    var d_vec: VF = undefined;
                    inline for (0..LANES) |lane| {
                        d_vec[lane] = depth[row + @as(usize, @intCast(x + @as(i32, @intCast(lane))))];
                    }
                    // Replace far/inf values with -inf so the max is
                    // bounded by real finite depths. NaN-safe: x < inf
                    // is false for NaN, so NaN gets masked too.
                    const finite = d_vec < far_thresh_v;
                    const filtered = @select(f32, finite, d_vec, neg_inf_v);
                    max_v = @max(max_v, filtered);
                }
                // Scalar tail
                while (x < px_end) : (x += 1) {
                    const d = depth[row + @as(usize, @intCast(x))];
                    if (std.math.isFinite(d) and d < 1.0e30) {
                        if (d > max_d_scalar) max_d_scalar = d;
                        has_finite = true;
                    }
                }
            }
            const vec_reduced = @reduce(.Max, max_v);
            const tile_max = @max(vec_reduced, max_d_scalar);
            const any_finite = tile_max > -std.math.inf(f32) and (vec_reduced > -std.math.inf(f32) or has_finite);
            const tile_idx: usize = ty * @as(usize, @intCast(tile_cols)) + @as(usize, @intCast(tx));
            pyramid[tile_idx] = if (any_finite) tile_max else std.math.inf(f32);
            _ = px_count;
        }
    }
}

const BuildJobCtx = struct {
    depth: []const f32 align(64),
    width: i32,
    height: i32,
    pyramid: []f32,
    tile_cols: i32,
    tile_row_start: usize,
    tile_row_end: usize,
};

fn buildJobEntry(ctx_ptr: *anyopaque) void {
    const ctx: *BuildJobCtx = @ptrCast(@alignCast(ctx_ptr));
    buildRows(ctx.depth, ctx.width, ctx.height, ctx.pyramid, ctx.tile_cols, ctx.tile_row_start, ctx.tile_row_end);
}

fn noopJob(_: *anyopaque) void {}

fn buildParallel(
    depth: []const f32,
    width: i32,
    height: i32,
    pyramid: []f32,
    tile_cols: i32,
    tile_rows: i32,
    job_sys: *JobSystem,
) void {
    const total_rows: usize = @intCast(tile_rows);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]BuildJobCtx = undefined;
    var parent_job = Job.init(noopJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var row_start: usize = 0;
    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const remaining_rows = total_rows - row_start;
        const remaining_chunks = chunk_count - chunk_index;
        const chunk_rows = @max(remaining_rows / remaining_chunks, 1);
        const row_end = @min(total_rows, row_start + chunk_rows);
        contexts[chunk_index] = .{
            .depth = depth,
            .width = width,
            .height = height,
            .pyramid = pyramid,
            .tile_cols = tile_cols,
            .tile_row_start = row_start,
            .tile_row_end = row_end,
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(buildJobEntry, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                buildJobEntry(&contexts[chunk_index]);
            }
        }
        row_start = row_end;
    }
    if (main_chunk) |idx| buildJobEntry(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);
}

inline fn shouldParallel(job_sys: ?*JobSystem, tile_count: usize) bool {
    return job_sys != null and job_sys.?.worker_count > 1 and tile_count >= 64;
}

/// Returns true if the primitive bounded by `bounds` with closest-point
/// depth `min_depth` is entirely behind the depth content already
/// recorded in `pyramid` for every tile it touches.
///
/// `bounds` is the screen-space AABB of the primitive in pixels.
/// `min_depth` is the smallest vertex depth (closest to camera).
pub fn isOccluded(
    bounds: direct_primitives.Rect2i,
    min_depth: f32,
    pyramid: []const f32,
    width: i32,
    height: i32,
) bool {
    if (pyramid.len == 0) return false;
    if (!std.math.isFinite(min_depth)) return false;
    const tile_cols: i32 = @divTrunc(width + TILE_SIZE - 1, TILE_SIZE);
    const tile_rows: i32 = @divTrunc(height + TILE_SIZE - 1, TILE_SIZE);
    const min_tx = @max(0, @divTrunc(bounds.min_x, TILE_SIZE));
    const min_ty = @max(0, @divTrunc(bounds.min_y, TILE_SIZE));
    const max_tx = @min(tile_cols - 1, @divTrunc(bounds.max_x, TILE_SIZE));
    const max_ty = @min(tile_rows - 1, @divTrunc(bounds.max_y, TILE_SIZE));
    if (max_tx < min_tx or max_ty < min_ty) return true; // off-screen
    var ty = min_ty;
    while (ty <= max_ty) : (ty += 1) {
        const row = @as(usize, @intCast(ty)) * @as(usize, @intCast(tile_cols));
        var tx = min_tx;
        while (tx <= max_tx) : (tx += 1) {
            const tile_max = pyramid[row + @as(usize, @intCast(tx))];
            // Any tile that could still pass (min_depth <= tile_max)
            // disqualifies the cull.
            if (min_depth <= tile_max) return false;
        }
    }
    return true;
}
