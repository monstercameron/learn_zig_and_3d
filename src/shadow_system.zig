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
    normal_cone_axis: math.Vec3,
    normal_cone_cutoff: f32,
    triangle_offset: u32,
    triangle_count: u16,
    triangle_packet_offset: u32,
    triangle_packet_count: u16,
    micro_bvh_offset: u32,
};

pub const ShadowTriangle = struct {
    v0: math.Vec3,
    edge1: math.Vec3,
    edge2: math.Vec3,
    source_triangle_id: u32,
};

pub const ShadowTrianglePacket = struct {
    v0x: PacketFloat8,
    v0y: PacketFloat8,
    v0z: PacketFloat8,
    edge1_x: PacketFloat8,
    edge1_y: PacketFloat8,
    edge1_z: PacketFloat8,
    edge2_x: PacketFloat8,
    edge2_y: PacketFloat8,
    edge2_z: PacketFloat8,
    source_triangle_ids: [8]u32,
    active_mask: PacketBool8,
};

const PacketFloat8 = @Vector(8, f32);
const PacketBool8 = @Vector(8, bool);

// Represents a packet of rays for SIMD-style traversal within a screen tile
pub const RayPacket = struct {
    origins_x: [64]f32,
    origins_y: [64]f32,
    origins_z: [64]f32,
    dirs_x: [64]f32,
    dirs_y: [64]f32,
    dirs_z: [64]f32,
    shared_dir: math.Vec3,
    shared_inv_dir: math.Vec3,
    skip_triangle_ids: [64]u32,
    active_mask: u64,
    occluded_mask: u64,
};

pub const ShadowSystem = struct {
    allocator: std.mem.Allocator,
    tlas_nodes: std.ArrayList(TLASNode),
    blas_nodes: std.ArrayList(BLASNode),
    shadow_meshlets: std.ArrayList(ShadowMeshlet),
    shadow_triangles: std.ArrayList(ShadowTriangle),
    shadow_triangle_packets: std.ArrayList(ShadowTrianglePacket),

    pub fn init(allocator: std.mem.Allocator) ShadowSystem {
        return .{
            .allocator = allocator,
            .tlas_nodes = std.ArrayList(TLASNode){},
            .blas_nodes = std.ArrayList(BLASNode){},
            .shadow_meshlets = std.ArrayList(ShadowMeshlet){},
            .shadow_triangles = std.ArrayList(ShadowTriangle){},
            .shadow_triangle_packets = std.ArrayList(ShadowTrianglePacket){},
        };
    }

    pub fn deinit(self: *ShadowSystem) void {
        self.tlas_nodes.deinit(self.allocator);
        self.blas_nodes.deinit(self.allocator);
        self.shadow_meshlets.deinit(self.allocator);
        self.shadow_triangles.deinit(self.allocator);
        self.shadow_triangle_packets.deinit(self.allocator);
    }

    pub fn reset(self: *ShadowSystem) void {
        self.tlas_nodes.clearRetainingCapacity();
        self.blas_nodes.clearRetainingCapacity();
        self.shadow_meshlets.clearRetainingCapacity();
        self.shadow_triangles.clearRetainingCapacity();
        self.shadow_triangle_packets.clearRetainingCapacity();
    }

    fn initTrianglePacket() ShadowTrianglePacket {
        return .{
            .v0x = @splat(0.0),
            .v0y = @splat(0.0),
            .v0z = @splat(0.0),
            .edge1_x = @splat(0.0),
            .edge1_y = @splat(0.0),
            .edge1_z = @splat(0.0),
            .edge2_x = @splat(0.0),
            .edge2_y = @splat(0.0),
            .edge2_z = @splat(0.0),
            .source_triangle_ids = @splat(std.math.maxInt(u32)),
            .active_mask = @splat(false),
        };
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

    pub fn buildBLAS(self: *ShadowSystem, mesh_ptr: *const mesh.Mesh) !u32 {
        const meshlets = mesh_ptr.meshlets;
        if (meshlets.len == 0) return std.math.maxInt(u32);

        var entries = try self.allocator.alloc(BLASBuildEntry, meshlets.len);
        defer self.allocator.free(entries);

        const sm_start_index = @as(u32, @intCast(self.shadow_meshlets.items.len));
        for (meshlets, 0..) |m, i| {
            const aabb = AABB{ .min = m.aabb_min, .max = m.aabb_max };
            const triangle_offset = @as(u32, @intCast(self.shadow_triangles.items.len));
            const triangle_packet_offset = @as(u32, @intCast(self.shadow_triangle_packets.items.len));
            var triangle_count: u16 = 0;
            var triangle_packet_count: u16 = 0;
            var triangle_packet = initTrianglePacket();
            var triangle_packet_lane: usize = 0;
            const primitive_start = m.primitive_offset;
            const primitive_end = primitive_start + m.primitive_count;
            for (mesh_ptr.meshlet_primitives[primitive_start..primitive_end]) |primitive| {
                if (primitive.triangle_index >= mesh_ptr.triangles.len) continue;
                const tri = mesh_ptr.triangles[primitive.triangle_index];
                const p0 = mesh_ptr.vertices[tri.v0];
                const p1 = mesh_ptr.vertices[tri.v1];
                const p2 = mesh_ptr.vertices[tri.v2];
                const source_triangle_id = @as(u32, @intCast(@min(primitive.triangle_index, std.math.maxInt(u32))));
                try self.shadow_triangles.append(self.allocator, .{
                    .v0 = p0,
                    .edge1 = math.Vec3.sub(p1, p0),
                    .edge2 = math.Vec3.sub(p2, p0),
                    .source_triangle_id = source_triangle_id,
                });

                triangle_packet.v0x[triangle_packet_lane] = p0.x;
                triangle_packet.v0y[triangle_packet_lane] = p0.y;
                triangle_packet.v0z[triangle_packet_lane] = p0.z;
                triangle_packet.edge1_x[triangle_packet_lane] = p1.x - p0.x;
                triangle_packet.edge1_y[triangle_packet_lane] = p1.y - p0.y;
                triangle_packet.edge1_z[triangle_packet_lane] = p1.z - p0.z;
                triangle_packet.edge2_x[triangle_packet_lane] = p2.x - p0.x;
                triangle_packet.edge2_y[triangle_packet_lane] = p2.y - p0.y;
                triangle_packet.edge2_z[triangle_packet_lane] = p2.z - p0.z;
                triangle_packet.source_triangle_ids[triangle_packet_lane] = source_triangle_id;
                triangle_packet.active_mask[triangle_packet_lane] = true;
                triangle_packet_lane += 1;

                if (triangle_packet_lane == 8) {
                    try self.shadow_triangle_packets.append(self.allocator, triangle_packet);
                    triangle_packet_count += 1;
                    triangle_packet = initTrianglePacket();
                    triangle_packet_lane = 0;
                }
                triangle_count += 1;
            }
            if (triangle_packet_lane > 0) {
                try self.shadow_triangle_packets.append(self.allocator, triangle_packet);
                triangle_packet_count += 1;
            }
            entries[i] = .{
                .aabb = aabb,
                .centroid = aabb.centroid(),
                .meshlet_offset = sm_start_index + @as(u32, @intCast(i)),
            };
            try self.shadow_meshlets.append(self.allocator, .{
                .bound_sphere = .{ .center = m.bounds_center, .radius = m.bounds_radius },
                .bound_aabb = aabb,
                .normal_cone_axis = m.normal_cone_axis,
                .normal_cone_cutoff = m.normal_cone_cutoff,
                .triangle_offset = triangle_offset,
                .triangle_count = triangle_count,
                .triangle_packet_offset = triangle_packet_offset,
                .triangle_packet_count = triangle_packet_count,
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

    fn intersectTriangle(origin: math.Vec3, dir: math.Vec3, triangle: ShadowTriangle) bool {
        const epsilon: f32 = 1e-5;
        const pvec = math.Vec3.cross(dir, triangle.edge2);
        const det = math.Vec3.dot(triangle.edge1, pvec);

        if (@abs(det) < epsilon) return false;

        const inv_det = 1.0 / det;
        const tvec = math.Vec3.sub(origin, triangle.v0);
        const u = math.Vec3.dot(tvec, pvec) * inv_det;
        if (u < 0.0 or u > 1.0) return false;

        const qvec = math.Vec3.cross(tvec, triangle.edge1);
        const v = math.Vec3.dot(dir, qvec) * inv_det;
        if (v < 0.0 or u + v > 1.0) return false;

        const t = math.Vec3.dot(triangle.edge2, qvec) * inv_det;
        return t > epsilon;
    }

    fn intersectSphere(sphere: BoundingSphere, origin: math.Vec3, dir: math.Vec3) bool {
        const center_offset = math.Vec3.sub(sphere.center, origin);
        const t_ca = math.Vec3.dot(center_offset, dir);
        if (t_ca + sphere.radius < 0.0) return false;

        const distance_sq = math.Vec3.dot(center_offset, center_offset) - t_ca * t_ca;
        const radius_sq = sphere.radius * sphere.radius;
        return distance_sq <= radius_sq;
    }

    fn intersectTriangle8Any(
        orig_x: PacketFloat8,
        orig_y: PacketFloat8,
        orig_z: PacketFloat8,
        dir_x: PacketFloat8,
        dir_y: PacketFloat8,
        dir_z: PacketFloat8,
        v0x: PacketFloat8,
        v0y: PacketFloat8,
        v0z: PacketFloat8,
        edge1_x: PacketFloat8,
        edge1_y: PacketFloat8,
        edge1_z: PacketFloat8,
        edge2_x: PacketFloat8,
        edge2_y: PacketFloat8,
        edge2_z: PacketFloat8,
        active_mask: PacketBool8,
    ) bool {
        const eps: PacketFloat8 = @splat(1e-6);
        const zeros: PacketFloat8 = @splat(0.0);
        const ones: PacketFloat8 = @splat(1.0);

        const pvec_x = dir_y * edge2_z - dir_z * edge2_y;
        const pvec_y = dir_z * edge2_x - dir_x * edge2_z;
        const pvec_z = dir_x * edge2_y - dir_y * edge2_x;

        const det = edge1_x * pvec_x + edge1_y * pvec_y + edge1_z * pvec_z;
        const valid_det = @abs(det) >= eps;
        const inv_det = ones / det;

        const tvec_x = orig_x - v0x;
        const tvec_y = orig_y - v0y;
        const tvec_z = orig_z - v0z;

        const u = (tvec_x * pvec_x + tvec_y * pvec_y + tvec_z * pvec_z) * inv_det;
        const valid_u_min = u >= zeros;
        const valid_u_max = u <= ones;

        const qvec_x = tvec_y * edge1_z - tvec_z * edge1_y;
        const qvec_y = tvec_z * edge1_x - tvec_x * edge1_z;
        const qvec_z = tvec_x * edge1_y - tvec_y * edge1_x;

        const v = (dir_x * qvec_x + dir_y * qvec_y + dir_z * qvec_z) * inv_det;
        const valid_v_min = v >= zeros;
        const valid_v_max = (u + v) <= ones;

        const t = (edge2_x * qvec_x + edge2_y * qvec_y + edge2_z * qvec_z) * inv_det;
        const valid_t = t > eps;

        var hit = active_mask;
        hit = @select(bool, hit, valid_det, @as(PacketBool8, @splat(false)));
        hit = @select(bool, hit, valid_u_min, @as(PacketBool8, @splat(false)));
        hit = @select(bool, hit, valid_u_max, @as(PacketBool8, @splat(false)));
        hit = @select(bool, hit, valid_v_min, @as(PacketBool8, @splat(false)));
        hit = @select(bool, hit, valid_v_max, @as(PacketBool8, @splat(false)));
        hit = @select(bool, hit, valid_t, @as(PacketBool8, @splat(false)));

        return @reduce(.Or, hit);
    }

    fn meshletOccludesRay(self: *const ShadowSystem, meshlet_index: u32, origin: math.Vec3, inv_dir: math.Vec3, dir: math.Vec3, skip_triangle_id: u32) bool {
        const shadow_meshlet = self.shadow_meshlets.items[meshlet_index];
        if (shadow_meshlet.normal_cone_cutoff > -1.0) {
            const cone_sine = @sqrt(@max(0.0, 1.0 - shadow_meshlet.normal_cone_cutoff * shadow_meshlet.normal_cone_cutoff));
            if (math.Vec3.dot(shadow_meshlet.normal_cone_axis, dir) < -cone_sine) return false;
        }
        if (!intersectAABB(shadow_meshlet.bound_aabb, origin, inv_dir)) return false;
        if (!intersectSphere(shadow_meshlet.bound_sphere, origin, dir)) return false;

        const triangle_packet_start = @as(usize, @intCast(shadow_meshlet.triangle_packet_offset));
        const triangle_packet_end = triangle_packet_start + @as(usize, @intCast(shadow_meshlet.triangle_packet_count));
        if (triangle_packet_end > self.shadow_triangle_packets.items.len) return false;

        const origin_x: PacketFloat8 = @splat(origin.x);
        const origin_y: PacketFloat8 = @splat(origin.y);
        const origin_z: PacketFloat8 = @splat(origin.z);
        const dir_x: PacketFloat8 = @splat(dir.x);
        const dir_y: PacketFloat8 = @splat(dir.y);
        const dir_z: PacketFloat8 = @splat(dir.z);

        for (self.shadow_triangle_packets.items[triangle_packet_start..triangle_packet_end]) |triangle_packet| {
            var active_mask = triangle_packet.active_mask;
            if (skip_triangle_id != std.math.maxInt(u32)) {
                for (0..8) |lane| {
                    if (triangle_packet.source_triangle_ids[lane] == skip_triangle_id) {
                        active_mask[lane] = false;
                    }
                }
            }

            if (@reduce(.Or, active_mask) and intersectTriangle8Any(origin_x, origin_y, origin_z, dir_x, dir_y, dir_z, triangle_packet.v0x, triangle_packet.v0y, triangle_packet.v0z, triangle_packet.edge1_x, triangle_packet.edge1_y, triangle_packet.edge1_z, triangle_packet.edge2_x, triangle_packet.edge2_y, triangle_packet.edge2_z, active_mask)) {
                return true;
            }
        }

        return false;
    }

    pub fn tracePacketAnyHit(self: *ShadowSystem, packet: *RayPacket) void {
        const dir = packet.shared_dir;
        const inv_dir = packet.shared_inv_dir;
        var remaining_mask = packet.active_mask & ~packet.occluded_mask;

        while (remaining_mask != 0) {
            const ray_idx: usize = @ctz(remaining_mask);
            const ray_bit = @as(u64, 1) << @intCast(ray_idx);
            remaining_mask &= ~ray_bit;

            const origin = math.Vec3.new(packet.origins_x[ray_idx], packet.origins_y[ray_idx], packet.origins_z[ray_idx]);
            const skip_triangle_id = packet.skip_triangle_ids[ray_idx];

            // Traverse TLAS -> BLAS
            if (self.tlas_nodes.items.len > 0) {
                const root_tlas = &self.tlas_nodes.items[0];
                if (intersectAABB(root_tlas.aabb, origin, inv_dir)) {
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

                            if (intersectAABB(node.aabb, origin, inv_dir)) {
                                if (node.is_leaf) {
                                    if (self.meshletOccludesRay(node.left_child_or_meshlet, origin, inv_dir, dir, skip_triangle_id)) {
                                        packet.occluded_mask |= ray_bit;
                                        break;
                                    }
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
