const std = @import("std");
const ssimd = @import("ssimd.zig");
const Vec4f = ssimd.Vec4f;
const Vec2f = @Vector(2, f32);

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
        const sum = Vec2f{ a.x, a.y } + Vec2f{ b.x, b.y };
        return Vec2.new(sum[0], sum[1]);
    }

    pub fn add_mul(a: Vec2, b: Vec2, c: Vec2) Vec2 {
        const va = Vec2f{ a.x, a.y };
        const vb = Vec2f{ b.x, b.y };
        const vc = Vec2f{ c.x, c.y };
        const fused = if (ssimd.has_fma)
            @mulAdd(Vec2f, vb, vc, va)
        else
            va + vb * vc;
        return Vec2.new(fused[0], fused[1]);
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        const diff = Vec2f{ a.x, a.y } - Vec2f{ b.x, b.y };
        return Vec2.new(diff[0], diff[1]);
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        const scaled = Vec2f{ v.x, v.y } * Vec2f{ s, s };
        return Vec2.new(scaled[0], scaled[1]);
    }
};

/// A 3D vector of single-precision floats.
/// Can represent a point in 3D space or a direction/vector.
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
    _pad: f32 = 0.0,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z, ._pad = 0.0 };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return storeSelf(loadSelf(a) + loadSelf(b));
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return storeSelf(loadSelf(a) - loadSelf(b));
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        const scalar = Vec4f{ s, s, s, s };
        return storeSelf(loadSelf(v) * scalar);
    }

    /// Calculates the dot product of two vectors (a · b).
    /// The result indicates how much the two vectors point in the same direction.
    /// > 0: Same general direction.
    ///   0: Perpendicular.
    /// < 0: Opposite general direction.
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return ssimd.dotVec3(loadSelf(a), loadSelf(b));
    }

    /// Calculates the cross product of two vectors (a × b).
    /// The result is a new vector that is perpendicular to both input vectors.
    /// This is essential for calculating surface normals.
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        const va = loadSelf(a);
        const vb = loadSelf(b);
        const a_yzx = permute(va, .{ 1, 2, 0 });
        const a_zxy = permute(va, .{ 2, 0, 1 });
        const b_yzx = permute(vb, .{ 1, 2, 0 });
        const b_zxy = permute(vb, .{ 2, 0, 1 });
        return storeSelf(a_yzx * b_zxy - a_zxy * b_yzx);
    }

    /// Calculates the length (magnitude) of the vector.
    pub fn length(v: Vec3) f32 {
        return @sqrt(Vec3.dot(v, v));
    }

    /// Returns a new vector with the same direction as the input but with a length of 1.
    /// This is called a "unit vector".
    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len == 0) return Vec3.new(0, 0, 0);
        return Vec3.scale(v, 1.0 / len);
    }

    inline fn loadSelf(v: Vec3) Vec4f {
        return ssimd.loadVec3(Vec3, v);
    }

    inline fn storeSelf(vec: Vec4f) Vec3 {
        return ssimd.storeVec3(Vec3, vec);
    }

    inline fn permute(vec: Vec4f, comptime order: [3]u32) Vec4f {
        const mask = @Vector(4, u32){ order[0], order[1], order[2], 3 };
        return @shuffle(f32, vec, vec, mask);
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

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return storeVec(loadVec(a) + loadVec(b));
    }

    pub fn add_mul(a: Vec4, b: Vec4, c: Vec4) Vec4 {
        const va = loadVec(a);
        const vb = loadVec(b);
        const vc = loadVec(c);
        const fused = if (ssimd.has_fma)
            @mulAdd(Vec4f, vb, vc, va)
        else
            va + vb * vc;
        return storeVec(fused);
    }

    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return storeVec(loadVec(a) - loadVec(b));
    }

    pub fn scale(v: Vec4, s: f32) Vec4 {
        const scalar = Vec4f{ s, s, s, s };
        return storeVec(loadVec(v) * scalar);
    }

    pub fn dot(a: Vec4, b: Vec4) f32 {
        return ssimd.dot4(loadVec(a), loadVec(b));
    }

    pub fn length(v: Vec4) f32 {
        return @sqrt(Vec4.dot(v, v));
    }

    pub fn normalize(v: Vec4) Vec4 {
        const len = v.length();
        if (len == 0) return Vec4.new(0, 0, 0, 0);
        return Vec4.scale(v, 1.0 / len);
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

    inline fn loadVec(v: Vec4) Vec4f {
        return Vec4f{ v.x, v.y, v.z, v.w };
    }

    inline fn storeVec(vec: Vec4f) Vec4 {
        return Vec4.new(vec[0], vec[1], vec[2], vec[3]);
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
    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = std.mem.zeroes(Mat4);
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            const row_vec = rowVec(a, row);
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                const column_vec = columnVec(b, col);
                result.data[row * 4 + col] = ssimd.dot4(row_vec, column_vec);
            }
        }
        return result;
    }

    /// Multiplies a matrix by a 4D vector, applying the transformation.
    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        const vec = Vec4f{ v.x, v.y, v.z, v.w };
        return Vec4.new(
            ssimd.dot4(rowVec(m, 0), vec),
            ssimd.dot4(rowVec(m, 1), vec),
            ssimd.dot4(rowVec(m, 2), vec),
            ssimd.dot4(rowVec(m, 3), vec),
        );
    }

    /// Multiplies a matrix by a 3D vector (point), applying the transformation.
    /// This is a convenience function that implicitly converts the Vec3 to a Vec4 (w=1) and back.
    pub fn mulVec3(m: Mat4, v: Vec3) Vec3 {
        const v4 = Vec4.from3D(v);
        const result = m.mulVec4(v4);
        return result.to3D();
    }

    inline fn rowVec(m: Mat4, row: usize) Vec4f {
        return Vec4f{
            m.data[row * 4 + 0],
            m.data[row * 4 + 1],
            m.data[row * 4 + 2],
            m.data[row * 4 + 3],
        };
    }

    inline fn columnVec(m: Mat4, col: usize) Vec4f {
        return Vec4f{
            m.data[0 * 4 + col],
            m.data[1 * 4 + col],
            m.data[2 * 4 + col],
            m.data[3 * 4 + col],
        };
    }
};
