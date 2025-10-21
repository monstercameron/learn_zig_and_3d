const math = @import("math.zig");

pub const TriangleFlags = packed struct(u8) {
    cull_fill: bool,
    cull_wire: bool,
    backface: bool,
    reserved: u5 = 0,
};

pub const TrianglePacket = struct {
    screen: [3][2]i32,
    camera: [3]math.Vec3,
    uv: [3]math.Vec2,
    base_color: u32,
    intensity: f32,
    flags: TriangleFlags,
    triangle_id: usize,
};

pub const MeshletPacket = struct {
    triangle_start: usize,
    triangle_count: usize,
    meshlet_index: usize,
};
