//! Screen-space contact shadows (v2). For each lit pixel, walk N
//! steps along the camera-space light direction. At each step,
//! reproject to screen space and sample `scene_depth`. If the sampled
//! depth is closer to the camera than the marched position, we're
//! blocked by intervening geometry — darken proportional to how
//! occluded we are.
//!
//! This is *not* a full shadow map. It only catches occluders that
//! are on-screen and close to the receiver. But it's free of the
//! shadow-map projection bias / acne / map-resolution issues and it
//! drops directly into the deferred pipeline because everything it
//! needs (depth, camera-space normal, light direction) already lives
//! in the G-buffer.
//!
//! Idempotent: each frame's shadow is recomputed from G-buffer state,
//! not from the prior frame's pixels.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "screen_shadows",
    .idempotent = true,
    .requires_scratch = false,
    .reads_gbuffer = true,
    .summary = "Screen-space contact shadows from G-buffer depth ray-march.",
};

pub const MAX_LIGHTS: usize = 4;

pub const Config = struct {
    /// Camera-space light directions (each TOWARDS its light), up to
    /// MAX_LIGHTS. Each light contributes a separate shadow ray-march;
    /// the final shadow factor is the average so multiple lights
    /// produce overlapping cast shadows instead of one harsh shadow.
    light_dirs: [MAX_LIGHTS]v2.Vec3 = [_]v2.Vec3{.{ .x = 0.0, .y = 1.0, .z = 0.0 }} ** MAX_LIGHTS,
    light_count: u32 = 1,
    /// 0..1; how dark a fully-occluded pixel gets. 1 = pitch black.
    strength: f32 = 0.55,
    /// Number of ray-march steps per light.
    steps: u32 = 8,
    /// Step length in camera-space units along the light direction.
    step_size: f32 = 0.20,
    /// Bias added to the marched depth before comparing against the
    /// scene depth — prevents self-shadowing acne.
    bias: f32 = 0.03,
    /// FOV reconstruction for camera→screen projection.
    fov_y_tan_half: f32 = 0.5773,
    aspect: f32 = 16.0 / 9.0,
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.strength <= 0.0 or config.steps == 0 or config.light_count == 0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    const gbuf = inputs.gbuf orelse return result;
    if (gbuf.depth.len != inputs.in_color.len) return result;

    // Pre-normalise each light direction. Skip degenerate (zero) ones.
    var lx_arr: [MAX_LIGHTS]f32 = undefined;
    var ly_arr: [MAX_LIGHTS]f32 = undefined;
    var lz_arr: [MAX_LIGHTS]f32 = undefined;
    var valid_count: u32 = 0;
    var i: u32 = 0;
    while (i < config.light_count and i < MAX_LIGHTS) : (i += 1) {
        const ld = config.light_dirs[i];
        const len = @sqrt(ld.x * ld.x + ld.y * ld.y + ld.z * ld.z);
        if (len < 1.0e-4) continue;
        lx_arr[valid_count] = ld.x / len;
        ly_arr[valid_count] = ld.y / len;
        lz_arr[valid_count] = ld.z / len;
        valid_count += 1;
    }
    if (valid_count == 0) return result;

    const w: i32 = inputs.width;
    const h: i32 = inputs.height;
    const w_us: usize = @intCast(w);
    const w_f: f32 = @floatFromInt(w);
    const h_f: f32 = @floatFromInt(h);
    const fov_t = config.fov_y_tan_half;
    const aspect = config.aspect;
    const steps = config.steps;
    const step_size = config.step_size;
    const bias = config.bias;
    const strength = config.strength;
    const inv_lights: f32 = 1.0 / @as(f32, @floatFromInt(valid_count));

    var modified: usize = 0;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const ndc_y = 1.0 - (yf + 0.5) / h_f * 2.0;
        const view_y = ndc_y * fov_t;
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w_us + @as(usize, @intCast(x));
            const d_here = gbuf.depth[idx];
            if (!std.math.isFinite(d_here)) {
                if (inputs.out_color.ptr != inputs.in_color.ptr) inputs.out_color[idx] = inputs.in_color[idx];
                continue;
            }
            const xf: f32 = @floatFromInt(x);
            const ndc_x = (xf + 0.5) / w_f * 2.0 - 1.0;
            const view_x = ndc_x * aspect * fov_t;
            const px_here = view_x * d_here;
            const py_here = view_y * d_here;
            const pz_here = d_here;
            const n = gbuf.normal[idx];

            // Accumulate per-light shadow contribution. Each light that
            // (a) faces the surface and (b) finds an on-screen occluder
            // along its march adds 1/N to the shadow factor.
            var shadow_frac: f32 = 0.0;
            var li: u32 = 0;
            while (li < valid_count) : (li += 1) {
                const lx = lx_arr[li];
                const ly = ly_arr[li];
                const lz = lz_arr[li];
                const n_dot_l = n.x * lx + n.y * ly + n.z * lz;
                if (n_dot_l <= 0.01) continue;
                var s: u32 = 1;
                var hit: bool = false;
                while (s <= steps) : (s += 1) {
                    const t: f32 = @as(f32, @floatFromInt(s)) * step_size;
                    const mx = px_here + lx * t;
                    const my = py_here + ly * t;
                    const mz = pz_here + lz * t;
                    if (mz <= 0.01) break;
                    const sx_ndc = (mx / mz) / (aspect * fov_t);
                    const sy_ndc = (my / mz) / fov_t;
                    if (sx_ndc < -1.0 or sx_ndc > 1.0 or sy_ndc < -1.0 or sy_ndc > 1.0) break;
                    const sx = (sx_ndc + 1.0) * 0.5 * w_f;
                    const sy = (1.0 - sy_ndc) * 0.5 * h_f;
                    const ix: i32 = @intFromFloat(sx);
                    const iy: i32 = @intFromFloat(sy);
                    if (ix < 0 or ix >= w or iy < 0 or iy >= h) break;
                    const sidx = @as(usize, @intCast(iy)) * w_us + @as(usize, @intCast(ix));
                    const sampled = gbuf.depth[sidx];
                    if (!std.math.isFinite(sampled)) continue;
                    if (sampled + bias < mz) {
                        hit = true;
                        break;
                    }
                }
                if (hit) shadow_frac += inv_lights;
            }

            const src = inputs.in_color[idx];
            if (shadow_frac <= 0.001) {
                if (inputs.out_color.ptr != inputs.in_color.ptr) inputs.out_color[idx] = src;
                continue;
            }
            const factor = 1.0 - shadow_frac * strength;
            const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
            const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
            const sb: f32 = @floatFromInt(src & 0xFF);
            const or_: u32 = @intFromFloat(std.math.clamp(sr * factor, 0.0, 255.0));
            const og: u32 = @intFromFloat(std.math.clamp(sg * factor, 0.0, 255.0));
            const ob: u32 = @intFromFloat(std.math.clamp(sb * factor, 0.0, 255.0));
            inputs.out_color[idx] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
            modified += 1;
        }
    }
    result.pixels_modified = modified;
    return result;
}
