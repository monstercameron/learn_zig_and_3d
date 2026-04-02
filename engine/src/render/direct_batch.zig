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

    pub fn ensureCommandCapacity(self: *PrimitiveBatch, count: usize) !void {
        try self.commands.ensureTotalCapacity(self.allocator, count);
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

    fn projectPoints(self: *const Projector, points: []const math.Vec3, out: []direct_primitives.Point2i) bool {
        std.debug.assert(out.len >= points.len);
        const lanes = comptime std.simd.suggestVectorLength(f32) orelse 0;
        if (lanes < 4 or points.len < 4) {
            for (points, 0..) |point, index| {
                out[index] = self.project(point) orelse return false;
            }
            return true;
        }

        const Vec = @Vector(lanes, f32);
        const pos_x: Vec = @splat(self.camera.position.x);
        const pos_y: Vec = @splat(self.camera.position.y);
        const pos_z: Vec = @splat(self.camera.position.z);
        const right_x: Vec = @splat(self.basis.right.x);
        const right_y: Vec = @splat(self.basis.right.y);
        const right_z: Vec = @splat(self.basis.right.z);
        const up_x: Vec = @splat(self.basis.up.x);
        const up_y: Vec = @splat(self.basis.up.y);
        const up_z: Vec = @splat(self.basis.up.z);
        const forward_x: Vec = @splat(self.basis.forward.x);
        const forward_y: Vec = @splat(self.basis.forward.y);
        const forward_z: Vec = @splat(self.basis.forward.z);
        const x_scale: Vec = @splat(self.projection.x_scale);
        const y_scale: Vec = @splat(self.projection.y_scale);
        const center_x: Vec = @splat(self.projection.center_x);
        const center_y: Vec = @splat(self.projection.center_y);

        var index: usize = 0;
        while (index + lanes <= points.len) : (index += lanes) {
            var xs: [lanes]f32 = undefined;
            var ys: [lanes]f32 = undefined;
            var zs: [lanes]f32 = undefined;
            inline for (0..lanes) |lane| {
                const point = points[index + lane];
                xs[lane] = point.x;
                ys[lane] = point.y;
                zs[lane] = point.z;
            }

            const rel_x: Vec = @as(Vec, @bitCast(xs)) - pos_x;
            const rel_y: Vec = @as(Vec, @bitCast(ys)) - pos_y;
            const rel_z: Vec = @as(Vec, @bitCast(zs)) - pos_z;
            const camera_x = rel_x * right_x + rel_y * right_y + rel_z * right_z;
            const camera_y = rel_x * up_x + rel_y * up_y + rel_z * up_z;
            const camera_z = rel_x * forward_x + rel_y * forward_y + rel_z * forward_z;
            inline for (0..lanes) |lane| {
                if (camera_z[lane] <= near_plane) return false;
            }
            const inv_z = @as(Vec, @splat(1.0)) / camera_z;
            const ndc_x = (camera_x * inv_z) * x_scale;
            const ndc_y = (camera_y * inv_z) * y_scale;
            const screen_x = center_x + ndc_x * center_x;
            const screen_y = center_y - ndc_y * center_y;

            inline for (0..lanes) |lane| {
                out[index + lane] = .{
                    .x = @intFromFloat(screen_x[lane]),
                    .y = @intFromFloat(screen_y[lane]),
                };
            }
        }

        while (index < points.len) : (index += 1) {
            out[index] = self.project(points[index]) orelse return false;
        }
        return true;
    }

    fn projectCircleRadius(self: *const Projector, center: math.Vec3, radius: f32) ?i32 {
        const offset_world = math.Vec3.add(center, math.Vec3.scale(self.basis.right, radius));
        const points = [_]math.Vec3{ center, offset_world };
        var projected: [2]direct_primitives.Point2i = undefined;
        if (!self.projectPoints(points[0..], projected[0..])) return null;
        const center_screen = projected[0];
        const edge_screen = projected[1];
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

    var polygon_point_count: usize = 0;
    for (batch.items()) |command| switch (command) {
        .polygon => |payload| polygon_point_count += payload.polygon.point_count,
        else => {},
    };
    try draw_list.ensureCommandCapacity(batch.items().len);
    try draw_list.ensurePolygonPointCapacity(polygon_point_count);

    const projector = Projector.init(camera, width, height);
    for (batch.items(), 0..) |command, packet_index| {
        const sort_key = makeSortKey(command, packet_index);
        switch (command) {
            .line => |payload| {
                const points = [_]math.Vec3{ payload.line.start, payload.line.end };
                var projected: [2]direct_primitives.Point2i = undefined;
                if (!projector.projectPoints(points[0..], projected[0..])) continue;
                try draw_list.append(.{
                    .sort_key = sort_key,
                    .layer = .geometry,
                    .flags = .{ .depth_test = false, .depth_write = false },
                    .material = .{ .stroke = payload.material },
                    .payload = .{ .line = .{ .start = projected[0], .end = projected[1] } },
                });
            },
            .triangle => |payload| {
                const points = [_]math.Vec3{ payload.triangle.a, payload.triangle.b, payload.triangle.c };
                var projected: [3]direct_primitives.Point2i = undefined;
                if (!projector.projectPoints(points[0..], projected[0..])) continue;
                try draw_list.append(.{
                    .sort_key = sort_key,
                    .layer = .geometry,
                    .flags = .{},
                    .material = .{ .surface = payload.material },
                    .payload = .{ .triangle = .{ .a = projected[0], .b = projected[1], .c = projected[2] } },
                });
            },
            .polygon => |payload| {
                var projected: [max_polygon_points]direct_primitives.Point2i = undefined;
                const visible_count = payload.polygon.slice().len;
                if (!projector.projectPoints(payload.polygon.slice(), projected[0..visible_count])) continue;
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
