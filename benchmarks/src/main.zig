const std = @import("std");
const bench_cache = @import("bench_cache.zig");
const bench_meshlet = @import("bench_meshlet.zig");
const lighting = @import("lighting");
const lighting_simd = @import("lighting_simd.zig");
const render_job_bench = @import("render_job_bench.zig");

fn lcgNext(state: *u64) u32 {
    state.* = state.* *% 6364136223846793005 +% 1;
    return @as(u32, @truncate((state.* >> 32)));
}

fn lcgFloat(state: *u64) f32 {
    const value = lcgNext(state);
    return @as(f32, @floatFromInt(value)) / 4294967295.0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running Cache Benchmarks...\n", .{});

    // Cache Benchmarks
    std.debug.print("\n--- Cache Benchmarks ---\n", .{});
    const total_ops = @as(u64, @intCast(bench_cache.CACHE_BENCH_ARRAY_SIZE)) * bench_cache.CACHE_BENCH_ITERATIONS;
    const warmup_runs: usize = 1;
    const measure_runs: usize = 5;
    const total_runs = warmup_runs + measure_runs;

    var vec2_add_scalar_sum: u128 = 0;
    var vec2_add_opt_sum: u128 = 0;
    var vec2_add_scalar_best: u64 = std.math.maxInt(u64);
    var vec2_add_opt_best: u64 = std.math.maxInt(u64);

    var vec2_add_mul_scalar_sum: u128 = 0;
    var vec2_add_mul_opt_sum: u128 = 0;
    var vec2_add_mul_scalar_best: u64 = std.math.maxInt(u64);
    var vec2_add_mul_opt_best: u64 = std.math.maxInt(u64);

    var vec3_add_scalar_sum: u128 = 0;
    var vec3_add_opt_sum: u128 = 0;
    var vec3_add_scalar_best: u64 = std.math.maxInt(u64);
    var vec3_add_opt_best: u64 = std.math.maxInt(u64);

    var vec3_add_mul_scalar_sum: u128 = 0;
    var vec3_add_mul_opt_sum: u128 = 0;
    var vec3_add_mul_scalar_best: u64 = std.math.maxInt(u64);
    var vec3_add_mul_opt_best: u64 = std.math.maxInt(u64);

    var vec4_add_scalar_sum: u128 = 0;
    var vec4_add_opt_sum: u128 = 0;
    var vec4_add_scalar_best: u64 = std.math.maxInt(u64);
    var vec4_add_opt_best: u64 = std.math.maxInt(u64);

    var vec4_add_mul_scalar_sum: u128 = 0;
    var vec4_add_mul_opt_sum: u128 = 0;
    var vec4_add_mul_scalar_best: u64 = std.math.maxInt(u64);
    var vec4_add_mul_opt_best: u64 = std.math.maxInt(u64);

    var run_index: usize = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        const vec2_add_scalar = try bench_cache.benchmarkVec2ArrayAddScalar(allocator);
        const vec2_add_opt = try bench_cache.benchmarkVec2ArrayAddOptimized(allocator);

        const vec2_add_mul_scalar = try bench_cache.benchmarkVec2ArrayAddMulScalar(allocator);
        const vec2_add_mul_opt = try bench_cache.benchmarkVec2ArrayAddMulOptimized(allocator);

        const vec3_add_scalar = try bench_cache.benchmarkVec3ArrayAddScalar(allocator);
        const vec3_add_opt = try bench_cache.benchmarkVec3ArrayAddOptimized(allocator);

        const vec3_add_mul_scalar = try bench_cache.benchmarkVec3ArrayAddMulScalar(allocator);
        const vec3_add_mul_opt = try bench_cache.benchmarkVec3ArrayAddMulOptimized(allocator);

        const vec4_add_scalar = try bench_cache.benchmarkVec4ArrayAddScalar(allocator);
        const vec4_add_opt = try bench_cache.benchmarkVec4ArrayAddOptimized(allocator);

        const vec4_add_mul_scalar = try bench_cache.benchmarkVec4ArrayAddMulScalar(allocator);
        const vec4_add_mul_opt = try bench_cache.benchmarkVec4ArrayAddMulOptimized(allocator);

        if (record) {
            vec2_add_scalar_sum += vec2_add_scalar;
            vec2_add_opt_sum += vec2_add_opt;
            vec2_add_mul_scalar_sum += vec2_add_mul_scalar;
            vec2_add_mul_opt_sum += vec2_add_mul_opt;

            vec3_add_scalar_sum += vec3_add_scalar;
            vec3_add_opt_sum += vec3_add_opt;
            vec3_add_mul_scalar_sum += vec3_add_mul_scalar;
            vec3_add_mul_opt_sum += vec3_add_mul_opt;

            vec4_add_scalar_sum += vec4_add_scalar;
            vec4_add_opt_sum += vec4_add_opt;
            vec4_add_mul_scalar_sum += vec4_add_mul_scalar;
            vec4_add_mul_opt_sum += vec4_add_mul_opt;

            if (vec2_add_scalar < vec2_add_scalar_best) vec2_add_scalar_best = vec2_add_scalar;
            if (vec2_add_opt < vec2_add_opt_best) vec2_add_opt_best = vec2_add_opt;
            if (vec2_add_mul_scalar < vec2_add_mul_scalar_best) vec2_add_mul_scalar_best = vec2_add_mul_scalar;
            if (vec2_add_mul_opt < vec2_add_mul_opt_best) vec2_add_mul_opt_best = vec2_add_mul_opt;

            if (vec3_add_scalar < vec3_add_scalar_best) vec3_add_scalar_best = vec3_add_scalar;
            if (vec3_add_opt < vec3_add_opt_best) vec3_add_opt_best = vec3_add_opt;
            if (vec3_add_mul_scalar < vec3_add_mul_scalar_best) vec3_add_mul_scalar_best = vec3_add_mul_scalar;
            if (vec3_add_mul_opt < vec3_add_mul_opt_best) vec3_add_mul_opt_best = vec3_add_mul_opt;

            if (vec4_add_scalar < vec4_add_scalar_best) vec4_add_scalar_best = vec4_add_scalar;
            if (vec4_add_opt < vec4_add_opt_best) vec4_add_opt_best = vec4_add_opt;
            if (vec4_add_mul_scalar < vec4_add_mul_scalar_best) vec4_add_mul_scalar_best = vec4_add_mul_scalar;
            if (vec4_add_mul_opt < vec4_add_mul_opt_best) vec4_add_mul_opt_best = vec4_add_mul_opt;
        }
    }

    const total_ops_f = @as(f64, @floatFromInt(total_ops));
    const measure_runs_f = @as(f64, @floatFromInt(measure_runs));

    const vec2_add_scalar_avg = @as(f64, @floatFromInt(vec2_add_scalar_sum)) / measure_runs_f;
    const vec2_add_opt_avg = @as(f64, @floatFromInt(vec2_add_opt_sum)) / measure_runs_f;
    const vec2_add_scalar_ns = vec2_add_scalar_avg / total_ops_f;
    const vec2_add_opt_ns = vec2_add_opt_avg / total_ops_f;
    const vec2_add_speedup = vec2_add_scalar_ns / vec2_add_opt_ns;
    const vec2_add_scalar_best_ns = @as(f64, @floatFromInt(vec2_add_scalar_best)) / total_ops_f;
    const vec2_add_opt_best_ns = @as(f64, @floatFromInt(vec2_add_opt_best)) / total_ops_f;

    std.debug.print(
        "Vec2ArrayAdd ({} ops): scalar avg {d:.3} ns/op (best {d:.3}) | optimized avg {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x\n",
        .{ total_ops, vec2_add_scalar_ns, vec2_add_scalar_best_ns, vec2_add_opt_ns, vec2_add_opt_best_ns, vec2_add_speedup },
    );

    const vec2_add_mul_scalar_avg = @as(f64, @floatFromInt(vec2_add_mul_scalar_sum)) / measure_runs_f;
    const vec2_add_mul_opt_avg = @as(f64, @floatFromInt(vec2_add_mul_opt_sum)) / measure_runs_f;
    const vec2_add_mul_scalar_ns = vec2_add_mul_scalar_avg / total_ops_f;
    const vec2_add_mul_opt_ns = vec2_add_mul_opt_avg / total_ops_f;
    const vec2_add_mul_speedup = vec2_add_mul_scalar_ns / vec2_add_mul_opt_ns;
    const vec2_add_mul_scalar_best_ns = @as(f64, @floatFromInt(vec2_add_mul_scalar_best)) / total_ops_f;
    const vec2_add_mul_opt_best_ns = @as(f64, @floatFromInt(vec2_add_mul_opt_best)) / total_ops_f;

    std.debug.print(
        "Vec2ArrayAddMul ({} ops): scalar avg {d:.3} ns/op (best {d:.3}) | optimized avg {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x\n",
        .{ total_ops, vec2_add_mul_scalar_ns, vec2_add_mul_scalar_best_ns, vec2_add_mul_opt_ns, vec2_add_mul_opt_best_ns, vec2_add_mul_speedup },
    );

    const vec3_add_scalar_avg = @as(f64, @floatFromInt(vec3_add_scalar_sum)) / measure_runs_f;
    const vec3_add_opt_avg = @as(f64, @floatFromInt(vec3_add_opt_sum)) / measure_runs_f;
    const vec3_add_scalar_ns = vec3_add_scalar_avg / total_ops_f;
    const vec3_add_opt_ns = vec3_add_opt_avg / total_ops_f;
    const vec3_add_speedup = vec3_add_scalar_ns / vec3_add_opt_ns;
    const vec3_add_scalar_best_ns = @as(f64, @floatFromInt(vec3_add_scalar_best)) / total_ops_f;
    const vec3_add_opt_best_ns = @as(f64, @floatFromInt(vec3_add_opt_best)) / total_ops_f;

    std.debug.print(
        "Vec3ArrayAdd ({} ops): scalar avg {d:.3} ns/op (best {d:.3}) | optimized avg {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x\n",
        .{ total_ops, vec3_add_scalar_ns, vec3_add_scalar_best_ns, vec3_add_opt_ns, vec3_add_opt_best_ns, vec3_add_speedup },
    );

    const vec3_add_mul_scalar_avg = @as(f64, @floatFromInt(vec3_add_mul_scalar_sum)) / measure_runs_f;
    const vec3_add_mul_opt_avg = @as(f64, @floatFromInt(vec3_add_mul_opt_sum)) / measure_runs_f;
    const vec3_add_mul_scalar_ns = vec3_add_mul_scalar_avg / total_ops_f;
    const vec3_add_mul_opt_ns = vec3_add_mul_opt_avg / total_ops_f;
    const vec3_add_mul_speedup = vec3_add_mul_scalar_ns / vec3_add_mul_opt_ns;
    const vec3_add_mul_scalar_best_ns = @as(f64, @floatFromInt(vec3_add_mul_scalar_best)) / total_ops_f;
    const vec3_add_mul_opt_best_ns = @as(f64, @floatFromInt(vec3_add_mul_opt_best)) / total_ops_f;

    std.debug.print(
        "Vec3ArrayAddMul ({} ops): scalar avg {d:.3} ns/op (best {d:.3}) | optimized avg {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x\n",
        .{ total_ops, vec3_add_mul_scalar_ns, vec3_add_mul_scalar_best_ns, vec3_add_mul_opt_ns, vec3_add_mul_opt_best_ns, vec3_add_mul_speedup },
    );

    const vec4_add_scalar_avg = @as(f64, @floatFromInt(vec4_add_scalar_sum)) / measure_runs_f;
    const vec4_add_opt_avg = @as(f64, @floatFromInt(vec4_add_opt_sum)) / measure_runs_f;
    const vec4_add_scalar_ns = vec4_add_scalar_avg / total_ops_f;
    const vec4_add_opt_ns = vec4_add_opt_avg / total_ops_f;
    const vec4_add_speedup = vec4_add_scalar_ns / vec4_add_opt_ns;
    const vec4_add_scalar_best_ns = @as(f64, @floatFromInt(vec4_add_scalar_best)) / total_ops_f;
    const vec4_add_opt_best_ns = @as(f64, @floatFromInt(vec4_add_opt_best)) / total_ops_f;

    std.debug.print(
        "Vec4ArrayAdd ({} ops): scalar avg {d:.3} ns/op (best {d:.3}) | optimized avg {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x\n",
        .{ total_ops, vec4_add_scalar_ns, vec4_add_scalar_best_ns, vec4_add_opt_ns, vec4_add_opt_best_ns, vec4_add_speedup },
    );

    const vec4_add_mul_scalar_avg = @as(f64, @floatFromInt(vec4_add_mul_scalar_sum)) / measure_runs_f;
    const vec4_add_mul_opt_avg = @as(f64, @floatFromInt(vec4_add_mul_opt_sum)) / measure_runs_f;
    const vec4_add_mul_scalar_ns = vec4_add_mul_scalar_avg / total_ops_f;
    const vec4_add_mul_opt_ns = vec4_add_mul_opt_avg / total_ops_f;
    const vec4_add_mul_speedup = vec4_add_mul_scalar_ns / vec4_add_mul_opt_ns;
    const vec4_add_mul_scalar_best_ns = @as(f64, @floatFromInt(vec4_add_mul_scalar_best)) / total_ops_f;
    const vec4_add_mul_opt_best_ns = @as(f64, @floatFromInt(vec4_add_mul_opt_best)) / total_ops_f;

    std.debug.print(
        "Vec4ArrayAddMul ({} ops): scalar avg {d:.3} ns/op (best {d:.3}) | optimized avg {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x\n",
        .{ total_ops, vec4_add_mul_scalar_ns, vec4_add_mul_scalar_best_ns, vec4_add_mul_opt_ns, vec4_add_mul_opt_best_ns, vec4_add_mul_speedup },
    );

    std.debug.print("\n--- Lighting Benchmarks ---\n", .{});
    const pixel_count: usize = 1 << 20;
    var colors = try allocator.alloc(u32, pixel_count);
    defer allocator.free(colors);
    var intensities = try allocator.alloc(f32, pixel_count);
    defer allocator.free(intensities);
    var lighting_out = try allocator.alloc(u32, pixel_count);
    defer allocator.free(lighting_out);

    var rng_state: u64 = 0xC0FFEE;
    var fill_index: usize = 0;
    while (fill_index < pixel_count) : (fill_index += 1) {
        colors[fill_index] = lcgNext(&rng_state);
        intensities[fill_index] = lcgFloat(&rng_state);
    }

    var lighting_scalar_sum: u128 = 0;
    var lighting_opt_sum: u128 = 0;
    var lighting_scalar_best: u64 = std.math.maxInt(u64);
    var lighting_opt_best: u64 = std.math.maxInt(u64);
    var lighting_scalar_accum: u32 = 0;
    var lighting_opt_accum: u32 = 0;

    var lighting_run: usize = 0;
    while (lighting_run < total_runs) : (lighting_run += 1) {
        const record = lighting_run >= warmup_runs;

        var scalar_timer = try std.time.Timer.start();
        var idx: usize = 0;
        var local_scalar_accum: u32 = 0;
        while (idx < pixel_count) : (idx += 1) {
            const result = lighting.applyIntensity(colors[idx], intensities[idx]);
            lighting_out[idx] = result;
            local_scalar_accum ^= result;
        }
        const scalar_elapsed = scalar_timer.read();

        var opt_timer = try std.time.Timer.start();
        lighting_simd.applyIntensityBatch(colors, intensities, lighting_out);
        const opt_elapsed = opt_timer.read();

        idx = 0;
        var local_opt_accum: u32 = 0;
        while (idx < pixel_count) : (idx += 1) {
            local_opt_accum ^= lighting_out[idx];
        }

        if (record) {
            lighting_scalar_sum += scalar_elapsed;
            lighting_opt_sum += opt_elapsed;
            if (scalar_elapsed < lighting_scalar_best) lighting_scalar_best = scalar_elapsed;
            if (opt_elapsed < lighting_opt_best) lighting_opt_best = opt_elapsed;
            lighting_scalar_accum ^= local_scalar_accum;
            lighting_opt_accum ^= local_opt_accum;
        }
    }

    const pixels_f = @as(f64, @floatFromInt(pixel_count));
    const lighting_scalar_avg = @as(f64, @floatFromInt(lighting_scalar_sum)) / measure_runs_f;
    const lighting_opt_avg = @as(f64, @floatFromInt(lighting_opt_sum)) / measure_runs_f;
    const lighting_scalar_ns = lighting_scalar_avg / pixels_f;
    const lighting_opt_ns = lighting_opt_avg / pixels_f;
    const lighting_speedup = lighting_scalar_ns / lighting_opt_ns;
    const lighting_scalar_best_ns = @as(f64, @floatFromInt(lighting_scalar_best)) / pixels_f;
    const lighting_opt_best_ns = @as(f64, @floatFromInt(lighting_opt_best)) / pixels_f;

    std.debug.print(
        "applyIntensity ({} pixels): scalar avg {d:.3} ns/pixel (best {d:.3}) | optimized avg {d:.3} ns/pixel (best {d:.3}) | speedup {d:.2}x | xor 0x{X:0>8}/0x{X:0>8}\n",
        .{
            pixel_count,
            lighting_scalar_ns,
            lighting_scalar_best_ns,
            lighting_opt_ns,
            lighting_opt_best_ns,
            lighting_speedup,
            lighting_scalar_accum,
            lighting_opt_accum,
        },
    );

    std.debug.print("\n--- Render Job Prep Benchmarks ---\n", .{});
    const meshlet_count: usize = 4096;
    var job_baseline_sum: u128 = 0;
    var job_baseline_best: u64 = std.math.maxInt(u64);
    var job_cached_sum: u128 = 0;
    var job_cached_best: u64 = std.math.maxInt(u64);
    var job_baseline_checksum: u32 = 0;
    var job_cached_checksum: u32 = 0;

    var job_cache = render_job_bench.JobCache.init(allocator);
    defer job_cache.deinit();

    var job_iter: usize = 0;
    while (job_iter < total_runs) : (job_iter += 1) {
        const record = job_iter >= warmup_runs;

        var baseline_timer = try std.time.Timer.start();
        const baseline_checksum = try render_job_bench.baselinePass(allocator, meshlet_count);
        const baseline_elapsed = baseline_timer.read();

        var cached_timer = try std.time.Timer.start();
        const cached_checksum = try job_cache.cachedPass(meshlet_count);
        const cached_elapsed = cached_timer.read();

        if (record) {
            job_baseline_sum += baseline_elapsed;
            job_cached_sum += cached_elapsed;
            if (baseline_elapsed < job_baseline_best) job_baseline_best = baseline_elapsed;
            if (cached_elapsed < job_cached_best) job_cached_best = cached_elapsed;
            job_baseline_checksum ^= baseline_checksum;
            job_cached_checksum ^= cached_checksum;
        }
    }

    const job_baseline_avg = @as(f64, @floatFromInt(job_baseline_sum)) / measure_runs_f;
    const job_cached_avg = @as(f64, @floatFromInt(job_cached_sum)) / measure_runs_f;
    const job_baseline_best_ns = @as(f64, @floatFromInt(job_baseline_best));
    const job_cached_best_ns = @as(f64, @floatFromInt(job_cached_best));
    const job_speedup = job_baseline_avg / job_cached_avg;

    std.debug.print(
        "Job buffer prep ({} meshlets): baseline avg {d:.3} ns (best {d:.3}) | cached avg {d:.3} ns (best {d:.3}) | speedup {d:.2}x | xor 0x{X:0>8}/0x{X:0>8}\n",
        .{
            meshlet_count,
            job_baseline_avg,
            job_baseline_best_ns,
            job_cached_avg,
            job_cached_best_ns,
            job_speedup,
            job_baseline_checksum,
            job_cached_checksum,
        },
    );

    std.debug.print("\n--- Meshlet Pipeline Benchmarks ---\n", .{});
    const meshlet_result = try bench_meshlet.runMeshletBench(allocator, 48, 120);
    std.debug.print(
        "Grid 48x48 -> meshlets:{} triangles:{}\n",
        .{ meshlet_result.meshlet_count, meshlet_result.triangle_count },
    );
    std.debug.print(
        "Generation time: {} ns\n",
        .{meshlet_result.generation_ns},
    );
    std.debug.print(
        "Average cull: {d:.2} ns/frame | visible meshlets: {d:.2} | visible triangles: {d:.2}\n",
        .{
            meshlet_result.avg_cull_ns,
            meshlet_result.avg_visible_meshlets,
            meshlet_result.avg_visible_triangles,
        },
    );

    std.debug.print("\nBenchmarks complete.\n", .{});
}
