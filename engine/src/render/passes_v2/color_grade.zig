//! Color grade (v2). Per-pixel brightness, contrast, saturation, gamma.
//! No LUT — direct math so the user can tune the four scalars without
//! a recompile or texture rebuild.
//!
//! Idempotent only when all knobs are at their unity values
//! (brightness=0, contrast=0, saturation=1, gamma=1). Outside that the
//! pass is destructive but operates per-pixel so re-running on its own
//! output simply re-applies the curve — drivers that hate that should
//! treat it as non-idempotent.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "color_grade",
    .idempotent = false,
    .requires_scratch = false,
    .reads_gbuffer = true, // depth for silhouette mask
    .summary = "Brightness, contrast (S-curve), saturation, gamma.",
};

pub const Config = struct {
    /// -1..+1; added to each channel before contrast.
    brightness: f32 = 0.0,
    /// -1..+1; positive steepens S-curve around mid-grey.
    contrast: f32 = 0.0,
    /// 0..2; 1 = neutral, >1 chroma boost, <1 desaturate.
    saturation: f32 = 1.0,
    /// 0.5..2.5; output gamma. 1.0 = neutral.
    gamma: f32 = 1.0,
};

inline fn applyOne(v: f32, brightness: f32, contrast: f32, gamma: f32) f32 {
    var out = v + brightness * 255.0;
    out = (out - 127.5) * (1.0 + contrast) + 127.5;
    out = std.math.clamp(out, 0.0, 255.0);
    if (gamma != 1.0) {
        const n = out / 255.0;
        out = std.math.pow(f32, n, 1.0 / gamma) * 255.0;
    }
    return out;
}

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.brightness == 0.0 and config.contrast == 0.0 and
        config.saturation == 1.0 and config.gamma == 1.0)
    {
        return result;
    }
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    const depth = if (inputs.gbuf) |g| g.depth else null;
    var modified: usize = 0;
    var idx: usize = 0;
    while (idx < inputs.in_color.len) : (idx += 1) {
        const src = inputs.in_color[idx];
        if (depth) |dbuf| {
            if (!std.math.isFinite(dbuf[idx])) {
                if (inputs.out_color.ptr != inputs.in_color.ptr) inputs.out_color[idx] = src;
                continue;
            }
        }
        var r: f32 = @floatFromInt((src >> 16) & 0xFF);
        var g: f32 = @floatFromInt((src >> 8) & 0xFF);
        var b: f32 = @floatFromInt(src & 0xFF);
        // Saturation around perceptual luminance.
        if (config.saturation != 1.0) {
            const lum = 0.299 * r + 0.587 * g + 0.114 * b;
            r = lum + (r - lum) * config.saturation;
            g = lum + (g - lum) * config.saturation;
            b = lum + (b - lum) * config.saturation;
        }
        r = applyOne(r, config.brightness, config.contrast, config.gamma);
        g = applyOne(g, config.brightness, config.contrast, config.gamma);
        b = applyOne(b, config.brightness, config.contrast, config.gamma);
        const out: u32 = 0xFF000000 |
            (@as(u32, @intFromFloat(r)) << 16) |
            (@as(u32, @intFromFloat(g)) << 8) |
            @as(u32, @intFromFloat(b));
        inputs.out_color[idx] = out;
        if (out != src) modified += 1;
    }
    result.pixels_modified = modified;
    return result;
}
