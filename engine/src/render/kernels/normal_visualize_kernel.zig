//! Implements the Normal Visualize kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA32F = compute.loadRGBA32F;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const NormalVisualizeKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input normal (RGBA32F, xyz in rgb)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const n: Float4 = loadRGBA32F(src, x, y);

        // Normals are typically stored in [-1, 1] range. Visualize by mapping to [0, 1] range.
        const rgb = n * @as(Float4, @splat(0.5)) + @as(Float4, @splat(0.5));

        storeRGBA(dst, x, y, .{ rgb[0], rgb[1], rgb[2], 1.0 });
    }
};
