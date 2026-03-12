//! Implements the Luminance Histogram kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA32F = compute.loadRGBA32F;
const storeR32F = compute.storeR32F;
const Float4 = @Vector(4, f32);

pub const LuminanceKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output luminance (R32F)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c: Float4 = loadRGBA32F(src, x, y);

        // Calculate luminance (BT.709 standard)
        const weights: Float4 = .{ 0.2126, 0.7152, 0.0722, 0.0 };
        const luminance = @reduce(.Add, c * weights);

        storeR32F(dst, x, y, luminance);
    }
};
