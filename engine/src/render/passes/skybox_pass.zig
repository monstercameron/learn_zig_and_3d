//! Renders sky/background contribution for visible pixels.
//! Projects view directions into sky texture/HDRI space and writes sky color.
//! Executed in row stripes so sky fill remains bandwidth-friendly on CPU.


const math = @import("../../core/math.zig");
const skybox_kernel = @import("../kernels/skybox_kernel.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

/// Builds the typed job-context wrapper used by this pass/kernel dispatch.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub fn JobContext(comptime RendererType: type, comptime ProjectionType: type, comptime HdriMapType: type) type {
    return struct {
        renderer: *RendererType,
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        projection: ProjectionType,
        hdri_map: *const HdriMapType,
        start_row: usize,
        end_row: usize,
    };
}

/// Runs job wrapper.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runJobWrapper(comptime CtxType: type) fn (*anyopaque) void {
    return struct {
        fn call(ctx_ptr: *anyopaque) void {
            const ctx: *CtxType = @ptrCast(@alignCast(ctx_ptr));
            const width: usize = @intCast(ctx.renderer.bitmap.width);
            runRows(
                ctx.renderer.bitmap.pixels,
                ctx.renderer.scene_depth,
                width,
                ctx.start_row,
                ctx.end_row,
                ctx.right,
                ctx.up,
                ctx.forward,
                ctx.projection,
                ctx.hdri_map,
            );
        }
    }.call;
}

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    pixels: []u32,
    scene_depth: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    projection: anytype,
    hdri_map: anytype,
) void {
    skybox_kernel.applyRows(
        pixels,
        scene_depth,
        width,
        start_row,
        end_row,
        right,
        up,
        forward,
        projection,
        hdri_map,
    );
}

/// runPipeline executes the full Skybox Pass pipeline for the current frame.
pub fn runPipeline(
    self: anytype,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    projection: anytype,
    hdri_map: anytype,
    height: usize,
    comptime noop_job_fn: fn (*anyopaque) void,
    comptime run_job_wrapper_fn: fn (*anyopaque) void,
) void {
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.skybox_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const JobType = @TypeOf(self.color_grade_jobs[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        self.skybox_job_contexts[0] = .{
            .renderer = self,
            .right = right,
            .up = up,
            .forward = forward,
            .projection = projection,
            .hdri_map = hdri_map,
            .start_row = 0,
            .end_row = height,
        };
        run_job_wrapper_fn(@ptrCast(&self.skybox_job_contexts[0]));
        return;
    }

    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.skybox_job_contexts[stripe_index] = .{
            .renderer = self,
            .right = right,
            .up = up,
            .forward = forward,
            .projection = projection,
            .hdri_map = hdri_map,
            .start_row = start_row,
            .end_row = end_row,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            run_job_wrapper_fn,
            @ptrCast(&self.skybox_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            run_job_wrapper_fn(@ptrCast(&self.skybox_job_contexts[stripe_index]));
        }
    }

    run_job_wrapper_fn(@ptrCast(&self.skybox_job_contexts[0]));
    parent_job.complete();
    parent_job.wait();
}
