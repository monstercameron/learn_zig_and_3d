const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const TonemapKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input HDR color (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output LDR color (RGBA8)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c = loadRGBA(src, x, y);

        // Simple Reinhard tone mapping operator: C / (1 + C)
        const tonemapped_r = c[0] / (1.0 + c[0]);
        const tonemapped_g = c[1] / (1.0 + c[1]);
        const tonemapped_b = c[2] / (1.0 + c[2]);

        storeRGBA(dst, x, y, .{ tonemapped_r, tonemapped_g, tonemapped_b, c[3] });
    }
};