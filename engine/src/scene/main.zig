//! Primary entry point and bootstrapping flow for the engine executable.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const builtin = @import("builtin");
const zphysics = @import("zphysics");
const handles = @import("entity.zig");
const world_module = @import("world.zig");
const components_module = @import("components.zig");
const graph_module = @import("graph.zig");
const dependency_graph_module = @import("dependency_graph.zig");
const asset_registry_module = @import("asset_registry.zig");
const octree_module = @import("octree.zig");
const residency_module = @import("residency_manager.zig");
const script_host_module = @import("script_host.zig");
const script_registry_module = @import("script_registry.zig");
const render_extraction_module = @import("render_extraction.zig");
const scene_math = @import("math.zig");
const loader_module = @import("loader.zig");
const physics_utils = @import("physics_utils");

pub const EntityId = handles.EntityId;
pub const AssetHandle = handles.AssetHandle;
pub const SceneNodeId = handles.SceneNodeId;

pub const World = world_module.World;
pub const Commands = world_module.Commands;
pub const Command = world_module.Command;
pub const CameraControlMode = world_module.CameraControlMode;
pub const RendererControlAxis = world_module.RendererControlAxis;
pub const ComponentStore = components_module.ComponentStore;
pub const components = components_module;
pub const TextureSlots = components_module.TextureSlots;
pub const HierarchyGraph = graph_module.HierarchyGraph;
pub const DependencyGraph = dependency_graph_module.DependencyGraph;
pub const DependencyEdge = dependency_graph_module.DependencyEdge;
pub const DependencyKind = dependency_graph_module.DependencyKind;
pub const DependencyTarget = dependency_graph_module.DependencyTarget;
pub const AssetRegistry = asset_registry_module.AssetRegistry;
pub const AssetKind = asset_registry_module.AssetKind;
pub const AssetState = asset_registry_module.AssetState;
pub const AssetRecord = asset_registry_module.AssetRecord;
pub const Aabb = octree_module.Aabb;
pub const Octree = octree_module.Octree;
pub const ResidencyManager = residency_module.ResidencyManager;
pub const CellState = residency_module.CellState;
pub const ScriptHost = script_host_module.ScriptHost;
pub const ScriptEvent = script_host_module.ScriptEvent;
pub const ScriptInputState = script_host_module.ScriptInputState;
pub const ScriptModuleVTable = script_host_module.ScriptModuleVTable;
pub const ScriptCallbackContext = script_host_module.ScriptCallbackContext;
pub const ScriptHostAbiVersion = script_host_module.abi_version;
pub const RenderSnapshot = render_extraction_module.RenderSnapshot;
pub const extractFrameSnapshot = render_extraction_module.extractFrameSnapshot;
pub const SceneIndexEntry = loader_module.SceneIndexEntry;
pub const SceneIndexFile = loader_module.SceneIndexFile;
pub const SceneTextureSlotEntry = loader_module.SceneTextureSlotEntry;
pub const SceneScriptConfigEntry = loader_module.SceneScriptConfigEntry;
pub const SceneAssetConfigEntry = loader_module.SceneAssetConfigEntry;
pub const SceneFile = loader_module.SceneFile;
pub const LoadedSceneRuntimeKind = loader_module.RuntimeKind;
pub const LoadedSceneModelType = loader_module.ModelType;
pub const LoadedSceneTextureSlot = loader_module.TextureSlotDefinition;
pub const LoadedSceneScriptAttachment = loader_module.ScriptAttachmentDefinition;
pub const LoadedSceneAsset = loader_module.AssetDefinition;
pub const LoadedSceneLight = loader_module.LightDefinition;
pub const LoadedSceneDescription = loader_module.SceneDescription;
pub const buildSceneDescription = loader_module.buildSceneDescription;
pub const parseSceneLightShadowMode = loader_module.parseSceneLightShadowMode;

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

const PhaseAssetUsage = enum {
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

const PendingParentLink = struct {
    child: EntityId,
    parent_authored_id: []const u8,
};

const PhysicsBinding = struct {
    entity: EntityId,
    body_id: zphysics.BodyId,
    body_to_entity_offset_local: scene_math.Vec3,
    suspended_for_residency: bool = false,
};

const ExecutionState = struct {
    mode: LoadedSceneRuntimeKind = .static,
    physics_world: ?*physics_utils.PhysicsWorld = null,
    bindings: std.ArrayList(PhysicsBinding) = .{},
    enter_pressed: bool = false,
    enter_was_down: bool = false,
    k_pressed: bool = false,
    k_was_down: bool = false,
    pause_dynamics: bool = false,

    fn deinit(self: *ExecutionState, allocator: std.mem.Allocator) void {
        self.reset(allocator);
        self.bindings.deinit(allocator);
    }

    fn reset(self: *ExecutionState, allocator: std.mem.Allocator) void {
        if (self.physics_world) |pw| pw.deinit(allocator);
        self.physics_world = null;
        self.mode = .static;
        self.enter_pressed = false;
        self.enter_was_down = false;
        self.k_pressed = false;
        self.k_was_down = false;
        self.pause_dynamics = false;
        self.bindings.clearRetainingCapacity();
    }

    fn setInputs(self: *ExecutionState, enter_pressed: bool, k_pressed: bool, pause_dynamics: bool) void {
        self.enter_pressed = enter_pressed;
        self.k_pressed = k_pressed;
        self.pause_dynamics = pause_dynamics;
    }

    fn consumeKPressedEdge(self: *ExecutionState) bool {
        const pressed = self.k_pressed and !self.k_was_down;
        self.k_was_down = self.k_pressed;
        return pressed;
    }

    fn configure(
        self: *ExecutionState,
        allocator: std.mem.Allocator,
        component_store: *ComponentStore,
        runtime_kind: LoadedSceneRuntimeKind,
        renderables: []const RuntimeRenderableSetup,
    ) !void {
        self.reset(allocator);
        self.mode = runtime_kind;
        if (runtime_kind == .static) return;

        var physics_world = try physics_utils.PhysicsWorld.init(allocator);
        errdefer physics_world.deinit(allocator);
        const body_interface = physics_world.system.getBodyInterfaceMut();

        switch (runtime_kind) {
            .static => unreachable,
            .gun_physics => {
                try createGunArena(body_interface);
                if (renderables.len == 0) return error.SceneHasNoAssets;
                const binding = try createBindingForRenderable(body_interface, component_store, renderables[0], .{
                    .motion = .dynamic,
                    .shape = .box,
                    .mass = 1.0,
                    .restitution = 0.5,
                    .angular_velocity = .{ 2.0, 1.0, 3.0, 0.0 },
                    .position_offset = .{ .x = 0.0, .y = 5.0, .z = 0.0 },
                });
                try self.bindings.append(allocator, binding);
            },
            .scene_physics => {
                try createSceneFloor(body_interface);
                for (renderables) |renderable| {
                    const index: usize = @intCast(renderable.entity.index);
                    if (index >= component_store.physics_bodies.items.len) continue;
                    const physics_body = component_store.physics_bodies.items[index] orelse continue;
                    if (physics_body.motion != .dynamic) continue;
                    const binding = try createBindingForRenderable(body_interface, component_store, renderable, .{
                        .motion = physics_body.motion,
                        .shape = physics_body.shape,
                        .mass = if (physics_body.mass > 0.0) physics_body.mass else 2.0,
                        .restitution = physics_body.restitution,
                        .angular_velocity = .{ 0.0, 0.0, 0.0, 0.0 },
                        .position_offset = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                    });
                    try self.bindings.append(allocator, binding);
                }
            },
        }

        self.physics_world = physics_world;
    }

    fn step(self: *ExecutionState, component_store: *ComponentStore, delta_seconds: f32, renderables_dirty: *bool) void {
        const physics_world = self.physics_world orelse return;
        switch (self.mode) {
            .static => return,
            .gun_physics => {
                if (self.enter_pressed and !self.enter_was_down and self.bindings.items.len != 0 and !self.bindings.items[0].suspended_for_residency) {
                    const body_interface = physics_world.system.getBodyInterfaceMut();
                    const binding = self.bindings.items[0];
                    body_interface.activate(binding.body_id);
                    body_interface.setLinearVelocity(binding.body_id, .{ 0.0, 6.5, 0.0 });
                }
                self.enter_was_down = self.enter_pressed;
                physics_world.system.update(delta_seconds, .{ .collision_steps = 1 }) catch {};
            },
            .scene_physics => {
                if (!self.pause_dynamics) {
                    physics_world.system.update(delta_seconds, .{ .collision_steps = 1 }) catch {};
                }
            },
        }

        if (self.bindings.items.len == 0) return;
        self.syncBindingsToTransforms(component_store);
        renderables_dirty.* = true;
    }

    fn translateEntity(
        self: *ExecutionState,
        component_store: *ComponentStore,
        entity: EntityId,
        delta: scene_math.Vec3,
        renderables_dirty: *bool,
    ) bool {
        const binding = self.lookupBinding(entity) orelse return false;
        const physics_world = self.physics_world orelse return false;
        const body_interface = physics_world.system.getBodyInterfaceMut();
        const pos = body_interface.getPosition(binding.body_id);
        body_interface.setPosition(binding.body_id, .{
            pos[0] + @as(zphysics.Real, @floatCast(delta.x)),
            pos[1] + @as(zphysics.Real, @floatCast(delta.y)),
            pos[2] + @as(zphysics.Real, @floatCast(delta.z)),
        }, .activate);
        body_interface.setLinearVelocity(binding.body_id, .{ 0.0, 0.0, 0.0 });
        body_interface.setAngularVelocity(binding.body_id, .{ 0.0, 0.0, 0.0 });
        self.syncSingleBindingToTransform(component_store, binding.*);
        renderables_dirty.* = true;
        return true;
    }

    fn jumpEntity(self: *ExecutionState, world: *const World, entity: EntityId, upward_velocity: f32) bool {
        if (!world.isAlive(entity) or !world.isEnabled(entity)) return false;
        const physics_world = self.physics_world orelse return false;
        const binding = self.lookupBinding(entity) orelse return false;
        if (binding.suspended_for_residency) return false;
        const body_interface = physics_world.system.getBodyInterfaceMut();
        body_interface.activate(binding.body_id);
        body_interface.setLinearVelocity(binding.body_id, .{ 0.0, @as(zphysics.Real, @floatCast(upward_velocity)), 0.0 });
        return true;
    }

    fn lookupBinding(self: *ExecutionState, entity: EntityId) ?*PhysicsBinding {
        for (self.bindings.items) |*binding| {
            if (binding.entity.eql(entity)) return binding;
        }
        return null;
    }

    fn syncBindingsToTransforms(self: *ExecutionState, component_store: *ComponentStore) void {
        for (self.bindings.items) |binding| {
            if (binding.suspended_for_residency) continue;
            self.syncSingleBindingToTransform(component_store, binding);
        }
    }

    fn syncBindingResidency(self: *ExecutionState, world: *const World, component_store: *ComponentStore, residency: *const ResidencyManager) void {
        const physics_world = self.physics_world orelse return;
        const body_interface = physics_world.system.getBodyInterfaceMut();
        for (self.bindings.items) |*binding| {
            const should_simulate = world.isAlive(binding.entity) and world.isEnabled(binding.entity) and entityIsResident(residency, binding.entity);
            if (should_simulate == !binding.suspended_for_residency) continue;

            if (should_simulate) {
                self.syncSingleTransformToBinding(component_store, body_interface, binding.*);
                body_interface.activate(binding.body_id);
                binding.suspended_for_residency = false;
            } else {
                body_interface.setLinearVelocity(binding.body_id, .{ 0.0, 0.0, 0.0 });
                body_interface.setAngularVelocity(binding.body_id, .{ 0.0, 0.0, 0.0 });
                body_interface.deactivate(binding.body_id);
                binding.suspended_for_residency = true;
            }
        }
    }

    fn syncSingleBindingToTransform(self: *ExecutionState, component_store: *ComponentStore, binding: PhysicsBinding) void {
        const physics_world = self.physics_world orelse return;
        const lock_iface = physics_world.system.getBodyLockInterfaceNoLock();
        var read_lock: zphysics.BodyLockRead = .{};
        read_lock.lock(lock_iface, binding.body_id);
        const body = read_lock.body orelse return;
        const xform = body.getWorldTransform();
        const rotation_deg = rotationMatrixToEulerDegrees(xform.rotation);
        const offset = rotateVector(binding.body_to_entity_offset_local, rotation_deg);
        const entity_position = scene_math.Vec3.new(
            @as(f32, @floatCast(xform.position[0])) + offset.x,
            @as(f32, @floatCast(xform.position[1])) + offset.y,
            @as(f32, @floatCast(xform.position[2])) + offset.z,
        );
        const index: usize = @intCast(binding.entity.index);
        if (index < component_store.local_transforms.items.len and component_store.local_transforms.items[index] != null) {
            component_store.local_transforms.items[index].?.position = entity_position;
            component_store.local_transforms.items[index].?.rotation_deg = rotation_deg;
        }
        if (index < component_store.world_transforms.items.len and component_store.world_transforms.items[index] != null) {
            component_store.world_transforms.items[index].?.position = entity_position;
            component_store.world_transforms.items[index].?.rotation_deg = rotation_deg;
        }
    }

    fn syncSingleTransformToBinding(self: *ExecutionState, component_store: *ComponentStore, body_interface: anytype, binding: PhysicsBinding) void {
        _ = self;
        const index: usize = @intCast(binding.entity.index);
        if (index >= component_store.world_transforms.items.len) return;
        const transform = component_store.world_transforms.items[index] orelse return;
        const body_position = entityTransformToBodyPosition(transform, binding.body_to_entity_offset_local);
        body_interface.setPosition(binding.body_id, .{
            @as(zphysics.Real, @floatCast(body_position.x)),
            @as(zphysics.Real, @floatCast(body_position.y)),
            @as(zphysics.Real, @floatCast(body_position.z)),
        }, .dont_activate);
        body_interface.setRotation(binding.body_id, eulerDegreesToQuaternion(transform.rotation_deg), .dont_activate);
    }
};

const BindingSetup = struct {
    motion: components_module.PhysicsMotion,
    shape: components_module.PhysicsShape,
    mass: f32,
    restitution: f32,
    angular_velocity: [4]zphysics.Real,
    position_offset: scene_math.Vec3,
};

fn createBindingForRenderable(
    body_interface: anytype,
    component_store: *ComponentStore,
    renderable: RuntimeRenderableSetup,
    setup: BindingSetup,
) !PhysicsBinding {
    const index: usize = @intCast(renderable.entity.index);
    if (index >= component_store.world_transforms.items.len) return error.InvalidEntity;
    const transform = component_store.world_transforms.items[index] orelse return error.InvalidEntity;
    const local_center = scene_math.Vec3.scale(scene_math.Vec3.add(renderable.local_bounds_min, renderable.local_bounds_max), 0.5);
    const scaled_center = mulComponents(local_center, transform.scale);
    const half_extents = scene_math.Vec3.scale(absComponents(mulComponents(scene_math.Vec3.sub(renderable.local_bounds_max, renderable.local_bounds_min), transform.scale)), 0.5);
    const rotation = eulerDegreesToQuaternion(transform.rotation_deg);
    const center_offset = rotateVector(scaled_center, transform.rotation_deg);
    const body_center = scene_math.Vec3.add(scene_math.Vec3.add(transform.position, center_offset), setup.position_offset);

    const body_id = switch (setup.shape) {
        .sphere => blk: {
            const radius = @max(@as(f32, 0.05), @max(half_extents.x, @max(half_extents.y, half_extents.z)));
            const shape_settings = try zphysics.SphereShapeSettings.create(radius);
            defer shape_settings.asShapeSettings().release();
            const shape = try shape_settings.asShapeSettings().createShape();
            defer shape.release();
            var body_settings = zphysics.BodyCreationSettings{
                .shape = shape,
                .position = .{ body_center.x, body_center.y, body_center.z, 0.0 },
                .rotation = rotation,
                .motion_type = switch (setup.motion) {
                    .static => .static,
                    .dynamic => .dynamic,
                    .kinematic => .kinematic,
                },
                .object_layer = if (setup.motion == .static) physics_utils.object_layers.non_moving else physics_utils.object_layers.moving,
            };
            body_settings.angular_velocity = setup.angular_velocity;
            body_settings.restitution = setup.restitution;
            if (setup.motion == .dynamic) {
                body_settings.inertia_multiplier = std.math.clamp(setup.mass / 3.0, 0.3, 6.0);
                body_settings.linear_damping = std.math.clamp(setup.mass * 0.02, 0.02, 0.25);
            }
            break :blk try body_interface.createAndAddBody(body_settings, .activate);
        },
        .box => blk: {
            const shape_settings = try zphysics.BoxShapeSettings.create(.{
                @max(@as(f32, 0.05), half_extents.x),
                @max(@as(f32, 0.05), half_extents.y),
                @max(@as(f32, 0.05), half_extents.z),
            });
            defer shape_settings.asShapeSettings().release();
            const shape = try shape_settings.asShapeSettings().createShape();
            defer shape.release();
            var body_settings = zphysics.BodyCreationSettings{
                .shape = shape,
                .position = .{ body_center.x, body_center.y, body_center.z, 0.0 },
                .rotation = rotation,
                .motion_type = switch (setup.motion) {
                    .static => .static,
                    .dynamic => .dynamic,
                    .kinematic => .kinematic,
                },
                .object_layer = if (setup.motion == .static) physics_utils.object_layers.non_moving else physics_utils.object_layers.moving,
            };
            body_settings.angular_velocity = setup.angular_velocity;
            body_settings.restitution = setup.restitution;
            if (setup.motion == .dynamic) {
                body_settings.inertia_multiplier = std.math.clamp(setup.mass / 4.0, 0.4, 8.0);
                body_settings.linear_damping = std.math.clamp(setup.mass * 0.015, 0.02, 0.3);
            }
            break :blk try body_interface.createAndAddBody(body_settings, .activate);
        },
    };

    return .{
        .entity = renderable.entity,
        .body_id = body_id,
        .body_to_entity_offset_local = scene_math.Vec3.new(-scaled_center.x, -scaled_center.y, -scaled_center.z),
    };
}

fn createSceneFloor(body_interface: anytype) !void {
    const floor_shape_settings = try zphysics.BoxShapeSettings.create(.{ 6.0, 0.1, 6.0 });
    defer floor_shape_settings.asShapeSettings().release();
    const floor_shape = try floor_shape_settings.asShapeSettings().createShape();
    defer floor_shape.release();
    _ = try body_interface.createAndAddBody(.{
        .shape = floor_shape,
        .position = .{ 0.0, -0.1, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .static,
        .object_layer = physics_utils.object_layers.non_moving,
    }, .activate);
}

fn createGunArena(body_interface: anytype) !void {
    const floor_shape_settings = try zphysics.BoxShapeSettings.create(.{ 100.0, 1.0, 100.0 });
    defer floor_shape_settings.asShapeSettings().release();
    const floor_shape = try floor_shape_settings.asShapeSettings().createShape();
    defer floor_shape.release();
    _ = try body_interface.createAndAddBody(.{
        .shape = floor_shape,
        .position = .{ 0.0, -2.0, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .static,
        .object_layer = physics_utils.object_layers.non_moving,
    }, .activate);

    const wall_shape_lr = try zphysics.BoxShapeSettings.create(.{ 0.1, 2.1, 2.0 });
    defer wall_shape_lr.asShapeSettings().release();
    const wall_shape_lr_obj = try wall_shape_lr.asShapeSettings().createShape();
    defer wall_shape_lr_obj.release();
    _ = try body_interface.createAndAddBody(.{
        .shape = wall_shape_lr_obj,
        .position = .{ -2.0, 2.1, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .static,
        .object_layer = physics_utils.object_layers.non_moving,
    }, .activate);
    _ = try body_interface.createAndAddBody(.{
        .shape = wall_shape_lr_obj,
        .position = .{ 2.0, 2.1, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .static,
        .object_layer = physics_utils.object_layers.non_moving,
    }, .activate);

    const wall_shape_back = try zphysics.BoxShapeSettings.create(.{ 2.0, 2.1, 0.1 });
    defer wall_shape_back.asShapeSettings().release();
    const wall_shape_back_obj = try wall_shape_back.asShapeSettings().createShape();
    defer wall_shape_back_obj.release();
    _ = try body_interface.createAndAddBody(.{
        .shape = wall_shape_back_obj,
        .position = .{ 0.0, 2.1, 2.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .static,
        .object_layer = physics_utils.object_layers.non_moving,
    }, .activate);
}

fn mulComponents(a: scene_math.Vec3, b: scene_math.Vec3) scene_math.Vec3 {
    return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
}

fn absComponents(v: scene_math.Vec3) scene_math.Vec3 {
    return .{ .x = @abs(v.x), .y = @abs(v.y), .z = @abs(v.z) };
}

fn rotateVector(v: scene_math.Vec3, rotation_deg: scene_math.Vec3) scene_math.Vec3 {
    const rad_scale = std.math.pi / 180.0;
    const rx = rotation_deg.x * rad_scale;
    const ry = rotation_deg.y * rad_scale;
    const rz = rotation_deg.z * rad_scale;

    const sx = @sin(rx);
    const cx = @cos(rx);
    const sy = @sin(ry);
    const cy = @cos(ry);
    const sz = @sin(rz);
    const cz = @cos(rz);

    const x1 = v.x;
    const y1 = v.y * cx - v.z * sx;
    const z1 = v.y * sx + v.z * cx;

    const x2 = x1 * cy + z1 * sy;
    const y2 = y1;
    const z2 = -x1 * sy + z1 * cy;

    return .{
        .x = x2 * cz - y2 * sz,
        .y = x2 * sz + y2 * cz,
        .z = z2,
    };
}

fn eulerDegreesToQuaternion(rotation_deg: scene_math.Vec3) [4]zphysics.Real {
    const half_to_rad = std.math.pi / 360.0;
    const hx = rotation_deg.x * half_to_rad;
    const hy = rotation_deg.y * half_to_rad;
    const hz = rotation_deg.z * half_to_rad;

    const sx = @sin(hx);
    const cx = @cos(hx);
    const sy = @sin(hy);
    const cy = @cos(hy);
    const sz = @sin(hz);
    const cz = @cos(hz);

    return .{
        @as(zphysics.Real, @floatCast(sx * cy * cz - cx * sy * sz)),
        @as(zphysics.Real, @floatCast(cx * sy * cz + sx * cy * sz)),
        @as(zphysics.Real, @floatCast(cx * cy * sz - sx * sy * cz)),
        @as(zphysics.Real, @floatCast(cx * cy * cz + sx * sy * sz)),
    };
}

fn rotationMatrixToEulerDegrees(rotation: [9]zphysics.Real) scene_math.Vec3 {
    const m00 = @as(f32, @floatCast(rotation[0]));
    const m10 = @as(f32, @floatCast(rotation[1]));
    const m20 = @as(f32, @floatCast(rotation[2]));
    const m21 = @as(f32, @floatCast(rotation[5]));
    const m22 = @as(f32, @floatCast(rotation[8]));
    const rad_to_deg = 180.0 / std.math.pi;
    const yaw = std.math.asin(std.math.clamp(-m20, -1.0, 1.0));
    const pitch = std.math.atan2(m21, m22);
    const roll = std.math.atan2(m10, m00);
    return .{
        .x = pitch * rad_to_deg,
        .y = yaw * rad_to_deg,
        .z = roll * rad_to_deg,
    };
}

fn entityTransformToBodyPosition(transform: components_module.TransformWorld, body_to_entity_offset_local: scene_math.Vec3) scene_math.Vec3 {
    return scene_math.Vec3.sub(transform.position, rotateVector(body_to_entity_offset_local, transform.rotation_deg));
}

pub const SceneRuntime = struct {
    allocator: std.mem.Allocator,
    world: World,
    commands: Commands,
    components: ComponentStore,
    hierarchy: HierarchyGraph,
    dependencies: DependencyGraph,
    assets: AssetRegistry,
    residency: ResidencyManager,
    scripts: ScriptHost,
    authored_entity_lookup: std.StringHashMapUnmanaged(EntityId),
    renderable_entities: std.ArrayList(EntityId),
    execution: ExecutionState,
    pending_renderer_commands: std.ArrayList(Command),
    started: bool,
    renderables_dirty: bool,
    selected_entity: ?EntityId,
    current_phase: ?FramePhase,
    last_completed_phase: ?FramePhase,
    fixed_step_accumulator: f32,
    script_input: ScriptInputState,
    stats: RuntimeStats,

    /// init initializes Main state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator, bounds: Aabb) !SceneRuntime {
        return .{
            .allocator = allocator,
            .world = World.init(allocator),
            .commands = Commands.init(allocator),
            .components = ComponentStore.init(allocator),
            .hierarchy = HierarchyGraph.init(allocator),
            .dependencies = DependencyGraph.init(allocator),
            .assets = AssetRegistry.init(allocator),
            .residency = try ResidencyManager.init(allocator, bounds, 4),
            .scripts = ScriptHost.init(allocator),
            .authored_entity_lookup = .{},
            .renderable_entities = .{},
            .execution = .{},
            .pending_renderer_commands = .{},
            .started = false,
            .renderables_dirty = true,
            .selected_entity = null,
            .current_phase = null,
            .last_completed_phase = null,
            .fixed_step_accumulator = 0.0,
            .script_input = .{},
            .stats = .{},
        };
    }

    /// deinit releases resources owned by Main.
    pub fn deinit(self: *SceneRuntime) void {
        self.execution.deinit(self.allocator);
        self.pending_renderer_commands.deinit(self.allocator);
        self.scripts.deinit();
        self.residency.deinit();
        self.assets.deinit();
        self.dependencies.deinit();
        self.hierarchy.deinit();
        self.components.deinit();
        self.authored_entity_lookup.deinit(self.allocator);
        self.renderable_entities.deinit(self.allocator);
        self.commands.deinit();
        self.world.deinit();
    }

    /// createEntity creates a new value used by Main.
    pub fn createEntity(self: *SceneRuntime) !EntityId {
        self.assertMutationAllowed();
        const entity = try self.world.createEntity();
        errdefer _ = self.world.destroyEntity(entity);
        try self.hierarchy.ensureEntityCapacity(self.world.slotCount());
        try self.components.ensureEntityCapacity(self.world.slotCount());
        try self.residency.ensureEntityCapacity(self.world.slotCount());
        self.components.activation_states.items[@intCast(entity.index)] = .{ .enabled = true };
        return entity;
    }

    /// destroyEntity destroys or reclaims Main resources.
    pub fn destroyEntity(self: *SceneRuntime, entity: EntityId) void {
        self.assertMutationAllowed();
        if (self.selected_entity) |selected| {
            if (selected.eql(entity)) {
                self.setSelectableSelected(entity, false);
                self.selected_entity = null;
            }
        }
        self.unregisterAuthoredEntity(entity);
        self.scripts.destroyInstancesForEntity(&self.world, &self.components, &self.commands, entity);
        self.residency.clearEntity(entity);
        self.dependencies.removeEntity(entity);
        self.hierarchy.clearEntity(&self.world, entity);
        self.components.clearEntity(entity);
        _ = self.world.destroyEntity(entity);
    }

    /// Applies deferred.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn applyDeferred(self: *SceneRuntime) void {
        for (self.commands.pending.items) |command| {
            switch (command) {
                .destroy_entity => |entity| self.destroyEntity(entity),
                .set_enabled => |payload| {
                    self.setEntityEnabledRecursive(payload.entity, payload.enabled);
                },
                .jump_entity => |payload| {
                    _ = self.execution.jumpEntity(&self.world, payload.entity, payload.upward_velocity);
                },
                .translate_entity => |payload| {
                    _ = self.translateEntity(payload.entity, payload.delta);
                },
                .set_camera_orientation => |payload| {
                    _ = self.setCameraOrientation(payload.entity, payload.pitch, payload.yaw);
                },
                .adjust_camera_fov,
                .set_camera_mode,
                .toggle_scene_item_gizmo,
                .toggle_light_gizmo,
                .set_gizmo_axis,
                .cycle_light_selection,
                .nudge_active_gizmo,
                .toggle_render_overlay,
                .toggle_shadow_debug,
                .advance_shadow_debug,
                => self.pending_renderer_commands.append(self.allocator, command) catch {},
            }
        }
        self.commands.clear();
    }

    pub fn rendererCommands(self: *const SceneRuntime) []const Command {
        return self.pending_renderer_commands.items;
    }

    pub fn clearRendererCommands(self: *SceneRuntime) void {
        self.pending_renderer_commands.clearRetainingCapacity();
    }

    pub fn lookupEntityByAuthoredId(self: *const SceneRuntime, authored_id: []const u8) ?EntityId {
        return self.authored_entity_lookup.get(authored_id);
    }

    pub fn attachScriptToEntity(self: *SceneRuntime, entity: EntityId, module_name: []const u8) !bool {
        self.assertMutationAllowed();
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        try self.ensureBuiltinScriptModules();

        const module = self.scripts.lookupModuleByName(module_name) orelse return error.UnknownScriptModule;
        const index: usize = @intCast(entity.index);
        if (index >= self.components.scripts.items.len) return error.InvalidEntity;

        const previous_component = self.components.scripts.items[index];
        var component = previous_component orelse components_module.ScriptComponent{};
        if (findScriptAttachmentSlot(component, module) != null) return false;
        if (@as(usize, component.count) >= components_module.max_script_attachments) return error.TooManyScriptAttachments;

        component.modules[component.count] = module;
        component.count += 1;
        self.components.scripts.items[index] = component;
        errdefer self.components.scripts.items[index] = previous_component;

        try self.scripts.attachScript(&self.world, &self.components, &self.commands, entity, module);
        errdefer _ = self.scripts.detachScript(&self.world, &self.components, &self.commands, entity, module);

        try self.dependencies.addEdge(.{
            .source = entity,
            .target = .{ .asset = module },
            .kind = .script,
            .hard = true,
        });
        errdefer _ = self.dependencies.removeAssetEdge(entity, module, .script);

        if (self.started and self.world.isEnabled(entity)) {
            try self.scripts.queueBeginPlayForEntity(&self.world, entity);
        }

        return true;
    }

    pub fn detachScriptFromEntity(self: *SceneRuntime, entity: EntityId, module_name: []const u8) !bool {
        self.assertMutationAllowed();
        if (!self.world.isAlive(entity)) return error.InvalidEntity;

        const module = self.scripts.lookupModuleByName(module_name) orelse return false;
        const index: usize = @intCast(entity.index);
        if (index >= self.components.scripts.items.len) return error.InvalidEntity;

        var component = self.components.scripts.items[index] orelse return false;
        const slot = findScriptAttachmentSlot(component, module) orelse return false;
        removeScriptAttachmentAt(&component, slot);
        self.components.scripts.items[index] = if (component.count == 0) null else component;

        if (!self.scripts.detachScript(&self.world, &self.components, &self.commands, entity, module)) {
            return error.ScriptInstanceMissing;
        }
        _ = self.dependencies.removeAssetEdge(entity, module, .script);
        return true;
    }

    pub fn renderableEntityAt(self: *const SceneRuntime, index: usize) ?EntityId {
        if (index >= self.renderable_entities.items.len) return null;
        const entity = self.renderable_entities.items[index];
        if (!self.world.isAlive(entity)) return null;
        return entity;
    }

    pub fn worldTransform(self: *const SceneRuntime, entity: EntityId) ?components_module.TransformWorld {
        if (!self.world.isAlive(entity)) return null;
        const index: usize = @intCast(entity.index);
        if (index >= self.components.world_transforms.items.len) return null;
        return self.components.world_transforms.items[index];
    }

    pub fn setSelectedEntity(self: *SceneRuntime, selected: ?EntityId) !void {
        self.assertMutationAllowed();
        if (self.selected_entity) |current| {
            if (selected) |next| {
                if (current.eql(next)) return;
            } else {
                if (!self.world.isAlive(current)) {
                    self.setSelectableSelected(current, false);
                    self.selected_entity = null;
                    return;
                }
            }
            self.setSelectableSelected(current, false);
            if (self.started and self.world.isAlive(current)) try self.scripts.queueEvent(current, .deselected);
            self.selected_entity = null;
        }

        if (selected) |entity| {
            if (!self.world.isAlive(entity)) return;
            const index: usize = @intCast(entity.index);
            if (index >= self.components.selectables.items.len or self.components.selectables.items[index] == null) return;
            self.setSelectableSelected(entity, true);
            self.selected_entity = entity;
            if (self.started) try self.scripts.queueEvent(entity, .selected);
        }
    }

    pub fn configureExecution(self: *SceneRuntime, runtime_kind: LoadedSceneRuntimeKind, renderables: []const RuntimeRenderableSetup) !void {
        try self.execution.configure(self.allocator, &self.components, runtime_kind, renderables);
        if (runtime_kind != .static) self.execution.syncBindingsToTransforms(&self.components);
        try self.propagateWorldTransforms();
        self.renderables_dirty = true;
    }

    pub fn setAssetState(self: *SceneRuntime, handle: AssetHandle, state: AssetState) !bool {
        const record = self.assets.getConst(handle) orelse return false;
        const previous_state = record.state;
        if (previous_state == state) return true;
        if (!self.assets.setState(handle, state)) return false;
        if (!self.started) return true;
        if (state == .resident) {
            try self.queueAssetEventForDependents(handle, .{ .asset_ready = handle });
        } else if (previous_state == .resident) {
            try self.queueAssetEventForDependents(handle, .{ .asset_lost = handle });
        }
        return true;
    }

    pub fn setExecutionInputs(self: *SceneRuntime, enter_pressed: bool, pause_dynamics: bool, script_input: ScriptInputState) void {
        self.script_input = script_input;
        self.execution.setInputs(enter_pressed, script_input.keyboard.isDown(.k), pause_dynamics);
    }

    pub fn takeRenderablesDirty(self: *SceneRuntime) bool {
        const dirty = self.renderables_dirty;
        self.renderables_dirty = false;
        return dirty;
    }

    pub fn translateEntity(self: *SceneRuntime, entity: EntityId, delta: scene_math.Vec3) bool {
        self.assertMutationAllowed();
        if (!self.world.isAlive(entity)) return false;
        if (self.execution.translateEntity(&self.components, entity, delta, &self.renderables_dirty)) {
            self.hierarchy.markSubtreeDirty(entity);
            self.propagateWorldTransforms() catch {};
            const index: usize = @intCast(entity.index);
            if (index < self.components.world_transforms.items.len and self.components.world_transforms.items[index] != null) {
                _ = self.residency.updateEntityPosition(entity, self.components.world_transforms.items[index].?.position) catch {};
            }
            return true;
        }
        const index: usize = @intCast(entity.index);
        var changed = false;
        const local_delta = if (self.hierarchy.parentOf(entity)) |parent|
            if (self.worldTransform(parent)) |parent_world|
                worldDeltaToLocal(parent_world, delta)
            else
                delta
        else
            delta;
        if (index < self.components.local_transforms.items.len and self.components.local_transforms.items[index] != null) {
            self.components.local_transforms.items[index].?.position = scene_math.Vec3.add(self.components.local_transforms.items[index].?.position, local_delta);
            changed = true;
        }
        if (changed) {
            self.hierarchy.markSubtreeDirty(entity);
            self.propagateWorldTransforms() catch {};
            if (index < self.components.world_transforms.items.len and self.components.world_transforms.items[index] != null) {
                _ = self.residency.updateEntityPosition(entity, self.components.world_transforms.items[index].?.position) catch return changed;
            }
            self.renderables_dirty = true;
        }
        return changed;
    }

    pub fn attachEntity(self: *SceneRuntime, parent: EntityId, child: EntityId) !void {
        self.assertMutationAllowed();
        try self.hierarchy.attachChild(&self.world, parent, child);
        try self.propagateWorldTransforms();
        if (self.started) try self.scripts.queueEvent(child, .parent_changed);
        self.renderables_dirty = true;
    }

    /// Builds bootstrap from description.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn bootstrapFromDescription(self: *SceneRuntime, scene: BootstrapScene) !void {
        self.assertMutationAllowed();
        self.renderable_entities.clearRetainingCapacity();
        try self.ensureBuiltinScriptModules();
        var pending_parent_links = std.ArrayList(PendingParentLink){};
        defer pending_parent_links.deinit(self.allocator);
        if (scene.hdri_path) |hdri_path| {
            const hdri_handle = try self.assets.register(.hdri, hdri_path);
            _ = try self.setAssetState(hdri_handle, .resident);
            _ = self.assets.retain(hdri_handle);
        }

        const camera_entity = try self.createEntity();
        const camera_index: usize = @intCast(camera_entity.index);
        self.components.local_transforms.items[camera_index] = .{ .position = scene.camera.position };
        self.components.world_transforms.items[camera_index] = .{ .position = scene.camera.position };
        self.components.cameras.items[camera_index] = .{
            .fov_deg = scene.camera.fov_deg,
            .pitch = scene.camera.pitch,
            .yaw = scene.camera.yaw,
            .active = true,
        };
        try self.registerAuthoredEntity(camera_entity, scene.camera.authored_id);
        try self.attachAuthoredScripts(camera_entity, scene.camera.scripts);
        _ = try self.residency.registerStaticEntity(camera_entity, scene.camera.position);
        if (scene.camera.parent_authored_id) |parent_authored_id| {
            try pending_parent_links.append(self.allocator, .{ .child = camera_entity, .parent_authored_id = parent_authored_id });
        }

        for (scene.lights) |light| {
            const entity = try self.createEntity();
            const index: usize = @intCast(entity.index);
            const position = scene_math.Vec3.scale(light.direction, light.distance);
            self.components.local_transforms.items[index] = .{ .position = position };
            self.components.world_transforms.items[index] = .{ .position = position };
            self.components.lights.items[index] = .{
                .kind = .directional,
                .color = light.color,
                .intensity = 1.0,
                .range = light.distance,
                .glow_radius = light.glow_radius,
                .glow_intensity = light.glow_intensity,
                .shadow_mode = light.shadow_mode,
                .shadow_update_interval_frames = @max(@as(u32, 1), light.shadow_update_interval_frames),
                .shadow_map_size = @max(@as(usize, 64), light.shadow_map_size),
            };
            try self.registerAuthoredEntity(entity, light.authored_id);
            try self.attachAuthoredScripts(entity, light.scripts);
            _ = try self.residency.registerStaticEntity(entity, position);
            if (light.parent_authored_id) |parent_authored_id| {
                try pending_parent_links.append(self.allocator, .{ .child = entity, .parent_authored_id = parent_authored_id });
            }
        }

        for (scene.assets) |asset| {
            const entity = try self.createEntity();
            const index: usize = @intCast(entity.index);
            const mesh_handle = try self.assets.register(.mesh, asset.model_path);
            _ = try self.setAssetState(mesh_handle, .resident);
            _ = self.assets.retain(mesh_handle);
            try self.dependencies.addEdge(.{
                .source = entity,
                .target = .{ .asset = mesh_handle },
                .kind = .asset,
                .hard = true,
            });

            self.components.local_transforms.items[index] = .{
                .position = asset.position,
                .rotation_deg = asset.rotation_deg,
                .scale = asset.scale,
            };
            self.components.world_transforms.items[index] = .{
                .position = asset.position,
                .rotation_deg = asset.rotation_deg,
                .scale = asset.scale,
            };
            self.components.renderables.items[index] = .{
                .mesh = mesh_handle,
                .visible = true,
                .casts_shadows = true,
            };
            try self.registerAuthoredEntity(entity, asset.authored_id);
            try self.attachAuthoredScripts(entity, asset.scripts);
            self.components.selectables.items[index] = .{};
            self.components.streamables.items[index] = .{ .policy = .always_resident };

            if (asset.physics_motion) |motion| {
                self.components.physics_bodies.items[index] = .{
                    .motion = motion,
                    .shape = if (asset.physics_shape != null and std.ascii.eqlIgnoreCase(asset.physics_shape.?, "sphere")) .sphere else .box,
                    .mass = asset.physics_mass orelse 0.0,
                    .restitution = asset.physics_restitution orelse 0.0,
                };
            }

            if (asset.texture_slots.len != 0) {
                var slots = TextureSlots{};
                for (asset.texture_slots) |slot| {
                    if (slot.slot >= slots.slots.len) continue;
                    const texture_handle = try self.assets.register(.texture, slot.path);
                    _ = try self.setAssetState(texture_handle, .resident);
                    _ = self.assets.retain(texture_handle);
                    try self.dependencies.addEdge(.{
                        .source = entity,
                        .target = .{ .asset = texture_handle },
                        .kind = .asset,
                        .hard = true,
                    });
                    slots.slots[slot.slot] = texture_handle;
                }
                self.components.texture_slots.items[index] = slots;
            }

            _ = try self.residency.registerStaticEntity(entity, asset.position);
            try self.renderable_entities.append(self.allocator, entity);
            if (asset.parent_authored_id) |parent_authored_id| {
                try pending_parent_links.append(self.allocator, .{ .child = entity, .parent_authored_id = parent_authored_id });
            }
        }

        for (pending_parent_links.items) |link| {
            const parent = self.lookupEntityByAuthoredId(link.parent_authored_id) orelse return error.UnknownParentEntityId;
            try self.attachEntity(parent, link.child);
        }

        try self.propagateWorldTransforms();
        try self.dependencies.validateAcyclic(&self.world);
        self.renderables_dirty = true;
    }

    fn registerAuthoredEntity(self: *SceneRuntime, entity: EntityId, authored_id: ?[]const u8) !void {
        const id = authored_id orelse return;
        const entry = try self.authored_entity_lookup.getOrPut(self.allocator, id);
        if (entry.found_existing) return error.DuplicateSceneEntityId;
        entry.value_ptr.* = entity;
        self.components.scene_nodes.items[@intCast(entity.index)] = .{
            .authored_id = id,
            .node_id = SceneNodeId.init(stableSceneNodeHash(id)),
        };
    }

    fn unregisterAuthoredEntity(self: *SceneRuntime, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.components.scene_nodes.items.len) return;
        const node = self.components.scene_nodes.items[index] orelse return;
        _ = self.authored_entity_lookup.remove(node.authored_id);
        self.components.scene_nodes.items[index] = null;
    }

    fn stableSceneNodeHash(authored_id: []const u8) u64 {
        return std.hash.Wyhash.hash(0, authored_id);
    }

    fn ensureBuiltinScriptModules(self: *SceneRuntime) !void {
        try script_registry_module.registerNativeModules(&self.scripts, &self.assets);
    }

    fn attachAuthoredScripts(self: *SceneRuntime, entity: EntityId, scripts: []const BootstrapScriptAttachment) !void {
        if (scripts.len == 0) return;
        for (scripts) |script| {
            const attached = try self.attachScriptToEntity(entity, script.module_name);
            if (!attached) return error.DuplicateScriptAttachment;
        }
    }

    /// Updates registry/attachment state for pin frame assets.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn pinFrameAssets(self: *SceneRuntime, snapshot: *const RenderSnapshot) void {
        var pin_count: usize = 0;
        for (snapshot.renderables.items) |entity| {
            const index: usize = @intCast(entity.entity.index);
            if (index >= self.components.renderables.items.len) continue;

            if (self.components.renderables.items[index]) |renderable| {
                if (renderable.mesh.isValid()) {
                    if (self.assets.pin(renderable.mesh)) pin_count += 1;
                }
                if (renderable.material.isValid()) {
                    if (self.assets.pin(renderable.material)) pin_count += 1;
                }
            }
            if (index < self.components.texture_slots.items.len) {
                if (self.components.texture_slots.items[index]) |texture_slots| {
                    for (texture_slots.slots) |handle| {
                        if (!handle.isValid()) continue;
                        if (self.assets.pin(handle)) pin_count += 1;
                    }
                }
            }
        }
        self.stats.render_extraction_pins = pin_count;
    }

    /// Updates registry/attachment state for unpin frame assets.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn unpinFrameAssets(self: *SceneRuntime, snapshot: *const RenderSnapshot) void {
        for (snapshot.renderables.items) |entity| {
            const index: usize = @intCast(entity.entity.index);
            if (index >= self.components.renderables.items.len) continue;

            if (self.components.renderables.items[index]) |renderable| {
                if (renderable.mesh.isValid()) _ = self.assets.unpin(renderable.mesh);
                if (renderable.material.isValid()) _ = self.assets.unpin(renderable.material);
            }
            if (index < self.components.texture_slots.items.len) {
                if (self.components.texture_slots.items[index]) |texture_slots| {
                    for (texture_slots.slots) |handle| {
                        if (!handle.isValid()) continue;
                        _ = self.assets.unpin(handle);
                    }
                }
            }
        }
    }

    /// updateFrame updates Main state for the current tick/frame.
    pub fn updateFrame(
        self: *SceneRuntime,
        camera_position: scene_math.Vec3,
        camera_pitch: f32,
        camera_yaw: f32,
        active_radius: f32,
        prefetch_radius: f32,
        frame_index: u64,
        delta_seconds: f32,
    ) !RenderSnapshot {
        self.beginPhase(.input);
        for (self.components.cameras.items, 0..) |maybe_camera, index| {
            if (maybe_camera) |camera| {
                if (!camera.active) continue;
                const entity = EntityId.init(@intCast(index), self.world.generations.items[index]);
                const renderer_owns_camera = !self.entityHasScripts(entity) or !self.script_input.first_person_active;
                if (renderer_owns_camera and index < self.components.local_transforms.items.len and self.components.local_transforms.items[index] != null) {
                    self.components.local_transforms.items[index].?.position = camera_position;
                    self.hierarchy.markSubtreeDirty(entity);
                    self.components.cameras.items[index].?.pitch = camera_pitch;
                    self.components.cameras.items[index].?.yaw = camera_yaw;
                }
                break;
            }
        }
        self.endPhase(.input);

        self.beginPhase(.job_completion_integration);
        self.endPhase(.job_completion_integration);

        self.beginPhase(.transform_propagation);
        try self.propagateWorldTransforms();
        self.endPhase(.transform_propagation);

        self.beginPhase(.fixed_step_physics);
        self.execution.syncBindingResidency(&self.world, &self.components, &self.residency);
        self.stats.physics_phase_pins = self.pinAssetsForUsage(.physics_sync);
        const fixed_step_count = self.stepFixedPhysics(delta_seconds);
        self.unpinAssetsForUsage(.physics_sync);
        self.endPhase(.fixed_step_physics);

        self.beginPhase(.transform_propagation);
        try self.propagateWorldTransforms();
        self.endPhase(.transform_propagation);

        self.beginPhase(.residency_decisions);
        const previous_resident_states = try self.allocator.alloc(bool, self.residency.cells.items.len);
        defer self.allocator.free(previous_resident_states);
        for (self.residency.cells.items, 0..) |cell, index| {
            previous_resident_states[index] = cell.state == .resident;
        }
        for (self.components.world_transforms.items, 0..) |maybe_transform, index| {
            const transform = maybe_transform orelse continue;
            const entity = EntityId.init(@intCast(index), self.world.generations.items[index]);
            if (!self.world.isAlive(entity)) continue;
            _ = try self.residency.updateEntityPosition(entity, transform.position);
        }

        try self.residency.updateCamera(camera_position, active_radius, prefetch_radius, frame_index);
        self.execution.syncBindingResidency(&self.world, &self.components, &self.residency);
        if (self.started) try self.queueResidencyZoneEvents(previous_resident_states);
        self.endPhase(.residency_decisions);

        self.beginPhase(.script_events);
        if (!self.started) {
            try self.scripts.queueBeginPlayForPending(&self.world);
            try self.queueResidentAssetReadyEvents();
            self.started = true;
        }

        self.stats.script_phase_pins = self.pinAssetsForUsage(.script_dispatch);
        if (self.execution.consumeKPressedEdge()) {
            try self.scripts.queueKPressedForAll(&self.world);
        }
        try self.scripts.queueUpdateForAll(&self.world, delta_seconds);
        try self.scripts.queueFixedUpdateForAll(&self.world, fixedStepSeconds, fixed_step_count);
        try self.scripts.queueLateUpdateForAll(&self.world, delta_seconds);
        self.scripts.dispatchQueued(&self.world, &self.components, &self.script_input, &self.commands);
        self.unpinAssetsForUsage(.script_dispatch);
        self.applyDeferred();
        self.endPhase(.script_events);

        self.beginPhase(.render_extraction);
        const snapshot = try extractFrameSnapshot(self.allocator, &self.world, &self.components, &self.residency);
        self.endPhase(.render_extraction);

        self.beginPhase(.safe_offload_deferred_destruction);
        self.applyDeferred();
        self.endPhase(.safe_offload_deferred_destruction);

        self.stats = .{
            .frame_index = frame_index,
            .resident_renderables = snapshot.renderables.items.len,
            .resident_lights = snapshot.lights.items.len,
            .script_phase_pins = self.stats.script_phase_pins,
            .physics_phase_pins = self.stats.physics_phase_pins,
            .render_extraction_pins = self.stats.render_extraction_pins,
        };
        return snapshot;
    }

    pub fn beginPresent(self: *SceneRuntime) void {
        self.beginPhase(.present);
    }

    pub fn endPresent(self: *SceneRuntime) void {
        self.endPhase(.present);
    }

    pub fn debugDumpDependenciesForEntity(self: *const SceneRuntime, allocator: std.mem.Allocator, entity: EntityId) ![]u8 {
        return self.dependencies.debugDumpForEntity(allocator, entity);
    }

    pub fn debugDumpAssetResidency(self: *const SceneRuntime, allocator: std.mem.Allocator) ![]u8 {
        return self.assets.debugDump(allocator);
    }

    fn setEntityEnabledRecursive(self: *SceneRuntime, entity: EntityId, enabled: bool) void {
        if (!self.world.setEnabled(entity, enabled)) return;
        const index: usize = @intCast(entity.index);
        if (index < self.components.activation_states.items.len) {
            self.components.activation_states.items[index] = .{ .enabled = enabled };
        }
        if (self.started) self.scripts.setEntityEnabled(&self.world, entity, enabled) catch {};
        var child = self.hierarchy.firstChildOf(entity);
        while (child) |current| {
            self.setEntityEnabledRecursive(current, enabled);
            child = self.hierarchy.nextSiblingOf(current);
        }
    }

    fn propagateWorldTransforms(self: *SceneRuntime) !void {
        for (self.components.local_transforms.items, 0..) |maybe_local, index| {
            _ = maybe_local orelse continue;
            const entity = EntityId.init(@intCast(index), self.world.generations.items[index]);
            if (!self.world.isAlive(entity)) continue;
            if (self.hierarchy.parentOf(entity) != null) continue;
            try self.propagateTransformSubtree(entity, null);
        }
    }

    fn propagateTransformSubtree(self: *SceneRuntime, entity: EntityId, parent_world: ?components_module.TransformWorld) !void {
        if (!self.world.isAlive(entity)) return;
        const index: usize = @intCast(entity.index);
        if (index >= self.components.local_transforms.items.len) return;
        const local = self.components.local_transforms.items[index] orelse return;
        const next_world = if (parent_world) |parent|
            composeWorldTransform(parent, local)
        else
            components_module.TransformWorld{
                .position = local.position,
                .rotation_deg = local.rotation_deg,
                .scale = local.scale,
            };
        const current_world = if (index < self.components.world_transforms.items.len) self.components.world_transforms.items[index] else null;
        const changed = current_world == null or !worldTransformsEqual(current_world.?, next_world);
        self.components.world_transforms.items[index] = next_world;
        self.hierarchy.clearDirty(entity);
        if (changed and self.started) try self.scripts.queueEvent(entity, .transform_changed);

        var child = self.hierarchy.firstChildOf(entity);
        while (child) |current| {
            try self.propagateTransformSubtree(current, next_world);
            child = self.hierarchy.nextSiblingOf(current);
        }
    }

    fn setSelectableSelected(self: *SceneRuntime, entity: EntityId, selected: bool) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.components.selectables.items.len) return;
        if (self.components.selectables.items[index]) |*selectable| {
            selectable.selected = selected;
        }
    }

    fn setCameraOrientation(self: *SceneRuntime, entity: EntityId, pitch: f32, yaw: f32) bool {
        if (!self.world.isAlive(entity)) return false;
        const index: usize = @intCast(entity.index);
        if (index >= self.components.cameras.items.len or self.components.cameras.items[index] == null) return false;
        self.components.cameras.items[index].?.pitch = pitch;
        self.components.cameras.items[index].?.yaw = yaw;
        return true;
    }

    fn entityHasScripts(self: *const SceneRuntime, entity: EntityId) bool {
        const index: usize = @intCast(entity.index);
        if (index >= self.components.scripts.items.len) return false;
        return scriptComponentHasAttachments(self.components.scripts.items[index]);
    }

    fn beginPhase(self: *SceneRuntime, phase: FramePhase) void {
        self.current_phase = phase;
    }

    fn endPhase(self: *SceneRuntime, phase: FramePhase) void {
        self.current_phase = null;
        self.last_completed_phase = phase;
    }

    fn stepFixedPhysics(self: *SceneRuntime, delta_seconds: f32) u32 {
        self.fixed_step_accumulator += delta_seconds;
        var step_count: u32 = 0;
        while (self.fixed_step_accumulator + 1e-6 >= fixedStepSeconds) {
            self.execution.step(&self.components, fixedStepSeconds, &self.renderables_dirty);
            self.fixed_step_accumulator -= fixedStepSeconds;
            step_count += 1;
        }
        return step_count;
    }

    fn queueResidentAssetReadyEvents(self: *SceneRuntime) !void {
        for (self.dependencies.edges.items) |edge| {
            if (edge.kind != .asset) continue;
            if (!self.world.isAlive(edge.source)) continue;
            switch (edge.target) {
                .asset => |handle| {
                    const record = self.assets.getConst(handle) orelse continue;
                    if (record.state != .resident) continue;
                    try self.scripts.queueEvent(edge.source, .{ .asset_ready = handle });
                },
                .entity => {},
            }
        }
    }

    fn queueResidencyZoneEvents(self: *SceneRuntime, previous_resident_states: []const bool) !void {
        const cell_count = @min(previous_resident_states.len, self.residency.cells.items.len);
        var cell_index: usize = 0;
        while (cell_index < cell_count) : (cell_index += 1) {
            const was_resident = previous_resident_states[cell_index];
            const is_resident = self.residency.cells.items[cell_index].state == .resident;
            if (was_resident == is_resident) continue;
            const event: ScriptEvent = if (is_resident)
                .{ .zone_enter = EntityId.init(@intCast(cell_index), 0) }
            else
                .{ .zone_exit = EntityId.init(@intCast(cell_index), 0) };
            for (self.residency.tree.cells.items[cell_index].entities.items) |entity| {
                if (!self.world.isAlive(entity) or !self.world.isEnabled(entity)) continue;
                const entity_index: usize = @intCast(entity.index);
                if (entity_index >= self.components.scripts.items.len or self.components.scripts.items[entity_index] == null) continue;
                try self.scripts.queueEvent(entity, event);
            }
        }
    }

    fn queueAssetEventForDependents(self: *SceneRuntime, handle: AssetHandle, event: ScriptEvent) !void {
        for (self.dependencies.edges.items) |edge| {
            if (edge.kind != .asset) continue;
            if (!self.world.isAlive(edge.source)) continue;
            switch (edge.target) {
                .asset => |target_handle| {
                    if (!target_handle.eql(handle)) continue;
                    try self.scripts.queueEvent(edge.source, event);
                },
                .entity => {},
            }
        }
    }

    fn pinAssetsForUsage(self: *SceneRuntime, usage: PhaseAssetUsage) usize {
        var pin_count: usize = 0;
        for (self.dependencies.edges.items) |edge| {
            if (!self.shouldPinAssetForUsage(edge.source, usage)) continue;
            switch (edge.target) {
                .asset => |handle| {
                    if (self.assets.pin(handle)) pin_count += 1;
                },
                .entity => {},
            }
        }
        return pin_count;
    }

    fn unpinAssetsForUsage(self: *SceneRuntime, usage: PhaseAssetUsage) void {
        for (self.dependencies.edges.items) |edge| {
            if (!self.shouldPinAssetForUsage(edge.source, usage)) continue;
            switch (edge.target) {
                .asset => |handle| {
                    _ = self.assets.unpin(handle);
                },
                .entity => {},
            }
        }
    }

    fn shouldPinAssetForUsage(self: *const SceneRuntime, entity: EntityId, usage: PhaseAssetUsage) bool {
        if (!self.world.isAlive(entity) or !self.world.isEnabled(entity)) return false;
        const index: usize = @intCast(entity.index);
        return switch (usage) {
            .script_dispatch => index < self.components.scripts.items.len and scriptComponentHasAttachments(self.components.scripts.items[index]),
            .physics_sync => index < self.components.physics_bodies.items.len and self.components.physics_bodies.items[index] != null,
        };
    }

    fn assertMutationAllowed(self: *const SceneRuntime) void {
        if (builtin.mode != .Debug) return;
        if (self.current_phase) |phase| {
            std.debug.assert(phase != .render_extraction);
            std.debug.assert(phase != .transform_propagation);
        }
    }
};

const fixedStepSeconds: f32 = 1.0 / 60.0;

fn composeWorldTransform(parent: components_module.TransformWorld, local: components_module.TransformLocal) components_module.TransformWorld {
    return .{
        .position = scene_math.Vec3.add(parent.position, rotateVector(mulComponents(local.position, parent.scale), parent.rotation_deg)),
        .rotation_deg = scene_math.Vec3.add(parent.rotation_deg, local.rotation_deg),
        .scale = mulComponents(parent.scale, local.scale),
    };
}

fn worldTransformsEqual(a: components_module.TransformWorld, b: components_module.TransformWorld) bool {
    return vec3ApproxEq(a.position, b.position) and vec3ApproxEq(a.rotation_deg, b.rotation_deg) and vec3ApproxEq(a.scale, b.scale);
}

fn vec3ApproxEq(a: scene_math.Vec3, b: scene_math.Vec3) bool {
    return approxEq(a.x, b.x) and approxEq(a.y, b.y) and approxEq(a.z, b.z);
}

fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-4;
}

fn scriptComponentHasAttachments(component: ?components_module.ScriptComponent) bool {
    return component != null and component.?.count != 0;
}

fn findScriptAttachmentSlot(component: components_module.ScriptComponent, module: AssetHandle) ?u8 {
    var index: u8 = 0;
    while (index < component.count) : (index += 1) {
        if (component.modules[index].eql(module)) return index;
    }
    return null;
}

fn removeScriptAttachmentAt(component: *components_module.ScriptComponent, slot: u8) void {
    std.debug.assert(slot < component.count);
    var index: usize = slot;
    const last_index: usize = component.count - 1;
    while (index < last_index) : (index += 1) {
        component.modules[index] = component.modules[index + 1];
    }
    component.count -= 1;
    component.modules[component.count] = AssetHandle.invalid();
}

fn worldDeltaToLocal(parent: components_module.TransformWorld, world_delta: scene_math.Vec3) scene_math.Vec3 {
    return divideComponents(inverseRotateVector(world_delta, parent.rotation_deg), parent.scale);
}

fn inverseRotateVector(v: scene_math.Vec3, rotation_deg: scene_math.Vec3) scene_math.Vec3 {
    return rotateVector(v, .{
        .x = -rotation_deg.x,
        .y = -rotation_deg.y,
        .z = -rotation_deg.z,
    });
}

fn divideComponents(a: scene_math.Vec3, b: scene_math.Vec3) scene_math.Vec3 {
    return .{
        .x = if (@abs(b.x) > 1e-6) a.x / b.x else a.x,
        .y = if (@abs(b.y) > 1e-6) a.y / b.y else a.y,
        .z = if (@abs(b.z) > 1e-6) a.z / b.z else a.z,
    };
}

fn entityIsResident(residency: *const ResidencyManager, entity: EntityId) bool {
    const index: usize = @intCast(entity.index);
    if (index >= residency.tree.entity_cells.items.len) return true;
    const cell_id = residency.tree.entity_cells.items[index] orelse return true;
    return residency.cells.items[@intCast(cell_id)].state == .resident;
}
