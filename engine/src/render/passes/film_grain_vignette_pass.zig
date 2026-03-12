//! Combines film-grain noise and vignette darkening in one post pass.
//! Uses runtime SIMD lane width to batch pixel operations while preserving deterministic output.
//! Executed near the end of post so it stylizes the fully composed image.


const film_grain_kernel = @import("../kernels/film_grain_kernel.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");
const cpu_features = @import("../../core/cpu_features.zig");

/// Returns the SIMD lane count selected for the current runtime target.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
fn runtimeLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    grain_str: f32,
    vig_str: f32,
    seed: u32,
) void {
    const lanes = runtimeLanes();
    const cx = @as(f32, @floatFromInt(width)) * 0.5;
    const cy = @as(f32, @floatFromInt(height)) * 0.5;
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const dy = (@as(f32, @floatFromInt(y)) - cy) / cy;
        var x: usize = 0;
        while (lanes > 1 and x + lanes <= width) : (x += lanes) {
            switch (lanes) {
                8 => applyBlock(8, pixels, row_start, x, y, grain_str, vig_str, seed, cx, dy),
                16 => applyBlock(16, pixels, row_start, x, y, grain_str, vig_str, seed, cx, dy),
                32 => applyBlock(32, pixels, row_start, x, y, grain_str, vig_str, seed, cx, dy),
                else => break,
            }
        }
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const dx = (@as(f32, @floatFromInt(x)) - cx) / cx;
            const dist = @sqrt(dx * dx + dy * dy);
            const v = 1.0 - @max(0.0, @min(1.0, dist * vig_str));
            const g = film_grain_kernel.grainFactor(x, y, seed, grain_str);
            const factor = v * g;
            const pixel = pixels[idx];
            const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
            const g_ch = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
            const b = @as(f32, @floatFromInt(pixel & 0xFF));
            const rr = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(r * factor))))));
            const gg = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(g_ch * factor))))));
            const bb = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(b * factor))))));
            pixels[idx] = 0xFF000000 | (rr << 16) | (gg << 8) | bb;
        }
    }
}

/// Applies this effect to a single block/tile region.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
fn applyBlock(
    comptime lanes: usize,
    pixels: []u32,
    row_start: usize,
    x_start: usize,
    y: usize,
    grain_str: f32,
    vig_str: f32,
    seed: u32,
    cx: f32,
    dy: f32,
) void {
    var factors: [lanes]f32 = undefined;
    var r_arr: [lanes]f32 = undefined;
    var g_arr: [lanes]f32 = undefined;
    var b_arr: [lanes]f32 = undefined;

    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
        const x = x_start + lane;
        const idx = row_start + x;
        const dx = (@as(f32, @floatFromInt(x)) - cx) / cx;
        const dist = @sqrt(dx * dx + dy * dy);
        const v = 1.0 - @max(0.0, @min(1.0, dist * vig_str));
        const g = film_grain_kernel.grainFactor(x, y, seed, grain_str);
        factors[lane] = v * g;

        const pixel = pixels[idx];
        r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
        g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
        b_arr[lane] = @floatFromInt(pixel & 0xFF);
    }

    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    const minv: FloatVec = @splat(0.0);
    const maxv: FloatVec = @splat(255.0);
    const factor_vec: FloatVec = @as(FloatVec, @bitCast(factors));
    const r_scaled: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(r_arr)) * factor_vec)))));
    const g_scaled: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(g_arr)) * factor_vec)))));
    const b_scaled: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(b_arr)) * factor_vec)))));

    var write_lane: usize = 0;
    while (write_lane < lanes) : (write_lane += 1) {
        const idx = row_start + x_start + write_lane;
        const rr: u32 = @intCast(@max(0, @min(255, r_scaled[write_lane])));
        const gg: u32 = @intCast(@max(0, @min(255, g_scaled[write_lane])));
        const bb: u32 = @intCast(@max(0, @min(255, b_scaled[write_lane])));
        pixels[idx] = 0xFF000000 | (rr << 16) | (gg << 8) | bb;
    }
}

/// runPipeline executes the full Film Grain Vignette Pass pipeline for the current frame.
pub fn runPipeline(
    self: anytype,
    width: usize,
    height: usize,
    grain_str: f32,
    vig_str: f32,
    seed: u32,
    comptime noop_job_fn: fn (*anyopaque) void,
) void {
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.film_grain_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.film_grain_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runRows(self.bitmap.pixels, 0, height, width, height, grain_str, vig_str, seed);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.film_grain_job_contexts[stripe_index] = .{
            .renderer = self,
            .start_row = start_row,
            .end_row = end_row,
            .width = width,
            .height = height,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.film_grain_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.film_grain_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.film_grain_job_contexts[0]));
    parent_job.complete();
    parent_job.wait();
}
