const std = @import("std");
const cpu_features = @import("../core/cpu_features.zig");
const math = @import("../core/math.zig");

pub fn clampByte(value: i32) u8 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return @intCast(value);
}

pub fn fastScale255(value: u32, factor: u32) u8 {
    const scaled = ((value * factor) + 128) * 257;
    return @intCast(@min(scaled >> 16, 255));
}

pub fn runtimeColorGradeSimdLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512 => 32,
        .avx2 => 16,
        .sse2, .neon => 8,
        .scalar => 1,
    };
}

pub fn nanosecondsToMs(elapsed_ns: i128) f32 {
    return @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
}

pub fn validSceneCameraSample(camera_pos: math.Vec3, near_clip: f32) bool {
    return std.math.isFinite(camera_pos.x) and
        std.math.isFinite(camera_pos.y) and
        std.math.isFinite(camera_pos.z) and
        camera_pos.z > near_clip;
}

pub fn sampleSceneCameraClamped(scene_camera: []const math.Vec3, width: usize, height: usize, x: i32, y: i32) math.Vec3 {
    const sx = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(width)) - 1, x))));
    const sy = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(height)) - 1, y))));
    return scene_camera[sy * width + sx];
}

pub fn estimateSceneNormal(scene_camera: []const math.Vec3, width: usize, height: usize, center: math.Vec3, x: i32, y: i32, step: i32, near_clip: f32) math.Vec3 {
    const left = sampleSceneCameraClamped(scene_camera, width, height, x - step, y);
    const right = sampleSceneCameraClamped(scene_camera, width, height, x + step, y);
    const up = sampleSceneCameraClamped(scene_camera, width, height, x, y - step);
    const down = sampleSceneCameraClamped(scene_camera, width, height, x, y + step);

    const tangent_x = if (validSceneCameraSample(left, near_clip) and validSceneCameraSample(right, near_clip))
        math.Vec3.sub(right, left)
    else if (validSceneCameraSample(right, near_clip))
        math.Vec3.sub(right, center)
    else if (validSceneCameraSample(left, near_clip))
        math.Vec3.sub(center, left)
    else
        math.Vec3.new(0.0, 0.0, 0.0);

    const tangent_y = if (validSceneCameraSample(up, near_clip) and validSceneCameraSample(down, near_clip))
        math.Vec3.sub(down, up)
    else if (validSceneCameraSample(down, near_clip))
        math.Vec3.sub(down, center)
    else if (validSceneCameraSample(up, near_clip))
        math.Vec3.sub(center, up)
    else
        math.Vec3.new(0.0, 0.0, 0.0);

    var normal = math.Vec3.cross(tangent_x, tangent_y);
    if (math.Vec3.length(normal) <= 1e-4) {
        normal = math.Vec3.scale(center, -1.0);
        if (math.Vec3.length(normal) <= 1e-4) return math.Vec3.new(0.0, 0.0, -1.0);
    }

    normal = math.Vec3.normalize(normal);
    if (math.Vec3.dot(normal, center) > 0.0) {
        normal = math.Vec3.scale(normal, -1.0);
    }
    return normal;
}

pub fn chooseShadowBasis(light_dir_world: math.Vec3) struct { right: math.Vec3, up: math.Vec3, forward: math.Vec3 } {
    const forward = math.Vec3.normalize(math.Vec3.scale(light_dir_world, -1.0));
    const world_up = if (@abs(forward.y) > 0.98)
        math.Vec3.new(1.0, 0.0, 0.0)
    else
        math.Vec3.new(0.0, 1.0, 0.0);
    const right = math.Vec3.normalize(math.Vec3.cross(world_up, forward));
    const up = math.Vec3.normalize(math.Vec3.cross(forward, right));
    return .{ .right = right, .up = up, .forward = forward };
}

pub fn cameraToWorldPosition(
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    camera_pos: math.Vec3,
) math.Vec3 {
    return math.Vec3.add(
        camera_position,
        math.Vec3.add(
            math.Vec3.add(
                math.Vec3.scale(basis_right, camera_pos.x),
                math.Vec3.scale(basis_up, camera_pos.y),
            ),
            math.Vec3.scale(basis_forward, camera_pos.z),
        ),
    );
}

pub fn projectCameraPositionFloat(position: math.Vec3, projection: anytype, near_epsilon: f32) math.Vec2 {
    const clamped_z = if (position.z < projection.near_plane + near_epsilon)
        projection.near_plane + near_epsilon
    else
        position.z;
    const inv_z = 1.0 / clamped_z;
    const ndc_x = position.x * inv_z * projection.x_scale;
    const ndc_y = position.y * inv_z * projection.y_scale;
    return .{
        .x = ndc_x * projection.center_x + projection.center_x + projection.jitter_x,
        .y = -ndc_y * projection.center_y + projection.center_y + projection.jitter_y,
    };
}

pub fn darkenPackedColor(pixel: u32, scale: f32) u32 {
    const alpha = pixel & 0xFF000000;
    const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * scale));
    const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * scale));
    const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * scale));
    return alpha |
        (@as(u32, clampByte(r)) << 16) |
        (@as(u32, clampByte(g)) << 8) |
        @as(u32, clampByte(b));
}

pub fn darkenPixelSpan(pixels: []u32, start_index: usize, end_index: usize, scale: f32) void {
    for (start_index..end_index) |idx| {
        pixels[idx] = darkenPackedColor(pixels[idx], scale);
    }
}
