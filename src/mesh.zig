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
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

/// A compact cluster of triangles processed together in the mesh-shader pipeline.
/// Stores the subset of vertex indices and triangle indices that belong to the meshlet
/// as well as a bounding sphere for quick culling tests.
pub const Meshlet = struct {
    vertex_indices: []usize,
    triangle_indices: []usize,
    bounds_center: Vec3,
    bounds_radius: f32,

    pub fn deinit(self: *Meshlet, allocator: std.mem.Allocator) void {
        allocator.free(self.vertex_indices);
        allocator.free(self.triangle_indices);
        self.vertex_indices = &[_]usize{};
        self.triangle_indices = &[_]usize{};
    }
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

    pub const default_color: u32 = 0xFF7F7F7F;

    pub fn new(v0: usize, v1: usize, v2: usize) Triangle {
        return Triangle{ .v0 = v0, .v1 = v1, .v2 = v2, .cull_flags = .{}, .base_color = default_color };
    }

    pub fn newWithCulling(v0: usize, v1: usize, v2: usize, cull_fill: bool, cull_wireframe: bool) Triangle {
        return Triangle{
            .v0 = v0,
            .v1 = v1,
            .v2 = v2,
            .cull_flags = .{ .cull_fill = cull_fill, .cull_wireframe = cull_wireframe },
            .base_color = default_color,
        };
    }

    pub fn newWithColor(v0: usize, v1: usize, v2: usize, color: u32) Triangle {
        return Triangle{ .v0 = v0, .v1 = v1, .v2 = v2, .cull_flags = .{}, .base_color = color };
    }

    pub fn newWithCullingAndColor(v0: usize, v1: usize, v2: usize, cull_fill: bool, cull_wireframe: bool, color: u32) Triangle {
        return Triangle{
            .v0 = v0,
            .v1 = v1,
            .v2 = v2,
            .cull_flags = .{ .cull_fill = cull_fill, .cull_wireframe = cull_wireframe },
            .base_color = color,
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
    /// The list of 2D texture coordinates (UVs). Each entry corresponds to a vertex.
    tex_coords: []Vec2,
    /// Meshlets generated for this mesh. Empty until meshlet generation runs.
    meshlets: []Meshlet,
    /// The allocator used to manage the memory for the mesh data.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Mesh {
        return Mesh{
            .vertices = &[_]Vec3{},
            .triangles = &[_]Triangle{},
            .normals = &[_]Vec3{},
            .tex_coords = &[_]Vec2{},
            .meshlets = &[_]Meshlet{},
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
            .tex_coords = tex_coords,
            .meshlets = &[_]Meshlet{},
            .allocator = allocator,
        };

        mesh.recalculateNormals();
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
            .tex_coords = tex_coords,
            .meshlets = &[_]Meshlet{},
            .allocator = allocator,
        };

        mesh.recalculateNormals();
        return mesh;
    }

    /// Frees all memory allocated for the mesh's data.
    pub fn deinit(self: *Mesh) void {
        self.clearMeshlets();
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
        self.allocator.free(self.normals);
        self.allocator.free(self.tex_coords);
    }

    /// Releases all generated meshlets and associated buffers.
    pub fn clearMeshlets(self: *Mesh) void {
        if (self.meshlets.len == 0) return;
        for (self.meshlets) |*meshlet| {
            meshlet.deinit(self.allocator);
        }
        self.allocator.free(self.meshlets);
        self.meshlets = &[_]Meshlet{};
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
    }

    pub fn generateMeshlets(self: *Mesh, max_vertices: usize, max_triangles: usize) !void {
        const safe_vertex_limit = if (max_vertices < 3) 3 else max_vertices;
        const safe_triangle_limit = if (max_triangles < 1) 1 else max_triangles;

        self.clearMeshlets();
        if (self.triangles.len == 0) {
            self.meshlets = &[_]Meshlet{};
            return;
        }

        var meshlets_temp = std.ArrayList(Meshlet){};
        var release_meshlets = true;
        defer {
            if (release_meshlets) {
                for (meshlets_temp.items) |*entry| {
                    entry.deinit(self.allocator);
                }
            }
            meshlets_temp.deinit(self.allocator);
        }

        var current_vertices = std.ArrayList(usize){};
        defer current_vertices.deinit(self.allocator);

        var current_triangles = std.ArrayList(usize){};
        defer current_triangles.deinit(self.allocator);

        var vertex_map = std.AutoHashMap(usize, bool).init(self.allocator);
        defer vertex_map.deinit();

        const Flush = struct {
            fn emit(
                mesh: *Mesh,
                meshlets: *std.ArrayList(Meshlet),
                vertex_indices: *std.ArrayList(usize),
                triangle_indices: *std.ArrayList(usize),
            ) !void {
                if (triangle_indices.items.len == 0) return;

                const vert_slice = try mesh.allocator.alloc(usize, vertex_indices.items.len);
                errdefer mesh.allocator.free(vert_slice);
                std.mem.copyForwards(usize, vert_slice, vertex_indices.items);

                const tri_slice = try mesh.allocator.alloc(usize, triangle_indices.items.len);
                errdefer mesh.allocator.free(tri_slice);
                std.mem.copyForwards(usize, tri_slice, triangle_indices.items);

                var centroid = Vec3.new(0.0, 0.0, 0.0);
                if (vert_slice.len != 0) {
                    for (vert_slice) |vi| {
                        centroid = Vec3.add(centroid, mesh.vertices[vi]);
                    }
                    const inv = 1.0 / @as(f32, @floatFromInt(vert_slice.len));
                    centroid = Vec3.scale(centroid, inv);
                }

                var radius: f32 = 0.0;
                for (vert_slice) |vi| {
                    const delta = Vec3.sub(mesh.vertices[vi], centroid);
                    const distance = Vec3.length(delta);
                    if (distance > radius) radius = distance;
                }

                const meshlet = Meshlet{
                    .vertex_indices = vert_slice,
                    .triangle_indices = tri_slice,
                    .bounds_center = centroid,
                    .bounds_radius = radius,
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
                const too_many_tris = current_triangles.items.len >= safe_triangle_limit;

                if ((too_many_vertices or too_many_tris) and current_triangles.items.len > 0) {
                    try Flush.emit(self, &meshlets_temp, &current_vertices, &current_triangles);
                    current_vertices.clearRetainingCapacity();
                    current_triangles.clearRetainingCapacity();
                    vertex_map.clearRetainingCapacity();
                    continue;
                }

                try current_triangles.append(self.allocator, tri_idx);
                for (tri_vertices) |vi| {
                    const put_result = try vertex_map.getOrPut(vi);
                    if (!put_result.found_existing) {
                        put_result.value_ptr.* = true;
                        try current_vertices.append(self.allocator, vi);
                    }
                }
                break;
            }
        }

        try Flush.emit(self, &meshlets_temp, &current_vertices, &current_triangles);

        if (meshlets_temp.items.len == 0) {
            self.meshlets = &[_]Meshlet{};
            release_meshlets = false;
            return;
        }

    self.meshlets = try self.allocator.alloc(Meshlet, meshlets_temp.items.len);
    std.mem.copyForwards(Meshlet, self.meshlets, meshlets_temp.items);
        release_meshlets = false;
    }
};
