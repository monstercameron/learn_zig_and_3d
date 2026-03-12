//! Applies depth-of-field blur based on focus distance/range and per-pixel scene depth.
//! Pixels farther from focus plane receive larger blur radius up to configured cap.
//! Runs in row stripes and writes into scratch/output buffers used by later post passes.


const depth_of_field_kernel = @import("../kernels/depth_of_field_kernel.zig");
const config = @import("../../core/app_config.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    scene_pixels: []const u32,
    scratch_pixels: []u32,
    scene_depth: []const f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    focal_distance: f32,
    focal_range: f32,
    max_blur_radius: i32,
) void {
    depth_of_field_kernel.applyRows(
        scene_pixels,
        scratch_pixels,
        scene_depth,
        width,
        height,
        start_row,
        end_row,
        focal_distance,
        focal_range,
        max_blur_radius,
    );
}

/// runPipeline executes the full Depth Of Field Pass pipeline for the current frame.
pub fn runPipeline(self: anytype, scene_width: usize, scene_height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {
    const center_x = scene_width / 2;
    const center_y = scene_height / 2;
    var center_depth = self.scene_depth[center_y * scene_width + center_x];
    if (center_depth > 1000.0) center_depth = 1000.0;

    var min_depth: f32 = 1000.0;
    const box_size: i32 = 4;
    var cy: i32 = -box_size;
    while (cy <= box_size) : (cy += 1) {
        var cx: i32 = -box_size;
        while (cx <= box_size) : (cx += 1) {
            const py = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(scene_height)) - 1, @as(i32, @intCast(center_y)) + cy))));
            const px = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(scene_width)) - 1, @as(i32, @intCast(center_x)) + cx))));
            const d = self.scene_depth[py * scene_width + px];
            if (d < min_depth) min_depth = d;
        }
    }
    if (min_depth > 1000.0) min_depth = 1000.0;

    self.dof_target_focal_distance = min_depth;
    self.dof_focal_distance = self.dof_focal_distance + (self.dof_target_focal_distance - self.dof_focal_distance) * 0.1;
    const auto_focal_distance = self.dof_focal_distance;

    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.dof_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (scene_height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, scene_height);
    const CtxType = @TypeOf(self.dof_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        self.dof_job_contexts[0] = .{
            .scene_pixels = self.bitmap.pixels,
            .scratch_pixels = self.dof_scratch.pixels,
            .scene_depth = self.scene_depth,
            .width = scene_width,
            .height = scene_height,
            .start_row = 0,
            .end_row = scene_height,
            .focal_distance = auto_focal_distance,
            .focal_range = config.POST_DOF_FOCAL_RANGE,
            .max_blur_radius = config.POST_DOF_BLUR_RADIUS,
        };
        CtxType.run(&self.dof_job_contexts[0]);
    } else {
        const JobType = @TypeOf(self.color_grade_jobs[0]);
        var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= scene_height) break;
            const end_row = @min(scene_height, start_row + rows_per_job);

            self.dof_job_contexts[stripe_index] = .{
                .scene_pixels = self.bitmap.pixels,
                .scratch_pixels = self.dof_scratch.pixels,
                .scene_depth = self.scene_depth,
                .width = scene_width,
                .height = scene_height,
                .start_row = start_row,
                .end_row = end_row,
                .focal_distance = auto_focal_distance,
                .focal_range = config.POST_DOF_FOCAL_RANGE,
                .max_blur_radius = config.POST_DOF_BLUR_RADIUS,
            };
            self.color_grade_jobs[stripe_index] = JobType.init(
                CtxType.run,
                @ptrCast(&self.dof_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                CtxType.run(@ptrCast(&self.dof_job_contexts[stripe_index]));
            }
        }
        CtxType.run(@ptrCast(&self.dof_job_contexts[0]));
        parent_job.complete();
        self.job_system.?.waitFor(&parent_job);
    }

    @memcpy(self.bitmap.pixels, self.dof_scratch.pixels);
}
