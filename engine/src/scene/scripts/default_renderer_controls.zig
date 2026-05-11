//! Default ECS-owned renderer/editor hotkeys.

const script_host = @import("../script_host.zig");

pub const module_name = "scene.default.renderer_controls";

pub const vtable = script_host.ScriptModuleVTable{
    .on_event = onEvent,
};

fn onEvent(ctx: *script_host.ScriptCallbackContext) void {
    switch (ctx.event) {
        .update => |_| updateControls(ctx),
        else => {},
    }
}

fn updateControls(ctx: *script_host.ScriptCallbackContext) void {
    const actions = ctx.input.actions;
    const mouse = ctx.input.mouse;
    const editor_pointer_active = mouse.isDown(.left) or mouse.isDown(.right);
    const editor_hotkeys_allowed = !ctx.input.first_person_active and !editor_pointer_active;

    if (editor_hotkeys_allowed) {
        if (actions.wasPressed(.toggle_scene_item_gizmo)) ctx.commands.queueToggleSceneItemGizmo() catch {};
        if (actions.wasPressed(.toggle_light_gizmo)) ctx.commands.queueToggleLightGizmo() catch {};
        if (actions.wasPressed(.gizmo_axis_x)) ctx.commands.queueSetGizmoAxis(.x) catch {};
        if (actions.wasPressed(.gizmo_axis_y)) ctx.commands.queueSetGizmoAxis(.y) catch {};
        if (actions.wasPressed(.gizmo_axis_z)) ctx.commands.queueSetGizmoAxis(.z) catch {};
        if (actions.wasPressed(.nudge_negative)) {
            ctx.commands.queueNudgeActiveGizmo(-0.2) catch {};
        } else if (actions.wasPressed(.nudge_positive)) {
            ctx.commands.queueNudgeActiveGizmo(0.2) catch {};
        } else if (actions.wasPressed(.cycle_light_selection)) {
            ctx.commands.queueCycleLightSelection() catch {};
        }
    }
    if (actions.wasPressed(.toggle_overlay)) ctx.commands.queueToggleRenderOverlay() catch {};
    if (actions.wasPressed(.toggle_shadow_debug)) ctx.commands.queueToggleShadowDebug() catch {};
    if (actions.wasPressed(.advance_shadow_debug)) ctx.commands.queueAdvanceShadowDebug() catch {};
}
