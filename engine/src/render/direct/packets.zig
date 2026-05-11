const math = @import("../../core/math.zig");
const texture_mod = @import("../../assets/texture.zig");
const direct_primitives = @import("primitives.zig");

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
    cull_backfaces: bool = true,
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
        vertex_depths: ?[3]f32 = null,
        gouraud_setup: ?direct_primitives.PreparedGouraudTriangle = null,
        // Camera-space face normal. The deferred rasterizer copies this
        // into gbuf_normal per covered pixel so the lighting stage has
        // surface orientation. None on triangles built before deferred
        // mode; ignored by the forward dispatcher. Stored as Vec3 for
        // now; can promote to packed RGB10/A2 once the lighting stage
        // is in place and we're ready to compact the G-buffer.
        face_normal: ?math.Vec3 = null,
        /// Texture + per-vertex UVs for deferred texture sampling.
        /// When `texture` is non-null and `uvs` is filled, the rasterizer
        /// samples the texture per pixel and writes the result to
        /// gbuf_base_color instead of the constant fill color.
        texture: ?*const texture_mod.Texture = null,
        uvs: ?[3]math.Vec2 = null,
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
