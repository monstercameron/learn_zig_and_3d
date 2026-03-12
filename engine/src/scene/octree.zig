//! Octree module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const math = @import("math.zig");
const handles = @import("entity.zig");

pub const EntityId = handles.EntityId;

pub const Aabb = struct {
    min: math.Vec3,
    max: math.Vec3,

    /// Performs center.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn center(self: Aabb) math.Vec3 {
        return math.Vec3.scale(math.Vec3.add(self.min, self.max), 0.5);
    }

    /// Returns whether contains point.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn containsPoint(self: Aabb, point: math.Vec3) bool {
        return point.x >= self.min.x and point.x <= self.max.x and
            point.y >= self.min.y and point.y <= self.max.y and
            point.z >= self.min.z and point.z <= self.max.z;
    }

    /// Computes intersection data for s sphere.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn intersectsSphere(self: Aabb, center_point: math.Vec3, radius: f32) bool {
        const clamped_x = std.math.clamp(center_point.x, self.min.x, self.max.x);
        const clamped_y = std.math.clamp(center_point.y, self.min.y, self.max.y);
        const clamped_z = std.math.clamp(center_point.z, self.min.z, self.max.z);
        const delta = math.Vec3.sub(center_point, math.Vec3.new(clamped_x, clamped_y, clamped_z));
        return math.Vec3.dot(delta, delta) <= radius * radius;
    }
};

pub const Cell = struct {
    bounds: Aabb,
    depth: u8,
    parent: ?u32,
    children: [8]?u32 = [_]?u32{null} ** 8,
    entities: std.ArrayList(EntityId) = .{},
};

pub const Octree = struct {
    allocator: std.mem.Allocator,
    root_bounds: Aabb,
    max_depth: u8,
    cells: std.ArrayList(Cell) = .{},
    entity_cells: std.ArrayList(?u32) = .{},

    /// init initializes Octree state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator, root_bounds: Aabb, max_depth: u8) !Octree {
        var tree = Octree{
            .allocator = allocator,
            .root_bounds = root_bounds,
            .max_depth = max_depth,
        };
        try tree.cells.append(allocator, .{
            .bounds = root_bounds,
            .depth = 0,
            .parent = null,
        });
        return tree;
    }

    /// deinit releases resources owned by Octree.
    pub fn deinit(self: *Octree) void {
        for (self.cells.items) |*cell| {
            cell.entities.deinit(self.allocator);
        }
        self.cells.deinit(self.allocator);
        self.entity_cells.deinit(self.allocator);
    }

    /// Ensures e ns ur ee nt it yc ap ac it y and grows backing storage/state when needed.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn ensureEntityCapacity(self: *Octree, count: usize) !void {
        while (self.entity_cells.items.len < count) try self.entity_cells.append(self.allocator, null);
    }

    /// Performs insert entity.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn insertEntity(self: *Octree, entity: EntityId, position: math.Vec3) !u32 {
        try self.ensureEntityCapacity(@as(usize, @intCast(entity.index)) + 1);
        if (self.entity_cells.items[@intCast(entity.index)]) |current_cell| {
            self.removeEntityFromCell(current_cell, entity);
        }

        var cell_id: u32 = 0;
        var depth: u8 = 0;
        while (depth < self.max_depth) : (depth += 1) {
            const next_index = childIndexForPoint(self.cells.items[@intCast(cell_id)].bounds, position);
            const next_cell = try self.ensureChild(cell_id, next_index);
            cell_id = next_cell;
        }

        try self.cells.items[@intCast(cell_id)].entities.append(self.allocator, entity);
        self.entity_cells.items[@intCast(entity.index)] = cell_id;
        return cell_id;
    }

    /// Clears c le ar en ti ty.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn clearEntity(self: *Octree, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.entity_cells.items.len) return;
        if (self.entity_cells.items[index]) |cell_id| {
            self.removeEntityFromCell(cell_id, entity);
            self.entity_cells.items[index] = null;
        }
    }

    /// Processes collect intersecting sphere.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn collectIntersectingSphere(self: *const Octree, allocator: std.mem.Allocator, center_point: math.Vec3, radius: f32) !std.ArrayList(u32) {
        var result: std.ArrayList(u32) = .{};
        try self.collectIntersectingSphereInto(allocator, 0, center_point, radius, &result);
        return result;
    }

    fn collectIntersectingSphereInto(self: *const Octree, allocator: std.mem.Allocator, cell_id: u32, center_point: math.Vec3, radius: f32, result: *std.ArrayList(u32)) !void {
        const cell = self.cells.items[@intCast(cell_id)];
        if (!cell.bounds.intersectsSphere(center_point, radius)) return;
        try result.append(allocator, cell_id);
        for (cell.children) |child| {
            if (child) |next_cell| try self.collectIntersectingSphereInto(allocator, next_cell, center_point, radius, result);
        }
    }

    fn ensureChild(self: *Octree, parent_id: u32, child_index: usize) !u32 {
        if (self.cells.items[@intCast(parent_id)].children[child_index]) |existing| return existing;

        const child_id: u32 = @intCast(self.cells.items.len);
        const child_bounds = childBounds(self.cells.items[@intCast(parent_id)].bounds, child_index);
        try self.cells.append(self.allocator, .{
            .bounds = child_bounds,
            .depth = self.cells.items[@intCast(parent_id)].depth + 1,
            .parent = parent_id,
        });
        self.cells.items[@intCast(parent_id)].children[child_index] = child_id;
        return child_id;
    }

    fn removeEntityFromCell(self: *Octree, cell_id: u32, entity: EntityId) void {
        var write_index: usize = 0;
        const entities = &self.cells.items[@intCast(cell_id)].entities;
        for (entities.items) |candidate| {
            if (candidate.eql(entity)) continue;
            entities.items[write_index] = candidate;
            write_index += 1;
        }
        entities.items.len = write_index;
    }
};

fn childIndexForPoint(bounds: Aabb, point: math.Vec3) usize {
    const center_point = bounds.center();
    var index: usize = 0;
    if (point.x >= center_point.x) index |= 1;
    if (point.y >= center_point.y) index |= 2;
    if (point.z >= center_point.z) index |= 4;
    return index;
}

fn childBounds(bounds: Aabb, child_index: usize) Aabb {
    const center_point = bounds.center();
    return .{
        .min = math.Vec3.new(
            if ((child_index & 1) == 0) bounds.min.x else center_point.x,
            if ((child_index & 2) == 0) bounds.min.y else center_point.y,
            if ((child_index & 4) == 0) bounds.min.z else center_point.z,
        ),
        .max = math.Vec3.new(
            if ((child_index & 1) == 0) center_point.x else bounds.max.x,
            if ((child_index & 2) == 0) center_point.y else bounds.max.y,
            if ((child_index & 4) == 0) center_point.z else bounds.max.z,
        ),
    };
}
