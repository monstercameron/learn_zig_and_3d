const std = @import("std");
const zphysics = @import("zphysics");
const scene_math = @import("math.zig");
const components_module = @import("components.zig");
pub fn mulComponents(a: scene_math.Vec3, b: scene_math.Vec3) scene_math.Vec3 {
    return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
}

pub fn absComponents(v: scene_math.Vec3) scene_math.Vec3 {
    return .{ .x = @abs(v.x), .y = @abs(v.y), .z = @abs(v.z) };
}

pub fn rotateVector(v: scene_math.Vec3, rotation_deg: scene_math.Vec3) scene_math.Vec3 {
    const rad_scale = std.math.pi / 180.0;
    const rx = rotation_deg.x * rad_scale;
    const ry = rotation_deg.y * rad_scale;
    const rz = rotation_deg.z * rad_scale;

    const sx = @sin(rx);
    const cx = @cos(rx);
    const sy = @sin(ry);
    const cy = @cos(ry);
    const sz = @sin(rz);
    const cz = @cos(rz);

    const x1 = v.x;
    const y1 = v.y * cx - v.z * sx;
    const z1 = v.y * sx + v.z * cx;

    const x2 = x1 * cy + z1 * sy;
    const y2 = y1;
    const z2 = -x1 * sy + z1 * cy;

    return .{
        .x = x2 * cz - y2 * sz,
        .y = x2 * sz + y2 * cz,
        .z = z2,
    };
}

pub fn eulerDegreesToQuaternion(rotation_deg: scene_math.Vec3) [4]zphysics.Real {
    const half_to_rad = std.math.pi / 360.0;
    const hx = rotation_deg.x * half_to_rad;
    const hy = rotation_deg.y * half_to_rad;
    const hz = rotation_deg.z * half_to_rad;

    const sx = @sin(hx);
    const cx = @cos(hx);
    const sy = @sin(hy);
    const cy = @cos(hy);
    const sz = @sin(hz);
    const cz = @cos(hz);

    return .{
        @as(zphysics.Real, @floatCast(sx * cy * cz - cx * sy * sz)),
        @as(zphysics.Real, @floatCast(cx * sy * cz + sx * cy * sz)),
        @as(zphysics.Real, @floatCast(cx * cy * sz - sx * sy * cz)),
        @as(zphysics.Real, @floatCast(cx * cy * cz + sx * sy * sz)),
    };
}

pub fn rotationMatrixToEulerDegrees(rotation: [9]zphysics.Real) scene_math.Vec3 {
    const m00 = @as(f32, @floatCast(rotation[0]));
    const m10 = @as(f32, @floatCast(rotation[1]));
    const m20 = @as(f32, @floatCast(rotation[2]));
    const m21 = @as(f32, @floatCast(rotation[5]));
    const m22 = @as(f32, @floatCast(rotation[8]));
    const rad_to_deg = 180.0 / std.math.pi;
    const yaw = std.math.asin(std.math.clamp(-m20, -1.0, 1.0));
    const pitch = std.math.atan2(m21, m22);
    const roll = std.math.atan2(m10, m00);
    return .{
        .x = pitch * rad_to_deg,
        .y = yaw * rad_to_deg,
        .z = roll * rad_to_deg,
    };
}

pub fn entityTransformToBodyPosition(transform: components_module.TransformWorld, body_to_entity_offset_local: scene_math.Vec3) scene_math.Vec3 {
    return scene_math.Vec3.sub(transform.position, rotateVector(body_to_entity_offset_local, transform.rotation_deg));
}

pub fn composeWorldTransform(parent: components_module.TransformWorld, local: components_module.TransformLocal) components_module.TransformWorld {
    return .{
        .position = scene_math.Vec3.add(parent.position, rotateVector(mulComponents(local.position, parent.scale), parent.rotation_deg)),
        .rotation_deg = scene_math.Vec3.add(parent.rotation_deg, local.rotation_deg),
        .scale = mulComponents(parent.scale, local.scale),
    };
}

pub fn worldTransformsEqual(a: components_module.TransformWorld, b: components_module.TransformWorld) bool {
    return vec3ApproxEq(a.position, b.position) and vec3ApproxEq(a.rotation_deg, b.rotation_deg) and vec3ApproxEq(a.scale, b.scale);
}

pub fn vec3ApproxEq(a: scene_math.Vec3, b: scene_math.Vec3) bool {
    return approxEq(a.x, b.x) and approxEq(a.y, b.y) and approxEq(a.z, b.z);
}

pub fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-4;
}

pub fn worldDeltaToLocal(parent: components_module.TransformWorld, world_delta: scene_math.Vec3) scene_math.Vec3 {
    return divideComponents(inverseRotateVector(world_delta, parent.rotation_deg), parent.scale);
}

pub fn inverseRotateVector(v: scene_math.Vec3, rotation_deg: scene_math.Vec3) scene_math.Vec3 {
    return rotateVector(v, .{
        .x = -rotation_deg.x,
        .y = -rotation_deg.y,
        .z = -rotation_deg.z,
    });
}

pub fn divideComponents(a: scene_math.Vec3, b: scene_math.Vec3) scene_math.Vec3 {
    return .{
        .x = if (@abs(b.x) > 1e-6) a.x / b.x else a.x,
        .y = if (@abs(b.y) > 1e-6) a.y / b.y else a.y,
        .z = if (@abs(b.z) > 1e-6) a.z / b.z else a.z,
    };
}
