const vignette_kernel = @import("../kernels/vignette_kernel.zig");
const film_grain_kernel = @import("../kernels/film_grain_kernel.zig");
const pass_dispatch = @import("../pass_dispatch.zig");

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
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const v = vignette_kernel.vignetteFactor(x, y, width, height, vig_str);
            const p1 = vignette_kernel.applyToPixel(pixels[idx], v);
            const g = film_grain_kernel.grainFactor(x, y, seed, grain_str);
            pixels[idx] = film_grain_kernel.applyToPixel(p1, g);
        }
    }
}

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
