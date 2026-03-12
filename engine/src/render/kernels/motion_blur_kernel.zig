//! Implements the Motion Blur kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA32F = compute.loadRGBA32F;
const storeRGBA32F = compute.storeRGBA32F;
const Float4 = @Vector(4, f32);

pub const MotionBlurPC = extern struct {
    intensity: f32,
    sample_count: u32,
};

pub const MotionBlurKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// getPC returns state derived from Motion Blur Kernel.
    fn getPC(ctx: *const ComputeContext) *const MotionBlurPC {
        return @ptrCast(*const MotionBlurPC, ctx.push_constants.?.ptr);
    }

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const color_tex = ctx.ro_textures[0]; // Input color (RGBA32F)
        const velocity_tex = ctx.ro_textures[1]; // Input velocity (RGBA32F, xy for motion vector)
        const dst = ctx.rw_textures[0]; // Output color (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const current_color: Float4 = loadRGBA32F(color_tex, x, y);
        const velocity: Float4 = loadRGBA32F(velocity_tex, x, y); // xy components are motion vector

        var final_color = current_color;
        const image_w = @as(f32, @floatFromInt(ctx.image_size.x));
        const image_h = @as(f32, @floatFromInt(ctx.image_size.y));
        const inv_count = 1.0 / (@as(f32, @floatFromInt(pc.sample_count)) + 1.0);
        const step_x = velocity[0] * pc.intensity * image_w;
        const step_y = velocity[1] * pc.intensity * image_h;
        const max_x = @as(i32, @intCast(ctx.image_size.x));
        const max_y = @as(i32, @intCast(ctx.image_size.y));
        const rgb_mask: Float4 = .{ 1.0, 1.0, 1.0, 0.0 };

        // Sample along the motion vector
        var i: u32 = 1;
        var t = inv_count;
        while (i <= pc.sample_count) : (i += 1) {
            const sample_x = @as(i32, @intCast(x)) - @as(i32, @intFromFloat(step_x * t));
            const sample_y = @as(i32, @intCast(y)) - @as(i32, @intFromFloat(step_y * t));

            if (sample_x >= 0 and sample_x < max_x and sample_y >= 0 and sample_y < max_y) {
                const sampled_color: Float4 = loadRGBA32F(color_tex, @as(u32, @intCast(sample_x)), @as(u32, @intCast(sample_y)));
                final_color += sampled_color * rgb_mask;
            }
            t += inv_count;
        }

        final_color *= @as(Float4, .{ inv_count, inv_count, inv_count, 1.0 });

        storeRGBA32F(dst, x, y, final_color);
    }
};
