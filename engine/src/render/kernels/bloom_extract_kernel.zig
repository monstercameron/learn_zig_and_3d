//! Implements the Bloom Extract kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA32F = compute.loadRGBA32F;
const storeRGBA32F = compute.storeRGBA32F;
const Float4 = @Vector(4, f32);

pub const BloomExtractPC = extern struct {
    threshold: f32,
};

pub const BloomExtractKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// getPC returns state derived from Bloom Extract Kernel.
    fn getPC(ctx: *const ComputeContext) *const BloomExtractPC {
        return @ptrCast(*const BloomExtractPC, ctx.push_constants.?.ptr);
    }

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input scene color (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output bright areas (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c: Float4 = loadRGBA32F(src, x, y);

        // Calculate luminance
        const luminance = @reduce(.Add, c * @as(Float4, .{ 0.299, 0.587, 0.114, 0.0 }));

        // Extract pixels brighter than a threshold
        if (luminance > pc.threshold) {
            // Scale color by how much it exceeds the threshold
            const factor = (luminance - pc.threshold) / (1.0 - pc.threshold);
            const out = c * @as(Float4, .{ factor, factor, factor, 1.0 });
            storeRGBA32F(dst, x, y, out);
        } else {
            storeRGBA32F(dst, x, y, .{ 0.0, 0.0, 0.0, 0.0 });
        }
    }
};
