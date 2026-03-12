//! Implements the Mipmap kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const MipmapKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input higher-res texture (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output lower-res texture (RGBA32F)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        // Sample 4 pixels from the source texture to average them
        const s00: Float4 = loadRGBA(src, x * 2, y * 2);
        const s10: Float4 = loadRGBA(src, x * 2 + 1, y * 2);
        const s01: Float4 = loadRGBA(src, x * 2, y * 2 + 1);
        const s11: Float4 = loadRGBA(src, x * 2 + 1, y * 2 + 1);
        const avg: Float4 = (s00 + s10 + s01 + s11) * @as(Float4, @splat(0.25));

        storeRGBA(dst, x, y, avg);
    }
};
