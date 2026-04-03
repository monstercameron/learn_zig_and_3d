const std = @import("std");
const math = @import("../core/math.zig");
const direct_batch = @import("direct_batch.zig");
const direct_mesh = @import("direct_mesh.zig");
const direct_meshlets = @import("direct_meshlets.zig");
const direct_packets = @import("direct_packets.zig");

pub const VisiblePacket = union(enum) {
    primitive: PrimitivePacket,
    mesh: MeshPacket,
    meshlets: MeshletPacket,
};

pub const PrimitivePacket = struct {
    layer: direct_packets.RenderLayer = .geometry,
    flags: direct_packets.PacketFlags = .{},
    transform: math.Mat4 = math.Mat4.identity(),
    source: Source,

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
    };
};

pub const MeshPacket = struct {
    layer: direct_packets.RenderLayer = .geometry,
    flags: direct_packets.PacketFlags = .{},
    transform: math.Mat4 = math.Mat4.identity(),
    mesh: *const direct_mesh.Mesh,
    material_override: ?direct_batch.SurfaceMaterial = null,
};

pub const MeshletPacket = struct {
    layer: direct_packets.RenderLayer = .geometry,
    flags: direct_packets.PacketFlags = .{},
    transform: math.Mat4 = math.Mat4.identity(),
    mesh: *direct_meshlets.Mesh,
    material_override: ?direct_batch.SurfaceMaterial = null,
    visible_offset: usize,
    visible_count: usize,
};

pub const VisibleScene = struct {
    allocator: std.mem.Allocator,
    packets: std.ArrayListUnmanaged(VisiblePacket) = .{},
    meshlet_indices: std.ArrayListUnmanaged(usize) = .{},

    pub fn init(allocator: std.mem.Allocator) VisibleScene {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VisibleScene) void {
        self.packets.deinit(self.allocator);
        self.meshlet_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *VisibleScene) void {
        self.packets.clearRetainingCapacity();
        self.meshlet_indices.clearRetainingCapacity();
    }

    pub fn ensurePacketCapacity(self: *VisibleScene, count: usize) !void {
        try self.packets.ensureTotalCapacity(self.allocator, count);
    }

    pub fn ensureMeshletIndexCapacity(self: *VisibleScene, count: usize) !void {
        try self.meshlet_indices.ensureTotalCapacity(self.allocator, count);
    }

    pub fn items(self: *const VisibleScene) []const VisiblePacket {
        return self.packets.items;
    }

    pub fn append(self: *VisibleScene, packet: VisiblePacket) !void {
        try self.packets.append(self.allocator, packet);
    }

    pub fn appendAssumeCapacity(self: *VisibleScene, packet: VisiblePacket) void {
        self.packets.appendAssumeCapacity(packet);
    }
};
