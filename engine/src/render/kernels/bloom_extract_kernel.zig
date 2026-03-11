const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const BloomExtractPC = extern struct {
    threshold: f32,
};

pub const BloomExtractKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const BloomExtractPC {
        return @ptrCast(*const BloomExtractPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input scene color (RGBA32F)
        const dst = ctx.rw_textures[0]; // Output bright areas (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c = loadRGBA(src, x, y);

        // Calculate luminance
        const luminance = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

        // Extract pixels brighter than a threshold
        if (luminance > pc.threshold) {
            // Scale color by how much it exceeds the threshold
            const factor = (luminance - pc.threshold) / (1.0 - pc.threshold);
            storeRGBA(dst, x, y, .{ c[0] * factor, c[1] * factor, c[2] * factor, c[3] });
        } else {
            storeRGBA(dst, x, y, .{ 0.0, 0.0, 0.0, 0.0 });
        }
    }
};