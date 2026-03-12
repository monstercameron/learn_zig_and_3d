//! Graph module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");
const World = @import("world.zig").World;

pub const EntityId = handles.EntityId;

pub const HierarchyGraph = struct {
    allocator: std.mem.Allocator,
    parent: std.ArrayList(?EntityId) = .{},
    first_child: std.ArrayList(?EntityId) = .{},
    next_sibling: std.ArrayList(?EntityId) = .{},
    dirty: std.ArrayList(bool) = .{},

    /// init initializes Graph state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) HierarchyGraph {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by Graph.
    pub fn deinit(self: *HierarchyGraph) void {
        self.parent.deinit(self.allocator);
        self.first_child.deinit(self.allocator);
        self.next_sibling.deinit(self.allocator);
        self.dirty.deinit(self.allocator);
    }

    /// Ensures e ns ur ee nt it yc ap ac it y and grows backing storage/state when needed.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn ensureEntityCapacity(self: *HierarchyGraph, count: usize) !void {
        while (self.parent.items.len < count) try self.parent.append(self.allocator, null);
        while (self.first_child.items.len < count) try self.first_child.append(self.allocator, null);
        while (self.next_sibling.items.len < count) try self.next_sibling.append(self.allocator, null);
        while (self.dirty.items.len < count) try self.dirty.append(self.allocator, false);
    }

    /// Updates registry/attachment state for detach.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn detach(self: *HierarchyGraph, world: *const World, child: EntityId) void {
        if (!world.isAlive(child)) return;
        const child_index: usize = @intCast(child.index);
        const maybe_parent = self.parent.items[child_index];
        if (maybe_parent == null) return;
        const parent = maybe_parent.?;
        const parent_index: usize = @intCast(parent.index);

        var current = self.first_child.items[parent_index];
        var previous: ?EntityId = null;
        while (current) |node| {
            if (node.eql(child)) {
                if (previous) |prev| {
                    self.next_sibling.items[@intCast(prev.index)] = self.next_sibling.items[child_index];
                } else {
                    self.first_child.items[parent_index] = self.next_sibling.items[child_index];
                }
                break;
            }
            previous = node;
            current = self.next_sibling.items[@intCast(node.index)];
        }

        self.parent.items[child_index] = null;
        self.next_sibling.items[child_index] = null;
        self.markSubtreeDirty(child);
    }

    /// Updates registry/attachment state for attach child.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn attachChild(self: *HierarchyGraph, world: *const World, parent: EntityId, child: EntityId) !void {
        if (!world.isAlive(parent) or !world.isAlive(child)) return error.InvalidEntity;
        if (parent.eql(child)) return error.HierarchyCycleDetected;
        try self.ensureEntityCapacity(world.slotCount());
        try self.assertNoCycle(parent, child);
        self.detach(world, child);

        const parent_index: usize = @intCast(parent.index);
        const child_index: usize = @intCast(child.index);
        self.parent.items[child_index] = parent;
        self.next_sibling.items[child_index] = self.first_child.items[parent_index];
        self.first_child.items[parent_index] = child;
        self.markSubtreeDirty(child);
    }

    /// Clears c le ar en ti ty.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn clearEntity(self: *HierarchyGraph, world: *const World, entity: EntityId) void {
        if (@as(usize, @intCast(entity.index)) >= self.parent.items.len) return;

        self.detach(world, entity);
        var child = self.first_child.items[@intCast(entity.index)];
        while (child) |current| {
            const next = self.next_sibling.items[@intCast(current.index)];
            self.parent.items[@intCast(current.index)] = null;
            self.next_sibling.items[@intCast(current.index)] = null;
            self.markSubtreeDirty(current);
            child = next;
        }
        self.first_child.items[@intCast(entity.index)] = null;
        self.dirty.items[@intCast(entity.index)] = false;
    }

    /// Returns whether i sd ir ty.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn isDirty(self: *const HierarchyGraph, entity: EntityId) bool {
        const index: usize = @intCast(entity.index);
        return index < self.dirty.items.len and self.dirty.items[index];
    }

    /// Clears c le ar di rt y.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn clearDirty(self: *HierarchyGraph, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index < self.dirty.items.len) self.dirty.items[index] = false;
    }

    pub fn parentOf(self: *const HierarchyGraph, entity: EntityId) ?EntityId {
        const index: usize = @intCast(entity.index);
        if (index >= self.parent.items.len) return null;
        return self.parent.items[index];
    }

    pub fn firstChildOf(self: *const HierarchyGraph, entity: EntityId) ?EntityId {
        const index: usize = @intCast(entity.index);
        if (index >= self.first_child.items.len) return null;
        return self.first_child.items[index];
    }

    pub fn nextSiblingOf(self: *const HierarchyGraph, entity: EntityId) ?EntityId {
        const index: usize = @intCast(entity.index);
        if (index >= self.next_sibling.items.len) return null;
        return self.next_sibling.items[index];
    }

    /// Performs mark subtree dirty.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn markSubtreeDirty(self: *HierarchyGraph, entity: EntityId) void {
        const index: usize = @intCast(entity.index);
        if (index >= self.dirty.items.len) return;
        self.dirty.items[index] = true;
        var child = self.first_child.items[index];
        while (child) |current| {
            self.markSubtreeDirty(current);
            child = self.next_sibling.items[@intCast(current.index)];
        }
    }

    fn assertNoCycle(self: *const HierarchyGraph, new_parent: EntityId, child: EntityId) !void {
        var current: ?EntityId = new_parent;
        while (current) |node| {
            if (node.eql(child)) return error.HierarchyCycleDetected;
            const index: usize = @intCast(node.index);
            if (index >= self.parent.items.len) break;
            current = self.parent.items[index];
        }
    }
};
