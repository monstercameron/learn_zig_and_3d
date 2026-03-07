const std = @import("std");
const math = @import("math.zig");
const mesh = @import("mesh.zig");

pub const AABB = struct {
    min: math.Vec3,
    max: math.Vec3,

    pub fn init() AABB {
        return .{
            .min = math.Vec3.new(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32)),
            .max = math.Vec3.new(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32)),
        };
    }

    pub fn expandPattern(self: *AABB, p: math.Vec3) void {
        self.min = math.Vec3.min(self.min, p);
        self.max = math.Vec3.max(self.max, p);
    }

    pub fn expandAABB(self: *AABB, other: AABB) void {
        self.min = math.Vec3.min(self.min, other.min);
        self.max = math.Vec3.max(self.max, other.max);
    }

    pub fn centroid(self: AABB) math.Vec3 {
        return math.Vec3.scale(math.Vec3.add(self.min, self.max), 0.5);
    }
};

pub const BoundingSphere = struct {
    center: math.Vec3,
    radius: f32,
};

pub const TLASNode = struct {
    aabb: AABB,
    // If is_leaf is true, left_child holds the instance index.
    // Otherwise, left_child and right_child hold child node indices.
    left_child_or_instance: u32,
    right_child_or_count: u32,
    is_leaf: bool,
};

pub const BLASNode = struct {
    aabb: AABB,
    left_child_or_meshlet: u32,
    right_child_or_count: u32,
    is_leaf: bool,
};

pub const ShadowMeshlet = struct {
    bound_sphere: BoundingSphere,
    bound_aabb: AABB,
    triangle_offset: u32,
    triangle_count: u16,
    micro_bvh_offset: u32,
};

// Represents a packet of rays for SIMD-style traversal within a screen tile
pub const RayPacket = struct {
    origins_x: [64]f32,
    origins_y: [64]f32,
    origins_z: [64]f32,
    dirs_x: [64]f32,
    dirs_y: [64]f32,
    dirs_z: [64]f32,
    active_mask: u64,
    occluded_mask: u64,
};

pub const ShadowSystem = struct {
    allocator: std.mem.Allocator,
    tlas_nodes: std.ArrayList(TLASNode),
    blas_nodes: std.ArrayList(BLASNode),
    shadow_meshlets: std.ArrayList(ShadowMeshlet),

    pub fn init(allocator: std.mem.Allocator) ShadowSystem {
        return .{
            .allocator = allocator,
            .tlas_nodes = std.ArrayList(TLASNode){},
            .blas_nodes = std.ArrayList(BLASNode){},
            .shadow_meshlets = std.ArrayList(ShadowMeshlet){},
        };
    }

    pub fn deinit(self: *ShadowSystem) void {
        self.tlas_nodes.deinit(self.allocator);
        self.blas_nodes.deinit(self.allocator);
        self.shadow_meshlets.deinit(self.allocator);
    }

    const BLASBuildEntry = struct {
        aabb: AABB,
        centroid: math.Vec3,
        meshlet_offset: u32,
    };

    fn updateNodeBounds(nodes: []BLASNode, node_idx: u32) void {
        const node = &nodes[node_idx];
        if (node.is_leaf) return;
        const left = &nodes[node.left_child_or_meshlet];
        const right = &nodes[node.right_child_or_count];
        node.aabb = left.aabb;
        node.aabb.expandAABB(right.aabb);
    }

    pub fn buildBLAS(self: *ShadowSystem, meshlets: []const mesh.Meshlet) !u32 {
        if (meshlets.len == 0) return std.math.maxInt(u32);

        var entries = try self.allocator.alloc(BLASBuildEntry, meshlets.len);
        defer self.allocator.free(entries);

        const sm_start_index = @as(u32, @intCast(self.shadow_meshlets.items.len));
        for (meshlets, 0..) |m, i| {
            const aabb = AABB{ .min = m.aabb_min, .max = m.aabb_max };
            entries[i] = .{
                .aabb = aabb,
                .centroid = aabb.centroid(),
                .meshlet_offset = sm_start_index + @as(u32, @intCast(i)),
            };
            try self.shadow_meshlets.append(self.allocator, .{
                .bound_sphere = .{ .center = m.bounds_center, .radius = m.bounds_radius },
                .bound_aabb = aabb,
                .triangle_offset = @intCast(m.primitive_offset),
                .triangle_count = @intCast(m.primitive_count),
                .micro_bvh_offset = 0,
            });
        }

        const root_node_idx = try self.buildBLASRecursive(entries);
        return root_node_idx;
    }

    fn buildBLASRecursive(self: *ShadowSystem, entries: []BLASBuildEntry) !u32 {
        const node_idx = @as(u32, @intCast(self.blas_nodes.items.len));
        const node = BLASNode{
            .aabb = AABB.init(),
            .left_child_or_meshlet = 0,
            .right_child_or_count = 0,
            .is_leaf = false,
        };
        try self.blas_nodes.append(self.allocator, node); // Append empty, update later

        for (entries) |entry| {
            self.blas_nodes.items[node_idx].aabb.expandAABB(entry.aabb);
        }

        if (entries.len <= 1) {
            self.blas_nodes.items[node_idx].left_child_or_meshlet = entries[0].meshlet_offset;
            self.blas_nodes.items[node_idx].right_child_or_count = 1;
            self.blas_nodes.items[node_idx].is_leaf = true;
            return node_idx;
        }

        // Find largest axis manually since arrays and tuples can't easily be indexed in Zig Vec3 easily without inline loops
        var bounds = AABB.init();
        for (entries) |e| {
            bounds.expandPattern(e.centroid);
        }
        const extent = math.Vec3.sub(bounds.max, bounds.min);

        var axis: u3 = 0;
        if (extent.y > extent.x and extent.y > extent.z) axis = 1;
        if (extent.z > extent.x and extent.z > extent.y) axis = 2;

        const Context = struct {
            ax: u3,
            pub fn lessThan(ctx: @This(), a: BLASBuildEntry, b: BLASBuildEntry) bool {
                if (ctx.ax == 0) return a.centroid.x < b.centroid.x;
                if (ctx.ax == 1) return a.centroid.y < b.centroid.y;
                return a.centroid.z < b.centroid.z;
            }
        };

        std.sort.block(BLASBuildEntry, entries, Context{ .ax = axis }, Context.lessThan);

        const mid = entries.len / 2;

        const left_child = try self.buildBLASRecursive(entries[0..mid]);
        const right_child = try self.buildBLASRecursive(entries[mid..]);

        self.blas_nodes.items[node_idx].left_child_or_meshlet = left_child;
        self.blas_nodes.items[node_idx].right_child_or_count = right_child;
        self.blas_nodes.items[node_idx].is_leaf = false;

        return node_idx;
    }

    pub fn buildTLAS(self: *ShadowSystem, instances: []const math.Mat4) !void {
        self.tlas_nodes.clearRetainingCapacity();
        if (instances.len == 0 or self.blas_nodes.items.len == 0) return;

        // Simply build a flat top level for now, assuming 1 instance pointing to BLAS 0.
        // In a real system, you'd do an aabb transform of the BLAS root bounds for each instance.
        const root_blas = &self.blas_nodes.items[0];

        // Root TLAS node
        try self.tlas_nodes.append(self.allocator, .{
            .aabb = root_blas.aabb, // TODO: transform AABB by instance mat
            .left_child_or_instance = 0, // Instance 0
            .right_child_or_count = 1,
            .is_leaf = true,
        });
    }

    fn intersectAABB(aabb: AABB, origin: math.Vec3, inv_dir: math.Vec3) bool {
        const t1 = (aabb.min.x - origin.x) * inv_dir.x;
        const t2 = (aabb.max.x - origin.x) * inv_dir.x;
        const t3 = (aabb.min.y - origin.y) * inv_dir.y;
        const t4 = (aabb.max.y - origin.y) * inv_dir.y;
        const t5 = (aabb.min.z - origin.z) * inv_dir.z;
        const t6 = (aabb.max.z - origin.z) * inv_dir.z;

        const tmin = @max(@max(@min(t1, t2), @min(t3, t4)), @min(t5, t6));
        const tmax = @min(@min(@max(t1, t2), @max(t3, t4)), @max(t5, t6));

        return tmax >= tmin and tmax >= 0.0;
    }

    pub fn tracePacketAnyHit(self: *ShadowSystem, mesh_ptr: *const mesh.Mesh, packet: *RayPacket) void {
        _ = mesh_ptr; // TODO: true triangle intersection. Currently using meshlet box.

        var ray_idx: usize = 0;
        while (ray_idx < 64) : (ray_idx += 1) {
            const ray_bit = @as(u64, 1) << @intCast(ray_idx);
            if ((packet.active_mask & ray_bit) == 0) continue;
            if ((packet.occluded_mask & ray_bit) != 0) continue;

            const origin = math.Vec3.new(packet.origins_x[ray_idx], packet.origins_y[ray_idx], packet.origins_z[ray_idx]);
            const dir = math.Vec3.new(packet.dirs_x[ray_idx], packet.dirs_y[ray_idx], packet.dirs_z[ray_idx]);
            const origin_biased = math.Vec3.add(origin, math.Vec3.scale(dir, 0.05));
            const inv_dir = math.Vec3.new(if (@abs(dir.x) < 1e-6) (if (dir.x < 0) @as(f32, -1e6) else @as(f32, 1e6)) else 1.0 / dir.x, if (@abs(dir.y) < 1e-6) (if (dir.y < 0) @as(f32, -1e6) else @as(f32, 1e6)) else 1.0 / dir.y, if (@abs(dir.z) < 1e-6) (if (dir.z < 0) @as(f32, -1e6) else @as(f32, 1e6)) else 1.0 / dir.z);

            // Traverse TLAS -> BLAS
            if (self.tlas_nodes.items.len > 0) {
                const root_tlas = &self.tlas_nodes.items[0];
                if (intersectAABB(root_tlas.aabb, origin_biased, inv_dir)) {
                    // Start BLAS traversal from index 0
                    if (self.blas_nodes.items.len > 0) {
                        var stack: [64]u32 = undefined;
                        var stack_ptr: usize = 0;
                        stack[stack_ptr] = 0; // root BLAS node
                        stack_ptr += 1;

                        while (stack_ptr > 0) {
                            stack_ptr -= 1;
                            const node_idx = stack[stack_ptr];
                            const node = &self.blas_nodes.items[node_idx];

                            if (intersectAABB(node.aabb, origin_biased, inv_dir)) {
                                if (node.is_leaf) {
                                    // Hit a meshlet!
                                    // For now, treat any meshlet box hit as occluded for test performance
                                    packet.occluded_mask |= ray_bit;
                                    break;
                                } else {
                                    stack[stack_ptr] = node.left_child_or_meshlet;
                                    stack_ptr += 1;
                                    stack[stack_ptr] = node.right_child_or_count;
                                    stack_ptr += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};
