//! Orchestrates SSAO as a multi-stage pass: generate, blur horizontal, blur vertical, composite.
//! Generation estimates local occlusion from depth/normal neighborhood sampling.
//! Blur/composite stages denoise and apply AO to scene color using parallel row dispatch.

const pass_dispatch = @import("../pipeline/pass_dispatch.zig");
const ssao_sample_kernel = @import("../kernels/ssao_sample_kernel.zig");
const ssao_blur_kernel = @import("../kernels/ssao_blur_kernel.zig");

pub const Stage = enum {
    generate,
    blur_horizontal,
    blur_vertical,
    composite,
};

/// Builds the typed job-context wrapper used by this pass/kernel dispatch.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn JobContext(
    comptime RendererType: type,
    comptime generate_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) type {
    return struct {
        renderer: *RendererType,
        stage: Stage,
        scene_width: usize,
        scene_height: usize,
        start_row: usize,
        end_row: usize,

        /// Runs this module step with the currently bound configuration.
        /// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
            switch (ctx.stage) {
                .generate => ssao_sample_kernel.runRows(
                    ctx.renderer.scene_camera,
                    ctx.scene_width,
                    ctx.scene_height,
                    &ctx.renderer.ao_scratch,
                    ctx.renderer.ambient_occlusion_config,
                    ctx.start_row,
                    ctx.end_row,
                    generate_fn,
                ),
                .blur_horizontal => ssao_blur_kernel.runHorizontalRows(
                    &ctx.renderer.ao_scratch,
                    ctx.renderer.ambient_occlusion_config.blur_depth_threshold,
                    ctx.start_row,
                    ctx.end_row,
                    blur_h_fn,
                ),
                .blur_vertical => ssao_blur_kernel.runVerticalRows(
                    &ctx.renderer.ao_scratch,
                    ctx.renderer.ambient_occlusion_config.blur_depth_threshold,
                    ctx.start_row,
                    ctx.end_row,
                    blur_v_fn,
                ),
                .composite => composite_fn(
                    ctx.renderer.bitmap.pixels,
                    ctx.renderer.scene_camera,
                    ctx.scene_width,
                    ctx.scene_height,
                    &ctx.renderer.ao_scratch,
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
    comptime generate_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) void {
    switch (stage) {
        .generate => generate_fn(self.scene_camera, scene_width, scene_height, &self.ao_scratch, self.ambient_occlusion_config, start_row, end_row),
        .blur_horizontal => blur_h_fn(&self.ao_scratch, self.ambient_occlusion_config.blur_depth_threshold, start_row, end_row),
        .blur_vertical => blur_v_fn(&self.ao_scratch, self.ambient_occlusion_config.blur_depth_threshold, start_row, end_row),
        .composite => composite_fn(self.bitmap.pixels, self.scene_camera, scene_width, scene_height, &self.ao_scratch, start_row, end_row),
    }
}

/// dispatchStage dispatches SSAO Pass jobs across workers.
fn dispatchStage(
    self: anytype,
    stage: Stage,
    row_count: usize,
    scene_width: usize,
    scene_height: usize,
    comptime noop_job_fn: fn (*anyopaque) void,
    comptime generate_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) void {
    if (row_count == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.ao_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (row_count + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, row_count);
    const CtxType = @TypeOf(self.ao_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runStageRange(self, stage, 0, row_count, scene_width, scene_height, generate_fn, blur_h_fn, blur_v_fn, composite_fn);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= row_count) break;
        const end_row = @min(row_count, start_row + rows_per_job);

        self.ao_job_contexts[stripe_index] = .{
            .renderer = self,
            .stage = stage,
            .scene_width = scene_width,
            .scene_height = scene_height,
            .start_row = start_row,
            .end_row = end_row,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.ao_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobWithClass(&self.color_grade_jobs[stripe_index], .normal)) {
            runStageRange(self, stage, start_row, end_row, scene_width, scene_height, generate_fn, blur_h_fn, blur_v_fn, composite_fn);
        }
    }

    runStageRange(
        self,
        stage,
        self.ao_job_contexts[0].start_row,
        self.ao_job_contexts[0].end_row,
        scene_width,
        scene_height,
        generate_fn,
        blur_h_fn,
        blur_v_fn,
        composite_fn,
    );
    parent_job.complete();
    self.job_system.?.waitFor(&parent_job);
}

/// runPipeline executes the full SSAO Pass pipeline for the current frame.
pub fn runPipeline(
    self: anytype,
    scene_width: usize,
    scene_height: usize,
    comptime noop_job_fn: fn (*anyopaque) void,
    comptime generate_fn: anytype,
    comptime blur_h_fn: anytype,
    comptime blur_v_fn: anytype,
    comptime composite_fn: anytype,
) void {
    const ao = &self.ao_scratch;
    dispatchStage(self, .generate, ao.height, scene_width, scene_height, noop_job_fn, generate_fn, blur_h_fn, blur_v_fn, composite_fn);
    dispatchStage(self, .blur_horizontal, ao.height, scene_width, scene_height, noop_job_fn, generate_fn, blur_h_fn, blur_v_fn, composite_fn);
    dispatchStage(self, .blur_vertical, ao.height, scene_width, scene_height, noop_job_fn, generate_fn, blur_h_fn, blur_v_fn, composite_fn);
    dispatchStage(self, .composite, scene_height, scene_width, scene_height, noop_job_fn, generate_fn, blur_h_fn, blur_v_fn, composite_fn);
}
