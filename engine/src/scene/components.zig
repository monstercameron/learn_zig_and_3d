//! Components module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const math = @import("math.zig");
const handles = @import("entity.zig");

pub const EntityId = handles.EntityId;
pub const AssetHandle = handles.AssetHandle;
pub const SceneNodeId = handles.SceneNodeId;

pub const SceneNode = struct {
    authored_id: []const u8,
    node_id: SceneNodeId,
};

pub const TransformLocal = struct {
    position: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    rotation_deg: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    scale: math.Vec3 = math.Vec3.new(1.0, 1.0, 1.0),
};

pub const TransformWorld = struct {
    position: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    rotation_deg: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    scale: math.Vec3 = math.Vec3.new(1.0, 1.0, 1.0),
};

pub const Renderable = struct {
    mesh: AssetHandle = AssetHandle.invalid(),
    material: AssetHandle = AssetHandle.invalid(),
    visible: bool = true,
    casts_shadows: bool = true,
};

pub const max_texture_slots: usize = 32;

pub const TextureSlots = struct {
    slots: [max_texture_slots]AssetHandle = [_]AssetHandle{AssetHandle.invalid()} ** max_texture_slots,
};

pub const Camera = struct {
    fov_deg: f32 = 60.0,
    pitch: f32 = 0.0,
    yaw: f32 = 0.0,
    active: bool = false,
};

pub const LightKind = enum(u8) {
    directional,
    point,
};

pub const LightShadowMode = enum(u8) {
    none,
    shadow_map,
    meshlet_ray,
};

pub const Light = struct {
    kind: LightKind = .directional,
    color: math.Vec3 = math.Vec3.new(1.0, 1.0, 1.0),
    intensity: f32 = 1.0,
    range: f32 = 0.0,
    glow_radius: f32 = 0.0,
    glow_intensity: f32 = 0.0,
    shadow_mode: LightShadowMode = .meshlet_ray,
    shadow_update_interval_frames: u32 = 1,
    shadow_map_size: usize = 512,
};

pub const PhysicsMotion = enum(u8) {
    static,
    dynamic,
    kinematic,
};

pub const PhysicsShape = enum(u8) {
    box,
    sphere,
};

pub const PhysicsBody = struct {
    motion: PhysicsMotion = .static,
    shape: PhysicsShape = .box,
    mass: f32 = 0.0,
    restitution: f32 = 0.0,
};

pub const Selectable = struct {
    gizmo_origin_offset: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    selected: bool = false,
};

pub const ActivationState = struct {
    enabled: bool = true,
};

pub const StreamPolicy = enum(u8) {
    always_resident,
    proximity,
    visibility,
    manual,
};

pub const Streamable = struct {
    policy: StreamPolicy = .always_resident,
    prefetch_radius: f32 = 0.0,
    offload_delay_frames: u32 = 0,
};

pub const max_script_attachments: usize = 4;

pub const ScriptComponent = struct {
    modules: [max_script_attachments]AssetHandle = [_]AssetHandle{AssetHandle.invalid()} ** max_script_attachments,
    count: u8 = 0,
};

pub const ComponentStore = struct {
    allocator: std.mem.Allocator,
    local_transforms: std.ArrayList(?TransformLocal) = .{},
    world_transforms: std.ArrayList(?TransformWorld) = .{},
    renderables: std.ArrayList(?Renderable) = .{},
    texture_slots: std.ArrayList(?TextureSlots) = .{},
    cameras: std.ArrayList(?Camera) = .{},
    lights: std.ArrayList(?Light) = .{},
    physics_bodies: std.ArrayList(?PhysicsBody) = .{},
    selectables: std.ArrayList(?Selectable) = .{},
    activation_states: std.ArrayList(?ActivationState) = .{},
    streamables: std.ArrayList(?Streamable) = .{},
    scripts: std.ArrayList(?ScriptComponent) = .{},
    scene_nodes: std.ArrayList(?SceneNode) = .{},

    /// init initializes Components state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) ComponentStore {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by Components.
    pub fn deinit(self: *ComponentStore) void {
        self.local_transforms.deinit(self.allocator);
        self.world_transforms.deinit(self.allocator);
        self.renderables.deinit(self.allocator);
        self.texture_slots.deinit(self.allocator);
        self.cameras.deinit(self.allocator);
        self.lights.deinit(self.allocator);
        self.physics_bodies.deinit(self.allocator);
        self.selectables.deinit(self.allocator);
        self.activation_states.deinit(self.allocator);
        self.streamables.deinit(self.allocator);
        self.scripts.deinit(self.allocator);
        self.scene_nodes.deinit(self.allocator);
    }

    /// Ensures e ns ur ee nt it yc ap ac it y and grows backing storage/state when needed.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn ensureEntityCapacity(self: *ComponentStore, count: usize) !void {
        try ensureOptionalArray(TransformLocal, self.allocator, &self.local_transforms, count);
        try ensureOptionalArray(TransformWorld, self.allocator, &self.world_transforms, count);
        try ensureOptionalArray(Renderable, self.allocator, &self.renderables, count);
        try ensureOptionalArray(TextureSlots, self.allocator, &self.texture_slots, count);
        try ensureOptionalArray(Camera, self.allocator, &self.cameras, count);
        try ensureOptionalArray(Light, self.allocator, &self.lights, count);
        try ensureOptionalArray(PhysicsBody, self.allocator, &self.physics_bodies, count);
        try ensureOptionalArray(Selectable, self.allocator, &self.selectables, count);
        try ensureOptionalArray(ActivationState, self.allocator, &self.activation_states, count);
        try ensureOptionalArray(Streamable, self.allocator, &self.streamables, count);
        try ensureOptionalArray(ScriptComponent, self.allocator, &self.scripts, count);
        try ensureOptionalArray(SceneNode, self.allocator, &self.scene_nodes, count);
    }

    /// Clears c le ar en ti ty.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn clearEntity(self: *ComponentStore, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.local_transforms.items.len) return;
        self.local_transforms.items[index] = null;
        self.world_transforms.items[index] = null;
        self.renderables.items[index] = null;
        self.texture_slots.items[index] = null;
        self.cameras.items[index] = null;
        self.lights.items[index] = null;
        self.physics_bodies.items[index] = null;
        self.selectables.items[index] = null;
        self.activation_states.items[index] = null;
        self.streamables.items[index] = null;
        self.scripts.items[index] = null;
        self.scene_nodes.items[index] = null;
    }
};

fn ensureOptionalArray(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(?T), count: usize) !void {
    while (list.items.len < count) {
        try list.append(allocator, null);
    }
}
