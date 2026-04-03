//! World module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");
const math = @import("math.zig");

pub const EntityId = handles.EntityId;

pub const RendererControlAxis = enum(u8) {
    x,
    y,
    z,
};

pub const CameraControlMode = enum(u8) {
    editor,
    first_person,
    toggle,
};

pub const Command = union(enum) {
    destroy_entity: EntityId,
    set_enabled: struct {
        entity: EntityId,
        enabled: bool,
    },
    jump_entity: struct {
        entity: EntityId,
        upward_velocity: f32,
    },
    translate_entity: struct {
        entity: EntityId,
        delta: math.Vec3,
    },
    set_local_rotation_deg: struct {
        entity: EntityId,
        rotation_deg: math.Vec3,
    },
    set_local_scale: struct {
        entity: EntityId,
        scale: math.Vec3,
    },
    set_camera_orientation: struct {
        entity: EntityId,
        pitch: f32,
        yaw: f32,
    },
    adjust_camera_fov: struct {
        delta: f32,
    },
    set_camera_mode: CameraControlMode,
    toggle_scene_item_gizmo,
    toggle_light_gizmo,
    set_gizmo_axis: RendererControlAxis,
    cycle_light_selection,
    nudge_active_gizmo: struct {
        delta: f32,
    },
    toggle_render_overlay,
    toggle_shadow_debug,
    advance_shadow_debug,
};

pub const Commands = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Command) = .{},

    /// init initializes World state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) Commands {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by World.
    pub fn deinit(self: *Commands) void {
        self.pending.deinit(self.allocator);
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueDestroy(self: *Commands, entity: EntityId) !void {
        try self.pending.append(self.allocator, .{ .destroy_entity = entity });
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueSetEnabled(self: *Commands, entity: EntityId, enabled: bool) !void {
        try self.pending.append(self.allocator, .{ .set_enabled = .{ .entity = entity, .enabled = enabled } });
    }

    /// Queues a jump request for an entity handled by the scene runtime at a safe sync point.
    pub fn queueJump(self: *Commands, entity: EntityId, upward_velocity: f32) !void {
        try self.pending.append(self.allocator, .{ .jump_entity = .{ .entity = entity, .upward_velocity = upward_velocity } });
    }

    pub fn queueTranslate(self: *Commands, entity: EntityId, delta: math.Vec3) !void {
        try self.pending.append(self.allocator, .{ .translate_entity = .{ .entity = entity, .delta = delta } });
    }

    pub fn queueSetLocalRotationDeg(self: *Commands, entity: EntityId, rotation_deg: math.Vec3) !void {
        try self.pending.append(self.allocator, .{ .set_local_rotation_deg = .{ .entity = entity, .rotation_deg = rotation_deg } });
    }

    pub fn queueSetLocalScale(self: *Commands, entity: EntityId, scale: math.Vec3) !void {
        try self.pending.append(self.allocator, .{ .set_local_scale = .{ .entity = entity, .scale = scale } });
    }

    pub fn queueSetCameraOrientation(self: *Commands, entity: EntityId, pitch: f32, yaw: f32) !void {
        try self.pending.append(self.allocator, .{ .set_camera_orientation = .{ .entity = entity, .pitch = pitch, .yaw = yaw } });
    }

    pub fn queueAdjustCameraFov(self: *Commands, delta: f32) !void {
        try self.pending.append(self.allocator, .{ .adjust_camera_fov = .{ .delta = delta } });
    }

    pub fn queueSetCameraMode(self: *Commands, mode: CameraControlMode) !void {
        try self.pending.append(self.allocator, .{ .set_camera_mode = mode });
    }

    pub fn queueToggleSceneItemGizmo(self: *Commands) !void {
        try self.pending.append(self.allocator, .toggle_scene_item_gizmo);
    }

    pub fn queueToggleLightGizmo(self: *Commands) !void {
        try self.pending.append(self.allocator, .toggle_light_gizmo);
    }

    pub fn queueSetGizmoAxis(self: *Commands, axis: RendererControlAxis) !void {
        try self.pending.append(self.allocator, .{ .set_gizmo_axis = axis });
    }

    pub fn queueCycleLightSelection(self: *Commands) !void {
        try self.pending.append(self.allocator, .cycle_light_selection);
    }

    pub fn queueNudgeActiveGizmo(self: *Commands, delta: f32) !void {
        try self.pending.append(self.allocator, .{ .nudge_active_gizmo = .{ .delta = delta } });
    }

    pub fn queueToggleRenderOverlay(self: *Commands) !void {
        try self.pending.append(self.allocator, .toggle_render_overlay);
    }

    pub fn queueToggleShadowDebug(self: *Commands) !void {
        try self.pending.append(self.allocator, .toggle_shadow_debug);
    }

    pub fn queueAdvanceShadowDebug(self: *Commands) !void {
        try self.pending.append(self.allocator, .advance_shadow_debug);
    }

    pub fn appendFrom(self: *Commands, other: *Commands) !void {
        if (other.pending.items.len == 0) return;
        try self.pending.appendSlice(self.allocator, other.pending.items);
        other.clear();
    }

    /// Resets clear.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn clear(self: *Commands) void {
        self.pending.clearRetainingCapacity();
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    generations: std.ArrayList(u32) = .{},
    alive: std.ArrayList(bool) = .{},
    enabled: std.ArrayList(bool) = .{},
    free_list: std.ArrayList(u32) = .{},

    /// init initializes World state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) World {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by World.
    pub fn deinit(self: *World) void {
        self.generations.deinit(self.allocator);
        self.alive.deinit(self.allocator);
        self.enabled.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// createEntity creates a new value used by World.
    pub fn createEntity(self: *World) !EntityId {
        if (self.free_list.items.len != 0) {
            const slot = self.free_list.pop().?;
            const index: usize = @intCast(slot);
            self.alive.items[index] = true;
            self.enabled.items[index] = true;
            return EntityId.init(slot, self.generations.items[index]);
        }

        const slot: u32 = @intCast(self.generations.items.len);
        try self.generations.append(self.allocator, 1);
        errdefer _ = self.generations.pop();
        try self.alive.append(self.allocator, true);
        errdefer _ = self.alive.pop();
        try self.enabled.append(self.allocator, true);
        errdefer _ = self.enabled.pop();
        return EntityId.init(slot, 1);
    }

    /// destroyEntity destroys or reclaims World resources.
    pub fn destroyEntity(self: *World, entity: EntityId) bool {
        if (!self.isAlive(entity)) return false;
        const index: usize = @intCast(entity.index);
        self.alive.items[index] = false;
        self.enabled.items[index] = false;
        self.generations.items[index] +%= 1;
        if (self.generations.items[index] == 0) self.generations.items[index] = 1;
        self.free_list.append(self.allocator, entity.index) catch return false;
        return true;
    }

    /// Returns whether i sa li ve.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn isAlive(self: *const World, entity: EntityId) bool {
        if (!entity.isValid()) return false;
        const index: usize = @intCast(entity.index);
        return index < self.generations.items.len and
            self.alive.items[index] and
            self.generations.items[index] == entity.generation;
    }

    /// Sets s et en ab le d.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn setEnabled(self: *World, entity: EntityId, value: bool) bool {
        if (!self.isAlive(entity)) return false;
        self.enabled.items[@intCast(entity.index)] = value;
        return true;
    }

    /// Returns whether i se na bl ed.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn isEnabled(self: *const World, entity: EntityId) bool {
        return self.isAlive(entity) and self.enabled.items[@intCast(entity.index)];
    }

    /// Returns slot count.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn slotCount(self: *const World) usize {
        return self.generations.items.len;
    }

    /// Returns live count.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn liveCount(self: *const World) usize {
        var count: usize = 0;
        for (self.alive.items) |alive| {
            if (alive) count += 1;
        }
        return count;
    }

    pub fn debugDump(self: *const World, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8){};
        errdefer buffer.deinit(allocator);
        const writer = buffer.writer(allocator);
        try writer.print("slots={d} live={d}\n", .{ self.slotCount(), self.liveCount() });
        for (self.generations.items, 0..) |generation, index| {
            try writer.print(
                "entity[{d}] generation={d} alive={any} enabled={any}\n",
                .{ index, generation, self.alive.items[index], self.enabled.items[index] },
            );
        }
        return buffer.toOwnedSlice(allocator);
    }

    /// Applies commands.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn applyCommands(self: *World, commands: *Commands) void {
        for (commands.pending.items) |command| {
            switch (command) {
                .destroy_entity => |entity| {
                    _ = self.destroyEntity(entity);
                },
                .set_enabled => |payload| {
                    _ = self.setEnabled(payload.entity, payload.enabled);
                },
                .jump_entity => {},
                .translate_entity => {},
                .set_local_rotation_deg => {},
                .set_local_scale => {},
                .set_camera_orientation => {},
                .adjust_camera_fov => {},
                .set_camera_mode => {},
                .toggle_scene_item_gizmo => {},
                .toggle_light_gizmo => {},
                .set_gizmo_axis => {},
                .cycle_light_selection => {},
                .nudge_active_gizmo => {},
                .toggle_render_overlay => {},
                .toggle_shadow_debug => {},
                .advance_shadow_debug => {},
            }
        }
        commands.clear();
    }
};
