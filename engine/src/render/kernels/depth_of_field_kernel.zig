//! Implements the Depth Of Field kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR32F = compute.loadR32F;
const loadRGBA32F = compute.loadRGBA32F;
const storeRGBA32F = compute.storeRGBA32F;
const Float4 = @Vector(4, f32);

pub const DepthOfFieldPC = extern struct {
    focal_distance: f32,
    focal_range: f32,
    max_blur_radius: f32,
};

pub const DepthOfFieldKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// getPC returns state derived from Depth Of Field Kernel.
    fn getPC(ctx: *const ComputeContext) *const DepthOfFieldPC {
        return @ptrCast(ctx.push_constants.?.ptr);
    }

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const color_tex = ctx.ro_textures[0]; // Input color (RGBA32F)
        const depth_tex = ctx.ro_textures[1]; // Input depth (R32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const depth = loadR32F(depth_tex, x, y);
        const color: Float4 = loadRGBA32F(color_tex, x, y);

        // Calculate blur amount based on depth
        const dist_from_focal = std.math.fabs(depth - pc.focal_distance);
        var blur_amount: f32 = 0.0;
        if (dist_from_focal > pc.focal_range) {
            blur_amount = std.math.min(1.0, (dist_from_focal - pc.focal_range) / pc.focal_range);
        }
        const blur_radius = blur_amount * pc.max_blur_radius;

        // Simplified blur: just output original color if no blur, otherwise a fixed blur color
        // A real DoF would sample neighbors based on blur_radius
        if (blur_radius < 0.01) {
            storeRGBA32F(dst, x, y, color);
        } else {
            // For simplicity, just output a slightly blurred version of the color
            // A proper implementation would sample neighbors based on blur_radius
            storeRGBA32F(dst, x, y, color * @as(Float4, .{ 0.8, 0.8, 0.8, 1.0 }));
        }
    }
};

/// Applies this effect over a `[start_row, end_row)` span.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn applyRows(
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
    const pixels = scene_pixels;
    const out_pixels = scratch_pixels;
    const depth = scene_depth;
    const w = width;
    const h = height;
    const max_rad = @as(f32, @floatFromInt(max_blur_radius));

    for (start_row..end_row) |y| {
        const row_start = y * w;
        const y_i32 = @as(i32, @intCast(y));
        for (0..w) |x| {
            const idx = row_start + x;
            const d = depth[idx];
            const dist_from_focal = @abs(d - focal_distance);

            var blur_amount: f32 = 0.0;
            if (dist_from_focal > focal_range) {
                blur_amount = @min(1.0, (dist_from_focal - focal_range) / focal_range);
            }

            const blur_radius = blur_amount * max_rad;

            if (blur_radius < 1.0) {
                out_pixels[idx] = pixels[idx];
            } else {
                const irad = @as(i32, @intFromFloat(blur_radius));
                var r_sum: u32 = 0;
                var g_sum: u32 = 0;
                var b_sum: u32 = 0;
                var count: u32 = 0;

                const min_y = @max(0, y_i32 - irad);
                const max_y = @min(@as(i32, @intCast(h)) - 1, y_i32 + irad);
                const min_x = @max(0, @as(i32, @intCast(x)) - irad);
                const max_x = @min(@as(i32, @intCast(w)) - 1, @as(i32, @intCast(x)) + irad);
                const step: i32 = if (irad > 2) 2 else 1;

                var sy: i32 = min_y;
                while (sy <= max_y) : (sy += step) {
                    const sy_row_start = @as(usize, @intCast(sy)) * w;
                    var sx: i32 = min_x;
                    while (sx <= max_x) : (sx += step) {
                        const sidx = sy_row_start + @as(usize, @intCast(sx));
                        const p = pixels[sidx];
                        r_sum += (p >> 16) & 0xFF;
                        g_sum += (p >> 8) & 0xFF;
                        b_sum += p & 0xFF;
                        count += 1;
                    }
                }

                const out_r = r_sum / count;
                const out_g = g_sum / count;
                const out_b = b_sum / count;
                out_pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
            }
        }
    }
}
