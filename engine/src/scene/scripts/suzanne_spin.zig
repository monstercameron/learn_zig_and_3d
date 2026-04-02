//! Scene script: rotates Suzanne around yaw only.

const std = @import("std");
const script_host = @import("../script_host.zig");
const scene_math = @import("../math.zig");

pub const module_name = "scene.suzanne_behavior.suzanne_spin";

pub const vtable = script_host.ScriptModuleVTable{
    .on_create = onCreate,
    .on_destroy = onDestroy,
    .on_event = onEvent,
};

const yaw_speed_deg_per_sec: f32 = 90.0;

const SuzanneAnimState = struct {
    base_scale: scene_math.Vec3 = scene_math.Vec3.new(1.0, 1.0, 1.0),
    base_rotation: scene_math.Vec3 = scene_math.Vec3.new(0.0, 0.0, 0.0),
    accumulated_yaw_deg: f32 = 0.0,
};

fn onCreate(ctx: *script_host.ScriptCallbackContext) void {
    const state = ctx.allocator.create(SuzanneAnimState) catch return;
    state.* = .{};
    captureBaseTransform(ctx, state);
    ctx.user_data_slot.* = state;
}

fn onDestroy(ctx: *script_host.ScriptCallbackContext) void {
    const state = getState(ctx) orelse return;
    ctx.allocator.destroy(state);
    ctx.user_data_slot.* = null;
}

fn onEvent(ctx: *script_host.ScriptCallbackContext) void {
    const state = getState(ctx) orelse return;
    switch (ctx.event) {
        .begin_play, .enable => captureBaseTransform(ctx, state),
        .update => |delta_seconds| animate(ctx, state, delta_seconds),
        else => {},
    }
}

fn animate(ctx: *script_host.ScriptCallbackContext, state: *SuzanneAnimState, delta_seconds: f32) void {
    const clamped_dt = std.math.clamp(delta_seconds, 0.0, 0.05);
    state.accumulated_yaw_deg += yaw_speed_deg_per_sec * clamped_dt;
    if (state.accumulated_yaw_deg >= 360.0) state.accumulated_yaw_deg -= 360.0;

    const animated_rotation = scene_math.Vec3.new(
        state.base_rotation.x,
        state.base_rotation.y + state.accumulated_yaw_deg,
        state.base_rotation.z,
    );
    ctx.commands.queueSetLocalRotationDeg(ctx.entity, animated_rotation) catch {};
    ctx.commands.queueSetLocalScale(ctx.entity, state.base_scale) catch {};
}

fn captureBaseTransform(ctx: *script_host.ScriptCallbackContext, state: *SuzanneAnimState) void {
    const index: usize = @intCast(ctx.entity.index);
    if (index >= ctx.components.local_transforms.items.len) return;
    const local = ctx.components.local_transforms.items[index] orelse return;
    state.base_scale = local.scale;
    state.base_rotation = local.rotation_deg;
    state.accumulated_yaw_deg = 0.0;
}

fn getState(ctx: *script_host.ScriptCallbackContext) ?*SuzanneAnimState {
    const user_data = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(user_data));
}
