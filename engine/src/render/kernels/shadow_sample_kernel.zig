//! Implements the Shadow Sample kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const math = @import("../../core/math.zig");

/// sampleOcclusion samples values used by Shadow Sample Kernel.
pub fn sampleOcclusion(shadow: anytype, world_pos: math.Vec3) f32 {
    if (!shadow.active) return 0.0;

    const lx = math.Vec3.dot(world_pos, shadow.basis_right);
    const ly = math.Vec3.dot(world_pos, shadow.basis_up);
    const lz = math.Vec3.dot(world_pos, shadow.basis_forward);
    if (lx < shadow.min_x or lx > shadow.max_x or ly < shadow.min_y or ly > shadow.max_y or lz < shadow.min_z or lz > shadow.max_z) return 0.0;

    const tex_x = (lx - shadow.min_x) * shadow.inv_extent_x * @as(f32, @floatFromInt(shadow.width - 1));
    const tex_y = (shadow.max_y - ly) * shadow.inv_extent_y * @as(f32, @floatFromInt(shadow.height - 1));
    const center_x = @as(i32, @intFromFloat(@round(tex_x)));
    const center_y = @as(i32, @intFromFloat(@round(tex_y)));

    const offsets = [_][2]i32{
        .{ 0, 0 },
        .{ -1, 0 },
        .{ 1, 0 },
        .{ 0, -1 },
        .{ 0, 1 },
    };

    var occluded: f32 = 0.0;
    var weight_sum: f32 = 0.0;
    for (offsets, 0..) |offset, tap_index| {
        const sx = std.math.clamp(center_x + offset[0], 0, @as(i32, @intCast(shadow.width - 1)));
        const sy = std.math.clamp(center_y + offset[1], 0, @as(i32, @intCast(shadow.height - 1)));
        const sample_idx = @as(usize, @intCast(sy)) * shadow.width + @as(usize, @intCast(sx));
        const stored_depth = shadow.depth[sample_idx];
        if (!std.math.isFinite(stored_depth)) continue;

        const weight: f32 = if (tap_index == 0) 0.4 else 0.15;
        weight_sum += weight;
        if (lz > stored_depth + shadow.depth_bias + shadow.texel_bias) occluded += weight;
    }

    if (weight_sum <= 0.0) return 0.0;
    return occluded / weight_sum;
}