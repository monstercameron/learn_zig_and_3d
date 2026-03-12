//! Orchestrates bloom as staged post-processing: extract bright regions, blur horizontally/vertically, then composite.
//! Each stage is row-striped across workers so wide screens stay cache-friendly on CPU.
//! The pass writes bloom contribution back into the frame buffer in the final composite stage.


const pass_dispatch = @import("../pipeline/pass_dispatch.zig");
const render_utils = @import("../core/utils.zig");

pub const Stage = enum {
    extract,
    blur_horizontal,
    blur_vertical,
    composite,
};

/// buildThresholdCurve builds data structures used by Bloom Pass.
pub fn buildThresholdCurve(threshold: i32) [256]u8 {
    var lut: [256]u8 = undefined;
    for (0..lut.len) |idx| {
        const luma: i32 = @intCast(idx);
        if (luma <= threshold) {
            lut[idx] = 0;
        } else {
            lut[idx] = render_utils.clampByte(@divTrunc((luma - threshold) * 255, @max(1, 255 - threshold)));
        }
    }
    return lut;
}

/// buildIntensityLut builds data structures used by Bloom Pass.
pub fn buildIntensityLut(intensity_percent: i32) [256]u8 {
    var lut: [256]u8 = undefined;
    for (0..lut.len) |idx| {
        lut[idx] = render_utils.clampByte(@divTrunc(@as(i32, @intCast(idx)) * intensity_percent, 100));
    }
    return lut;
}

/// Builds the typed job-context wrapper used by this pass/kernel dispatch.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub fn JobContext(comptime BloomScratchType: type) type {
    return struct {
        stage: Stage,
        scene_pixels: []u32,
        scene_width: usize,
        scene_height: usize,
        bloom: *BloomScratchType,
        threshold_curve: *const [256]u8,
        intensity_lut: *const [256]u8,
        start_row: usize,
        end_row: usize,

        /// Runs this module step with the currently bound configuration.
        /// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const bloom_rows = @import("bloom_rows.zig");
            switch (ctx.stage) {
                .extract => bloom_rows.extractDownsampleRows(
                    ctx.scene_pixels,
                    ctx.scene_width,
                    ctx.scene_height,
                    ctx.bloom,
                    ctx.threshold_curve,
                    ctx.start_row,
                    ctx.end_row,
                ),
                .blur_horizontal => bloom_rows.blurHorizontalRows(ctx.bloom, ctx.start_row, ctx.end_row),
                .blur_vertical => bloom_rows.blurVerticalRows(ctx.bloom, ctx.start_row, ctx.end_row),
                .composite => bloom_rows.compositeRows(
                    ctx.scene_pixels,
                    ctx.scene_width,
                    ctx.bloom,
                    ctx.intensity_lut,
                    ctx.start_row,
                    ctx.end_row,
                ),
            }
        }
    };
}

/// Runs stage range.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
fn runStageRange(
    self: anytype,
    stage: Stage,
    start_row: usize,
    end_row: usize,
    scene_width: usize,
    scene_height: usize,
    threshold: i32,
    intensity_percent: i32,
    comptime extract_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) void {
    switch (stage) {
        .extract => {
            _ = threshold;
            extract_fn(self.bitmap.pixels, scene_width, scene_height, &self.bloom_scratch, &self.bloom_threshold_curve, start_row, end_row);
        },
        .blur_horizontal => blur_h_fn(&self.bloom_scratch, start_row, end_row),
        .blur_vertical => blur_v_fn(&self.bloom_scratch, start_row, end_row),
        .composite => {
            _ = intensity_percent;
            composite_fn(self.bitmap.pixels, scene_width, &self.bloom_scratch, &self.bloom_intensity_lut, start_row, end_row);
        },
    }
}

/// dispatchStage dispatches Bloom Pass jobs across workers.
fn dispatchStage(
    self: anytype,
    stage: Stage,
    row_count: usize,
    scene_width: usize,
    scene_height: usize,
    threshold: i32,
    intensity_percent: i32,
    comptime noop_job_fn: fn (*anyopaque) void,
    comptime extract_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) void {
    if (row_count == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.bloom_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (row_count + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, row_count);
    const CtxType = @TypeOf(self.bloom_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runStageRange(self, stage, 0, row_count, scene_width, scene_height, threshold, intensity_percent, extract_fn, blur_h_fn, blur_v_fn, composite_fn);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= row_count) break;
        const end_row = @min(row_count, start_row + rows_per_job);

        self.bloom_job_contexts[stripe_index] = .{
            .stage = stage,
            .scene_pixels = self.bitmap.pixels,
            .scene_width = scene_width,
            .scene_height = scene_height,
            .bloom = &self.bloom_scratch,
            .threshold_curve = &self.bloom_threshold_curve,
            .intensity_lut = &self.bloom_intensity_lut,
            .start_row = start_row,
            .end_row = end_row,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.bloom_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            runStageRange(self, stage, start_row, end_row, scene_width, scene_height, threshold, intensity_percent, extract_fn, blur_h_fn, blur_v_fn, composite_fn);
        }
    }

    CtxType.run(@ptrCast(&self.bloom_job_contexts[0]));
    parent_job.complete();
    self.job_system.?.waitFor(&parent_job);
}

/// runPipeline executes the full Bloom Pass pipeline for the current frame.
pub fn runPipeline(
    self: anytype,
    scene_width: usize,
    scene_height: usize,
    threshold: i32,
    intensity_percent: i32,
    comptime noop_job_fn: fn (*anyopaque) void,
    comptime extract_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) void {
    const bloom = &self.bloom_scratch;
    dispatchStage(self, .extract, bloom.height, scene_width, scene_height, threshold, 0, noop_job_fn, extract_fn, blur_h_fn, blur_v_fn, composite_fn);
    dispatchStage(self, .blur_horizontal, bloom.height, scene_width, scene_height, 0, 0, noop_job_fn, extract_fn, blur_h_fn, blur_v_fn, composite_fn);
    dispatchStage(self, .blur_vertical, bloom.height, scene_width, scene_height, 0, 0, noop_job_fn, extract_fn, blur_h_fn, blur_v_fn, composite_fn);
    dispatchStage(self, .composite, scene_height, scene_width, scene_height, 0, intensity_percent, noop_job_fn, extract_fn, blur_h_fn, blur_v_fn, composite_fn);
}
