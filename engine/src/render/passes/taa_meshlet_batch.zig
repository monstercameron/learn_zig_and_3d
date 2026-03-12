//! SIMD fast-path helpers for TAA on contiguous pixels sharing meshlet/surface identity.
//! Builds batched history samples and applies vectorized temporal blends when coherence is high.
//! Falls back to scalar TAA path when identity/depth conditions are not met.

const std = @import("std");
const math = @import("../../core/math.zig");
const taa_helpers = @import("taa_helpers.zig");

/// Performs try apply.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn tryApply(
    self: anytype,
    mesh: anytype,
    current_view: anytype,
    previous_view: anytype,
    row_start: usize,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    simd_lanes: usize,
    comptime max_runtime_color_grade_simd_lanes: usize,
    comptime valid_scene_camera_fn: anytype,
    comptime camera_to_world_fn: anytype,
    comptime project_camera_fn: anytype,
    comptime near_epsilon: f32,
) bool {
    if (x + simd_lanes > width) return false;

    var current_pixels: [max_runtime_color_grade_simd_lanes]u32 = undefined;
    var history_colors: [max_runtime_color_grade_simd_lanes][3]f32 = undefined;
    var history_weights: [max_runtime_color_grade_simd_lanes]f32 = undefined;

    for (0..simd_lanes) |lane| {
        const idx = row_start + x + lane;
        const current_pixel = self.bitmap.pixels[idx];
        current_pixels[lane] = current_pixel;

        const current_camera = self.scene_camera[idx];
        if (!valid_scene_camera_fn(current_camera)) return false;

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
            if (previous_camera.z <= previous_view.projection.near_plane + near_epsilon) return false;
            reprojection = .{
                .screen = project_camera_fn(previous_camera, previous_view.projection),
                .depth = previous_camera.z,
                .used_surface_path = false,
            };
        }

        const previous_sample = reprojection orelse return false;
        const history_sample = taa_helpers.sampleHistoryNearest(
            self.taa_scratch.history_pixels,
            self.taa_scratch.history_depth,
            self.taa_scratch.history_surface_tags,
            width,
            height,
            previous_sample.screen,
        ) orelse return false;
        const previous_depth = history_sample.depth;
        const depth_delta = @abs(previous_depth - previous_sample.depth);
        const depth_factor = 1.0 - std.math.clamp(depth_delta / @max(1e-4, self.temporal_aa_config.depth_threshold), 0.0, 1.0);
        if (depth_factor <= 0.0) return false;

        const previous_tag = history_sample.tag;
        const current_tag = taa_helpers.surfaceTagForHandle(current_surface);
        if (current_tag == taa_helpers.invalid_surface_tag or previous_tag == taa_helpers.invalid_surface_tag or previous_tag != current_tag) return false;

        history_colors[lane] = history_sample.color;
        history_weights[lane] = std.math.clamp(self.temporal_aa_config.history_weight * (0.6 + 0.15 * depth_factor), 0.0, self.temporal_aa_config.history_weight);
    }

    var blended: [max_runtime_color_grade_simd_lanes]u32 = undefined;
    taa_helpers.blendTemporalColorBatch(current_pixels[0..simd_lanes], history_colors[0..simd_lanes], history_weights[0..simd_lanes], blended[0..simd_lanes]);
    for (0..simd_lanes) |lane| {
        self.taa_scratch.resolve_pixels[row_start + x + lane] = blended[lane];
    }
    _ = y;
    return true;
}
