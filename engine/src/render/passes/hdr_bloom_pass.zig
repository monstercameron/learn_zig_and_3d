//! HDR bloom (ROADMAP §H6).
//!
//! Reads the linear HDR scene buffer, extracts pixels above a bright
//! threshold, runs a separable Gaussian blur on a 1/4-resolution scratch,
//! and composites the blurred result back into scene_hdr before
//! tone-map.
//!
//! Bloom only makes sense on a real HDR signal — pixels >1.0 luminance
//! are the visual cue for "this is a light source". The lighting stage's
//! intensity multiplier (DeferredConfig.intensity > 1) is what generates
//! those pixels.
//!
//! Four passes:
//!   1. Bright-pass + downsample: scene_hdr (full res)  -> scratch_a (1/4 res)
//!   2. Horizontal Gaussian blur:  scratch_a            -> scratch_b
//!   3. Vertical Gaussian blur:    scratch_b            -> scratch_a
//!   4. Upsample + add:            scratch_a            -> scene_hdr
//!
//! Scratch buffers are caller-supplied (allocated once on Renderer init).

const std = @import("std");
const job_system = @import("job_system");
const math = @import("../../core/math.zig");
const cpu_features = @import("../../core/cpu_features.zig");
const direct_primitives = @import("../direct/primitives.zig");
const frame_resources = @import("../frame/resources.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const DOWNSAMPLE: i32 = 4;

pub const Config = struct {
    /// Pixels with linear luminance above this contribute to bloom.
    bright_threshold: f32 = 1.0,
    /// Strength of the bloom contribution added back to scene_hdr.
    /// 1.0 = full add; lower values produce subtler bloom.
    intensity: f32 = 0.6,
};

pub const Result = struct {
    bright_pixels: usize = 0,
    bloom_width: i32 = 0,
    bloom_height: i32 = 0,
};

pub const Scratch = struct {
    width: i32,
    height: i32,
    ping: []math.Vec4,
    pong: []math.Vec4,
};

/// Allocates the two 1/4-res scratch buffers and returns them. Caller
/// owns the slices and must free with `freeScratch`.
pub fn allocateScratch(allocator: std.mem.Allocator, full_width: i32, full_height: i32) !Scratch {
    const w = @max(@as(i32, 1), @divTrunc(full_width + DOWNSAMPLE - 1, DOWNSAMPLE));
    const h = @max(@as(i32, 1), @divTrunc(full_height + DOWNSAMPLE - 1, DOWNSAMPLE));
    const count = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    const ping = try allocator.alignedAlloc(math.Vec4, std.mem.Alignment.@"64", count);
    errdefer allocator.free(ping);
    const pong = try allocator.alignedAlloc(math.Vec4, std.mem.Alignment.@"64", count);
    errdefer allocator.free(pong);
    return .{ .width = w, .height = h, .ping = ping, .pong = pong };
}

pub fn freeScratch(allocator: std.mem.Allocator, scratch: Scratch) void {
    allocator.free(scratch.ping);
    allocator.free(scratch.pong);
}

pub fn execute(
    resources: frame_resources.FrameResources,
    scratch: Scratch,
    config: Config,
    job_sys: ?*JobSystem,
) Result {
    if (resources.aux.scene_hdr.len == 0) return .{};
    if (scratch.ping.len == 0 or scratch.pong.len == 0) return .{};

    var bp_ctx = BrightPassCtx{
        .src = resources.aux.scene_hdr,
        .dst = scratch.ping,
        .src_w = @intCast(resources.target.width),
        .src_h = @intCast(resources.target.height),
        .dst_w = @intCast(scratch.width),
        .threshold = config.bright_threshold,
    };
    const bright = runRowsParallel(@as(usize, @intCast(scratch.height)), @ptrCast(&bp_ctx), brightPassRows, job_sys);

    var blur_ctx = BlurCtx{
        .scratch = scratch,
        .stride = @intCast(scratch.width),
    };
    _ = runRowsParallel(@as(usize, @intCast(scratch.height)), @ptrCast(&blur_ctx), blurHorizontalRows, job_sys);
    _ = runRowsParallel(@as(usize, @intCast(scratch.height)), @ptrCast(&blur_ctx), blurVerticalRows, job_sys);

    var up_ctx = UpsampleCtx{
        .dst = resources.aux.scene_hdr,
        .src = scratch.ping,
        .dst_w = @intCast(resources.target.width),
        .src_w_i = scratch.width,
        .src_h_i = scratch.height,
        .src_stride = @intCast(scratch.width),
        .inv_ds = 1.0 / @as(f32, @floatFromInt(DOWNSAMPLE)),
        .intensity = config.intensity,
    };
    _ = runRowsParallel(@as(usize, @intCast(resources.target.height)), @ptrCast(&up_ctx), upsampleAddRows, job_sys);

    return .{
        .bright_pixels = bright,
        .bloom_width = scratch.width,
        .bloom_height = scratch.height,
    };
}

// === Generic row-parallel runner ===
const RowJobFn = *const fn (start: usize, end: usize, ctx: *anyopaque) usize;

const RowJobContext = struct {
    fn_ptr: RowJobFn align(64),
    user_ctx: *anyopaque,
    start: usize,
    end: usize,
    result: usize,
};

fn rowJobEntry(ctx_ptr: *anyopaque) void {
    const ctx: *RowJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.result = ctx.fn_ptr(ctx.start, ctx.end, ctx.user_ctx);
}

fn noopJob(_: *anyopaque) void {}

fn runRowsParallel(
    total_rows: usize,
    user_ctx: *anyopaque,
    func: RowJobFn,
    job_sys_opt: ?*JobSystem,
) usize {
    if (total_rows == 0) return 0;
    if (job_sys_opt == null or job_sys_opt.?.worker_count <= 1 or total_rows < 16) {
        return func(0, total_rows, user_ctx);
    }
    const job_sys = job_sys_opt.?;
    const worker_count = @as(usize, job_sys.worker_count);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]RowJobContext = undefined;
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
            .fn_ptr = func,
            .user_ctx = user_ctx,
            .start = row_start,
            .end = row_end,
            .result = 0,
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(rowJobEntry, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                rowJobEntry(&contexts[chunk_index]);
            }
        }
        row_start = row_end;
    }
    if (main_chunk) |idx| rowJobEntry(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);
    var total: usize = 0;
    for (contexts[0..chunk_count]) |c| total += c.result;
    return total;
}

// === Pass 1: bright-pass + downsample ===
const BrightPassCtx = struct {
    src: []const math.Vec4,
    dst: []math.Vec4,
    src_w: usize,
    src_h: usize,
    dst_w: usize,
    threshold: f32,
};

fn brightPassRows(start: usize, end: usize, raw: *anyopaque) usize {
    const ctx: *BrightPassCtx = @ptrCast(@alignCast(raw));
    // Inner 4×4 source block is too small to SIMD per-output-pixel —
    // instead the dominant cost is bandwidth (reading 16 Vec4 samples).
    // We use a fixed @Vector(4, f32) reduce across the 4-pixel row for
    // each source row of the block, so the accumulator stays in YMM/ZMM
    // registers.
    const V4 = @Vector(4, f32);
    const ds: usize = @intCast(DOWNSAMPLE);
    var bright_count: usize = 0;
    var dy = start;
    while (dy < end) : (dy += 1) {
        const sy0 = dy * ds;
        var dx: usize = 0;
        while (dx < ctx.dst_w) : (dx += 1) {
            const sx0 = dx * ds;
            var r_acc: V4 = @splat(0.0);
            var g_acc: V4 = @splat(0.0);
            var b_acc: V4 = @splat(0.0);
            var n_acc: V4 = @splat(0.0);
            var oy: usize = 0;
            while (oy < ds and sy0 + oy < ctx.src_h) : (oy += 1) {
                const sy = sy0 + oy;
                var ox: usize = 0;
                // 4-wide row load — DOWNSAMPLE is 4 so we read 4
                // samples per source row.
                while (ox + 4 <= ds and sx0 + ox + 3 < ctx.src_w) : (ox += 4) {
                    const row_base = sy * ctx.src_w + sx0 + ox;
                    const v0 = ctx.src[row_base + 0];
                    const v1 = ctx.src[row_base + 1];
                    const v2 = ctx.src[row_base + 2];
                    const v3 = ctx.src[row_base + 3];
                    const r_v: V4 = .{ v0.x, v1.x, v2.x, v3.x };
                    const g_v: V4 = .{ v0.y, v1.y, v2.y, v3.y };
                    const b_v: V4 = .{ v0.z, v1.z, v2.z, v3.z };
                    const w_v: V4 = .{ v0.w, v1.w, v2.w, v3.w };
                    const valid = w_v != @as(V4, @splat(0.0));
                    const r_masked = @select(f32, valid, r_v, @as(V4, @splat(0.0)));
                    const g_masked = @select(f32, valid, g_v, @as(V4, @splat(0.0)));
                    const b_masked = @select(f32, valid, b_v, @as(V4, @splat(0.0)));
                    const n_masked = @select(f32, valid, @as(V4, @splat(1.0)), @as(V4, @splat(0.0)));
                    r_acc += r_masked;
                    g_acc += g_masked;
                    b_acc += b_masked;
                    n_acc += n_masked;
                }
                // Scalar tail when DOWNSAMPLE is not a multiple of 4
                // or when we run off the source-image edge.
                while (ox < ds and sx0 + ox < ctx.src_w) : (ox += 1) {
                    const v = ctx.src[sy * ctx.src_w + sx0 + ox];
                    if (v.w != 0.0) {
                        r_acc[0] += v.x;
                        g_acc[0] += v.y;
                        b_acc[0] += v.z;
                        n_acc[0] += 1.0;
                    }
                }
            }
            const r_total = @reduce(.Add, r_acc);
            const g_total = @reduce(.Add, g_acc);
            const b_total = @reduce(.Add, b_acc);
            const n_total = @reduce(.Add, n_acc);
            if (n_total > 0.0) {
                const inv = 1.0 / n_total;
                const r = r_total * inv;
                const g = g_total * inv;
                const b = b_total * inv;
                const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                if (lum > ctx.threshold) {
                    const excess = lum - ctx.threshold;
                    const scale = excess / @max(lum, 1e-4);
                    ctx.dst[dy * ctx.dst_w + dx] = math.Vec4.new(r * scale, g * scale, b * scale, 1.0);
                    bright_count += 1;
                    continue;
                }
            }
            ctx.dst[dy * ctx.dst_w + dx] = math.Vec4.new(0.0, 0.0, 0.0, 0.0);
        }
    }
    return bright_count;
}

// Separable 9-tap Gaussian (sigma ~1.6). Weights centred on tap 4.
const gauss_weights = [_]f32{
    0.027, 0.065, 0.121, 0.176, 0.222, 0.176, 0.121, 0.065, 0.027,
};

const BlurCtx = struct {
    scratch: Scratch,
    stride: usize,
};

fn blurHorizontalRows(start: usize, end: usize, raw: *anyopaque) usize {
    // SIMD across LANES output X columns per iteration. For each
    // output[x..x+LANES], compute the 9-tap weighted sum by reading
    // shifted neighborhoods. The 9 source-x positions are scalars
    // gathered into a lane vector per tap; clamp via @max/@min at edges.
    const ctx: *BlurCtx = @ptrCast(@alignCast(raw));
    const LANES: usize = cpu_features.SIMD_F32_LANES;
    const VF = @Vector(LANES, f32);
    const VI = @Vector(LANES, i32);
    const src = ctx.scratch.ping;
    const dst = ctx.scratch.pong;
    const w: i32 = ctx.scratch.width;
    const w_minus_1: VI = @splat(w - 1);
    const zero_i: VI = @splat(0);
    var y: usize = start;
    while (y < end) : (y += 1) {
        const row = y * ctx.stride;
        var x: i32 = 0;
        while (x + @as(i32, @intCast(LANES)) <= w) : (x += @as(i32, @intCast(LANES))) {
            // Lane indices [x, x+1, ..., x+LANES-1]
            var lane_x: VI = undefined;
            inline for (0..LANES) |l| {
                lane_x[l] = x + @as(i32, @intCast(l));
            }
            var r_acc: VF = @splat(0.0);
            var g_acc: VF = @splat(0.0);
            var b_acc: VF = @splat(0.0);
            // Unroll 9 taps. Each tap shifts the read x by (i - 4).
            inline for (0..9) |i| {
                const offset: VI = @splat(@as(i32, @intCast(i)) - 4);
                const sx_unclamped = lane_x + offset;
                const sx = @max(zero_i, @min(w_minus_1, sx_unclamped));
                var r_v: VF = undefined;
                var g_v: VF = undefined;
                var b_v: VF = undefined;
                inline for (0..LANES) |l| {
                    const v = src[row + @as(usize, @intCast(sx[l]))];
                    r_v[l] = v.x;
                    g_v[l] = v.y;
                    b_v[l] = v.z;
                }
                const wt: VF = @splat(gauss_weights[i]);
                r_acc += r_v * wt;
                g_acc += g_v * wt;
                b_acc += b_v * wt;
            }
            // Scatter the lane vector back to dst as Vec4 entries.
            inline for (0..LANES) |l| {
                dst[row + @as(usize, @intCast(x + @as(i32, @intCast(l))))] = math.Vec4.new(r_acc[l], g_acc[l], b_acc[l], 1.0);
            }
        }
        // Scalar tail
        while (x < w) : (x += 1) {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            inline for (0..9) |i| {
                const sx = std.math.clamp(x + @as(i32, @intCast(i)) - 4, 0, w - 1);
                const v = src[row + @as(usize, @intCast(sx))];
                const wt = gauss_weights[i];
                r += v.x * wt;
                g += v.y * wt;
                b += v.z * wt;
            }
            dst[row + @as(usize, @intCast(x))] = math.Vec4.new(r, g, b, 1.0);
        }
    }
    return 0;
}

fn blurVerticalRows(start: usize, end: usize, raw: *anyopaque) usize {
    // SIMD across LANES output X columns per row. Vertical taps share
    // the same y for all output X, so this is friendlier to SIMD than
    // the horizontal pass — no per-tap edge clamp needed within the X
    // dimension.
    const ctx: *BlurCtx = @ptrCast(@alignCast(raw));
    const LANES: usize = cpu_features.SIMD_F32_LANES;
    const VF = @Vector(LANES, f32);
    const src = ctx.scratch.pong;
    const dst = ctx.scratch.ping;
    const w: i32 = ctx.scratch.width;
    const h: i32 = ctx.scratch.height;
    var y: usize = start;
    while (y < end) : (y += 1) {
        var x: i32 = 0;
        while (x + @as(i32, @intCast(LANES)) <= w) : (x += @as(i32, @intCast(LANES))) {
            var r_acc: VF = @splat(0.0);
            var g_acc: VF = @splat(0.0);
            var b_acc: VF = @splat(0.0);
            inline for (0..9) |i| {
                const sy_i = std.math.clamp(@as(i32, @intCast(y)) + @as(i32, @intCast(i)) - 4, 0, h - 1);
                const src_row = @as(usize, @intCast(sy_i)) * ctx.stride + @as(usize, @intCast(x));
                var r_v: VF = undefined;
                var g_v: VF = undefined;
                var b_v: VF = undefined;
                inline for (0..LANES) |l| {
                    const v = src[src_row + l];
                    r_v[l] = v.x;
                    g_v[l] = v.y;
                    b_v[l] = v.z;
                }
                const wt: VF = @splat(gauss_weights[i]);
                r_acc += r_v * wt;
                g_acc += g_v * wt;
                b_acc += b_v * wt;
            }
            inline for (0..LANES) |l| {
                dst[y * ctx.stride + @as(usize, @intCast(x + @as(i32, @intCast(l))))] = math.Vec4.new(r_acc[l], g_acc[l], b_acc[l], 1.0);
            }
        }
        while (x < w) : (x += 1) {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            inline for (0..9) |i| {
                const sy_i = std.math.clamp(@as(i32, @intCast(y)) + @as(i32, @intCast(i)) - 4, 0, h - 1);
                const v = src[@as(usize, @intCast(sy_i)) * ctx.stride + @as(usize, @intCast(x))];
                const wt = gauss_weights[i];
                r += v.x * wt;
                g += v.y * wt;
                b += v.z * wt;
            }
            dst[y * ctx.stride + @as(usize, @intCast(x))] = math.Vec4.new(r, g, b, 1.0);
        }
    }
    return 0;
}

// === Pass 4: upsample + add ===
// Bilinear lookup from 1/4-res scratch back into full-res scene_hdr.
const UpsampleCtx = struct {
    dst: []math.Vec4,
    src: []const math.Vec4,
    dst_w: usize,
    src_w_i: i32,
    src_h_i: i32,
    src_stride: usize,
    inv_ds: f32,
    intensity: f32,
};

fn upsampleAddRows(start: usize, end: usize, raw: *anyopaque) usize {
    // SIMD across LANES output X columns. Bilinear samples gathered
    // per-lane (1 indirect read × 4 corners), then weighted-blend in
    // vector ops. Masked write keeps unlit (w==0) pixels intact.
    const ctx: *UpsampleCtx = @ptrCast(@alignCast(raw));
    const LANES: usize = cpu_features.SIMD_F32_LANES;
    const VF = @Vector(LANES, f32);
    const VI = @Vector(LANES, i32);
    const zero_vf: VF = @splat(0.0);
    const one_vf: VF = @splat(1.0);
    const intensity_v: VF = @splat(ctx.intensity);
    const inv_ds_v: VF = @splat(ctx.inv_ds);
    const x_max: VI = @splat(ctx.src_w_i - 1);
    const zero_vi: VI = @splat(0);
    var y = start;
    while (y < end) : (y += 1) {
        const yf: f32 = @as(f32, @floatFromInt(y)) * ctx.inv_ds;
        const y0_i: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(yf))), 0, ctx.src_h_i - 1);
        const y1_i: i32 = std.math.clamp(y0_i + 1, 0, ctx.src_h_i - 1);
        const ty_s: f32 = yf - @as(f32, @floatFromInt(y0_i));
        const ty_v: VF = @splat(ty_s);
        const one_minus_ty: VF = one_vf - ty_v;
        const y0: usize = @intCast(y0_i);
        const y1: usize = @intCast(y1_i);
        const dst_row = y * ctx.dst_w;
        var x: usize = 0;
        while (x + LANES <= ctx.dst_w) : (x += LANES) {
            // Lane x indices
            var lane_x: VF = undefined;
            inline for (0..LANES) |l| {
                lane_x[l] = @as(f32, @floatFromInt(x + l));
            }
            const xf_v = lane_x * inv_ds_v;
            // floor → x0
            var x0_v: VI = undefined;
            inline for (0..LANES) |l| {
                x0_v[l] = @as(i32, @intFromFloat(@floor(xf_v[l])));
            }
            const x0_clamped = @max(zero_vi, @min(x_max, x0_v));
            const x1_clamped = @max(zero_vi, @min(x_max, x0_clamped + @as(VI, @splat(1))));
            var x0_f: VF = undefined;
            inline for (0..LANES) |l| {
                x0_f[l] = @floatFromInt(x0_v[l]);
            }
            const tx_v = xf_v - x0_f;
            const one_minus_tx = one_vf - tx_v;
            // Gather the 4 corners per lane.
            var s00r: VF = undefined;
            var s00g: VF = undefined;
            var s00b: VF = undefined;
            var s10r: VF = undefined;
            var s10g: VF = undefined;
            var s10b: VF = undefined;
            var s01r: VF = undefined;
            var s01g: VF = undefined;
            var s01b: VF = undefined;
            var s11r: VF = undefined;
            var s11g: VF = undefined;
            var s11b: VF = undefined;
            var vw_v: VF = undefined;
            var vr_v: VF = undefined;
            var vg_v: VF = undefined;
            var vb_v: VF = undefined;
            inline for (0..LANES) |l| {
                const x0u: usize = @intCast(x0_clamped[l]);
                const x1u: usize = @intCast(x1_clamped[l]);
                const s00 = ctx.src[y0 * ctx.src_stride + x0u];
                const s10 = ctx.src[y0 * ctx.src_stride + x1u];
                const s01 = ctx.src[y1 * ctx.src_stride + x0u];
                const s11 = ctx.src[y1 * ctx.src_stride + x1u];
                s00r[l] = s00.x;
                s00g[l] = s00.y;
                s00b[l] = s00.z;
                s10r[l] = s10.x;
                s10g[l] = s10.y;
                s10b[l] = s10.z;
                s01r[l] = s01.x;
                s01g[l] = s01.y;
                s01b[l] = s01.z;
                s11r[l] = s11.x;
                s11g[l] = s11.y;
                s11b[l] = s11.z;
                const v = ctx.dst[dst_row + x + l];
                vw_v[l] = v.w;
                vr_v[l] = v.x;
                vg_v[l] = v.y;
                vb_v[l] = v.z;
            }
            // Bilinear blend
            const r_top = s00r * one_minus_tx + s10r * tx_v;
            const r_bot = s01r * one_minus_tx + s11r * tx_v;
            const r_v = r_top * one_minus_ty + r_bot * ty_v;
            const g_top = s00g * one_minus_tx + s10g * tx_v;
            const g_bot = s01g * one_minus_tx + s11g * tx_v;
            const g_v = g_top * one_minus_ty + g_bot * ty_v;
            const b_top = s00b * one_minus_tx + s10b * tx_v;
            const b_bot = s01b * one_minus_tx + s11b * tx_v;
            const b_v = b_top * one_minus_ty + b_bot * ty_v;
            const lit_mask = vw_v != zero_vf;
            const out_r = vr_v + r_v * intensity_v;
            const out_g = vg_v + g_v * intensity_v;
            const out_b = vb_v + b_v * intensity_v;
            inline for (0..LANES) |l| {
                if (lit_mask[l]) {
                    ctx.dst[dst_row + x + l] = math.Vec4.new(out_r[l], out_g[l], out_b[l], vw_v[l]);
                }
            }
        }
        // Scalar tail
        while (x < ctx.dst_w) : (x += 1) {
            const v = ctx.dst[dst_row + x];
            if (v.w == 0.0) continue;
            const xf: f32 = @as(f32, @floatFromInt(x)) * ctx.inv_ds;
            const x0_i: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(xf))), 0, ctx.src_w_i - 1);
            const x1_i: i32 = std.math.clamp(x0_i + 1, 0, ctx.src_w_i - 1);
            const tx: f32 = xf - @as(f32, @floatFromInt(x0_i));
            const x0u: usize = @intCast(x0_i);
            const x1u: usize = @intCast(x1_i);
            const s00 = ctx.src[y0 * ctx.src_stride + x0u];
            const s10 = ctx.src[y0 * ctx.src_stride + x1u];
            const s01 = ctx.src[y1 * ctx.src_stride + x0u];
            const s11 = ctx.src[y1 * ctx.src_stride + x1u];
            const r = lerp(lerp(s00.x, s10.x, tx), lerp(s01.x, s11.x, tx), ty_s);
            const g = lerp(lerp(s00.y, s10.y, tx), lerp(s01.y, s11.y, tx), ty_s);
            const b = lerp(lerp(s00.z, s10.z, tx), lerp(s01.z, s11.z, tx), ty_s);
            ctx.dst[dst_row + x] = math.Vec4.new(
                v.x + r * ctx.intensity,
                v.y + g * ctx.intensity,
                v.z + b * ctx.intensity,
                v.w,
            );
        }
    }
    return 0;
}

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
