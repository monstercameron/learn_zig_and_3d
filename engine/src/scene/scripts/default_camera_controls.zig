//! Default ECS camera controls for editor and first-person modes.

const std = @import("std");
const script_host = @import("../script_host.zig");
const scene_components = @import("../components.zig");
const scene_math = @import("../math.zig");

pub const module_name = "scene.default.camera_controls";

pub const vtable = script_host.ScriptModuleVTable{
    .on_create = onCreate,
    .on_destroy = onDestroy,
    .on_event = onEvent,
};

const floor_y: f32 = 0.0;
const eye_height: f32 = 1.6;
const look_sensitivity: f32 = 0.0075;
const max_pitch: f32 = 1.5;
const body_max_step_s: f32 = 1.0 / 120.0;
const editor_move_speed: f32 = 6.0;
const editor_turn_speed: f32 = 2.0;
const fov_step: f32 = 1.5;
const jump_recycle_seconds: f32 = 0.5;

const CameraControlState = struct {
    velocity: scene_math.Vec3 = scene_math.Vec3.new(0.0, 0.0, 0.0),
    grounded: bool = false,
    jump_was_down: bool = false,
    toggle_mode_was_down: bool = false,
    jump_cycle_active: bool = false,
    jump_recycle_remaining_s: f32 = 0.0,
    repeat_jump_when_grounded: bool = false,
    initialized: bool = false,
};

fn onCreate(ctx: *script_host.ScriptCallbackContext) void {
    const state = ctx.allocator.create(CameraControlState) catch return;
    state.* = .{};
    ctx.user_data_slot.* = state;
    initializeState(ctx, state);
}

fn onDestroy(ctx: *script_host.ScriptCallbackContext) void {
    const state = getState(ctx) orelse return;
    ctx.allocator.destroy(state);
    ctx.user_data_slot.* = null;
}

fn onEvent(ctx: *script_host.ScriptCallbackContext) void {
    const state = getState(ctx) orelse return;
    switch (ctx.event) {
        .begin_play, .enable => initializeState(ctx, state),
        .update => |delta_seconds| updateCamera(ctx, state, delta_seconds),
        else => {},
    }
}

fn updateCamera(ctx: *script_host.ScriptCallbackContext, state: *CameraControlState, delta_seconds: f32) void {
    initializeState(ctx, state);
    const state_view = getCameraState(ctx) orelse return;
    const keyboard = ctx.input.keyboard;
    var camera_position = state_view.transform.position;
    var pitch = state_view.camera.pitch;
    var yaw = state_view.camera.yaw;

    const toggle_camera_mode_down = keyboard.isDown(.v);
    const toggle_mode_pressed = toggle_camera_mode_down and !state.toggle_mode_was_down;
    state.toggle_mode_was_down = toggle_camera_mode_down;

    if (toggle_mode_pressed) ctx.commands.queueSetCameraMode(.toggle) catch {};
    if (keyboard.wasPressed(.q)) ctx.commands.queueAdjustCameraFov(-fov_step) catch {};
    if (keyboard.wasPressed(.e)) ctx.commands.queueAdjustCameraFov(fov_step) catch {};

    if (ctx.input.first_person_active) {
        applyLook(&yaw, &pitch, ctx.input.look_delta.x, ctx.input.look_delta.y);

        if (!keyboard.isDown(.space)) {
            state.repeat_jump_when_grounded = false;
        } else if (state.grounded and state.repeat_jump_when_grounded and state.jump_recycle_remaining_s <= 0.0) {
            state.jump_was_down = false;
            state.repeat_jump_when_grounded = false;
        }

        stepPlayerBody(state, &camera_position, yaw, pitch, ctx.input, delta_seconds);

        if (keyboard.isDown(.space) and !state.grounded) {
            state.repeat_jump_when_grounded = true;
        }
    } else {
        state.jump_was_down = false;
        state.jump_cycle_active = false;
        state.jump_recycle_remaining_s = 0.0;
        state.repeat_jump_when_grounded = false;
        stepEditorCamera(&camera_position, &yaw, &pitch, ctx.input, delta_seconds);
    }

    const delta = scene_math.Vec3.sub(camera_position, state_view.transform.position);
    if (!vec3ApproxEq(delta, scene_math.Vec3.new(0.0, 0.0, 0.0))) {
        ctx.commands.queueTranslate(ctx.entity, delta) catch {};
    }
    if (!approxEq(pitch, state_view.camera.pitch) or !approxEq(yaw, state_view.camera.yaw)) {
        ctx.commands.queueSetCameraOrientation(ctx.entity, pitch, yaw) catch {};
    }
}

fn initializeState(ctx: *script_host.ScriptCallbackContext, state: *CameraControlState) void {
    if (state.initialized) return;
    const state_view = getCameraState(ctx) orelse return;
    state.velocity = scene_math.Vec3.new(0.0, 0.0, 0.0);
    state.grounded = state_view.transform.position.y <= floor_y + eye_height + 1e-4;
    state.jump_was_down = false;
    state.toggle_mode_was_down = false;
    state.jump_cycle_active = false;
    state.jump_recycle_remaining_s = 0.0;
    state.repeat_jump_when_grounded = false;
    state.initialized = true;
}

fn getCameraState(ctx: *script_host.ScriptCallbackContext) ?struct { transform: scene_components.TransformLocal, camera: scene_components.Camera } {
    const index: usize = @intCast(ctx.entity.index);
    if (index >= ctx.components.local_transforms.items.len or index >= ctx.components.cameras.items.len) return null;
    const transform = ctx.components.local_transforms.items[index] orelse return null;
    const camera = ctx.components.cameras.items[index] orelse return null;
    return .{ .transform = transform, .camera = camera };
}

fn getState(ctx: *script_host.ScriptCallbackContext) ?*CameraControlState {
    const user_data = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(user_data));
}

fn stepEditorCamera(camera_position: *scene_math.Vec3, yaw: *f32, pitch: *f32, input_state: *const script_host.ScriptInputState, delta_seconds: f32) void {
    const keyboard = input_state.keyboard;
    const mouse = input_state.mouse;
    if (mouse.isDown(.right)) {
        applyLook(yaw, pitch, input_state.look_delta.x, input_state.look_delta.y);
    }
    if (keyboard.isDown(.left)) yaw.* -= editor_turn_speed * delta_seconds;
    if (keyboard.isDown(.right)) yaw.* += editor_turn_speed * delta_seconds;
    if (keyboard.isDown(.up)) pitch.* -= editor_turn_speed * delta_seconds;
    if (keyboard.isDown(.down)) pitch.* += editor_turn_speed * delta_seconds;
    pitch.* = std.math.clamp(pitch.*, -max_pitch, max_pitch);

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
    if (keyboard.isDown(.w)) movement_dir = scene_math.Vec3.add(movement_dir, forward_flat);
    if (keyboard.isDown(.s)) movement_dir = scene_math.Vec3.sub(movement_dir, forward_flat);
    if (keyboard.isDown(.d)) movement_dir = scene_math.Vec3.add(movement_dir, right_flat);
    if (keyboard.isDown(.a)) movement_dir = scene_math.Vec3.sub(movement_dir, right_flat);
    if (keyboard.isDown(.space)) movement_dir = scene_math.Vec3.add(movement_dir, scene_math.Vec3.new(0.0, 1.0, 0.0));
    if (keyboard.isDown(.ctrl)) movement_dir = scene_math.Vec3.sub(movement_dir, scene_math.Vec3.new(0.0, 1.0, 0.0));

    if (length(movement_dir) > 1e-4) {
        const move_step = scene_math.Vec3.scale(normalize(movement_dir), editor_move_speed * delta_seconds);
        camera_position.* = scene_math.Vec3.add(camera_position.*, move_step);
    }
}

fn stepPlayerBody(state: *CameraControlState, camera_position: *scene_math.Vec3, yaw: f32, pitch: f32, input_state: *const script_host.ScriptInputState, delta_seconds: f32) void {
    var remaining_dt = std.math.clamp(delta_seconds, 0.0, 0.25);
    while (remaining_dt > 1e-6) {
        const dt = @min(remaining_dt, body_max_step_s);
        stepPlayerBodySubstep(state, camera_position, yaw, pitch, input_state, dt);
        remaining_dt -= dt;
    }
}

fn stepPlayerBodySubstep(state: *CameraControlState, camera_position: *scene_math.Vec3, yaw: f32, pitch: f32, input_state: *const script_host.ScriptInputState, dt: f32) void {
    const keyboard = input_state.keyboard;
    state.jump_recycle_remaining_s = @max(0.0, state.jump_recycle_remaining_s - dt);

    var forward_flat = normalize(scene_math.Vec3.new(@sin(yaw) * @cos(pitch), 0.0, @cos(yaw) * @cos(pitch)));
    if (length(forward_flat) <= 1e-4) forward_flat = scene_math.Vec3.new(0.0, 0.0, 0.0);
    var right_flat = normalize(scene_math.Vec3.new(forward_flat.z, 0.0, -forward_flat.x));
    if (length(right_flat) <= 1e-4) right_flat = scene_math.Vec3.new(1.0, 0.0, 0.0);

    var move_dir = scene_math.Vec3.new(0.0, 0.0, 0.0);
    if (keyboard.isDown(.w)) move_dir = scene_math.Vec3.add(move_dir, forward_flat);
    if (keyboard.isDown(.s)) move_dir = scene_math.Vec3.sub(move_dir, forward_flat);
    if (keyboard.isDown(.d)) move_dir = scene_math.Vec3.add(move_dir, right_flat);
    if (keyboard.isDown(.a)) move_dir = scene_math.Vec3.sub(move_dir, right_flat);

    const desired_flat_velocity = if (length(move_dir) > 1e-4)
        scene_math.Vec3.scale(normalize(move_dir), 6.0)
    else
        scene_math.Vec3.new(0.0, 0.0, 0.0);
    const accel_rate: f32 = if (state.grounded) 42.0 else 12.0;
    const accel_blend = 1.0 - @exp(-accel_rate * dt);
    state.velocity.x += (desired_flat_velocity.x - state.velocity.x) * accel_blend;
    state.velocity.z += (desired_flat_velocity.z - state.velocity.z) * accel_blend;

    const jump_down = keyboard.isDown(.space);
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

fn applyLook(yaw: *f32, pitch: *f32, look_delta_x: f32, look_delta_y: f32) void {
    yaw.* += look_delta_x * look_sensitivity;
    pitch.* -= look_delta_y * look_sensitivity;
    pitch.* = std.math.clamp(pitch.*, -max_pitch, max_pitch);
}

fn normalize(vec: scene_math.Vec3) scene_math.Vec3 {
    const len = length(vec);
    if (len <= 1e-6) return scene_math.Vec3.new(0.0, 0.0, 0.0);
    return scene_math.Vec3.scale(vec, 1.0 / len);
}

fn length(vec: scene_math.Vec3) f32 {
    return @sqrt(scene_math.Vec3.dot(vec, vec));
}

fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-4;
}

fn vec3ApproxEq(a: scene_math.Vec3, b: scene_math.Vec3) bool {
    return approxEq(a.x, b.x) and approxEq(a.y, b.y) and approxEq(a.z, b.z);
}