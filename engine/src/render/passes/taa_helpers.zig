const std = @import("std");
const math = @import("../../core/math.zig");
const TileRenderer = @import("../tile_renderer.zig");

pub const invalid_surface_tag: u64 = std.math.maxInt(u64);

pub const HistoryNearestSample = struct {
    color: [3]f32,
    depth: f32,
    tag: u64,
};

fn clampByte(value: i32) u8 {
    return @intCast(@max(0, @min(255, value)));
}

pub fn sampleHistoryColor(history: []const u32, width: usize, height: usize, screen: math.Vec2) ?[3]f32 {
    const w_f = @as(f32, @floatFromInt(width));
    const h_f = @as(f32, @floatFromInt(height));
    if (screen.x < 0.0 or screen.y < 0.0 or screen.x >= w_f or screen.y >= h_f) return null;

    const adj_x = screen.x - 0.5;
    const adj_y = screen.y - 0.5;
    const x0_i = @as(i32, @intFromFloat(@floor(adj_x)));
    const y0_i = @as(i32, @intFromFloat(@floor(adj_y)));
    const cx0 = @max(0, @min(@as(i32, @intCast(width - 1)), x0_i));
    const cy0 = @max(0, @min(@as(i32, @intCast(height - 1)), y0_i));
    const cx1 = @max(0, @min(@as(i32, @intCast(width - 1)), x0_i + 1));
    const cy1 = @max(0, @min(@as(i32, @intCast(height - 1)), y0_i + 1));
    const frac_x = std.math.clamp(adj_x - @as(f32, @floatFromInt(x0_i)), 0.0, 1.0);
    const frac_y = std.math.clamp(adj_y - @as(f32, @floatFromInt(y0_i)), 0.0, 1.0);
    const x0: usize = @intCast(cx0);
    const y0: usize = @intCast(cy0);
    const x1: usize = @intCast(cx1);
    const y1: usize = @intCast(cy1);

    const c00 = history[y0 * width + x0];
    const c10 = history[y0 * width + x1];
    const c01 = history[y1 * width + x0];
    const c11 = history[y1 * width + x1];

    const top_r = @as(f32, @floatFromInt((c00 >> 16) & 0xFF)) + (@as(f32, @floatFromInt((c10 >> 16) & 0xFF)) - @as(f32, @floatFromInt((c00 >> 16) & 0xFF))) * frac_x;
    const top_g = @as(f32, @floatFromInt((c00 >> 8) & 0xFF)) + (@as(f32, @floatFromInt((c10 >> 8) & 0xFF)) - @as(f32, @floatFromInt((c00 >> 8) & 0xFF))) * frac_x;
    const top_b = @as(f32, @floatFromInt(c00 & 0xFF)) + (@as(f32, @floatFromInt(c10 & 0xFF)) - @as(f32, @floatFromInt(c00 & 0xFF))) * frac_x;
    const bottom_r = @as(f32, @floatFromInt((c01 >> 16) & 0xFF)) + (@as(f32, @floatFromInt((c11 >> 16) & 0xFF)) - @as(f32, @floatFromInt((c01 >> 16) & 0xFF))) * frac_x;
    const bottom_g = @as(f32, @floatFromInt((c01 >> 8) & 0xFF)) + (@as(f32, @floatFromInt((c11 >> 8) & 0xFF)) - @as(f32, @floatFromInt((c01 >> 8) & 0xFF))) * frac_x;
    const bottom_b = @as(f32, @floatFromInt(c01 & 0xFF)) + (@as(f32, @floatFromInt(c11 & 0xFF)) - @as(f32, @floatFromInt(c01 & 0xFF))) * frac_x;

    return .{
        top_r + (bottom_r - top_r) * frac_y,
        top_g + (bottom_g - top_g) * frac_y,
        top_b + (bottom_b - top_b) * frac_y,
    };
}

pub fn sampleHistoryColorNearest(history: []const u32, width: usize, height: usize, screen: math.Vec2) ?[3]f32 {
    const x = @as(i32, @intFromFloat(@floor(screen.x)));
    const y = @as(i32, @intFromFloat(@floor(screen.y)));
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return null;
    const pixel = history[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
    return .{
        @floatFromInt((pixel >> 16) & 0xFF),
        @floatFromInt((pixel >> 8) & 0xFF),
        @floatFromInt(pixel & 0xFF),
    };
}

pub fn sampleHistoryNearest(history_pixels: []const u32, history_depth: []const f32, history_surface_tags: []const u64, width: usize, height: usize, screen: math.Vec2) ?HistoryNearestSample {
    const x = @as(i32, @intFromFloat(@floor(screen.x)));
    const y = @as(i32, @intFromFloat(@floor(screen.y)));
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return null;

    const idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    const depth = history_depth[idx];
    if (!std.math.isFinite(depth)) return null;

    const pixel = history_pixels[idx];
    const tag = history_surface_tags[idx];
    return .{
        .color = .{
            @floatFromInt((pixel >> 16) & 0xFF),
            @floatFromInt((pixel >> 8) & 0xFF),
            @floatFromInt(pixel & 0xFF),
        },
        .depth = depth,
        .tag = tag,
    };
}

pub fn packHistoryNormal(normal: math.Vec3) u32 {
    const nx = clampByte(@as(i32, @intFromFloat((std.math.clamp(normal.x, -1.0, 1.0) * 0.5 + 0.5) * 255.0 + 0.5)));
    const ny = clampByte(@as(i32, @intFromFloat((std.math.clamp(normal.y, -1.0, 1.0) * 0.5 + 0.5) * 255.0 + 0.5)));
    const nz = clampByte(@as(i32, @intFromFloat((std.math.clamp(normal.z, -1.0, 1.0) * 0.5 + 0.5) * 255.0 + 0.5)));
    return (@as(u32, nx) << 16) | (@as(u32, ny) << 8) | @as(u32, nz);
}

fn unpackHistoryNormal(packed_normal: u32) math.Vec3 {
    const nx = (@as(f32, @floatFromInt((packed_normal >> 16) & 0xFF)) / 255.0) * 2.0 - 1.0;
    const ny = (@as(f32, @floatFromInt((packed_normal >> 8) & 0xFF)) / 255.0) * 2.0 - 1.0;
    const nz = (@as(f32, @floatFromInt(packed_normal & 0xFF)) / 255.0) * 2.0 - 1.0;
    return math.Vec3.normalize(math.Vec3.new(nx, ny, nz));
}

pub fn sampleHistoryNormalNearest(history_normals: []const u32, width: usize, height: usize, screen: math.Vec2) ?math.Vec3 {
    const x = @as(i32, @intFromFloat(@floor(screen.x)));
    const y = @as(i32, @intFromFloat(@floor(screen.y)));
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return null;
    return unpackHistoryNormal(history_normals[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))]);
}

pub fn surfaceTagForHandle(handle: TileRenderer.SurfaceHandle) u64 {
    if (!handle.isValid()) return invalid_surface_tag;
    return (@as(u64, handle.meshlet_id) << 32) | @as(u64, handle.triangle_id);
}

pub fn surfaceTagMeshletId(tag: u64) u32 {
    return @intCast(tag >> 32);
}

pub fn clampHistoryToSurfaceNeighborhood(
    pixels: []const u32,
    surface_handles: []const TileRenderer.SurfaceHandle,
    normals: []const math.Vec3,
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    history_color: [3]f32,
) [3]f32 {
    const center_idx = y * width + x;
    const center_surface = surface_handles[center_idx];
    const center_normal = normals[center_idx];

    var min_rgb = [3]f32{ 255.0, 255.0, 255.0 };
    var max_rgb = [3]f32{ 0.0, 0.0, 0.0 };
    var matched_samples: usize = 0;

    const offsets = [_][2]i32{ .{ 0, 0 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    for (offsets) |offset| {
        const sample_x_i = @as(i32, @intCast(x)) + offset[0];
        const sample_y_i = @as(i32, @intCast(y)) + offset[1];
        if (sample_x_i < 0 or sample_y_i < 0 or sample_x_i >= @as(i32, @intCast(width)) or sample_y_i >= @as(i32, @intCast(height))) continue;

        const sample_idx = @as(usize, @intCast(sample_y_i)) * width + @as(usize, @intCast(sample_x_i));
        const sample_surface = surface_handles[sample_idx];
        const sample_normal = normals[sample_idx];
        const include_sample = if (center_surface.isValid() and sample_surface.isValid())
            center_surface.meshlet_id == sample_surface.meshlet_id
        else
            math.Vec3.dot(center_normal, sample_normal) >= 0.9;
        if (!include_sample) continue;

        const pixel = pixels[sample_idx];
        const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
        const g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
        const b = @as(f32, @floatFromInt(pixel & 0xFF));

        min_rgb[0] = @min(min_rgb[0], r);
        min_rgb[1] = @min(min_rgb[1], g);
        min_rgb[2] = @min(min_rgb[2], b);
        max_rgb[0] = @max(max_rgb[0], r);
        max_rgb[1] = @max(max_rgb[1], g);
        max_rgb[2] = @max(max_rgb[2], b);
        matched_samples += 1;
    }

    if (matched_samples == 0) return history_color;
    return .{
        std.math.clamp(history_color[0], min_rgb[0], max_rgb[0]),
        std.math.clamp(history_color[1], min_rgb[1], max_rgb[1]),
        std.math.clamp(history_color[2], min_rgb[2], max_rgb[2]),
    };
}

pub fn surfaceHistoryEdgeFactor(surface_handles: []const TileRenderer.SurfaceHandle, width: usize, height: usize, x: usize, y: usize) f32 {
    const center = surface_handles[y * width + x];
    if (!center.isValid()) return 0.6;

    var total_neighbors: u32 = 0;
    var stable_neighbors: u32 = 0;
    const offsets = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    for (offsets) |offset| {
        const sample_x = @as(i32, @intCast(x)) + offset[0];
        const sample_y = @as(i32, @intCast(y)) + offset[1];
        if (sample_x < 0 or sample_y < 0 or sample_x >= @as(i32, @intCast(width)) or sample_y >= @as(i32, @intCast(height))) continue;
        total_neighbors += 1;
        const neighbor = surface_handles[@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))];
        if (neighbor.isValid() and neighbor.meshlet_id == center.meshlet_id) stable_neighbors += 1;
    }
    if (total_neighbors == 0) return 1.0;
    if (stable_neighbors >= total_neighbors) return 1.0;
    if (stable_neighbors + 1 >= total_neighbors) return 0.9;
    if (stable_neighbors * 2 >= total_neighbors) return 0.75;
    return 0.5;
}

pub fn clampHistoryToNeighborhood(pixels: []const u32, width: usize, height: usize, x: usize, y: usize, history_color: [3]f32) [3]f32 {
    var mu = [3]f32{ 0.0, 0.0, 0.0 };
    var m2 = [3]f32{ 0.0, 0.0, 0.0 };
    var count: f32 = 0.0;
    var offset_y: i32 = -1;
    while (offset_y <= 1) : (offset_y += 1) {
        const sample_y = @min(@as(i32, @intCast(height - 1)), @max(0, @as(i32, @intCast(y)) + offset_y));
        var offset_x: i32 = -1;
        while (offset_x <= 1) : (offset_x += 1) {
            const sample_x = @min(@as(i32, @intCast(width - 1)), @max(0, @as(i32, @intCast(x)) + offset_x));
            const pixel = pixels[@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))];
            const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
            const g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
            const b = @as(f32, @floatFromInt(pixel & 0xFF));
            mu[0] += r; mu[1] += g; mu[2] += b;
            m2[0] += r * r; m2[1] += g * g; m2[2] += b * b;
            count += 1.0;
        }
    }

    mu[0] /= count; mu[1] /= count; mu[2] /= count;
    m2[0] /= count; m2[1] /= count; m2[2] /= count;

    var sigma = [3]f32{ 0.0, 0.0, 0.0 };
    inline for (0..3) |i| sigma[i] = @sqrt(@max(0.0, m2[i] - mu[i] * mu[i]));
    const gamma: f32 = 1.25;
    return .{
        std.math.clamp(history_color[0], @max(0.0, mu[0] - gamma * sigma[0]), @min(255.0, mu[0] + gamma * sigma[0])),
        std.math.clamp(history_color[1], @max(0.0, mu[1] - gamma * sigma[1]), @min(255.0, mu[1] + gamma * sigma[1])),
        std.math.clamp(history_color[2], @max(0.0, mu[2] - gamma * sigma[2]), @min(255.0, mu[2] + gamma * sigma[2])),
    };
}

pub fn blendTemporalColor(current_pixel: u32, history_color: [3]f32, history_weight: f32) u32 {
    const alpha = current_pixel & 0xFF000000;
    const current_weight = 1.0 - history_weight;
    const current_r = @as(f32, @floatFromInt((current_pixel >> 16) & 0xFF));
    const current_g = @as(f32, @floatFromInt((current_pixel >> 8) & 0xFF));
    const current_b = @as(f32, @floatFromInt(current_pixel & 0xFF));
    const out_r = @as(i32, @intFromFloat(current_r * current_weight + history_color[0] * history_weight + 0.5));
    const out_g = @as(i32, @intFromFloat(current_g * current_weight + history_color[1] * history_weight + 0.5));
    const out_b = @as(i32, @intFromFloat(current_b * current_weight + history_color[2] * history_weight + 0.5));
    return alpha | (@as(u32, clampByte(out_r)) << 16) | (@as(u32, clampByte(out_g)) << 8) | @as(u32, clampByte(out_b));
}

fn blendTemporalColorBatchSimd(comptime lanes: usize, current_pixels: *const [lanes]u32, history_colors: *const [lanes][3]f32, history_weights: *const [lanes]f32) [lanes]u32 {
    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);
    var alpha: [lanes]u32 = undefined;
    var current_r_arr: [lanes]f32 = undefined;
    var current_g_arr: [lanes]f32 = undefined;
    var current_b_arr: [lanes]f32 = undefined;
    var history_r_arr: [lanes]f32 = undefined;
    var history_g_arr: [lanes]f32 = undefined;
    var history_b_arr: [lanes]f32 = undefined;
    inline for (0..lanes) |lane| {
        const pixel = current_pixels[lane];
        alpha[lane] = pixel & 0xFF000000;
        current_r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
        current_g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
        current_b_arr[lane] = @floatFromInt(pixel & 0xFF);
        history_r_arr[lane] = history_colors[lane][0];
        history_g_arr[lane] = history_colors[lane][1];
        history_b_arr[lane] = history_colors[lane][2];
    }

    const history_weight_vec: FloatVec = @bitCast(history_weights.*);
    const current_weight_vec: FloatVec = @as(FloatVec, @splat(1.0)) - history_weight_vec;
    const half_vec: FloatVec = @as(FloatVec, @splat(0.5));
    const out_r_vec = (@as(FloatVec, @bitCast(current_r_arr)) * current_weight_vec) + (@as(FloatVec, @bitCast(history_r_arr)) * history_weight_vec) + half_vec;
    const out_g_vec = (@as(FloatVec, @bitCast(current_g_arr)) * current_weight_vec) + (@as(FloatVec, @bitCast(history_g_arr)) * history_weight_vec) + half_vec;
    const out_b_vec = (@as(FloatVec, @bitCast(current_b_arr)) * current_weight_vec) + (@as(FloatVec, @bitCast(history_b_arr)) * history_weight_vec) + half_vec;
    const out_r: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(out_r_vec)));
    const out_g: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(out_g_vec)));
    const out_b: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(out_b_vec)));

    var result: [lanes]u32 = undefined;
    inline for (0..lanes) |lane| {
        result[lane] = alpha[lane] | (@as(u32, clampByte(out_r[lane])) << 16) | (@as(u32, clampByte(out_g[lane])) << 8) | @as(u32, clampByte(out_b[lane]));
    }
    return result;
}

pub fn blendTemporalColorBatch(current_pixels: []const u32, history_colors: []const [3]f32, history_weights: []const f32, output: []u32) void {
    std.debug.assert(current_pixels.len == history_colors.len);
    std.debug.assert(current_pixels.len == history_weights.len);
    std.debug.assert(output.len >= current_pixels.len);
    switch (current_pixels.len) {
        0 => {},
        1 => output[0] = blendTemporalColor(current_pixels[0], history_colors[0], history_weights[0]),
        8 => {
            const result = blendTemporalColorBatchSimd(8, @ptrCast(current_pixels.ptr), @ptrCast(history_colors.ptr), @ptrCast(history_weights.ptr));
            const out_ptr: *[8]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        16 => {
            const result = blendTemporalColorBatchSimd(16, @ptrCast(current_pixels.ptr), @ptrCast(history_colors.ptr), @ptrCast(history_weights.ptr));
            const out_ptr: *[16]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        32 => {
            const result = blendTemporalColorBatchSimd(32, @ptrCast(current_pixels.ptr), @ptrCast(history_colors.ptr), @ptrCast(history_weights.ptr));
            const out_ptr: *[32]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        else => unreachable,
    }
}

pub fn pixelLuma(pixel: u32) f32 {
    const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(pixel & 0xFF));
    return (r * 0.299) + (g * 0.587) + (b * 0.114);
}

pub fn colorLuma(color: [3]f32) f32 {
    return (color[0] * 0.299) + (color[1] * 0.587) + (color[2] * 0.114);
}
