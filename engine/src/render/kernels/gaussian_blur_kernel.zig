const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const BlurDirection = enum { horizontal, vertical };

pub const GaussianBlurPC = extern struct {
    direction: BlurDirection,
    radius: u32,
    // For a true Gaussian blur, precomputed weights would be passed here.
};

pub const GaussianBlurKernel = struct {
    pub const group_size_x: u32 = 16;
    pub const group_size_y: u32 = 1; // For 1D blur, group size in other dim is 1
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const GaussianBlurPC {
        return @ptrCast(*const GaussianBlurPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA8/RGBA32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8/RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        var sum_r: f32 = 0;
        var sum_g: f32 = 0;
        var sum_b: f32 = 0;
        var sum_a: f32 = 0;
        var weight_sum: f32 = 0;

        // This is a simplified box blur approximation for demonstration.
        // A true Gaussian blur would use precomputed weights based on a Gaussian function.
        const radius_i = @as(i32, @intCast(pc.radius));

        if (pc.direction == .horizontal) {
            var i: i32 = -radius_i;
            while (i <= radius_i) : (i += 1) {
                const sample_x = @as(u32, @intCast(std.math.clamp(@as(i32, @intCast(x)) + i, 0, @as(i32, @intCast(src.width)) - 1)));
                const c = loadRGBA(src, sample_x, y);
                const weight = 1.0; // For box blur
                sum_r += c[0] * weight;
                sum_g += c[1] * weight;
                sum_b += c[2] * weight;
                sum_a += c[3] * weight;
                weight_sum += weight;
            }
        } else { // vertical
            var i: i32 = -radius_i;
            while (i <= radius_i) : (i += 1) {
                const sample_y = @as(u32, @intCast(std.math.clamp(@as(i32, @intCast(y)) + i, 0, @as(i32, @intCast(src.height)) - 1)));
                const c = loadRGBA(src, x, sample_y);
                const weight = 1.0; // For box blur
                sum_r += c[0] * weight;
                sum_g += c[1] * weight;
                sum_b += c[2] * weight;
                sum_a += c[3] * weight;
                weight_sum += weight;
            }
        }

        storeRGBA(dst, x, y, .{ sum_r / weight_sum, sum_g / weight_sum, sum_b / weight_sum, sum_a / weight_sum });
    }
};