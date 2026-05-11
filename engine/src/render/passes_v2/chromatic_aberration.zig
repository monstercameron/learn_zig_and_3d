//! Chromatic aberration (v2). Radial channel offset: R is read from
//! a position pushed outward from the screen centre, B from a position
//! pulled inward. Cheap "lens" look without the round-off.
//!
//! Requires a separate source buffer (`requires_scratch = true`).
//! Running this in-place would compound: the radial gather reads
//! pixels that have already been modified on the same row, dragging
//! the previous output into the next sample. The v1 pass shipped with
//! that bug.
//!
//! Silhouette-correct: skips pixels with non-finite depth so the
//! background never picks up false fringes.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "chromatic_aberration",
    .idempotent = false, // each application doubles the offset
    .requires_scratch = true,
    .reads_gbuffer = true,
    .summary = "Radial RGB channel offset (lens fringing).",
};

pub const Config = struct {
    /// Pixel offset at the screen corner. 0 = off. Reasonable: 0.5..3.0.
    strength_px: f32 = 1.5,
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.strength_px <= 0.0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    // In-place is invalid for CA — the radial gather would read already-modified pixels.
    if (inputs.in_color.ptr == inputs.out_color.ptr) return result;

    const w: usize = @intCast(inputs.width);
    const h: usize = @intCast(inputs.height);
    const w_f: f32 = @floatFromInt(inputs.width);
    const h_f: f32 = @floatFromInt(inputs.height);
    const inv_w: f32 = 1.0 / w_f;
    const inv_h: f32 = 1.0 / h_f;
    const max_off = config.strength_px;
    const depth = if (inputs.gbuf) |g| g.depth else null;

    var modified: usize = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const ndc_y = (yf + 0.5) * inv_h - 0.5;
        const row = y * w;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const idx = row + x;
            if (depth) |dbuf| {
                if (!std.math.isFinite(dbuf[idx])) {
                    inputs.out_color[idx] = inputs.in_color[idx];
                    continue;
                }
            }
            const xf: f32 = @floatFromInt(x);
            const ndc_x = (xf + 0.5) * inv_w - 0.5;
            const r2 = ndc_x * ndc_x + ndc_y * ndc_y;
            const r = @sqrt(r2);
            const dir_inv: f32 = if (r > 1.0e-4) 1.0 / r else 0.0;
            const dx_n = ndc_x * dir_inv;
            const dy_n = ndc_y * dir_inv;
            const off = max_off * r * 2.0;
            // R sampled outward, B sampled inward, G from origin.
            const xr = std.math.clamp(xf + dx_n * off, 0.0, w_f - 1.0);
            const yr = std.math.clamp(yf + dy_n * off, 0.0, h_f - 1.0);
            const xb = std.math.clamp(xf - dx_n * off, 0.0, w_f - 1.0);
            const yb = std.math.clamp(yf - dy_n * off, 0.0, h_f - 1.0);
            const orig = inputs.in_color[idx];
            const r_pix = inputs.in_color[@as(usize, @intFromFloat(yr)) * w + @as(usize, @intFromFloat(xr))];
            const b_pix = inputs.in_color[@as(usize, @intFromFloat(yb)) * w + @as(usize, @intFromFloat(xb))];
            const r_chan = (r_pix >> 16) & 0xFF;
            const g_chan = (orig >> 8) & 0xFF;
            const b_chan = b_pix & 0xFF;
            inputs.out_color[idx] = 0xFF000000 | (r_chan << 16) | (g_chan << 8) | b_chan;
            if (inputs.out_color[idx] != orig) modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
