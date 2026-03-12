//! Scene script: rotates the monkey at a medium pace and applies a breathing scale pulse.

const std = @import("std");
const script_host = @import("../script_host.zig");
const scene_math = @import("../math.zig");

pub const module_name = "scene.monkey_two_lights.monkey_breathe_rotate";

pub const vtable = script_host.ScriptModuleVTable{
    .on_create = onCreate,
    .on_destroy = onDestroy,
    .on_event = onEvent,
};

const rotation_speed_deg_per_sec: f32 = 36.0;
const breathing_cycles_per_sec: f32 = 0.55;
const breathing_amplitude: f32 = 0.12;
const tau: f32 = std.math.pi * 2.0;
// Suzanne OBJ in this repo is not centered at origin; this is the mesh bounds center in model space.
const suzanne_mesh_center_local = scene_math.Vec3.new(-2.4940625, 1.251686, 4.1038925);

const MonkeyAnimState = struct {
    base_position: scene_math.Vec3 = scene_math.Vec3.new(0.0, 0.0, 0.0),
    base_scale: scene_math.Vec3 = scene_math.Vec3.new(1.0, 1.0, 1.0),
    base_rotation: scene_math.Vec3 = scene_math.Vec3.new(0.0, 0.0, 0.0),
    base_visual_center: scene_math.Vec3 = scene_math.Vec3.new(0.0, 0.0, 0.0),
    accumulated_yaw_deg: f32 = 0.0,
    breathing_phase: f32 = 0.0,
    log_timer_s: f32 = 0.0,
};

fn onCreate(ctx: *script_host.ScriptCallbackContext) void {
    const state = ctx.allocator.create(MonkeyAnimState) catch return;
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

fn animate(ctx: *script_host.ScriptCallbackContext, state: *MonkeyAnimState, delta_seconds: f32) void {
    const clamped_dt = std.math.clamp(delta_seconds, 0.0, 0.05);

    state.accumulated_yaw_deg += rotation_speed_deg_per_sec * clamped_dt;
    if (state.accumulated_yaw_deg >= 360.0) {
        state.accumulated_yaw_deg -= 360.0;
    }

    state.breathing_phase += tau * breathing_cycles_per_sec * clamped_dt;
    if (state.breathing_phase >= tau) {
        state.breathing_phase -= tau;
    }

    const breathing_factor = 1.0 + breathing_amplitude * @sin(state.breathing_phase);
    const animated_scale = scene_math.Vec3.new(
        state.base_scale.x * breathing_factor,
        state.base_scale.y * breathing_factor,
        state.base_scale.z * breathing_factor,
    );
    const animated_rotation = scene_math.Vec3.new(
        state.base_rotation.x,
        state.base_rotation.y + state.accumulated_yaw_deg,
        state.base_rotation.z,
    );
    const rotated_center_offset = rotateVector(mulComponents(suzanne_mesh_center_local, animated_scale), animated_rotation);
    const animated_position = scene_math.Vec3.sub(state.base_visual_center, rotated_center_offset);
    if (currentLocalPosition(ctx)) |position_now| {
        const delta = scene_math.Vec3.sub(animated_position, position_now);
        if (length(delta) > 1e-6) {
            ctx.commands.queueTranslate(ctx.entity, delta) catch {};
        }
    }

    ctx.commands.queueSetLocalScale(ctx.entity, animated_scale) catch {};
    ctx.commands.queueSetLocalRotationDeg(ctx.entity, animated_rotation) catch {};

    state.log_timer_s += clamped_dt;
    if (state.log_timer_s >= 1.0) {
        state.log_timer_s -= 1.0;
        logMonkeyTransform(ctx);
    }
}

fn captureBaseTransform(ctx: *script_host.ScriptCallbackContext, state: *MonkeyAnimState) void {
    const index: usize = @intCast(ctx.entity.index);
    if (index >= ctx.components.local_transforms.items.len) return;
    const local = ctx.components.local_transforms.items[index] orelse return;
    state.base_position = local.position;
    state.base_scale = local.scale;
    state.base_rotation = local.rotation_deg;
    // Treat authored entity position as the intended visual center anchor.
    state.base_visual_center = local.position;
}

fn getState(ctx: *script_host.ScriptCallbackContext) ?*MonkeyAnimState {
    const user_data = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(user_data));
}

fn logMonkeyTransform(ctx: *script_host.ScriptCallbackContext) void {
    const index: usize = @intCast(ctx.entity.index);
    if (index >= ctx.components.local_transforms.items.len or index >= ctx.components.world_transforms.items.len) return;
    const local = ctx.components.local_transforms.items[index] orelse return;
    const world = ctx.components.world_transforms.items[index] orelse return;
    const visual_center = scene_math.Vec3.add(
        local.position,
        rotateVector(mulComponents(suzanne_mesh_center_local, local.scale), local.rotation_deg),
    );
    std.debug.print(
        "[scene.script] [INFO] [monkey_anim] entity={} local_pos=({d:.4},{d:.4},{d:.4}) world_pos=({d:.4},{d:.4},{d:.4}) center=({d:.4},{d:.4},{d:.4}) rot=({d:.2},{d:.2},{d:.2}) scale=({d:.4},{d:.4},{d:.4})\n",
        .{
            ctx.entity.index,
            local.position.x,
            local.position.y,
            local.position.z,
            world.position.x,
            world.position.y,
            world.position.z,
            visual_center.x,
            visual_center.y,
            visual_center.z,
            local.rotation_deg.x,
            local.rotation_deg.y,
            local.rotation_deg.z,
            local.scale.x,
            local.scale.y,
            local.scale.z,
        },
    );
}

fn currentLocalPosition(ctx: *script_host.ScriptCallbackContext) ?scene_math.Vec3 {
    const index: usize = @intCast(ctx.entity.index);
    if (index >= ctx.components.local_transforms.items.len) return null;
    const local = ctx.components.local_transforms.items[index] orelse return null;
    return local.position;
}

fn rotateVector(v: scene_math.Vec3, rotation_deg: scene_math.Vec3) scene_math.Vec3 {
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

    var out = v;
    out = scene_math.Vec3.new(out.x, out.y * cx - out.z * sx, out.y * sx + out.z * cx);
    out = scene_math.Vec3.new(out.x * cy + out.z * sy, out.y, -out.x * sy + out.z * cy);
    out = scene_math.Vec3.new(out.x * cz - out.y * sz, out.x * sz + out.y * cz, out.z);
    return out;
}

fn mulComponents(a: scene_math.Vec3, b: scene_math.Vec3) scene_math.Vec3 {
    return scene_math.Vec3.new(a.x * b.x, a.y * b.y, a.z * b.z);
}

fn length(v: scene_math.Vec3) f32 {
    return @sqrt(scene_math.Vec3.dot(v, v));
}
