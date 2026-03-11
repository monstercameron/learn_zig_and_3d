const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const InvertKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0];
        const dst = ctx.rw_textures[0];

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c = loadRGBA(src, x, y);
        storeRGBA(dst, x, y, .{ 1.0 - c[0], 1.0 - c[1], 1.0 - c[2], c[3] });
    }
};