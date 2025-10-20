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

/// A triangle face - references 3 vertex indices
pub const Triangle = struct {
    v0: usize,
    v1: usize,
    v2: usize,

    pub fn new(v0: usize, v1: usize, v2: usize) Triangle {
        return Triangle{ .v0 = v0, .v1 = v1, .v2 = v2 };
    }
};

/// A 3D mesh: collection of vertices and triangles
pub const Mesh = struct {
    vertices: []Vec3,
    triangles: []Triangle,
    allocator: std.mem.Allocator,

    /// Initialize an empty mesh
    pub fn init(allocator: std.mem.Allocator) !Mesh {
        return Mesh{
            .vertices = &[_]Vec3{},
            .triangles = &[_]Triangle{},
            .allocator = allocator,
        };
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
        vertices[1] = Vec3.new(1, -1, -1);  // back-bottom-right
        vertices[2] = Vec3.new(1, 1, -1);   // back-top-right
        vertices[3] = Vec3.new(-1, 1, -1);  // back-top-left
        vertices[4] = Vec3.new(-1, -1, 1);  // front-bottom-left
        vertices[5] = Vec3.new(1, -1, 1);   // front-bottom-right
        vertices[6] = Vec3.new(1, 1, 1);    // front-top-right
        vertices[7] = Vec3.new(-1, 1, 1);   // front-top-left

        // ===== Create 12 triangles (2 per face) =====
        // Each face is split into 2 triangles
        // Total: 6 faces * 2 triangles = 12 triangles

        const triangles = try allocator.alloc(Triangle, 12);

        // Back face (z = -1): vertices 0, 1, 2, 3
        triangles[0] = Triangle.new(0, 1, 2);
        triangles[1] = Triangle.new(0, 2, 3);

        // Front face (z = 1): vertices 4, 5, 6, 7
        triangles[2] = Triangle.new(5, 4, 7);
        triangles[3] = Triangle.new(5, 7, 6);

        // Left face (x = -1): vertices 0, 3, 7, 4
        triangles[4] = Triangle.new(3, 7, 4);
        triangles[5] = Triangle.new(3, 4, 0);

        // Right face (x = 1): vertices 1, 5, 6, 2
        triangles[6] = Triangle.new(1, 5, 6);
        triangles[7] = Triangle.new(1, 6, 2);

        // Bottom face (y = -1): vertices 0, 4, 5, 1
        triangles[8] = Triangle.new(4, 5, 1);
        triangles[9] = Triangle.new(4, 1, 0);

        // Top face (y = 1): vertices 3, 2, 6, 7
        triangles[10] = Triangle.new(3, 6, 2);
        triangles[11] = Triangle.new(3, 7, 6);

        return Mesh{
            .vertices = vertices,
            .triangles = triangles,
            .allocator = allocator,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
    }
};
