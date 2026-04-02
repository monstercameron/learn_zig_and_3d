const std = @import("std");
const direct_packets = @import("direct_packets.zig");
const scanline = @import("core/scanline.zig");

pub const Point2i = struct {
    x: i32,
    y: i32,
};

pub const Triangle2i = struct {
    a: Point2i,
    b: Point2i,
    c: Point2i,
};

pub const Line2i = struct {
    start: Point2i,
    end: Point2i,
};

pub const Polygon2i = struct {
    points: []const Point2i,
};

pub const Circle2i = struct {
    center: Point2i,
    radius: i32,
};

pub const Rect2i = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
};

pub const FrameTarget = struct {
    width: i32,
    height: i32,
    color: []u32,
    depth: ?[]f32 = null,
    clip: ?Rect2i = null,
};

pub const ClearConfig = struct {
    color: u32,
    depth: ?f32 = null,
};

pub const TriangleStyle = struct {
    fill_color: u32,
    outline_color: ?u32 = null,
    depth: ?f32 = null,
};

pub const LineStyle = struct {
    color: u32,
};

pub const PolygonStyle = struct {
    fill_color: u32,
    outline_color: ?u32 = null,
    depth: ?f32 = null,
};

pub const CircleStyle = struct {
    fill_color: ?u32 = null,
    outline_color: ?u32 = null,
    depth: ?f32 = null,
};

pub const Command = union(enum) {
    line: struct {
        line: Line2i,
        style: LineStyle,
    },
    triangle: struct {
        triangle: Triangle2i,
        style: TriangleStyle,
    },
    polygon: struct {
        polygon: Polygon2i,
        style: PolygonStyle,
    },
    circle: struct {
        circle: Circle2i,
        style: CircleStyle,
    },
};

pub fn clear(target: FrameTarget, config: ClearConfig) void {
    @memset(target.color, config.color);
    if (config.depth) |depth_value| {
        if (target.depth) |depth_buffer| {
            for (depth_buffer) |*depth| depth.* = depth_value;
        }
    }
}

pub fn centeredIsoscelesTriangle(width: i32, height: i32, half_extent: i32, vertical_extent: i32) Triangle2i {
    const center_x = @divTrunc(width, 2);
    const center_y = @divTrunc(height, 2);
    return .{
        .a = .{ .x = center_x, .y = center_y - vertical_extent },
        .b = .{ .x = center_x - half_extent, .y = center_y + half_extent },
        .c = .{ .x = center_x + half_extent, .y = center_y + half_extent },
    };
}

pub fn drawTriangle(target: FrameTarget, triangle: Triangle2i, style: TriangleStyle) void {
    drawSolidTriangle(target, triangle, style.fill_color, style.depth);
    if (style.outline_color) |outline_color| {
        drawLine(target, .{ .start = triangle.a, .end = triangle.b }, .{ .color = outline_color });
        drawLine(target, .{ .start = triangle.b, .end = triangle.c }, .{ .color = outline_color });
        drawLine(target, .{ .start = triangle.c, .end = triangle.a }, .{ .color = outline_color });
    }
}

pub fn draw(target: FrameTarget, command: Command) void {
    switch (command) {
        .line => |payload| drawLine(target, payload.line, payload.style),
        .triangle => |payload| drawTriangle(target, payload.triangle, payload.style),
        .polygon => |payload| drawPolygon(target, payload.polygon, payload.style),
        .circle => |payload| drawCircle(target, payload.circle, payload.style),
    }
}

pub fn drawPacket(target: FrameTarget, packet: direct_packets.DrawPacket) void {
    switch (packet.payload) {
        .line => |line| drawLine(target, line, .{ .color = packet.material.stroke.color }),
        .triangle => |triangle| {
            const style = packet.material.surface;
            drawTriangle(target, triangle, .{
                .fill_color = style.fill_color,
                .outline_color = style.outline_color,
                .depth = if (packet.flags.depth_write) style.depth else null,
            });
        },
        .polygon => |polygon| {
            const style = packet.material.surface;
            drawPolygon(target, polygon, .{
                .fill_color = style.fill_color,
                .outline_color = style.outline_color,
                .depth = if (packet.flags.depth_write) style.depth else null,
            });
        },
        .circle => |circle| {
            const style = packet.material.surface;
            drawCircle(target, circle, .{
                .fill_color = style.fill_color,
                .outline_color = style.outline_color,
                .depth = if (packet.flags.depth_write) style.depth else null,
            });
        },
    }
}

pub fn drawMany(target: FrameTarget, commands: []const Command) void {
    for (commands) |command| draw(target, command);
}

pub fn drawLine(target: FrameTarget, line: Line2i, style: LineStyle) void {
    var cx = line.start.x;
    var cy = line.start.y;

    const dx = if (line.end.x >= line.start.x) (line.end.x - line.start.x) else (line.start.x - line.end.x);
    const dy = if (line.end.y >= line.start.y) (line.end.y - line.start.y) else (line.start.y - line.end.y);
    const sx: i32 = if (line.start.x < line.end.x) 1 else -1;
    const sy: i32 = if (line.start.y < line.end.y) 1 else -1;
    var err: i32 = dx - dy;

    while (true) {
        setPixel(target, cx, cy, style.color, null);
        if (cx == line.end.x and cy == line.end.y) break;

        const doubled_err = err * 2;
        if (doubled_err > -dy) {
            err -= dy;
            cx += sx;
        }
        if (doubled_err < dx) {
            err += dx;
            cy += sy;
        }
    }
}

pub fn drawSolidTriangle(target: FrameTarget, triangle: Triangle2i, color: u32, depth_value: ?f32) void {
    if (target.width <= 0 or target.height <= 0) return;

    const bounds = targetBounds(target);
    const min_x = scanline.clampI32(scanline.minI32(triangle.a.x, scanline.minI32(triangle.b.x, triangle.c.x)), bounds.min_x, bounds.max_x);
    const max_x = scanline.clampI32(scanline.maxI32(triangle.a.x, scanline.maxI32(triangle.b.x, triangle.c.x)), bounds.min_x, bounds.max_x);
    const min_y = scanline.clampI32(scanline.minI32(triangle.a.y, scanline.minI32(triangle.b.y, triangle.c.y)), bounds.min_y, bounds.max_y);
    const max_y = scanline.clampI32(scanline.maxI32(triangle.a.y, scanline.maxI32(triangle.b.y, triangle.c.y)), bounds.min_y, bounds.max_y);

    const area = edgeFunction(triangle.a, triangle.b, triangle.c.x, triangle.c.y);
    if (area == 0) return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const w0 = edgeFunction(triangle.b, triangle.c, x, y);
            const w1 = edgeFunction(triangle.c, triangle.a, x, y);
            const w2 = edgeFunction(triangle.a, triangle.b, x, y);
            const inside = if (area > 0)
                (w0 >= 0 and w1 >= 0 and w2 >= 0)
            else
                (w0 <= 0 and w1 <= 0 and w2 <= 0);
            if (!inside) continue;

            setPixel(target, x, y, color, depth_value);
        }
    }
}

pub fn drawPolygon(target: FrameTarget, polygon: Polygon2i, style: PolygonStyle) void {
    if (polygon.points.len < 2) return;

    if (polygon.points.len >= 3) {
        const anchor = polygon.points[0];
        var index: usize = 1;
        while (index + 1 < polygon.points.len) : (index += 1) {
            drawSolidTriangle(target, .{
                .a = anchor,
                .b = polygon.points[index],
                .c = polygon.points[index + 1],
            }, style.fill_color, style.depth);
        }
    }

    if (style.outline_color) |outline_color| {
        var index: usize = 0;
        while (index < polygon.points.len) : (index += 1) {
            const next_index = (index + 1) % polygon.points.len;
            drawLine(target, .{
                .start = polygon.points[index],
                .end = polygon.points[next_index],
            }, .{ .color = outline_color });
        }
    }
}

pub fn drawCircle(target: FrameTarget, circle: Circle2i, style: CircleStyle) void {
    if (circle.radius <= 0) return;

    const bounds = targetBounds(target);
    const min_x = scanline.clampI32(circle.center.x - circle.radius, bounds.min_x, bounds.max_x);
    const max_x = scanline.clampI32(circle.center.x + circle.radius, bounds.min_x, bounds.max_x);
    const min_y = scanline.clampI32(circle.center.y - circle.radius, bounds.min_y, bounds.max_y);
    const max_y = scanline.clampI32(circle.center.y + circle.radius, bounds.min_y, bounds.max_y);
    const radius_sq: i64 = @as(i64, circle.radius) * @as(i64, circle.radius);
    const inner_radius = @max(circle.radius - 1, 0);
    const inner_radius_sq: i64 = @as(i64, inner_radius) * @as(i64, inner_radius);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const dx: i64 = @as(i64, x - circle.center.x);
            const dy: i64 = @as(i64, y - circle.center.y);
            const dist_sq = dx * dx + dy * dy;

            if (style.fill_color) |fill_color| {
                if (dist_sq <= radius_sq) {
                    setPixel(target, x, y, fill_color, style.depth);
                }
            }

            if (style.outline_color) |outline_color| {
                if (dist_sq <= radius_sq and dist_sq >= inner_radius_sq) {
                    setPixel(target, x, y, outline_color, style.depth);
                }
            }
        }
    }
}

pub fn edgeFunction(a: Point2i, b: Point2i, px: i32, py: i32) i64 {
    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const x: i64 = px;
    const y: i64 = py;
    return (x - ax) * (by - ay) - (y - ay) * (bx - ax);
}

fn setPixel(target: FrameTarget, x: i32, y: i32, color: u32, depth_value: ?f32) void {
    if (x < 0 or x >= target.width or y < 0 or y >= target.height) return;
    if (target.clip) |clip| {
        if (x < clip.min_x or x > clip.max_x or y < clip.min_y or y > clip.max_y) return;
    }
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(target.width)) + @as(usize, @intCast(x));
    if (idx >= target.color.len) return;
    target.color[idx] = color;
    if (depth_value) |depth| {
        if (target.depth) |depth_buffer| {
            if (idx < depth_buffer.len) depth_buffer[idx] = depth;
        }
    }
}

fn targetBounds(target: FrameTarget) Rect2i {
    const screen = Rect2i{
        .min_x = 0,
        .min_y = 0,
        .max_x = target.width - 1,
        .max_y = target.height - 1,
    };
    if (target.clip) |clip| {
        return .{
            .min_x = @max(screen.min_x, clip.min_x),
            .min_y = @max(screen.min_y, clip.min_y),
            .max_x = @min(screen.max_x, clip.max_x),
            .max_y = @min(screen.max_y, clip.max_y),
        };
    }
    return screen;
}

test "centered triangle lands around screen center" {
    const triangle = centeredIsoscelesTriangle(100, 80, 20, 24);
    try std.testing.expectEqual(@as(i32, 50), triangle.a.x);
    try std.testing.expectEqual(@as(i32, 16), triangle.a.y);
    try std.testing.expectEqual(@as(i32, 30), triangle.b.x);
    try std.testing.expectEqual(@as(i32, 60), triangle.b.y);
    try std.testing.expectEqual(@as(i32, 70), triangle.c.x);
    try std.testing.expectEqual(@as(i32, 60), triangle.c.y);
}

test "draw triangle fills center pixel" {
    var color = [_]u32{0} ** 64;
    var depth = [_]f32{0} ** 64;
    const target = FrameTarget{
        .width = 8,
        .height = 8,
        .color = color[0..],
        .depth = depth[0..],
    };
    clear(target, .{ .color = 0xFF000000, .depth = std.math.inf(f32) });
    drawTriangle(target, .{
        .a = .{ .x = 4, .y = 1 },
        .b = .{ .x = 1, .y = 6 },
        .c = .{ .x = 6, .y = 6 },
    }, .{
        .fill_color = 0xFFFF0000,
        .outline_color = 0xFFFFFFFF,
        .depth = 1.0,
    });

    const center_idx: usize = 4 * 8 + 4;
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), color[center_idx]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), depth[center_idx], 1e-6);
}

test "drawMany applies line and triangle commands" {
    var color = [_]u32{0} ** 100;
    const target = FrameTarget{
        .width = 10,
        .height = 10,
        .color = color[0..],
    };
    clear(target, .{ .color = 0xFF000000 });

    const commands = [_]Command{
        .{ .line = .{
            .line = .{
                .start = .{ .x = 0, .y = 0 },
                .end = .{ .x = 9, .y = 0 },
            },
            .style = .{ .color = 0xFFFFFFFF },
        } },
        .{ .triangle = .{
            .triangle = .{
                .a = .{ .x = 5, .y = 2 },
                .b = .{ .x = 2, .y = 8 },
                .c = .{ .x = 8, .y = 8 },
            },
            .style = .{
                .fill_color = 0xFFFF0000,
            },
        } },
    };

    drawMany(target, commands[0..]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), color[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), color[6 * 10 + 5]);
}

test "draw polygon and circle commands" {
    var color = [_]u32{0} ** 144;
    const target = FrameTarget{
        .width = 12,
        .height = 12,
        .color = color[0..],
    };
    clear(target, .{ .color = 0xFF000000 });

    const polygon_points = [_]Point2i{
        .{ .x = 2, .y = 2 },
        .{ .x = 5, .y = 1 },
        .{ .x = 8, .y = 3 },
        .{ .x = 7, .y = 7 },
        .{ .x = 3, .y = 8 },
    };

    const commands = [_]Command{
        .{ .polygon = .{
            .polygon = .{ .points = polygon_points[0..] },
            .style = .{
                .fill_color = 0xFF00AAFF,
                .outline_color = 0xFFFFFFFF,
            },
        } },
        .{ .circle = .{
            .circle = .{
                .center = .{ .x = 9, .y = 9 },
                .radius = 2,
            },
            .style = .{
                .fill_color = 0xFFFFAA00,
                .outline_color = 0xFFFFFFFF,
            },
        } },
    };

    drawMany(target, commands[0..]);
    try std.testing.expectEqual(@as(u32, 0xFF00AAFF), color[4 * 12 + 5]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), color[9 * 12 + 11]);
}
