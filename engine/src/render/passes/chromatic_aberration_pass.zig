const chromatic_aberration_kernel = @import("../kernels/chromatic_aberration_kernel.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

pub fn runRows(
    src_pixels: []const u32,
    dst_pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    strength: f32,
) void {
    chromatic_aberration_kernel.applyRows(
        src_pixels,
        dst_pixels,
        start_row,
        end_row,
        width,
        height,
        strength,
    );
}

pub fn runPipeline(
    self: anytype,
    width: usize,
    height: usize,
    strength: f32,
    comptime noop_job_fn: fn (*anyopaque) void,
) void {
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.chromatic_aberration_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.chromatic_aberration_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runRows(self.bitmap.pixels, self.moblur_scratch_pixels, 0, height, width, height, strength);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.chromatic_aberration_job_contexts[stripe_index] = .{
            .renderer = self,
            .start_row = start_row,
            .end_row = end_row,
            .width = width,
            .height = height,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.chromatic_aberration_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.chromatic_aberration_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.chromatic_aberration_job_contexts[0]));
    parent_job.complete();
    parent_job.wait();
}
