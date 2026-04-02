const std = @import("std");
const direct_packets = @import("direct_packets.zig");
const direct_primitives = @import("direct_primitives.zig");

pub const DrawList = struct {
    pub const PreparedGouraudEntry = struct {
        triangle: direct_primitives.Triangle2i,
        prepared: direct_primitives.PreparedGouraudTriangle,
        depth_value: ?f32,
        vertex_depths: ?[3]f32,
    };

    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(direct_packets.DrawPacket) = .{},
    command_bounds: std.ArrayListUnmanaged(?direct_primitives.Rect2i) = .{},
    prepared_gouraud: std.ArrayListUnmanaged(?PreparedGouraudEntry) = .{},
    polygon_points: std.ArrayListUnmanaged(direct_primitives.Point2i) = .{},

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DrawList) void {
        self.commands.deinit(self.allocator);
        self.command_bounds.deinit(self.allocator);
        self.prepared_gouraud.deinit(self.allocator);
        self.polygon_points.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.command_bounds.clearRetainingCapacity();
        self.prepared_gouraud.clearRetainingCapacity();
        self.polygon_points.clearRetainingCapacity();
    }

    pub fn ensureCommandCapacity(self: *DrawList, count: usize) !void {
        try self.commands.ensureTotalCapacity(self.allocator, count);
        try self.command_bounds.ensureTotalCapacity(self.allocator, count);
        try self.prepared_gouraud.ensureTotalCapacity(self.allocator, count);
    }

    pub fn ensurePolygonPointCapacity(self: *DrawList, count: usize) !void {
        try self.polygon_points.ensureTotalCapacity(self.allocator, count);
    }

    pub fn items(self: *const DrawList) []const direct_packets.DrawPacket {
        return self.commands.items;
    }

    pub fn bounds(self: *const DrawList) []const ?direct_primitives.Rect2i {
        return self.command_bounds.items;
    }

    pub fn preparedGouraud(self: *const DrawList) []const ?PreparedGouraudEntry {
        return self.prepared_gouraud.items;
    }

    pub fn disablePreparedGouraud(self: *DrawList) void {
        @memset(self.prepared_gouraud.items, null);
        for (self.commands.items) |*packet| {
            if (packet.payload == .triangle) {
                packet.payload.triangle.gouraud_setup = null;
            }
        }
    }

    pub fn append(self: *DrawList, packet: direct_packets.DrawPacket) !void {
        try self.commands.append(self.allocator, packet);
        try self.command_bounds.append(self.allocator, direct_primitives.packetBounds(packet));
        try self.prepared_gouraud.append(self.allocator, cachePreparedGouraud(packet));
    }

    pub fn appendProjectedTriangle(
        self: *DrawList,
        sort_key: u64,
        material: direct_packets.SurfaceMaterial,
        triangle: direct_primitives.Triangle2i,
        vertex_colors: ?[3]u32,
        vertex_depths: ?[3]f32,
        gouraud_setup: ?direct_primitives.PreparedGouraudTriangle,
    ) !void {
        const packet: direct_packets.DrawPacket = .{
            .sort_key = sort_key,
            .layer = .geometry,
            .flags = .{},
            .material = .{ .surface = material },
            .payload = .{ .triangle = .{
                .triangle = triangle,
                .vertex_colors = vertex_colors,
                .vertex_depths = vertex_depths,
                .gouraud_setup = gouraud_setup,
            } },
        };
        try self.commands.append(self.allocator, packet);
        try self.command_bounds.append(self.allocator, .{
            .min_x = @min(triangle.a.x, @min(triangle.b.x, triangle.c.x)),
            .min_y = @min(triangle.a.y, @min(triangle.b.y, triangle.c.y)),
            .max_x = @max(triangle.a.x, @max(triangle.b.x, triangle.c.x)),
            .max_y = @max(triangle.a.y, @max(triangle.b.y, triangle.c.y)),
        });
        try self.prepared_gouraud.append(self.allocator, if (gouraud_setup != null and material.outline_color == null)
            .{
                .triangle = triangle,
                .prepared = gouraud_setup.?,
                .depth_value = material.depth,
                .vertex_depths = vertex_depths,
            }
        else
            null);
    }

    pub fn appendProjectedTriangleAssumeCapacity(
        self: *DrawList,
        sort_key: u64,
        material: direct_packets.SurfaceMaterial,
        triangle: direct_primitives.Triangle2i,
        vertex_colors: ?[3]u32,
        vertex_depths: ?[3]f32,
        gouraud_setup: ?direct_primitives.PreparedGouraudTriangle,
    ) void {
        const packet: direct_packets.DrawPacket = .{
            .sort_key = sort_key,
            .layer = .geometry,
            .flags = .{},
            .material = .{ .surface = material },
            .payload = .{ .triangle = .{
                .triangle = triangle,
                .vertex_colors = vertex_colors,
                .vertex_depths = vertex_depths,
                .gouraud_setup = gouraud_setup,
            } },
        };
        self.commands.appendAssumeCapacity(packet);
        self.command_bounds.appendAssumeCapacity(.{
            .min_x = @min(triangle.a.x, @min(triangle.b.x, triangle.c.x)),
            .min_y = @min(triangle.a.y, @min(triangle.b.y, triangle.c.y)),
            .max_x = @max(triangle.a.x, @max(triangle.b.x, triangle.c.x)),
            .max_y = @max(triangle.a.y, @max(triangle.b.y, triangle.c.y)),
        });
        self.prepared_gouraud.appendAssumeCapacity(if (gouraud_setup != null and material.outline_color == null)
            .{
                .triangle = triangle,
                .prepared = gouraud_setup.?,
                .depth_value = material.depth,
                .vertex_depths = vertex_depths,
            }
        else
            null);
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

inline fn cachePreparedGouraud(packet: direct_packets.DrawPacket) ?DrawList.PreparedGouraudEntry {
    if (packet.payload != .triangle or packet.material != .surface) return null;
    const payload = packet.payload.triangle;
    const surface = packet.material.surface;
    const prepared = payload.gouraud_setup orelse return null;
    if (surface.outline_color != null) return null;
    if (!packet.flags.depth_write and !packet.flags.depth_test) return null;
    return .{
        .triangle = payload.triangle,
        .prepared = prepared,
        .depth_value = if (packet.flags.depth_write) surface.depth else null,
        .vertex_depths = payload.vertex_depths,
    };
}

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
