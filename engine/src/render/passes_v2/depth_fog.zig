//! Depth-fog pass (v2). Linear-distance fog over the camera-space depth
//! G-buffer. Pixels at non-finite depth are skipped entirely — background
//! never accumulates fog. Idempotent: re-running on its own output is a
//! no-op because the fog blend is keyed off `depth`, not the current
//! pixel value.
//!
//! Inputs: LDR `in_color`, depth from G-buffer.
//! Outputs: LDR `out_color`. Safe in-place (in_color == out_color).
//!
//! Fog model: factor = clamp((depth - near) / (far - near), 0, 1) * strength.
//!            out = lerp(in, fog_color, factor).
//!
//! Vectorised over `cpu_features.SIMD_F32_LANES`.

const std = @import("std");
const v2 = @import("mod.zig");
const cpu_features = @import("../../core/cpu_features.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "depth_fog",
    .idempotent = true,
    .requires_scratch = false,
    .reads_gbuffer = true,
    .summary = "Linear depth fog; silhouette-masked via G-buffer depth.",
};

pub const Config = struct {
    near: f32 = 5.5,
    far: f32 = 16.0,
    strength: f32 = 1.0,
    color: [3]u8 = .{ 92, 118, 142 }, // soft cool grey-blue
};

pub fn execute(inputs: v2.Inputs, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (config.strength <= 0.0) return result;
    const gbuf = inputs.gbuf orelse return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (gbuf.depth.len != inputs.in_color.len) return result;

    const inv_range = 1.0 / @max(0.001, config.far - config.near);
    const fog_r: f32 = @floatFromInt(config.color[0]);
    const fog_g: f32 = @floatFromInt(config.color[1]);
    const fog_b: f32 = @floatFromInt(config.color[2]);
    const strength = config.strength;
    const near = config.near;

    const w: usize = @intCast(inputs.width);
    const total: usize = inputs.in_color.len;

    var min_x: i32 = inputs.width;
    var max_x: i32 = -1;
    var min_y: i32 = inputs.height;
    var max_y: i32 = -1;
    var modified: usize = 0;

    const lanes = cpu_features.SIMD_F32_LANES;
    const VF = @Vector(lanes, f32);
    const v_near: VF = @splat(near);
    const v_inv: VF = @splat(inv_range);
    const v_strength: VF = @splat(strength);
    const v_one: VF = @splat(1.0);
    const v_zero: VF = @splat(0.0);

    var idx: usize = 0;
    while (idx + lanes <= total) : (idx += lanes) {
        // Load depths and compute fog factor per lane.
        var v_depth: VF = undefined;
        var v_valid_mask: VF = undefined;
        inline for (0..lanes) |li| {
            const d = gbuf.depth[idx + li];
            const valid = std.math.isFinite(d) and d > near;
            v_depth[li] = if (valid) d else near;
            v_valid_mask[li] = if (valid) 1.0 else 0.0;
        }
        const v_norm = @min(v_one, @max(v_zero, (v_depth - v_near) * v_inv));
        const v_factor = v_norm * v_strength * v_valid_mask;

        // Lane-by-lane blend. `inline for` is comptime over `lanes`,
        // so we can't `continue` — use an explicit conditional block.
        inline for (0..lanes) |li| {
            const factor = v_factor[li];
            if (factor > 0.001) {
                const src = inputs.in_color[idx + li];
                const inv = 1.0 - factor;
                const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
                const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
                const sb: f32 = @floatFromInt(src & 0xFF);
                const or_: u32 = @intFromFloat(std.math.clamp(sr * inv + fog_r * factor, 0.0, 255.0));
                const og: u32 = @intFromFloat(std.math.clamp(sg * inv + fog_g * factor, 0.0, 255.0));
                const ob: u32 = @intFromFloat(std.math.clamp(sb * inv + fog_b * factor, 0.0, 255.0));
                inputs.out_color[idx + li] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
                modified += 1;
                const x_i32: i32 = @intCast((idx + li) % w);
                const y_i32: i32 = @intCast((idx + li) / w);
                min_x = @min(min_x, x_i32);
                max_x = @max(max_x, x_i32);
                min_y = @min(min_y, y_i32);
                max_y = @max(max_y, y_i32);
            }
        }
    }

    // Scalar tail.
    while (idx < total) : (idx += 1) {
        const d = gbuf.depth[idx];
        if (!std.math.isFinite(d) or d <= near) continue;
        const norm = std.math.clamp((d - near) * inv_range, 0.0, 1.0);
        const factor = norm * strength;
        if (factor <= 0.001) continue;
        const src = inputs.in_color[idx];
        const inv = 1.0 - factor;
        const sr: f32 = @floatFromInt((src >> 16) & 0xFF);
        const sg: f32 = @floatFromInt((src >> 8) & 0xFF);
        const sb: f32 = @floatFromInt(src & 0xFF);
        const or_: u32 = @intFromFloat(std.math.clamp(sr * inv + fog_r * factor, 0.0, 255.0));
        const og: u32 = @intFromFloat(std.math.clamp(sg * inv + fog_g * factor, 0.0, 255.0));
        const ob: u32 = @intFromFloat(std.math.clamp(sb * inv + fog_b * factor, 0.0, 255.0));
        inputs.out_color[idx] = (src & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
        modified += 1;
        const x_i32: i32 = @intCast(idx % w);
        const y_i32: i32 = @intCast(idx / w);
        min_x = @min(min_x, x_i32);
        max_x = @max(max_x, x_i32);
        min_y = @min(min_y, y_i32);
        max_y = @max(max_y, y_i32);
    }

    result.pixels_modified = modified;
    if (modified > 0) {
        result.touched_rect = .{
            .min_x = min_x,
            .min_y = min_y,
            .max_x = max_x,
            .max_y = max_y,
        };
    }
    return result;
}

// -----------------------------------------------------------------------
//                              tests
// -----------------------------------------------------------------------

test "background pixels are not fogged" {
    const w: i32 = 4;
    const h: i32 = 1;
    var src = [_]u32{ 0xFF112233, 0xFF112233, 0xFF112233, 0xFF112233 };
    var dst = [_]u32{0} ** 4;
    const depth = [_]f32{
        std.math.inf(f32),
        std.math.inf(f32),
        std.math.inf(f32),
        std.math.inf(f32),
    };
    const normal = [_]v2.Vec3{.{ .x = 0, .y = 0, .z = 0 }} ** 4;
    const base = [_]u32{0} ** 4;
    const mat = [_]u32{0} ** 4;
    const gbuf: v2.GBufferView = .{
        .width = w,
        .height = h,
        .depth = &depth,
        .normal = &normal,
        .base_color = &base,
        .material = &mat,
    };
    const inputs: v2.Inputs = .{
        .width = w,
        .height = h,
        .in_color = &src,
        .out_color = &dst,
        .gbuf = gbuf,
    };
    const r = execute(inputs, .{});
    try std.testing.expectEqual(@as(usize, 0), r.pixels_modified);
}

test "geometry at far distance is fully fogged" {
    const w: i32 = 1;
    const h: i32 = 1;
    var src = [_]u32{0xFF000000}; // pure black
    var dst = [_]u32{0};
    const depth = [_]f32{100.0}; // way past far=16
    const normal = [_]v2.Vec3{.{ .x = 0, .y = 0, .z = 0 }};
    const base = [_]u32{0};
    const mat = [_]u32{0};
    const gbuf: v2.GBufferView = .{
        .width = w,
        .height = h,
        .depth = &depth,
        .normal = &normal,
        .base_color = &base,
        .material = &mat,
    };
    const inputs: v2.Inputs = .{
        .width = w,
        .height = h,
        .in_color = &src,
        .out_color = &dst,
        .gbuf = gbuf,
    };
    const r = execute(inputs, .{});
    try std.testing.expectEqual(@as(usize, 1), r.pixels_modified);
    // At full fog factor, output ≈ fog colour (92, 118, 142).
    try std.testing.expectEqual(@as(u32, 92), (dst[0] >> 16) & 0xFF);
    try std.testing.expectEqual(@as(u32, 118), (dst[0] >> 8) & 0xFF);
    try std.testing.expectEqual(@as(u32, 142), dst[0] & 0xFF);
}
