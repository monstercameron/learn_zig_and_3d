const direct_primitives = @import("direct_primitives.zig");

pub const RenderLayer = enum(u8) {
    background,
    geometry,
    overlay,
};

pub const PacketFlags = packed struct(u8) {
    depth_test: bool = true,
    depth_write: bool = true,
    reserved: u6 = 0,
};

pub const StrokeMaterial = struct {
    color: u32,
    depth: ?f32 = null,
};

pub const SurfaceMaterial = struct {
    fill_color: u32,
    outline_color: ?u32 = null,
    depth: ?f32 = null,
};

pub const PacketMaterial = union(enum) {
    stroke: StrokeMaterial,
    surface: SurfaceMaterial,
};

pub const Payload = union(enum) {
    line: direct_primitives.Line2i,
    triangle: struct {
        triangle: direct_primitives.Triangle2i,
        vertex_colors: ?[3]u32 = null,
    },
    polygon: direct_primitives.Polygon2i,
    circle: direct_primitives.Circle2i,
};

pub const DrawPacket = struct {
    sort_key: u64 = 0,
    layer: RenderLayer = .geometry,
    flags: PacketFlags = .{},
    material: PacketMaterial,
    payload: Payload,
};
