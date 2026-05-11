//! ECS camera/player controller for the shadow_single_model scene.

const std = @import("std");
const script_host = @import("../script_host.zig");
const scene_components = @import("../components.zig");
const scene_math = @import("../math.zig");
const camera_motion = @import("camera_motion.zig");

pub const module_name = "scene.shadow_single_model.player_camera";

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
const jump_recycle_seconds: f32 = 0.5;

const PlayerCameraState = struct {
    velocity: scene_math.Vec3 = scene_math.Vec3.new(0.0, 0.0, 0.0),
    grounded: bool = false,
    jump_was_down: bool = false,
    jump_cycle_active: bool = false,
    jump_recycle_remaining_s: f32 = 0.0,
    repeat_jump_when_grounded: bool = false,
    initialized: bool = false,
};

fn onCreate(ctx: *script_host.ScriptCallbackContext) void {
    const state = ctx.allocator.create(PlayerCameraState) catch return;
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

fn updateCamera(ctx: *script_host.ScriptCallbackContext, state: *PlayerCameraState, delta_seconds: f32) void {
    if (!ctx.input.first_person_active) {
        state.jump_was_down = false;
        state.jump_cycle_active = false;
        state.jump_recycle_remaining_s = 0.0;
        state.repeat_jump_when_grounded = false;
        return;
    }

    initializeState(ctx, state);
    const state_view = getCameraState(ctx) orelse return;
    const actions = ctx.input.actions;
    var camera_position = state_view.transform.position;
    var pitch = state_view.camera.pitch;
    var yaw = state_view.camera.yaw;

    camera_motion.applyLook(&yaw, &pitch, ctx.input.look_delta.x, ctx.input.look_delta.y, look_sensitivity);

    if (!actions.isDown(.jump)) {
        state.repeat_jump_when_grounded = false;
    } else if (state.grounded and state.repeat_jump_when_grounded and state.jump_recycle_remaining_s <= 0.0) {
        state.jump_was_down = false;
        state.repeat_jump_when_grounded = false;
    }

    camera_motion.stepPlayerBody(state, &camera_position, yaw, pitch, ctx.input, delta_seconds, body_max_step_s, floor_y, eye_height, jump_recycle_seconds);

    if (actions.isDown(.jump) and !state.grounded) {
        state.repeat_jump_when_grounded = true;
    }

    const delta = scene_math.Vec3.sub(camera_position, state_view.transform.position);
    if (!camera_motion.vec3ApproxEq(delta, scene_math.Vec3.new(0.0, 0.0, 0.0))) {
        ctx.commands.queueTranslate(ctx.entity, delta) catch {};
    }
    if (!camera_motion.approxEq(pitch, state_view.camera.pitch) or !camera_motion.approxEq(yaw, state_view.camera.yaw)) {
        ctx.commands.queueSetCameraOrientation(ctx.entity, pitch, yaw) catch {};
    }
}

fn initializeState(ctx: *script_host.ScriptCallbackContext, state: *PlayerCameraState) void {
    if (state.initialized) return;
    const state_view = getCameraState(ctx) orelse return;
    state.velocity = scene_math.Vec3.new(0.0, 0.0, 0.0);
    state.grounded = state_view.transform.position.y <= floor_y + eye_height + 1e-4;
    state.jump_was_down = false;
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

fn getState(ctx: *script_host.ScriptCallbackContext) ?*PlayerCameraState {
    const user_data = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(user_data));
}
