const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
    _pad: f32 = 0.0,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z, ._pad = 0.0 };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(a.x + b.x, a.y + b.y, a.z + b.z);
    }

    pub fn add_mul(a: Vec3, b: Vec3, c: Vec3) Vec3 {
        return Vec3.new(
            a.x + b.x * c.x,
            a.y + b.y * c.y,
            a.z + b.z * c.z,
        );
    }
};

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn new(x: f32, y: f32) Vec2 {
        return Vec2{ .x = x, .y = y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return Vec2.new(a.x + b.x, a.y + b.y);
    }

    pub fn add_mul(a: Vec2, b: Vec2, c: Vec2) Vec2 {
        return Vec2.new(
            a.x + b.x * c.x,
            a.y + b.y * c.y,
        );
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

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return Vec4.new(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w);
    }

    pub fn add_mul(a: Vec4, b: Vec4, c: Vec4) Vec4 {
        return Vec4.new(
            a.x + b.x * c.x,
            a.y + b.y * c.y,
            a.z + b.z * c.z,
            a.w + b.w * c.w,
        );
    }
};

pub fn addSliceVec2(result: []Vec2, lhs: []const Vec2, rhs: []const Vec2) void {
    std.debug.assert(result.len == lhs.len and lhs.len == rhs.len);
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
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec2.add_mul(acc[i], mul_a[i], mul_b[i]);
    }
}

pub fn addSliceVec4(result: []Vec4, lhs: []const Vec4, rhs: []const Vec4) void {
    std.debug.assert(result.len == lhs.len and lhs.len == rhs.len);
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
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec4.add_mul(acc[i], mul_a[i], mul_b[i]);
    }
}

pub fn addSlice(result: []Vec3, lhs: []const Vec3, rhs: []const Vec3) void {
    std.debug.assert(result.len == lhs.len and lhs.len == rhs.len);
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec3.add(lhs[i], rhs[i]);
    }
}

pub fn addMulSlice(
    result: []Vec3,
    acc: []const Vec3,
    mul_a: []const Vec3,
    mul_b: []const Vec3,
) void {
    std.debug.assert(result.len == acc.len and acc.len == mul_a.len and mul_a.len == mul_b.len);
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        result[i] = Vec3.add_mul(acc[i], mul_a[i], mul_b[i]);
    }
}
