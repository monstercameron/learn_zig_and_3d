//! Implements the Bloom Composite kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

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

    /// getPC returns state derived from Bloom Composite Kernel.
    fn getPC(ctx: *const ComputeContext) *const BloomCompositePC {
        return @ptrCast(*const BloomCompositePC, ctx.push_constants.?.ptr);
    }

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const scene_tex = ctx.ro_textures[0]; // Original scene (RGBA32F)
        const bloom_tex = ctx.ro_textures[1]; // Blurred bright areas (RGBA32F)
        const dst = ctx.rw_textures[0];       // Final output (RGBA32F or RGBA8)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const scene_color = loadRGBA(scene_tex, x, y);
        const bloom_color = loadRGBA(bloom_tex, x, y);

        const Float4 = @Vector(4, f32);
        const scene_v: Float4 = scene_color;
        const bloom_v: Float4 = bloom_color;
        const scene_scale: Float4 = .{ pc.scene_intensity, pc.scene_intensity, pc.scene_intensity, 0.0 };
        const bloom_scale: Float4 = .{ pc.bloom_intensity, pc.bloom_intensity, pc.bloom_intensity, 0.0 };
        var out_v = scene_v * scene_scale + bloom_v * bloom_scale;
        out_v[3] = scene_v[3];
        storeRGBA(dst, x, y, out_v);
    }
};
