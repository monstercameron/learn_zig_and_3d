//! Render Extraction module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");
const World = @import("world.zig").World;
const components = @import("components.zig");
const ComponentStore = components.ComponentStore;
const ResidencyManager = @import("residency_manager.zig").ResidencyManager;
const math = @import("math.zig");

pub const EntityId = handles.EntityId;

pub const CameraState = struct {
    entity: EntityId,
    position: math.Vec3,
    pitch: f32,
    yaw: f32,
    fov_deg: f32,
};

pub const LightState = struct {
    entity: EntityId,
    position: math.Vec3,
    kind: components.LightKind,
    color: math.Vec3,
    intensity: f32,
    range: f32,
    glow_radius: f32,
    glow_intensity: f32,
    shadow_mode: components.LightShadowMode,
    shadow_update_interval_frames: u32,
    shadow_map_size: usize,
};

pub const RenderableState = struct {
    entity: EntityId,
    position: math.Vec3,
};

pub const RenderSnapshot = struct {
    allocator: std.mem.Allocator,
    active_camera: ?CameraState = null,
    renderables: std.ArrayList(RenderableState) = .{},
    lights: std.ArrayList(LightState) = .{},

    /// deinit releases resources owned by Render Extraction.
    pub fn deinit(self: *RenderSnapshot) void {
        self.renderables.deinit(self.allocator);
        self.lights.deinit(self.allocator);
    }
};

/// Processes extract frame snapshot.
/// Propagates recoverable errors so allocation/IO failures stay explicit to the caller.
pub fn extractFrameSnapshot(allocator: std.mem.Allocator, world: *const World, store: *const ComponentStore, residency: *const ResidencyManager) !RenderSnapshot {
    var snapshot = RenderSnapshot{ .allocator = allocator };
    errdefer snapshot.deinit();

    for (store.cameras.items, 0..) |maybe_camera, index| {
        const entity = EntityId.init(@intCast(index), world.generations.items[index]);
        if (!world.isEnabled(entity)) continue;
        if (!isResident(residency, entity)) continue;
        if (maybe_camera) |camera| {
            if (camera.active) {
                const position = if (index < store.world_transforms.items.len and store.world_transforms.items[index] != null)
                    store.world_transforms.items[index].?.position
                else
                    math.Vec3.new(0.0, 0.0, 0.0);
                snapshot.active_camera = .{
                    .entity = entity,
                    .position = position,
                    .pitch = camera.pitch,
                    .yaw = camera.yaw,
                    .fov_deg = camera.fov_deg,
                };
                break;
            }
        }
    }

    for (store.renderables.items, 0..) |maybe_renderable, index| {
        const entity = EntityId.init(@intCast(index), world.generations.items[index]);
        if (!world.isEnabled(entity)) continue;
        if (!isResident(residency, entity)) continue;
        if (maybe_renderable) |renderable| {
            if (renderable.visible) {
                const position = if (index < store.world_transforms.items.len and store.world_transforms.items[index] != null)
                    store.world_transforms.items[index].?.position
                else
                    math.Vec3.new(0.0, 0.0, 0.0);
                try snapshot.renderables.append(allocator, .{
                    .entity = entity,
                    .position = position,
                });
            }
        }
    }

    for (store.lights.items, 0..) |maybe_light, index| {
        const entity = EntityId.init(@intCast(index), world.generations.items[index]);
        if (!world.isEnabled(entity)) continue;
        if (!isResident(residency, entity)) continue;
        if (maybe_light) |light| {
            const position = if (index < store.world_transforms.items.len and store.world_transforms.items[index] != null)
                store.world_transforms.items[index].?.position
            else
                math.Vec3.new(0.0, 0.0, 0.0);
            try snapshot.lights.append(allocator, .{
                .entity = entity,
                .position = position,
                .kind = light.kind,
                .color = light.color,
                .intensity = light.intensity,
                .range = light.range,
                .glow_radius = light.glow_radius,
                .glow_intensity = light.glow_intensity,
                .shadow_mode = light.shadow_mode,
                .shadow_update_interval_frames = light.shadow_update_interval_frames,
                .shadow_map_size = light.shadow_map_size,
            });
        }
    }

    return snapshot;
}

/// Returns whether i sr es id en t.
/// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
fn isResident(residency: *const ResidencyManager, entity: EntityId) bool {
    const index: usize = @intCast(entity.index);
    if (index >= residency.tree.entity_cells.items.len) return true;
    const cell_id = residency.tree.entity_cells.items[index] orelse return true;
    return residency.cells.items[@intCast(cell_id)].state == .resident;
}
