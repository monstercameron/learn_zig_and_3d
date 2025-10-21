const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR = compute.loadR;
const storeR = compute.storeR;

pub const SobelKernel = struct {
    pub const group_size_x: u32 = 16;
    pub const group_size_y: u32 = 16;
    pub const SharedSize: usize = 0;

    fn clamp(v: i32, lo: i32, hi: i32) i32 { return if (v < lo) lo else if (v > hi) hi else v; }

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0];
        const dst = ctx.rw_textures[0];
        const w = @as(i32, @intCast(ctx.image_size.x));
        const h = @as(i32, @intCast(ctx.image_size.y));

        const x = @as(i32, @intCast(ctx.global_id.x));
        const y = @as(i32, @intCast(ctx.global_id.y));

        var gx: f32 = 0;
        var gy: f32 = 0;

        inline for ([_]i32{-1,0,1}) |dy| {
            inline for ([_]i32{-1,0,1}) |dx| {
                const sx = @as(u32, @intCast(clamp(x+dx, 0, w-1)));
                const sy = @as(u32, @intCast(clamp(y+dy, 0, h-1)));
                const v = loadR(src, sx, sy);
                const wx = switch (dy) { -1 => -1, 0 => 0, 1 => 1, else => 0 } * switch (dx) { -1 => 1, 0 => 2, 1 => 1, else => 0 };
                const wy = switch (dx) { -1 => 1, 0 => 2, 1 => 1, else => 0 } * switch (dy) { -1 => 1, 0 => 2, 1 => 1, else => 0 };
                gx += v * @as(f32, @floatFromInt(wx));
                gy += v * @as(f32, @floatFromInt(wy));
            }
        }

        const mag = std.math.sqrt(gx*gx + gy*gy);
        storeR(dst, @as(u32, @intCast(x)), @as(u32, @intCast(y)), mag);
    }
};