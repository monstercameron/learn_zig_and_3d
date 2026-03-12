//! Implements the Depth Visualize kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR32F = compute.loadR32F;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const DepthVisualizeKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input depth (R32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const depth = loadR32F(src, x, y);

        // Map depth (0.0 to 1.0) to grayscale color
        // Assuming 0.0 is near, 1.0 is far
        const gray = 1.0 - depth; // Invert so near is white, far is black

        const out: Float4 = .{ gray, gray, gray, 1.0 };
        storeRGBA(dst, x, y, out);
    }
};
