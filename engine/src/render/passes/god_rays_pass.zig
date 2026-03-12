//! Computes light shafts by sampling/accumulating along projected light directions.
//! Builds a softened scattering contribution and blends it onto scene color.
//! Runs per-row dispatch to keep work balanced across worker threads.


const god_rays_kernel = @import("../kernels/god_rays_kernel.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    src_pixels: []const u32,
    dst_pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    light_screen_pos_x: f32,
    light_screen_pos_y: f32,
    samples: i32,
    decay: f32,
    density: f32,
    weight: f32,
    exposure: f32,
) void {
    god_rays_kernel.applyRows(
        src_pixels,
        dst_pixels,
        start_row,
        end_row,
        width,
        height,
        light_screen_pos_x,
        light_screen_pos_y,
        samples,
        decay,
        density,
        weight,
        exposure,
    );
}

/// runPipeline executes the full God Rays Pass pipeline for the current frame.
pub fn runPipeline(
    self: anytype,
    width: usize,
    height: usize,
    light_screen_pos_x: f32,
    light_screen_pos_y: f32,
    samples: i32,
    decay: f32,
    density: f32,
    weight: f32,
    exposure: f32,
    comptime noop_job_fn: fn (*anyopaque) void,
) void {
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.god_rays_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.god_rays_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runRows(
            self.bitmap.pixels,
            self.god_rays_scratch_pixels,
            0,
            height,
            width,
            height,
            light_screen_pos_x,
            light_screen_pos_y,
            samples,
            decay,
            density,
            weight,
            exposure,
        );
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.god_rays_job_contexts[stripe_index] = .{
            .renderer = self,
            .start_row = start_row,
            .end_row = end_row,
            .width = width,
            .height = height,
            .light_screen_pos = .{ .x = light_screen_pos_x, .y = light_screen_pos_y },
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.god_rays_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.god_rays_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.god_rays_job_contexts[0]));
    parent_job.complete();
    self.job_system.?.waitFor(&parent_job);
}
