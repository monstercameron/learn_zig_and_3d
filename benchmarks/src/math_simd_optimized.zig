const std = @import("std");
const ssimd = @import("ssimd.zig");

const Vec3SimdWidth: comptime_int = ssimd.f32_lane_count;
const Vec3SimdType = ssimd.WideVec;
const Vec4f = ssimd.Vec4f;

comptime {
    if (Vec3SimdWidth < 4 or Vec3SimdWidth % 4 != 0) {
        @compileError("ssimd Vec3 requires at least four lanes");
    }
}

/// A 3D vector of single-precision floats.
/// Can represent a point in 3D space or a direction/vector.
pub const Vec3 = struct {
    data: Vec3SimdType,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        var vec: Vec3SimdType = undefined;
        vec[0] = x;
        vec[1] = y;
        vec[2] = z;
        // Pad remaining elements with 0.0
        var i: usize = 3;
        while (i < Vec3SimdWidth) : (i += 1) {
            vec[i] = 0.0;
        }
        return Vec3{ .data = vec };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3{ .data = a.data + b.data };
    }

    pub fn add_mul(a: Vec3, b: Vec3, c: Vec3) Vec3 {
        return Vec3{ .data = ssimd.fmaddWide(a.data, b.data, c.data) };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return Vec3{ .data = a.data - b.data };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return Vec3{ .data = v.data * @splat(Vec3SimdType, s) };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return ssimd.reduceAddWide(a.data * b.data);
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        const a_yzx = ssimd.permuteVec3Wide(a.data, .{ 1, 2, 0 });
        const a_zxy = ssimd.permuteVec3Wide(a.data, .{ 2, 0, 1 });
        const b_yzx = ssimd.permuteVec3Wide(b.data, .{ 1, 2, 0 });
        const b_zxy = ssimd.permuteVec3Wide(b.data, .{ 2, 0, 1 });
        return Vec3{ .data = (a_yzx * b_zxy) - (a_zxy * b_yzx) };
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.dot(v));
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len == 0) return Vec3.new(0, 0, 0);
        return Vec3.scale(v, 1.0 / len);
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
    pub fn new(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return Vec4{ .x = x, .y = y, .z = z, .w = w };
    }
    pub fn from3D(v: Vec3) Vec4 {
        return Vec4{ .x = v.data[0], .y = v.data[1], .z = v.data[2], .w = 1.0 };
    }
    pub fn to3D(v: Vec4) Vec3 {
        if (v.w == 0) return Vec3.new(v.x, v.y, v.z);
        const inv_w = 1.0 / v.w;
        return Vec3.new(v.x * inv_w, v.y * inv_w, v.z * inv_w);
    }

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return Vec4.new(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w);
    }

    pub fn add_mul(a: Vec4, b: Vec4, c: Vec4) Vec4 {
        const va = Vec4f{ a.x, a.y, a.z, a.w };
        const vb = Vec4f{ b.x, b.y, b.z, b.w };
        const vc = Vec4f{ c.x, c.y, c.z, c.w };
        const fused = if (ssimd.has_fma)
            @mulAdd(Vec4f, vb, vc, va)
        else
            va + vb * vc;
        return Vec4.new(fused[0], fused[1], fused[2], fused[3]);
    }

    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return Vec4.new(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w);
    }

    pub fn scale(v: Vec4, s: f32) Vec4 {
        return Vec4.new(v.x * s, v.y * s, v.z * s, v.w * s);
    }

    pub fn dot(a: Vec4, b: Vec4) f32 {
        const va = Vec4f{ a.x, a.y, a.z, a.w };
        const vb = Vec4f{ b.x, b.y, b.z, b.w };
        return ssimd.dot4(va, vb);
    }

    pub fn length(v: Vec4) f32 {
        return @sqrt(Vec4.dot(v, v));
    }

    pub fn normalize(v: Vec4) Vec4 {
        const len = v.length();
        if (len == 0) return Vec4.new(0, 0, 0, 0);
        return Vec4.scale(v, 1.0 / len);
    }
};

pub const Mat4 = struct {
    data: [16]f32,
    pub fn identity() Mat4 {
        return Mat4{ .data = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
    }
    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        const vec = Vec4f{ v.x, v.y, v.z, v.w };
        return Vec4.new(
            ssimd.dot4(rowVec(m, 0), vec),
            ssimd.dot4(rowVec(m, 1), vec),
            ssimd.dot4(rowVec(m, 2), vec),
            ssimd.dot4(rowVec(m, 3), vec),
        );
    }
    pub fn mulVec3(m: Mat4, v: Vec3) Vec3 {
        const v4 = Vec4.from3D(v);
        const result = m.mulVec4(v4);
        return result.to3D();
    }
    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = std.mem.zeroes(Mat4);
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            const row_vec = rowVec(a, row);
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                result.data[row * 4 + col] = ssimd.dot4(row_vec, columnVec(b, col));
            }
        }
        return result;
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
