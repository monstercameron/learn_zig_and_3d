const std = @import("std");
const math = @import("../../core/math.zig");

pub fn runBuild(
    self: anytype,
    mesh: anytype,
    light_dir_world: math.Vec3,
    target_shadow_map: anytype,
    post_shadow_enabled: bool,
    post_shadow_depth_bias: f32,
    comptime choose_shadow_basis_fn: anytype,
    comptime compute_stripe_count_fn: anytype,
    comptime noop_job_fn: anytype,
    comptime rasterize_rows_fn: anytype,
) i128 {
    if (!post_shadow_enabled or mesh.meshlets.len == 0) {
        target_shadow_map.*.active = false;
        return 0;
    }

    const pass_start = std.time.nanoTimestamp();
    const basis = choose_shadow_basis_fn(light_dir_world);
    var min_x = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var min_z = std.math.inf(f32);
    var max_z = -std.math.inf(f32);

    for (mesh.vertices) |vertex| {
        const lx = math.Vec3.dot(vertex, basis.right);
        const ly = math.Vec3.dot(vertex, basis.up);
        const lz = math.Vec3.dot(vertex, basis.forward);
        min_x = @min(min_x, lx);
        max_x = @max(max_x, lx);
        min_y = @min(min_y, ly);
        max_y = @max(max_y, ly);
        min_z = @min(min_z, lz);
        max_z = @max(max_z, lz);
    }

    if (!std.math.isFinite(min_x) or !std.math.isFinite(max_x)) {
        target_shadow_map.*.active = false;
        return std.time.nanoTimestamp() - pass_start;
    }

    const range_x = @max(0.001, max_x - min_x);
    const range_y = @max(0.001, max_y - min_y);
    const range_z = @max(0.001, max_z - min_z);
    const margin = @max(0.25, @max(range_x, @max(range_y, range_z)) * 0.08);

    target_shadow_map.*.basis_right = basis.right;
    target_shadow_map.*.basis_up = basis.up;
    target_shadow_map.*.basis_forward = basis.forward;
    target_shadow_map.*.min_x = min_x - margin;
    target_shadow_map.*.max_x = max_x + margin;
    target_shadow_map.*.min_y = min_y - margin;
    target_shadow_map.*.max_y = max_y + margin;
    target_shadow_map.*.min_z = min_z - margin;
    target_shadow_map.*.max_z = max_z + margin;
    target_shadow_map.*.inv_extent_x = 1.0 / @max(0.001, target_shadow_map.*.max_x - target_shadow_map.*.min_x);
    target_shadow_map.*.inv_extent_y = 1.0 / @max(0.001, target_shadow_map.*.max_y - target_shadow_map.*.min_y);
    target_shadow_map.*.depth_bias = post_shadow_depth_bias;
    target_shadow_map.*.texel_bias = @max(
        0.001,
        @max(
            (target_shadow_map.*.max_x - target_shadow_map.*.min_x) / @as(f32, @floatFromInt(target_shadow_map.*.width)),
            (target_shadow_map.*.max_y - target_shadow_map.*.min_y) / @as(f32, @floatFromInt(target_shadow_map.*.height)),
        ) * 0.35,
    );
    target_shadow_map.*.active = true;
    @memset(target_shadow_map.*.depth, std.math.inf(f32));

    const stripe_count = compute_stripe_count_fn(self.shadow_raster_job_contexts.len, target_shadow_map.*.height);
    const rows_per_job = if (stripe_count <= 1) target_shadow_map.*.height else (target_shadow_map.*.height + stripe_count - 1) / stripe_count;

    if (stripe_count <= 1 or self.job_system == null) {
        rasterize_rows_fn(mesh, target_shadow_map, 0, target_shadow_map.*.height, light_dir_world);
        return std.time.nanoTimestamp() - pass_start;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    const CtxType = @TypeOf(self.shadow_raster_job_contexts[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= target_shadow_map.*.height) break;
        const end_row = @min(target_shadow_map.*.height, start_row + rows_per_job);

        self.shadow_raster_job_contexts[stripe_index] = .{
            .mesh = mesh,
            .shadow = target_shadow_map,
            .start_row = start_row,
            .end_row = end_row,
            .light_dir_world = light_dir_world,
        };

        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.shadow_raster_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.shadow_raster_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.shadow_raster_job_contexts[0]));
    parent_job.complete();
    parent_job.wait();

    return std.time.nanoTimestamp() - pass_start;
}

pub fn runPerLight(
    light_count: usize,
    ctx: anytype,
    comptime apply_fn: fn (@TypeOf(ctx), usize) void,
) void {
    for (0..light_count) |pass_index| {
        apply_fn(ctx, pass_index);
    }
}

const pass_dispatch = @import("../pass_dispatch.zig");

pub fn runPipeline(
    self: anytype,
    width: usize,
    height: usize,
    resolve_config: anytype,
    target_shadow_map: anytype,
    pass_index: usize,
    build_elapsed_ns: i128,
    comptime noop_job_fn: fn (*anyopaque) void,
) void {
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.shadow_resolve_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.shadow_resolve_job_contexts[0]);
    const pass_start = std.time.nanoTimestamp();

    if (stripe_count <= 1 or self.job_system == null) {
        CtxType.runRowsDirect(self.bitmap.pixels, self.scene_camera, width, 0, height, resolve_config, target_shadow_map);
        self.recordRenderPassDuration(if (pass_index == 0) "shadow_pass_0" else "shadow_pass_1", build_elapsed_ns + (std.time.nanoTimestamp() - pass_start));
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.shadow_resolve_job_contexts[stripe_index] = .{
            .pixels = self.bitmap.pixels,
            .camera_buffer = self.scene_camera,
            .width = width,
            .start_row = start_row,
            .end_row = end_row,
            .config = resolve_config,
            .shadow = target_shadow_map,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.shadow_resolve_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
            CtxType.run(@ptrCast(&self.shadow_resolve_job_contexts[stripe_index]));
        }
    }

    CtxType.run(@ptrCast(&self.shadow_resolve_job_contexts[0]));
    parent_job.complete();
    parent_job.wait();
    self.recordRenderPassDuration(if (pass_index == 0) "shadow_pass_0" else "shadow_pass_1", build_elapsed_ns + (std.time.nanoTimestamp() - pass_start));
}
