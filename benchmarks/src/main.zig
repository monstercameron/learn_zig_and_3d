const std = @import("std");
const bench_cache = @import("bench_cache.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running Cache Benchmarks...\n", .{});

    // Cache Benchmarks
    std.debug.print("\n--- Cache Benchmarks ---\n", .{});
    std.debug.print("Vec3ArrayAdd ({} total operations): {} ns/op\n", .{ bench_cache.CACHE_BENCH_ARRAY_SIZE * bench_cache.CACHE_BENCH_ITERATIONS, @as(f64, @floatFromInt(try bench_cache.benchmarkVec3ArrayAdd(allocator))) / @as(f64, @floatFromInt(bench_cache.CACHE_BENCH_ARRAY_SIZE * bench_cache.CACHE_BENCH_ITERATIONS)) });

    std.debug.print("\nBenchmarks complete.\n", .{});
}
