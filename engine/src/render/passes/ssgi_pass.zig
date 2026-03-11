const ssgi_kernel = @import("../kernels/ssgi_kernel.zig");
const pass_dispatch = @import("../pass_dispatch.zig");

pub fn runRows(
    pixels: []const u32,
    out_pixels: []u32,
    camera: anytype,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
) void {
    ssgi_kernel.runRows(pixels, out_pixels, camera, width, height, start_row, end_row);
}

pub fn runPipeline(self: anytype, height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {
    if (height == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.ssgi_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.ssgi_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        var ctx = CtxType{
            .renderer = self,
            .scene_pixels = self.bitmap.pixels,
            .scratch_pixels = self.ssgi_scratch_pixels,
            .scene_camera = self.scene_camera,
            .start_row = 0,
            .end_row = height,
        };
        CtxType.run(@ptrCast(&ctx));
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.ssgi_job_contexts[stripe_index] = .{
            .renderer = self,
            .scene_pixels = self.bitmap.pixels,
            .scratch_pixels = self.ssgi_scratch_pixels,
            .scene_camera = self.scene_camera,
            .start_row = start_row,
            .end_row = end_row,
        };

        if (stripe_index == 0) continue;
        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.ssgi_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.ssgi_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.ssgi_job_contexts[0]));
    parent_job.complete();
    parent_job.wait();
}
