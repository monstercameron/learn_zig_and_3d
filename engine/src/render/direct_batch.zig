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
        const relative = math.Vec3.sub(center, self.camera.position);
        const camera_z = math.Vec3.dot(relative, self.basis.forward);
        if (camera_z <= near_plane) return null;
        const radius_px = @as(i32, @intFromFloat(@abs((radius / camera_z) * self.projection.x_scale * self.projection.center_x)));
        if (radius_px <= 0) return null;
        return radius_px;
    }

    fn projectLine(self: *const Projector, start: math.Vec3, end: math.Vec3, out: *[2]direct_primitives.Point2i) bool {
        const points = [_]math.Vec3{ start, end };
        return self.projectSmallPoints(points[0..], out[0..], 2);
    }

    fn projectTriangle(self: *const Projector, a: math.Vec3, b: math.Vec3, c: math.Vec3, out: *[3]direct_primitives.Point2i) bool {
        const points = [_]math.Vec3{ a, b, c };
        return self.projectSmallPoints(points[0..], out[0..], 3);
    }

    fn projectSmallPoints(self: *const Projector, points: []const math.Vec3, out: []direct_primitives.Point2i, comptime count: usize) bool {
        std.debug.assert(points.len == count);
        std.debug.assert(out.len >= count);

        if (comptime count == 0) return true;
        if (comptime count >= 4) return self.projectPoints(points, out);

        const Vec = @Vector(4, f32);
        const pos_x: Vec = .{ self.camera.position.x, self.camera.position.x, self.camera.position.x, self.camera.position.x };
        const pos_y: Vec = .{ self.camera.position.y, self.camera.position.y, self.camera.position.y, self.camera.position.y };
        const pos_z: Vec = .{ self.camera.position.z, self.camera.position.z, self.camera.position.z, self.camera.position.z };
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

        var xs = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
        var ys = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
        var zs = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
        inline for (0..count) |index| {
            xs[index] = points[index].x;
            ys[index] = points[index].y;
            zs[index] = points[index].z;
        }

        const rel_x: Vec = @as(Vec, @bitCast(xs)) - pos_x;
        const rel_y: Vec = @as(Vec, @bitCast(ys)) - pos_y;
        const rel_z: Vec = @as(Vec, @bitCast(zs)) - pos_z;
        const camera_x = rel_x * right_x + rel_y * right_y + rel_z * right_z;
        const camera_y = rel_x * up_x + rel_y * up_y + rel_z * up_z;
        const camera_z = rel_x * forward_x + rel_y * forward_y + rel_z * forward_z;

        inline for (0..count) |index| {
            if (camera_z[index] <= near_plane) return false;
        }

        const inv_z = @as(Vec, @splat(1.0)) / camera_z;
        const screen_x = center_x + (camera_x * inv_z) * x_scale * center_x;
        const screen_y = center_y - (camera_y * inv_z) * y_scale * center_y;

        inline for (0..count) |index| {
            out[index] = .{
                .x = @intFromFloat(screen_x[index]),
                .y = @intFromFloat(screen_y[index]),
            };
        }
        return true;
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
                var projected: [2]direct_primitives.Point2i = undefined;
                if (!projector.projectLine(payload.line.start, payload.line.end, &projected)) continue;
                try draw_list.append(.{
                    .sort_key = sort_key,
                    .layer = .geometry,
                    .flags = .{ .depth_test = false, .depth_write = false },
                    .material = .{ .stroke = payload.material },
                    .payload = .{ .line = .{ .start = projected[0], .end = projected[1] } },
                });
            },
            .triangle => |payload| {
                var projected: [3]direct_primitives.Point2i = undefined;
                if (!projector.projectTriangle(payload.triangle.a, payload.triangle.b, payload.triangle.c, &projected)) continue;
                if (!projectedTriangleFrontFacing(projected[0], projected[1], projected[2])) continue;
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
                if (!projectedPolygonFrontFacing(projected[0..visible_count])) continue;
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

inline fn makeSortKey(command: DrawPacket, packet_index: usize) u64 {
    const depth_component: u32 = switch (command) {
        .line => |payload| encodeDepth(payload.material.depth),
        .triangle => |payload| encodeDepth(payload.material.depth),
        .polygon => |payload| encodeDepth(payload.material.depth),
        .circle => |payload| encodeDepth(payload.material.depth),
    };
    return (@as(u64, depth_component) << 32) | @as(u64, @intCast(packet_index));
}

inline fn projectedTriangleFrontFacing(a: direct_primitives.Point2i, b: direct_primitives.Point2i, c: direct_primitives.Point2i) bool {
    return signedArea2(a, b, c) < 0;
}

fn projectedPolygonFrontFacing(points: []const direct_primitives.Point2i) bool {
    if (points.len < 3) return false;
    var area2: i64 = 0;
    const lanes = comptime std.simd.suggestVectorLength(i64) orelse 0;
    const edge_count = points.len - 1;
    if (lanes >= 4 and edge_count >= lanes) {
        const Vec = @Vector(lanes, i64);
        var index: usize = 0;
        var cur_xs: [lanes]i64 = undefined;
        var cur_ys: [lanes]i64 = undefined;
        var next_xs: [lanes]i64 = undefined;
        var next_ys: [lanes]i64 = undefined;

        while (index + lanes <= edge_count) : (index += lanes) {
            inline for (0..lanes) |lane| {
                const current = points[index + lane];
                const next = points[index + lane + 1];
                cur_xs[lane] = current.x;
                cur_ys[lane] = current.y;
                next_xs[lane] = next.x;
                next_ys[lane] = next.y;
            }
            const cur_x: Vec = @as(Vec, @bitCast(cur_xs));
            const cur_y: Vec = @as(Vec, @bitCast(cur_ys));
            const next_x: Vec = @as(Vec, @bitCast(next_xs));
            const next_y: Vec = @as(Vec, @bitCast(next_ys));
            const cross = cur_x * next_y - next_x * cur_y;
            inline for (0..lanes) |lane| area2 += cross[lane];
        }

        for (index..edge_count) |tail_index| {
            const point = points[tail_index];
            const next = points[tail_index + 1];
            area2 += @as(i64, point.x) * @as(i64, next.y) - @as(i64, next.x) * @as(i64, point.y);
        }
        const last = points[points.len - 1];
        const first = points[0];
        area2 += @as(i64, last.x) * @as(i64, first.y) - @as(i64, first.x) * @as(i64, last.y);
        return area2 < 0;
    }

    for (0..edge_count) |index| {
        const point = points[index];
        const next = points[index + 1];
        area2 += @as(i64, point.x) * @as(i64, next.y) - @as(i64, next.x) * @as(i64, point.y);
    }
    const last = points[points.len - 1];
    const first = points[0];
    area2 += @as(i64, last.x) * @as(i64, first.y) - @as(i64, first.x) * @as(i64, last.y);
    return area2 < 0;
}

inline fn signedArea2(a: direct_primitives.Point2i, b: direct_primitives.Point2i, c: direct_primitives.Point2i) i64 {
    return (@as(i64, b.x) - @as(i64, a.x)) * (@as(i64, c.y) - @as(i64, a.y)) -
        (@as(i64, b.y) - @as(i64, a.y)) * (@as(i64, c.x) - @as(i64, a.x));
}

inline fn encodeDepth(depth: ?f32) u32 {
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
