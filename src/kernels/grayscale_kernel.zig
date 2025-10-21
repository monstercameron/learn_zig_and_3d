const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeR = compute.storeR;

pub const GrayscaleKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA8/RGBA32F)
        const dst = ctx.rw_textures[0]; // Output grayscale (R8/R32F)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c = loadRGBA(src, x, y);
        // Simple luminance calculation (BT.601 standard)
        const gray = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
        storeR(dst, x, y, gray);
    }
};