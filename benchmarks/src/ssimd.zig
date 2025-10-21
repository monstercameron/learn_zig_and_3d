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

pub inline fn loadWide(ptr: [*]const f32) WideVec {
    return @as(*align(1) const WideVec, @ptrCast(ptr)).*;
}

pub inline fn storeWide(ptr: [*]f32, value: WideVec) void {
    @as(*align(1) WideVec, @ptrCast(ptr)).* = value;
}

pub inline fn fmaddWide(a: WideVec, b: WideVec, c: WideVec) WideVec {
    if (has_fma) {
        return @mulAdd(WideVec, b, c, a);
    }
    return a + b * c;
}

pub inline fn reduceAddWide(vec: WideVec) f32 {
    return std.simd.reduce(.Add, vec);
}

pub inline fn loadVec3(comptime Vec: type, value: Vec) Vec4f {
    var result = Vec4f{ value.x, value.y, value.z, 0.0 };
    if (@hasField(Vec, "_pad")) {
        result[3] = @field(value, "_pad");
    }
    return result;
}

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

pub inline fn fmaddVec3(a: Vec4f, b: Vec4f, c: Vec4f) Vec4f {
    if (has_fma) {
        return @mulAdd(Vec4f, b, c, a);
    }
    return a + b * c;
}

pub inline fn fmaddVec4(a: Vec4f, b: Vec4f, c: Vec4f) Vec4f {
    if (has_fma) {
        return @mulAdd(Vec4f, b, c, a);
    }
    return a + b * c;
}

pub inline fn dot4(a: Vec4f, b: Vec4f) f32 {
    const mul = a * b;
    return mul[0] + mul[1] + mul[2] + mul[3];
}

pub inline fn dotVec3(a: Vec4f, b: Vec4f) f32 {
    const mul = a * b;
    return mul[0] + mul[1] + mul[2];
}

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
