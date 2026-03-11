const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const MotionBlurPC = extern struct {
    intensity: f32,
    sample_count: u32,
};

pub const MotionBlurKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const MotionBlurPC {
        return @ptrCast(*const MotionBlurPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const color_tex = ctx.ro_textures[0]; // Input color (RGBA32F)
        const velocity_tex = ctx.ro_textures[1]; // Input velocity (RGBA32F, xy for motion vector)
        const dst = ctx.rw_textures[0];          // Output color (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const current_color = loadRGBA(color_tex, x, y);
        const velocity = loadRGBA(velocity_tex, x, y); // xy components are motion vector

        var final_color = current_color;
        const image_w = @as(f32, @floatFromInt(ctx.image_size.x));
        const image_h = @as(f32, @floatFromInt(ctx.image_size.y));
        const inv_count = 1.0 / (@as(f32, @floatFromInt(pc.sample_count)) + 1.0);
        const step_x = velocity[0] * pc.intensity * image_w;
        const step_y = velocity[1] * pc.intensity * image_h;
        const max_x = @as(i32, @intCast(ctx.image_size.x));
        const max_y = @as(i32, @intCast(ctx.image_size.y));

        // Sample along the motion vector
        var i: u32 = 1;
        var t = inv_count;
        while (i <= pc.sample_count) : (i += 1) {
            const sample_x = @as(i32, @intCast(x)) - @as(i32, @intFromFloat(step_x * t));
            const sample_y = @as(i32, @intCast(y)) - @as(i32, @intFromFloat(step_y * t));

            if (sample_x >= 0 and sample_x < max_x and sample_y >= 0 and sample_y < max_y) {
                const sampled_color = loadRGBA(color_tex, @as(u32, @intCast(sample_x)), @as(u32, @intCast(sample_y)));
                final_color[0] += sampled_color[0];
                final_color[1] += sampled_color[1];
                final_color[2] += sampled_color[2];
            }
            t += inv_count;
        }

        final_color[0] *= inv_count;
        final_color[1] *= inv_count;
        final_color[2] *= inv_count;

        storeRGBA(dst, x, y, final_color);
    }
};
