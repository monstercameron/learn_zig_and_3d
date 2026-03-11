const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR = compute.loadR;
const loadRGBA = compute.loadRGBA;
const storeR = compute.storeR;

pub const SsaoPC = extern struct {
    radius: f32,
    bias: f32,
    intensity: f32,
    sample_count: u32,
};

pub const SsaoKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const SsaoPC {
        return @ptrCast(*const SsaoPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const ntex = ctx.ro_textures[0]; // normals (rgba32f: xyz in rgb)
        const dtex = ctx.ro_textures[1]; // depth (r32f)
        const dst  = ctx.rw_textures[0]; // ao (r32f)

        const pc = getPC(ctx);
        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const n = loadRGBA(ntex, x, y);
        const center_depth = loadR(dtex, x, y);

        var occ: f32 = 0;
        var i: u32 = 0;
        while (i < pc.sample_count) : (i += 1) {
            // toy spiral pattern; replace with blue-noise or precomputed kernel
            const ang = @as(f32, @floatFromInt(i)) * 2.3999632; // golden angle
            const r   = pc.radius * ( @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pc.sample_count)));
            const sx = @as(i32, @intCast(x)) + @as(i32, @intFromFloat(r * std.math.cos(ang)));
            const sy = @as(i32, @intCast(y)) + @as(i32, @intFromFloat(r * std.math.sin(ang)));

            if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(ctx.image_size.x)) or sy >= @as(i32, @intCast(ctx.image_size.y))) continue;

            const sd = loadR(dtex, @as(u32, @intCast(sx)), @as(u32, @intCast(sy)));
            const delta = sd - center_depth - pc.bias;
            const contrib = if (delta > 0) 1.0 else 0.0;
            // cheap normal falloff
            const ndot = @max(0.0, n[2]); // assuming view space z in B
            occ += contrib * ndot;
        }

        const ao = 1.0 - @min(1.0, occ / @as(f32, @floatFromInt(pc.sample_count)) * pc.intensity);
        storeR(dst, x, y, ao);
    }
};