const pass_dispatch = @import("../pipeline/pass_dispatch.zig");
const std = @import("std");
const math = @import("../../core/math.zig");
const taa_helpers = @import("taa_helpers.zig");

pub fn bootstrapHistory(
    pixels: []const u32,
    scene_depth: []const f32,
    scene_surface: anytype,
    scene_normal: anytype,
    history_pixels: []u32,
    history_depth: []f32,
    history_surface_tags: []u64,
    history_normals: []u32,
    comptime surface_tag_fn: fn (@TypeOf(scene_surface[0])) u64,
    comptime pack_normal_fn: fn (@TypeOf(scene_normal[0])) u32,
) void {
    @memcpy(history_pixels, pixels);
    @memcpy(history_depth, scene_depth);
    for (0..pixels.len) |idx| {
        history_surface_tags[idx] = surface_tag_fn(scene_surface[idx]);
        history_normals[idx] = pack_normal_fn(scene_normal[idx]);
    }
}

pub fn runPipeline(
    self: anytype,
    mesh: anytype,
    current_view: anytype,
    width: usize,
    height: usize,
    comptime noop_job_fn: fn (*anyopaque) void,
    comptime surface_tag_fn: anytype,
    comptime pack_normal_fn: anytype,
) void {
    if (!self.taa_scratch.valid) {
        bootstrapHistory(
            self.bitmap.pixels,
            self.scene_depth,
            self.scene_surface,
            self.scene_normal,
            self.taa_scratch.history_pixels,
            self.taa_scratch.history_depth,
            self.taa_scratch.history_surface_tags,
            self.taa_scratch.history_normals,
            surface_tag_fn,
            pack_normal_fn,
        );
        self.taa_previous_view = current_view;
        self.taa_scratch.valid = true;
        self.captureTemporalMeshState(mesh);
        return;
    }

    const min_rows_per_parallel_job: usize = 16;
    const max_stripes = self.taa_job_contexts.len;
    const stripe_count = @max(@as(usize, 1), @min(max_stripes, (height + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job));
    const rows_per_job = pass_dispatch.computeRowsPerStripe(stripe_count, height);
    const CtxType = @TypeOf(self.taa_job_contexts[0]);

    if (stripe_count <= 1 or self.job_system == null) {
        self.applyTemporalAARows(mesh, current_view, self.taa_previous_view, 0, height, width, height);
    } else {
        const JobType = @TypeOf(self.color_grade_jobs[0]);
        var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= height) break;
            const end_row = @min(height, start_row + rows_per_job);

            self.taa_job_contexts[stripe_index] = .{
                .renderer = self,
                .mesh = mesh,
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
                @ptrCast(&self.taa_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                CtxType.run(@ptrCast(&self.taa_job_contexts[stripe_index]));
            }
        }

        CtxType.run(@ptrCast(&self.taa_job_contexts[0]));
        parent_job.complete();
        parent_job.wait();
    }

    finalizeHistory(
        self.bitmap.pixels,
        self.taa_scratch.resolve_pixels,
        self.scene_depth,
        self.scene_surface,
        self.scene_normal,
        self.taa_scratch.history_pixels,
        self.taa_scratch.history_depth,
        self.taa_scratch.history_surface_tags,
        self.taa_scratch.history_normals,
        surface_tag_fn,
        pack_normal_fn,
    );
    self.taa_previous_view = current_view;
    self.taa_scratch.valid = true;
    self.captureTemporalMeshState(mesh);
}

pub fn finalizeHistory(
    pixels: []u32,
    resolve_pixels: []const u32,
    scene_depth: []const f32,
    scene_surface: anytype,
    scene_normal: anytype,
    history_pixels: []u32,
    history_depth: []f32,
    history_surface_tags: []u64,
    history_normals: []u32,
    comptime surface_tag_fn: fn (@TypeOf(scene_surface[0])) u64,
    comptime pack_normal_fn: fn (@TypeOf(scene_normal[0])) u32,
) void {
    @memcpy(pixels, resolve_pixels);
    @memcpy(history_pixels, pixels);
    @memcpy(history_depth, scene_depth);
    for (0..pixels.len) |idx| {
        history_surface_tags[idx] = surface_tag_fn(scene_surface[idx]);
        history_normals[idx] = pack_normal_fn(scene_normal[idx]);
    }
}

pub fn runRows(
    self: anytype,
    mesh: anytype,
    current_view: anytype,
    previous_view: anytype,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    comptime try_meshlet_batch_fn: anytype,
    comptime valid_scene_camera_fn: anytype,
    comptime camera_to_world_fn: anytype,
    comptime project_camera_fn: anytype,
    comptime near_epsilon: f32,
) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            if (try_meshlet_batch_fn(self, mesh, current_view, previous_view, row_start, x, y, width, height)) {
                x += 7;
                continue;
            }

            const idx = row_start + x;
            const current_pixel = self.bitmap.pixels[idx];
            self.taa_scratch.resolve_pixels[idx] = current_pixel;

            const current_camera = self.scene_camera[idx];
            if (!valid_scene_camera_fn(current_camera)) continue;

            const current_surface = self.scene_surface[idx];
            var reprojection: ?struct { screen: math.Vec2, depth: f32, used_surface_path: bool } = null;

            if (current_surface.isValid() and self.taa_previous_mesh_valid and current_surface.triangle_id < mesh.triangles.len and self.taa_previous_mesh_triangle_count == mesh.triangles.len) {
                const tri = mesh.triangles[current_surface.triangle_id];
                if (tri.v0 < self.taa_previous_mesh_vertex_count and tri.v1 < self.taa_previous_mesh_vertex_count and tri.v2 < self.taa_previous_mesh_vertex_count) {
                    const bary = current_surface.barycentrics();
                    const prev_v0 = self.taa_previous_mesh_vertices[tri.v0];
                    const prev_v1 = self.taa_previous_mesh_vertices[tri.v1];
                    const prev_v2 = self.taa_previous_mesh_vertices[tri.v2];
                    const previous_world = math.Vec3.new(
                        prev_v0.x * bary.x + prev_v1.x * bary.y + prev_v2.x * bary.z,
                        prev_v0.y * bary.x + prev_v1.y * bary.y + prev_v2.y * bary.z,
                        prev_v0.z * bary.x + prev_v1.z * bary.y + prev_v2.z * bary.z,
                    );
                    const previous_relative = math.Vec3.sub(previous_world, previous_view.camera_position);
                    const previous_camera = math.Vec3.new(
                        math.Vec3.dot(previous_relative, previous_view.basis_right),
                        math.Vec3.dot(previous_relative, previous_view.basis_up),
                        math.Vec3.dot(previous_relative, previous_view.basis_forward),
                    );
                    if (previous_camera.z > previous_view.projection.near_plane + near_epsilon) {
                        reprojection = .{
                            .screen = project_camera_fn(previous_camera, previous_view.projection),
                            .depth = previous_camera.z,
                            .used_surface_path = true,
                        };
                    }
                }
            }

            if (reprojection == null) {
                const world_pos = camera_to_world_fn(
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
                reprojection = .{
                    .screen = project_camera_fn(previous_camera, previous_view.projection),
                    .depth = previous_camera.z,
                    .used_surface_path = false,
                };
            }

            const previous_sample = reprojection orelse continue;
            const history_sample = taa_helpers.sampleHistoryNearest(
                self.taa_scratch.history_pixels,
                self.taa_scratch.history_depth,
                self.taa_scratch.history_surface_tags,
                width,
                height,
                previous_sample.screen,
            ) orelse continue;

            const depth_delta = @abs(history_sample.depth - previous_sample.depth);
            const depth_factor = 1.0 - std.math.clamp(depth_delta / @max(1e-4, self.temporal_aa_config.depth_threshold), 0.0, 1.0);
            if (depth_factor <= 0.0) continue;

            const previous_tag = history_sample.tag;
            const current_tag = taa_helpers.surfaceTagForHandle(current_surface);
            if (current_tag != taa_helpers.invalid_surface_tag and previous_tag != taa_helpers.invalid_surface_tag and previous_tag == current_tag) {
                const history_weight = std.math.clamp(self.temporal_aa_config.history_weight * (0.6 + 0.15 * depth_factor), 0.0, self.temporal_aa_config.history_weight);
                self.taa_scratch.resolve_pixels[idx] = taa_helpers.blendTemporalColor(current_pixel, history_sample.color, history_weight);
                continue;
            }

            const history_color = if (previous_sample.used_surface_path)
                taa_helpers.sampleHistoryColorNearest(self.taa_scratch.history_pixels, width, height, previous_sample.screen)
            else
                taa_helpers.sampleHistoryColor(self.taa_scratch.history_pixels, width, height, previous_sample.screen);
            const color_sample = history_color orelse continue;

            const current_normal = self.scene_normal[idx];
            const previous_normal = taa_helpers.sampleHistoryNormalNearest(self.taa_scratch.history_normals, width, height, previous_sample.screen) orelse math.Vec3.new(0.0, 0.0, 0.0);

            var identity_factor: f32 = if (previous_sample.used_surface_path) 0.35 else 0.2;
            const same_meshlet_history = current_tag != taa_helpers.invalid_surface_tag and previous_tag != taa_helpers.invalid_surface_tag and taa_helpers.surfaceTagMeshletId(previous_tag) == current_surface.meshlet_id;
            if (same_meshlet_history) identity_factor = 0.6;
            const normal_alignment = math.Vec3.dot(current_normal, previous_normal);
            const normal_factor = if (!previous_sample.used_surface_path and previous_tag == taa_helpers.invalid_surface_tag) 0.5 else if (normal_alignment <= 0.5) 0.0 else std.math.clamp((normal_alignment - 0.5) * 2.0, 0.0, 1.0);
            const edge_factor = taa_helpers.surfaceHistoryEdgeFactor(self.scene_surface, width, height, x, y);
            const confidence = identity_factor * depth_factor * normal_factor * edge_factor;
            const fallback_history_weight = if (previous_sample.used_surface_path)
                self.temporal_aa_config.history_weight * 0.04 * depth_factor * edge_factor
            else if (previous_tag != taa_helpers.invalid_surface_tag or same_meshlet_history)
                self.temporal_aa_config.history_weight * 0.025 * depth_factor * edge_factor
            else
                self.temporal_aa_config.history_weight * 0.015 * depth_factor * edge_factor;

            const clamped_history = if (current_surface.isValid() or previous_tag != taa_helpers.invalid_surface_tag)
                taa_helpers.clampHistoryToSurfaceNeighborhood(self.bitmap.pixels, self.scene_surface, self.scene_normal, width, height, x, y, color_sample)
            else
                taa_helpers.clampHistoryToNeighborhood(self.bitmap.pixels, width, height, x, y, color_sample);

            const luma_delta = @abs(taa_helpers.colorLuma(clamped_history) - taa_helpers.pixelLuma(current_pixel)) / 255.0;
            const shadow_darkening = std.math.clamp((taa_helpers.colorLuma(clamped_history) - taa_helpers.pixelLuma(current_pixel) - 10.0) / 72.0, 0.0, 1.0);
            const luminance_factor = 1.0 - (std.math.clamp((luma_delta - 0.06) / 0.24, 0.0, 1.0) * 0.85);
            const shadow_factor = 1.0 - (shadow_darkening * 0.9);
            const history_weight = std.math.clamp(@max(self.temporal_aa_config.history_weight * confidence * 0.9, fallback_history_weight), 0.0, self.temporal_aa_config.history_weight) * luminance_factor * shadow_factor;
            if (history_weight <= 0.0) continue;
            self.taa_scratch.resolve_pixels[idx] = taa_helpers.blendTemporalColor(current_pixel, clamped_history, history_weight);
        }
    }
}
