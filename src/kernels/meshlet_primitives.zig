const math = @import("../math.zig");

pub const MeshletDescriptor = extern struct {
    bounds_center: math.Vec3,
    bounds_radius: f32,
    vertex_offset: u32,
    vertex_count: u32,
    triangle_offset: u32,
    triangle_count: u32,
};

pub const MeshTriangle = extern struct {
    v0: u32,
    v1: u32,
    v2: u32,
    base_color: u32,
    cull_fill: u8,
    cull_wireframe: u8,
    _padding: [2]u8 = .{ 0, 0 },
};

pub const MeshletWorkRange = extern struct {
    primitive_offset: u32,
    primitive_count: u32,
};

pub const MeshletVisibility = extern struct {
    visible: u32,
};

pub const PrimitiveFlags = struct {
    pub const none: u32 = 0;
    pub const near_plane: u32 = 1 << 0;
    pub const backface: u32 = 1 << 1;
    pub const clipped: u32 = 1 << 2;
};

pub const MeshletPrimitive = extern struct {
    meshlet_index: u32,
    triangle_index: u32,
    flags: u32,
    reserved: u32,
    camera_positions: [3]math.Vec3,
    projected: [3][2]i32,
    uvs: [3]math.Vec2,
    base_color: u32,
    intensity: f32,
    normal_camera: math.Vec3,
    _padding: f32 = 0.0,
};
