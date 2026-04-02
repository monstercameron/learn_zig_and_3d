//! Applies camera/object motion blur by reprojecting and accumulating along motion direction.
//! Uses depth/camera history signals to stabilize sampling and reduce obvious ghosting.
//! Executed as striped row jobs so sample-heavy blur remains parallel on CPU.


const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const pass_dispatch = @import("../pipeline/pass_dispatch.zig");

const near_clip: f32 = 0.01;
const near_epsilon: f32 = 1e-4;

fn validSceneCameraSample(camera_pos: math.Vec3) bool {
    return std.math.isFinite(camera_pos.x) and
        std.math.isFinite(camera_pos.y) and
        std.math.isFinite(camera_pos.z) and
        camera_pos.z > near_clip;
}

fn cameraToWorldPosition(
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    camera_pos: math.Vec3,
) math.Vec3 {
    return math.Vec3.add(
        camera_position,
        math.Vec3.add(
            math.Vec3.add(
                math.Vec3.scale(basis_right, camera_pos.x),
                math.Vec3.scale(basis_up, camera_pos.y),
            ),
            math.Vec3.scale(basis_forward, camera_pos.z),
        ),
    );
}

/// projectCameraPositionFloat projects coordinates for Motion Blur Pass calculations.
fn projectCameraPositionFloat(position: math.Vec3, projection: anytype) math.Vec2 {
    const clamped_z = if (position.z < projection.near_plane + near_epsilon)
        projection.near_plane + near_epsilon
    else
        position.z;
    const inv_z = 1.0 / clamped_z;
    const ndc_x = position.x * inv_z * projection.x_scale;
    const ndc_y = position.y * inv_z * projection.y_scale;
    return .{
        .x = ndc_x * projection.center_x + projection.center_x + projection.jitter_x,
        .y = -ndc_y * projection.center_y + projection.center_y + projection.jitter_y,
    };
}

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    src_pixels: []const u32,
    dst_pixels: []u32,
    scene_camera: []const math.Vec3,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    current_view: anytype,
    previous_view: anytype,
) void {
    const samples = config.POST_MOTION_BLUR_SAMPLES;
    const intensity = config.POST_MOTION_BLUR_INTENSITY;
    const inv_samples_plus_one = 1.0 / (@as(f32, @floatFromInt(samples)) + 1.0);

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const current_pixel = src_pixels[idx];
            dst_pixels[idx] = current_pixel;

            const current_camera = scene_camera[idx];
            if (!validSceneCameraSample(current_camera)) continue;

            const world_pos = cameraToWorldPosition(
                current_view.camera_position,
                current_view.basis_right,
                current_view.basis_up,
                current_view.basis_forward,
                current_camera,
            );

            const previous_relative = math.Vec3.sub(world_pos, previous_view.camera_position);
            const previous_camera = math.Vec3.new(
                math.Vec3.dot(previous_relative, previous_view.basis_right),
                math.Vec3.dot(previous_relative, previous_view.basis_up),
                math.Vec3.dot(previous_relative, previous_view.basis_forward),
            );
            if (previous_camera.z <= previous_view.projection.near_plane + near_epsilon) continue;

            const previous_screen_raw = projectCameraPositionFloat(previous_camera, previous_view.projection);
            const vec_x = previous_screen_raw.x - @as(f32, @floatFromInt(x));
            const vec_y = previous_screen_raw.y - @as(f32, @floatFromInt(y));

            const vel_mag_sq = vec_x * vec_x + vec_y * vec_y;
            if (vel_mag_sq < 0.25) continue;

            const current_r = @as(f32, @floatFromInt((current_pixel >> 16) & 0xFF));
            const current_g = @as(f32, @floatFromInt((current_pixel >> 8) & 0xFF));
            const current_b = @as(f32, @floatFromInt(current_pixel & 0xFF));
            var r_sum: f32 = current_r;
            var g_sum: f32 = current_g;
            var b_sum: f32 = current_b;

            var s: i32 = 1;
            var t = inv_samples_plus_one;
            while (s <= samples) : (s += 1) {
                const p_x = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x)) + vec_x * t * intensity));
                const p_y = @as(i32, @intFromFloat(@as(f32, @floatFromInt(y)) + vec_y * t * intensity));

                if (p_x >= 0 and p_x < @as(i32, @intCast(width)) and p_y >= 0 and p_y < @as(i32, @intCast(height))) {
                    const s_idx = @as(usize, @intCast(p_y)) * width + @as(usize, @intCast(p_x));
                    const sample_px = src_pixels[s_idx];
                    r_sum += @as(f32, @floatFromInt((sample_px >> 16) & 0xFF));
                    g_sum += @as(f32, @floatFromInt((sample_px >> 8) & 0xFF));
                    b_sum += @as(f32, @floatFromInt(sample_px & 0xFF));
                } else {
                    r_sum += current_r;
                    g_sum += current_g;
                    b_sum += current_b;
                }
                t += inv_samples_plus_one;
            }

            const final_r = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(r_sum * inv_samples_plus_one))))));
            const final_g = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(g_sum * inv_samples_plus_one))))));
            const final_b = @as(u32, @intCast(@max(0, @min(255, @as(i32, @intFromFloat(b_sum * inv_samples_plus_one))))));

            dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
        }
    }
}

/// runPipeline executes the full Motion Blur Pass pipeline for the current frame.
pub fn runPipeline(self: anytype, current_view: anytype, height: usize, width: usize, comptime noop_job_fn: fn (*anyopaque) void) void {
    if (height == 0) return;
    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.moblur_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.moblur_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        runRows(self.bitmap.pixels, self.moblur_scratch_pixels, self.scene_camera, 0, height, width, height, current_view, self.taa_previous_view);
        return;
    }

    const JobType = @TypeOf(self.color_grade_jobs[0]);
    var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
    var stripe_index: usize = 0;
    while (stripe_index < stripe_count) : (stripe_index += 1) {
        const start_row = stripe_index * rows_per_job;
        if (start_row >= height) break;
        const end_row = @min(height, start_row + rows_per_job);

        self.moblur_job_contexts[stripe_index] = .{
            .renderer = self,
            .current_view = current_view,
            .previous_view = self.taa_previous_view,
            .start_row = start_row,
            .end_row = end_row,
            .width = width,
            .height = height,
        };
        if (stripe_index == 0) continue;

        self.color_grade_jobs[stripe_index] = JobType.init(
            CtxType.run,
            @ptrCast(&self.moblur_job_contexts[stripe_index]),
            &parent_job,
        );
        if (!self.job_system.?.submitJobWithClass(&self.color_grade_jobs[stripe_index], .normal)) {
            CtxType.run(@ptrCast(&self.moblur_job_contexts[stripe_index]));
        }
    }
    CtxType.run(@ptrCast(&self.moblur_job_contexts[0]));
    parent_job.complete();
    self.job_system.?.waitFor(&parent_job);
}
