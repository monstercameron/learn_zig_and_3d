//! Residency Manager module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const math = @import("math.zig");
const handles = @import("entity.zig");
const octree = @import("octree.zig");

pub const EntityId = handles.EntityId;
pub const Aabb = octree.Aabb;
pub const Octree = octree.Octree;

pub const CellState = enum(u8) {
    cold,
    prefetch,
    requested,
    resident,
    evict_pending,
};

pub const CellResidency = struct {
    state: CellState = .cold,
    pin_count: u32 = 0,
    last_touched_frame: u64 = 0,
};

pub const ResidencyManager = struct {
    allocator: std.mem.Allocator,
    tree: Octree,
    cells: std.ArrayList(CellResidency) = .{},
    entity_pins: std.ArrayList(u32) = .{},

    /// init initializes Residency Manager state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator, bounds: Aabb, max_depth: u8) !ResidencyManager {
        var manager = ResidencyManager{
            .allocator = allocator,
            .tree = try Octree.init(allocator, bounds, max_depth),
        };
        try manager.syncCellCapacity();
        return manager;
    }

    /// deinit releases resources owned by Residency Manager.
    pub fn deinit(self: *ResidencyManager) void {
        self.tree.deinit();
        self.cells.deinit(self.allocator);
        self.entity_pins.deinit(self.allocator);
    }

    /// Ensures e ns ur ee nt it yc ap ac it y and grows backing storage/state when needed.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn ensureEntityCapacity(self: *ResidencyManager, count: usize) !void {
        try self.tree.ensureEntityCapacity(count);
        while (self.entity_pins.items.len < count) try self.entity_pins.append(self.allocator, 0);
        try self.syncCellCapacity();
    }

    /// Registers r eg is te rs ta ti ce nt it y with the owning system.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn registerStaticEntity(self: *ResidencyManager, entity: EntityId, position: math.Vec3) !u32 {
        const cell_id = try self.tree.insertEntity(entity, position);
        try self.syncCellCapacity();
        return cell_id;
    }

    /// Updates registry/attachment state for moving an entity between octree cells.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn updateEntityPosition(self: *ResidencyManager, entity: EntityId, position: math.Vec3) !u32 {
        const index: usize = @intCast(entity.index);
        try self.ensureEntityCapacity(index + 1);

        const old_cell_id = if (index < self.tree.entity_cells.items.len) self.tree.entity_cells.items[index] else null;
        const pin_count = if (index < self.entity_pins.items.len) self.entity_pins.items[index] else 0;
        const cell_id = try self.tree.insertEntity(entity, position);
        try self.syncCellCapacity();

        if (old_cell_id) |old_id| {
            if (old_id != cell_id and pin_count != 0) {
                const old_cell = &self.cells.items[@intCast(old_id)];
                old_cell.pin_count -|= pin_count;
            }
        }

        if (pin_count != 0) {
            const new_cell = &self.cells.items[@intCast(cell_id)];
            if (old_cell_id == null or old_cell_id.? != cell_id) new_cell.pin_count += pin_count;
            new_cell.state = .resident;
        }

        return cell_id;
    }

    /// Clears c le ar en ti ty.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn clearEntity(self: *ResidencyManager, entity: EntityId) void {
        self.tree.clearEntity(entity);
        const index: usize = @intCast(entity.index);
        if (index < self.entity_pins.items.len) self.entity_pins.items[index] = 0;
    }

    /// Updates registry/attachment state for pin entity.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn pinEntity(self: *ResidencyManager, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.entity_pins.items.len) return;
        self.entity_pins.items[index] += 1;
        if (self.tree.entity_cells.items[index]) |cell_id| {
            self.cells.items[@intCast(cell_id)].pin_count += 1;
            self.cells.items[@intCast(cell_id)].state = .resident;
        }
    }

    /// Updates registry/attachment state for unpin entity.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn unpinEntity(self: *ResidencyManager, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.entity_pins.items.len) return;
        if (self.entity_pins.items[index] != 0) self.entity_pins.items[index] -= 1;
        if (self.tree.entity_cells.items[index]) |cell_id| {
            if (self.cells.items[@intCast(cell_id)].pin_count != 0) self.cells.items[@intCast(cell_id)].pin_count -= 1;
        }
    }

    /// updateCamera updates Residency Manager state for the current tick/frame.
    pub fn updateCamera(self: *ResidencyManager, position: math.Vec3, active_radius: f32, prefetch_radius: f32, frame_index: u64) !void {
        var prefetch_cells = try self.tree.collectIntersectingSphere(self.allocator, position, prefetch_radius);
        defer prefetch_cells.deinit(self.allocator);
        var active_cells = try self.tree.collectIntersectingSphere(self.allocator, position, active_radius);
        defer active_cells.deinit(self.allocator);

        for (self.cells.items) |*cell| {
            if (cell.pin_count == 0 and cell.state == .resident) cell.state = .evict_pending;
            if (cell.pin_count == 0 and cell.state == .prefetch) cell.state = .cold;
        }

        for (prefetch_cells.items) |cell_id| {
            const cell = &self.cells.items[@intCast(cell_id)];
            if (cell.state == .cold) cell.state = .prefetch;
            cell.last_touched_frame = frame_index;
        }

        for (active_cells.items) |cell_id| {
            const cell = &self.cells.items[@intCast(cell_id)];
            cell.state = .resident;
            cell.last_touched_frame = frame_index;
        }
    }

    fn syncCellCapacity(self: *ResidencyManager) !void {
        while (self.cells.items.len < self.tree.cells.items.len) {
            try self.cells.append(self.allocator, .{});
        }
    }
};
