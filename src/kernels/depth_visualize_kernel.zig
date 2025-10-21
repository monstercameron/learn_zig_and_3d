const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR = compute.loadR;
const storeRGBA = compute.storeRGBA;

pub const DepthVisualizeKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input depth (R32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const depth = loadR(src, x, y);

        // Map depth (0.0 to 1.0) to grayscale color
        // Assuming 0.0 is near, 1.0 is far
        const gray = 1.0 - depth; // Invert so near is white, far is black

        storeRGBA(dst, x, y, .{ gray, gray, gray, 1.0 });
    }
};