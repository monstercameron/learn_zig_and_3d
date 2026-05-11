const std = @import("std");
const scanline = @import("../core/scanline.zig");
const primitives = @import("primitives.zig");

const Triangle2i = primitives.Triangle2i;
const FrameTarget = primitives.FrameTarget;
const targetBounds = primitives.targetBounds;
const edgeFunction = primitives.edgeFunction;
const edgeStepX = primitives.edgeStepX;
const edgeStepY = primitives.edgeStepY;
pub const PreparedGouraudTriangle = struct {
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
    step_w0_x: i32,
    step_w1_x: i32,
    step_w2_x: i32,
    step_w0_y: i32,
    step_w1_y: i32,
    step_w2_y: i32,
    base_w0: i32,
    base_w1: i32,
    base_w2: i32,
    alpha: u32,
    is_degenerate: bool,
    channel_steps: GouraudChannelSteps,
    row_rgb: @Vector(4, i64),
};

pub const PreparedDepthPlane = struct {
    step_x: f32,
    step_y: f32,
    base_depth: f32,
};

pub inline fn prepareDepthPlane(triangle: Triangle2i, vertex_depths: [3]f32) ?PreparedDepthPlane {
    const dx1 = @as(f32, @floatFromInt(triangle.b.x - triangle.a.x));
    const dy1 = @as(f32, @floatFromInt(triangle.b.y - triangle.a.y));
    const dx2 = @as(f32, @floatFromInt(triangle.c.x - triangle.a.x));
    const dy2 = @as(f32, @floatFromInt(triangle.c.y - triangle.a.y));
    const det = dx1 * dy2 - dy1 * dx2;
    if (@abs(det) <= 1e-6) return null;
    const dz1 = vertex_depths[1] - vertex_depths[0];
    const dz2 = vertex_depths[2] - vertex_depths[0];
    return .{
        .step_x = (dz1 * dy2 - dy1 * dz2) / det,
        .step_y = (dx1 * dz2 - dz1 * dx2) / det,
        .base_depth = vertex_depths[0],
    };
}

pub inline fn prepareGouraudTriangle(triangle: Triangle2i, vertex_colors: [3]u32) PreparedGouraudTriangle {
    const colors = unpackGouraudColors(vertex_colors);
    const area = edgeFunction(triangle.a, triangle.b, triangle.c.x, triangle.c.y);
    const min_x = scanline.minI32(triangle.a.x, scanline.minI32(triangle.b.x, triangle.c.x));
    const max_x = scanline.maxI32(triangle.a.x, scanline.maxI32(triangle.b.x, triangle.c.x));
    const min_y = scanline.minI32(triangle.a.y, scanline.minI32(triangle.b.y, triangle.c.y));
    const max_y = scanline.maxI32(triangle.a.y, scanline.maxI32(triangle.b.y, triangle.c.y));
    const raw_step_w0_x: i32 = @intCast(edgeStepX(triangle.b, triangle.c));
    const raw_step_w1_x: i32 = @intCast(edgeStepX(triangle.c, triangle.a));
    const raw_step_w2_x: i32 = @intCast(edgeStepX(triangle.a, triangle.b));
    const raw_step_w0_y: i32 = @intCast(edgeStepY(triangle.b, triangle.c));
    const raw_step_w1_y: i32 = @intCast(edgeStepY(triangle.c, triangle.a));
    const raw_step_w2_y: i32 = @intCast(edgeStepY(triangle.a, triangle.b));
    const raw_base_w0: i32 = @intCast(edgeFunction(triangle.b, triangle.c, triangle.a.x, triangle.a.y));
    const raw_base_w1: i32 = @intCast(edgeFunction(triangle.c, triangle.a, triangle.a.x, triangle.a.y));
    const raw_base_w2: i32 = @intCast(edgeFunction(triangle.a, triangle.b, triangle.a.x, triangle.a.y));
    const is_degenerate = area == 0;
    const area_abs: i64 = if (area < 0) -area else area;
    const sign: i32 = if (area < 0) -1 else 1;
    const step_w0_x = raw_step_w0_x * sign;
    const step_w1_x = raw_step_w1_x * sign;
    const step_w2_x = raw_step_w2_x * sign;
    const step_w0_y = raw_step_w0_y * sign;
    const step_w1_y = raw_step_w1_y * sign;
    const step_w2_y = raw_step_w2_y * sign;
    const base_w0 = raw_base_w0 * sign;
    const base_w1 = raw_base_w1 * sign;
    const base_w2 = raw_base_w2 * sign;
    const numer_steps = colorChannelSteps(colors, triangle);
    const numer_row = gouraudRowColor(colors, base_w0, base_w1, base_w2);
    return .{
        .min_x = min_x,
        .max_x = max_x,
        .min_y = min_y,
        .max_y = max_y,
        .step_w0_x = step_w0_x,
        .step_w1_x = step_w1_x,
        .step_w2_x = step_w2_x,
        .step_w0_y = step_w0_y,
        .step_w1_y = step_w1_y,
        .step_w2_y = step_w2_y,
        .base_w0 = base_w0,
        .base_w1 = base_w1,
        .base_w2 = base_w2,
        .alpha = colors.alpha,
        .is_degenerate = is_degenerate,
        .channel_steps = if (is_degenerate)
            .{ .x = @splat(0), .y = @splat(0) }
        else
            .{
                .x = normalizeGouraudVectorQ16(numer_steps.x * @as(@Vector(4, i64), @splat(sign)), area_abs),
                .y = normalizeGouraudVectorQ16(numer_steps.y * @as(@Vector(4, i64), @splat(sign)), area_abs),
            },
        .row_rgb = if (is_degenerate)
            @splat(0)
        else
            normalizeGouraudVectorQ16(numer_row, area_abs),
    };
}

pub fn drawGouraudTriangle(target: FrameTarget, triangle: Triangle2i, vertex_colors: [3]u32, depth_value: ?f32) void {
    drawGouraudTriangleWithDepths(target, triangle, vertex_colors, depth_value, null);
}

pub fn drawPreparedGouraudTrianglePrepared(target: FrameTarget, triangle: Triangle2i, prepared: PreparedGouraudTriangle, depth_value: ?f32) void {
    drawPreparedGouraudTrianglePreparedWithDepths(target, triangle, prepared, depth_value, null);
}

pub fn drawGouraudTriangleWithDepths(
    target: FrameTarget,
    triangle: Triangle2i,
    vertex_colors: [3]u32,
    depth_value: ?f32,
    vertex_depths: ?[3]f32,
) void {
    if (vertex_colors[0] == vertex_colors[1] and vertex_colors[1] == vertex_colors[2]) {
        primitives.drawSolidTriangleWithDepths(target, triangle, vertex_colors[0], depth_value, vertex_depths, null);
        return;
    }
    drawPreparedGouraudTrianglePreparedWithDepths(target, triangle, prepareGouraudTriangle(triangle, vertex_colors), depth_value, vertex_depths);
}

pub fn drawPreparedGouraudTrianglePreparedWithDepths(
    target: FrameTarget,
    triangle: Triangle2i,
    prepared: PreparedGouraudTriangle,
    depth_value: ?f32,
    vertex_depths: ?[3]f32,
) void {
    if (target.width <= 0 or target.height <= 0) return;
    if (prepared.is_degenerate) return;
    const bounds = targetBounds(target);
    const min_x = scanline.clampI32(prepared.min_x, bounds.min_x, bounds.max_x);
    const max_x = scanline.clampI32(prepared.max_x, bounds.min_x, bounds.max_x);
    const min_y = scanline.clampI32(prepared.min_y, bounds.min_y, bounds.max_y);
    const max_y = scanline.clampI32(prepared.max_y, bounds.min_y, bounds.max_y);
    if (min_x > max_x or min_y > max_y) return;
    const offset_x: i32 = min_x - triangle.a.x;
    const offset_y: i32 = min_y - triangle.a.y;
    const row_w0: i32 = prepared.base_w0 + offset_x * prepared.step_w0_x + offset_y * prepared.step_w0_y;
    const row_w1: i32 = prepared.base_w1 + offset_x * prepared.step_w1_x + offset_y * prepared.step_w1_y;
    const row_w2: i32 = prepared.base_w2 + offset_x * prepared.step_w2_x + offset_y * prepared.step_w2_y;
    const row_rgb = prepared.row_rgb +
        @as(@Vector(4, i64), @splat(offset_x)) * prepared.channel_steps.x +
        @as(@Vector(4, i64), @splat(offset_y)) * prepared.channel_steps.y;
    const depth_plane = if (vertex_depths) |depths| prepareDepthPlane(triangle, depths) else null;
    const row_depth = if (depth_plane) |plane|
        plane.base_depth + @as(f32, @floatFromInt(offset_x)) * plane.step_x + @as(f32, @floatFromInt(offset_y)) * plane.step_y
    else
        0.0;
    drawPreparedGouraudTriangleInner(target, prepared, depth_value, depth_plane, min_x, max_x, min_y, max_y, row_w0, row_w1, row_w2, row_rgb, row_depth);
}

pub fn drawPreparedGouraudTriangleBlock(
    target: FrameTarget,
    triangles: []const Triangle2i,
    prepared_setups: []const PreparedGouraudTriangle,
    depth_values: []const ?f32,
    vertex_depths: []const ?[3]f32,
) void {
    std.debug.assert(triangles.len == prepared_setups.len);
    std.debug.assert(triangles.len == depth_values.len);
    std.debug.assert(triangles.len == vertex_depths.len);
    for (triangles, prepared_setups, depth_values, vertex_depths) |triangle, prepared, depth_value, tri_depths| {
        drawPreparedGouraudTriangleBlockPrepared(target, triangle, prepared, depth_value, tri_depths);
    }
}

fn drawPreparedGouraudTriangleBlockPrepared(target: FrameTarget, triangle: Triangle2i, prepared: PreparedGouraudTriangle, depth_value: ?f32, vertex_depths: ?[3]f32) void {
    if (target.width <= 0 or target.height <= 0) return;
    if (prepared.is_degenerate) return;
    const bounds = targetBounds(target);
    const min_x = scanline.clampI32(prepared.min_x, bounds.min_x, bounds.max_x);
    const max_x = scanline.clampI32(prepared.max_x, bounds.min_x, bounds.max_x);
    const min_y = scanline.clampI32(prepared.min_y, bounds.min_y, bounds.max_y);
    const max_y = scanline.clampI32(prepared.max_y, bounds.min_y, bounds.max_y);
    if (min_x > max_x or min_y > max_y) return;
    const offset_x: i32 = min_x - triangle.a.x;
    const offset_y: i32 = min_y - triangle.a.y;
    const row_w0: i32 = prepared.base_w0 + offset_x * prepared.step_w0_x + offset_y * prepared.step_w0_y;
    const row_w1: i32 = prepared.base_w1 + offset_x * prepared.step_w1_x + offset_y * prepared.step_w1_y;
    const row_w2: i32 = prepared.base_w2 + offset_x * prepared.step_w2_x + offset_y * prepared.step_w2_y;
    const row_rgb = prepared.row_rgb +
        @as(@Vector(4, i64), @splat(offset_x)) * prepared.channel_steps.x +
        @as(@Vector(4, i64), @splat(offset_y)) * prepared.channel_steps.y;
    const depth_plane = if (vertex_depths) |depths| prepareDepthPlane(triangle, depths) else null;
    const row_depth = if (depth_plane) |plane|
        plane.base_depth + @as(f32, @floatFromInt(offset_x)) * plane.step_x + @as(f32, @floatFromInt(offset_y)) * plane.step_y
    else
        0.0;
    drawPreparedGouraudTriangleBlockInner(target, prepared, depth_value, depth_plane, min_x, max_x, min_y, max_y, row_w0, row_w1, row_w2, row_rgb, row_depth);
}

fn drawPreparedGouraudTriangleBlockInner(
    target: FrameTarget,
    prepared: PreparedGouraudTriangle,
    depth_value: ?f32,
    depth_plane: ?PreparedDepthPlane,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
    row_w0_init: i32,
    row_w1_init: i32,
    row_w2_init: i32,
    row_rgb_init: @Vector(4, i64),
    row_depth_init: f32,
) void {
    const stride: usize = @intCast(target.width);
    const alpha = prepared.alpha;
    const depth = depth_value orelse 0.0;
    const step_w0_x = prepared.step_w0_x;
    const step_w1_x = prepared.step_w1_x;
    const step_w2_x = prepared.step_w2_x;
    const step_w0_y = prepared.step_w0_y;
    const step_w1_y = prepared.step_w1_y;
    const step_w2_y = prepared.step_w2_y;
    const step_rgb = prepared.channel_steps.x;
    const step_rgb8 = step_rgb * @as(@Vector(4, i64), @splat(8));
    const burst_offsets: @Vector(8, i32) = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var y = min_y;
    var row_w0 = row_w0_init;
    var row_w1 = row_w1_init;
    var row_w2 = row_w2_init;
    var row_rgb = row_rgb_init;

    if (depth_value == null) {
        while (y <= max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride;
            const row_color = target.color[row_start .. row_start + stride];
            var w0 = row_w0;
            var w1 = row_w1;
            var w2 = row_w2;
            var accum_rgb = row_rgb;
            var x = min_x;
            var idx: usize = @intCast(x);

            while (x <= max_x and (w0 < 0 or w1 < 0 or w2 < 0)) : (x += 1) {
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
                accum_rgb += step_rgb;
                idx += 1;
            }
            while (x + 7 <= max_x and allBurstPixelsCovered(w0, step_w0_x, w1, step_w1_x, w2, step_w2_x, burst_offsets)) : (x += 8)
            {
                const rgb1 = accum_rgb + step_rgb;
                const rgb2 = rgb1 + step_rgb;
                const rgb3 = rgb2 + step_rgb;
                const rgb4 = rgb3 + step_rgb;
                const rgb5 = rgb4 + step_rgb;
                const rgb6 = rgb5 + step_rgb;
                const rgb7 = rgb6 + step_rgb;
                row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                row_color[idx + 1] = packInterpolatedColorQ16(alpha, rgb1);
                row_color[idx + 2] = packInterpolatedColorQ16(alpha, rgb2);
                row_color[idx + 3] = packInterpolatedColorQ16(alpha, rgb3);
                row_color[idx + 4] = packInterpolatedColorQ16(alpha, rgb4);
                row_color[idx + 5] = packInterpolatedColorQ16(alpha, rgb5);
                row_color[idx + 6] = packInterpolatedColorQ16(alpha, rgb6);
                row_color[idx + 7] = packInterpolatedColorQ16(alpha, rgb7);
                w0 += step_w0_x * 8;
                w1 += step_w1_x * 8;
                w2 += step_w2_x * 8;
                accum_rgb += step_rgb8;
                idx += 8;
            }
            while (x <= max_x and w0 >= 0 and w1 >= 0 and w2 >= 0) : (x += 1) {
                row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
                accum_rgb += step_rgb;
                idx += 1;
            }

            row_w0 += step_w0_y;
            row_w1 += step_w1_y;
            row_w2 += step_w2_y;
            row_rgb += prepared.channel_steps.y;
        }
        return;
    }

    const depth_buffer = target.depth.?;
    if (depth_plane) |plane| {
        while (y <= max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride;
            const row_color = target.color[row_start .. row_start + stride];
            const row_depth = depth_buffer[row_start .. row_start + stride];
            var w0 = row_w0;
            var w1 = row_w1;
            var w2 = row_w2;
            var accum_rgb = row_rgb;
            var current_depth = row_depth_init + @as(f32, @floatFromInt(y - min_y)) * plane.step_y;
            var x = min_x;
            var idx: usize = @intCast(x);

            while (x <= max_x and (w0 < 0 or w1 < 0 or w2 < 0)) : (x += 1) {
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
                accum_rgb += step_rgb;
                current_depth += plane.step_x;
                idx += 1;
            }
            while (x <= max_x and w0 >= 0 and w1 >= 0 and w2 >= 0) : (x += 1) {
                if (current_depth <= row_depth[idx]) {
                    row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                    row_depth[idx] = current_depth;
                }
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
                accum_rgb += step_rgb;
                current_depth += plane.step_x;
                idx += 1;
            }

            row_w0 += step_w0_y;
            row_w1 += step_w1_y;
            row_w2 += step_w2_y;
            row_rgb += prepared.channel_steps.y;
        }
        return;
    }
    while (y <= max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        const row_color = target.color[row_start .. row_start + stride];
        const row_depth = depth_buffer[row_start .. row_start + stride];
        var w0 = row_w0;
        var w1 = row_w1;
        var w2 = row_w2;
        var accum_rgb = row_rgb;
        var x = min_x;
        var idx: usize = @intCast(x);

        while (x <= max_x and (w0 < 0 or w1 < 0 or w2 < 0)) : (x += 1) {
            w0 += step_w0_x;
            w1 += step_w1_x;
            w2 += step_w2_x;
            accum_rgb += step_rgb;
            idx += 1;
        }
        while (x + 7 <= max_x and allBurstPixelsCovered(w0, step_w0_x, w1, step_w1_x, w2, step_w2_x, burst_offsets)) : (x += 8)
        {
            const rgb1 = accum_rgb + step_rgb;
            const rgb2 = rgb1 + step_rgb;
            const rgb3 = rgb2 + step_rgb;
            const rgb4 = rgb3 + step_rgb;
            const rgb5 = rgb4 + step_rgb;
            const rgb6 = rgb5 + step_rgb;
            const rgb7 = rgb6 + step_rgb;
            if (depth <= row_depth[idx]) {
                row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                row_depth[idx] = depth;
            }
            if (depth <= row_depth[idx + 1]) {
                row_color[idx + 1] = packInterpolatedColorQ16(alpha, rgb1);
                row_depth[idx + 1] = depth;
            }
            if (depth <= row_depth[idx + 2]) {
                row_color[idx + 2] = packInterpolatedColorQ16(alpha, rgb2);
                row_depth[idx + 2] = depth;
            }
            if (depth <= row_depth[idx + 3]) {
                row_color[idx + 3] = packInterpolatedColorQ16(alpha, rgb3);
                row_depth[idx + 3] = depth;
            }
            if (depth <= row_depth[idx + 4]) {
                row_color[idx + 4] = packInterpolatedColorQ16(alpha, rgb4);
                row_depth[idx + 4] = depth;
            }
            if (depth <= row_depth[idx + 5]) {
                row_color[idx + 5] = packInterpolatedColorQ16(alpha, rgb5);
                row_depth[idx + 5] = depth;
            }
            if (depth <= row_depth[idx + 6]) {
                row_color[idx + 6] = packInterpolatedColorQ16(alpha, rgb6);
                row_depth[idx + 6] = depth;
            }
            if (depth <= row_depth[idx + 7]) {
                row_color[idx + 7] = packInterpolatedColorQ16(alpha, rgb7);
                row_depth[idx + 7] = depth;
            }
            w0 += step_w0_x * 8;
            w1 += step_w1_x * 8;
            w2 += step_w2_x * 8;
            accum_rgb += step_rgb8;
            idx += 8;
        }
        while (x <= max_x and w0 >= 0 and w1 >= 0 and w2 >= 0) : (x += 1) {
            if (depth <= row_depth[idx]) {
                row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                row_depth[idx] = depth;
            }
            w0 += step_w0_x;
            w1 += step_w1_x;
            w2 += step_w2_x;
            accum_rgb += step_rgb;
            idx += 1;
        }

        row_w0 += step_w0_y;
        row_w1 += step_w1_y;
        row_w2 += step_w2_y;
        row_rgb += prepared.channel_steps.y;
    }
}

inline fn allBurstPixelsCovered(
    w0: i32,
    step_w0_x: i32,
    w1: i32,
    step_w1_x: i32,
    w2: i32,
    step_w2_x: i32,
    offsets: @Vector(8, i32),
) bool {
    const base_w0: @Vector(8, i32) = @splat(w0);
    const base_w1: @Vector(8, i32) = @splat(w1);
    const base_w2: @Vector(8, i32) = @splat(w2);
    const step0: @Vector(8, i32) = @splat(step_w0_x);
    const step1: @Vector(8, i32) = @splat(step_w1_x);
    const step2: @Vector(8, i32) = @splat(step_w2_x);
    const zero: @Vector(8, i32) = @splat(0);
    const mask0 = base_w0 + step0 * offsets >= zero;
    const mask1 = base_w1 + step1 * offsets >= zero;
    const mask2 = base_w2 + step2 * offsets >= zero;
    const mask = mask0 & mask1 & mask2;
    return @reduce(.And, mask);
}

fn drawPreparedGouraudTriangleInner(
    target: FrameTarget,
    prepared: PreparedGouraudTriangle,
    depth_value: ?f32,
    depth_plane: ?PreparedDepthPlane,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
    row_w0_init: i32,
    row_w1_init: i32,
    row_w2_init: i32,
    row_rgb_init: @Vector(4, i64),
    row_depth_init: f32,
) void {
    const stride: usize = @intCast(target.width);
    const alpha = prepared.alpha;
    const depth = depth_value orelse 0.0;
    const step_w0_x = prepared.step_w0_x;
    const step_w1_x = prepared.step_w1_x;
    const step_w2_x = prepared.step_w2_x;
    const step_w0_y = prepared.step_w0_y;
    const step_w1_y = prepared.step_w1_y;
    const step_w2_y = prepared.step_w2_y;
    const step_w0_x2: i32 = step_w0_x + step_w0_x;
    const step_w1_x2: i32 = step_w1_x + step_w1_x;
    const step_w2_x2: i32 = step_w2_x + step_w2_x;
    const step_rgb_x2 = prepared.channel_steps.x + prepared.channel_steps.x;
    var y = min_y;
    var row_w0 = row_w0_init;
    var row_w1 = row_w1_init;
    var row_w2 = row_w2_init;
    var row_rgb = row_rgb_init;
    if (depth_value == null) {
        while (y <= max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride;
            const row_color = target.color[row_start .. row_start + stride];
            var w0 = row_w0;
            var w1 = row_w1;
            var w2 = row_w2;
            var accum_rgb = row_rgb;
            var x = min_x;
            var idx: usize = @intCast(x);
            while (x + 1 <= max_x) : (x += 2) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                }
                const next_w0 = w0 + step_w0_x;
                const next_w1 = w1 + step_w1_x;
                const next_w2 = w2 + step_w2_x;
                const next_rgb = accum_rgb + prepared.channel_steps.x;
                if (next_w0 >= 0 and next_w1 >= 0 and next_w2 >= 0) {
                    row_color[idx + 1] = packInterpolatedColorQ16(alpha, next_rgb);
                }
                w0 += step_w0_x2;
                w1 += step_w1_x2;
                w2 += step_w2_x2;
                accum_rgb += step_rgb_x2;
                idx += 2;
            }
            while (x <= max_x) : (x += 1) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                }
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
                accum_rgb += prepared.channel_steps.x;
                idx += 1;
            }
            row_w0 += step_w0_y;
            row_w1 += step_w1_y;
            row_w2 += step_w2_y;
            row_rgb += prepared.channel_steps.y;
        }
        return;
    }

    const depth_buffer = target.depth.?;
    if (depth_plane) |plane| {
        var depth_row = row_depth_init;
        while (y <= max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride;
            const row_color = target.color[row_start .. row_start + stride];
            const row_depth = depth_buffer[row_start .. row_start + stride];
            var w0 = row_w0;
            var w1 = row_w1;
            var w2 = row_w2;
            var accum_rgb = row_rgb;
            var current_depth = depth_row;
            var x = min_x;
            var idx: usize = @intCast(x);
            while (x + 1 <= max_x) : (x += 2) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    if (current_depth <= row_depth[idx]) {
                        row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                        row_depth[idx] = current_depth;
                    }
                }
                const next_w0 = w0 + step_w0_x;
                const next_w1 = w1 + step_w1_x;
                const next_w2 = w2 + step_w2_x;
                const next_rgb = accum_rgb + prepared.channel_steps.x;
                const next_depth = current_depth + plane.step_x;
                if (next_w0 >= 0 and next_w1 >= 0 and next_w2 >= 0) {
                    if (next_depth <= row_depth[idx + 1]) {
                        row_color[idx + 1] = packInterpolatedColorQ16(alpha, next_rgb);
                        row_depth[idx + 1] = next_depth;
                    }
                }
                w0 += step_w0_x2;
                w1 += step_w1_x2;
                w2 += step_w2_x2;
                accum_rgb += step_rgb_x2;
                current_depth += plane.step_x + plane.step_x;
                idx += 2;
            }
            while (x <= max_x) : (x += 1) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    if (current_depth <= row_depth[idx]) {
                        row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                        row_depth[idx] = current_depth;
                    }
                }
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
                accum_rgb += prepared.channel_steps.x;
                current_depth += plane.step_x;
                idx += 1;
            }
            row_w0 += step_w0_y;
            row_w1 += step_w1_y;
            row_w2 += step_w2_y;
            row_rgb += prepared.channel_steps.y;
            depth_row += plane.step_y;
        }
        return;
    }
    while (y <= max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        const row_color = target.color[row_start .. row_start + stride];
        const row_depth = depth_buffer[row_start .. row_start + stride];
        var w0 = row_w0;
        var w1 = row_w1;
        var w2 = row_w2;
        var accum_rgb = row_rgb;
        var x = min_x;
        var idx: usize = @intCast(x);
        while (x + 1 <= max_x) : (x += 2) {
            if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                if (depth <= row_depth[idx]) {
                    row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                    row_depth[idx] = depth;
                }
            }
            const next_w0 = w0 + step_w0_x;
            const next_w1 = w1 + step_w1_x;
            const next_w2 = w2 + step_w2_x;
            const next_rgb = accum_rgb + prepared.channel_steps.x;
            if (next_w0 >= 0 and next_w1 >= 0 and next_w2 >= 0) {
                if (depth <= row_depth[idx + 1]) {
                    row_color[idx + 1] = packInterpolatedColorQ16(alpha, next_rgb);
                    row_depth[idx + 1] = depth;
                }
            }
            w0 += step_w0_x2;
            w1 += step_w1_x2;
            w2 += step_w2_x2;
            accum_rgb += step_rgb_x2;
            idx += 2;
        }
        while (x <= max_x) : (x += 1) {
            if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                if (depth <= row_depth[idx]) {
                    row_color[idx] = packInterpolatedColorQ16(alpha, accum_rgb);
                    row_depth[idx] = depth;
                }
            }
            w0 += step_w0_x;
            w1 += step_w1_x;
            w2 += step_w2_x;
            accum_rgb += prepared.channel_steps.x;
            idx += 1;
        }
        row_w0 += step_w0_y;
        row_w1 += step_w1_y;
        row_w2 += step_w2_y;
        row_rgb += prepared.channel_steps.y;
    }
}

const GouraudColorComponents = struct {
    alpha: u32,
    rgb0: @Vector(4, i64),
    rgb1: @Vector(4, i64),
    rgb2: @Vector(4, i64),
};

const GouraudChannelSteps = struct {
    x: @Vector(4, i64),
    y: @Vector(4, i64),
};

inline fn unpackGouraudColors(colors: [3]u32) GouraudColorComponents {
    return .{
        .alpha = (colors[0] >> 24) & 0xFF,
        .rgb0 = .{ @as(i64, @intCast((colors[0] >> 16) & 0xFF)), @as(i64, @intCast((colors[0] >> 8) & 0xFF)), @as(i64, @intCast(colors[0] & 0xFF)), 0 },
        .rgb1 = .{ @as(i64, @intCast((colors[1] >> 16) & 0xFF)), @as(i64, @intCast((colors[1] >> 8) & 0xFF)), @as(i64, @intCast(colors[1] & 0xFF)), 0 },
        .rgb2 = .{ @as(i64, @intCast((colors[2] >> 16) & 0xFF)), @as(i64, @intCast((colors[2] >> 8) & 0xFF)), @as(i64, @intCast(colors[2] & 0xFF)), 0 },
    };
}

inline fn colorChannelSteps(colors: GouraudColorComponents, triangle: Triangle2i) GouraudChannelSteps {
    const w0_x: i32 = @intCast(edgeStepX(triangle.b, triangle.c));
    const w1_x: i32 = @intCast(edgeStepX(triangle.c, triangle.a));
    const w2_x: i32 = @intCast(edgeStepX(triangle.a, triangle.b));
    const w0_y: i32 = @intCast(edgeStepY(triangle.b, triangle.c));
    const w1_y: i32 = @intCast(edgeStepY(triangle.c, triangle.a));
    const w2_y: i32 = @intCast(edgeStepY(triangle.a, triangle.b));
    return .{
        .x = colors.rgb0 * @as(@Vector(4, i64), @splat(w0_x)) + colors.rgb1 * @as(@Vector(4, i64), @splat(w1_x)) + colors.rgb2 * @as(@Vector(4, i64), @splat(w2_x)),
        .y = colors.rgb0 * @as(@Vector(4, i64), @splat(w0_y)) + colors.rgb1 * @as(@Vector(4, i64), @splat(w1_y)) + colors.rgb2 * @as(@Vector(4, i64), @splat(w2_y)),
    };
}

inline fn gouraudRowColor(colors: GouraudColorComponents, w0: i64, w1: i64, w2: i64) @Vector(4, i64) {
    return colors.rgb0 * @as(@Vector(4, i64), @splat(w0)) + colors.rgb1 * @as(@Vector(4, i64), @splat(w1)) + colors.rgb2 * @as(@Vector(4, i64), @splat(w2));
}

inline fn packInterpolatedColorQ16(alpha: u32, rgb_q16: @Vector(4, i64)) u32 {
    const rgb = normalizedChannelsQ16(rgb_q16);
    return (alpha << 24) | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2];
}

inline fn normalizeGouraudVectorQ16(value_num: @Vector(4, i64), area_abs: i64) @Vector(4, i64) {
    return .{
        divideQ16(value_num[0], area_abs),
        divideQ16(value_num[1], area_abs),
        divideQ16(value_num[2], area_abs),
        divideQ16(value_num[3], area_abs),
    };
}

inline fn divideQ16(value_num: i64, area_abs: i64) i64 {
    const wide_num = value_num << 16;
    const bias = @divTrunc(area_abs, 2);
    return @divTrunc(if (wide_num >= 0) wide_num + bias else wide_num - bias, area_abs);
}

inline fn normalizedChannelsQ16(value_q16: @Vector(4, i64)) @Vector(4, u32) {
    const scaled = value_q16 >> @as(@Vector(4, i64), @splat(16));
    const zero: @Vector(4, i64) = @splat(0);
    const max_channel: @Vector(4, i64) = @splat(255);
    return @intCast(@min(@max(scaled, zero), max_channel));
}
