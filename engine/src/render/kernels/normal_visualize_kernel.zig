const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const NormalVisualizeKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input normal (RGBA32F, xyz in rgb)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8)

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const n = loadRGBA(src, x, y);

        // Normals are typically stored in [-1, 1] range. Visualize by mapping to [0, 1] range.
        const r = n[0] * 0.5 + 0.5;
        const g = n[1] * 0.5 + 0.5;
        const b = n[2] * 0.5 + 0.5;

        storeRGBA(dst, x, y, .{ r, g, b, 1.0 });
    }
};