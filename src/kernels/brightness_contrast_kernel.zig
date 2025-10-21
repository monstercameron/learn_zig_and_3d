const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const BrightnessContrastPC = extern struct {
    brightness: f32,
    contrast: f32,
};

pub const BrightnessContrastKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const BrightnessContrastPC {
        return @ptrCast(*const BrightnessContrastPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA8/RGBA32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8/RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c = loadRGBA(src, x, y);

        // Apply brightness and contrast
        // Contrast: (C - 0.5) * contrast + 0.5
        // Brightness: C + brightness
        const r = (c[0] - 0.5) * pc.contrast + 0.5 + pc.brightness;
        const g = (c[1] - 0.5) * pc.contrast + 0.5 + pc.brightness;
        const b = (c[2] - 0.5) * pc.contrast + 0.5 + pc.brightness;

        storeRGBA(dst, x, y, .{ std.math.clamp(r, 0.0, 1.0), std.math.clamp(g, 0.0, 1.0), std.math.clamp(b, 0.0, 1.0), c[3] });
    }
};