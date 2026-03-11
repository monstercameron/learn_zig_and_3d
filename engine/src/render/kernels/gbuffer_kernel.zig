const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const storeRGBA = compute.storeRGBA;
const storeR = compute.storeR;

// This kernel is conceptual. G-buffer generation is typically done by the rasterizer
// writing to multiple render targets (MRT) in a single pass, not as a post-process compute kernel.
// However, this demonstrates the *idea* of what data would be generated per pixel.

pub const GBufferKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *ComputeContext) void {
        // In a real G-buffer pass, the rasterizer would output these directly.
        // Here, we just simulate writing some dummy data.

        // Output 0: Albedo (RGBA8/RGBA32F)
        const albedo_tex = ctx.rw_textures[0];
        // Output 1: Normals (RGBA32F)
        const normal_tex = ctx.rw_textures[1];
        // Output 2: Depth (R32F)
        const depth_tex = ctx.rw_textures[2];

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        // Simulate some data being written by the rasterizer
        const dummy_albedo = .{ 0.5, 0.5, 0.5, 1.0 }; // Grey color
        const dummy_normal = .{ 0.0, 1.0, 0.0, 0.0 }; // Upwards normal
        const dummy_depth = @as(f32, @floatFromInt(x + y)) / @as(f32, @floatFromInt(ctx.image_size.x + ctx.image_size.y));

        storeRGBA(albedo_tex, x, y, dummy_albedo);
        storeRGBA(normal_tex, x, y, dummy_normal);
        storeR(depth_tex, x, y, dummy_depth);
    }
};