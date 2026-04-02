const std = @import("std");
const script_host = @import("../script_host.zig");
const scene_math = @import("../math.zig");
const camera_state = @import("../camera_state.zig");

pub fn applyLook(yaw: *f32, pitch: *f32, look_delta_x: f32, look_delta_y: f32, sensitivity: f32) void {
    yaw.* = camera_state.wrapYaw(yaw.* + look_delta_x * sensitivity);
    pitch.* = camera_state.clampPitch(pitch.* - look_delta_y * sensitivity);
}

pub fn stepEditorCamera(
    camera_position: *scene_math.Vec3,
    yaw: *f32,
    pitch: *f32,
    input_state: *const script_host.ScriptInputState,
    delta_seconds: f32,
    turn_speed: f32,
    move_speed: f32,
    mouse_look_requires_right_button: bool,
    look_sensitivity: f32,
) void {
    const actions = input_state.actions;
    const mouse = input_state.mouse;
    if (!mouse_look_requires_right_button or mouse.isDown(.right)) {
        applyLook(yaw, pitch, input_state.look_delta.x, input_state.look_delta.y, look_sensitivity);
    }
    yaw.* = camera_state.wrapYaw(yaw.* + actions.axis(.turn_left, .turn_right) * turn_speed * delta_seconds);
    pitch.* = camera_state.clampPitch(pitch.* + actions.axis(.turn_up, .turn_down) * turn_speed * delta_seconds);

    const forward = normalize(scene_math.Vec3.new(@sin(yaw.*) * @cos(pitch.*), @sin(pitch.*), @cos(yaw.*) * @cos(pitch.*)));
    var forward_flat = scene_math.Vec3.new(forward.x, 0.0, forward.z);
    if (length(forward_flat) > 1e-4) {
        forward_flat = normalize(forward_flat);
    } else {
        forward_flat = scene_math.Vec3.new(0.0, 0.0, 0.0);
    }
    var right_flat = normalize(scene_math.Vec3.new(forward_flat.z, 0.0, -forward_flat.x));
    if (length(right_flat) <= 1e-4) right_flat = scene_math.Vec3.new(1.0, 0.0, 0.0);

    var movement_dir = scene_math.Vec3.new(0.0, 0.0, 0.0);
    movement_dir = scene_math.Vec3.add(movement_dir, scene_math.Vec3.scale(forward_flat, actions.axis(.move_backward, .move_forward)));
    movement_dir = scene_math.Vec3.add(movement_dir, scene_math.Vec3.scale(right_flat, actions.axis(.move_left, .move_right)));
    movement_dir = scene_math.Vec3.add(movement_dir, scene_math.Vec3.new(0.0, actions.axis(.move_down, .move_up), 0.0));

    if (length(movement_dir) > 1e-4) {
        const move_step = scene_math.Vec3.scale(normalize(movement_dir), move_speed * delta_seconds);
        camera_position.* = scene_math.Vec3.add(camera_position.*, move_step);
    }
}

pub fn stepPlayerBody(
    state: anytype,
    camera_position: *scene_math.Vec3,
    yaw: f32,
    pitch: f32,
    input_state: *const script_host.ScriptInputState,
    delta_seconds: f32,
    body_max_step_s: f32,
    floor_y: f32,
    eye_height: f32,
    jump_recycle_seconds: f32,
) void {
    var remaining_dt = std.math.clamp(delta_seconds, 0.0, 0.25);
    while (remaining_dt > 1e-6) {
        const dt = @min(remaining_dt, body_max_step_s);
        stepPlayerBodySubstep(state, camera_position, yaw, pitch, input_state, dt, floor_y, eye_height, jump_recycle_seconds);
        remaining_dt -= dt;
    }
}

fn stepPlayerBodySubstep(
    state: anytype,
    camera_position: *scene_math.Vec3,
    yaw: f32,
    pitch: f32,
    input_state: *const script_host.ScriptInputState,
    dt: f32,
    floor_y: f32,
    eye_height: f32,
    jump_recycle_seconds: f32,
) void {
    const actions = input_state.actions;
    state.jump_recycle_remaining_s = @max(0.0, state.jump_recycle_remaining_s - dt);

    var forward_flat = normalize(scene_math.Vec3.new(@sin(yaw) * @cos(pitch), 0.0, @cos(yaw) * @cos(pitch)));
    if (length(forward_flat) <= 1e-4) forward_flat = scene_math.Vec3.new(0.0, 0.0, 0.0);
    var right_flat = normalize(scene_math.Vec3.new(forward_flat.z, 0.0, -forward_flat.x));
    if (length(right_flat) <= 1e-4) right_flat = scene_math.Vec3.new(1.0, 0.0, 0.0);

    var move_dir = scene_math.Vec3.new(0.0, 0.0, 0.0);
    move_dir = scene_math.Vec3.add(move_dir, scene_math.Vec3.scale(forward_flat, actions.axis(.move_backward, .move_forward)));
    move_dir = scene_math.Vec3.add(move_dir, scene_math.Vec3.scale(right_flat, actions.axis(.move_left, .move_right)));

    const desired_flat_velocity = if (length(move_dir) > 1e-4)
        scene_math.Vec3.scale(normalize(move_dir), 6.0)
    else
        scene_math.Vec3.new(0.0, 0.0, 0.0);
    const accel_rate: f32 = if (state.grounded) 42.0 else 12.0;
    const accel_blend = 1.0 - @exp(-accel_rate * dt);
    state.velocity.x += (desired_flat_velocity.x - state.velocity.x) * accel_blend;
    state.velocity.z += (desired_flat_velocity.z - state.velocity.z) * accel_blend;

    const jump_down = actions.isDown(.jump);
    const jump_pressed = jump_down and !state.jump_was_down;
    state.jump_was_down = jump_down;
    const was_grounded = state.grounded;
    if (state.grounded and jump_pressed and state.jump_recycle_remaining_s <= 0.0) {
        state.velocity.y = 6.0;
        state.grounded = false;
        state.jump_cycle_active = true;
    }

    state.velocity.y -= 28.0 * dt;
    camera_position.* = scene_math.Vec3.add(camera_position.*, scene_math.Vec3.scale(state.velocity, dt));

    const floor_eye_y = floor_y + eye_height;
    if (camera_position.y <= floor_eye_y) {
        camera_position.y = floor_eye_y;
        if (state.velocity.y < 0.0) state.velocity.y = 0.0;
        state.grounded = true;
        if (!was_grounded and state.jump_cycle_active) {
            state.jump_cycle_active = false;
            state.jump_recycle_remaining_s = jump_recycle_seconds;
        }
    } else {
        state.grounded = false;
    }
}

pub fn normalize(vec: scene_math.Vec3) scene_math.Vec3 {
    const len = length(vec);
    if (len <= 1e-6) return scene_math.Vec3.new(0.0, 0.0, 0.0);
    return scene_math.Vec3.scale(vec, 1.0 / len);
}

pub fn length(vec: scene_math.Vec3) f32 {
    return @sqrt(scene_math.Vec3.dot(vec, vec));
}

pub fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-4;
}

pub fn vec3ApproxEq(a: scene_math.Vec3, b: scene_math.Vec3) bool {
    return approxEq(a.x, b.x) and approxEq(a.y, b.y) and approxEq(a.z, b.z);
}
