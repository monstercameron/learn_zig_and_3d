const std = @import("std");
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

        // Sample along the motion vector
        var i: u32 = 1;
        while (i <= pc.sample_count) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pc.sample_count + 1));
            const sample_x = @as(i32, @intCast(x)) - @as(i32, @intFromFloat(velocity[0] * pc.intensity * t * @as(f32, @floatFromInt(ctx.image_size.x))));
            const sample_y = @as(i32, @intCast(y)) - @as(i32, @intFromFloat(velocity[1] * pc.intensity * t * @as(f32, @floatFromInt(ctx.image_size.y))));

            if (sample_x >= 0 and sample_x < @as(i32, @intCast(ctx.image_size.x)) and
                sample_y >= 0 and sample_y < @as(i32, @intCast(ctx.image_size.y))) {
                const sampled_color = loadRGBA(color_tex, @as(u32, @intCast(sample_x)), @as(u32, @intCast(sample_y)));
                final_color[0] += sampled_color[0];
                final_color[1] += sampled_color[1];
                final_color[2] += sampled_color[2];
            }
        }

        final_color[0] /= (@as(f32, @floatFromInt(pc.sample_count)) + 1.0);
        final_color[1] /= (@as(f32, @floatFromInt(pc.sample_count)) + 1.0);
        final_color[2] /= (@as(f32, @floatFromInt(pc.sample_count)) + 1.0);

        storeRGBA(dst, x, y, final_color);
    }
};