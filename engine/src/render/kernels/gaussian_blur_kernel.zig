//! Implements the Gaussian Blur kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const BlurDirection = enum { horizontal, vertical };

pub const GaussianBlurPC = extern struct {
    direction: BlurDirection,
    radius: u32,
    // For a true Gaussian blur, precomputed weights would be passed here.
};

pub const GaussianBlurKernel = struct {
    pub const group_size_x: u32 = 16;
    pub const group_size_y: u32 = 1; // For 1D blur, group size in other dim is 1
    pub const SharedSize: usize = 0;

    /// getPC returns state derived from Gaussian Blur Kernel.
    fn getPC(ctx: *const ComputeContext) *const GaussianBlurPC {
        return @ptrCast(*const GaussianBlurPC, ctx.push_constants.?.ptr);
    }

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA8/RGBA32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8/RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        var sum: Float4 = @splat(0.0);
        var weight_sum: f32 = 0;

        // This is a simplified box blur approximation for demonstration.
        // A true Gaussian blur would use precomputed weights based on a Gaussian function.
        const radius_i = @as(i32, @intCast(pc.radius));

        if (pc.direction == .horizontal) {
            var i: i32 = -radius_i;
            while (i <= radius_i) : (i += 1) {
                const sample_x = @as(u32, @intCast(std.math.clamp(@as(i32, @intCast(x)) + i, 0, @as(i32, @intCast(src.width)) - 1)));
                const c: Float4 = loadRGBA(src, sample_x, y);
                const weight = 1.0; // For box blur
                sum += c * @as(Float4, @splat(weight));
                weight_sum += weight;
            }
        } else { // vertical
            var i: i32 = -radius_i;
            while (i <= radius_i) : (i += 1) {
                const sample_y = @as(u32, @intCast(std.math.clamp(@as(i32, @intCast(y)) + i, 0, @as(i32, @intCast(src.height)) - 1)));
                const c: Float4 = loadRGBA(src, x, sample_y);
                const weight = 1.0; // For box blur
                sum += c * @as(Float4, @splat(weight));
                weight_sum += weight;
            }
        }

        const inv_weight = 1.0 / weight_sum;
        storeRGBA(dst, x, y, sum * @as(Float4, @splat(inv_weight)));
    }
};
