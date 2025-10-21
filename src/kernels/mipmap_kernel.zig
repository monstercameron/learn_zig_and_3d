const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const MipmapKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input higher-res texture (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output lower-res texture (RGBA32F)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        // Sample 4 pixels from the source texture to average them
        const s00 = loadRGBA(src, x * 2, y * 2);
        const s10 = loadRGBA(src, x * 2 + 1, y * 2);
        const s01 = loadRGBA(src, x * 2, y * 2 + 1);
        const s11 = loadRGBA(src, x * 2 + 1, y * 2 + 1);

        const avg_r = (s00[0] + s10[0] + s01[0] + s11[0]) * 0.25;
        const avg_g = (s00[1] + s10[1] + s01[1] + s11[1]) * 0.25;
        const avg_b = (s00[2] + s10[2] + s01[2] + s11[2]) * 0.25;
        const avg_a = (s00[3] + s10[3] + s01[3] + s11[3]) * 0.25;

        storeRGBA(dst, x, y, .{ avg_r, avg_g, avg_b, avg_a });
    }
};