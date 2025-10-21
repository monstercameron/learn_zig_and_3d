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
const Vec2 = math.Vec2;

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
    tex_coords: []Vec2,
    allocator: std.mem.Allocator,

    /// Initialize an empty mesh
    pub fn init(allocator: std.mem.Allocator) !Mesh {
        return Mesh{
            .vertices = &[_]Vec3{},
            .triangles = &[_]Triangle{},
            .normals = &[_]Vec3{},
            .tex_coords = &[_]Vec2{},
            .allocator = allocator,
        };
    }

    /// Calculate face normals for all triangles
    pub fn recalculateNormals(self: *Mesh) void {
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

        // Back face (z = -1): should point outward (toward camera from -Z)
        // Viewed from camera (+Z), counter-clockwise: 0->3->2->1
        triangles[0] = Triangle.new(0, 3, 2);
        triangles[1] = Triangle.new(0, 2, 1);

        // Front face (z = 1): should point outward (toward camera from +Z)
        // Viewed from camera (+Z), counter-clockwise: 4->5->6->7
        triangles[2] = Triangle.new(4, 5, 6);
        triangles[3] = Triangle.new(4, 6, 7);

        // Left face (x = -1): should point outward (toward camera from -X)
        // Viewed from camera (+Z), counter-clockwise: 0->4->7->3
        triangles[4] = Triangle.new(0, 4, 7);
        triangles[5] = Triangle.new(0, 7, 3);

        // Right face (x = 1): should point outward (toward camera from +X)
        // Viewed from camera (+Z), counter-clockwise: 1->2->6->5
        triangles[6] = Triangle.new(1, 2, 6);
        triangles[7] = Triangle.new(1, 6, 5);

        // Bottom face (y = -1): should point outward (toward camera from -Y)
        // Viewed from camera (+Z), counter-clockwise: 0->1->5->4
        triangles[8] = Triangle.new(0, 1, 5);
        triangles[9] = Triangle.new(0, 5, 4);

        // Top face (y = 1): should point outward (toward camera from +Y)
        // Viewed from camera (+Z), counter-clockwise: 3->7->6->2
        triangles[10] = Triangle.new(3, 7, 6);
        triangles[11] = Triangle.new(3, 6, 2);

        const tex_coords = try allocator.alloc(Vec2, 8);
        const zero_uv = Vec2.new(0.0, 0.0);
        for (tex_coords) |*uv| {
            uv.* = zero_uv;
        }

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 12),
            .tex_coords = tex_coords,
            .allocator = allocator,
        };

        // Calculate all face normals
        mesh.recalculateNormals();

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

        const tex_coords = try allocator.alloc(Vec2, 3);
        const zero_uv = Vec2.new(0.0, 0.0);
        for (tex_coords) |*uv| {
            uv.* = zero_uv;
        }

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 1),
            .tex_coords = tex_coords,
            .allocator = allocator,
        };

        mesh.recalculateNormals();
        return mesh;
    }

    /// Free allocated memory
    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
        self.allocator.free(self.normals);
        self.allocator.free(self.tex_coords);
    }

    /// Translate the mesh so its bounding box center sits at the origin.
    pub fn centerToOrigin(self: *Mesh) void {
        if (self.vertices.len == 0) return;

        var min = self.vertices[0];
        var max = self.vertices[0];

        for (self.vertices[1..]) |v| {
            min = Vec3.new(@min(min.x, v.x), @min(min.y, v.y), @min(min.z, v.z));
            max = Vec3.new(@max(max.x, v.x), @max(max.y, v.y), @max(max.z, v.z));
        }

        const center = Vec3.scale(Vec3.add(min, max), 0.5);

        for (self.vertices, 0..) |v, i| {
            self.vertices[i] = Vec3.sub(v, center);
        }
    }

    /// Build a flat ground plane centered on the origin
    pub fn groundPlane(allocator: std.mem.Allocator, size: f32, uv_scale: f32, elevation: f32, offset_z: f32) !Mesh {
        const half = size * 0.5;

        const vertices = try allocator.alloc(Vec3, 4);
        vertices[0] = Vec3.new(-half, elevation, -half + offset_z);
        vertices[1] = Vec3.new(half, elevation, -half + offset_z);
        vertices[2] = Vec3.new(half, elevation, half + offset_z);
        vertices[3] = Vec3.new(-half, elevation, half + offset_z);

        const triangles = try allocator.alloc(Triangle, 2);
        triangles[0] = Triangle.new(0, 2, 1);
        triangles[1] = Triangle.new(0, 3, 2);

    const tex_coords = try allocator.alloc(Vec2, 4);
    const uv_max = uv_scale;
    tex_coords[0] = Vec2.new(0, 0);
    tex_coords[1] = Vec2.new(uv_max, 0);
    tex_coords[2] = Vec2.new(uv_max, uv_max);
    tex_coords[3] = Vec2.new(0, uv_max);

        var mesh = Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .normals = try allocator.alloc(Vec3, 2),
            .tex_coords = tex_coords,
            .allocator = allocator,
        };

        mesh.recalculateNormals();
        return mesh;
    }
};
