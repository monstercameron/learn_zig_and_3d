//! Implements the Tonemap kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA32F = compute.loadRGBA32F;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const TonemapKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input HDR color (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output LDR color (RGBA8)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c: Float4 = loadRGBA32F(src, x, y);

        // Simple Reinhard tone mapping operator: C / (1 + C)
        const tonemapped = c / (@as(Float4, @splat(1.0)) + c);

        storeRGBA(dst, x, y, .{ tonemapped[0], tonemapped[1], tonemapped[2], c[3] });
    }
};
