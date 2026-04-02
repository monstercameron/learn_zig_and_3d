const std = @import("std");
const direct_packets = @import("direct_packets.zig");
const direct_primitives = @import("direct_primitives.zig");

pub const DrawList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(direct_packets.DrawPacket) = .{},
    polygon_points: std.ArrayListUnmanaged(direct_primitives.Point2i) = .{},

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DrawList) void {
        self.commands.deinit(self.allocator);
        self.polygon_points.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.polygon_points.clearRetainingCapacity();
    }

    pub fn ensureCommandCapacity(self: *DrawList, count: usize) !void {
        try self.commands.ensureTotalCapacity(self.allocator, count);
    }

    pub fn ensurePolygonPointCapacity(self: *DrawList, count: usize) !void {
        try self.polygon_points.ensureTotalCapacity(self.allocator, count);
    }

    pub fn items(self: *const DrawList) []const direct_packets.DrawPacket {
        return self.commands.items;
    }

    pub fn append(self: *DrawList, packet: direct_packets.DrawPacket) !void {
        try self.commands.append(self.allocator, packet);
    }

    pub fn appendLine(self: *DrawList, line: direct_primitives.Line2i, style: direct_primitives.LineStyle) !void {
        try self.append(.{
            .material = .{ .stroke = .{ .color = style.color } },
            .payload = .{ .line = line },
        });
    }

    pub fn appendTriangle(self: *DrawList, triangle: direct_primitives.Triangle2i, style: direct_primitives.TriangleStyle) !void {
        try self.append(.{
            .material = .{ .surface = .{
                .fill_color = style.fill_color,
                .outline_color = style.outline_color,
                .depth = style.depth,
            } },
            .payload = .{ .triangle = triangle },
        });
    }

    pub fn appendPolygon(self: *DrawList, polygon: direct_primitives.Polygon2i, style: direct_primitives.PolygonStyle) !void {
        const start = self.polygon_points.items.len;
        try self.polygon_points.appendSlice(self.allocator, polygon.points);
        try self.append(.{
            .material = .{ .surface = .{
                .fill_color = style.fill_color,
                .outline_color = style.outline_color,
                .depth = style.depth,
            } },
            .payload = .{ .polygon = .{
                .points = self.polygon_points.items[start .. start + polygon.points.len],
            } },
        });
    }

    pub fn appendCircle(self: *DrawList, circle: direct_primitives.Circle2i, style: direct_primitives.CircleStyle) !void {
        try self.append(.{
            .material = .{ .surface = .{
                .fill_color = style.fill_color orelse 0,
                .outline_color = style.outline_color,
                .depth = style.depth,
            } },
            .payload = .{ .circle = circle },
        });
    }
};

test "draw list appends typed commands" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try draw_list.appendLine(.{
        .start = .{ .x = 1, .y = 2 },
        .end = .{ .x = 3, .y = 4 },
    }, .{ .color = 0xFFFFFFFF });
    try draw_list.appendCircle(.{
        .center = .{ .x = 5, .y = 6 },
        .radius = 7,
    }, .{ .fill_color = 0xFF00FF00 });

    try std.testing.expectEqual(@as(usize, 2), draw_list.items().len);
    try std.testing.expect(draw_list.items()[0].payload == .line);
    try std.testing.expect(draw_list.items()[1].payload == .circle);
}

test "draw list owns polygon point storage" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    var points = [_]direct_primitives.Point2i{
        .{ .x = 1, .y = 1 },
        .{ .x = 4, .y = 1 },
        .{ .x = 3, .y = 5 },
    };
    try draw_list.appendPolygon(.{ .points = points[0..] }, .{ .fill_color = 0xFFFFFFFF });

    points[0] = .{ .x = 99, .y = 99 };
    try std.testing.expect(draw_list.items()[0].payload == .polygon);
    try std.testing.expectEqual(@as(i32, 1), draw_list.items()[0].payload.polygon.points[0].x);
}
