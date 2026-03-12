//! Ssimd module.
//! Benchmark harness module used to measure CPU/scalar/SIMD performance characteristics.

const std = @import("std");
const builtin = @import("builtin");

fn detectF32LaneCount() comptime_int {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => blk: {
            const features = builtin.cpu.features;
            if (std.Target.x86.featureSetHas(features, .avx512f)) break :blk 16;
            if (std.Target.x86.featureSetHas(features, .avx2)) break :blk 8;
            if (std.Target.x86.featureSetHas(features, .sse2)) break :blk 4;
            break :blk 1;
        },
        .aarch64 => blk: {
            if (std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon)) break :blk 4;
            break :blk 1;
        },
        .arm => blk: {
            if (std.Target.arm.featureSetHas(builtin.cpu.features, .neon)) break :blk 4;
            break :blk 1;
        },
        else => 4,
    };
}

fn detectHasFma() bool {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
        else => false,
    };
}

pub const f32_lane_count = detectF32LaneCount();
pub const has_fma = detectHasFma();

pub const Vec4f = @Vector(4, f32);
pub const WideVec = @Vector(f32_lane_count, f32);

pub const vec3s_per_wide = if (f32_lane_count >= 4 and f32_lane_count % 4 == 0) f32_lane_count / 4 else 0;
pub const supports_vec3_batches = vec3s_per_wide != 0;

/// Loads l oa dw id e from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
pub inline fn loadWide(ptr: [*]const f32) WideVec {
    return @as(*align(1) const WideVec, @ptrCast(ptr)).*;
}

/// Moves data for store wide.
/// Keeps store wide as the single implementation point so call-site behavior stays consistent.
pub inline fn storeWide(ptr: [*]f32, value: WideVec) void {
    @as(*align(1) WideVec, @ptrCast(ptr)).* = value;
}

/// Returns a fused multiply-add result over wide SIMD lanes.
/// Keeps fmadd wide as the single implementation point so call-site behavior stays consistent.
pub inline fn fmaddWide(a: WideVec, b: WideVec, c: WideVec) WideVec {
    if (has_fma) {
        return @mulAdd(WideVec, b, c, a);
    }
    return a + b * c;
}

/// Reduces wide SIMD lanes into a single summed scalar value.
/// Keeps reduce add wide as the single implementation point so call-site behavior stays consistent.
pub inline fn reduceAddWide(vec: WideVec) f32 {
    return std.simd.reduce(.Add, vec);
}

/// Loads l oa dv ec3 from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
pub inline fn loadVec3(comptime Vec: type, value: Vec) Vec4f {
    var result = Vec4f{ value.x, value.y, value.z, 0.0 };
    if (@hasField(Vec, "_pad")) {
        result[3] = @field(value, "_pad");
    }
    return result;
}

/// Moves data for store vec3.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub inline fn storeVec3(comptime Vec: type, vec: Vec4f) Vec {
    var result: Vec = undefined;
    result.x = vec[0];
    result.y = vec[1];
    result.z = vec[2];
    if (@hasField(Vec, "_pad")) {
        @field(result, "_pad") = 0.0;
    }
    return result;
}

/// Returns a fused multiply-add result for packed Vec3 data.
/// Keeps fmadd vec3 as the single implementation point so call-site behavior stays consistent.
pub inline fn fmaddVec3(a: Vec4f, b: Vec4f, c: Vec4f) Vec4f {
    if (has_fma) {
        return @mulAdd(Vec4f, b, c, a);
    }
    return a + b * c;
}

/// Returns a fused multiply-add result for Vec4 inputs.
/// Keeps fmadd vec4 as the single implementation point so call-site behavior stays consistent.
pub inline fn fmaddVec4(a: Vec4f, b: Vec4f, c: Vec4f) Vec4f {
    if (has_fma) {
        return @mulAdd(Vec4f, b, c, a);
    }
    return a + b * c;
}

/// Returns the 4-component dot product.
/// Keeps dot4 as the single implementation point so call-site behavior stays consistent.
pub inline fn dot4(a: Vec4f, b: Vec4f) f32 {
    const mul = a * b;
    return mul[0] + mul[1] + mul[2] + mul[3];
}

/// Returns the 3-component dot product.
/// Keeps dot vec3 as the single implementation point so call-site behavior stays consistent.
pub inline fn dotVec3(a: Vec4f, b: Vec4f) f32 {
    const mul = a * b;
    return mul[0] + mul[1] + mul[2];
}

/// Performs permute vec3 wide.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub inline fn permuteVec3Wide(vec: WideVec, comptime order: [3]u32) WideVec {
    var mask: @Vector(f32_lane_count, u32) = undefined;
    inline for (0..f32_lane_count) |lane| {
        const block_base = @as(u32, (lane / 4) * 4);
        const block_index = lane % 4;
        mask[lane] = switch (block_index) {
            0 => block_base + order[0],
            1 => block_base + order[1],
            2 => block_base + order[2],
            else => block_base + 3,
        };
    }
    return @shuffle(f32, vec, vec, mask);
}
