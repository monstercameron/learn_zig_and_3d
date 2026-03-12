//! Implements the Color Grade kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const cpu_features = @import("../../core/cpu_features.zig");

/// Clamps a scalar channel value to the byte range `[0, 255]`.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn clampByte(value: i32) u8 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return @intCast(value);
}

/// Returns the SIMD lane count selected for the current runtime target.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn runtimeLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

/// Applies batch simd.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn applyBatchSimd(comptime lanes: usize, pixels: *[lanes]u32, grade: anytype) void {
    const I16Vec = @Vector(lanes, i16);
    const zero: I16Vec = @splat(0);
    const max_channel: I16Vec = @splat(255);
    const three: I16Vec = @splat(3);
    const sat_r: I16Vec = @splat(110);
    const sat_g: I16Vec = @splat(104);
    const sat_b: I16Vec = @splat(96);
    const hundred: I16Vec = @splat(100);

    var alpha: [lanes]u32 = undefined;
    var r_arr: [lanes]i16 = undefined;
    var g_arr: [lanes]i16 = undefined;
    var b_arr: [lanes]i16 = undefined;
    var add_r_arr: [lanes]i16 = undefined;
    var add_g_arr: [lanes]i16 = undefined;
    var add_b_arr: [lanes]i16 = undefined;

    inline for (0..lanes) |lane| {
        const pixel = pixels[lane];
        alpha[lane] = pixel & 0xFF000000;

        const r0: u8 = grade.base_curve[@intCast((pixel >> 16) & 0xFF)];
        const g0: u8 = grade.base_curve[@intCast((pixel >> 8) & 0xFF)];
        const b0: u8 = grade.base_curve[@intCast(pixel & 0xFF)];
        const luma_index: usize = @intCast((@as(u32, r0) * 77 + @as(u32, g0) * 150 + @as(u32, b0) * 29) >> 8);

        r_arr[lane] = r0;
        g_arr[lane] = g0;
        b_arr[lane] = b0;
        add_r_arr[lane] = grade.tone_add_r[luma_index];
        add_g_arr[lane] = grade.tone_add_g[luma_index];
        add_b_arr[lane] = grade.tone_add_b[luma_index];
    }

    var r_vec: I16Vec = @bitCast(r_arr);
    var g_vec: I16Vec = @bitCast(g_arr);
    var b_vec: I16Vec = @bitCast(b_arr);
    r_vec += @bitCast(add_r_arr);
    g_vec += @bitCast(add_g_arr);
    b_vec += @bitCast(add_b_arr);

    const mean = @divTrunc(r_vec + g_vec + b_vec, three);
    r_vec = mean + @divTrunc((r_vec - mean) * sat_r, hundred);
    g_vec = mean + @divTrunc((g_vec - mean) * sat_g, hundred);
    b_vec = mean + @divTrunc((b_vec - mean) * sat_b, hundred);

    const r_clamped: I16Vec = @min(@max(r_vec, zero), max_channel);
    const g_clamped: I16Vec = @min(@max(g_vec, zero), max_channel);
    const b_clamped: I16Vec = @min(@max(b_vec, zero), max_channel);
    const r_out: [lanes]i16 = @bitCast(r_clamped);
    const g_out: [lanes]i16 = @bitCast(g_clamped);
    const b_out: [lanes]i16 = @bitCast(b_clamped);

    inline for (0..lanes) |lane| {
        pixels[lane] = alpha[lane] |
            (@as(u32, @intCast(r_out[lane])) << 16) |
            (@as(u32, @intCast(g_out[lane])) << 8) |
            @as(u32, @intCast(b_out[lane]));
    }
}

/// Applies range.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn applyRange(
    pixels: []u32,
    start_index: usize,
    end_index: usize,
    grade: anytype,
) void {
    var i = start_index;
    const lanes = runtimeLanes();

    while (i + lanes <= end_index) : (i += lanes) {
        switch (lanes) {
            8 => {
                const block: *[8]u32 = @ptrCast(pixels[i .. i + 8].ptr);
                applyBatchSimd(8, block, grade);
            },
            16 => {
                const block: *[16]u32 = @ptrCast(pixels[i .. i + 16].ptr);
                applyBatchSimd(16, block, grade);
            },
            32 => {
                const block: *[32]u32 = @ptrCast(pixels[i .. i + 32].ptr);
                applyBatchSimd(32, block, grade);
            },
            else => break,
        }
    }

    while (i < end_index) : (i += 1) {
        const pixel = pixels[i];
        const a: u32 = pixel & 0xFF000000;

        const r0: u8 = grade.base_curve[@intCast((pixel >> 16) & 0xFF)];
        const g0: u8 = grade.base_curve[@intCast((pixel >> 8) & 0xFF)];
        const b0: u8 = grade.base_curve[@intCast(pixel & 0xFF)];

        const luma_index: usize = @intCast((@as(u32, r0) * 77 + @as(u32, g0) * 150 + @as(u32, b0) * 29) >> 8);
        var r: i32 = @as(i32, r0) + grade.tone_add_r[luma_index];
        var g: i32 = @as(i32, g0) + grade.tone_add_g[luma_index];
        var b: i32 = @as(i32, b0) + grade.tone_add_b[luma_index];

        const mean = @divTrunc(r + g + b, 3);
        r = mean + @divTrunc((r - mean) * 110, 100);
        g = mean + @divTrunc((g - mean) * 104, 100);
        b = mean + @divTrunc((b - mean) * 96, 100);

        pixels[i] = a |
            (@as(u32, clampByte(r)) << 16) |
            (@as(u32, clampByte(g)) << 8) |
            @as(u32, clampByte(b));
    }
}
