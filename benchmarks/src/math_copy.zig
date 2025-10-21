const std = @import("std");
const ssimd = @import("ssimd.zig");

const Vec4f = ssimd.Vec4f;
const WideVec = ssimd.WideVec;
const wide_batch = ssimd.vec3s_per_wide;
const vec2_batch = if (ssimd.f32_lane_count >= 4 and ssimd.f32_lane_count % 2 == 0)
    ssimd.f32_lane_count / 2
else
    0;
const supports_vec2_batches = vec2_batch != 0;
const Vec2f = @Vector(2, f32);
const vec4_batch = if (ssimd.f32_lane_count >= 4 and ssimd.f32_lane_count % 4 == 0)
    ssimd.f32_lane_count / 4
else
    0;
const supports_vec4_batches = vec4_batch != 0;

inline fn loadVec3(v: Vec3) Vec4f {
    return ssimd.loadVec3(Vec3, v);
}

inline fn storeVec3(vec: Vec4f) Vec3 {
    return ssimd.storeVec3(Vec3, vec);
}

inline fn loadVec4(v: Vec4) Vec4f {
    return Vec4f{ v.x, v.y, v.z, v.w };
}

inline fn storeVec4(vec: Vec4f) Vec4 {
    return Vec4.new(vec[0], vec[1], vec[2], vec[3]);
}

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

pub fn addSliceVec2(result: []Vec2, lhs: []const Vec2, rhs: []const Vec2) void {
    std.debug.assert(result.len == lhs.len and lhs.len == rhs.len);
    if (supports_vec2_batches and result.len >= vec2_batch and vec2_batch != 0) {
        addSliceVec2Wide(result, lhs, rhs);
        return;
    }
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec2.add(lhs[i], rhs[i]);
    }
}

pub fn addMulSliceVec2(
    result: []Vec2,
    acc: []const Vec2,
    mul_a: []const Vec2,
    mul_b: []const Vec2,
) void {
    std.debug.assert(result.len == acc.len and acc.len == mul_a.len and mul_a.len == mul_b.len);
    if (supports_vec2_batches and result.len >= vec2_batch and vec2_batch != 0) {
        addMulSliceVec2Wide(result, acc, mul_a, mul_b);
        return;
    }
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec2.add_mul(acc[i], mul_a[i], mul_b[i]);
    }
}

pub fn addSliceVec4(result: []Vec4, lhs: []const Vec4, rhs: []const Vec4) void {
    std.debug.assert(result.len == lhs.len and lhs.len == rhs.len);
    if (supports_vec4_batches and result.len >= vec4_batch and vec4_batch != 0) {
        addSliceVec4Wide(result, lhs, rhs);
        return;
    }
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec4.add(lhs[i], rhs[i]);
    }
}

pub fn addMulSliceVec4(
    result: []Vec4,
    acc: []const Vec4,
    mul_a: []const Vec4,
    mul_b: []const Vec4,
) void {
    std.debug.assert(result.len == acc.len and acc.len == mul_a.len and mul_a.len == mul_b.len);
    if (supports_vec4_batches and result.len >= vec4_batch and vec4_batch != 0) {
        addMulSliceVec4Wide(result, acc, mul_a, mul_b);
        return;
    }
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec4.add_mul(acc[i], mul_a[i], mul_b[i]);
    }
}

/// A 3D vector of single-precision floats.
/// Can represent a point in 3D space or a direction/vector.
/// `_pad` keeps the structure 16 bytes wide so we can hit 128/256-bit loads cleanly.
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
    _pad: f32 = 0.0,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z, ._pad = 0.0 };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        const sum = loadVec3(a) + loadVec3(b);
        return storeVec3(sum);
    }

    pub fn add_mul(a: Vec3, b: Vec3, c: Vec3) Vec3 {
        const va = loadVec3(a);
        const vb = loadVec3(b);
        const vc = loadVec3(c);
        return storeVec3(ssimd.fmaddVec3(va, vb, vc));
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        const diff = loadVec3(a) - loadVec3(b);
        return storeVec3(diff);
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        const scalar = Vec4f{ s, s, s, s };
        return storeVec3(loadVec3(v) * scalar);
    }

    /// Calculates the dot product of two vectors (a dot b).
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return ssimd.dotVec3(loadVec3(a), loadVec3(b));
    }

    /// Calculates the cross product of two vectors (a x b).
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        const va = loadVec3(a);
        const vb = loadVec3(b);
        const a_yzx = @shuffle(f32, va, va, @Vector(4, u32){ 1, 2, 0, 3 });
        const a_zxy = @shuffle(f32, va, va, @Vector(4, u32){ 2, 0, 1, 3 });
        const b_yzx = @shuffle(f32, vb, vb, @Vector(4, u32){ 1, 2, 0, 3 });
        const b_zxy = @shuffle(f32, vb, vb, @Vector(4, u32){ 2, 0, 1, 3 });
        return storeVec3(a_yzx * b_zxy - a_zxy * b_yzx);
    }

    /// Calculates the length (magnitude) of the vector.
    pub fn length(v: Vec3) f32 {
        return @sqrt(Vec3.dot(v, v));
    }

    /// Returns a new vector with the same direction as the input but with a length of 1.
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

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return storeVec4(loadVec4(a) + loadVec4(b));
    }

    pub fn add_mul(a: Vec4, b: Vec4, c: Vec4) Vec4 {
        const va = loadVec4(a);
        const vb = loadVec4(b);
        const vc = loadVec4(c);
        return storeVec4(ssimd.fmaddVec4(va, vb, vc));
    }

    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return storeVec4(loadVec4(a) - loadVec4(b));
    }

    pub fn scale(v: Vec4, s: f32) Vec4 {
        const scalar = Vec4f{ s, s, s, s };
        return storeVec4(loadVec4(v) * scalar);
    }

    pub fn dot(a: Vec4, b: Vec4) f32 {
        return ssimd.dot4(loadVec4(a), loadVec4(b));
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
    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        return Vec4.new(
            m.data[0] * v.x + m.data[1] * v.y + m.data[2] * v.z + m.data[3] * v.w,
            m.data[4] * v.x + m.data[5] * v.y + m.data[6] * v.z + m.data[7] * v.w,
            m.data[8] * v.x + m.data[9] * v.y + m.data[10] * v.z + m.data[11] * v.w,
            m.data[12] * v.x + m.data[13] * v.y + m.data[14] * v.z + m.data[15] * v.w,
        );
    }

    /// Multiplies a matrix by a 3D vector (point), applying the transformation.
    /// This is a convenience function that implicitly converts the Vec3 to a Vec4 (w=1) and back.
    pub fn mulVec3(m: Mat4, v: Vec3) Vec3 {
        const v4 = Vec4.from3D(v);
        const result = m.mulVec4(v4);
        return result.to3D();
    }
};

// ========== SIMD SLICE HELPERS ==========

pub fn addSlice(
    result: []Vec3,
    lhs: []const Vec3,
    rhs: []const Vec3,
) void {
    std.debug.assert(result.len == lhs.len and lhs.len == rhs.len);
    if (ssimd.supports_vec3_batches and result.len >= wide_batch and wide_batch != 0) {
        addSliceAvx2(result, lhs, rhs);
        return;
    }
    addSliceScalar(result, lhs, rhs);
}

fn addSliceScalar(result: []Vec3, lhs: []const Vec3, rhs: []const Vec3) void {
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec3.add(lhs[i], rhs[i]);
    }
}

fn addSliceVec2Wide(result: []Vec2, lhs: []const Vec2, rhs: []const Vec2) void {
    if (vec2_batch == 0) {
        var i: usize = 0;
        while (i < result.len) : (i += 1) {
            result[i] = Vec2.add(lhs[i], rhs[i]);
        }
        return;
    }

    const lhs_ptr = @as([*]const f32, @ptrCast(lhs.ptr));
    const rhs_ptr = @as([*]const f32, @ptrCast(rhs.ptr));
    const dst_ptr = @as([*]f32, @ptrCast(result.ptr));

    var batch_index: usize = 0;
    const batch_count = result.len / vec2_batch;
    const floats_per_batch = ssimd.f32_lane_count;
    while (batch_index < batch_count) : (batch_index += 1) {
        const float_index = batch_index * floats_per_batch;
        const va = ssimd.loadWide(lhs_ptr + float_index);
        const vb = ssimd.loadWide(rhs_ptr + float_index);
        const sum = va + vb;
        ssimd.storeWide(dst_ptr + float_index, sum);
    }

    var tail = batch_count * vec2_batch;
    while (tail < result.len) : (tail += 1) {
        result[tail] = Vec2.add(lhs[tail], rhs[tail]);
    }
}

fn addSliceVec4Wide(result: []Vec4, lhs: []const Vec4, rhs: []const Vec4) void {
    if (vec4_batch == 0) {
        var i: usize = 0;
        while (i < result.len) : (i += 1) {
            result[i] = Vec4.add(lhs[i], rhs[i]);
        }
        return;
    }

    const lhs_ptr = @as([*]const f32, @ptrCast(lhs.ptr));
    const rhs_ptr = @as([*]const f32, @ptrCast(rhs.ptr));
    const dst_ptr = @as([*]f32, @ptrCast(result.ptr));

    var batch_index: usize = 0;
    const batch_count = result.len / vec4_batch;
    const floats_per_batch = ssimd.f32_lane_count;
    while (batch_index < batch_count) : (batch_index += 1) {
        const float_index = batch_index * floats_per_batch;
        const va = ssimd.loadWide(lhs_ptr + float_index);
        const vb = ssimd.loadWide(rhs_ptr + float_index);
        const sum = va + vb;
        ssimd.storeWide(dst_ptr + float_index, sum);
    }

    var tail = batch_count * vec4_batch;
    while (tail < result.len) : (tail += 1) {
        result[tail] = Vec4.add(lhs[tail], rhs[tail]);
    }
}

fn addSliceAvx2(result: []Vec3, lhs: []const Vec3, rhs: []const Vec3) void {
    if (wide_batch == 0) {
        addSliceScalar(result, lhs, rhs);
        return;
    }

    const lhs_ptr = @as([*]const f32, @ptrCast(lhs.ptr));
    const rhs_ptr = @as([*]const f32, @ptrCast(rhs.ptr));
    const dst_ptr = @as([*]f32, @ptrCast(result.ptr));

    var batch_index: usize = 0;
    const batch_count = result.len / wide_batch;
    const floats_per_batch = ssimd.f32_lane_count;
    while (batch_index < batch_count) : (batch_index += 1) {
        const float_index = batch_index * floats_per_batch;
        const va = ssimd.loadWide(lhs_ptr + float_index);
        const vb = ssimd.loadWide(rhs_ptr + float_index);
        const sum = va + vb;
        ssimd.storeWide(dst_ptr + float_index, sum);

        const base = batch_index * wide_batch;
        var lane: usize = 0;
        while (lane < wide_batch) : (lane += 1) {
            result[base + lane]._pad = 0.0;
        }
    }

    var tail = batch_count * wide_batch;
    while (tail < result.len) : (tail += 1) {
        result[tail] = Vec3.add(lhs[tail], rhs[tail]);
    }
}

pub fn addMulSlice(
    result: []Vec3,
    acc: []const Vec3,
    mul_a: []const Vec3,
    mul_b: []const Vec3,
) void {
    std.debug.assert(result.len == acc.len and acc.len == mul_a.len and mul_a.len == mul_b.len);
    if (ssimd.supports_vec3_batches and result.len >= wide_batch and wide_batch != 0) {
        addMulSliceAvx2(result, acc, mul_a, mul_b);
        return;
    }
    addMulSliceScalar(result, acc, mul_a, mul_b);
}

fn addMulSliceScalar(
    result: []Vec3,
    acc: []const Vec3,
    mul_a: []const Vec3,
    mul_b: []const Vec3,
) void {
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec3.add_mul(acc[i], mul_a[i], mul_b[i]);
    }
}

fn addMulSliceAvx2(
    result: []Vec3,
    acc: []const Vec3,
    mul_a: []const Vec3,
    mul_b: []const Vec3,
) void {
    if (wide_batch == 0) {
        addMulSliceScalar(result, acc, mul_a, mul_b);
        return;
    }

    const acc_ptr = @as([*]const f32, @ptrCast(acc.ptr));
    const mul_a_ptr = @as([*]const f32, @ptrCast(mul_a.ptr));
    const mul_b_ptr = @as([*]const f32, @ptrCast(mul_b.ptr));
    const dst_ptr = @as([*]f32, @ptrCast(result.ptr));

    var batch_index: usize = 0;
    const batch_count = result.len / wide_batch;
    const floats_per_batch = ssimd.f32_lane_count;
    while (batch_index < batch_count) : (batch_index += 1) {
        const float_index = batch_index * floats_per_batch;
        const va = ssimd.loadWide(acc_ptr + float_index);
        const vb = ssimd.loadWide(mul_a_ptr + float_index);
        const vc = ssimd.loadWide(mul_b_ptr + float_index);
        const fused = ssimd.fmaddWide(va, vb, vc);
        ssimd.storeWide(dst_ptr + float_index, fused);

        const base = batch_index * wide_batch;
        var lane: usize = 0;
        while (lane < wide_batch) : (lane += 1) {
            result[base + lane]._pad = 0.0;
        }
    }

    var tail = batch_count * wide_batch;
    while (tail < result.len) : (tail += 1) {
        result[tail] = Vec3.add_mul(acc[tail], mul_a[tail], mul_b[tail]);
    }
}

fn addMulSliceVec2Wide(
    result: []Vec2,
    acc: []const Vec2,
    mul_a: []const Vec2,
    mul_b: []const Vec2,
) void {
    if (vec2_batch == 0) {
        var i: usize = 0;
        while (i < result.len) : (i += 1) {
            result[i] = Vec2.add_mul(acc[i], mul_a[i], mul_b[i]);
        }
        return;
    }

    const acc_ptr = @as([*]const f32, @ptrCast(acc.ptr));
    const mul_a_ptr = @as([*]const f32, @ptrCast(mul_a.ptr));
    const mul_b_ptr = @as([*]const f32, @ptrCast(mul_b.ptr));
    const dst_ptr = @as([*]f32, @ptrCast(result.ptr));

    var batch_index: usize = 0;
    const batch_count = result.len / vec2_batch;
    const floats_per_batch = ssimd.f32_lane_count;
    while (batch_index < batch_count) : (batch_index += 1) {
        const float_index = batch_index * floats_per_batch;
        const va = ssimd.loadWide(acc_ptr + float_index);
        const vb = ssimd.loadWide(mul_a_ptr + float_index);
        const vc = ssimd.loadWide(mul_b_ptr + float_index);
        const fused = ssimd.fmaddWide(va, vb, vc);
        ssimd.storeWide(dst_ptr + float_index, fused);
    }

    var tail = batch_count * vec2_batch;
    while (tail < result.len) : (tail += 1) {
        result[tail] = Vec2.add_mul(acc[tail], mul_a[tail], mul_b[tail]);
    }
}

fn addMulSliceVec4Wide(
    result: []Vec4,
    acc: []const Vec4,
    mul_a: []const Vec4,
    mul_b: []const Vec4,
) void {
    if (vec4_batch == 0) {
        var i: usize = 0;
        while (i < result.len) : (i += 1) {
            result[i] = Vec4.add_mul(acc[i], mul_a[i], mul_b[i]);
        }
        return;
    }

    const acc_ptr = @as([*]const f32, @ptrCast(acc.ptr));
    const mul_a_ptr = @as([*]const f32, @ptrCast(mul_a.ptr));
    const mul_b_ptr = @as([*]const f32, @ptrCast(mul_b.ptr));
    const dst_ptr = @as([*]f32, @ptrCast(result.ptr));

    var batch_index: usize = 0;
    const batch_count = result.len / vec4_batch;
    const floats_per_batch = ssimd.f32_lane_count;
    while (batch_index < batch_count) : (batch_index += 1) {
        const float_index = batch_index * floats_per_batch;
        const va = ssimd.loadWide(acc_ptr + float_index);
        const vb = ssimd.loadWide(mul_a_ptr + float_index);
        const vc = ssimd.loadWide(mul_b_ptr + float_index);
        const fused = ssimd.fmaddWide(va, vb, vc);
        ssimd.storeWide(dst_ptr + float_index, fused);
    }

    var tail = batch_count * vec4_batch;
    while (tail < result.len) : (tail += 1) {
        result[tail] = Vec4.add_mul(acc[tail], mul_a[tail], mul_b[tail]);
    }
}
