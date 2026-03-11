const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeR = compute.storeR;

pub const LuminanceKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output luminance (R32F)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c = loadRGBA(src, x, y);

        // Calculate luminance (BT.709 standard)
        const luminance = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];

        storeR(dst, x, y, luminance);
    }
};