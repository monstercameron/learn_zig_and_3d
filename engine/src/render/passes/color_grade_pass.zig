//! Applies final color-grade transforms over the frame buffer.
//! Runs profile-driven color adjustments in contiguous ranges for SIMD/vector efficiency.
//! Used late in post-processing so grading sees near-final HDR/LDR color composition.


const color_grade_kernel = @import("../kernels/color_grade_kernel.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

/// Runs range.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRange(
    pixels: []u32,
    start_index: usize,
    end_index: usize,
    grade: anytype,
) void {
    color_grade_kernel.applyRange(pixels, start_index, end_index, grade);
}

/// runPipeline executes the full Color Grade Pass pipeline for the current frame.
pub fn runPipeline(self: anytype, width: usize, height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {
    if (height == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.color_grade_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.color_grade_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runRange(self.bitmap.pixels, 0, self.bitmap.pixels.len, &self.color_grade_profile);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.color_grade_job_contexts[stripe_index] = .{
            .pixels = self.bitmap.pixels,
            .start_index = start_row * width,
            .end_index = end_row * width,
            .profile = &self.color_grade_profile,
        };

        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.color_grade_job_contexts[stripe_index]),
            &parent_job,
        );

        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            runRange(
                self.bitmap.pixels,
                self.color_grade_job_contexts[stripe_index].start_index,
                self.color_grade_job_contexts[stripe_index].end_index,
                &self.color_grade_profile,
            );
        }
    }

    runRange(
        self.bitmap.pixels,
        self.color_grade_job_contexts[0].start_index,
        self.color_grade_job_contexts[0].end_index,
        &self.color_grade_profile,
    );
    parent_job.complete();
    parent_job.wait();
}
