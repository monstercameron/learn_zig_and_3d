//! World module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");

pub const EntityId = handles.EntityId;

pub const Command = union(enum) {
    destroy_entity: EntityId,
    set_enabled: struct {
        entity: EntityId,
        enabled: bool,
    },
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
            }
        }
        commands.clear();
    }
};
