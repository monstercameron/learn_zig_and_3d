//! # 3D Math Module
//!
//! This module provides the fundamental data structures and operations for 3D graphics,
//! including vectors and 4x4 matrices. It is a self-contained library for linear
//! algebra, which is the foundation of all 3D transformations.
//!
//! ## JavaScript Analogy
//!
//! This file is like a standalone 3D math library, such as `gl-matrix` or the
//! `THREE.Math` module in three.js. It provides the tools to move, rotate, scale,
//! and project objects in 3D space.
//!
//! ```javascript
//! // e.g., using gl-matrix
//! import { vec3, mat4 } from 'gl-matrix';
//!
//! const position = vec3.fromValues(1, 2, 3);
//! const transform = mat4.create(); // Creates an identity matrix
//! mat4.translate(transform, transform, [10, 0, 0]);
//! vec3.transformMat4(position, position, transform);
//! ```

const std = @import("std");

// ========== VECTOR TYPES ==========

/// A 2D vector of single-precision floats.
/// Primarily used for 2D screen positions and UV texture coordinates.
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

/// A 3D vector of single-precision floats.
/// Can represent a point in 3D space or a direction/vector.
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z };
    }

    // TODO(SIMD): This function can be vectorized. Multiple Vec3 additions can be performed in a single instruction.
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(a.x + b.x, a.y + b.y, a.z + b.z);
    }

    // TODO(SIMD): This function can be vectorized. Multiple Vec3 subtractions can be performed in a single instruction.
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(a.x - b.x, a.y - b.y, a.z - b.z);
    }

    // TODO(SIMD): This function can be vectorized. Multiple Vec3 scalar multiplications can be performed in a single instruction.
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return Vec3.new(v.x * s, v.y * s, v.z * s);
    }

    /// Calculates the dot product of two vectors (a · b).
    /// The result indicates how much the two vectors point in the same direction.
    /// > 0: Same general direction.
    ///   0: Perpendicular.
    /// < 0: Opposite general direction.
    // TODO(SIMD): This function is a prime candidate for a SIMD dot product instruction (DPPS on SSE4.1, FMA on AVX2).
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    /// Calculates the cross product of two vectors (a × b).
    /// The result is a new vector that is perpendicular to both input vectors.
    /// This is essential for calculating surface normals.
    // TODO(SIMD): The cross product can be vectorized using shuffle and multiply-subtract operations.
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
        );
    }

    /// Calculates the length (magnitude) of the vector.
    pub fn length(v: Vec3) f32 {
        return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    }

    /// Returns a new vector with the same direction as the input but with a length of 1.
    /// This is called a "unit vector".
    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len == 0) return Vec3.new(0, 0, 0);
        return Vec3.scale(v, 1.0 / len);
    }
};

/// A 4D homogeneous vector. This is a `Vec3` with an added `w` component.
/// This is a mathematical trick that allows a 4x4 matrix to perform perspective projection.
/// The `w` component is used as a divisor to create the illusion of depth.
pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn new(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return Vec4{ .x = x, .y = y, .z = z, .w = w };
    }

    /// Converts a 3D point into a 4D vector for matrix math. `w` is set to 1.0 for points.
    pub fn from3D(v: Vec3) Vec4 {
        return Vec4.new(v.x, v.y, v.z, 1.0);
    }

    /// Converts a 4D vector back to a 3D point by dividing by `w` (perspective divide).
    pub fn to3D(v: Vec4) Vec3 {
        if (v.w == 0) return Vec3.new(v.x, v.y, v.z);
        return Vec3.new(v.x / v.w, v.y / v.w, v.z / v.w);
    }
};

// ========== MATRIX TYPES ==========

/// A 4x4 matrix for 3D transformations, stored in row-major order.
/// This single structure can be used to represent translation, rotation, scale,
/// and projection transformations, which can be combined via multiplication.
pub const Mat4 = struct {
    // The 16 matrix elements, stored as a flat array in row-major order.
    // data[row * 4 + col]
    data: [16]f32,

    /// Returns an identity matrix. This matrix represents "no transformation".
    pub fn identity() Mat4 {
        return Mat4{ .data = [_]f32{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    /// Creates a translation matrix that moves an object by (tx, ty, tz).
    pub fn translate(tx: f32, ty: f32, tz: f32) Mat4 {
        var m = Mat4.identity();
        m.data[12] = tx;
        m.data[13] = ty;
        m.data[14] = tz;
        return m;
    }

    /// Creates a scale matrix that resizes an object by factors (sx, sy, sz).
    pub fn scale(sx: f32, sy: f32, sz: f32) Mat4 {
        var m = Mat4.identity();
        m.data[0] = sx;
        m.data[5] = sy;
        m.data[10] = sz;
        return m;
    }

    /// Creates a rotation matrix around the X-axis.
    /// `angle` is in radians.
    pub fn rotateX(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return Mat4{ .data = [_]f32{
            1, 0,  0, 0,
            0, c,  s, 0,
            0, -s, c, 0,
            0, 0,  0, 1,
        } };
    }

    /// Creates a rotation matrix around the Y-axis.
    pub fn rotateY(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return Mat4{ .data = [_]f32{
            c, 0, -s, 0,
            0, 1, 0,  0,
            s, 0, c,  0,
            0, 0, 0,  1,
        } };
    }

    /// Creates a rotation matrix around the Z-axis.
    pub fn rotateZ(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return Mat4{ .data = [_]f32{
            c,  s, 0, 0,
            -s, c, 0, 0,
            0,  0, 1, 0,
            0,  0, 0, 1,
        } };
    }

    /// Creates a perspective projection matrix, which simulates a camera lens.
    /// - `fov`: Vertical field of view, in radians.
    /// - `aspect`: The aspect ratio of the viewport (width / height).
    /// - `near`: The distance to the near clipping plane.
    /// - `far`: The distance to the far clipping plane.
    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        var m: Mat4 = std.mem.zeroes(Mat4);
        const f = 1.0 / @tan(fov / 2.0);
        const range_inv = 1.0 / (near - far);

        m.data[0] = f / aspect;
        m.data[5] = f;
        m.data[10] = (far + near) * range_inv;
        m.data[11] = -1.0;
        m.data[14] = 2.0 * far * near * range_inv;

        return m;
    }

    /// Creates an orthographic projection matrix (no perspective, like a 2D view).
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var m = Mat4.identity();
        const lr_inv = 1.0 / (right - left);
        const tb_inv = 1.0 / (top - bottom);
        const fn_inv = 1.0 / (far - near);

        m.data[0] = 2.0 * lr_inv;
        m.data[5] = 2.0 * tb_inv;
        m.data[10] = -2.0 * fn_inv;
        m.data[12] = -(right + left) * lr_inv;
        m.data[13] = -(top + bottom) * tb_inv;
        m.data[14] = -(far + near) * fn_inv;

        return m;
    }

    /// Multiplies two 4x4 matrices. Note: matrix multiplication is not commutative (A * B != B * A).
    /// The order matters and typically corresponds to applying transformations in reverse order.
    // TODO(SIMD): 4x4 matrix multiplication is a classic SIMD optimization. This can be heavily vectorized by processing rows/columns in parallel.
    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = std.mem.zeroes(Mat4);
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.data[row * 4 + k] * b.data[k * 4 + col];
                }
                result.data[row * 4 + col] = sum;
            }
        }
        return result;
    }

    /// Multiplies a matrix by a 4D vector, applying the transformation.
    // TODO(SIMD): This operation can be vectorized using 4-wide dot products.
    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        return Vec4.new(
            m.data[0] * v.x + m.data[1] * v.y + m.data[2] * v.z + m.data[3] * v.w,
            m.data[4] * v.x + m.data[5] * v.y + m.data[6] * v.z + m.data[7] * v.w,
            m.data[8] * v.x + m.data[9] * v.y + m.data[10] * v.z + m.data[11] * v.w,
            m.data[12] * v.x + m.data[13] * v.y + m.data[14] * v.z + m.data[15] * v.w,
        );
    }

    /// Multiplies a matrix by a 3D vector (point), applying the transformation.
    /// This is a convenience function that implicitly converts the Vec3 to a Vec4 (with w=1) and back.
    pub fn mulVec3(m: Mat4, v: Vec3) Vec3 {
        const v4 = Vec4.from3D(v);
        const result = m.mulVec4(v4);
        return result.to3D();
    }
};
