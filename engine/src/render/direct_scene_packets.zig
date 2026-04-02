const std = @import("std");
const math = @import("../core/math.zig");
const job_system = @import("job_system");
const direct_batch = @import("direct_batch.zig");
const direct_mesh = @import("direct_mesh.zig");
const direct_meshlets = @import("direct_meshlets.zig");

const JobSystem = job_system.JobSystem;

pub const WorldPacket = struct {
    layer: @import("direct_packets.zig").RenderLayer = .geometry,
    flags: @import("direct_packets.zig").PacketFlags = .{},
    transform: math.Mat4 = math.Mat4.identity(),
    source: Source,
};

pub const Source = union(enum) {
    line: struct {
        line: direct_batch.WorldLine,
        material: direct_batch.StrokeMaterial,
    },
    triangle: struct {
        triangle: direct_batch.WorldTriangle,
        material: direct_batch.SurfaceMaterial,
    },
    polygon: struct {
        polygon: direct_batch.WorldPolygon,
        material: direct_batch.SurfaceMaterial,
    },
    circle: struct {
        circle: direct_batch.WorldCircle,
        material: direct_batch.SurfaceMaterial,
    },
    mesh: struct {
        mesh: *const direct_mesh.Mesh,
        material_override: ?direct_batch.SurfaceMaterial = null,
    },
    meshlets: struct {
        mesh: *direct_meshlets.Mesh,
        material_override: ?direct_batch.SurfaceMaterial = null,
    },
};

pub const PacketList = struct {
    allocator: std.mem.Allocator,
    packets: std.ArrayListUnmanaged(WorldPacket) = .{},

    pub fn init(allocator: std.mem.Allocator) PacketList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PacketList) void {
        self.packets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *PacketList) void {
        self.packets.clearRetainingCapacity();
    }

    pub fn items(self: *const PacketList) []const WorldPacket {
        return self.packets.items;
    }

    pub fn append(self: *PacketList, packet: WorldPacket) !void {
        try self.packets.append(self.allocator, packet);
    }
};

pub fn compileToPrimitiveBatch(
    list: *PacketList,
    batch: *direct_batch.PrimitiveBatch,
    camera: direct_batch.Camera,
    visible_meshlets: *direct_meshlets.VisibleMeshlets,
    job_sys: ?*JobSystem,
) !void {
    batch.clearRetainingCapacity();
    for (list.items()) |packet| {
        switch (packet.source) {
            .line => |payload| {
                try batch.appendLine(.{
                    .start = packet.transform.mulVec3(payload.line.start),
                    .end = packet.transform.mulVec3(payload.line.end),
                }, payload.material);
            },
            .triangle => |payload| {
                try batch.appendTriangle(.{
                    .a = packet.transform.mulVec3(payload.triangle.a),
                    .b = packet.transform.mulVec3(payload.triangle.b),
                    .c = packet.transform.mulVec3(payload.triangle.c),
                }, payload.material);
            },
            .polygon => |payload| {
                var transformed: [direct_batch.max_polygon_points]math.Vec3 = undefined;
                const points = payload.polygon.slice();
                for (points, 0..) |point, index| {
                    transformed[index] = packet.transform.mulVec3(point);
                }
                try batch.appendPolygon(transformed[0..points.len], payload.material);
            },
            .circle => |payload| {
                try batch.appendCircle(.{
                    .center = packet.transform.mulVec3(payload.circle.center),
                    .radius = payload.circle.radius,
                }, payload.material);
            },
            .mesh => |payload| {
                try direct_mesh.appendMeshTriangles(batch, payload.mesh, .{
                    .transform = packet.transform,
                    .material_override = payload.material_override,
                });
            },
            .meshlets => |payload| {
                try direct_meshlets.ensureMeshlets(payload.mesh, list.allocator);
                try direct_meshlets.cullVisibleMeshlets(visible_meshlets, payload.mesh, .{
                    .transform = packet.transform,
                    .material_override = payload.material_override,
                }, camera);
                if (job_sys) |js| {
                    try direct_meshlets.appendVisibleMeshletsToBatchParallel(batch, payload.mesh, visible_meshlets, .{
                        .transform = packet.transform,
                        .material_override = payload.material_override,
                    }, list.allocator, js);
                } else {
                    try direct_meshlets.appendVisibleMeshletsToBatch(batch, payload.mesh, visible_meshlets, .{
                        .transform = packet.transform,
                        .material_override = payload.material_override,
                    });
                }
            },
        }
    }
}

test "scene packet list can append primitive and mesh sources" {
    var list = PacketList.init(std.testing.allocator);
    defer list.deinit();
    var mesh = try direct_mesh.Mesh.triangle(std.testing.allocator);
    defer mesh.deinit();

    try list.append(.{
        .source = .{ .line = .{
            .line = .{ .start = math.Vec3.new(0.0, 0.0, 3.0), .end = math.Vec3.new(1.0, 0.0, 3.0) },
            .material = .{ .color = 0xFFFFFFFF },
        } },
    });
    try list.append(.{
        .transform = math.Mat4.translate(0.0, 0.0, 3.0),
        .source = .{ .mesh = .{ .mesh = &mesh } },
    });

    try std.testing.expectEqual(@as(usize, 2), list.items().len);
}
