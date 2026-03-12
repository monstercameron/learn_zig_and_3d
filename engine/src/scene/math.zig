//! Math module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    /// Constructs and returns a new value initialized from the provided fields.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    /// Returns the component-wise sum of the provided inputs.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    /// Returns the component-wise difference of the provided inputs.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    /// Scales the input by the provided scalar factor and returns the result.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    /// Computes and returns the dot product of the input vectors.
    /// It provides deterministic utility math used by multiple rendering and simulation call-sites.
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
};
