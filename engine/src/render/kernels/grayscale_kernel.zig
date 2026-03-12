//! Implements the Grayscale kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeR = compute.storeR;
const Float4 = @Vector(4, f32);

pub const GrayscaleKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA8/RGBA32F)
        const dst = ctx.rw_textures[0]; // Output grayscale (R8/R32F)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c: Float4 = loadRGBA(src, x, y);
        // Simple luminance calculation (BT.601 standard)
        const gray = @reduce(.Add, c * @as(Float4, .{ 0.299, 0.587, 0.114, 0.0 }));
        storeR(dst, x, y, gray);
    }
};
