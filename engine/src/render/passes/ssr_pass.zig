const config = @import("../../core/app_config.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");
const ssr_kernel = @import("../kernels/ssr_kernel.zig");

pub fn runRows(
    scene_pixels: []const u32,
    scratch_pixels: []u32,
    scene_camera: anytype,
    scene_depth: []const f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    projection: anytype,
    max_samples: i32,
    step_size: f32,
    max_distance: f32,
    thickness: f32,
    intensity: f32,
) void {
    ssr_kernel.runRows(
        scene_pixels,
        scratch_pixels,
        scene_camera,
        scene_depth,
        width,
        height,
        start_row,
        end_row,
        projection,
        max_samples,
        step_size,
        max_distance,
        thickness,
        intensity,
    );
}

pub fn runPipeline(self: anytype, projection: anytype, scene_height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {
    if (scene_height == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.ssr_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (scene_height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, scene_height);
    const scene_width: usize = @intCast(self.bitmap.width);
    const CtxType = @TypeOf(self.ssr_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        self.ssr_job_contexts[0] = .{
            .renderer = self,
            .scene_pixels = self.bitmap.pixels,
            .scratch_pixels = self.ssr_scratch_pixels,
            .scene_camera = self.scene_camera,
            .scene_normal = self.scene_normal,
            .scene_depth = self.scene_depth,
            .width = scene_width,
            .height = scene_height,
            .start_row = 0,
            .end_row = scene_height,
            .projection = projection,
            .max_samples = config.POST_SSR_MAX_SAMPLES,
            .step_size = config.POST_SSR_STEP,
            .max_distance = config.POST_SSR_MAX_DISTANCE,
            .thickness = config.POST_SSR_THICKNESS,
            .intensity = config.POST_SSR_INTENSITY,
        };
        CtxType.run(&self.ssr_job_contexts[0]);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= scene_height) break;
        const end_row = @min(scene_height, start_row + rows_per_job);

        self.ssr_job_contexts[stripe_index] = .{
            .renderer = self,
            .scene_pixels = self.bitmap.pixels,
            .scratch_pixels = self.ssr_scratch_pixels,
            .scene_camera = self.scene_camera,
            .scene_normal = self.scene_normal,
            .scene_depth = self.scene_depth,
            .width = scene_width,
            .height = scene_height,
            .start_row = start_row,
            .end_row = end_row,
            .projection = projection,
            .max_samples = config.POST_SSR_MAX_SAMPLES,
            .step_size = config.POST_SSR_STEP,
            .max_distance = config.POST_SSR_MAX_DISTANCE,
            .thickness = config.POST_SSR_THICKNESS,
            .intensity = config.POST_SSR_INTENSITY,
        };

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.ssr_job_contexts[stripe_index]),
            &parent_job,
        );

        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.ssr_job_contexts[stripe_index]));
        }
    }

    parent_job.complete();
    parent_job.wait();
}
