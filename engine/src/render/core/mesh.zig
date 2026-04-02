//! # 3D Mesh Data Structure
//!
//! This module defines the data structures for representing a 3D model (a "mesh").
//! A mesh is essentially a collection of 3D points (vertices) and instructions on how
//! to connect those points to form faces (triangles).
//!
//! ## JavaScript Analogy
//!
//! This is very similar to a `THREE.BufferGeometry` object in three.js. A BufferGeometry
//! stores all its data in flat arrays (buffers).
//!
//! ```javascript
//! const geometry = new THREE.BufferGeometry();
//!
//! // 1. Vertex positions (x, y, z, x, y, z, ...)
//! const vertices = new Float32Array([ ... ]);
//! geometry.setAttribute('position', new THREE.BufferAttribute(vertices, 3));
//!
//! // 2. Triangle indices (which vertices make up each face)
//! const indices = [ 0, 1, 2,  0, 2, 3, ... ];
//! geometry.setIndex(indices);
//!
//! // 3. Normals (for lighting)
//! geometry.computeVertexNormals();
//! ```
//! Our `Mesh` struct holds the same kinds of data: `vertices`, `triangles` (indices), and `normals`.

const std = @import("std");
const math = @import("../../core/math.zig");
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

/// A compact cluster of triangles processed together in the mesh-shader pipeline.
/// Stores offsets into the packed meshlet vertex/primitive buffers along with a
/// bounding sphere for quick culling tests.
pub const MeshletPrimitive = struct {
    triangle_index: usize,
    local_v0: u16,
    local_v1: u16,
    local_v2: u16,
};

pub const Meshlet = struct {
    vertex_offset: usize,
    vertex_count: usize,
    primitive_offset: usize,
    primitive_count: usize,
    bounds_center: Vec3,
    bounds_radius: f32,
    normal_cone_axis: Vec3,
    normal_cone_cutoff: f32,
    aabb_min: Vec3,
    aabb_max: Vec3,
};

// ========== MESH STRUCTURE ==========

/// Flags to control whether a triangle's filled face or wireframe outline is rendered.
pub const TriangleCullFlags = struct {
    cull_fill: bool = false,
    cull_wireframe: bool = false,
};

/// Represents a single triangle face.
/// Importantly, this does not store the vertex positions themselves, but rather the *indices*
/// into the mesh's main `vertices` array. This is a crucial optimization to avoid duplicating
/// vertex data that is shared between multiple triangles.
pub const Triangle = struct {
    v0: usize, // Index of the first vertex.
    v1: usize, // Index of the second vertex.
    v2: usize, // Index of the third vertex.
    cull_flags: TriangleCullFlags = .{}, // Flags for rendering.
    base_color: u32 = default_color,
    texture_index: u16 = no_texture_index,

    pub const default_color: u32 = 0xFF7F7F7F;
    pub const no_texture_index: u16 = std.math.maxInt(u16);

    /// Constructs and returns a new value initialized from the provided fields.
    /// Keeps new as the single implementation point so call-site behavior stays consistent.
    pub fn new(v0: usize, v1: usize, v2: usize) Triangle {
        return Triangle{
            .v0 = v0,
            .v1 = v1,
            .v2 = v2,
            .cull_flags = .{},
            .base_color = default_color,
            .texture_index = no_texture_index,
        };
    }

    /// Constructs and returns new with culling.
    /// Keeps new with culling as the single implementation point so call-site behavior stays consistent.
    pub fn newWithCulling(v0: usize, v1: usize, v2: usize, cull_fill: bool, cull_wireframe: bool) Triangle {
        return Triangle{
            .v0 = v0,
            .v1 = v1,
            .v2 = v2,
            .cull_flags = .{ .cull_fill = cull_fill, .cull_wireframe = cull_wireframe },
            .base_color = default_color,
            .texture_index = no_texture_index,
        };
    }

    /// Constructs and returns new with color.
    /// Keeps new with color as the single implementation point so call-site behavior stays consistent.
    pub fn newWithColor(v0: usize, v1: usize, v2: usize, color: u32) Triangle {
        return Triangle{
            .v0 = v0,
            .v1 = v1,
            .v2 = v2,
            .cull_flags = .{},
            .base_color = color,
            .texture_index = no_texture_index,
        };
    }

    /// Constructs and returns new with culling and color.
    /// Keeps new with culling and color as the single implementation point so call-site behavior stays consistent.
    pub fn newWithCullingAndColor(v0: usize, v1: usize, v2: usize, cull_fill: bool, cull_wireframe: bool, color: u32) Triangle {
        return Triangle{
            .v0 = v0,
            .v1 = v1,
            .v2 = v2,
            .cull_flags = .{ .cull_fill = cull_fill, .cull_wireframe = cull_wireframe },
            .base_color = color,
            .texture_index = no_texture_index,
        };
    }
};

/// A 3D mesh, composed of vertices, texture coordinates, and triangles that index them.
pub const Mesh = struct {
    /// The list of unique 3D points (vertices) in the mesh.
    vertices: []Vec3,
    /// The list of triangles that form the mesh's surface.
    /// Each triangle is a set of 3 indices into the `vertices` array.
    triangles: []Triangle,
    /// The list of face normals. Each normal corresponds to a triangle in the `triangles` array
    /// and represents the direction that triangle is facing. Used for lighting.
    normals: []Vec3,
    /// Optional per-vertex normals used for smooth shading paths such as Gouraud.
    vertex_normals: []Vec3,
    /// The list of 2D texture coordinates (UVs). Each entry corresponds to a vertex.
    tex_coords: []Vec2,
    /// Meshlets generated for this mesh. Empty until meshlet generation runs.
    meshlets: []Meshlet,
    /// Packed global vertex indices for all meshlets.
    meshlet_vertices: []usize,
    /// Packed primitive descriptors for all meshlets.
    meshlet_primitives: []MeshletPrimitive,
    /// The allocator used to manage the memory for the mesh data.
    allocator: std.mem.Allocator,

    /// init initializes Mesh state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) !Mesh {
        return Mesh{
            .vertices = &[_]Vec3{},
            .triangles = &[_]Triangle{},
            .normals = &[_]Vec3{},
            .vertex_normals = &[_]Vec3{},
            .tex_coords = &[_]Vec2{},
            .meshlets = &[_]Meshlet{},
            .meshlet_vertices = &[_]usize{},
            .meshlet_primitives = &[_]MeshletPrimitive{},
            .allocator = allocator,
        };
    }

    /// Calculates the face normal for every triangle in the mesh.
    /// A normal is calculated by taking the cross product of two edges of a triangle.
    pub fn recalculateNormals(self: *Mesh) void {
        for (self.triangles, 0..) |tri, i| {
            const v0 = self.vertices[tri.v0];
            const v1 = self.vertices[tri.v1];
            const v2 = self.vertices[tri.v2];

            const edge1 = Vec3.sub(v1, v0);
            const edge2 = Vec3.sub(v2, v0);

            // The cross product gives a vector that is perpendicular to the plane of the triangle.
            const normal = Vec3.cross(edge1, edge2);
            self.normals[i] = normal.normalize();
        }
    }

    /// A factory function to create a simple 2x2x2 cube mesh, centered at the origin.
    pub fn cube(allocator: std.mem.Allocator) !Mesh {
        // 8 vertices for the corners of the cube.
        const vertices = try allocator.alloc(Vec3, 8);
        vertices[0] = Vec3.new(-1, -1, -1); // back-bottom-left
        vertices[1] = Vec3.new(1, -1, -1); // back-bottom-right
        vertices[2] = Vec3.new(1, 1, -1); // back-top-right
        vertices[3] = Vec3.new(-1, 1, -1); // back-top-left
        vertices[4] = Vec3.new(-1, -1, 1); // front-bottom-left
        vertices[5] = Vec3.new(1, -1, 1); // front-bottom-right
        vertices[6] = Vec3.new(1, 1, 1); // front-top-right
        vertices[7] = Vec3.new(-1, 1, 1); // front-top-left

        // 12 triangles (2 for each of the 6 faces).
        // The order of vertices (winding order) is important. We use a counter-clockwise (CCW)
        // order, which is standard for defining the "front" of a face.
        const triangles = try allocator.alloc(Triangle, 12);
        triangles[0] = Triangle.new(0, 3, 2); // Back face
        triangles[1] = Triangle.new(0, 2, 1);
        triangles[2] = Triangle.new(4, 5, 6); // Front face
        triangles[3] = Triangle.new(4, 6, 7);
        triangles[4] = Triangle.new(0, 4, 7); // Left face
        triangles[5] = Triangle.new(0, 7, 3);
        triangles[6] = Triangle.new(1, 2, 6); // Right face
        triangles[7] = Triangle.new(1, 6, 5);
        triangles[8] = Triangle.new(0, 1, 5); // Bottom face
        triangles[9] = Triangle.new(0, 5, 4);
        triangles[10] = Triangle.new(3, 7, 6); // Top face
        triangles[11] = Triangle.new(3, 6, 2);

        // For this simple cube, we just assign a default (0,0) texture coordinate to all vertices.
        const tex_coords = try allocator.alloc(Vec2, 8);
        @memset(tex_coords, Vec2.new(0.0, 0.0));

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 12),
            .vertex_normals = try allocator.alloc(Vec3, 8),
            .tex_coords = tex_coords,
            .meshlets = &[_]Meshlet{},
            .meshlet_vertices = &[_]usize{},
            .meshlet_primitives = &[_]MeshletPrimitive{},
            .allocator = allocator,
        };

        mesh.recalculateNormals();
        for (mesh.vertices, 0..) |vertex, index| {
            mesh.vertex_normals[index] = vertex.normalize();
        }
        return mesh;
    }

    /// A factory function to create a single triangle mesh.
    pub fn triangle(allocator: std.mem.Allocator) !Mesh {
        const vertices = try allocator.alloc(Vec3, 3);
        vertices[0] = Vec3.new(0, 1, 0);
        vertices[1] = Vec3.new(-1, -1, 0);
        vertices[2] = Vec3.new(1, -1, 0);

        const triangles = try allocator.alloc(Triangle, 1);
        triangles[0] = Triangle.new(0, 1, 2);

        const tex_coords = try allocator.alloc(Vec2, 3);
        @memset(tex_coords, Vec2.new(0.0, 0.0));

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 1),
            .vertex_normals = try allocator.alloc(Vec3, 3),
            .tex_coords = tex_coords,
            .meshlets = &[_]Meshlet{},
            .meshlet_vertices = &[_]usize{},
            .meshlet_primitives = &[_]MeshletPrimitive{},
            .allocator = allocator,
        };

        mesh.recalculateNormals();
        @memset(mesh.vertex_normals, Vec3.new(0.0, 0.0, 1.0));
        return mesh;
    }

    /// Frees all memory allocated for the mesh's data.
    pub fn deinit(self: *Mesh) void {
        self.clearMeshlets();
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
        self.allocator.free(self.normals);
        self.allocator.free(self.vertex_normals);
        self.allocator.free(self.tex_coords);
    }

    /// Releases all generated meshlets and associated buffers.
    pub fn clearMeshlets(self: *Mesh) void {
        if (self.meshlets.len != 0) self.allocator.free(self.meshlets);
        if (self.meshlet_vertices.len != 0) self.allocator.free(self.meshlet_vertices);
        if (self.meshlet_primitives.len != 0) self.allocator.free(self.meshlet_primitives);
        self.meshlets = &[_]Meshlet{};
        self.meshlet_vertices = &[_]usize{};
        self.meshlet_primitives = &[_]MeshletPrimitive{};
    }

    /// Performs meshlet vertex slice.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn meshletVertexSlice(self: *const Mesh, meshlet: *const Meshlet) []const usize {
        return self.meshlet_vertices[meshlet.vertex_offset .. meshlet.vertex_offset + meshlet.vertex_count];
    }

    /// Performs meshlet primitive slice.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn meshletPrimitiveSlice(self: *const Mesh, meshlet: *const Meshlet) []const MeshletPrimitive {
        return self.meshlet_primitives[meshlet.primitive_offset .. meshlet.primitive_offset + meshlet.primitive_count];
    }

    /// Returns meshlet global vertex index.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn meshletGlobalVertexIndex(self: *const Mesh, meshlet: *const Meshlet, local_index: u16) usize {
        return self.meshlet_vertices[meshlet.vertex_offset + @as(usize, @intCast(local_index))];
    }

    /// Processes refresh meshlets.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn refreshMeshlets(self: *Mesh) void {
        if (self.meshlets.len == 0) return;

        for (self.meshlets) |*meshlet| {
            const vertex_indices = self.meshletVertexSlice(meshlet);
            const primitive_slice = self.meshletPrimitiveSlice(meshlet);
            if (vertex_indices.len == 0 or primitive_slice.len == 0) continue;

            var centroid = Vec3.new(0.0, 0.0, 0.0);
            for (vertex_indices) |vertex_index| {
                centroid = Vec3.add(centroid, self.vertices[vertex_index]);
            }
            centroid = Vec3.scale(centroid, 1.0 / @as(f32, @floatFromInt(vertex_indices.len)));

            var radius: f32 = 0.0;
            var aabb_min = Vec3.new(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
            var aabb_max = Vec3.new(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32));
            for (vertex_indices) |vertex_index| {
                const pos = self.vertices[vertex_index];
                const delta = Vec3.sub(pos, centroid);
                const distance = Vec3.length(delta);
                if (distance > radius) radius = distance;
                aabb_min = Vec3.min(aabb_min, pos);
                aabb_max = Vec3.max(aabb_max, pos);
            }

            var cone_axis_sum = Vec3.new(0.0, 0.0, 0.0);
            for (primitive_slice) |primitive| {
                cone_axis_sum = Vec3.add(cone_axis_sum, self.triangleNormalForIndex(primitive.triangle_index));
            }

            var cone_axis = Vec3.new(0.0, 0.0, 1.0);
            var cone_cutoff: f32 = -1.0;
            const cone_axis_len = Vec3.length(cone_axis_sum);
            if (cone_axis_len > 1e-6) {
                cone_axis = Vec3.scale(cone_axis_sum, 1.0 / cone_axis_len);
                cone_cutoff = 1.0;
                for (primitive_slice) |primitive| {
                    const tri_normal = self.triangleNormalForIndex(primitive.triangle_index);
                    const alignment = std.math.clamp(Vec3.dot(cone_axis, tri_normal), -1.0, 1.0);
                    if (alignment < cone_cutoff) cone_cutoff = alignment;
                }
            }

            meshlet.bounds_center = centroid;
            meshlet.bounds_radius = radius;
            meshlet.normal_cone_axis = cone_axis;
            meshlet.normal_cone_cutoff = cone_cutoff;
            meshlet.aabb_min = aabb_min;
            meshlet.aabb_max = aabb_max;
        }
    }

    fn triangleNormalForIndex(self: *const Mesh, tri_idx: usize) Vec3 {
        if (tri_idx < self.normals.len) {
            const normal = self.normals[tri_idx];
            const len = Vec3.length(normal);
            if (len > 1e-6) return Vec3.scale(normal, 1.0 / len);
        }

        const tri = self.triangles[tri_idx];
        const p0 = self.vertices[tri.v0];
        const p1 = self.vertices[tri.v1];
        const p2 = self.vertices[tri.v2];
        const fallback = Vec3.cross(Vec3.sub(p1, p0), Vec3.sub(p2, p0));
        const len = Vec3.length(fallback);
        if (len > 1e-6) return Vec3.scale(fallback, 1.0 / len);
        return Vec3.new(0.0, 0.0, 1.0);
    }

    /// Calculates the mesh's bounding box and translates its vertices so that the
    /// center of the box is at the world origin (0,0,0).
    pub fn centerToOrigin(self: *Mesh) void {
        if (self.vertices.len == 0) return;

        var min = self.vertices[0];
        var max = self.vertices[0];

        for (self.vertices[1..]) |v| {
            min = Vec3.new(@min(min.x, v.x), @min(min.y, v.y), @min(min.z, v.z));
            max = Vec3.new(@max(max.x, v.x), @max(max.y, v.y), @max(max.z, v.z));
        }

        const center = Vec3.scale(Vec3.add(min, max), 0.5);

        for (self.vertices) |*v| {
            v.* = Vec3.sub(v.*, center);
        }
        self.clearMeshlets();
    }

    fn sortTrianglesSpatially(self: *Mesh) !void {
        if (self.triangles.len == 0) return;

        const TriSortData = struct {
            tri: Triangle,
            code: u32,
        };

        var sort_data = try self.allocator.alloc(TriSortData, self.triangles.len);
        defer self.allocator.free(sort_data);

        var min_c = Vec3.new(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
        var max_c = Vec3.new(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32));

        for (self.triangles, 0..) |*tri, i| {
            const v0 = self.vertices[tri.v0];
            const v1 = self.vertices[tri.v1];
            const v2 = self.vertices[tri.v2];
            const cx = (v0.x + v1.x + v2.x) / 3.0;
            const cy = (v0.y + v1.y + v2.y) / 3.0;
            const cz = (v0.z + v1.z + v2.z) / 3.0;
            min_c.x = @min(min_c.x, cx);
            min_c.y = @min(min_c.y, cy);
            min_c.z = @min(min_c.z, cz);
            max_c.x = @max(max_c.x, cx);
            max_c.y = @max(max_c.y, cy);
            max_c.z = @max(max_c.z, cz);
            sort_data[i] = .{ .tri = tri.*, .code = 0 };
        }

        const extent = Vec3.new(
            @max(1e-4, max_c.x - min_c.x),
            @max(1e-4, max_c.y - min_c.y),
            @max(1e-4, max_c.z - min_c.z),
        );

        const Morton = struct {
            fn expandBits(v: u32) u32 {
                var x = v & 0x000003ff; // 10 bits
                x = (x | (x << 16)) & 0x30000ff;
                x = (x | (x <<  8)) & 0x0300f00f;
                x = (x | (x <<  4)) & 0x30c30c3;
                x = (x | (x <<  2)) & 0x9249249;
                return x;
            }
            fn encode(x: f32, y: f32, z: f32) u32 {
                const xx = expandBits(@as(u32, @intFromFloat(@max(0.0, @min(0.999, x)) * 1024.0)));
                const yy = expandBits(@as(u32, @intFromFloat(@max(0.0, @min(0.999, y)) * 1024.0)));
                const zz = expandBits(@as(u32, @intFromFloat(@max(0.0, @min(0.999, z)) * 1024.0)));
                return xx | (yy << 1) | (zz << 2);
            }
        };

        for (self.triangles, 0..) |*tri, i| {
            const v0 = self.vertices[tri.v0];
            const v1 = self.vertices[tri.v1];
            const v2 = self.vertices[tri.v2];
            const cx = (v0.x + v1.x + v2.x) / 3.0;
            const cy = (v0.y + v1.y + v2.y) / 3.0;
            const cz = (v0.z + v1.z + v2.z) / 3.0;
            const nx = (cx - min_c.x) / extent.x;
            const ny = (cy - min_c.y) / extent.y;
            const nz = (cz - min_c.z) / extent.z;
            sort_data[i].code = Morton.encode(nx, ny, nz);
        }

        const SortCtx = struct {
            fn lessThan(_: void, a: TriSortData, b: TriSortData) bool {
                return a.code < b.code;
            }
        };
        std.mem.sortUnstable(TriSortData, sort_data, {}, SortCtx.lessThan);

        for (sort_data, 0..) |sd, i| {
            self.triangles[i] = sd.tri;
        }
    }

    /// Processes generate meshlets.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn generateMeshlets(self: *Mesh, max_vertices: usize, max_triangles: usize) !void {
        const safe_vertex_limit = if (max_vertices < 3) 3 else max_vertices;
        const safe_triangle_limit = if (max_triangles < 1) 1 else max_triangles;

        self.clearMeshlets();
        if (self.triangles.len == 0) {
            self.meshlets = &[_]Meshlet{};
            return;
        }

        self.sortTrianglesSpatially() catch |err| {
            std.debug.print("Spatial sort failed, continuing without sort: {}\n", .{err});
        };

        var meshlets_temp = std.ArrayList(Meshlet){};
        defer meshlets_temp.deinit(self.allocator);
        var packed_vertices_temp = std.ArrayList(usize){};
        defer packed_vertices_temp.deinit(self.allocator);
        var packed_primitives_temp = std.ArrayList(MeshletPrimitive){};
        defer packed_primitives_temp.deinit(self.allocator);

        var current_vertices = std.ArrayList(usize){};
        defer current_vertices.deinit(self.allocator);

        var current_primitives = std.ArrayList(MeshletPrimitive){};
        defer current_primitives.deinit(self.allocator);

        var vertex_map = std.AutoHashMap(usize, u16).init(self.allocator);
        defer vertex_map.deinit();

        const Flush = struct {
            fn emit(
                mesh: *Mesh,
                meshlets: *std.ArrayList(Meshlet),
                packed_vertices: *std.ArrayList(usize),
                packed_primitives: *std.ArrayList(MeshletPrimitive),
                vertex_indices: *std.ArrayList(usize),
                primitives: *std.ArrayList(MeshletPrimitive),
            ) !void {
                if (primitives.items.len == 0) return;

                var centroid = Vec3.new(0.0, 0.0, 0.0);
                if (vertex_indices.items.len != 0) {
                    for (vertex_indices.items) |vi| {
                        centroid = Vec3.add(centroid, mesh.vertices[vi]);
                    }
                    const inv = 1.0 / @as(f32, @floatFromInt(vertex_indices.items.len));
                    centroid = Vec3.scale(centroid, inv);
                }

                var radius: f32 = 0.0;
                var aabb_min = Vec3.new(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
                var aabb_max = Vec3.new(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32));
                for (vertex_indices.items) |vi| {
                    const pos = mesh.vertices[vi];
                    const delta = Vec3.sub(pos, centroid);
                    const distance = Vec3.length(delta);
                    if (distance > radius) radius = distance;
                    aabb_min = Vec3.min(aabb_min, pos);
                    aabb_max = Vec3.max(aabb_max, pos);
                }

                var cone_axis_sum = Vec3.new(0.0, 0.0, 0.0);
                for (primitives.items) |primitive| {
                    cone_axis_sum = Vec3.add(cone_axis_sum, mesh.triangleNormalForIndex(primitive.triangle_index));
                }

                var cone_axis = Vec3.new(0.0, 0.0, 1.0);
                var cone_cutoff: f32 = -1.0;
                const cone_axis_len = Vec3.length(cone_axis_sum);
                if (cone_axis_len > 1e-6) {
                    cone_axis = Vec3.scale(cone_axis_sum, 1.0 / cone_axis_len);
                    cone_cutoff = 1.0;
                    for (primitives.items) |primitive| {
                        const tri_normal = mesh.triangleNormalForIndex(primitive.triangle_index);
                        const alignment = std.math.clamp(Vec3.dot(cone_axis, tri_normal), -1.0, 1.0);
                        if (alignment < cone_cutoff) cone_cutoff = alignment;
                    }
                }

                const vertex_offset = packed_vertices.items.len;
                const primitive_offset = packed_primitives.items.len;
                try packed_vertices.appendSlice(mesh.allocator, vertex_indices.items);
                try packed_primitives.appendSlice(mesh.allocator, primitives.items);

                const meshlet = Meshlet{
                    .vertex_offset = vertex_offset,
                    .vertex_count = vertex_indices.items.len,
                    .primitive_offset = primitive_offset,
                    .primitive_count = primitives.items.len,
                    .bounds_center = centroid,
                    .bounds_radius = radius,
                    .normal_cone_axis = cone_axis,
                    .normal_cone_cutoff = cone_cutoff,
                    .aabb_min = aabb_min,
                    .aabb_max = aabb_max,
                };
                try meshlets.append(mesh.allocator, meshlet);
            }
        };

        for (self.triangles, 0..) |tri, tri_idx| {
            while (true) {
                var additional_vertices: usize = 0;
                const tri_vertices = [_]usize{ tri.v0, tri.v1, tri.v2 };
                for (tri_vertices) |vi| {
                    if (!vertex_map.contains(vi)) {
                        additional_vertices += 1;
                    }
                }

                const too_many_vertices = current_vertices.items.len + additional_vertices > safe_vertex_limit;
                const too_many_tris = current_primitives.items.len >= safe_triangle_limit;

                if ((too_many_vertices or too_many_tris) and current_primitives.items.len > 0) {
                    try Flush.emit(self, &meshlets_temp, &packed_vertices_temp, &packed_primitives_temp, &current_vertices, &current_primitives);
                    current_vertices.clearRetainingCapacity();
                    current_primitives.clearRetainingCapacity();
                    vertex_map.clearRetainingCapacity();
                    continue;
                }

                var local_vertices: [3]u16 = undefined;
                for (tri_vertices) |vi| {
                    const put_result = try vertex_map.getOrPut(vi);
                    if (!put_result.found_existing) {
                        if (current_vertices.items.len > std.math.maxInt(u16)) return error.MeshletVertexLimitExceeded;
                        const local_index: u16 = @intCast(current_vertices.items.len);
                        put_result.value_ptr.* = local_index;
                        try current_vertices.append(self.allocator, vi);
                    }
                }
                local_vertices[0] = vertex_map.get(tri.v0).?;
                local_vertices[1] = vertex_map.get(tri.v1).?;
                local_vertices[2] = vertex_map.get(tri.v2).?;
                try current_primitives.append(self.allocator, MeshletPrimitive{
                    .triangle_index = tri_idx,
                    .local_v0 = local_vertices[0],
                    .local_v1 = local_vertices[1],
                    .local_v2 = local_vertices[2],
                });
                break;
            }
        }

        try Flush.emit(self, &meshlets_temp, &packed_vertices_temp, &packed_primitives_temp, &current_vertices, &current_primitives);

        if (meshlets_temp.items.len == 0) {
            self.meshlets = &[_]Meshlet{};
            self.meshlet_vertices = &[_]usize{};
            self.meshlet_primitives = &[_]MeshletPrimitive{};
            return;
        }

        const meshlet_slice = try meshlets_temp.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(meshlet_slice);
        const meshlet_vertex_slice = try packed_vertices_temp.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(meshlet_vertex_slice);
        const meshlet_primitive_slice = try packed_primitives_temp.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(meshlet_primitive_slice);

        self.meshlets = meshlet_slice;
        self.meshlet_vertices = meshlet_vertex_slice;
        self.meshlet_primitives = meshlet_primitive_slice;
    }
};

test "generateMeshlets packs vertices and primitives contiguously" {
    var mesh = try Mesh.cube(std.testing.allocator);
    defer mesh.deinit();

    try mesh.generateMeshlets(64, 126);

    try std.testing.expect(mesh.meshlets.len > 0);
    try std.testing.expect(mesh.meshlet_vertices.len > 0);
    try std.testing.expect(mesh.meshlet_primitives.len > 0);

    var total_vertex_count: usize = 0;
    var total_primitive_count: usize = 0;
    for (mesh.meshlets) |meshlet| {
        total_vertex_count += meshlet.vertex_count;
        total_primitive_count += meshlet.primitive_count;

        const vertex_slice = mesh.meshletVertexSlice(&meshlet);
        const primitive_slice = mesh.meshletPrimitiveSlice(&meshlet);
        try std.testing.expectEqual(meshlet.vertex_count, vertex_slice.len);
        try std.testing.expectEqual(meshlet.primitive_count, primitive_slice.len);
        try std.testing.expect(meshlet.normal_cone_cutoff >= -1.0);
        try std.testing.expect(meshlet.normal_cone_cutoff <= 1.0);

        for (primitive_slice) |primitive| {
            try std.testing.expect(primitive.triangle_index < mesh.triangles.len);
            try std.testing.expect(@as(usize, primitive.local_v0) < meshlet.vertex_count);
            try std.testing.expect(@as(usize, primitive.local_v1) < meshlet.vertex_count);
            try std.testing.expect(@as(usize, primitive.local_v2) < meshlet.vertex_count);
            try std.testing.expect(mesh.meshletGlobalVertexIndex(&meshlet, primitive.local_v0) < mesh.vertices.len);
            try std.testing.expect(mesh.meshletGlobalVertexIndex(&meshlet, primitive.local_v1) < mesh.vertices.len);
            try std.testing.expect(mesh.meshletGlobalVertexIndex(&meshlet, primitive.local_v2) < mesh.vertices.len);
        }
    }

    try std.testing.expectEqual(total_vertex_count, mesh.meshlet_vertices.len);
    try std.testing.expectEqual(total_primitive_count, mesh.meshlet_primitives.len);
}

test "generateMeshlets respects primitive budget" {
    var mesh = try Mesh.cube(std.testing.allocator);
    defer mesh.deinit();

    try mesh.generateMeshlets(64, 1);

    try std.testing.expectEqual(mesh.triangles.len, mesh.meshlets.len);
    for (mesh.meshlets) |meshlet| {
        try std.testing.expect(meshlet.primitive_count <= 1);
        try std.testing.expect(meshlet.vertex_count <= 3);
    }
}
