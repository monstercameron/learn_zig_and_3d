const std = @import("std");
const engine_bench = @import("engine_bench");
const math = engine_bench.math;
const config = engine_bench.app_config;
const texture = engine_bench.texture;
const lighting = engine_bench.lighting;
const shadow_system = engine_bench.shadow_system;
const tile_renderer = engine_bench.tile_renderer;
const hybrid_shadow_cache_kernel = engine_bench.hybrid_shadow_cache_kernel;
const job_system = engine_bench.job_system;

const WarmupRuns: usize = 1;
const MeasureRuns: usize = 7;
const TotalRuns: usize = WarmupRuns + MeasureRuns;

const RasterCase = struct {
    name: []const u8,
    p0: math.Vec2,
    p1: math.Vec2,
    p2: math.Vec2,
};

fn averageNs(sum: u128, runs: usize) f64 {
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(runs));
}

fn lcgNext(state: *u64) u32 {
    state.* = state.* *% 6364136223846793005 +% 1;
    return @as(u32, @truncate(state.* >> 32));
}

fn lcgFloat01(state: *u64) f32 {
    const u = lcgNext(state);
    return @as(f32, @floatFromInt(u)) / 4294967295.0;
}

fn makeMaskWithPopcount(target_count: usize, seed: u64) u64 {
    if (target_count == 0) return 0;
    if (target_count >= 64) return std.math.maxInt(u64);

    var state = seed;
    var mask: u64 = 0;
    while (@as(usize, @intCast(@popCount(mask))) < target_count) {
        const bit = @as(u6, @intCast(lcgNext(&state) % 64));
        mask |= (@as(u64, 1) << bit);
    }
    return mask;
}

fn runRasterBench(allocator: std.mem.Allocator) !void {
    const tile = tile_renderer.Tile.init(0, 0, tile_renderer.TILE_SIZE, tile_renderer.TILE_SIZE, 0);
    var tile_buffer = try tile_renderer.TileBuffer.init(tile.width, tile.height, allocator);
    defer tile_buffer.deinit();

    const camera_positions = [3]math.Vec3{
        math.Vec3.new(-0.2, -0.2, 2.0),
        math.Vec3.new(0.3, -0.1, 2.2),
        math.Vec3.new(-0.1, 0.4, 2.4),
    };
    const depths = [3]f32{ 2.0, 2.2, 2.4 };
    const iterations_per_run: usize = 1800;

    const raster_cases = [_]RasterCase{
        .{
            .name = "small",
            .p0 = math.Vec2.new(28.0, 28.0),
            .p1 = math.Vec2.new(36.0, 29.0),
            .p2 = math.Vec2.new(30.0, 36.0),
        },
        .{
            .name = "medium",
            .p0 = math.Vec2.new(12.0, 10.0),
            .p1 = math.Vec2.new(52.0, 16.0),
            .p2 = math.Vec2.new(20.0, 54.0),
        },
        .{
            .name = "full_tile",
            .p0 = math.Vec2.new(1.0, 1.0),
            .p1 = math.Vec2.new(62.0, 4.0),
            .p2 = math.Vec2.new(4.0, 62.0),
        },
    };

    const modes = [_]struct {
        name: []const u8,
        base_color: u32,
        use_stats: bool,
    }{
        .{ .name = "opaque_no_stats", .base_color = 0xFFFFA040, .use_stats = false },
        .{ .name = "opaque_with_stats", .base_color = 0xFFFFA040, .use_stats = true },
        .{ .name = "alpha_with_stats", .base_color = 0x80FFA040, .use_stats = true },
    };

    std.debug.print("\n[phase15] rasterizeTriangleToTile\n", .{});
    std.debug.print("  warmup={} measure={} iter={}\n", .{ WarmupRuns, MeasureRuns, iterations_per_run });
    for (raster_cases) |raster_case| {
        for (modes) |mode| {
            var elapsed_sum_ns: u128 = 0;
            var elapsed_best_ns: u64 = std.math.maxInt(u64);
            var stats_total: tile_renderer.RasterizePerfStats = .{};

            var run_index: usize = 0;
            while (run_index < TotalRuns) : (run_index += 1) {
                const record = run_index >= WarmupRuns;
                var run_stats: tile_renderer.RasterizePerfStats = .{};
                var timer = try std.time.Timer.start();

                var iter: usize = 0;
                while (iter < iterations_per_run) : (iter += 1) {
                    @memset(tile_buffer.depth, std.math.inf(f32));
                    const shading = tile_renderer.ShadingParams{
                        .base_color = mode.base_color,
                        .texture = null,
                        .uv0 = math.Vec2.new(0.0, 0.0),
                        .uv1 = math.Vec2.new(1.0, 0.0),
                        .uv2 = math.Vec2.new(0.0, 1.0),
                        .surface_bary0 = math.Vec3.new(1.0, 0.0, 0.0),
                        .surface_bary1 = math.Vec3.new(0.0, 1.0, 0.0),
                        .surface_bary2 = math.Vec3.new(0.0, 0.0, 1.0),
                        .triangle_id = 17,
                        .meshlet_id = 3,
                        .intensity = 1.0,
                        .normals = [3]math.Vec3{
                            math.Vec3.new(0.0, 0.0, -1.0),
                            math.Vec3.new(0.0, 0.0, -1.0),
                            math.Vec3.new(0.0, 0.0, -1.0),
                        },
                        .metallic = 0.0,
                        .roughness = 0.85,
                    };
                    tile_renderer.rasterizeTriangleToTile(
                        &tile,
                        &tile_buffer,
                        raster_case.p0,
                        raster_case.p1,
                        raster_case.p2,
                        camera_positions,
                        depths,
                        shading,
                        if (mode.use_stats) &run_stats else null,
                    );
                }

                const elapsed_ns = timer.read();
                if (record) {
                    elapsed_sum_ns += elapsed_ns;
                    if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
                    if (mode.use_stats) {
                        stats_total.triangles_rasterized += run_stats.triangles_rasterized;
                        stats_total.covered_pixels += run_stats.covered_pixels;
                        stats_total.depth_tests_passed += run_stats.depth_tests_passed;
                        stats_total.alpha_pixels += run_stats.alpha_pixels;
                    }
                }
            }

            const avg_ns = averageNs(elapsed_sum_ns, MeasureRuns);
            const avg_ns_tri = avg_ns / @as(f64, @floatFromInt(iterations_per_run));
            const best_ns_tri = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations_per_run));
            std.debug.print("  - {s}/{s}: avg {d:.3} ns/tri (best {d:.3})", .{ raster_case.name, mode.name, avg_ns_tri, best_ns_tri });
            if (mode.use_stats) {
                const tri_count = @max(@as(f64, 1.0), @as(f64, @floatFromInt(stats_total.triangles_rasterized)));
                std.debug.print(
                    " | covered/tri {d:.2} depth_pass/tri {d:.2} alpha/tri {d:.2}\n",
                    .{
                        @as(f64, @floatFromInt(stats_total.covered_pixels)) / tri_count,
                        @as(f64, @floatFromInt(stats_total.depth_tests_passed)) / tri_count,
                        @as(f64, @floatFromInt(stats_total.alpha_pixels)) / tri_count,
                    },
                );
            } else {
                std.debug.print("\n", .{});
            }
        }
    }
}

fn desiredShadowChunks(total_pixels: usize, tri_cost: usize, light_cost: usize, worker_count: usize) usize {
    const shadow_chunk_pixels: usize = 2048;
    const shadow_min_chunk_pixels: usize = 1024;
    const shadow_split_tri_threshold: usize = 96;
    const high_parallelism = worker_count > 4;
    const runtime_shadow_min_chunk_pixels: usize = if (high_parallelism) @max(@as(usize, 512), @divTrunc(shadow_min_chunk_pixels, 2)) else shadow_min_chunk_pixels;
    const shadow_max_chunks_per_tile: usize = if (high_parallelism) 16 else 8;

    const tri_weight = @max(@as(usize, 1), @divTrunc(tri_cost + shadow_split_tri_threshold - 1, shadow_split_tri_threshold));
    const effective_light_cost = @max(@as(usize, 1), light_cost);
    const estimated_work_units = total_pixels * tri_weight * effective_light_cost;
    const target_work_units = shadow_chunk_pixels * 2;
    const desired_chunks_by_work = @max(@as(usize, 1), @divTrunc(estimated_work_units + target_work_units - 1, target_work_units));
    const desired_chunks_by_pixels = @max(@as(usize, 1), @divTrunc(total_pixels + shadow_chunk_pixels - 1, shadow_chunk_pixels));
    const max_chunks = @max(@as(usize, 1), @min(shadow_max_chunks_per_tile, worker_count * 2));
    const should_split = worker_count > 2 and total_pixels >= runtime_shadow_min_chunk_pixels and tri_cost >= @divTrunc(shadow_split_tri_threshold, 2);
    const desired_chunks_base: usize = if (should_split) @min(max_chunks, @max(desired_chunks_by_work, desired_chunks_by_pixels)) else 1;
    return if (high_parallelism and should_split) @min(max_chunks, desired_chunks_base * 2) else desired_chunks_base;
}

fn runShadowChunkPlannerBench() !void {
    const decisions: usize = 600_000;
    var rng: u64 = 0xC0DEC0DE;
    var elapsed_sum_ns: u128 = 0;
    var elapsed_best_ns: u64 = std.math.maxInt(u64);
    var checksum: usize = 0;

    std.debug.print("\n[phase15] shadow chunk planner\n", .{});
    std.debug.print("  warmup={} measure={} decisions={}\n", .{ WarmupRuns, MeasureRuns, decisions });

    var run_index: usize = 0;
    while (run_index < TotalRuns) : (run_index += 1) {
        const record = run_index >= WarmupRuns;
        var timer = try std.time.Timer.start();
        var local_checksum: usize = 0;
        var i: usize = 0;
        while (i < decisions) : (i += 1) {
            const pixels = 256 + @as(usize, lcgNext(&rng) % 4096);
            const tris = @as(usize, lcgNext(&rng) % 420);
            const lights = 1 + @as(usize, lcgNext(&rng) % 8);
            const workers = 1 + @as(usize, lcgNext(&rng) % 16);
            local_checksum +%= desiredShadowChunks(pixels, tris, lights, workers);
        }
        const elapsed_ns = timer.read();
        if (record) {
            elapsed_sum_ns += elapsed_ns;
            if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
            checksum +%= local_checksum;
        }
    }

    const avg_ns = averageNs(elapsed_sum_ns, MeasureRuns);
    const ns_per_decision = avg_ns / @as(f64, @floatFromInt(decisions));
    const best_per_decision = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(decisions));
    std.debug.print("  - avg {d:.3} ns/decision (best {d:.3}) | checksum={}\n", .{ ns_per_decision, best_per_decision, checksum });
}

fn runShadowApplyBench(allocator: std.mem.Allocator) !void {
    const pixel_count: usize = 64 * 64;
    var colors = try allocator.alloc(math.Vec4, pixel_count);
    defer allocator.free(colors);
    const base_color = math.Vec4.new(1.0, 0.9, 0.8, 1.0);
    @memset(colors, base_color);

    const iterations: usize = 3200;
    const masks = [_]struct {
        name: []const u8,
        mask: u64,
    }{
        .{ .name = "occl_0pct", .mask = 0x0000000000000000 },
        .{ .name = "occl_25pct", .mask = 0x1111111111111111 },
        .{ .name = "occl_50pct", .mask = 0x5555555555555555 },
        .{ .name = "occl_100pct", .mask = 0xFFFFFFFFFFFFFFFF },
    };

    std.debug.print("\n[phase15] shadow apply loop\n", .{});
    std.debug.print("  warmup={} measure={} iter={} batch=64\n", .{ WarmupRuns, MeasureRuns, iterations });

    for (masks) |entry| {
        const modes = [_]enum { scan, bitwalk, auto }{ .scan, .bitwalk, .auto };
        for (modes) |mode| {
            var elapsed_sum_ns: u128 = 0;
            var elapsed_best_ns: u64 = std.math.maxInt(u64);
            var checksum: f64 = 0.0;

            var run_index: usize = 0;
            while (run_index < TotalRuns) : (run_index += 1) {
                const record = run_index >= WarmupRuns;
                @memset(colors, base_color);
                var timer = try std.time.Timer.start();
                var local_checksum: f64 = 0.0;

                var it: usize = 0;
                while (it < iterations) : (it += 1) {
                    var base: usize = 0;
                    while (base < pixel_count) : (base += 64) {
                        const batch = @min(@as(usize, 64), pixel_count - base);
                        switch (mode) {
                            .scan => {
                                var lane: usize = 0;
                                while (lane < batch) : (lane += 1) {
                                    if ((entry.mask & (@as(u64, 1) << @as(u6, @intCast(lane)))) == 0) continue;
                                    colors[base + lane].x *= 0.2;
                                    colors[base + lane].y *= 0.2;
                                    colors[base + lane].z *= 0.2;
                                }
                            },
                            .bitwalk => {
                                const batch_mask: u64 = if (batch == 64) std.math.maxInt(u64) else ((@as(u64, 1) << @intCast(batch)) - 1);
                                var pending = entry.mask & batch_mask;
                                while (pending != 0) {
                                    const lane = @as(usize, @intCast(@ctz(pending)));
                                    pending &= pending - 1;
                                    colors[base + lane].x *= 0.2;
                                    colors[base + lane].y *= 0.2;
                                    colors[base + lane].z *= 0.2;
                                }
                            },
                            .auto => {
                                const batch_mask: u64 = if (batch == 64) std.math.maxInt(u64) else ((@as(u64, 1) << @intCast(batch)) - 1);
                                const occluded_mask = entry.mask & batch_mask;
                                if (occluded_mask == batch_mask) {
                                    for (0..batch) |lane| {
                                        colors[base + lane].x *= 0.2;
                                        colors[base + lane].y *= 0.2;
                                        colors[base + lane].z *= 0.2;
                                    }
                                } else if (@as(usize, @intCast(@popCount(occluded_mask))) >= 48) {
                                    var lane: usize = 0;
                                    while (lane < batch) : (lane += 1) {
                                        if ((occluded_mask & (@as(u64, 1) << @as(u6, @intCast(lane)))) == 0) continue;
                                        colors[base + lane].x *= 0.2;
                                        colors[base + lane].y *= 0.2;
                                        colors[base + lane].z *= 0.2;
                                    }
                                } else {
                                    var pending = occluded_mask;
                                    while (pending != 0) {
                                        const lane = @as(usize, @intCast(@ctz(pending)));
                                        pending &= pending - 1;
                                        colors[base + lane].x *= 0.2;
                                        colors[base + lane].y *= 0.2;
                                        colors[base + lane].z *= 0.2;
                                    }
                                }
                            },
                        }
                    }
                }

                for (colors[0..@min(@as(usize, 64), colors.len)]) |c| {
                    local_checksum += c.x + c.y + c.z;
                }
                std.mem.doNotOptimizeAway(local_checksum);
                const elapsed_ns = timer.read();
                if (record) {
                    elapsed_sum_ns += elapsed_ns;
                    if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
                    checksum += local_checksum;
                }
            }

            const mode_name = switch (mode) {
                .scan => "scan",
                .bitwalk => "bitwalk",
                .auto => "auto",
            };
            const ops = @as(f64, @floatFromInt(iterations * pixel_count));
            std.debug.print(
                "  - {s}/{s}: avg {d:.3} ns/pixel (best {d:.3}) | checksum {d:.3}\n",
                .{
                    entry.name,
                    mode_name,
                    averageNs(elapsed_sum_ns, MeasureRuns) / ops,
                    @as(f64, @floatFromInt(elapsed_best_ns)) / ops,
                    checksum,
                },
            );
        }
    }
}

fn runShadowApplyThresholdSweepBench(allocator: std.mem.Allocator) !void {
    const pixel_count: usize = 64 * 64;
    const iterations: usize = 2600;
    const target_counts = [_]usize{ 0, 8, 16, 24, 32, 40, 48, 56, 64 };
    const thresholds = [_]usize{ 48, 52, 56, 60, 64 };
    const base_color = math.Vec4.new(1.0, 0.9, 0.8, 1.0);

    var colors = try allocator.alloc(math.Vec4, pixel_count);
    defer allocator.free(colors);

    var masks: [target_counts.len]u64 = undefined;
    for (target_counts, 0..) |count, idx| {
        masks[idx] = makeMaskWithPopcount(count, 0xBAD5EED + idx * 17);
    }

    std.debug.print("\n[phase15] shadow apply threshold sweep\n", .{});
    std.debug.print("  warmup={} measure={} iter={} batch=64\n", .{ WarmupRuns, MeasureRuns, iterations });

    for (thresholds) |threshold| {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);
        var checksum: f64 = 0.0;

        var run_index: usize = 0;
        while (run_index < TotalRuns) : (run_index += 1) {
            const record = run_index >= WarmupRuns;
            @memset(colors, base_color);
            var local_checksum: f64 = 0.0;
            var timer = try std.time.Timer.start();

            for (masks) |mask| {
                var it: usize = 0;
                while (it < iterations) : (it += 1) {
                    var base: usize = 0;
                    while (base < pixel_count) : (base += 64) {
                        const batch = @min(@as(usize, 64), pixel_count - base);
                        const batch_mask: u64 = if (batch == 64) std.math.maxInt(u64) else ((@as(u64, 1) << @intCast(batch)) - 1);
                        const occluded_mask = mask & batch_mask;

                        if (occluded_mask == batch_mask) {
                            for (0..batch) |lane| {
                                colors[base + lane].x *= 0.2;
                                colors[base + lane].y *= 0.2;
                                colors[base + lane].z *= 0.2;
                            }
                        } else if (@as(usize, @intCast(@popCount(occluded_mask))) >= threshold) {
                            var lane: usize = 0;
                            while (lane < batch) : (lane += 1) {
                                if ((occluded_mask & (@as(u64, 1) << @as(u6, @intCast(lane)))) == 0) continue;
                                colors[base + lane].x *= 0.2;
                                colors[base + lane].y *= 0.2;
                                colors[base + lane].z *= 0.2;
                            }
                        } else {
                            var pending = occluded_mask;
                            while (pending != 0) {
                                const lane = @as(usize, @intCast(@ctz(pending)));
                                pending &= pending - 1;
                                colors[base + lane].x *= 0.2;
                                colors[base + lane].y *= 0.2;
                                colors[base + lane].z *= 0.2;
                            }
                        }
                    }
                }
            }

            for (colors[0..@min(@as(usize, 64), colors.len)]) |c| {
                local_checksum += c.x + c.y + c.z;
            }
            std.mem.doNotOptimizeAway(local_checksum);
            const elapsed_ns = timer.read();
            if (record) {
                elapsed_sum_ns += elapsed_ns;
                if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
                checksum += local_checksum;
            }
        }

        const ops = @as(f64, @floatFromInt(iterations * pixel_count * masks.len));
        std.debug.print(
            "  - threshold={}: avg {d:.3} ns/pixel (best {d:.3}) | checksum {d:.3}\n",
            .{
                threshold,
                averageNs(elapsed_sum_ns, MeasureRuns) / ops,
                @as(f64, @floatFromInt(elapsed_best_ns)) / ops,
                checksum,
            },
        );
    }
}

fn makeSyntheticTrianglePacket(packet_idx: usize, lane_count: usize) shadow_system.ShadowTrianglePacket {
    var packet: shadow_system.ShadowTrianglePacket = .{
        .v0x = @splat(0.0),
        .v0y = @splat(0.0),
        .v0z = @splat(0.0),
        .edge1_x = @splat(0.0),
        .edge1_y = @splat(0.0),
        .edge1_z = @splat(0.0),
        .edge2_x = @splat(0.0),
        .edge2_y = @splat(0.0),
        .edge2_z = @splat(0.0),
        .source_triangle_ids = @splat(std.math.maxInt(u32)),
        .active_mask = @splat(false),
        .active_lane_mask = 0,
    };

    var lane: usize = 0;
    while (lane < lane_count and lane < 8) : (lane += 1) {
        const fx = -1.1 + @as(f32, @floatFromInt(lane % 4)) * 0.02;
        const fy = -1.1 + @as(f32, @floatFromInt(lane / 4)) * 0.02;
        const jitter = @as(f32, @floatFromInt(packet_idx)) * 0.002;
        packet.v0x[lane] = fx + jitter;
        packet.v0y[lane] = fy - jitter;
        packet.v0z[lane] = 0.0;
        packet.edge1_x[lane] = 2.2;
        packet.edge1_y[lane] = 0.0;
        packet.edge1_z[lane] = 0.0;
        packet.edge2_x[lane] = 0.0;
        packet.edge2_y[lane] = 2.2;
        packet.edge2_z[lane] = 0.0;
        packet.source_triangle_ids[lane] = @as(u32, @intCast(packet_idx * 8 + lane));
        packet.active_mask[lane] = true;
        packet.active_lane_mask |= (@as(u8, 1) << @as(u3, @intCast(lane)));
    }
    return packet;
}

fn buildSyntheticShadowSystem(allocator: std.mem.Allocator, triangle_packet_count: usize) !shadow_system.ShadowSystem {
    var sys = shadow_system.ShadowSystem.init(allocator);
    errdefer sys.deinit();

    const scene_aabb = shadow_system.AABB{
        .min = math.Vec3.new(-2.0, -2.0, -0.5),
        .max = math.Vec3.new(2.0, 2.0, 0.5),
    };

    try sys.tlas_nodes.append(allocator, .{
        .aabb = scene_aabb,
        .left_child_or_instance = 0,
        .right_child_or_count = 1,
        .is_leaf = true,
    });
    try sys.blas_nodes.append(allocator, .{
        .aabb = scene_aabb,
        .left_child_or_meshlet = 0,
        .right_child_or_count = 1,
        .is_leaf = true,
    });

    var packet_idx: usize = 0;
    while (packet_idx < triangle_packet_count) : (packet_idx += 1) {
        try sys.shadow_triangle_packets.append(allocator, makeSyntheticTrianglePacket(packet_idx, 8));
    }

    try sys.shadow_meshlets.append(allocator, .{
        .bound_sphere = .{
            .center = math.Vec3.new(0.0, 0.0, 0.0),
            .radius = 3.0,
        },
        .bound_aabb = scene_aabb,
        .normal_cone_axis = math.Vec3.new(0.0, 0.0, 1.0),
        .normal_cone_cutoff = -1.0,
        .normal_cone_sine = 0.0,
        .triangle_offset = 0,
        .triangle_count = @as(u16, @intCast(@min(triangle_packet_count * 8, @as(usize, std.math.maxInt(u16))))),
        .triangle_packet_offset = 0,
        .triangle_packet_count = @as(u16, @intCast(@min(triangle_packet_count, @as(usize, std.math.maxInt(u16))))),
        .micro_bvh_offset = 0,
    });

    return sys;
}

fn initSyntheticRayPacket(active_lanes: usize) shadow_system.RayPacket {
    var packet = shadow_system.RayPacket{
        .origins_x = undefined,
        .origins_y = undefined,
        .origins_z = undefined,
        .shared_dir = math.Vec3.new(0.0, 0.0, 1.0),
        .shared_inv_dir = math.Vec3.new(1e6, 1e6, 1.0),
        .skip_triangle_ids = undefined,
        .active_mask = if (active_lanes >= 64) std.math.maxInt(u64) else ((@as(u64, 1) << @as(u6, @intCast(active_lanes))) - 1),
        .occluded_mask = 0,
    };

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const x = (@as(f32, @floatFromInt(i % 8)) - 3.5) * 0.18;
        const y = (@as(f32, @floatFromInt(@divTrunc(i, 8))) - 3.5) * 0.18;
        packet.origins_x[i] = x;
        packet.origins_y[i] = y;
        packet.origins_z[i] = -1.0;
        packet.skip_triangle_ids[i] = std.math.maxInt(u32);
    }
    return packet;
}

fn runShadowTraceBench(allocator: std.mem.Allocator) !void {
    const active_lane_cases = [_]usize{ 1, 4, 8, 16, 32, 64 };
    const triangle_packet_cases = [_]usize{ 1, 4, 8, 16 };
    const iterations: usize = 6500;

    std.debug.print("\n[phase15] shadow trace traversal\n", .{});
    std.debug.print("  warmup={} measure={} iter={}\n", .{ WarmupRuns, MeasureRuns, iterations });

    for (triangle_packet_cases) |triangle_packet_count| {
        var sys = try buildSyntheticShadowSystem(allocator, triangle_packet_count);
        defer sys.deinit();

        for (active_lane_cases) |active_lanes| {
            var packet = initSyntheticRayPacket(active_lanes);
            var elapsed_sum_ns: u128 = 0;
            var elapsed_best_ns: u64 = std.math.maxInt(u64);
            var checksum: u64 = 0;

            var run_index: usize = 0;
            while (run_index < TotalRuns) : (run_index += 1) {
                const record = run_index >= WarmupRuns;
                var local_checksum: u64 = 0;
                var timer = try std.time.Timer.start();
                var it: usize = 0;
                while (it < iterations) : (it += 1) {
                    packet.occluded_mask = 0;
                    sys.tracePacketAnyHit(&packet);
                    local_checksum +%= @as(u64, @intCast(@popCount(packet.occluded_mask)));
                }
                const elapsed_ns = timer.read();
                if (record) {
                    elapsed_sum_ns += elapsed_ns;
                    if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
                    checksum +%= local_checksum;
                }
            }

            const avg_ns = averageNs(elapsed_sum_ns, MeasureRuns);
            const avg_ns_trace = avg_ns / @as(f64, @floatFromInt(iterations));
            const best_ns_trace = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations));
            std.debug.print(
                "  - packets={} active_lanes={}: avg {d:.3} ns/trace (best {d:.3}) | checksum={}\n",
                .{ triangle_packet_count, active_lanes, avg_ns_trace, best_ns_trace, checksum },
            );
        }
    }
}

const TinyJobCtx = struct {
    counter: *std.atomic.Value(u64),
};

fn tinyJob(ctx_ptr: *anyopaque) void {
    const ctx: *TinyJobCtx = @ptrCast(@alignCast(ctx_ptr));
    _ = ctx.counter.fetchAdd(1, .monotonic);
}

fn noopJob(_: *anyopaque) void {}

fn runTinyJobBench(allocator: std.mem.Allocator) !void {
    var js = try job_system.JobSystem.init(allocator);
    defer js.deinit();

    const job_count: usize = 12_000;
    var jobs = try allocator.alloc(job_system.Job, job_count);
    defer allocator.free(jobs);
    var contexts = try allocator.alloc(TinyJobCtx, job_count);
    defer allocator.free(contexts);
    var counter = std.atomic.Value(u64).init(0);

    std.debug.print("\n[phase15] job system tiny jobs\n", .{});
    std.debug.print("  workers={} warmup={} measure={} jobs/run={}\n", .{ js.worker_count, WarmupRuns, MeasureRuns, job_count });

    var elapsed_sum_ns: u128 = 0;
    var elapsed_best_ns: u64 = std.math.maxInt(u64);
    var run_index: usize = 0;
    while (run_index < TotalRuns) : (run_index += 1) {
        const record = run_index >= WarmupRuns;
        counter.store(0, .release);
        var parent = job_system.Job.init(noopJob, undefined, null);

        var timer = try std.time.Timer.start();
        for (0..job_count) |i| {
            contexts[i] = .{ .counter = &counter };
            jobs[i] = job_system.Job.init(tinyJob, @ptrCast(&contexts[i]), &parent);
            if (!js.submitJobAuto(&jobs[i])) {
                jobs[i].execute();
            }
        }
        parent.complete();
        parent.wait();
        const elapsed_ns = timer.read();

        if (record) {
            elapsed_sum_ns += elapsed_ns;
            if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
        }
    }

    const total_jobs = @as(f64, @floatFromInt(job_count));
    const avg_ns = averageNs(elapsed_sum_ns, MeasureRuns);
    std.debug.print(
        "  - avg {d:.3} ns/job (best {d:.3}) | throughput {d:.2} Mjobs/s | completed={}\n",
        .{
            avg_ns / total_jobs,
            @as(f64, @floatFromInt(elapsed_best_ns)) / total_jobs,
            (total_jobs / avg_ns) * 1000.0,
            counter.load(.acquire),
        },
    );
}

fn runTonemapPackBench(allocator: std.mem.Allocator) !void {
    const width: usize = 1280;
    const height: usize = 720;
    const pixels = width * height;
    const hdr = try allocator.alloc(math.Vec3, pixels);
    defer allocator.free(hdr);
    var out = try allocator.alloc(u32, pixels);
    defer allocator.free(out);

    var rng: u64 = 0x123456789ABCDEF0;
    for (hdr) |*v| {
        v.* = math.Vec3.new(
            lcgFloat01(&rng) * 4.0,
            lcgFloat01(&rng) * 4.0,
            lcgFloat01(&rng) * 4.0,
        );
    }

    const iterations: usize = 24;
    var elapsed_sum_ns: u128 = 0;
    var elapsed_best_ns: u64 = std.math.maxInt(u64);
    var checksum: u64 = 0;

    std.debug.print("\n[phase15] tonemap pack\n", .{});
    std.debug.print("  warmup={} measure={} pixels={} iter={}\n", .{ WarmupRuns, MeasureRuns, pixels, iterations });

    var run_index: usize = 0;
    while (run_index < TotalRuns) : (run_index += 1) {
        const record = run_index >= WarmupRuns;
        var timer = try std.time.Timer.start();
        var local_checksum: u64 = 0;
        var it: usize = 0;
            while (it < iterations) : (it += 1) {
                for (hdr, 0..) |c, i| {
                    const packed_color = lighting.packColorTonemapped(c, 255);
                    out[i] = packed_color;
                    local_checksum +%= packed_color;
                }
            }
        const elapsed_ns = timer.read();
        if (record) {
            elapsed_sum_ns += elapsed_ns;
            if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
            checksum +%= local_checksum;
        }
    }

    const ops = @as(f64, @floatFromInt(pixels * iterations));
    std.debug.print(
        "  - avg {d:.3} ns/pixel (best {d:.3}) | checksum={}\n",
        .{
            averageNs(elapsed_sum_ns, MeasureRuns) / ops,
            @as(f64, @floatFromInt(elapsed_best_ns)) / ops,
            checksum,
        },
    );
}

fn runTextureBilinearBench(allocator: std.mem.Allocator) !void {
    config.TEXTURE_FILTERING_BILINEAR = true;

    const w: usize = 1024;
    const h: usize = 1024;
    const pixel_count = w * h;
    const pixels = try allocator.alloc(u32, pixel_count);
    var rng: u64 = 0xF00DFACE;
    for (pixels) |*p| {
        p.* = lcgNext(&rng);
    }
    var tex = texture.Texture{
        .width = w,
        .height = h,
        .pixels = pixels,
        .mip_levels = .{},
        .allocator = allocator,
    };
    defer tex.deinit();

    const uv_count: usize = 4096;
    var coherent_uvs = try allocator.alloc(math.Vec2, uv_count);
    defer allocator.free(coherent_uvs);
    var random_uvs = try allocator.alloc(math.Vec2, uv_count);
    defer allocator.free(random_uvs);
    var out = try allocator.alloc(u32, uv_count);
    defer allocator.free(out);

    var i: usize = 0;
    while (i < uv_count) : (i += 1) {
        const x = @as(f32, @floatFromInt(i % 64)) / 63.0;
        const y = @as(f32, @floatFromInt(i / 64)) / 63.0;
        coherent_uvs[i] = math.Vec2.new(x, y);
        random_uvs[i] = math.Vec2.new(lcgFloat01(&rng), lcgFloat01(&rng));
    }

    const iterations: usize = 700;
    std.debug.print("\n[phase15] texture bilinear cache behavior\n", .{});
    std.debug.print("  warmup={} measure={} uv_count={} iter={}\n", .{ WarmupRuns, MeasureRuns, uv_count, iterations });

    const cases = [_]struct {
        name: []const u8,
        uvs: []const math.Vec2,
    }{
        .{ .name = "coherent_uvs", .uvs = coherent_uvs },
        .{ .name = "random_uvs", .uvs = random_uvs },
    };

    for (cases) |entry| {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);
        var checksum: u64 = 0;

        var run_index: usize = 0;
        while (run_index < TotalRuns) : (run_index += 1) {
            const record = run_index >= WarmupRuns;
            var timer = try std.time.Timer.start();
            var local_checksum: u64 = 0;
            var it: usize = 0;
            while (it < iterations) : (it += 1) {
                tex.sampleLodBatch(entry.uvs, 0.0, out);
                for (out[0..64]) |v| local_checksum +%= v;
            }
            const elapsed_ns = timer.read();
            if (record) {
                elapsed_sum_ns += elapsed_ns;
                if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
                checksum +%= local_checksum;
            }
        }

        const ops = @as(f64, @floatFromInt(uv_count * iterations));
        std.debug.print(
            "  - {s}: avg {d:.3} ns/sample (best {d:.3}) | checksum={}\n",
            .{
                entry.name,
                averageNs(elapsed_sum_ns, MeasureRuns) / ops,
                @as(f64, @floatFromInt(elapsed_best_ns)) / ops,
                checksum,
            },
        );
    }
}

fn runCacheStrategyBench(allocator: std.mem.Allocator) !void {
    const cache_cells: usize = 1280 * 720;
    const touches_per_frame: usize = 16_384;
    const frames: usize = 140;

    var cache = try allocator.alloc(u8, cache_cells);
    defer allocator.free(cache);
    var marks = try allocator.alloc(u32, cache_cells);
    defer allocator.free(marks);
    @memset(marks, 0);

    var touch_indices = try allocator.alloc(usize, touches_per_frame);
    defer allocator.free(touch_indices);
    var rng: u64 = 0xA55A55A55;
    for (touch_indices) |*idx| {
        idx.* = @as(usize, lcgNext(&rng)) % cache_cells;
    }

    std.debug.print("\n[phase15] hybrid shadow cache strategy\n", .{});
    std.debug.print("  warmup={} measure={} frames={} touches/frame={}\n", .{ WarmupRuns, MeasureRuns, frames, touches_per_frame });

    var clear_sum_ns: u128 = 0;
    var clear_best_ns: u64 = std.math.maxInt(u64);
    var clear_checksum: u64 = 0;
    var gen_sum_ns: u128 = 0;
    var gen_best_ns: u64 = std.math.maxInt(u64);
    var gen_checksum: u64 = 0;

    var run_index: usize = 0;
    while (run_index < TotalRuns) : (run_index += 1) {
        const record = run_index >= WarmupRuns;

        var clear_timer = try std.time.Timer.start();
        var local_clear_checksum: u64 = 0;
        var frame: usize = 0;
        while (frame < frames) : (frame += 1) {
            hybrid_shadow_cache_kernel.clearUnknown(cache);
            for (touch_indices) |idx| {
                cache[idx] = 128;
            }
            local_clear_checksum +%= cache[touch_indices[0]];
        }
        const clear_ns = clear_timer.read();

        var generation: u32 = 0;
        var gen_timer = try std.time.Timer.start();
        var local_gen_checksum: u64 = 0;
        frame = 0;
        while (frame < frames) : (frame += 1) {
            generation +%= 1;
            if (generation == 0) {
                generation = 1;
                @memset(marks, 0);
            }
            for (touch_indices) |idx| {
                marks[idx] = generation;
            }
            var hits: usize = 0;
            for (touch_indices[0..256]) |idx| {
                if (marks[idx] == generation) hits += 1;
            }
            local_gen_checksum +%= hits;
        }
        const gen_ns = gen_timer.read();

        if (record) {
            clear_sum_ns += clear_ns;
            gen_sum_ns += gen_ns;
            if (clear_ns < clear_best_ns) clear_best_ns = clear_ns;
            if (gen_ns < gen_best_ns) gen_best_ns = gen_ns;
            clear_checksum +%= local_clear_checksum;
            gen_checksum +%= local_gen_checksum;
        }
    }

    std.debug.print(
        "  - full_clear: avg {d:.3} us/frame (best {d:.3}) | checksum={}\n",
        .{
            averageNs(clear_sum_ns, MeasureRuns) / @as(f64, @floatFromInt(frames)) / 1000.0,
            @as(f64, @floatFromInt(clear_best_ns)) / @as(f64, @floatFromInt(frames)) / 1000.0,
            clear_checksum,
        },
    );
    std.debug.print(
        "  - generation_stamp: avg {d:.3} us/frame (best {d:.3}) | checksum={}\n",
        .{
            averageNs(gen_sum_ns, MeasureRuns) / @as(f64, @floatFromInt(frames)) / 1000.0,
            @as(f64, @floatFromInt(gen_best_ns)) / @as(f64, @floatFromInt(frames)) / 1000.0,
            gen_checksum,
        },
    );
}

const BenchName = enum {
    all,
    raster,
    chunk,
    trace,
    shadow_apply,
    shadow_apply_threshold,
    jobs,
    tonemap,
    bilinear,
    cache,
};

fn parseBenchName(arg: []const u8) BenchName {
    if (std.mem.eql(u8, arg, "all")) return .all;
    if (std.mem.eql(u8, arg, "raster")) return .raster;
    if (std.mem.eql(u8, arg, "chunk")) return .chunk;
    if (std.mem.eql(u8, arg, "trace")) return .trace;
    if (std.mem.eql(u8, arg, "shadow_apply")) return .shadow_apply;
    if (std.mem.eql(u8, arg, "shadow_apply_threshold")) return .shadow_apply_threshold;
    if (std.mem.eql(u8, arg, "jobs")) return .jobs;
    if (std.mem.eql(u8, arg, "tonemap")) return .tonemap;
    if (std.mem.eql(u8, arg, "bilinear")) return .bilinear;
    if (std.mem.eql(u8, arg, "cache")) return .cache;
    return .all;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const bench = if (args.len > 1) parseBenchName(args[1]) else BenchName.all;

    if (bench == .all or bench == .raster) try runRasterBench(allocator);
    if (bench == .all or bench == .chunk) try runShadowChunkPlannerBench();
    if (bench == .all or bench == .trace) try runShadowTraceBench(allocator);
    if (bench == .all or bench == .shadow_apply) try runShadowApplyBench(allocator);
    if (bench == .all or bench == .shadow_apply_threshold) try runShadowApplyThresholdSweepBench(allocator);
    if (bench == .all or bench == .jobs) try runTinyJobBench(allocator);
    if (bench == .all or bench == .tonemap) try runTonemapPackBench(allocator);
    if (bench == .all or bench == .bilinear) try runTextureBilinearBench(allocator);
    if (bench == .all or bench == .cache) try runCacheStrategyBench(allocator);
}
