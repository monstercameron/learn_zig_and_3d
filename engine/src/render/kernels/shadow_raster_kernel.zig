const std = @import("std");

fn shadowEdge(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
}

pub fn rasterizeTriangleRows(
    shadow: anytype,
    start_row: usize,
    end_row: usize,
    p0: anytype,
    p1: anytype,
    p2: anytype,
) void {
    if (!shadow.active) return;
    if (start_row >= end_row or end_row > shadow.height) return;

    const scale_x = @as(f32, @floatFromInt(shadow.width - 1)) * shadow.inv_extent_x;
    const scale_y = @as(f32, @floatFromInt(shadow.height - 1)) * shadow.inv_extent_y;

    const s0 = [2]f32{ (p0.x - shadow.min_x) * scale_x, (shadow.max_y - p0.y) * scale_y };
    const s1 = [2]f32{ (p1.x - shadow.min_x) * scale_x, (shadow.max_y - p1.y) * scale_y };
    const s2 = [2]f32{ (p2.x - shadow.min_x) * scale_x, (shadow.max_y - p2.y) * scale_y };

    const area = shadowEdge(s0, s1, s2);
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
            const w0 = shadowEdge(s1, s2, sample);
            const w1 = shadowEdge(s2, s0, sample);
            const w2 = shadowEdge(s0, s1, sample);

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
