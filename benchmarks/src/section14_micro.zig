//! Focused micro-benchmarks for Section 14 kernel hot-path work.
//! Compares baseline generic paths against specialized/optimized paths.

const std = @import("std");
const compute = @import("render_compute");
const shadow_raster_kernel = @import("shadow_raster_kernel");
const chromatic_aberration_kernel = @import("chromatic_aberration_kernel");

const Texture2D = compute.Texture2D;
const RWTexture2D = compute.RWTexture2D;

const RasterShadowMap = struct {
    active: bool = true,
    width: usize,
    height: usize,
    inv_extent_x: f32,
    inv_extent_y: f32,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    depth: []f32,
};

const RasterPoint = struct {
    x: f32,
    y: f32,
    z: f32,
};

fn shadowEdgeBaseline(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
}

fn rasterizeTriangleRowsBaseline(
    shadow: *RasterShadowMap,
    start_row: usize,
    end_row: usize,
    p0: RasterPoint,
    p1: RasterPoint,
    p2: RasterPoint,
) void {
    if (!shadow.active) return;
    if (start_row >= end_row or end_row > shadow.height) return;

    const scale_x = @as(f32, @floatFromInt(shadow.width - 1)) * shadow.inv_extent_x;
    const scale_y = @as(f32, @floatFromInt(shadow.height - 1)) * shadow.inv_extent_y;

    const s0 = [2]f32{ (p0.x - shadow.min_x) * scale_x, (shadow.max_y - p0.y) * scale_y };
    const s1 = [2]f32{ (p1.x - shadow.min_x) * scale_x, (shadow.max_y - p1.y) * scale_y };
    const s2 = [2]f32{ (p2.x - shadow.min_x) * scale_x, (shadow.max_y - p2.y) * scale_y };

    const area = shadowEdgeBaseline(s0, s1, s2);
    if (@abs(area) < 1e-5) return;

    const min_x = std.math.clamp(@as(i32, @intFromFloat(@floor(@min(s0[0], @min(s1[0], s2[0]))))), 0, @as(i32, @intCast(shadow.width - 1)));
    const max_x = std.math.clamp(@as(i32, @intFromFloat(@ceil(@max(s0[0], @max(s1[0], s2[0]))))), 0, @as(i32, @intCast(shadow.width - 1)));
    const min_y = std.math.clamp(
        @as(i32, @intFromFloat(@floor(@min(s0[1], @min(s1[1], s2[1]))))),
        @as(i32, @intCast(start_row)),
        @as(i32, @intCast(end_row - 1)),
    );
    const max_y = std.math.clamp(
        @as(i32, @intFromFloat(@ceil(@max(s0[1], @max(s1[1], s2[1]))))),
        @as(i32, @intCast(start_row)),
        @as(i32, @intCast(end_row - 1)),
    );
    if (min_y > max_y) return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const sample = [2]f32{
                @as(f32, @floatFromInt(x)) + 0.5,
                @as(f32, @floatFromInt(y)) + 0.5,
            };
            const w0 = shadowEdgeBaseline(s1, s2, sample);
            const w1 = shadowEdgeBaseline(s2, s0, sample);
            const w2 = shadowEdgeBaseline(s0, s1, sample);

            if ((area > 0.0 and (w0 < 0.0 or w1 < 0.0 or w2 < 0.0)) or
                (area < 0.0 and (w0 > 0.0 or w1 > 0.0 or w2 > 0.0)))
            {
                continue;
            }

            const inv_area = 1.0 / area;
            const depth = (w0 * p0.z + w1 * p1.z + w2 * p2.z) * inv_area;
            const idx = @as(usize, @intCast(y)) * shadow.width + @as(usize, @intCast(x));
            if (depth < shadow.depth[idx]) shadow.depth[idx] = depth;
        }
    }
}

fn checksumTextureRGBA32F(tex: *const Texture2D) f32 {
    var sum: f32 = 0.0;
    var y: u32 = 0;
    while (y < tex.height) : (y += 1) {
        var x: u32 = 0;
        while (x < tex.width) : (x += 1) {
            const c = compute.loadRGBA32F(tex, x, y);
            sum += c[0] * 0.25 + c[1] * 0.5 + c[2] * 0.125 + c[3] * 0.0625;
        }
    }
    return sum;
}

fn checksumDepth(depth: []const f32) f64 {
    var sum: f64 = 0.0;
    for (depth) |v| {
        if (std.math.isFinite(v)) sum += v;
    }
    return sum;
}

fn checksumPixels(pixels: []const u32) u64 {
    var sum: u64 = 0;
    for (pixels) |p| {
        sum +%= @as(u64, p) *% 2654435761;
        sum ^= (sum >> 13);
    }
    return sum;
}

fn dofApplyRowsBaseline(
    scene_pixels: []const u32,
    scratch_pixels: []u32,
    scene_depth: []const f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    focal_distance: f32,
    focal_range: f32,
    max_blur_radius: i32,
) void {
    const pixels = scene_pixels;
    const out_pixels = scratch_pixels;
    const depth = scene_depth;
    const w = width;
    const h = height;
    const max_rad = @as(f32, @floatFromInt(max_blur_radius));

    for (start_row..end_row) |y| {
        for (0..w) |x| {
            const idx = y * w + x;
            const d = depth[idx];
            const dist_from_focal = @abs(d - focal_distance);

            var blur_amount: f32 = 0.0;
            if (dist_from_focal > focal_range) {
                blur_amount = @min(1.0, (dist_from_focal - focal_range) / focal_range);
            }

            const blur_radius = blur_amount * max_rad;

            if (blur_radius < 1.0) {
                out_pixels[idx] = pixels[idx];
            } else {
                const irad = @as(i32, @intFromFloat(blur_radius));
                var r_sum: u32 = 0;
                var g_sum: u32 = 0;
                var b_sum: u32 = 0;
                var count: u32 = 0;

                const min_y = @max(0, @as(i32, @intCast(y)) - irad);
                const max_y = @min(@as(i32, @intCast(h)) - 1, @as(i32, @intCast(y)) + irad);
                const min_x = @max(0, @as(i32, @intCast(x)) - irad);
                const max_x = @min(@as(i32, @intCast(w)) - 1, @as(i32, @intCast(x)) + irad);
                const step: i32 = if (irad > 2) 2 else 1;

                var sy: i32 = min_y;
                while (sy <= max_y) : (sy += step) {
                    var sx: i32 = min_x;
                    while (sx <= max_x) : (sx += step) {
                        const sidx = @as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx));
                        const p = pixels[sidx];
                        r_sum += (p >> 16) & 0xFF;
                        g_sum += (p >> 8) & 0xFF;
                        b_sum += p & 0xFF;
                        count += 1;
                    }
                }

                const out_r = r_sum / count;
                const out_g = g_sum / count;
                const out_b = b_sum / count;
                out_pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
            }
        }
    }
}

fn dofApplyRowsOptimized(
    scene_pixels: []const u32,
    scratch_pixels: []u32,
    scene_depth: []const f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    focal_distance: f32,
    focal_range: f32,
    max_blur_radius: i32,
) void {
    const pixels = scene_pixels;
    const out_pixels = scratch_pixels;
    const depth = scene_depth;
    const w = width;
    const h = height;
    const max_rad = @as(f32, @floatFromInt(max_blur_radius));

    for (start_row..end_row) |y| {
        const row_start = y * w;
        const y_i32 = @as(i32, @intCast(y));
        for (0..w) |x| {
            const idx = row_start + x;
            const d = depth[idx];
            const dist_from_focal = @abs(d - focal_distance);

            var blur_amount: f32 = 0.0;
            if (dist_from_focal > focal_range) {
                blur_amount = @min(1.0, (dist_from_focal - focal_range) / focal_range);
            }

            const blur_radius = blur_amount * max_rad;

            if (blur_radius < 1.0) {
                out_pixels[idx] = pixels[idx];
            } else {
                const irad = @as(i32, @intFromFloat(blur_radius));
                var r_sum: u32 = 0;
                var g_sum: u32 = 0;
                var b_sum: u32 = 0;
                var count: u32 = 0;

                const min_y = @max(0, y_i32 - irad);
                const max_y = @min(@as(i32, @intCast(h)) - 1, y_i32 + irad);
                const min_x = @max(0, @as(i32, @intCast(x)) - irad);
                const max_x = @min(@as(i32, @intCast(w)) - 1, @as(i32, @intCast(x)) + irad);
                const step: i32 = if (irad > 2) 2 else 1;

                var sy: i32 = min_y;
                while (sy <= max_y) : (sy += step) {
                    const sy_row_start = @as(usize, @intCast(sy)) * w;
                    var sx: i32 = min_x;
                    while (sx <= max_x) : (sx += step) {
                        const sidx = sy_row_start + @as(usize, @intCast(sx));
                        const p = pixels[sidx];
                        r_sum += (p >> 16) & 0xFF;
                        g_sum += (p >> 8) & 0xFF;
                        b_sum += p & 0xFF;
                        count += 1;
                    }
                }

                const out_r = r_sum / count;
                const out_g = g_sum / count;
                const out_b = b_sum / count;
                out_pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
            }
        }
    }
}

fn chromaticAberrationApplyRowsBaseline(
    src_pixels: []const u32,
    dst_pixels: []u32,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,
    strength: f32,
) void {
    const cx = @as(f32, @floatFromInt(width)) * 0.5;
    const cy = @as(f32, @floatFromInt(height)) * 0.5;

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = row_start + x;
            const dx = (@as(f32, @floatFromInt(x)) - cx) / cx;
            const dy = (@as(f32, @floatFromInt(y)) - cy) / cy;
            const dist = dx * dx + dy * dy;
            const shift = dist * strength;

            const x_f = @as(f32, @floatFromInt(x));
            const r_x = @as(i32, @intFromFloat(x_f + shift));
            const b_x = @as(i32, @intFromFloat(x_f - shift));

            const safe_r_x = @max(0, @min(@as(i32, @intCast(width)) - 1, r_x));
            const safe_b_x = @max(0, @min(@as(i32, @intCast(width)) - 1, b_x));

            const px_r = src_pixels[y * width + @as(usize, @intCast(safe_r_x))];
            const px_g = src_pixels[idx];
            const px_b = src_pixels[y * width + @as(usize, @intCast(safe_b_x))];

            const final_r = (px_r >> 16) & 0xFF;
            const final_g = (px_g >> 8) & 0xFF;
            const final_b = px_b & 0xFF;

            dst_pixels[idx] = 0xFF000000 | (final_r << 16) | (final_g << 8) | final_b;
        }
    }
}

fn averageNs(sum: u128, runs: usize) f64 {
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(runs));
}

pub fn run(allocator: std.mem.Allocator) !void {
    const warmup_runs: usize = 1;
    const measure_runs: usize = 7;
    const total_runs = warmup_runs + measure_runs;

    std.debug.print("\n--- Section 14 Micro Benchmarks ---\n", .{});

    // 14.1: generic texture format switch vs specialized rgba32f paths.
    const tex_width: u32 = 512;
    const tex_height: u32 = 512;
    const tex_pixels: usize = @as(usize, tex_width) * @as(usize, tex_height);
    const tex_stride: u32 = tex_width * 16;
    const tex_bytes: usize = tex_pixels * 16;

    const src_data = try allocator.alloc(u8, tex_bytes);
    defer allocator.free(src_data);
    const dst_generic_data = try allocator.alloc(u8, tex_bytes);
    defer allocator.free(dst_generic_data);
    const dst_fast_data = try allocator.alloc(u8, tex_bytes);
    defer allocator.free(dst_fast_data);

    var src_tex = RWTexture2D{
        .width = tex_width,
        .height = tex_height,
        .stride_bytes = tex_stride,
        .format = .rgba32f,
        .data = src_data,
    };
    var dst_generic_tex = RWTexture2D{
        .width = tex_width,
        .height = tex_height,
        .stride_bytes = tex_stride,
        .format = .rgba32f,
        .data = dst_generic_data,
    };
    var dst_fast_tex = RWTexture2D{
        .width = tex_width,
        .height = tex_height,
        .stride_bytes = tex_stride,
        .format = .rgba32f,
        .data = dst_fast_data,
    };

    var init_y: u32 = 0;
    while (init_y < tex_height) : (init_y += 1) {
        var init_x: u32 = 0;
        while (init_x < tex_width) : (init_x += 1) {
            const fx = @as(f32, @floatFromInt(init_x));
            const fy = @as(f32, @floatFromInt(init_y));
            compute.storeRGBA32F(&src_tex, init_x, init_y, .{
                @sin(fx * 0.007 + fy * 0.003) * 0.5 + 0.5,
                @sin(fx * 0.005 + fy * 0.009) * 0.5 + 0.5,
                @sin(fx * 0.011 + fy * 0.004) * 0.5 + 0.5,
                1.0,
            });
        }
    }

    const load_iterations: usize = 8;
    var load_generic_sum: u128 = 0;
    var load_generic_best: u64 = std.math.maxInt(u64);
    var load_fast_sum: u128 = 0;
    var load_fast_best: u64 = std.math.maxInt(u64);
    var load_generic_accum: f32 = 0.0;
    var load_fast_accum: f32 = 0.0;

    var run_index: usize = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        var load_generic_accum_local: f32 = 0.0;
        var load_generic_timer = try std.time.Timer.start();
        var iter: usize = 0;
        while (iter < load_iterations) : (iter += 1) {
            var y: u32 = 0;
            while (y < tex_height) : (y += 1) {
                var x: u32 = 0;
                while (x < tex_width) : (x += 1) {
                    const c = compute.loadRGBA(&src_tex, x, y);
                    load_generic_accum_local += c[0] * 0.25 + c[1] * 0.5 + c[2] * 0.125 + c[3] * 0.0625;
                }
            }
        }
        const load_generic_ns = load_generic_timer.read();
        std.mem.doNotOptimizeAway(load_generic_accum_local);

        var load_fast_accum_local: f32 = 0.0;
        var load_fast_timer = try std.time.Timer.start();
        iter = 0;
        while (iter < load_iterations) : (iter += 1) {
            var y: u32 = 0;
            while (y < tex_height) : (y += 1) {
                var x: u32 = 0;
                while (x < tex_width) : (x += 1) {
                    const c = compute.loadRGBA32F(&src_tex, x, y);
                    load_fast_accum_local += c[0] * 0.25 + c[1] * 0.5 + c[2] * 0.125 + c[3] * 0.0625;
                }
            }
        }
        const load_fast_ns = load_fast_timer.read();
        std.mem.doNotOptimizeAway(load_fast_accum_local);

        if (record) {
            load_generic_sum += load_generic_ns;
            load_fast_sum += load_fast_ns;
            if (load_generic_ns < load_generic_best) load_generic_best = load_generic_ns;
            if (load_fast_ns < load_fast_best) load_fast_best = load_fast_ns;
            load_generic_accum += load_generic_accum_local;
            load_fast_accum += load_fast_accum_local;
        }
    }

    const load_ops = @as(f64, @floatFromInt(@as(u64, tex_pixels * load_iterations)));
    const load_generic_avg = averageNs(load_generic_sum, measure_runs);
    const load_fast_avg = averageNs(load_fast_sum, measure_runs);
    const load_generic_ns_op = load_generic_avg / load_ops;
    const load_fast_ns_op = load_fast_avg / load_ops;
    std.debug.print(
        "compute.loadRGBA32F specialization: generic {d:.3} ns/op (best {d:.3}) | specialized {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x | accum {d:.3}/{d:.3}\n",
        .{
            load_generic_ns_op,
            @as(f64, @floatFromInt(load_generic_best)) / load_ops,
            load_fast_ns_op,
            @as(f64, @floatFromInt(load_fast_best)) / load_ops,
            load_generic_ns_op / load_fast_ns_op,
            load_generic_accum,
            load_fast_accum,
        },
    );

    const store_iterations: usize = 6;
    var store_generic_sum: u128 = 0;
    var store_generic_best: u64 = std.math.maxInt(u64);
    var store_fast_sum: u128 = 0;
    var store_fast_best: u64 = std.math.maxInt(u64);

    run_index = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        var store_generic_timer = try std.time.Timer.start();
        var iter: usize = 0;
        while (iter < store_iterations) : (iter += 1) {
            var y: u32 = 0;
            while (y < tex_height) : (y += 1) {
                var x: u32 = 0;
                while (x < tex_width) : (x += 1) {
                    const fx = @as(f32, @floatFromInt(x));
                    const fy = @as(f32, @floatFromInt(y));
                    compute.storeRGBA(&dst_generic_tex, x, y, .{
                        @sin(fx * 0.003 + fy * 0.002) * 0.5 + 0.5,
                        @sin(fx * 0.004 + fy * 0.007) * 0.5 + 0.5,
                        @sin(fx * 0.009 + fy * 0.005) * 0.5 + 0.5,
                        1.0,
                    });
                }
            }
        }
        const store_generic_ns = store_generic_timer.read();

        var store_fast_timer = try std.time.Timer.start();
        iter = 0;
        while (iter < store_iterations) : (iter += 1) {
            var y: u32 = 0;
            while (y < tex_height) : (y += 1) {
                var x: u32 = 0;
                while (x < tex_width) : (x += 1) {
                    const fx = @as(f32, @floatFromInt(x));
                    const fy = @as(f32, @floatFromInt(y));
                    compute.storeRGBA32F(&dst_fast_tex, x, y, .{
                        @sin(fx * 0.003 + fy * 0.002) * 0.5 + 0.5,
                        @sin(fx * 0.004 + fy * 0.007) * 0.5 + 0.5,
                        @sin(fx * 0.009 + fy * 0.005) * 0.5 + 0.5,
                        1.0,
                    });
                }
            }
        }
        const store_fast_ns = store_fast_timer.read();

        if (record) {
            store_generic_sum += store_generic_ns;
            store_fast_sum += store_fast_ns;
            if (store_generic_ns < store_generic_best) store_generic_best = store_generic_ns;
            if (store_fast_ns < store_fast_best) store_fast_best = store_fast_ns;
        }
    }

    const store_ops = @as(f64, @floatFromInt(@as(u64, tex_pixels * store_iterations)));
    const store_generic_avg = averageNs(store_generic_sum, measure_runs);
    const store_fast_avg = averageNs(store_fast_sum, measure_runs);
    const store_generic_ns_op = store_generic_avg / store_ops;
    const store_fast_ns_op = store_fast_avg / store_ops;
    const store_generic_checksum = checksumTextureRGBA32F(&dst_generic_tex);
    const store_fast_checksum = checksumTextureRGBA32F(&dst_fast_tex);
    std.debug.print(
        "compute.storeRGBA32F specialization: generic {d:.3} ns/op (best {d:.3}) | specialized {d:.3} ns/op (best {d:.3}) | speedup {d:.2}x | checksum {d:.3}/{d:.3}\n",
        .{
            store_generic_ns_op,
            @as(f64, @floatFromInt(store_generic_best)) / store_ops,
            store_fast_ns_op,
            @as(f64, @floatFromInt(store_fast_best)) / store_ops,
            store_generic_ns_op / store_fast_ns_op,
            store_generic_checksum,
            store_fast_checksum,
        },
    );

    // 14.1 mixed kernel-like path: loadRGBA + loadR + blend + storeRGBA.
    const depth_stride: u32 = tex_width * 4;
    const depth_bytes: usize = tex_pixels * 4;
    const depth_data = try allocator.alloc(u8, depth_bytes);
    defer allocator.free(depth_data);
    var depth_tex = RWTexture2D{
        .width = tex_width,
        .height = tex_height,
        .stride_bytes = depth_stride,
        .format = .r32f,
        .data = depth_data,
    };
    var depth_init_y: u32 = 0;
    while (depth_init_y < tex_height) : (depth_init_y += 1) {
        var depth_init_x: u32 = 0;
        while (depth_init_x < tex_width) : (depth_init_x += 1) {
            const fx = @as(f32, @floatFromInt(depth_init_x));
            const fy = @as(f32, @floatFromInt(depth_init_y));
            const d = @sin(fx * 0.0017 + fy * 0.0031) * 0.5 + 0.5;
            compute.storeR32F(&depth_tex, depth_init_x, depth_init_y, d);
        }
    }

    const mixed_generic_data = try allocator.alloc(u8, tex_bytes);
    defer allocator.free(mixed_generic_data);
    const mixed_fast_data = try allocator.alloc(u8, tex_bytes);
    defer allocator.free(mixed_fast_data);
    var mixed_generic_tex = RWTexture2D{
        .width = tex_width,
        .height = tex_height,
        .stride_bytes = tex_stride,
        .format = .rgba32f,
        .data = mixed_generic_data,
    };
    var mixed_fast_tex = RWTexture2D{
        .width = tex_width,
        .height = tex_height,
        .stride_bytes = tex_stride,
        .format = .rgba32f,
        .data = mixed_fast_data,
    };

    const mixed_iterations: usize = 6;
    var mixed_generic_sum: u128 = 0;
    var mixed_generic_best: u64 = std.math.maxInt(u64);
    var mixed_fast_sum: u128 = 0;
    var mixed_fast_best: u64 = std.math.maxInt(u64);

    run_index = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        var mixed_generic_timer = try std.time.Timer.start();
        var iter: usize = 0;
        while (iter < mixed_iterations) : (iter += 1) {
            var y: u32 = 0;
            while (y < tex_height) : (y += 1) {
                var x: u32 = 0;
                while (x < tex_width) : (x += 1) {
                    const c = compute.loadRGBA(&src_tex, x, y);
                    const d = compute.loadR(&depth_tex, x, y);
                    const out: [4]f32 = .{
                        c[0] * (0.7 + d * 0.3),
                        c[1] * (0.75 + d * 0.25),
                        c[2] * (0.8 + d * 0.2),
                        c[3],
                    };
                    compute.storeRGBA(&mixed_generic_tex, x, y, out);
                }
            }
        }
        const mixed_generic_ns = mixed_generic_timer.read();

        var mixed_fast_timer = try std.time.Timer.start();
        iter = 0;
        while (iter < mixed_iterations) : (iter += 1) {
            var y: u32 = 0;
            while (y < tex_height) : (y += 1) {
                var x: u32 = 0;
                while (x < tex_width) : (x += 1) {
                    const c = compute.loadRGBA32F(&src_tex, x, y);
                    const d = compute.loadR32F(&depth_tex, x, y);
                    const out: [4]f32 = .{
                        c[0] * (0.7 + d * 0.3),
                        c[1] * (0.75 + d * 0.25),
                        c[2] * (0.8 + d * 0.2),
                        c[3],
                    };
                    compute.storeRGBA32F(&mixed_fast_tex, x, y, out);
                }
            }
        }
        const mixed_fast_ns = mixed_fast_timer.read();

        if (record) {
            mixed_generic_sum += mixed_generic_ns;
            mixed_fast_sum += mixed_fast_ns;
            if (mixed_generic_ns < mixed_generic_best) mixed_generic_best = mixed_generic_ns;
            if (mixed_fast_ns < mixed_fast_best) mixed_fast_best = mixed_fast_ns;
        }
    }

    const mixed_ops = @as(f64, @floatFromInt(@as(u64, tex_pixels * mixed_iterations)));
    const mixed_generic_avg = averageNs(mixed_generic_sum, measure_runs);
    const mixed_fast_avg = averageNs(mixed_fast_sum, measure_runs);
    const mixed_generic_ns_px = mixed_generic_avg / mixed_ops;
    const mixed_fast_ns_px = mixed_fast_avg / mixed_ops;
    const mixed_generic_checksum = checksumTextureRGBA32F(&mixed_generic_tex);
    const mixed_fast_checksum = checksumTextureRGBA32F(&mixed_fast_tex);
    std.debug.print(
        "compute mixed path (load+depth+store): generic {d:.3} ns/pixel (best {d:.3}) | specialized {d:.3} ns/pixel (best {d:.3}) | speedup {d:.2}x | checksum {d:.3}/{d:.3}\n",
        .{
            mixed_generic_ns_px,
            @as(f64, @floatFromInt(mixed_generic_best)) / mixed_ops,
            mixed_fast_ns_px,
            @as(f64, @floatFromInt(mixed_fast_best)) / mixed_ops,
            mixed_generic_ns_px / mixed_fast_ns_px,
            mixed_generic_checksum,
            mixed_fast_checksum,
        },
    );

    // 14.x cache pass benchmark: depth-of-field row kernel index/layout optimizations.
    const dof_width: usize = 960;
    const dof_height: usize = 540;
    const dof_pixels = dof_width * dof_height;
    const dof_scene = try allocator.alloc(u32, dof_pixels);
    defer allocator.free(dof_scene);
    const dof_depth = try allocator.alloc(f32, dof_pixels);
    defer allocator.free(dof_depth);
    const dof_baseline_out = try allocator.alloc(u32, dof_pixels);
    defer allocator.free(dof_baseline_out);
    const dof_optimized_out = try allocator.alloc(u32, dof_pixels);
    defer allocator.free(dof_optimized_out);

    var dof_fill_y: usize = 0;
    while (dof_fill_y < dof_height) : (dof_fill_y += 1) {
        const row_start = dof_fill_y * dof_width;
        var dof_fill_x: usize = 0;
        while (dof_fill_x < dof_width) : (dof_fill_x += 1) {
            const idx = row_start + dof_fill_x;
            const fx = @as(f32, @floatFromInt(dof_fill_x));
            const fy = @as(f32, @floatFromInt(dof_fill_y));
            const r = @as(u32, @intFromFloat((@sin(fx * 0.011 + fy * 0.003) * 0.5 + 0.5) * 255.0));
            const g = @as(u32, @intFromFloat((@sin(fx * 0.007 + fy * 0.005) * 0.5 + 0.5) * 255.0));
            const b = @as(u32, @intFromFloat((@sin(fx * 0.005 + fy * 0.009) * 0.5 + 0.5) * 255.0));
            dof_scene[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
            dof_depth[idx] = @sin(fx * 0.0013 + fy * 0.0021) * 4.0 + 6.0;
        }
    }

    const dof_iterations: usize = 8;
    var dof_baseline_sum: u128 = 0;
    var dof_baseline_best: u64 = std.math.maxInt(u64);
    var dof_optimized_sum: u128 = 0;
    var dof_optimized_best: u64 = std.math.maxInt(u64);

    run_index = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        var dof_baseline_timer = try std.time.Timer.start();
        var iter: usize = 0;
        while (iter < dof_iterations) : (iter += 1) {
            dofApplyRowsBaseline(
                dof_scene,
                dof_baseline_out,
                dof_depth,
                dof_width,
                dof_height,
                0,
                dof_height,
                6.0,
                1.8,
                6,
            );
        }
        const dof_baseline_ns = dof_baseline_timer.read();

        var dof_optimized_timer = try std.time.Timer.start();
        iter = 0;
        while (iter < dof_iterations) : (iter += 1) {
            dofApplyRowsOptimized(
                dof_scene,
                dof_optimized_out,
                dof_depth,
                dof_width,
                dof_height,
                0,
                dof_height,
                6.0,
                1.8,
                6,
            );
        }
        const dof_optimized_ns = dof_optimized_timer.read();

        if (record) {
            dof_baseline_sum += dof_baseline_ns;
            dof_optimized_sum += dof_optimized_ns;
            if (dof_baseline_ns < dof_baseline_best) dof_baseline_best = dof_baseline_ns;
            if (dof_optimized_ns < dof_optimized_best) dof_optimized_best = dof_optimized_ns;
        }
    }

    const dof_ops = @as(f64, @floatFromInt(@as(u64, dof_pixels * dof_iterations)));
    const dof_baseline_avg = averageNs(dof_baseline_sum, measure_runs);
    const dof_optimized_avg = averageNs(dof_optimized_sum, measure_runs);
    const dof_baseline_ns_px = dof_baseline_avg / dof_ops;
    const dof_optimized_ns_px = dof_optimized_avg / dof_ops;
    const dof_baseline_checksum = checksumPixels(dof_baseline_out);
    const dof_optimized_checksum = checksumPixels(dof_optimized_out);
    std.debug.print(
        "depth_of_field.applyRows cache pass: baseline {d:.3} ns/pixel (best {d:.3}) | optimized {d:.3} ns/pixel (best {d:.3}) | speedup {d:.2}x | checksum 0x{X:0>16}/0x{X:0>16}\n",
        .{
            dof_baseline_ns_px,
            @as(f64, @floatFromInt(dof_baseline_best)) / dof_ops,
            dof_optimized_ns_px,
            @as(f64, @floatFromInt(dof_optimized_best)) / dof_ops,
            dof_baseline_ns_px / dof_optimized_ns_px,
            dof_baseline_checksum,
            dof_optimized_checksum,
        },
    );

    // 14.x cache pass benchmark: chromatic aberration row locality improvements.
    const chroma_width: usize = 1280;
    const chroma_height: usize = 720;
    const chroma_pixels = chroma_width * chroma_height;
    const chroma_src = try allocator.alloc(u32, chroma_pixels);
    defer allocator.free(chroma_src);
    const chroma_baseline_out = try allocator.alloc(u32, chroma_pixels);
    defer allocator.free(chroma_baseline_out);
    const chroma_optimized_out = try allocator.alloc(u32, chroma_pixels);
    defer allocator.free(chroma_optimized_out);

    var chroma_fill_y: usize = 0;
    while (chroma_fill_y < chroma_height) : (chroma_fill_y += 1) {
        const row_start = chroma_fill_y * chroma_width;
        var chroma_fill_x: usize = 0;
        while (chroma_fill_x < chroma_width) : (chroma_fill_x += 1) {
            const idx = row_start + chroma_fill_x;
            const fx = @as(f32, @floatFromInt(chroma_fill_x));
            const fy = @as(f32, @floatFromInt(chroma_fill_y));
            const r = @as(u32, @intFromFloat((@sin(fx * 0.017 + fy * 0.004) * 0.5 + 0.5) * 255.0));
            const g = @as(u32, @intFromFloat((@sin(fx * 0.010 + fy * 0.008) * 0.5 + 0.5) * 255.0));
            const b = @as(u32, @intFromFloat((@sin(fx * 0.006 + fy * 0.013) * 0.5 + 0.5) * 255.0));
            chroma_src[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
    }

    const chroma_iterations: usize = 12;
    var chroma_baseline_sum: u128 = 0;
    var chroma_baseline_best: u64 = std.math.maxInt(u64);
    var chroma_optimized_sum: u128 = 0;
    var chroma_optimized_best: u64 = std.math.maxInt(u64);

    run_index = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        var chroma_baseline_timer = try std.time.Timer.start();
        var iter: usize = 0;
        while (iter < chroma_iterations) : (iter += 1) {
            chromaticAberrationApplyRowsBaseline(
                chroma_src,
                chroma_baseline_out,
                0,
                chroma_height,
                chroma_width,
                chroma_height,
                6.0,
            );
        }
        const chroma_baseline_ns = chroma_baseline_timer.read();

        var chroma_optimized_timer = try std.time.Timer.start();
        iter = 0;
        while (iter < chroma_iterations) : (iter += 1) {
            chromatic_aberration_kernel.applyRows(
                chroma_src,
                chroma_optimized_out,
                0,
                chroma_height,
                chroma_width,
                chroma_height,
                6.0,
            );
        }
        const chroma_optimized_ns = chroma_optimized_timer.read();

        if (record) {
            chroma_baseline_sum += chroma_baseline_ns;
            chroma_optimized_sum += chroma_optimized_ns;
            if (chroma_baseline_ns < chroma_baseline_best) chroma_baseline_best = chroma_baseline_ns;
            if (chroma_optimized_ns < chroma_optimized_best) chroma_optimized_best = chroma_optimized_ns;
        }
    }

    const chroma_ops = @as(f64, @floatFromInt(@as(u64, chroma_pixels * chroma_iterations)));
    const chroma_baseline_avg = averageNs(chroma_baseline_sum, measure_runs);
    const chroma_optimized_avg = averageNs(chroma_optimized_sum, measure_runs);
    const chroma_baseline_ns_px = chroma_baseline_avg / chroma_ops;
    const chroma_optimized_ns_px = chroma_optimized_avg / chroma_ops;
    const chroma_baseline_checksum = checksumPixels(chroma_baseline_out);
    const chroma_optimized_checksum = checksumPixels(chroma_optimized_out);
    std.debug.print(
        "chromatic_aberration.applyRows cache pass: baseline {d:.3} ns/pixel (best {d:.3}) | optimized {d:.3} ns/pixel (best {d:.3}) | speedup {d:.2}x | checksum 0x{X:0>16}/0x{X:0>16}\n",
        .{
            chroma_baseline_ns_px,
            @as(f64, @floatFromInt(chroma_baseline_best)) / chroma_ops,
            chroma_optimized_ns_px,
            @as(f64, @floatFromInt(chroma_optimized_best)) / chroma_ops,
            chroma_baseline_ns_px / chroma_optimized_ns_px,
            chroma_baseline_checksum,
            chroma_optimized_checksum,
        },
    );

    // 14.3: baseline shadow raster loop vs optimized production kernel.
    const shadow_width: usize = 1024;
    const shadow_height: usize = 1024;
    const shadow_pixels = shadow_width * shadow_height;
    const baseline_depth = try allocator.alloc(f32, shadow_pixels);
    defer allocator.free(baseline_depth);
    const optimized_depth = try allocator.alloc(f32, shadow_pixels);
    defer allocator.free(optimized_depth);

    var baseline_shadow = RasterShadowMap{
        .width = shadow_width,
        .height = shadow_height,
        .inv_extent_x = 1.0 / 20.0,
        .inv_extent_y = 1.0 / 20.0,
        .min_x = -10.0,
        .max_x = 10.0,
        .min_y = -10.0,
        .max_y = 10.0,
        .depth = baseline_depth,
    };
    var optimized_shadow = RasterShadowMap{
        .width = shadow_width,
        .height = shadow_height,
        .inv_extent_x = 1.0 / 20.0,
        .inv_extent_y = 1.0 / 20.0,
        .min_x = -10.0,
        .max_x = 10.0,
        .min_y = -10.0,
        .max_y = 10.0,
        .depth = optimized_depth,
    };
    const rp0 = RasterPoint{ .x = -8.0, .y = -7.0, .z = 3.9 };
    const rp1 = RasterPoint{ .x = 8.0, .y = -6.5, .z = 5.6 };
    const rp2 = RasterPoint{ .x = 0.5, .y = 8.5, .z = 4.7 };
    const raster_iterations: usize = 200;

    var raster_baseline_sum: u128 = 0;
    var raster_baseline_best: u64 = std.math.maxInt(u64);
    var raster_optimized_sum: u128 = 0;
    var raster_optimized_best: u64 = std.math.maxInt(u64);

    run_index = 0;
    while (run_index < total_runs) : (run_index += 1) {
        const record = run_index >= warmup_runs;

        var baseline_timer = try std.time.Timer.start();
        var iter: usize = 0;
        while (iter < raster_iterations) : (iter += 1) {
            @memset(baseline_shadow.depth, std.math.inf(f32));
            rasterizeTriangleRowsBaseline(&baseline_shadow, 0, shadow_height, rp0, rp1, rp2);
        }
        const baseline_ns = baseline_timer.read();

        var optimized_timer = try std.time.Timer.start();
        iter = 0;
        while (iter < raster_iterations) : (iter += 1) {
            @memset(optimized_shadow.depth, std.math.inf(f32));
            shadow_raster_kernel.rasterizeTriangleRows(&optimized_shadow, 0, shadow_height, rp0, rp1, rp2);
        }
        const optimized_ns = optimized_timer.read();

        if (record) {
            raster_baseline_sum += baseline_ns;
            raster_optimized_sum += optimized_ns;
            if (baseline_ns < raster_baseline_best) raster_baseline_best = baseline_ns;
            if (optimized_ns < raster_optimized_best) raster_optimized_best = optimized_ns;
        }
    }

    const raster_baseline_avg = averageNs(raster_baseline_sum, measure_runs);
    const raster_optimized_avg = averageNs(raster_optimized_sum, measure_runs);
    const raster_baseline_checksum = checksumDepth(baseline_shadow.depth);
    const raster_optimized_checksum = checksumDepth(optimized_shadow.depth);
    std.debug.print(
        "shadow_raster inner-loop rewrite: baseline avg {d:.3} ns (best {d:.3}) | optimized avg {d:.3} ns (best {d:.3}) | speedup {d:.2}x | checksum {d:.6}/{d:.6}\n",
        .{
            raster_baseline_avg,
            @as(f64, @floatFromInt(raster_baseline_best)),
            raster_optimized_avg,
            @as(f64, @floatFromInt(raster_optimized_best)),
            raster_baseline_avg / raster_optimized_avg,
            raster_baseline_checksum,
            raster_optimized_checksum,
        },
    );
}
