const std = @import("std");
const engine_bench = @import("engine_bench");
const math = engine_bench.math;
const texture = engine_bench.texture;
const lighting = engine_bench.lighting;
const tile_renderer = engine_bench.tile_renderer;
const BinningStage = engine_bench.binning_stage;
const Bitmap = engine_bench.bitmap.Bitmap;
const TrianglePacket = engine_bench.mesh_work_types.TrianglePacket;
const TriangleFlags = engine_bench.mesh_work_types.TriangleFlags;

const WarmupRuns: usize = 1;
const MeasureRuns: usize = 7;
const TotalRuns: usize = WarmupRuns + MeasureRuns;

fn averageNs(sum: u128, runs: usize) f64 {
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(runs));
}

fn lcgNext(state: *u64) u32 {
    state.* = state.* *% 6364136223846793005 +% 1;
    return @as(u32, @truncate(state.* >> 32));
}

fn lcgFloat01(state: *u64) f32 {
    return @as(f32, @floatFromInt(lcgNext(state))) / 4294967295.0;
}

// ============================================================================
// 1. packColorTonemapped: scalar vs SIMD batch
// ============================================================================
fn benchTonemapScalar() void {
    const iterations: usize = 50_000;
    const pixels_per_iter: usize = 64; // one tile row
    var rng: u64 = 0xDEADBEEF;

    std.debug.print("\n[perf-uplift] packColorTonemapped scalar vs batch (8-wide)\n", .{});
    std.debug.print("  warmup={} measure={} iterations={} pixels/iter={}\n", .{ WarmupRuns, MeasureRuns, iterations, pixels_per_iter });

    // Generate test data
    var colors_x: [pixels_per_iter]f32 = undefined;
    var colors_y: [pixels_per_iter]f32 = undefined;
    var colors_z: [pixels_per_iter]f32 = undefined;
    var alphas: [pixels_per_iter]u32 = undefined;
    for (0..pixels_per_iter) |i| {
        colors_x[i] = lcgFloat01(&rng) * 2.0;
        colors_y[i] = lcgFloat01(&rng) * 2.0;
        colors_z[i] = lcgFloat01(&rng) * 2.0;
        alphas[i] = 255;
    }

    // Scalar benchmark
    {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);
        var sink: u32 = 0;

        var run: usize = 0;
        while (run < TotalRuns) : (run += 1) {
            var timer = std.time.Timer.start() catch unreachable;
            var iter: usize = 0;
            while (iter < iterations) : (iter += 1) {
                for (0..pixels_per_iter) |i| {
                    sink +%= lighting.packColorTonemapped(
                        math.Vec3.new(colors_x[i], colors_y[i], colors_z[i]),
                        alphas[i],
                    );
                }
            }
            const ns = timer.read();
            if (run >= WarmupRuns) {
                elapsed_sum_ns += ns;
                if (ns < elapsed_best_ns) elapsed_best_ns = ns;
            }
        }
        std.mem.doNotOptimizeAway(&sink);
        const avg = averageNs(elapsed_sum_ns, MeasureRuns);
        const per_pixel = avg / @as(f64, @floatFromInt(iterations * pixels_per_iter));
        const best_pp = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations * pixels_per_iter));
        std.debug.print("  scalar:  avg {d:.3} ns total, {d:.3} ns/pixel (best {d:.3})\n", .{ avg, per_pixel, best_pp });
    }

    // Batch benchmark
    {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);
        var sink: u32 = 0;
        const batch = 8;

        var run: usize = 0;
        while (run < TotalRuns) : (run += 1) {
            var timer = std.time.Timer.start() catch unreachable;
            var iter: usize = 0;
            while (iter < iterations) : (iter += 1) {
                var i: usize = 0;
                while (i + batch <= pixels_per_iter) : (i += batch) {
                    const result = lighting.packColorTonemappedBatch(
                        batch,
                        colors_x[i..][0..batch],
                        colors_y[i..][0..batch],
                        colors_z[i..][0..batch],
                        alphas[i..][0..batch],
                    );
                    for (result) |r| sink +%= r;
                }
            }
            const ns = timer.read();
            if (run >= WarmupRuns) {
                elapsed_sum_ns += ns;
                if (ns < elapsed_best_ns) elapsed_best_ns = ns;
            }
        }
        std.mem.doNotOptimizeAway(&sink);
        const avg = averageNs(elapsed_sum_ns, MeasureRuns);
        const per_pixel = avg / @as(f64, @floatFromInt(iterations * pixels_per_iter));
        const best_pp = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations * pixels_per_iter));
        std.debug.print("  batch8:  avg {d:.3} ns total, {d:.3} ns/pixel (best {d:.3})\n", .{ avg, per_pixel, best_pp });
    }
}

// ============================================================================
// 2. Bilinear texture sampling: vectorized blend
// ============================================================================
fn benchBilinearSample(allocator: std.mem.Allocator) !void {
    const iterations: usize = 20_000;
    const samples_per_iter: usize = 64;
    var rng: u64 = 0xCAFEBABE;

    std.debug.print("\n[perf-uplift] bilinear texture sample (8-wide batch)\n", .{});
    std.debug.print("  warmup={} measure={} iterations={} samples/iter={}\n", .{ WarmupRuns, MeasureRuns, iterations, samples_per_iter });

    // Create a synthetic 64x64 texture
    const tex_w: usize = 64;
    const tex_h: usize = 64;
    var pixels: [tex_w * tex_h]u32 = undefined;
    for (&pixels) |*p| {
        p.* = lcgNext(&rng);
    }

    // Build a minimal Texture struct for benchmarking
    const tex = texture.Texture{
        .pixels = &pixels,
        .width = tex_w,
        .height = tex_h,
        .mip_levels = .{},
        .allocator = allocator,
    };

    // Generate random UVs
    var uvs: [samples_per_iter]math.Vec2 = undefined;
    for (&uvs) |*uv| {
        uv.* = math.Vec2.new(lcgFloat01(&rng), lcgFloat01(&rng));
    }

    var out: [samples_per_iter]u32 = undefined;
    var elapsed_sum_ns: u128 = 0;
    var elapsed_best_ns: u64 = std.math.maxInt(u64);

    var run: usize = 0;
    while (run < TotalRuns) : (run += 1) {
        var timer = std.time.Timer.start() catch unreachable;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            tex.sampleLodBatch(&uvs, 0.0, &out);
        }
        const ns = timer.read();
        if (run >= WarmupRuns) {
            elapsed_sum_ns += ns;
            if (ns < elapsed_best_ns) elapsed_best_ns = ns;
        }
    }
    std.mem.doNotOptimizeAway(&out);
    const avg = averageNs(elapsed_sum_ns, MeasureRuns);
    const per_sample = avg / @as(f64, @floatFromInt(iterations * samples_per_iter));
    const best_ps = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations * samples_per_iter));
    std.debug.print("  batch8:  avg {d:.3} ns total, {d:.3} ns/sample (best {d:.3})\n", .{ avg, per_sample, best_ps });
}

// ============================================================================
// 3. Compositing: tile tonemap + scatter
// ============================================================================
fn benchComposite(allocator: std.mem.Allocator) !void {
    const iterations: usize = 5_000;

    std.debug.print("\n[perf-uplift] compositeTileToScreen\n", .{});
    std.debug.print("  warmup={} measure={} iterations={}\n", .{ WarmupRuns, MeasureRuns, iterations });

    const tile = tile_renderer.Tile.init(0, 0, tile_renderer.TILE_SIZE, tile_renderer.TILE_SIZE, 0);
    var tile_buffer = try tile_renderer.TileBuffer.init(tile.width, tile.height, allocator);
    defer tile_buffer.deinit();

    const screen_w: usize = 256;
    const screen_h: usize = 256;
    const total_pixels = screen_w * screen_h;
    const screen_pixels = try allocator.alloc(u32, total_pixels);
    defer allocator.free(screen_pixels);
    const depth_buf = try allocator.alloc(f32, total_pixels);
    defer allocator.free(depth_buf);
    const camera_buf = try allocator.alloc(math.Vec3, total_pixels);
    defer allocator.free(camera_buf);
    const normal_buf = try allocator.alloc(math.Vec3, total_pixels);
    defer allocator.free(normal_buf);
    const surface_buf = try allocator.alloc(tile_renderer.SurfaceHandle, total_pixels);
    defer allocator.free(surface_buf);

    // Fill tile buffer with synthetic data
    var rng: u64 = 0xBAADF00D;
    for (tile_buffer.data) |*pd| {
        pd.color = math.Vec4.new(lcgFloat01(&rng) * 2.0, lcgFloat01(&rng) * 2.0, lcgFloat01(&rng) * 2.0, 1.0);
        pd.camera = math.Vec3.new(lcgFloat01(&rng), lcgFloat01(&rng), lcgFloat01(&rng));
        pd.normal = math.Vec3.new(0.0, 0.0, -1.0);
        pd.surface = tile_renderer.SurfaceHandle.invalid();
    }
    @memset(tile_buffer.depth, 1.0);

    // Use a dummy GDI handle for benchmarking (not used by compositeTileToScreen)
    var dummy_handle: u8 = 0;
    var bitmap_val = Bitmap{
        .hbitmap = @ptrCast(&dummy_handle),
        .pixels = screen_pixels,
        .width = @intCast(screen_w),
        .height = @intCast(screen_h),
    };

    var elapsed_sum_ns: u128 = 0;
    var elapsed_best_ns: u64 = std.math.maxInt(u64);

    var run: usize = 0;
    while (run < TotalRuns) : (run += 1) {
        var timer = std.time.Timer.start() catch unreachable;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            tile_renderer.compositeTileToScreen(
                &tile,
                &tile_buffer,
                &bitmap_val,
                depth_buf,
                camera_buf,
                normal_buf,
                surface_buf,
            );
        }
        const ns = timer.read();
        if (run >= WarmupRuns) {
            elapsed_sum_ns += ns;
            if (ns < elapsed_best_ns) elapsed_best_ns = ns;
        }
    }
    const avg = averageNs(elapsed_sum_ns, MeasureRuns);
    const per_iter = avg / @as(f64, @floatFromInt(iterations));
    const best_pi = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations));
    const tile_pixels = @as(f64, @floatFromInt(tile_renderer.TILE_SIZE * tile_renderer.TILE_SIZE));
    std.debug.print("  composite:  avg {d:.3} ns/tile, {d:.3} ns/pixel (best {d:.3} ns/tile)\n", .{ per_iter, per_iter / tile_pixels, best_pi });
}

// ============================================================================
// 4. Binning: single-tile fast path impact
// ============================================================================
fn benchBinning(allocator: std.mem.Allocator) !void {
    const grid_cols: usize = 4;
    const grid_rows: usize = 4;
    const tile_count = grid_cols * grid_rows;
    const screen_w: i32 = @intCast(grid_cols * tile_renderer.TILE_SIZE);
    const screen_h: i32 = @intCast(grid_rows * tile_renderer.TILE_SIZE);

    std.debug.print("\n[perf-uplift] binTrianglesRangeToTiles (single-tile fast path)\n", .{});

    // Build a tile grid manually
    var tiles: [tile_count]tile_renderer.Tile = undefined;
    for (0..grid_rows) |r| {
        for (0..grid_cols) |c| {
            tiles[r * grid_cols + c] = tile_renderer.Tile.init(
                @intCast(c * tile_renderer.TILE_SIZE),
                @intCast(r * tile_renderer.TILE_SIZE),
                tile_renderer.TILE_SIZE,
                tile_renderer.TILE_SIZE,
                r * grid_cols + c,
            );
        }
    }

    const grid = tile_renderer.TileGrid{
        .tiles = &tiles,
        .cols = grid_cols,
        .rows = grid_rows,
        .screen_width = screen_w,
        .screen_height = screen_h,
        .allocator = allocator,
    };

    // Generate triangles: mix of single-tile (small) and multi-tile (spanning)
    const tri_count: usize = 4000;
    var rng: u64 = 0xFEEDFACE;
    var triangle_packets: [tri_count]TrianglePacket = undefined;

    for (&triangle_packets) |*pkt| {
        // 75% small (single-tile), 25% spanning
        const is_small = (lcgNext(&rng) % 4) != 0;
        const base_x: i32 = @intFromFloat(lcgFloat01(&rng) * @as(f32, @floatFromInt(screen_w - 10)));
        const base_y: i32 = @intFromFloat(lcgFloat01(&rng) * @as(f32, @floatFromInt(screen_h - 10)));
        const span: i32 = if (is_small) 8 else 120;

        const dx1: i32 = @intFromFloat(@as(f32, @floatFromInt(span)) * lcgFloat01(&rng));
        const dy1: i32 = @intFromFloat(@as(f32, @floatFromInt(span)) * 0.3 * lcgFloat01(&rng));
        const dx2: i32 = @intFromFloat(@as(f32, @floatFromInt(span)) * 0.3 * lcgFloat01(&rng));
        const dy2: i32 = @intFromFloat(@as(f32, @floatFromInt(span)) * lcgFloat01(&rng));

        pkt.* = .{
            .screen = .{
                .{ base_x, base_y },
                .{ base_x + dx1, base_y + dy1 },
                .{ base_x + dx2, base_y + dy2 },
            },
            .camera = .{
                math.Vec3.new(0, 0, 1),
                math.Vec3.new(0, 0, 1),
                math.Vec3.new(0, 0, 1),
            },
            .normals = .{
                math.Vec3.new(0, 0, -1),
                math.Vec3.new(0, 0, -1),
                math.Vec3.new(0, 0, -1),
            },
            .uv = .{
                math.Vec2.new(0, 0),
                math.Vec2.new(1, 0),
                math.Vec2.new(0, 1),
            },
            .base_color = 0xFFFFFFFF,
            .texture_index = 0,
            .intensity = 1.0,
            .flags = .{ .cull_fill = false, .cull_wire = false, .backface = false },
            .triangle_id = 0,
            .meshlet_id = 0,
        };
    }

    var tile_lists: [tile_count]BinningStage.TileTriangleList = undefined;
    for (&tile_lists) |*tl| {
        tl.* = BinningStage.TileTriangleList.init(allocator);
    }
    defer for (&tile_lists) |*tl| tl.deinit();

    const iterations: usize = 2_000;
    std.debug.print("  warmup={} measure={} iterations={} triangles={}\n", .{ WarmupRuns, MeasureRuns, iterations, tri_count });

    var elapsed_sum_ns: u128 = 0;
    var elapsed_best_ns: u64 = std.math.maxInt(u64);

    var run: usize = 0;
    while (run < TotalRuns) : (run += 1) {
        var timer = std.time.Timer.start() catch unreachable;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            for (&tile_lists) |*tl| tl.clear();
            BinningStage.binTrianglesRangeToTiles(
                &triangle_packets,
                0,
                tri_count,
                &grid,
                &tile_lists,
            ) catch {};
        }
        const ns = timer.read();
        if (run >= WarmupRuns) {
            elapsed_sum_ns += ns;
            if (ns < elapsed_best_ns) elapsed_best_ns = ns;
        }
    }
    const avg = averageNs(elapsed_sum_ns, MeasureRuns);
    const per_tri = avg / @as(f64, @floatFromInt(iterations * tri_count));
    const best_pt = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations * tri_count));
    std.debug.print("  binning:  avg {d:.3} ns total, {d:.3} ns/tri (best {d:.3})\n", .{ avg, per_tri, best_pt });
}

// ============================================================================
// 5. GLTF vertex transform: scalar vs batch
// ============================================================================
fn benchVertexTransform() void {
    const iterations: usize = 100_000;
    const verts_per_iter: usize = 64;

    std.debug.print("\n[perf-uplift] transformPoint scalar vs batch (4-wide)\n", .{});
    std.debug.print("  warmup={} measure={} iterations={} verts/iter={}\n", .{ WarmupRuns, MeasureRuns, iterations, verts_per_iter });

    var rng: u64 = 0x12345678;

    // Random rotation + translation matrix
    const matrix = [16]f32{
        0.866, 0.0, 0.5,   0.0,
        0.0,   1.0, 0.0,   0.0,
        -0.5,  0.0, 0.866, 0.0,
        1.5,   2.0, 3.0,   1.0,
    };

    var px: [verts_per_iter]f32 = undefined;
    var py: [verts_per_iter]f32 = undefined;
    var pz: [verts_per_iter]f32 = undefined;
    for (0..verts_per_iter) |i| {
        px[i] = lcgFloat01(&rng) * 10.0 - 5.0;
        py[i] = lcgFloat01(&rng) * 10.0 - 5.0;
        pz[i] = lcgFloat01(&rng) * 10.0 - 5.0;
    }

    // Scalar benchmark
    {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);
        var sink_x: f32 = 0;

        var run: usize = 0;
        while (run < TotalRuns) : (run += 1) {
            var timer = std.time.Timer.start() catch unreachable;
            var iter: usize = 0;
            while (iter < iterations) : (iter += 1) {
                for (0..verts_per_iter) |i| {
                    const v = scalarTransformPoint(matrix, math.Vec3.new(px[i], py[i], pz[i]));
                    sink_x += v.x;
                }
            }
            const ns = timer.read();
            if (run >= WarmupRuns) {
                elapsed_sum_ns += ns;
                if (ns < elapsed_best_ns) elapsed_best_ns = ns;
            }
        }
        std.mem.doNotOptimizeAway(&sink_x);
        const avg = averageNs(elapsed_sum_ns, MeasureRuns);
        const per_vert = avg / @as(f64, @floatFromInt(iterations * verts_per_iter));
        const best_pv = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations * verts_per_iter));
        std.debug.print("  scalar:  avg {d:.3} ns total, {d:.3} ns/vert (best {d:.3})\n", .{ avg, per_vert, best_pv });
    }

    // Batch benchmark
    {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);
        var sink_x: f32 = 0;
        const batch = 4;

        var run: usize = 0;
        while (run < TotalRuns) : (run += 1) {
            var timer = std.time.Timer.start() catch unreachable;
            var iter: usize = 0;
            while (iter < iterations) : (iter += 1) {
                var i: usize = 0;
                while (i + batch <= verts_per_iter) : (i += batch) {
                    const results = batchTransformPoint(batch, matrix, px[i..][0..batch], py[i..][0..batch], pz[i..][0..batch]);
                    for (results) |v| sink_x += v.x;
                }
            }
            const ns = timer.read();
            if (run >= WarmupRuns) {
                elapsed_sum_ns += ns;
                if (ns < elapsed_best_ns) elapsed_best_ns = ns;
            }
        }
        std.mem.doNotOptimizeAway(&sink_x);
        const avg = averageNs(elapsed_sum_ns, MeasureRuns);
        const per_vert = avg / @as(f64, @floatFromInt(iterations * verts_per_iter));
        const best_pv = @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations * verts_per_iter));
        std.debug.print("  batch4:  avg {d:.3} ns total, {d:.3} ns/vert (best {d:.3})\n", .{ avg, per_vert, best_pv });
    }
}

// Local copies of scalar/batch transform for isolated benchmarking
fn scalarTransformPoint(matrix: [16]f32, point: math.Vec3) math.Vec3 {
    const x = matrix[0] * point.x + matrix[4] * point.y + matrix[8] * point.z + matrix[12];
    const y = matrix[1] * point.x + matrix[5] * point.y + matrix[9] * point.z + matrix[13];
    const z = matrix[2] * point.x + matrix[6] * point.y + matrix[10] * point.z + matrix[14];
    const w = matrix[3] * point.x + matrix[7] * point.y + matrix[11] * point.z + matrix[15];
    if (@abs(w) <= 1e-6 or @abs(w - 1.0) <= 1e-6) return math.Vec3.new(x, y, z);
    const inv_w = 1.0 / w;
    return math.Vec3.new(x * inv_w, y * inv_w, z * inv_w);
}

fn batchTransformPoint(comptime lanes: comptime_int, matrix: [16]f32, bx: *const [lanes]f32, by: *const [lanes]f32, bz: *const [lanes]f32) [lanes]math.Vec3 {
    const V = @Vector(lanes, f32);
    const vx: V = bx.*;
    const vy: V = by.*;
    const vz: V = bz.*;

    const rx = @as(V, @splat(matrix[0])) * vx + @as(V, @splat(matrix[4])) * vy + @as(V, @splat(matrix[8])) * vz + @as(V, @splat(matrix[12]));
    const ry = @as(V, @splat(matrix[1])) * vx + @as(V, @splat(matrix[5])) * vy + @as(V, @splat(matrix[9])) * vz + @as(V, @splat(matrix[13]));
    const rz = @as(V, @splat(matrix[2])) * vx + @as(V, @splat(matrix[6])) * vy + @as(V, @splat(matrix[10])) * vz + @as(V, @splat(matrix[14]));
    const rw = @as(V, @splat(matrix[3])) * vx + @as(V, @splat(matrix[7])) * vy + @as(V, @splat(matrix[11])) * vz + @as(V, @splat(matrix[15]));

    const eps: V = @splat(1e-6);
    const one: V = @splat(1.0);
    const abs_w = @abs(rw);
    const dist_one = @abs(rw - one);
    const needs_divide = (abs_w > eps) & (dist_one > eps);
    const inv_w = one / @select(f32, needs_divide, rw, one);
    const ox = @select(f32, needs_divide, rx * inv_w, rx);
    const oy = @select(f32, needs_divide, ry * inv_w, ry);
    const oz = @select(f32, needs_divide, rz * inv_w, rz);

    const ox_arr: [lanes]f32 = ox;
    const oy_arr: [lanes]f32 = oy;
    const oz_arr: [lanes]f32 = oz;

    var result: [lanes]math.Vec3 = undefined;
    inline for (0..lanes) |i| {
        result[i] = math.Vec3.new(ox_arr[i], oy_arr[i], oz_arr[i]);
    }
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Performance Uplift Microbenchmarks ===\n", .{});

    benchTonemapScalar();
    try benchBilinearSample(allocator);
    try benchComposite(allocator);
    try benchBinning(allocator);
    benchVertexTransform();

    std.debug.print("\n=== Done ===\n", .{});
}
