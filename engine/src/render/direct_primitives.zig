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
    color: ?u32 = null,
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
    if (config.color) |color| fillU32(target.color, color);
    if (config.depth) |depth_value| {
        if (target.depth) |depth_buffer| {
            fillF32(depth_buffer, depth_value);
        }
    }
}

pub fn clearRect(target: FrameTarget, rect: Rect2i, config: ClearConfig) void {
    const bounds = intersectRect(targetBounds(target), rect) orelse return;
    const stride: usize = @intCast(target.width);

    if (config.color) |color| {
        var y = bounds.min_y;
        while (y <= bounds.max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(bounds.min_x));
            const row_end = row_start + @as(usize, @intCast(bounds.max_x - bounds.min_x + 1));
            fillU32(target.color[row_start..row_end], color);
        }
    }
    if (config.depth) |depth_value| {
        if (target.depth) |depth_buffer| {
            var y = bounds.min_y;
            while (y <= bounds.max_y) : (y += 1) {
                const row_start = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(bounds.min_x));
                const row_end = row_start + @as(usize, @intCast(bounds.max_x - bounds.min_x + 1));
                fillF32(depth_buffer[row_start..row_end], depth_value);
            }
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
            drawSolidTriangle(target, triangle, style.fill_color, if (packet.flags.depth_write) style.depth else null);
            if (style.outline_color) |outline_color| {
                drawLine(target, .{ .start = triangle.a, .end = triangle.b }, .{ .color = outline_color });
                drawLine(target, .{ .start = triangle.b, .end = triangle.c }, .{ .color = outline_color });
                drawLine(target, .{ .start = triangle.c, .end = triangle.a }, .{ .color = outline_color });
            }
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

pub fn packetBounds(packet: direct_packets.DrawPacket) ?Rect2i {
    return switch (packet.payload) {
        .line => |line| .{
            .min_x = @min(line.start.x, line.end.x),
            .min_y = @min(line.start.y, line.end.y),
            .max_x = @max(line.start.x, line.end.x),
            .max_y = @max(line.start.y, line.end.y),
        },
        .triangle => |triangle| .{
            .min_x = @min(triangle.a.x, @min(triangle.b.x, triangle.c.x)),
            .min_y = @min(triangle.a.y, @min(triangle.b.y, triangle.c.y)),
            .max_x = @max(triangle.a.x, @max(triangle.b.x, triangle.c.x)),
            .max_y = @max(triangle.a.y, @max(triangle.b.y, triangle.c.y)),
        },
        .polygon => |polygon| polygonBounds(polygon.points),
        .circle => |circle| .{
            .min_x = circle.center.x - circle.radius,
            .min_y = circle.center.y - circle.radius,
            .max_x = circle.center.x + circle.radius,
            .max_y = circle.center.y + circle.radius,
        },
    };
}

pub fn drawMany(target: FrameTarget, commands: []const Command) void {
    for (commands) |command| draw(target, command);
}

pub fn drawLine(target: FrameTarget, line: Line2i, style: LineStyle) void {
    const bounds = targetBounds(target);
    const clipped = clipLineToRect(line, bounds) orelse return;

    if (clipped.start.y == clipped.end.y) {
        drawHorizontalLine(target, clipped.start.y, @min(clipped.start.x, clipped.end.x), @max(clipped.start.x, clipped.end.x), style.color);
        return;
    }
    if (clipped.start.x == clipped.end.x) {
        drawVerticalLine(target, clipped.start.x, @min(clipped.start.y, clipped.end.y), @max(clipped.start.y, clipped.end.y), style.color);
        return;
    }

    var cx = clipped.start.x;
    var cy = clipped.start.y;

    const dx = if (clipped.end.x >= clipped.start.x) (clipped.end.x - clipped.start.x) else (clipped.start.x - clipped.end.x);
    const dy = if (clipped.end.y >= clipped.start.y) (clipped.end.y - clipped.start.y) else (clipped.start.y - clipped.end.y);
    const sx: i32 = if (clipped.start.x < clipped.end.x) 1 else -1;
    const sy: i32 = if (clipped.start.y < clipped.end.y) 1 else -1;
    var err: i32 = dx - dy;

    while (true) {
        setPixelClippedColorOnly(target, cx, cy, style.color);
        if (cx == clipped.end.x and cy == clipped.end.y) break;

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

fn clipLineToRect(line: Line2i, rect: Rect2i) ?Line2i {
    var x0 = @as(f32, @floatFromInt(line.start.x));
    var y0 = @as(f32, @floatFromInt(line.start.y));
    var x1 = @as(f32, @floatFromInt(line.end.x));
    var y1 = @as(f32, @floatFromInt(line.end.y));

    const dx = x1 - x0;
    const dy = y1 - y0;

    var t0: f32 = 0.0;
    var t1: f32 = 1.0;

    if (!clipLineEdge(-dx, x0 - @as(f32, @floatFromInt(rect.min_x)), &t0, &t1)) return null;
    if (!clipLineEdge(dx, @as(f32, @floatFromInt(rect.max_x)) - x0, &t0, &t1)) return null;
    if (!clipLineEdge(-dy, y0 - @as(f32, @floatFromInt(rect.min_y)), &t0, &t1)) return null;
    if (!clipLineEdge(dy, @as(f32, @floatFromInt(rect.max_y)) - y0, &t0, &t1)) return null;

    if (t1 < t0) return null;

    if (t1 < 1.0) {
        x1 = x0 + t1 * dx;
        y1 = y0 + t1 * dy;
    }
    if (t0 > 0.0) {
        x0 += t0 * dx;
        y0 += t0 * dy;
    }

    return .{
        .start = .{
            .x = @intFromFloat(@round(x0)),
            .y = @intFromFloat(@round(y0)),
        },
        .end = .{
            .x = @intFromFloat(@round(x1)),
            .y = @intFromFloat(@round(y1)),
        },
    };
}

inline fn clipLineEdge(p: f32, q: f32, t0: *f32, t1: *f32) bool {
    if (p == 0.0) return q >= 0.0;
    const r = q / p;
    if (p < 0.0) {
        if (r > t1.*) return false;
        if (r > t0.*) t0.* = r;
        return true;
    }
    if (r < t0.*) return false;
    if (r < t1.*) t1.* = r;
    return true;
}

inline fn setPixelClippedColorOnly(target: FrameTarget, x: i32, y: i32, color: u32) void {
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(target.width)) + @as(usize, @intCast(x));
    target.color[idx] = color;
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

    if (depth_value == null) {
        drawSolidTriangleColorOnly(target, triangle, color, min_x, max_x, min_y, max_y, area);
        return;
    }

    const stride: usize = @intCast(target.width);
    const step_w0_x = edgeStepX(triangle.b, triangle.c);
    const step_w1_x = edgeStepX(triangle.c, triangle.a);
    const step_w2_x = edgeStepX(triangle.a, triangle.b);
    const step_w0_y = edgeStepY(triangle.b, triangle.c);
    const step_w1_y = edgeStepY(triangle.c, triangle.a);
    const step_w2_y = edgeStepY(triangle.a, triangle.b);
    var row_w0 = edgeFunction(triangle.b, triangle.c, min_x, min_y);
    var row_w1 = edgeFunction(triangle.c, triangle.a, min_x, min_y);
    var row_w2 = edgeFunction(triangle.a, triangle.b, min_x, min_y);
    const depth_buffer = target.depth.?;
    var y = min_y;
    const depth = depth_value.?;
    if (area > 0) {
        while (y <= max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride;
            var w0 = row_w0;
            var w1 = row_w1;
            var w2 = row_w2;
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    const idx = row_start + @as(usize, @intCast(x));
                    target.color[idx] = color;
                    depth_buffer[idx] = depth;
                }
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
            }
            row_w0 += step_w0_y;
            row_w1 += step_w1_y;
            row_w2 += step_w2_y;
        }
        return;
    }

    while (y <= max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        var w0 = row_w0;
        var w1 = row_w1;
        var w2 = row_w2;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            if (w0 <= 0 and w1 <= 0 and w2 <= 0) {
                const idx = row_start + @as(usize, @intCast(x));
                target.color[idx] = color;
                depth_buffer[idx] = depth;
            }
            w0 += step_w0_x;
            w1 += step_w1_x;
            w2 += step_w2_x;
        }
        row_w0 += step_w0_y;
        row_w1 += step_w1_y;
        row_w2 += step_w2_y;
    }
}

fn drawSolidTriangleColorOnly(
    target: FrameTarget,
    triangle: Triangle2i,
    color: u32,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
    area: i64,
) void {
    const stride: usize = @intCast(target.width);
    const step_w0_x = edgeStepX(triangle.b, triangle.c);
    const step_w1_x = edgeStepX(triangle.c, triangle.a);
    const step_w2_x = edgeStepX(triangle.a, triangle.b);
    const step_w0_y = edgeStepY(triangle.b, triangle.c);
    const step_w1_y = edgeStepY(triangle.c, triangle.a);
    const step_w2_y = edgeStepY(triangle.a, triangle.b);

    var row_w0 = edgeFunction(triangle.b, triangle.c, min_x, min_y);
    var row_w1 = edgeFunction(triangle.c, triangle.a, min_x, min_y);
    var row_w2 = edgeFunction(triangle.a, triangle.b, min_x, min_y);
    var y = min_y;
    if (area > 0) {
        while (y <= max_y) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride;
            var w0 = row_w0;
            var w1 = row_w1;
            var w2 = row_w2;
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    const idx = row_start + @as(usize, @intCast(x));
                    target.color[idx] = color;
                }
                w0 += step_w0_x;
                w1 += step_w1_x;
                w2 += step_w2_x;
            }
            row_w0 += step_w0_y;
            row_w1 += step_w1_y;
            row_w2 += step_w2_y;
        }
        return;
    }

    while (y <= max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        var w0 = row_w0;
        var w1 = row_w1;
        var w2 = row_w2;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            if (w0 <= 0 and w1 <= 0 and w2 <= 0) {
                const idx = row_start + @as(usize, @intCast(x));
                target.color[idx] = color;
            }
            w0 += step_w0_x;
            w1 += step_w1_x;
            w2 += step_w2_x;
        }
        row_w0 += step_w0_y;
        row_w1 += step_w1_y;
        row_w2 += step_w2_y;
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

    if (style.depth == null and style.fill_color != null and style.outline_color == null) {
        drawFilledCircleColorOnly(target, circle, style.fill_color.?, min_x, max_x, min_y, max_y, radius_sq);
        return;
    }

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

fn drawHorizontalLine(target: FrameTarget, y: i32, min_x: i32, max_x: i32, color: u32) void {
    if (y < 0 or y >= target.height or min_x > max_x) return;
    const bounds = targetBounds(target);
    if (y < bounds.min_y or y > bounds.max_y) return;
    const clamped_min_x = @max(min_x, bounds.min_x);
    const clamped_max_x = @min(max_x, bounds.max_x);
    if (clamped_min_x > clamped_max_x) return;
    const stride: usize = @intCast(target.width);
    const row_start = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(clamped_min_x));
    const row_end = row_start + @as(usize, @intCast(clamped_max_x - clamped_min_x + 1));
    fillU32(target.color[row_start..row_end], color);
}

fn drawVerticalLine(target: FrameTarget, x: i32, min_y: i32, max_y: i32, color: u32) void {
    if (x < 0 or x >= target.width or min_y > max_y) return;
    const bounds = targetBounds(target);
    if (x < bounds.min_x or x > bounds.max_x) return;
    const clamped_min_y = @max(min_y, bounds.min_y);
    const clamped_max_y = @min(max_y, bounds.max_y);
    if (clamped_min_y > clamped_max_y) return;
    const stride: usize = @intCast(target.width);
    var y = clamped_min_y;
    while (y <= clamped_max_y) : (y += 1) {
        const idx = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x));
        target.color[idx] = color;
    }
}

fn drawFilledCircleColorOnly(
    target: FrameTarget,
    circle: Circle2i,
    color: u32,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
    radius_sq: i64,
) void {
    _ = min_y;
    _ = max_y;
    _ = radius_sq;
    var x = circle.radius;
    var y: i32 = 0;
    var decision: i32 = 1 - circle.radius;

    while (y <= x) : (y += 1) {
        drawHorizontalLine(
            target,
            circle.center.y + y,
            @max(min_x, circle.center.x - x),
            @min(max_x, circle.center.x + x),
            color,
        );
        if (y != 0) {
            drawHorizontalLine(
                target,
                circle.center.y - y,
                @max(min_x, circle.center.x - x),
                @min(max_x, circle.center.x + x),
                color,
            );
        }
        if (x != y) {
            drawHorizontalLine(
                target,
                circle.center.y + x,
                @max(min_x, circle.center.x - y),
                @min(max_x, circle.center.x + y),
                color,
            );
            if (x != 0) {
                drawHorizontalLine(
                    target,
                    circle.center.y - x,
                    @max(min_x, circle.center.x - y),
                    @min(max_x, circle.center.x + y),
                    color,
                );
            }
        }

        if (decision < 0) {
            decision += (2 * y) + 3;
        } else {
            decision += (2 * (y - x)) + 5;
            x -= 1;
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

fn edgeStepX(a: Point2i, b: Point2i) i64 {
    return @as(i64, b.y) - @as(i64, a.y);
}

fn edgeStepY(a: Point2i, b: Point2i) i64 {
    return @as(i64, a.x) - @as(i64, b.x);
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

fn polygonBounds(points: []const Point2i) ?Rect2i {
    if (points.len == 0) return null;
    const lanes = comptime std.simd.suggestVectorLength(i32) orelse 0;
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;

    if (lanes >= 4 and points.len >= lanes) {
        const Vec = @Vector(lanes, i32);
        var index: usize = 0;
        var xs: [lanes]i32 = undefined;
        var ys: [lanes]i32 = undefined;
        inline for (0..lanes) |lane| {
            xs[lane] = points[lane].x;
            ys[lane] = points[lane].y;
        }
        var min_x_vec: Vec = @as(Vec, @bitCast(xs));
        var min_y_vec: Vec = @as(Vec, @bitCast(ys));
        var max_x_vec = min_x_vec;
        var max_y_vec = min_y_vec;
        index = lanes;

        while (index + lanes <= points.len) : (index += lanes) {
            inline for (0..lanes) |lane| {
                xs[lane] = points[index + lane].x;
                ys[lane] = points[index + lane].y;
            }
            const x_vec: Vec = @as(Vec, @bitCast(xs));
            const y_vec: Vec = @as(Vec, @bitCast(ys));
            min_x_vec = @min(min_x_vec, x_vec);
            min_y_vec = @min(min_y_vec, y_vec);
            max_x_vec = @max(max_x_vec, x_vec);
            max_y_vec = @max(max_y_vec, y_vec);
        }

        inline for (0..lanes) |lane| {
            min_x = @min(min_x, min_x_vec[lane]);
            min_y = @min(min_y, min_y_vec[lane]);
            max_x = @max(max_x, max_x_vec[lane]);
            max_y = @max(max_y, max_y_vec[lane]);
        }

        for (points[index..]) |point| {
            min_x = @min(min_x, point.x);
            min_y = @min(min_y, point.y);
            max_x = @max(max_x, point.x);
            max_y = @max(max_y, point.y);
        }
    } else {
        for (points[1..]) |point| {
            min_x = @min(min_x, point.x);
            min_y = @min(min_y, point.y);
            max_x = @max(max_x, point.x);
            max_y = @max(max_y, point.y);
        }
    }

    return .{
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
    };
}

pub fn unionRect(a: Rect2i, b: Rect2i) Rect2i {
    return .{
        .min_x = @min(a.min_x, b.min_x),
        .min_y = @min(a.min_y, b.min_y),
        .max_x = @max(a.max_x, b.max_x),
        .max_y = @max(a.max_y, b.max_y),
    };
}

pub fn intersectRect(a: Rect2i, b: Rect2i) ?Rect2i {
    const result = Rect2i{
        .min_x = @max(a.min_x, b.min_x),
        .min_y = @max(a.min_y, b.min_y),
        .max_x = @min(a.max_x, b.max_x),
        .max_y = @min(a.max_y, b.max_y),
    };
    if (result.min_x > result.max_x or result.min_y > result.max_y) return null;
    return result;
}

fn fillU32(dst: []u32, value: u32) void {
    const lanes = comptime std.simd.suggestVectorLength(u32) orelse 0;
    if (lanes >= 4) {
        fillVectorU32(lanes, dst, value);
        return;
    }
    @memset(dst, value);
}

fn fillF32(dst: []f32, value: f32) void {
    const lanes = comptime std.simd.suggestVectorLength(f32) orelse 0;
    if (lanes >= 4) {
        fillVectorF32(lanes, dst, value);
        return;
    }
    @memset(dst, value);
}

fn fillVectorU32(comptime lanes: usize, dst: []u32, value: u32) void {
    const Vec = @Vector(lanes, u32);
    const fill: Vec = @splat(value);
    var index: usize = 0;
    while (index + lanes <= dst.len) : (index += lanes) {
        const vec_ptr: *align(1) Vec = @ptrCast(dst[index..].ptr);
        vec_ptr.* = fill;
    }
    if (index < dst.len) @memset(dst[index..], value);
}

fn fillVectorF32(comptime lanes: usize, dst: []f32, value: f32) void {
    const Vec = @Vector(lanes, f32);
    const fill: Vec = @splat(value);
    var index: usize = 0;
    while (index + lanes <= dst.len) : (index += lanes) {
        const vec_ptr: *align(1) Vec = @ptrCast(dst[index..].ptr);
        vec_ptr.* = fill;
    }
    if (index < dst.len) @memset(dst[index..], value);
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
