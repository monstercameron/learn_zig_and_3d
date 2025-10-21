const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR = compute.loadR;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const DepthOfFieldPC = extern struct {
    focal_distance: f32,
    focal_range: f32,
    max_blur_radius: f32,
};

pub const DepthOfFieldKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const DepthOfFieldPC {
        return @ptrCast(*const DepthOfFieldPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const color_tex = ctx.ro_textures[0]; // Input color (RGBA32F)
        const depth_tex = ctx.ro_textures[1]; // Input depth (R32F)
        const dst = ctx.rw_textures[0];       // Output color (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const depth = loadR(depth_tex, x, y);
        const color = loadRGBA(color_tex, x, y);

        // Calculate blur amount based on depth
        const dist_from_focal = std.math.fabs(depth - pc.focal_distance);
        var blur_amount = 0.0f;
        if (dist_from_focal > pc.focal_range) {
            blur_amount = std.math.min(1.0, (dist_from_focal - pc.focal_range) / pc.focal_range);
        }
        const blur_radius = blur_amount * pc.max_blur_radius;

        // Simplified blur: just output original color if no blur, otherwise a fixed blur color
        // A real DoF would sample neighbors based on blur_radius
        if (blur_radius < 0.01) {
            storeRGBA(dst, x, y, color);
        } else {
            // For simplicity, just output a slightly blurred version of the color
            // A proper implementation would sample neighbors based on blur_radius
            storeRGBA(dst, x, y, .{ color[0] * 0.8, color[1] * 0.8, color[2] * 0.8, color[3] });
        }
    }
};