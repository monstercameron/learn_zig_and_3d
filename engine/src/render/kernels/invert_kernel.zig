//! Implements the Invert kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const InvertKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0];
        const dst = ctx.rw_textures[0];

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c: Float4 = loadRGBA(src, x, y);
        const inv = @as(Float4, @splat(1.0)) - c;
        storeRGBA(dst, x, y, .{ inv[0], inv[1], inv[2], c[3] });
    }
};
