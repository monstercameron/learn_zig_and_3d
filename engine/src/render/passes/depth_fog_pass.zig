//! Applies depth-based fog attenuation to scene color.
//! Converts depth into fog factor, then blends toward configured fog color/intensity.
//! Processes rows in stripes so fog stays parallel and cache-local on CPU.


const depth_fog_kernel = @import("../kernels/depth_fog_kernel.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    pixels: []u32,
    depth_buffer: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    fog: anytype,
) void {
    depth_fog_kernel.applyDepthFogRows(pixels, depth_buffer, width, start_row, end_row, fog);
}

/// runPipeline executes the full Depth Fog Pass pipeline for the current frame.
pub fn runPipeline(self: anytype, width: usize, height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {
    if (height == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.fog_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.fog_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runRows(self.bitmap.pixels, self.scene_depth, width, 0, height, self.depth_fog_config);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.fog_job_contexts[stripe_index] = .{
            .pixels = self.bitmap.pixels,
            .depth = self.scene_depth,
            .width = width,
            .start_row = start_row,
            .end_row = end_row,
            .config = self.depth_fog_config,
        };

        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.fog_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.fog_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.fog_job_contexts[0]));
    parent_job.complete();
    self.job_system.?.waitFor(&parent_job);
}
