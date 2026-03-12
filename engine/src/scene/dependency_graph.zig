//! Dependency Graph module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");
const World = @import("world.zig").World;

pub const EntityId = handles.EntityId;
pub const AssetHandle = handles.AssetHandle;

pub const DependencyKind = enum(u8) {
    asset,
    script,
    activation,
    logic,
    physics,
    render,
};

pub const DependencyTarget = union(enum) {
    entity: EntityId,
    asset: AssetHandle,
};

pub const DependencyEdge = struct {
    source: EntityId,
    target: DependencyTarget,
    kind: DependencyKind,
    hard: bool = true,
};

pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    edges: std.ArrayList(DependencyEdge) = .{},

    /// init initializes Dependency Graph state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by Dependency Graph.
    pub fn deinit(self: *DependencyGraph) void {
        self.edges.deinit(self.allocator);
    }

    /// Computes add edge.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn addEdge(self: *DependencyGraph, edge: DependencyEdge) !void {
        try self.edges.append(self.allocator, edge);
    }

    /// Processes collect direct dependencies.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn collectDirectDependencies(self: *const DependencyGraph, allocator: std.mem.Allocator, entity: EntityId) !std.ArrayList(DependencyEdge) {
        var matches: std.ArrayList(DependencyEdge) = .{};
        errdefer matches.deinit(allocator);
        for (self.edges.items) |edge| {
            if (!edge.source.eql(entity)) continue;
            try matches.append(allocator, edge);
        }
        return matches;
    }

    /// Processes collect dependents.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn collectDependents(self: *const DependencyGraph, allocator: std.mem.Allocator, entity: EntityId) !std.ArrayList(DependencyEdge) {
        var matches: std.ArrayList(DependencyEdge) = .{};
        errdefer matches.deinit(allocator);
        for (self.edges.items) |edge| {
            switch (edge.target) {
                .entity => |target_entity| {
                    if (!target_entity.eql(entity)) continue;
                    try matches.append(allocator, edge);
                },
                .asset => {},
            }
        }
        return matches;
    }

    /// Performs remove entity.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn removeEntity(self: *DependencyGraph, entity: EntityId) void {
        var write_index: usize = 0;
        for (self.edges.items) |edge| {
            const touches_source = edge.source.eql(entity);
            const touches_target = switch (edge.target) {
                .entity => |target_entity| target_entity.eql(entity),
                .asset => false,
            };
            if (touches_source or touches_target) continue;
            self.edges.items[write_index] = edge;
            write_index += 1;
        }
        self.edges.items.len = write_index;
    }

    /// Derives validate acyclic.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn validateAcyclic(self: *const DependencyGraph, world: *const World) !void {
        var topo = try self.topologicalOrder(self.allocator, world);
        defer topo.deinit(self.allocator);
        if (topo.items.len != world.liveCount()) return error.DependencyCycleDetected;
    }

    /// Converts data via topological order.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn topologicalOrder(self: *const DependencyGraph, allocator: std.mem.Allocator, world: *const World) !std.ArrayList(EntityId) {
        const slot_count = world.slotCount();
        var indegree = try allocator.alloc(u32, slot_count);
        defer allocator.free(indegree);
        @memset(indegree, 0);

        for (self.edges.items) |edge| {
            if (!world.isAlive(edge.source)) continue;
            switch (edge.target) {
                .entity => |target_entity| {
                    if (!world.isAlive(target_entity)) continue;
                    indegree[@intCast(edge.source.index)] += 1;
                },
                .asset => {},
            }
        }

        var queue: std.ArrayList(u32) = .{};
        defer queue.deinit(allocator);
        for (indegree, 0..) |degree, index| {
            const entity = EntityId.init(@intCast(index), if (index < world.generations.items.len) world.generations.items[index] else 0);
            if (degree == 0 and world.isAlive(entity)) {
                try queue.append(allocator, @intCast(index));
            }
        }

        var ordered: std.ArrayList(EntityId) = .{};
        errdefer ordered.deinit(allocator);

        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const node_index = queue.items[cursor];
            const node = EntityId.init(node_index, world.generations.items[@intCast(node_index)]);
            try ordered.append(allocator, node);
            for (self.edges.items) |edge| {
                switch (edge.target) {
                    .entity => |target_entity| {
                        if (!target_entity.eql(node)) continue;
                        const source_index: usize = @intCast(edge.source.index);
                        if (indegree[source_index] == 0) continue;
                        indegree[source_index] -= 1;
                        if (indegree[source_index] == 0 and world.isAlive(edge.source)) {
                            try queue.append(allocator, edge.source.index);
                        }
                    },
                    .asset => {},
                }
            }
        }

        return ordered;
    }

    pub fn debugDumpForEntity(self: *const DependencyGraph, allocator: std.mem.Allocator, entity: EntityId) ![]u8 {
        var buffer = std.ArrayList(u8){};
        errdefer buffer.deinit(allocator);
        const writer = buffer.writer(allocator);
        try writer.print("entity=({d},{d})\n", .{ entity.index, entity.generation });
        for (self.edges.items) |edge| {
            if (!edge.source.eql(entity)) continue;
            switch (edge.target) {
                .entity => |target_entity| {
                    try writer.print(
                        "out kind={s} hard={any} target_entity=({d},{d})\n",
                        .{ @tagName(edge.kind), edge.hard, target_entity.index, target_entity.generation },
                    );
                },
                .asset => |target_asset| {
                    try writer.print(
                        "out kind={s} hard={any} target_asset=({d},{d})\n",
                        .{ @tagName(edge.kind), edge.hard, target_asset.slot, target_asset.generation },
                    );
                },
            }
        }
        for (self.edges.items) |edge| {
            switch (edge.target) {
                .entity => |target_entity| {
                    if (!target_entity.eql(entity)) continue;
                    try writer.print(
                        "in kind={s} hard={any} source_entity=({d},{d})\n",
                        .{ @tagName(edge.kind), edge.hard, edge.source.index, edge.source.generation },
                    );
                },
                .asset => {},
            }
        }
        return buffer.toOwnedSlice(allocator);
    }
};
