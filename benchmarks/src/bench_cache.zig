const std = @import("std");
const math = @import("math.zig");

pub const CACHE_BENCH_ARRAY_SIZE: usize = 1024 * 1024; // 1 million Vec3 elements
pub const CACHE_BENCH_ITERATIONS: u64 = 10; // Fewer iterations for large arrays

pub fn benchmarkVec3ArrayAdd(allocator: std.mem.Allocator) !u64 {
    var a = try allocator.alloc(math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(a);
    var b = try allocator.alloc(math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(b);
    var result = try allocator.alloc(math.Vec3, CACHE_BENCH_ARRAY_SIZE);
    defer allocator.free(result);

    // Initialize data to prevent cache hits from previous runs and ensure realistic access
    var i: usize = 0;
    while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
        a[i] = math.Vec3.new(@as(f32, @floatFromInt(i)), @as(f32, @floatFromInt(i + 1)), @as(f32, @floatFromInt(i + 2)));
        b[i] = math.Vec3.new(@as(f32, @floatFromInt(i * 2)), @as(f32, @floatFromInt(i * 2 + 1)), @as(f32, @floatFromInt(i * 2 + 2)));
    }

    var timer = std.time.Timer.init();
    timer.start();
    var iter: u64 = 0;
    while (iter < CACHE_BENCH_ITERATIONS) : (iter += 1) {
        i = 0;
        while (i < CACHE_BENCH_ARRAY_SIZE) : (i += 1) {
            result[i] = math.Vec3.add(a[i], b[i]);
        }
    }
    timer.stop();
    return timer.read();
}

// A more comprehensive cache benchmark would include:
// - Different access strides (e.g., `array[i * stride]`) to test cache line misses.
// - Matrix multiplication with different loop orders (ijk, ikj, jik, etc.) to see cache effects.
// - Comparing Array of Structs (AoS) vs. Struct of Arrays (SoA) for vector data.
