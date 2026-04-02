const std = @import("std");
const math = @import("../core/math.zig");
const direct_batch = @import("direct_batch.zig");
const direct_mesh = @import("direct_mesh.zig");
const direct_meshlets = @import("direct_meshlets.zig");

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

    pub fn ensureCapacity(self: *PacketList, count: usize) !void {
        try self.packets.ensureTotalCapacity(self.allocator, count);
    }

    pub fn items(self: *const PacketList) []const WorldPacket {
        return self.packets.items;
    }

    pub fn append(self: *PacketList, packet: WorldPacket) !void {
        try self.packets.append(self.allocator, packet);
    }
};

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
