//! # Math Module
//!
//! This module provides 3D math utilities for graphics programming.
//! Includes vector types, matrix types, and transformation operations.
//!
//! **Single Concern**: Linear algebra for 3D graphics (vectors, matrices, transformations)
//!
//! **JavaScript Equivalent**:
//! ```javascript
//! // Like a math library for graphics
//! class Vec3 {
//!   constructor(x, y, z) { this.x = x; this.y = y; this.z = z; }
//!   static add(a, b) { return new Vec3(a.x+b.x, a.y+b.y, a.z+b.z); }
//!   static dot(a, b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
//! }
//!
//! class Mat4 {
//!   constructor(data) { this.data = data; } // 4x4 matrix stored as 16 floats
//!   static identity() { /* ... */ }
//!   static multiply(a, b) { /* ... */ }
//! }
//! ```

const std = @import("std");

// ========== VECTOR TYPES ==========

/// 2D vector for UV texture coordinates or screen positions
pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn new(x: f32, y: f32) Vec2 {
        return Vec2{ .x = x, .y = y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return Vec2.new(a.x + b.x, a.y + b.y);
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return Vec2.new(a.x - b.x, a.y - b.y);
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return Vec2.new(v.x * s, v.y * s);
    }
};

/// 3D vector for positions and directions
/// Can represent either a point or a direction in 3D space
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    /// Create a new 3D vector
    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z };
    }

    /// Add two vectors
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(a.x + b.x, a.y + b.y, a.z + b.z);
    }

    /// Subtract two vectors
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(a.x - b.x, a.y - b.y, a.z - b.z);
    }

    /// Multiply vector by scalar
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return Vec3.new(v.x * s, v.y * s, v.z * s);
    }

    /// Dot product (a · b)
    /// Returns how "aligned" two vectors are (positive = same direction)
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    /// Cross product (a × b)
    /// Returns a vector perpendicular to both a and b
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
        );
    }

    /// Length (magnitude) of the vector
    pub fn length(v: Vec3) f32 {
        return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    }

    /// Normalize vector to unit length (length = 1)
    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len == 0) return Vec3.new(0, 0, 0);
        return Vec3.scale(v, 1.0 / len);
    }
};

/// 4D homogeneous vector (used for matrix transformations)
/// The 4th component (w) is used for perspective division
pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    /// Create a new 4D vector
    pub fn new(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return Vec4{ .x = x, .y = y, .z = z, .w = w };
    }

    /// Convert 3D vector to 4D homogeneous vector (w = 1.0)
    pub fn from3D(v: Vec3) Vec4 {
        return Vec4.new(v.x, v.y, v.z, 1.0);
    }

    /// Convert 4D homogeneous vector back to 3D (divide by w)
    pub fn to3D(v: Vec4) Vec3 {
        if (v.w == 0) return Vec3.new(v.x, v.y, v.z);
        return Vec3.new(v.x / v.w, v.y / v.w, v.z / v.w);
    }
};

// ========== MATRIX TYPES ==========

/// 4x4 matrix for 3D transformations
/// Stored in row-major order: data[row * 4 + col]
/// Used for: translation, rotation, scaling, projection
pub const Mat4 = struct {
    // 16 elements in row-major order
    data: [16]f32,

    /// Create identity matrix (no transformation)
    pub fn identity() Mat4 {
        var m = Mat4{ .data = undefined };
        for (0..16) |i| {
            m.data[i] = 0;
        }
        m.data[0] = 1; // m[0][0]
        m.data[5] = 1; // m[1][1]
        m.data[10] = 1; // m[2][2]
        m.data[15] = 1; // m[3][3]
        return m;
    }

    /// Create translation matrix
    /// Moves an object by (tx, ty, tz)
    pub fn translate(tx: f32, ty: f32, tz: f32) Mat4 {
        var m = Mat4.identity();
        m.data[12] = tx; // m[3][0]
        m.data[13] = ty; // m[3][1]
        m.data[14] = tz; // m[3][2]
        return m;
    }

    /// Create scale matrix
    /// Scales an object by (sx, sy, sz)
    pub fn scale(sx: f32, sy: f32, sz: f32) Mat4 {
        var m = Mat4.identity();
        m.data[0] = sx; // m[0][0]
        m.data[5] = sy; // m[1][1]
        m.data[10] = sz; // m[2][2]
        return m;
    }

    /// Create rotation matrix around X axis
    /// Angle in radians, positive = counterclockwise (right-hand rule)
    pub fn rotateX(angle: f32) Mat4 {
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        var m = Mat4.identity();
        m.data[5] = cos_a; // m[1][1]
        m.data[6] = sin_a; // m[1][2]
        m.data[9] = -sin_a; // m[2][1]
        m.data[10] = cos_a; // m[2][2]
        return m;
    }

    /// Create rotation matrix around Y axis
    pub fn rotateY(angle: f32) Mat4 {
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        var m = Mat4.identity();
        m.data[0] = cos_a; // m[0][0]
        m.data[2] = -sin_a; // m[0][2]
        m.data[8] = sin_a; // m[2][0]
        m.data[10] = cos_a; // m[2][2]
        return m;
    }

    /// Create rotation matrix around Z axis
    pub fn rotateZ(angle: f32) Mat4 {
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        var m = Mat4.identity();
        m.data[0] = cos_a; // m[0][0]
        m.data[1] = sin_a; // m[0][1]
        m.data[4] = -sin_a; // m[1][0]
        m.data[5] = cos_a; // m[1][1]
        return m;
    }

    /// Create perspective projection matrix
    /// fov: field of view angle in radians (typically pi/4 for 45 degrees)
    /// aspect: width / height
    /// near, far: depth clipping planes
    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        var m = Mat4{ .data = undefined };
        for (0..16) |i| {
            m.data[i] = 0;
        }

        const f = 1.0 / @tan(fov / 2.0);
        const range = 1.0 / (near - far);

        m.data[0] = f / aspect; // m[0][0]
        m.data[5] = f; // m[1][1]
        m.data[10] = (near + far) * range; // m[2][2]
        m.data[11] = -1.0; // m[2][3]
        m.data[14] = 2.0 * near * far * range; // m[3][2]

        return m;
    }

    /// Create orthographic projection matrix (no perspective)
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var m = Mat4{ .data = undefined };
        for (0..16) |i| {
            m.data[i] = 0;
        }

        m.data[0] = 2.0 / (right - left); // m[0][0]
        m.data[5] = 2.0 / (top - bottom); // m[1][1]
        m.data[10] = -2.0 / (far - near); // m[2][2]
        m.data[12] = -(right + left) / (right - left); // m[3][0]
        m.data[13] = -(top + bottom) / (top - bottom); // m[3][1]
        m.data[14] = -(far + near) / (far - near); // m[3][2]
        m.data[15] = 1.0; // m[3][3]

        return m;
    }

    /// Multiply two 4x4 matrices: result = a * b
    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result = Mat4{ .data = undefined };
        for (0..4) |row| {
            for (0..4) |col| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.data[row * 4 + k] * b.data[k * 4 + col];
                }
                result.data[row * 4 + col] = sum;
            }
        }
        return result;
    }

    /// Multiply matrix by 4D vector: result = m * v
    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        var result = Vec4.new(0, 0, 0, 0);
        result.x = m.data[0] * v.x + m.data[1] * v.y + m.data[2] * v.z + m.data[3] * v.w;
        result.y = m.data[4] * v.x + m.data[5] * v.y + m.data[6] * v.z + m.data[7] * v.w;
        result.z = m.data[8] * v.x + m.data[9] * v.y + m.data[10] * v.z + m.data[11] * v.w;
        result.w = m.data[12] * v.x + m.data[13] * v.y + m.data[14] * v.z + m.data[15] * v.w;
        return result;
    }

    /// Multiply matrix by 3D vector (implicitly w=1)
    pub fn mulVec3(m: Mat4, v: Vec3) Vec3 {
        const v4 = Vec4.from3D(v);
        const result = m.mulVec4(v4);
        return result.to3D();
    }
};
