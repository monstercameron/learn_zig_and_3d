//! Dedicated ECS script for the interactive box in the shadow_single_model scene.

const std = @import("std");
const script_host = @import("../script_host.zig");

pub const module_name = "scene.shadow_single_model.jump_box";

pub const vtable = script_host.ScriptModuleVTable{
    .on_create = onCreate,
    .on_destroy = onDestroy,
    .on_event = onEvent,
};

const JumpState = struct {
    cycle_remaining_s: f32 = 0.0,
    recycle_remaining_s: f32 = 0.0,
};

const jump_velocity: f32 = 2.4;
const jump_cycle_seconds: f32 = 0.55;
const jump_recycle_seconds: f32 = 0.5;

fn onCreate(ctx: *script_host.ScriptCallbackContext) void {
    const state = ctx.allocator.create(JumpState) catch return;
    state.* = .{};
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
        .update => |delta_seconds| {
            state.cycle_remaining_s = @max(0.0, state.cycle_remaining_s - delta_seconds);
            if (state.cycle_remaining_s <= 0.0) {
                state.recycle_remaining_s = @max(0.0, state.recycle_remaining_s - delta_seconds);
            }
            if (ctx.input.keyboard.isDown(.k) and state.cycle_remaining_s <= 0.0 and state.recycle_remaining_s <= 0.0) {
                ctx.commands.queueJump(ctx.entity, jump_velocity) catch {};
                state.cycle_remaining_s = jump_cycle_seconds;
                state.recycle_remaining_s = jump_recycle_seconds;
            }
        },
        else => {},
    }
}

fn getState(ctx: *script_host.ScriptCallbackContext) ?*JumpState {
    const user_data = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(user_data));
}