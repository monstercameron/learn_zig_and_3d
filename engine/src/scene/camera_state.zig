const std = @import("std");
const math = @import("math.zig");
const fov_min: f32 = 20.0;
const fov_max: f32 = 120.0;

pub const default_fov_deg: f32 = 60.0;
pub const max_pitch: f32 = 1.5;

pub const State = struct {
    position: math.Vec3,
    pitch: f32,
    yaw: f32,
    fov_deg: f32,

    pub fn normalized(self: State) State {
        return .{
            .position = self.position,
            .pitch = clampPitch(self.pitch),
            .yaw = wrapYaw(self.yaw),
            .fov_deg = normalizeFov(self.fov_deg),
        };
    }
};

pub fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -max_pitch, max_pitch);
}

pub fn wrapYaw(yaw: f32) f32 {
    return std.math.atan2(@sin(yaw), @cos(yaw));
}

pub fn normalizeFov(fov_deg: f32) f32 {
    return std.math.clamp(fov_deg, fov_min, fov_max);
}
