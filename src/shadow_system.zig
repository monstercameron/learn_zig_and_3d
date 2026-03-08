const std = @import("std");
const cpu_features = @import("cpu_features.zig");
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
const max_trace_packet_lanes = 16;

const TraversalStackEntry = struct {
    node_idx: u32,
    ray_mask: u64,
};

fn runtimeTracePacketLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 16,
        .avx2 => 8,
        else => 1,
    };
}

fn chunkBitMask(start: usize, count: usize) u64 {
    if (count == 0) return 0;
    if (count >= 64) return std.math.maxInt(u64);
    return ((@as(u64, 1) << @intCast(count)) - 1) << @intCast(start);
}

fn loadFloatChunk(comptime lanes: usize, source: *const [64]f32, start: usize) @Vector(lanes, f32) {
    var arr: [lanes]f32 = undefined;
    inline for (0..lanes) |lane| {
        arr[lane] = source[start + lane];
    }
    return @bitCast(arr);
}

fn intersectAABBPacketChunkMask(comptime lanes: usize, aabb: AABB, packet: *const RayPacket, start: usize, active_mask: u64, inv_dir: math.Vec3) u64 {
    const FloatVec = @Vector(lanes, f32);
    const zeros: FloatVec = @splat(0.0);

    const origin_x = loadFloatChunk(lanes, &packet.origins_x, start);
    const origin_y = loadFloatChunk(lanes, &packet.origins_y, start);
    const origin_z = loadFloatChunk(lanes, &packet.origins_z, start);
    const inv_x: FloatVec = @splat(inv_dir.x);
    const inv_y: FloatVec = @splat(inv_dir.y);
    const inv_z: FloatVec = @splat(inv_dir.z);

    const min_x: FloatVec = @splat(aabb.min.x);
    const min_y: FloatVec = @splat(aabb.min.y);
    const min_z: FloatVec = @splat(aabb.min.z);
    const max_x: FloatVec = @splat(aabb.max.x);
    const max_y: FloatVec = @splat(aabb.max.y);
    const max_z: FloatVec = @splat(aabb.max.z);

    const t1 = (min_x - origin_x) * inv_x;
    const t2 = (max_x - origin_x) * inv_x;
    const t3 = (min_y - origin_y) * inv_y;
    const t4 = (max_y - origin_y) * inv_y;
    const t5 = (min_z - origin_z) * inv_z;
    const t6 = (max_z - origin_z) * inv_z;

    const tmin = @max(@max(@min(t1, t2), @min(t3, t4)), @min(t5, t6));
    const tmax = @min(@min(@max(t1, t2), @max(t3, t4)), @max(t5, t6));
    const hits = (tmax >= tmin) & (tmax >= zeros);

    var result_mask: u64 = 0;
    inline for (0..lanes) |lane| {
        const bit_index = start + lane;
        const bit = @as(u64, 1) << @intCast(bit_index);
        if ((active_mask & bit) != 0 and hits[lane]) {
            result_mask |= bit;
        }
    }
    return result_mask;
}

fn intersectSpherePacketChunkMask(comptime lanes: usize, sphere: BoundingSphere, packet: *const RayPacket, start: usize, active_mask: u64) u64 {
    const FloatVec = @Vector(lanes, f32);
    const zeros: FloatVec = @splat(0.0);
    const radius: FloatVec = @splat(sphere.radius);
    const radius_sq = radius * radius;

    const origin_x = loadFloatChunk(lanes, &packet.origins_x, start);
    const origin_y = loadFloatChunk(lanes, &packet.origins_y, start);
    const origin_z = loadFloatChunk(lanes, &packet.origins_z, start);
    const dir_x = loadFloatChunk(lanes, &packet.dirs_x, start);
    const dir_y = loadFloatChunk(lanes, &packet.dirs_y, start);
    const dir_z = loadFloatChunk(lanes, &packet.dirs_z, start);

    const center_x: FloatVec = @splat(sphere.center.x);
    const center_y: FloatVec = @splat(sphere.center.y);
    const center_z: FloatVec = @splat(sphere.center.z);

    const off_x = center_x - origin_x;
    const off_y = center_y - origin_y;
    const off_z = center_z - origin_z;
    const t_ca = off_x * dir_x + off_y * dir_y + off_z * dir_z;
    const distance_sq = (off_x * off_x + off_y * off_y + off_z * off_z) - (t_ca * t_ca);
    const hits = ((t_ca + radius) >= zeros) & (distance_sq <= radius_sq);

    var result_mask: u64 = 0;
    inline for (0..lanes) |lane| {
        const bit_index = start + lane;
        const bit = @as(u64, 1) << @intCast(bit_index);
        if ((active_mask & bit) != 0 and hits[lane]) {
            result_mask |= bit;
        }
    }
    return result_mask;
}

fn intersectTrianglePacketChunkMask(comptime lanes: usize, packet: *const RayPacket, start: usize, active_mask: u64, triangle_packet: ShadowTrianglePacket, triangle_lane: usize) u64 {
    const FloatVec = @Vector(lanes, f32);
    const eps: FloatVec = @splat(1e-6);
    const zeros: FloatVec = @splat(0.0);
    const ones: FloatVec = @splat(1.0);

    const origin_x = loadFloatChunk(lanes, &packet.origins_x, start);
    const origin_y = loadFloatChunk(lanes, &packet.origins_y, start);
    const origin_z = loadFloatChunk(lanes, &packet.origins_z, start);
    const dir_x = loadFloatChunk(lanes, &packet.dirs_x, start);
    const dir_y = loadFloatChunk(lanes, &packet.dirs_y, start);
    const dir_z = loadFloatChunk(lanes, &packet.dirs_z, start);

    const v0x: FloatVec = @splat(triangle_packet.v0x[triangle_lane]);
    const v0y: FloatVec = @splat(triangle_packet.v0y[triangle_lane]);
    const v0z: FloatVec = @splat(triangle_packet.v0z[triangle_lane]);
    const edge1_x: FloatVec = @splat(triangle_packet.edge1_x[triangle_lane]);
    const edge1_y: FloatVec = @splat(triangle_packet.edge1_y[triangle_lane]);
    const edge1_z: FloatVec = @splat(triangle_packet.edge1_z[triangle_lane]);
    const edge2_x: FloatVec = @splat(triangle_packet.edge2_x[triangle_lane]);
    const edge2_y: FloatVec = @splat(triangle_packet.edge2_y[triangle_lane]);
    const edge2_z: FloatVec = @splat(triangle_packet.edge2_z[triangle_lane]);

    const pvec_x = dir_y * edge2_z - dir_z * edge2_y;
    const pvec_y = dir_z * edge2_x - dir_x * edge2_z;
    const pvec_z = dir_x * edge2_y - dir_y * edge2_x;
    const det = edge1_x * pvec_x + edge1_y * pvec_y + edge1_z * pvec_z;
    const valid_det = @abs(det) >= eps;
    const inv_det = ones / det;

    const tvec_x = origin_x - v0x;
    const tvec_y = origin_y - v0y;
    const tvec_z = origin_z - v0z;
    const u = (tvec_x * pvec_x + tvec_y * pvec_y + tvec_z * pvec_z) * inv_det;
    const valid_u = (u >= zeros) & (u <= ones);

    const qvec_x = tvec_y * edge1_z - tvec_z * edge1_y;
    const qvec_y = tvec_z * edge1_x - tvec_x * edge1_z;
    const qvec_z = tvec_x * edge1_y - tvec_y * edge1_x;
    const v = (dir_x * qvec_x + dir_y * qvec_y + dir_z * qvec_z) * inv_det;
    const valid_v = (v >= zeros) & ((u + v) <= ones);
    const t = (edge2_x * qvec_x + edge2_y * qvec_y + edge2_z * qvec_z) * inv_det;
    const valid_t = t > eps;
    const tri_id = triangle_packet.source_triangle_ids[triangle_lane];

    var result_mask: u64 = 0;
    inline for (0..lanes) |lane| {
        const bit_index = start + lane;
        const bit = @as(u64, 1) << @intCast(bit_index);
        if ((active_mask & bit) != 0 and packet.skip_triangle_ids[bit_index] != tri_id and valid_det[lane] and valid_u[lane] and valid_v[lane] and valid_t[lane]) {
            result_mask |= bit;
        }
    }
    return result_mask;
}

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

    fn meshletOccludesPacketMask(self: *const ShadowSystem, meshlet_index: u32, packet: *const RayPacket, ray_mask: u64) u64 {
        if (ray_mask == 0) return 0;

        const shadow_meshlet = self.shadow_meshlets.items[meshlet_index];
        if (shadow_meshlet.normal_cone_cutoff > -1.0) {
            const cone_sine = @sqrt(@max(0.0, 1.0 - shadow_meshlet.normal_cone_cutoff * shadow_meshlet.normal_cone_cutoff));
            if (math.Vec3.dot(shadow_meshlet.normal_cone_axis, packet.shared_dir) < -cone_sine) return 0;
        }

        const lane_width = runtimeTracePacketLanes();
        var candidate_mask: u64 = 0;
        var chunk_start: usize = 0;
        while (chunk_start < 64) : (chunk_start += lane_width) {
            const chunk_mask = ray_mask & chunkBitMask(chunk_start, lane_width);
            if (chunk_mask == 0) continue;

            const aabb_mask = switch (lane_width) {
                16 => intersectAABBPacketChunkMask(16, shadow_meshlet.bound_aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                8 => intersectAABBPacketChunkMask(8, shadow_meshlet.bound_aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                else => if (intersectAABB(shadow_meshlet.bound_aabb, math.Vec3.new(packet.origins_x[chunk_start], packet.origins_y[chunk_start], packet.origins_z[chunk_start]), packet.shared_inv_dir)) chunk_mask else 0,
            };
            if (aabb_mask == 0) continue;

            const sphere_mask = switch (lane_width) {
                16 => intersectSpherePacketChunkMask(16, shadow_meshlet.bound_sphere, packet, chunk_start, aabb_mask),
                8 => intersectSpherePacketChunkMask(8, shadow_meshlet.bound_sphere, packet, chunk_start, aabb_mask),
                else => if (intersectSphere(shadow_meshlet.bound_sphere, math.Vec3.new(packet.origins_x[chunk_start], packet.origins_y[chunk_start], packet.origins_z[chunk_start]), math.Vec3.new(packet.dirs_x[chunk_start], packet.dirs_y[chunk_start], packet.dirs_z[chunk_start]))) aabb_mask else 0,
            };
            candidate_mask |= sphere_mask;
        }
        if (candidate_mask == 0) return 0;

        const triangle_packet_start = @as(usize, @intCast(shadow_meshlet.triangle_packet_offset));
        const triangle_packet_end = triangle_packet_start + @as(usize, @intCast(shadow_meshlet.triangle_packet_count));
        if (triangle_packet_end > self.shadow_triangle_packets.items.len) return 0;

        var occluded_mask: u64 = 0;
        for (self.shadow_triangle_packets.items[triangle_packet_start..triangle_packet_end]) |triangle_packet| {
            var triangle_lane: usize = 0;
            while (triangle_lane < 8) : (triangle_lane += 1) {
                if (!triangle_packet.active_mask[triangle_lane]) continue;

                const pending_mask = candidate_mask & ~occluded_mask;
                if (pending_mask == 0) return occluded_mask;

                chunk_start = 0;
                while (chunk_start < 64) : (chunk_start += lane_width) {
                    const chunk_mask = pending_mask & chunkBitMask(chunk_start, lane_width);
                    if (chunk_mask == 0) continue;

                    const hit_mask = switch (lane_width) {
                        16 => intersectTrianglePacketChunkMask(16, packet, chunk_start, chunk_mask, triangle_packet, triangle_lane),
                        8 => intersectTrianglePacketChunkMask(8, packet, chunk_start, chunk_mask, triangle_packet, triangle_lane),
                        else => blk: {
                            const ray_origin = math.Vec3.new(packet.origins_x[chunk_start], packet.origins_y[chunk_start], packet.origins_z[chunk_start]);
                            const ray_dir = math.Vec3.new(packet.dirs_x[chunk_start], packet.dirs_y[chunk_start], packet.dirs_z[chunk_start]);
                            const tri = ShadowTriangle{
                                .v0 = math.Vec3.new(triangle_packet.v0x[triangle_lane], triangle_packet.v0y[triangle_lane], triangle_packet.v0z[triangle_lane]),
                                .edge1 = math.Vec3.new(triangle_packet.edge1_x[triangle_lane], triangle_packet.edge1_y[triangle_lane], triangle_packet.edge1_z[triangle_lane]),
                                .edge2 = math.Vec3.new(triangle_packet.edge2_x[triangle_lane], triangle_packet.edge2_y[triangle_lane], triangle_packet.edge2_z[triangle_lane]),
                                .source_triangle_id = triangle_packet.source_triangle_ids[triangle_lane],
                            };
                            if (packet.skip_triangle_ids[chunk_start] != tri.source_triangle_id and intersectTriangle(ray_origin, ray_dir, tri)) {
                                break :blk chunk_mask;
                            }
                            break :blk 0;
                        },
                    };
                    occluded_mask |= hit_mask;
                }
            }
        }

        return occluded_mask;
    }

    pub fn tracePacketAnyHit(self: *ShadowSystem, packet: *RayPacket) void {
        const remaining_mask = packet.active_mask & ~packet.occluded_mask;
        if (remaining_mask == 0) return;
        if (self.tlas_nodes.items.len == 0 or self.blas_nodes.items.len == 0) return;

        const root_tlas = &self.tlas_nodes.items[0];
        var root_mask: u64 = 0;
        const lane_width = runtimeTracePacketLanes();
        var chunk_start: usize = 0;
        while (chunk_start < 64) : (chunk_start += lane_width) {
            const chunk_mask = remaining_mask & chunkBitMask(chunk_start, lane_width);
            if (chunk_mask == 0) continue;
            root_mask |= switch (lane_width) {
                16 => intersectAABBPacketChunkMask(16, root_tlas.aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                8 => intersectAABBPacketChunkMask(8, root_tlas.aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                else => if (intersectAABB(root_tlas.aabb, math.Vec3.new(packet.origins_x[chunk_start], packet.origins_y[chunk_start], packet.origins_z[chunk_start]), packet.shared_inv_dir)) chunk_mask else 0,
            };
        }
        if (root_mask == 0) return;

        var stack: [128]TraversalStackEntry = undefined;
        var stack_ptr: usize = 0;
        stack[stack_ptr] = .{ .node_idx = 0, .ray_mask = root_mask };
        stack_ptr += 1;

        while (stack_ptr > 0) {
            stack_ptr -= 1;
            const entry = stack[stack_ptr];
            const active_rays = entry.ray_mask & ~packet.occluded_mask;
            if (active_rays == 0) continue;

            const node = &self.blas_nodes.items[entry.node_idx];
            if (node.is_leaf) {
                packet.occluded_mask |= self.meshletOccludesPacketMask(node.left_child_or_meshlet, packet, active_rays);
                continue;
            }

            const left = &self.blas_nodes.items[node.left_child_or_meshlet];
            const right = &self.blas_nodes.items[node.right_child_or_count];
            var left_mask: u64 = 0;
            var right_mask: u64 = 0;
            chunk_start = 0;
            while (chunk_start < 64) : (chunk_start += lane_width) {
                const chunk_mask = active_rays & chunkBitMask(chunk_start, lane_width);
                if (chunk_mask == 0) continue;
                left_mask |= switch (lane_width) {
                    16 => intersectAABBPacketChunkMask(16, left.aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                    8 => intersectAABBPacketChunkMask(8, left.aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                    else => if (intersectAABB(left.aabb, math.Vec3.new(packet.origins_x[chunk_start], packet.origins_y[chunk_start], packet.origins_z[chunk_start]), packet.shared_inv_dir)) chunk_mask else 0,
                };
                right_mask |= switch (lane_width) {
                    16 => intersectAABBPacketChunkMask(16, right.aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                    8 => intersectAABBPacketChunkMask(8, right.aabb, packet, chunk_start, chunk_mask, packet.shared_inv_dir),
                    else => if (intersectAABB(right.aabb, math.Vec3.new(packet.origins_x[chunk_start], packet.origins_y[chunk_start], packet.origins_z[chunk_start]), packet.shared_inv_dir)) chunk_mask else 0,
                };
            }

            if (left_mask != 0) {
                stack[stack_ptr] = .{ .node_idx = node.left_child_or_meshlet, .ray_mask = left_mask };
                stack_ptr += 1;
            }
            if (right_mask != 0) {
                stack[stack_ptr] = .{ .node_idx = node.right_child_or_count, .ray_mask = right_mask };
                stack_ptr += 1;
            }
        }
    }
};
