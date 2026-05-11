const math = @import("../../core/math.zig");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_primitives = @import("../direct/primitives.zig");

/// G-buffer surfaces. The forward path already populates scene_camera /
/// scene_normal / scene_surface opportunistically (for SSAO/SSGI/SSR
/// sampling). Deferred shading promotes them to the load-bearing
/// per-pixel state plus adds base-colour and material surfaces.
///
/// Layout target for Phase 1 (this commit):
///   scene_depth     []f32        existing on Renderer (not in this struct yet)
///   scene_camera    []Vec3       camera-space position per pixel
///   scene_normal    []Vec3       camera-space normal per pixel
///   scene_surface   []SurfaceHandle  surface / triangle id per pixel
///   scene_base_color []u32       packed RGBA8 albedo per pixel        (NEW)
///   scene_material  []u32       packed material params per pixel     (NEW)
///                                  layout: r=roughness, g=metallic,
///                                          b=ao, a=flags
///
/// scene_base_color and scene_material are allocated but unused until
/// Phase 3 (rasterizer writes) and Phase 4 (lighting stage reads).
pub const AuxiliaryBuffers = struct {
    scene_camera: []math.Vec3,
    scene_normal: []math.Vec3,
    scene_surface: []TileRenderer.SurfaceHandle,
    scene_base_color: []u32,
    scene_material: []u32,
};

pub const FrameResources = struct {
    target: direct_primitives.FrameTarget,
    aux: AuxiliaryBuffers,
};
