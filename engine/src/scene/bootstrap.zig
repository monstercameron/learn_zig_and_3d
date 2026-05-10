const scene_math = @import("math.zig");
const components_module = @import("components.zig");
const handles = @import("entity.zig");

const EntityId = handles.EntityId;
pub const BootstrapTextureSlot = struct {
    slot: usize,
    path: []const u8,
};

pub const BootstrapScriptAttachment = struct {
    module_name: []const u8,
};

pub const BootstrapAsset = struct {
    authored_id: ?[]const u8 = null,
    parent_authored_id: ?[]const u8 = null,
    scripts: []const BootstrapScriptAttachment = &.{},
    model_path: []const u8,
    position: scene_math.Vec3,
    rotation_deg: scene_math.Vec3,
    scale: scene_math.Vec3,
    texture_slots: []const BootstrapTextureSlot = &.{},
    physics_motion: ?components_module.PhysicsMotion = null,
    physics_shape: ?[]const u8 = null,
    physics_mass: ?f32 = null,
    physics_restitution: ?f32 = null,
};

pub const BootstrapLight = struct {
    authored_id: ?[]const u8 = null,
    parent_authored_id: ?[]const u8 = null,
    scripts: []const BootstrapScriptAttachment = &.{},
    direction: scene_math.Vec3,
    distance: f32,
    color: scene_math.Vec3,
    glow_radius: f32 = 0.0,
    glow_intensity: f32 = 0.0,
    shadow_mode: components_module.LightShadowMode = .meshlet_ray,
    shadow_update_interval_frames: u32 = 1,
    shadow_map_size: usize = 512,
};

pub const BootstrapCamera = struct {
    authored_id: ?[]const u8 = null,
    parent_authored_id: ?[]const u8 = null,
    scripts: []const BootstrapScriptAttachment = &.{},
    position: scene_math.Vec3,
    pitch: f32,
    yaw: f32,
    fov_deg: f32,
};

pub const BootstrapScene = struct {
    camera: BootstrapCamera,
    lights: []const BootstrapLight,
    assets: []const BootstrapAsset,
    hdri_path: ?[]const u8 = null,
};

pub const RuntimeStats = struct {
    frame_index: u64 = 0,
    resident_renderables: usize = 0,
    resident_lights: usize = 0,
    script_phase_pins: usize = 0,
    physics_phase_pins: usize = 0,
    render_extraction_pins: usize = 0,
};

pub const PhaseAssetUsage = enum {
    script_dispatch,
    physics_sync,
};

pub const FramePhase = enum {
    input,
    residency_decisions,
    job_completion_integration,
    script_events,
    fixed_step_physics,
    transform_propagation,
    render_extraction,
    present,
    safe_offload_deferred_destruction,
};

pub const RuntimeRenderableSetup = struct {
    entity: EntityId,
    local_bounds_min: scene_math.Vec3,
    local_bounds_max: scene_math.Vec3,
};