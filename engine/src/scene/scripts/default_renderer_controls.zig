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
    const keyboard = ctx.input.keyboard;
    const mouse = ctx.input.mouse;
    const editor_pointer_active = mouse.isDown(.left) or mouse.isDown(.right);
    const editor_hotkeys_allowed = !ctx.input.first_person_active and !editor_pointer_active;

    if (editor_hotkeys_allowed) {
        if (keyboard.wasPressed(.m)) ctx.commands.queueToggleSceneItemGizmo() catch {};
        if (keyboard.wasPressed(.g)) ctx.commands.queueToggleLightGizmo() catch {};
        if (keyboard.wasPressed(.x)) ctx.commands.queueSetGizmoAxis(.x) catch {};
        if (keyboard.wasPressed(.y)) ctx.commands.queueSetGizmoAxis(.y) catch {};
        if (keyboard.wasPressed(.z)) ctx.commands.queueSetGizmoAxis(.z) catch {};
        if (keyboard.isDown(.ctrl) and keyboard.wasPressed(.j)) {
            ctx.commands.queueNudgeActiveGizmo(-0.2) catch {};
        } else if (keyboard.isDown(.ctrl) and keyboard.wasPressed(.l)) {
            ctx.commands.queueNudgeActiveGizmo(0.2) catch {};
        } else if (keyboard.wasPressed(.l)) {
            ctx.commands.queueCycleLightSelection() catch {};
        }
    }
    if (keyboard.wasPressed(.p)) ctx.commands.queueToggleRenderOverlay() catch {};
    if (keyboard.wasPressed(.h)) ctx.commands.queueToggleShadowDebug() catch {};
    if (keyboard.wasPressed(.n)) ctx.commands.queueAdvanceShadowDebug() catch {};
}