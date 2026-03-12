//! Row-kernel implementations for SSAO generation, bilateral blur, and final composite.
//! Picks runtime SIMD lanes and keeps loops contiguous for CPU cache efficiency.
//! Called by SSAO orchestration stages to process exact row ranges.

const std = @import("std");
const math = @import("../../core/math.zig");
const cpu_features = @import("../../core/cpu_features.zig");
const render_utils = @import("../core/utils.zig");
const taa_helpers = @import("taa_helpers.zig");

const ao_sample_offsets = [_][2]i32{
    .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 },
    .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
};

/// Returns the SIMD lane count selected for the current runtime target.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
fn runtimeLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

/// renderRows renders SSAO Rows output.
pub fn renderRows(scene_camera: []const math.Vec3, scene_width: usize, scene_height: usize, ao: anytype, config_value: anytype, start_row: usize, end_row: usize) void {
    const radius_sq = config_value.radius * config_value.radius;
    const sample_step = @as(i32, @intCast(@max(1, config_value.downsample)));
    const half_step = @divTrunc(sample_step, 2);
    const downsample = config_value.downsample;

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const scene_y = @min(scene_height - 1, y * downsample + @as(usize, @intCast(half_step)));
        const scene_row = scene_y * scene_width;
        const dst_row = y * ao.width;
        var x: usize = 0;
        while (x < ao.width) : (x += 1) {
            const scene_x = @min(scene_width - 1, x * downsample + @as(usize, @intCast(half_step)));
            const dst_idx = dst_row + x;
            const center = scene_camera[scene_row + scene_x];
            if (!render_utils.validSceneCameraSample(center, 0.01)) {
                ao.ping[dst_idx] = 255;
                ao.depth[dst_idx] = std.math.inf(f32);
                continue;
            }

            ao.depth[dst_idx] = center.z;
            const normal = render_utils.estimateSceneNormal(scene_camera, scene_width, scene_height, center, @intCast(scene_x), @intCast(scene_y), sample_step, 0.01);
            var occlusion: f32 = 0.0;
            var sample_count: usize = 0;
            for (ao_sample_offsets) |offset| {
                const sample = render_utils.sampleSceneCameraClamped(
                    scene_camera,
                    scene_width,
                    scene_height,
                    @as(i32, @intCast(scene_x)) + offset[0] * sample_step,
                    @as(i32, @intCast(scene_y)) + offset[1] * sample_step,
                );
                if (!render_utils.validSceneCameraSample(sample, 0.01)) continue;
                const delta = math.Vec3.sub(sample, center);
                const distance_sq = math.Vec3.dot(delta, delta);
                if (distance_sq <= 1e-5 or distance_sq > radius_sq) continue;
                const distance = @sqrt(distance_sq);
                const ndot = math.Vec3.dot(normal, math.Vec3.scale(delta, 1.0 / distance)) - config_value.bias;
                if (ndot <= 0.0) continue;
                const range_weight = 1.0 - (distance_sq / radius_sq);
                occlusion += ndot * range_weight;
                sample_count += 1;
            }

            if (sample_count == 0) {
                ao.ping[dst_idx] = 255;
                continue;
            }
            const inv_sample_count = 1.0 / @as(f32, @floatFromInt(sample_count));
            const normalized = occlusion * inv_sample_count;
            const visibility = @max(0.0, 1.0 - @min(1.0, normalized * config_value.strength));
            ao.ping[dst_idx] = @intFromFloat(visibility * 255.0 + 0.5);
        }
    }
}

/// Processes blur horizontal rows.
/// Operates on the `[start_row, end_row)` stripe so worker jobs can run in parallel without overlap.
pub fn blurHorizontalRows(ao: anytype, depth_threshold: f32, start_row: usize, end_row: usize) void {
    const weights = [_]u32{ 1, 2, 3, 2, 1 };
    const lanes = runtimeLanes();
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * ao.width;
        var x: usize = 0;
        while (lanes > 1 and x + lanes <= ao.width) : (x += lanes) {
            switch (lanes) {
                8 => blurHorizontalBlock(8, ao, row_start, x, depth_threshold, weights),
                16 => blurHorizontalBlock(16, ao, row_start, x, depth_threshold, weights),
                32 => blurHorizontalBlock(32, ao, row_start, x, depth_threshold, weights),
                else => break,
            }
        }
        while (x < ao.width) : (x += 1) {
            const idx = row_start + x;
            const center_depth = ao.depth[idx];
            if (!std.math.isFinite(center_depth)) {
                ao.pong[idx] = 255;
                continue;
            }
            var sum: u32 = 0;
            var weight_sum: u32 = 0;
            for (weights, 0..) |w, tap| {
                const sample_x: usize = @intCast(@min(@as(i32, @intCast(ao.width - 1)), @max(0, @as(i32, @intCast(x)) + @as(i32, @intCast(tap)) - 2)));
                const sample_idx = row_start + sample_x;
                const sample_depth = ao.depth[sample_idx];
                if (!std.math.isFinite(sample_depth) or @abs(sample_depth - center_depth) > depth_threshold) continue;
                sum += @as(u32, ao.ping[sample_idx]) * w;
                weight_sum += w;
            }
            ao.pong[idx] = if (weight_sum == 0) ao.ping[idx] else @intCast(@divTrunc(sum + (weight_sum / 2), weight_sum));
        }
    }
}

/// Blurs vertical rows using the configured radius/weights for this pass.
/// Operates on the `[start_row, end_row)` stripe so worker jobs can run in parallel without overlap.
pub fn blurVerticalRows(ao: anytype, depth_threshold: f32, start_row: usize, end_row: usize) void {
    const weights = [_]u32{ 1, 2, 3, 2, 1 };
    const lanes = runtimeLanes();
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * ao.width;
        var x: usize = 0;
        while (lanes > 1 and x + lanes <= ao.width) : (x += lanes) {
            switch (lanes) {
                8 => blurVerticalBlock(8, ao, row_start, x, y, depth_threshold, weights),
                16 => blurVerticalBlock(16, ao, row_start, x, y, depth_threshold, weights),
                32 => blurVerticalBlock(32, ao, row_start, x, y, depth_threshold, weights),
                else => break,
            }
        }
        while (x < ao.width) : (x += 1) {
            const idx = row_start + x;
            const center_depth = ao.depth[idx];
            if (!std.math.isFinite(center_depth)) {
                ao.ping[idx] = 255;
                continue;
            }
            var sum: u32 = 0;
            var weight_sum: u32 = 0;
            for (weights, 0..) |w, tap| {
                const sample_y: usize = @intCast(@min(@as(i32, @intCast(ao.height - 1)), @max(0, @as(i32, @intCast(y)) + @as(i32, @intCast(tap)) - 2)));
                const sample_idx = sample_y * ao.width + x;
                const sample_depth = ao.depth[sample_idx];
                if (!std.math.isFinite(sample_depth) or @abs(sample_depth - center_depth) > depth_threshold) continue;
                sum += @as(u32, ao.pong[sample_idx]) * w;
                weight_sum += w;
            }
            ao.ping[idx] = if (weight_sum == 0) ao.pong[idx] else @intCast(@divTrunc(sum + (weight_sum / 2), weight_sum));
        }
    }
}

fn blurHorizontalBlock(
    comptime lanes: usize,
    ao: anytype,
    row_start: usize,
    x_start: usize,
    depth_threshold: f32,
    weights: [5]u32,
) void {
    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
        const x = x_start + lane;
        const idx = row_start + x;
        const center_depth = ao.depth[idx];
        if (!std.math.isFinite(center_depth)) {
            ao.pong[idx] = 255;
            continue;
        }
        var sum: u32 = 0;
        var weight_sum: u32 = 0;
        for (weights, 0..) |w, tap| {
            const sample_x: usize = @intCast(@min(@as(i32, @intCast(ao.width - 1)), @max(0, @as(i32, @intCast(x)) + @as(i32, @intCast(tap)) - 2)));
            const sample_idx = row_start + sample_x;
            const sample_depth = ao.depth[sample_idx];
            if (!std.math.isFinite(sample_depth) or @abs(sample_depth - center_depth) > depth_threshold) continue;
            sum += @as(u32, ao.ping[sample_idx]) * w;
            weight_sum += w;
        }
        ao.pong[idx] = if (weight_sum == 0) ao.ping[idx] else @intCast(@divTrunc(sum + (weight_sum / 2), weight_sum));
    }
}

fn blurVerticalBlock(
    comptime lanes: usize,
    ao: anytype,
    row_start: usize,
    x_start: usize,
    y: usize,
    depth_threshold: f32,
    weights: [5]u32,
) void {
    var lane: usize = 0;
    while (lane < lanes) : (lane += 1) {
        const x = x_start + lane;
        const idx = row_start + x;
        const center_depth = ao.depth[idx];
        if (!std.math.isFinite(center_depth)) {
            ao.ping[idx] = 255;
            continue;
        }
        var sum: u32 = 0;
        var weight_sum: u32 = 0;
        for (weights, 0..) |w, tap| {
            const sample_y: usize = @intCast(@min(@as(i32, @intCast(ao.height - 1)), @max(0, @as(i32, @intCast(y)) + @as(i32, @intCast(tap)) - 2)));
            const sample_idx = sample_y * ao.width + x;
            const sample_depth = ao.depth[sample_idx];
            if (!std.math.isFinite(sample_depth) or @abs(sample_depth - center_depth) > depth_threshold) continue;
            sum += @as(u32, ao.pong[sample_idx]) * w;
            weight_sum += w;
        }
        ao.ping[idx] = if (weight_sum == 0) ao.pong[idx] else @intCast(@divTrunc(sum + (weight_sum / 2), weight_sum));
    }
}

/// sampleVisibility samples values used by SSAO Rows.
fn sampleVisibility(ao: anytype, scene_width: usize, scene_height: usize, x: usize, y: usize) f32 {
    const u = ((@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(ao.width))) / @as(f32, @floatFromInt(scene_width)) - 0.5;
    const v = ((@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(ao.height))) / @as(f32, @floatFromInt(scene_height)) - 0.5;
    const x0_i = @max(0, @as(i32, @intFromFloat(@floor(u))));
    const y0_i = @max(0, @as(i32, @intFromFloat(@floor(v))));
    const x1_i = @min(@as(i32, @intCast(ao.width - 1)), x0_i + 1);
    const y1_i = @min(@as(i32, @intCast(ao.height - 1)), y0_i + 1);
    const frac_x = @max(0.0, @min(1.0, u - @as(f32, @floatFromInt(x0_i))));
    const frac_y = @max(0.0, @min(1.0, v - @as(f32, @floatFromInt(y0_i))));
    const x0: usize = @intCast(x0_i);
    const y0: usize = @intCast(y0_i);
    const x1: usize = @intCast(x1_i);
    const y1: usize = @intCast(y1_i);
    const s00 = @as(f32, @floatFromInt(ao.ping[y0 * ao.width + x0])) / 255.0;
    const s10 = @as(f32, @floatFromInt(ao.ping[y0 * ao.width + x1])) / 255.0;
    const s01 = @as(f32, @floatFromInt(ao.ping[y1 * ao.width + x0])) / 255.0;
    const s11 = @as(f32, @floatFromInt(ao.ping[y1 * ao.width + x1])) / 255.0;
    return (s00 + (s10 - s00) * frac_x) + ((s01 + (s11 - s01) * frac_x) - (s00 + (s10 - s00) * frac_x)) * frac_y;
}

/// Composites c om po si te ro ws into the destination buffer.
/// Operates on the `[start_row, end_row)` stripe so worker jobs can run in parallel without overlap.
pub fn compositeRows(dst: []u32, scene_camera: []const math.Vec3, dst_width: usize, dst_height: usize, ao: anytype, start_row: usize, end_row: usize) void {
    const lanes = runtimeLanes();
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * dst_width;
        var x: usize = 0;
        while (x + lanes <= dst_width and lanes > 1) : (x += lanes) {
            switch (lanes) {
                8 => compositeBlock(8, dst, scene_camera, dst_width, dst_height, ao, row_start, x, y),
                16 => compositeBlock(16, dst, scene_camera, dst_width, dst_height, ao, row_start, x, y),
                32 => compositeBlock(32, dst, scene_camera, dst_width, dst_height, ao, row_start, x, y),
                else => break,
            }
        }
        while (x < dst_width) : (x += 1) {
            const idx = row_start + x;
            if (!render_utils.validSceneCameraSample(scene_camera[idx], 0.01)) continue;
            const visibility = sampleVisibility(ao, dst_width, dst_height, x, y);
            if (visibility >= 0.999) continue;
            const pixel = dst[idx];
            const alpha = pixel & 0xFF000000;
            const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * visibility + 0.5));
            const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * visibility + 0.5));
            const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * visibility + 0.5));
            dst[idx] = alpha | (@as(u32, render_utils.clampByte(r)) << 16) | (@as(u32, render_utils.clampByte(g)) << 8) | @as(u32, render_utils.clampByte(b));
        }
    }
    _ = taa_helpers; // keep module available for future SIMD blend path parity.
}

fn compositeBlock(
    comptime lanes: usize,
    dst: []u32,
    scene_camera: []const math.Vec3,
    dst_width: usize,
    dst_height: usize,
    ao: anytype,
    row_start: usize,
    x_start: usize,
    y: usize,
) void {
    var alpha: [lanes]u32 = undefined;
    var r_arr: [lanes]f32 = undefined;
    var g_arr: [lanes]f32 = undefined;
    var b_arr: [lanes]f32 = undefined;
    var vis_arr: [lanes]f32 = undefined;
    var valid: [lanes]bool = undefined;

    var lane_idx: usize = 0;
    while (lane_idx < lanes) : (lane_idx += 1) {
        const x = x_start + lane_idx;
        const idx = row_start + x;
        valid[lane_idx] = false;
        if (!render_utils.validSceneCameraSample(scene_camera[idx], 0.01)) continue;
        const visibility = sampleVisibility(ao, dst_width, dst_height, x, y);
        if (visibility >= 0.999) continue;
        const pixel = dst[idx];
        alpha[lane_idx] = pixel & 0xFF000000;
        r_arr[lane_idx] = @floatFromInt((pixel >> 16) & 0xFF);
        g_arr[lane_idx] = @floatFromInt((pixel >> 8) & 0xFF);
        b_arr[lane_idx] = @floatFromInt(pixel & 0xFF);
        vis_arr[lane_idx] = visibility;
        valid[lane_idx] = true;
    }

    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    const maxv: FloatVec = @splat(255.0);
    const minv: FloatVec = @splat(0.0);
    const r_scaled: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(r_arr)) * @as(FloatVec, @bitCast(vis_arr)))))));
    const g_scaled: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(g_arr)) * @as(FloatVec, @bitCast(vis_arr)))))));
    const b_scaled: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(@max(minv, @min(maxv, @as(FloatVec, @bitCast(b_arr)) * @as(FloatVec, @bitCast(vis_arr)))))));

    var write_lane: usize = 0;
    while (write_lane < lanes) : (write_lane += 1) {
        if (!valid[write_lane]) continue;
        const idx = row_start + x_start + write_lane;
        dst[idx] = alpha[write_lane] |
            (@as(u32, render_utils.clampByte(r_scaled[write_lane])) << 16) |
            (@as(u32, render_utils.clampByte(g_scaled[write_lane])) << 8) |
            @as(u32, render_utils.clampByte(b_scaled[write_lane]));
    }
}
