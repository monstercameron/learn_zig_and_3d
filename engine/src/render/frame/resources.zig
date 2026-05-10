const math = @import("../core/math.zig");
const TileRenderer = @import("core/tile_renderer.zig");
const direct_primitives = @import("direct_primitives.zig");

pub const AuxiliaryBuffers = struct {
    scene_camera: []math.Vec3,
    scene_normal: []math.Vec3,
    scene_surface: []TileRenderer.SurfaceHandle,
};

pub const FrameResources = struct {
    target: direct_primitives.FrameTarget,
    aux: AuxiliaryBuffers,
};
