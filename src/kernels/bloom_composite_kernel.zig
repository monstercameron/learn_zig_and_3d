const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const BloomCompositePC = extern struct {
    bloom_intensity: f32,
    scene_intensity: f32,
};

pub const BloomCompositeKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const BloomCompositePC {
        return @ptrCast(*const BloomCompositePC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const scene_tex = ctx.ro_textures[0]; // Original scene (RGBA32F)
        const bloom_tex = ctx.ro_textures[1]; // Blurred bright areas (RGBA32F)
        const dst = ctx.rw_textures[0];       // Final output (RGBA32F or RGBA8)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const scene_color = loadRGBA(scene_tex, x, y);
        const bloom_color = loadRGBA(bloom_tex, x, y);

        // Composite the bloom effect onto the original scene
        const final_r = scene_color[0] * pc.scene_intensity + bloom_color[0] * pc.bloom_intensity;
        const final_g = scene_color[1] * pc.scene_intensity + bloom_color[1] * pc.bloom_intensity;
        const final_b = scene_color[2] * pc.scene_intensity + bloom_color[2] * pc.bloom_intensity;
        const final_a = scene_color[3]; // Alpha usually comes from the scene

        storeRGBA(dst, x, y, .{ final_r, final_g, final_b, final_a });
    }
};