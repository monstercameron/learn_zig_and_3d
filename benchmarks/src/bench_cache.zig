const std = @import("std");
const math_ssimd = @import("math_copy.zig");
const math_scalar = @import("math_scalar.zig");

pub const CACHE_BENCH_ARRAY_SIZE: usize = 1024 * 1024; // 1 million Vec3 elements
pub const CACHE_BENCH_ITERATIONS: u64 = 10;

fn benchmarkVec2ArrayAddImpl(comptime Math: type, allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);

    var b = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);

    const result = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = Math.Vec2.new(
            @as(f32, @floatFromInt(i)),
            @as(f32, @floatFromInt(i + 1)),
        );
        b[i] = Math.Vec2.new(
            @as(f32, @floatFromInt(i * 2)),
            @as(f32, @floatFromInt(i * 2 + 1)),
        );
    }

    var timer = try std.time.Timer.start();

    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        Math.addSliceVec2(result, a, b);
    }

    return timer.read();
}

fn benchmarkVec2ArrayAddMulImpl(comptime Math: type, allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);

    var b = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);

    var c = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(c);

    const result = try allocator.alloc(Math.Vec2, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = Math.Vec2.new(
            @as(f32, @floatFromInt(i)),
            @as(f32, @floatFromInt(i + 1)),
        );
        b[i] = Math.Vec2.new(
            @as(f32, @floatFromInt(i * 2)),
            @as(f32, @floatFromInt(i * 2 + 1)),
        );
        c[i] = Math.Vec2.new(
            @as(f32, @floatFromInt(i * 3)),
            @as(f32, @floatFromInt(i * 3 + 1)),
        );
    }

    var timer = try std.time.Timer.start();

    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        Math.addMulSliceVec2(result, a, b, c);
    }

    return timer.read();
}

fn benchmarkVec3ArrayAddImpl(comptime Math: type, allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);

    var b = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);

    const result = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = Math.Vec3.new(
            @as(f32, @floatFromInt(i)),
            @as(f32, @floatFromInt(i + 1)),
            @as(f32, @floatFromInt(i + 2)),
        );
        b[i] = Math.Vec3.new(
            @as(f32, @floatFromInt(i * 2)),
            @as(f32, @floatFromInt(i * 2 + 1)),
            @as(f32, @floatFromInt(i * 2 + 2)),
        );
    }

    var timer = try std.time.Timer.start();

    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        Math.addSlice(result, a, b);
    }

    return timer.read();
}

fn benchmarkVec3ArrayAddMulImpl(comptime Math: type, allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);

    var b = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);

    var c = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(c);

    const result = try allocator.alloc(Math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = Math.Vec3.new(
            @as(f32, @floatFromInt(i)),
            @as(f32, @floatFromInt(i + 1)),
            @as(f32, @floatFromInt(i + 2)),
        );
        b[i] = Math.Vec3.new(
            @as(f32, @floatFromInt(i * 2)),
            @as(f32, @floatFromInt(i * 2 + 1)),
            @as(f32, @floatFromInt(i * 2 + 2)),
        );
        c[i] = Math.Vec3.new(
            @as(f32, @floatFromInt(i * 3)),
            @as(f32, @floatFromInt(i * 3 + 1)),
            @as(f32, @floatFromInt(i * 3 + 2)),
        );
    }

    var timer = try std.time.Timer.start();

    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        Math.addMulSlice(result, a, b, c);
    }

    return timer.read();
}

fn benchmarkVec4ArrayAddImpl(comptime Math: type, allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);

    var b = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);

    const result = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = Math.Vec4.new(
            @as(f32, @floatFromInt(i)),
            @as(f32, @floatFromInt(i + 1)),
            @as(f32, @floatFromInt(i + 2)),
            @as(f32, @floatFromInt(i + 3)),
        );
        b[i] = Math.Vec4.new(
            @as(f32, @floatFromInt(i * 2)),
            @as(f32, @floatFromInt(i * 2 + 1)),
            @as(f32, @floatFromInt(i * 2 + 2)),
            @as(f32, @floatFromInt(i * 2 + 3)),
        );
    }

    var timer = try std.time.Timer.start();

    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        Math.addSliceVec4(result, a, b);
    }

    return timer.read();
}

fn benchmarkVec4ArrayAddMulImpl(comptime Math: type, allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);

    var b = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);

    var c = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(c);

    const result = try allocator.alloc(Math.Vec4, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = Math.Vec4.new(
            @as(f32, @floatFromInt(i)),
            @as(f32, @floatFromInt(i + 1)),
            @as(f32, @floatFromInt(i + 2)),
            @as(f32, @floatFromInt(i + 3)),
        );
        b[i] = Math.Vec4.new(
            @as(f32, @floatFromInt(i * 2)),
            @as(f32, @floatFromInt(i * 2 + 1)),
            @as(f32, @floatFromInt(i * 2 + 2)),
            @as(f32, @floatFromInt(i * 2 + 3)),
        );
        c[i] = Math.Vec4.new(
            @as(f32, @floatFromInt(i * 3)),
            @as(f32, @floatFromInt(i * 3 + 1)),
            @as(f32, @floatFromInt(i * 3 + 2)),
            @as(f32, @floatFromInt(i * 3 + 3)),
        );
    }

    var timer = try std.time.Timer.start();

    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        Math.addMulSliceVec4(result, a, b, c);
    }

    return timer.read();
}

pub fn benchmarkVec3ArrayAddScalar(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec3ArrayAddImpl(math_scalar, allocator);
}

pub fn benchmarkVec3ArrayAddOptimized(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec3ArrayAddImpl(math_ssimd, allocator);
}

pub fn benchmarkVec3ArrayAddMulScalar(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec3ArrayAddMulImpl(math_scalar, allocator);
}

pub fn benchmarkVec3ArrayAddMulOptimized(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec3ArrayAddMulImpl(math_ssimd, allocator);
}

pub fn benchmarkVec2ArrayAddScalar(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec2ArrayAddImpl(math_scalar, allocator);
}

pub fn benchmarkVec2ArrayAddOptimized(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec2ArrayAddImpl(math_ssimd, allocator);
}

pub fn benchmarkVec2ArrayAddMulScalar(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec2ArrayAddMulImpl(math_scalar, allocator);
}

pub fn benchmarkVec2ArrayAddMulOptimized(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec2ArrayAddMulImpl(math_ssimd, allocator);
}

pub fn benchmarkVec4ArrayAddScalar(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec4ArrayAddImpl(math_scalar, allocator);
}

pub fn benchmarkVec4ArrayAddOptimized(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec4ArrayAddImpl(math_ssimd, allocator);
}

pub fn benchmarkVec4ArrayAddMulScalar(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec4ArrayAddMulImpl(math_scalar, allocator);
}

pub fn benchmarkVec4ArrayAddMulOptimized(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec4ArrayAddMulImpl(math_ssimd, allocator);
}

pub fn benchmarkVec3ArrayAdd(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec3ArrayAddOptimized(allocator);
}

pub fn benchmarkVec3ArrayAddMul(allocator: std.mem.Allocator) !u64 {
    return benchmarkVec3ArrayAddMulOptimized(allocator);
}
