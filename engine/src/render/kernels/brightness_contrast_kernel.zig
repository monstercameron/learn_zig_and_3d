//! Implements the Brightness Contrast kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;
const Float4 = @Vector(4, f32);

pub const BrightnessContrastPC = extern struct {
    brightness: f32,
    contrast: f32,
};

pub const BrightnessContrastKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    /// getPC returns state derived from Brightness Contrast Kernel.
    fn getPC(ctx: *const ComputeContext) *const BrightnessContrastPC {
        const bytes = ctx.push_constants.?;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Kernel entry point executed by the compute dispatcher for this pass.
    /// Reads bound inputs from `ctx`, processes the current dispatch work, and writes results to the configured outputs.
    pub fn main(ctx: *ComputeContext) void {
        const src = ctx.ro_textures[0]; // Input color (RGBA8/RGBA32F)
        const dst = ctx.rw_textures[0]; // Output color (RGBA8/RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const c: Float4 = loadRGBA(src, x, y);

        // Apply brightness and contrast
        // Contrast: (C - 0.5) * contrast + 0.5
        // Brightness: C + brightness
        const contrast = @as(Float4, @splat(pc.contrast));
        const half = @as(Float4, @splat(0.5));
        const brightness: Float4 = .{ pc.brightness, pc.brightness, pc.brightness, 0.0 };
        const adjusted = (c - half) * contrast + half + brightness;
        storeRGBA(dst, x, y, .{
            std.math.clamp(adjusted[0], 0.0, 1.0),
            std.math.clamp(adjusted[1], 0.0, 1.0),
            std.math.clamp(adjusted[2], 0.0, 1.0),
            c[3],
        });
    }
};
