//! # Mesh Module
//!
//! This module defines 3D mesh data (vertices and triangles).
//! A mesh is a collection of vertices and indices that form 3D geometry.
//!
//! **Single Concern**: Defining and storing 3D mesh geometry
//!
//! **JavaScript Equivalent**:
//! ```javascript
//! // Like Three.js geometry
//! class Mesh {
//!   constructor() {
//!     this.vertices = [];   // Array of {x, y, z}
//!     this.triangles = [];  // Array of [v0, v1, v2] (vertex indices)
//!   }
//!
//!   static cube() {
//!     const m = new Mesh();
//!     // Define 8 corner vertices
//!     // Add 12 triangles (2 per face)
//!     return m;
//!   }
//! }
//! ```

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

// ========== MESH STRUCTURE ==========

/// Triangle culling flags to control rendering
pub const TriangleCullFlags = struct {
    cull_fill: bool = false, // If true, skip painting the filled triangle
    cull_wireframe: bool = false, // If true, skip drawing the wireframe edges
};

/// A triangle face - references 3 vertex indices with optional culling flags
pub const Triangle = struct {
    v0: usize,
    v1: usize,
    v2: usize,
    cull_flags: TriangleCullFlags = .{}, // Culling flags for independent fill/wireframe control

    pub fn new(v0: usize, v1: usize, v2: usize) Triangle {
        return Triangle{ .v0 = v0, .v1 = v1, .v2 = v2, .cull_flags = .{} };
    }

    pub fn newWithCulling(v0: usize, v1: usize, v2: usize, cull_fill: bool, cull_wireframe: bool) Triangle {
        return Triangle{ .v0 = v0, .v1 = v1, .v2 = v2, .cull_flags = .{ .cull_fill = cull_fill, .cull_wireframe = cull_wireframe } };
    }
};

/// A 3D mesh: collection of vertices and triangles
pub const Mesh = struct {
    vertices: []Vec3,
    triangles: []Triangle,
    normals: []Vec3, // Face normals (one per triangle)
    allocator: std.mem.Allocator,

    /// Initialize an empty mesh
    pub fn init(allocator: std.mem.Allocator) !Mesh {
        return Mesh{
            .vertices = &[_]Vec3{},
            .triangles = &[_]Triangle{},
            .normals = &[_]Vec3{},
            .allocator = allocator,
        };
    }

    /// Calculate face normals for all triangles
    fn calculateNormals(self: *Mesh) void {
        for (self.triangles, 0..) |tri, i| {
            const v0 = self.vertices[tri.v0];
            const v1 = self.vertices[tri.v1];
            const v2 = self.vertices[tri.v2];

            // Calculate two edge vectors
            const edge1 = Vec3.sub(v1, v0);
            const edge2 = Vec3.sub(v2, v0);

            // Normal is the cross product of edges
            const normal = Vec3.cross(edge1, edge2);
            self.normals[i] = normal.normalize();
        }
    }

    /// Create a cube mesh (8 vertices, 12 triangles = 2 per face)
    /// Cube has dimensions 2x2x2, centered at origin
    /// Vertices go from -1 to +1 in each axis
    pub fn cube(allocator: std.mem.Allocator) !Mesh {
        // ===== Create 8 vertices for cube corners =====
        // Using 3D coordinate system:
        //   X: left (-) to right (+)
        //   Y: bottom (-) to top (+)
        //   Z: back (-) to front (+)

        const vertices = try allocator.alloc(Vec3, 8);
        vertices[0] = Vec3.new(-1, -1, -1); // back-bottom-left
        vertices[1] = Vec3.new(1, -1, -1); // back-bottom-right
        vertices[2] = Vec3.new(1, 1, -1); // back-top-right
        vertices[3] = Vec3.new(-1, 1, -1); // back-top-left
        vertices[4] = Vec3.new(-1, -1, 1); // front-bottom-left
        vertices[5] = Vec3.new(1, -1, 1); // front-bottom-right
        vertices[6] = Vec3.new(1, 1, 1); // front-top-right
        vertices[7] = Vec3.new(-1, 1, 1); // front-top-left

        // ===== Create 12 triangles (2 per face) =====
        // Each face is split into 2 triangles
        // Total: 6 faces * 2 triangles = 12 triangles

        const triangles = try allocator.alloc(Triangle, 12);

        // Back face (z = -1): should point outward (negative Z)
        // Viewed from outside (negative Z), counter-clockwise: 3->2->1->0
        triangles[0] = Triangle.new(3, 2, 1);
        triangles[1] = Triangle.new(3, 1, 0);

        // Front face (z = 1): should point outward (positive Z)
        // Viewed from outside (positive Z), counter-clockwise: 4->5->6->7
        triangles[2] = Triangle.new(4, 5, 6);
        triangles[3] = Triangle.new(4, 6, 7);

        // Left face (x = -1): should point outward (negative X)
        // Viewed from outside (negative X), counter-clockwise: 0->3->7->4
        triangles[4] = Triangle.new(0, 3, 7);
        triangles[5] = Triangle.new(0, 7, 4);

        // Right face (x = 1): should point outward (positive X)
        // Viewed from outside (positive X), counter-clockwise: 2->6->5->1
        triangles[6] = Triangle.new(2, 6, 5);
        triangles[7] = Triangle.new(2, 5, 1);

        // Bottom face (y = -1): should point outward (negative Y)
        // Viewed from outside (negative Y), counter-clockwise: 0->1->5->4
        triangles[8] = Triangle.new(0, 1, 5);
        triangles[9] = Triangle.new(0, 5, 4);

        // Top face (y = 1): should point outward (positive Y)
        // Viewed from outside (positive Y), counter-clockwise: 7->6->2->3
        triangles[10] = Triangle.new(7, 6, 2);
        triangles[11] = Triangle.new(7, 2, 3);

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 12),
            .allocator = allocator,
        };

        // Calculate all face normals
        mesh.calculateNormals();

        return mesh;
    }

    /// Create a single triangle mesh positioned around the origin
    /// Useful for simple rotation demos without hidden faces
    pub fn triangle(allocator: std.mem.Allocator) !Mesh {
        const vertices = try allocator.alloc(Vec3, 3);
        vertices[0] = Vec3.new(0, 1, 0); // top
        vertices[1] = Vec3.new(-1, -1, 0); // bottom-left
        vertices[2] = Vec3.new(1, -1, 0); // bottom-right

        const triangles = try allocator.alloc(Triangle, 1);
        triangles[0] = Triangle.new(0, 1, 2);

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 1),
            .allocator = allocator,
        };

        mesh.calculateNormals();
        return mesh;
    }

    /// Free allocated memory
    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
        self.allocator.free(self.normals);
    }
};
