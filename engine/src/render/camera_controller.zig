const std = @import("std");
const windows = std.os.windows;
const math = @import("../core/math.zig");
const config = @import("../core/app_config.zig");

pub const ControlMode = enum(u8) {
    first_person = 0,
    editor = 1,
};

pub const MouseState = struct {
    sensitivity: f32 = 0.0075,
    pending_delta: math.Vec2 = math.Vec2.new(0.0, 0.0),
    smoothed_delta: math.Vec2 = math.Vec2.new(0.0, 0.0),
    initialized: bool = false,
    last_pos: windows.POINT = .{ .x = 0, .y = 0 },
    ignore_next_move: bool = false,
};

pub const FpsBodyState = struct {
    velocity: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    grounded: bool = false,
    jump_was_down: bool = false,
};

const fps_right_click_zoom_steps: f32 = 8.0;
const fps_zoom_in_duration_s: f32 = 0.250;
const fps_zoom_out_duration_s: f32 = 0.100;

pub const FpsZoomState = struct {
    hold_active: bool = false,
    base_fov_deg: f32 = 60.0,
    anim_active: bool = false,
    anim_from_fov: f32 = 0.0,
    anim_to_fov: f32 = 0.0,
    anim_elapsed_s: f32 = 0.0,
    anim_duration_s: f32 = 0.0,
};

pub const ViewBasis = struct {
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
};

pub const ProjectionScalars = struct {
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
};

pub const FpsMoveInput = struct {
    move_forward: bool = false,
    move_back: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    jump_down: bool = false,
};

pub const FpsStepParams = struct {
    dt: f32,
    move_speed: f32,
    accel_ground: f32 = 42.0,
    accel_air: f32 = 12.0,
    gravity: f32 = 28.0,
    jump_speed: f32 = 6.0,
    floor_y: f32 = 0.0,
    eye_height: f32 = 1.6,
};

pub fn noteMouseWarp(state: *MouseState, client_x: i32, client_y: i32) void {
    state.last_pos = .{ .x = client_x, .y = client_y };
    state.initialized = true;
    state.ignore_next_move = true;
}

pub fn resetForModeToggle(state: *MouseState) void {
    state.pending_delta = math.Vec2.new(0.0, 0.0);
    state.smoothed_delta = math.Vec2.new(0.0, 0.0);
    state.initialized = false;
    state.ignore_next_move = false;
}

pub fn resetFpsBody(state: *FpsBodyState, camera_position: math.Vec3, floor_y: f32, eye_height: f32) void {
    state.velocity = math.Vec3.new(0.0, 0.0, 0.0);
    state.grounded = camera_position.y <= floor_y + eye_height + 1e-4;
    state.jump_was_down = false;
}

pub fn setJumpHeldState(state: *FpsBodyState, jump_down: bool) void {
    state.jump_was_down = jump_down;
}

fn clampFov(fov_deg: f32) f32 {
    return std.math.clamp(fov_deg, config.CAMERA_FOV_MIN, config.CAMERA_FOV_MAX);
}

fn startZoomAnimation(state: *FpsZoomState, current_fov_deg: f32, target_fov_deg: f32, duration_s: f32) void {
    state.anim_from_fov = current_fov_deg;
    state.anim_to_fov = clampFov(target_fov_deg);
    state.anim_elapsed_s = 0.0;
    state.anim_duration_s = @max(duration_s, 0.001);
    state.anim_active = true;
}

pub fn onEnterFirstPerson(state: *FpsZoomState, current_fov_deg: f32) void {
    state.base_fov_deg = current_fov_deg;
}

pub fn beginRightClickZoom(state: *FpsZoomState, current_fov_deg: f32) void {
    if (state.hold_active) return;
    state.hold_active = true;
    state.base_fov_deg = current_fov_deg;
    const zoom_delta = config.CAMERA_FOV_STEP * fps_right_click_zoom_steps;
    startZoomAnimation(state, current_fov_deg, state.base_fov_deg - zoom_delta, fps_zoom_in_duration_s);
}

pub fn endRightClickZoom(state: *FpsZoomState, current_fov_deg: f32) void {
    if (!state.hold_active) return;
    state.hold_active = false;
    startZoomAnimation(state, current_fov_deg, state.base_fov_deg, fps_zoom_out_duration_s);
}

pub fn cancelRightClickZoom(state: *FpsZoomState, camera_fov_deg: *f32, restore_fov: bool) void {
    state.hold_active = false;
    state.anim_active = false;
    if (restore_fov) {
        camera_fov_deg.* = clampFov(state.base_fov_deg);
    }
}

pub fn updateRightClickZoom(state: *FpsZoomState, camera_fov_deg: *f32, dt_s: f32) void {
    if (!state.anim_active) return;
    if (dt_s <= 0.0) return;
    state.anim_elapsed_s += dt_s;
    const t = std.math.clamp(state.anim_elapsed_s / state.anim_duration_s, 0.0, 1.0);
    const ease = t * t * (3.0 - 2.0 * t); // smoothstep
    const fov = state.anim_from_fov + (state.anim_to_fov - state.anim_from_fov) * ease;
    camera_fov_deg.* = clampFov(fov);
    if (t >= 1.0) state.anim_active = false;
}

pub fn isRightClickZoomHeld(state: *const FpsZoomState) bool {
    return state.hold_active;
}

pub fn nextRawDelta(state: *MouseState, x: i32, y: i32) ?math.Vec2 {
    const current = windows.POINT{ .x = x, .y = y };
    if (!state.initialized) {
        state.last_pos = current;
        state.initialized = true;
        return null;
    }
    if (state.ignore_next_move) {
        state.last_pos = current;
        state.ignore_next_move = false;
        return null;
    }

    const dx = @as(f32, @floatFromInt(current.x - state.last_pos.x));
    const dy = @as(f32, @floatFromInt(current.y - state.last_pos.y));
    state.last_pos = current;
    // Drop obvious cursor-warp artifacts that occasionally leak through recenter ignore.
    if (@abs(dx) > 200.0 or @abs(dy) > 200.0) return null;
    return math.Vec2.new(dx, dy);
}

pub fn accumulateFirstPersonDelta(state: *MouseState, raw_delta: math.Vec2) void {
    const clamped_dx = std.math.clamp(raw_delta.x, -128.0, 128.0);
    const clamped_dy = std.math.clamp(raw_delta.y, -128.0, 128.0);
    state.pending_delta = math.Vec2.new(
        state.pending_delta.x + clamped_dx,
        state.pending_delta.y + clamped_dy,
    );
}

pub fn consumeLookDelta(state: *MouseState, mode: ControlMode, frame_dt_seconds: f32) math.Vec2 {
    const delta = state.pending_delta;
    state.pending_delta = math.Vec2.new(0.0, 0.0);
    if (mode != .first_person) {
        state.smoothed_delta = math.Vec2.new(0.0, 0.0);
        return delta;
    }

    const smoothing_60hz = std.math.clamp(config.CAMERA_MOUSE_SMOOTHING, 0.0, 0.95);
    if (smoothing_60hz <= 0.0) {
        state.smoothed_delta = delta;
        return delta;
    }

    // Integrate a filtered pixel-velocity so look motion stays smooth as frame/input cadence changes.
    const dt = std.math.clamp(frame_dt_seconds, 1.0 / 240.0, 1.0 / 15.0);
    const response_hz = 8.0 + (1.0 - smoothing_60hz) * 72.0;
    const blend = 1.0 - @exp(-response_hz * dt);
    const target_vel = math.Vec2.new(delta.x / dt, delta.y / dt);
    state.smoothed_delta = math.Vec2.new(
        state.smoothed_delta.x + (target_vel.x - state.smoothed_delta.x) * blend,
        state.smoothed_delta.y + (target_vel.y - state.smoothed_delta.y) * blend,
    );
    const out = math.Vec2.new(state.smoothed_delta.x * dt, state.smoothed_delta.y * dt);
    if (@abs(delta.x) < 1e-4 and @abs(state.smoothed_delta.x) < 0.05) state.smoothed_delta.x = 0.0;
    if (@abs(delta.y) < 1e-4 and @abs(state.smoothed_delta.y) < 0.05) state.smoothed_delta.y = 0.0;
    return out;
}

pub fn effectiveSensitivity(state: *const MouseState) f32 {
    const base = std.math.clamp(state.sensitivity, 0.0001, 0.05);
    const dpi_scale = std.math.clamp(config.CAMERA_MOUSE_DPI_SCALE, 0.1, 8.0);
    return base * dpi_scale;
}

pub fn stepFpsBody(
    body: *FpsBodyState,
    camera_position: *math.Vec3,
    basis: ViewBasis,
    input_state: FpsMoveInput,
    params: FpsStepParams,
) void {
    const dt = std.math.clamp(params.dt, 0.0, 1.0 / 20.0);
    if (dt <= 0.0) return;

    var forward_flat = math.Vec3.new(basis.forward.x, 0.0, basis.forward.z);
    const forward_flat_len = math.Vec3.length(forward_flat);
    if (forward_flat_len > 0.0001) {
        forward_flat = math.Vec3.scale(forward_flat, 1.0 / forward_flat_len);
    } else {
        forward_flat = math.Vec3.new(0.0, 0.0, 0.0);
    }

    var right_flat = math.Vec3.new(basis.right.x, 0.0, basis.right.z);
    const right_flat_len = math.Vec3.length(right_flat);
    if (right_flat_len > 0.0001) {
        right_flat = math.Vec3.scale(right_flat, 1.0 / right_flat_len);
    } else {
        right_flat = math.Vec3.new(0.0, 0.0, 0.0);
    }

    var move_dir = math.Vec3.new(0.0, 0.0, 0.0);
    if (input_state.move_forward) move_dir = math.Vec3.add(move_dir, forward_flat);
    if (input_state.move_back) move_dir = math.Vec3.sub(move_dir, forward_flat);
    if (input_state.move_right) move_dir = math.Vec3.add(move_dir, right_flat);
    if (input_state.move_left) move_dir = math.Vec3.sub(move_dir, right_flat);

    const move_mag = math.Vec3.length(move_dir);
    const desired_flat_velocity = if (move_mag > 0.0001)
        math.Vec3.scale(math.Vec3.scale(move_dir, 1.0 / move_mag), params.move_speed)
    else
        math.Vec3.new(0.0, 0.0, 0.0);
    const accel_rate = if (body.grounded) params.accel_ground else params.accel_air;
    const accel_blend = 1.0 - @exp(-accel_rate * dt);
    body.velocity.x += (desired_flat_velocity.x - body.velocity.x) * accel_blend;
    body.velocity.z += (desired_flat_velocity.z - body.velocity.z) * accel_blend;

    const jump_pressed = input_state.jump_down and !body.jump_was_down;
    body.jump_was_down = input_state.jump_down;
    if (body.grounded and jump_pressed) {
        body.velocity.y = params.jump_speed;
        body.grounded = false;
    }

    body.velocity.y -= params.gravity * dt;
    camera_position.* = math.Vec3.add(camera_position.*, math.Vec3.scale(body.velocity, dt));

    const floor_eye_y = params.floor_y + params.eye_height;
    if (camera_position.y <= floor_eye_y) {
        camera_position.y = floor_eye_y;
        if (body.velocity.y < 0.0) body.velocity.y = 0.0;
        body.grounded = true;
    } else {
        body.grounded = false;
    }
}

pub fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -1.5, 1.5);
}

pub fn applyFirstPersonLook(yaw: *f32, pitch: *f32, look_delta: math.Vec2, sensitivity: f32) void {
    yaw.* += look_delta.x * sensitivity;
    pitch.* -= look_delta.y * sensitivity;
    pitch.* = clampPitch(pitch.*);
}

pub fn computeViewBasis(yaw: f32, pitch: f32) ViewBasis {
    const cos_pitch = @cos(pitch);
    const sin_pitch = @sin(pitch);
    const cos_yaw = @cos(yaw);
    const sin_yaw = @sin(yaw);

    var forward = math.Vec3.new(sin_yaw * cos_pitch, sin_pitch, cos_yaw * cos_pitch);
    forward = math.Vec3.normalize(forward);

    const world_up = math.Vec3.new(0.0, 1.0, 0.0);
    var right = math.Vec3.cross(world_up, forward);
    const right_len = math.Vec3.length(right);
    if (right_len < 0.0001) {
        right = math.Vec3.new(1.0, 0.0, 0.0);
    } else {
        right = math.Vec3.scale(right, 1.0 / right_len);
    }

    var up = math.Vec3.cross(forward, right);
    up = math.Vec3.normalize(up);

    return .{
        .right = right,
        .up = up,
        .forward = forward,
    };
}

pub fn computeProjectionScalars(bitmap_width: i32, bitmap_height: i32, fov_deg: f32) ProjectionScalars {
    const width_f = @as(f32, @floatFromInt(bitmap_width));
    const height_f = @as(f32, @floatFromInt(bitmap_height));
    const aspect_ratio = if (height_f > 0.0) width_f / height_f else 1.0;
    const fov_rad = fov_deg * (std.math.pi / 180.0);
    const half_fov = fov_rad * 0.5;
    const tan_half_fov = std.math.tan(half_fov);
    const y_scale = if (tan_half_fov > 0.0) 1.0 / tan_half_fov else 1.0;
    const x_scale = y_scale / aspect_ratio;
    const center_x = width_f * 0.5;
    const center_y = height_f * 0.5;
    return .{
        .center_x = center_x,
        .center_y = center_y,
        .x_scale = x_scale,
        .y_scale = y_scale,
    };
}
