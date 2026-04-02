const std = @import("std");
const math = @import("../core/math.zig");
const camera_controller = @import("camera_controller.zig");
const direct_draw_list = @import("direct_draw_list.zig");
const direct_packets = @import("direct_packets.zig");
const direct_primitives = @import("direct_primitives.zig");

pub const max_polygon_points = 8;
pub const near_plane: f32 = 0.1;

pub const Camera = struct {
    position: math.Vec3,
    yaw: f32,
    pitch: f32,
    fov_deg: f32,
};

pub const WorldLine = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const WorldTriangle = struct {
    a: math.Vec3,
    b: math.Vec3,
    c: math.Vec3,
};

pub const WorldPolygon = struct {
    point_count: u8,
    points: [max_polygon_points]math.Vec3,

    pub fn fromSlice(points: []const math.Vec3) !WorldPolygon {
        if (points.len == 0 or points.len > max_polygon_points) return error.InvalidPolygonPointCount;
        var copied = [_]math.Vec3{math.Vec3.new(0.0, 0.0, 0.0)} ** max_polygon_points;
        for (points, 0..) |point, index| copied[index] = point;
        return .{
            .point_count = @intCast(points.len),
            .points = copied,
        };
    }

    pub fn slice(self: *const WorldPolygon) []const math.Vec3 {
        return self.points[0..self.point_count];
    }
};

pub const WorldCircle = struct {
    center: math.Vec3,
    radius: f32,
};

pub const StrokeMaterial = direct_packets.StrokeMaterial;
pub const SurfaceMaterial = direct_packets.SurfaceMaterial;

pub const DrawPacket = union(enum) {
    line: struct {
        line: WorldLine,
        material: StrokeMaterial,
    },
    triangle: struct {
        triangle: WorldTriangle,
        material: SurfaceMaterial,
    },
    polygon: struct {
        polygon: WorldPolygon,
        material: SurfaceMaterial,
    },
    circle: struct {
        circle: WorldCircle,
        material: SurfaceMaterial,
    },
};

pub const PrimitiveBatch = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(DrawPacket) = .{},

    pub fn init(allocator: std.mem.Allocator) PrimitiveBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrimitiveBatch) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *PrimitiveBatch) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn items(self: *const PrimitiveBatch) []const DrawPacket {
        return self.commands.items;
    }

    pub fn append(self: *PrimitiveBatch, command: DrawPacket) !void {
        try self.commands.append(self.allocator, command);
    }

    pub fn appendLine(self: *PrimitiveBatch, line: WorldLine, material: StrokeMaterial) !void {
        try self.append(.{ .line = .{ .line = line, .material = material } });
    }

    pub fn appendTriangle(self: *PrimitiveBatch, triangle: WorldTriangle, material: SurfaceMaterial) !void {
        try self.append(.{ .triangle = .{ .triangle = triangle, .material = material } });
    }

    pub fn appendPolygon(self: *PrimitiveBatch, points: []const math.Vec3, material: SurfaceMaterial) !void {
        try self.append(.{ .polygon = .{
            .polygon = try WorldPolygon.fromSlice(points),
            .material = material,
        } });
    }

    pub fn appendCircle(self: *PrimitiveBatch, circle: WorldCircle, material: SurfaceMaterial) !void {
        try self.append(.{ .circle = .{ .circle = circle, .material = material } });
    }
};

const Projector = struct {
    camera: Camera,
    width: i32,
    height: i32,
    basis: camera_controller.ViewBasis,
    projection: camera_controller.ProjectionScalars,

    fn init(camera: Camera, width: i32, height: i32) Projector {
        return .{
            .camera = camera,
            .width = width,
            .height = height,
            .basis = camera_controller.computeViewBasis(camera.yaw, camera.pitch),
            .projection = camera_controller.computeProjectionScalars(width, height, camera.fov_deg),
        };
    }

    fn project(self: *const Projector, point: math.Vec3) ?direct_primitives.Point2i {
        const relative = math.Vec3.sub(point, self.camera.position);
        const camera_x = math.Vec3.dot(relative, self.basis.right);
        const camera_y = math.Vec3.dot(relative, self.basis.up);
        const camera_z = math.Vec3.dot(relative, self.basis.forward);
        if (camera_z <= near_plane) return null;

        const ndc_x = (camera_x / camera_z) * self.projection.x_scale;
        const ndc_y = (camera_y / camera_z) * self.projection.y_scale;
        return .{
            .x = @intFromFloat(self.projection.center_x + ndc_x * self.projection.center_x),
            .y = @intFromFloat(self.projection.center_y - ndc_y * self.projection.center_y),
        };
    }

    fn projectCircleRadius(self: *const Projector, center: math.Vec3, radius: f32) ?i32 {
        const center_screen = self.project(center) orelse return null;
        const offset_world = math.Vec3.add(center, math.Vec3.scale(self.basis.right, radius));
        const edge_screen = self.project(offset_world) orelse return null;
        const dx = edge_screen.x - center_screen.x;
        const dy = edge_screen.y - center_screen.y;
        const radius_px = @as(i32, @intFromFloat(std.math.sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)))));
        if (radius_px <= 0) return null;
        return radius_px;
    }
};

pub fn compileToDrawList(
    batch: *const PrimitiveBatch,
    draw_list: *direct_draw_list.DrawList,
    camera: Camera,
    width: i32,
    height: i32,
) !void {
    draw_list.clearRetainingCapacity();
    if (width <= 0 or height <= 0) return;

    const projector = Projector.init(camera, width, height);
    for (batch.items(), 0..) |command, packet_index| {
        const sort_key = makeSortKey(command, packet_index);
        switch (command) {
            .line => |payload| {
                const start = projector.project(payload.line.start) orelse continue;
                const end = projector.project(payload.line.end) orelse continue;
                try draw_list.append(.{
                    .sort_key = sort_key,
                    .layer = .geometry,
                    .flags = .{ .depth_test = false, .depth_write = false },
                    .material = .{ .stroke = payload.material },
                    .payload = .{ .line = .{ .start = start, .end = end } },
                });
            },
            .triangle => |payload| {
                const a = projector.project(payload.triangle.a) orelse continue;
                const b = projector.project(payload.triangle.b) orelse continue;
                const c = projector.project(payload.triangle.c) orelse continue;
                try draw_list.append(.{
                    .sort_key = sort_key,
                    .layer = .geometry,
                    .flags = .{},
                    .material = .{ .surface = payload.material },
                    .payload = .{ .triangle = .{ .a = a, .b = b, .c = c } },
                });
            },
            .polygon => |payload| {
                var projected: [max_polygon_points]direct_primitives.Point2i = undefined;
                var visible_count: usize = 0;
                for (payload.polygon.slice()) |point| {
                    const projected_point = projector.project(point) orelse {
                        visible_count = 0;
                        break;
                    };
                    projected[visible_count] = projected_point;
                    visible_count += 1;
                }
                if (visible_count >= 3) {
                    const start = draw_list.polygon_points.items.len;
                    try draw_list.polygon_points.appendSlice(draw_list.allocator, projected[0..visible_count]);
                    try draw_list.append(.{
                        .sort_key = sort_key,
                        .layer = .geometry,
                        .flags = .{},
                        .material = .{ .surface = payload.material },
                        .payload = .{ .polygon = .{
                            .points = draw_list.polygon_points.items[start .. start + visible_count],
                        } },
                    });
                }
            },
            .circle => |payload| {
                const center = projector.project(payload.circle.center) orelse continue;
                const radius = projector.projectCircleRadius(payload.circle.center, payload.circle.radius) orelse continue;
                try draw_list.append(.{
                    .sort_key = sort_key,
                    .layer = .geometry,
                    .flags = .{},
                    .material = .{ .surface = payload.material },
                    .payload = .{ .circle = .{ .center = center, .radius = radius } },
                });
            },
        }
    }
}

fn makeSortKey(command: DrawPacket, packet_index: usize) u64 {
    const depth_component: u32 = switch (command) {
        .line => |payload| encodeDepth(payload.material.depth),
        .triangle => |payload| encodeDepth(payload.material.depth),
        .polygon => |payload| encodeDepth(payload.material.depth),
        .circle => |payload| encodeDepth(payload.material.depth),
    };
    return (@as(u64, depth_component) << 32) | @as(u64, @intCast(packet_index));
}

fn encodeDepth(depth: ?f32) u32 {
    if (depth == null) return 0;
    const scaled = std.math.clamp(depth.?, 0.0, 65535.0) * 1024.0;
    return @intFromFloat(scaled);
}

test "compile world triangle into draw list" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try batch.appendTriangle(.{
        .a = math.Vec3.new(0.0, 0.5, 0.0),
        .b = math.Vec3.new(-0.5, -0.5, 0.0),
        .c = math.Vec3.new(0.5, -0.5, 0.0),
    }, .{ .fill_color = 0xFFFFFFFF });

    try compileToDrawList(&batch, &draw_list, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 1), draw_list.items().len);
    try std.testing.expect(draw_list.items()[0].payload == .triangle);
}
