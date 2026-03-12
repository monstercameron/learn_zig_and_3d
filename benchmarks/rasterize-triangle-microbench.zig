const std = @import("std");
const engine_bench = @import("engine_bench");
const math = engine_bench.math;
const tile_renderer = engine_bench.tile_renderer;

const RasterCase = struct {
    name: []const u8,
    p0: math.Vec2,
    p1: math.Vec2,
    p2: math.Vec2,
};

fn averageNs(sum: u128, runs: usize) f64 {
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(runs));
}

fn depthChecksum(depth: []const f32) f64 {
    var sum: f64 = 0.0;
    for (depth) |value| {
        if (std.math.isFinite(value)) sum += value;
    }
    return sum;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tile = tile_renderer.Tile.init(0, 0, tile_renderer.TILE_SIZE, tile_renderer.TILE_SIZE, 0);
    var tile_buffer = try tile_renderer.TileBuffer.init(tile.width, tile.height, allocator);
    defer tile_buffer.deinit();

    const shading = tile_renderer.ShadingParams{
        .base_color = 0xFFFFA040,
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

    const camera_positions = [3]math.Vec3{
        math.Vec3.new(-0.2, -0.2, 2.0),
        math.Vec3.new(0.3, -0.1, 2.2),
        math.Vec3.new(-0.1, 0.4, 2.4),
    };
    const depths = [3]f32{ 2.0, 2.2, 2.4 };

    const warmup_runs: usize = 1;
    const measure_runs: usize = 7;
    const total_runs = warmup_runs + measure_runs;
    const iterations_per_run: usize = 2000;

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

    std.debug.print("rasterizeTriangleToTile microbench ({d}x{d} tile)\n", .{ tile.width, tile.height });
    std.debug.print("warmup_runs={} measure_runs={} iterations_per_run={}\n", .{ warmup_runs, measure_runs, iterations_per_run });

    for (raster_cases) |raster_case| {
        var elapsed_sum_ns: u128 = 0;
        var elapsed_best_ns: u64 = std.math.maxInt(u64);

        var run_index: usize = 0;
        while (run_index < total_runs) : (run_index += 1) {
            const record = run_index >= warmup_runs;
            var timer = try std.time.Timer.start();

            var iter: usize = 0;
            while (iter < iterations_per_run) : (iter += 1) {
                @memset(tile_buffer.depth, std.math.inf(f32));
                tile_renderer.rasterizeTriangleToTile(
                    &tile,
                    &tile_buffer,
                    raster_case.p0,
                    raster_case.p1,
                    raster_case.p2,
                    camera_positions,
                    depths,
                    shading,
                    null,
                );
            }

            const elapsed_ns = timer.read();
            if (record) {
                elapsed_sum_ns += elapsed_ns;
                if (elapsed_ns < elapsed_best_ns) elapsed_best_ns = elapsed_ns;
            }
        }

        const area = 0.5 * @abs(
            (raster_case.p1.x - raster_case.p0.x) * (raster_case.p2.y - raster_case.p0.y) -
                (raster_case.p1.y - raster_case.p0.y) * (raster_case.p2.x - raster_case.p0.x),
        );
        const covered_pixels_est = @max(@as(f64, 1.0), @as(f64, @floatCast(area)));
        const pixels_per_run = covered_pixels_est * @as(f64, @floatFromInt(iterations_per_run));
        const avg_ns = averageNs(elapsed_sum_ns, measure_runs);
        const checksum = depthChecksum(tile_buffer.depth);
        std.mem.doNotOptimizeAway(checksum);

        std.debug.print(
            "- {s}: avg {d:.3} ns/tri (best {d:.3}) | approx {d:.3} ns/covered-pixel (best {d:.3}) | depth_checksum={d:.6}\n",
            .{
                raster_case.name,
                avg_ns / @as(f64, @floatFromInt(iterations_per_run)),
                @as(f64, @floatFromInt(elapsed_best_ns)) / @as(f64, @floatFromInt(iterations_per_run)),
                avg_ns / pixels_per_run,
                @as(f64, @floatFromInt(elapsed_best_ns)) / pixels_per_run,
                checksum,
            },
        );
    }
}
