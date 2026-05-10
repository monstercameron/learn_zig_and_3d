const std = @import("std");
const math = @import("../../core/math.zig");
const renderer_module = @import("../renderer.zig");

const Renderer = renderer_module.Renderer;
const CursorStyle = renderer_module.CursorStyle;
const SceneItemBinding = renderer_module.SceneItemBinding;
const SceneItemTranslateRequest = renderer_module.SceneItemTranslateRequest;
const direct_backend = @import("../backends/direct_backend.zig");
const camera_runtime = @import("../camera_runtime.zig");
const camera_controller = @import("../camera_controller.zig");
const input = @import("platform_input");
const log = @import("../../core/log.zig");
const scene_item_gizmo = @import("../scene_item_gizmo.zig");

const renderer_logger = renderer_module.renderer_logger;
const LightGizmoAxis = renderer_module.LightGizmoAxis;
const ResizeStateSnapshot = renderer_module.Renderer.ResizeStateSnapshot;
const SceneItemGizmoDrawContext = renderer_module.Renderer.SceneItemGizmoDrawContext;
const lightGizmoAxisName = renderer_module.lightGizmoAxisName;
const config = @import("../../core/app_config.zig");
/// Handles handle key input.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleKeyInput(renderer: *Renderer, key: u32, is_down: bool) void {
    _ = input.updateKeyState(&renderer.keys_pressed, key, is_down);
}

/// Returns whether i sf ir st pe rs on mo de.
/// The check is side-effect free so callers can gate expensive follow-up work cheaply.
pub fn isFirstPersonMode(renderer: *const Renderer) bool {
    return camera_runtime.wantsHiddenCursor(renderer);
}

/// Returns whether i ss ce ne it em dr ag ac ti ve.
/// The check is side-effect free so callers can gate expensive follow-up work cheaply.
pub fn isSceneItemDragActive(renderer: *const Renderer) bool {
    return renderer.scene_item_gizmo.isDragging();
}

pub fn setSceneCameraScriptActive(renderer: *Renderer, active: bool) void {
    renderer.scene_camera_script_active = active;
}

pub fn applyCameraModeCommand(renderer: *Renderer, mode_tag: u8) void {
    const next_mode = camera_runtime.resolveCameraModeCommand(renderer.camera_control_mode, mode_tag) orelse return;
    renderer.setCameraControlMode(next_mode);
}

pub fn toggleSceneItemGizmo(renderer: *Renderer) void {
    renderer.scene_item_gizmo.toggleEnabled();
    if (renderer.scene_item_gizmo.isActive()) {
        renderer_logger.infoSub(
            "scene_gizmo",
            "enabled item={} axis={s} step={d:.2}",
            .{
                renderer.scene_item_gizmo.selected_item_index.?,
                scene_item_gizmo.axisName(renderer.scene_item_gizmo.active_axis),
                renderer.scene_item_gizmo.move_step,
            },
        );
    } else if (renderer.scene_item_gizmo.enabled) {
        renderer_logger.infoSub("scene_gizmo", "enabled (no selected item)", .{});
    } else {
        renderer_logger.infoSub("scene_gizmo", "disabled", .{});
    }
}

pub fn toggleLightGizmo(renderer: *Renderer) void {
    renderer.light_gizmo.enabled = !renderer.light_gizmo.enabled;
    renderer.clampLightGizmoSelection();
    if (renderer.light_gizmo.enabled and renderer.lights.items.len > 0) {
        renderer_logger.infoSub(
            "light_gizmo",
            "enabled light={} axis={s} step={d:.2}",
            .{
                renderer.light_gizmo.selected_light_index,
                lightGizmoAxisName(renderer.light_gizmo.active_axis),
                renderer.light_gizmo.move_step,
            },
        );
    } else if (renderer.light_gizmo.enabled) {
        renderer_logger.infoSub("light_gizmo", "enabled (no lights)", .{});
    } else {
        renderer.clearLightGizmoInteraction();
        renderer_logger.infoSub("light_gizmo", "disabled", .{});
    }
}

pub fn setActiveGizmoAxis(renderer: *Renderer, axis_tag: u8) void {
    const light_axis: LightGizmoAxis = switch (axis_tag) {
        0 => .x,
        1 => .y,
        2 => .z,
        else => return,
    };
    if (renderer.scene_item_gizmo.isActive()) {
        renderer.scene_item_gizmo.setAxis(switch (axis_tag) {
            0 => .x,
            1 => .y,
            2 => .z,
            else => unreachable,
        });
        renderer_logger.infoSub("scene_gizmo", "axis={s}", .{scene_item_gizmo.axisName(renderer.scene_item_gizmo.active_axis)});
    } else {
        renderer.light_gizmo.active_axis = light_axis;
        renderer_logger.infoSub("light_gizmo", "axis={s}", .{lightGizmoAxisName(renderer.light_gizmo.active_axis)});
    }
}

pub fn cycleLightGizmoSelection(renderer: *Renderer) void {
    if (renderer.lights.items.len == 0) return;
    renderer.clampLightGizmoSelection();
    renderer.light_gizmo.selected_light_index = (renderer.light_gizmo.selected_light_index + 1) % renderer.lights.items.len;
    renderer_logger.infoSub("light_gizmo", "light={}", .{renderer.light_gizmo.selected_light_index});
}

pub fn nudgeActiveGizmo(renderer: *Renderer, delta: f32) void {
    if (renderer.scene_item_gizmo.isActive()) {
        renderer.scene_item_gizmo.queueSelectedTranslation(delta);
    } else if (renderer.light_gizmo.enabled) {
        renderer.moveSelectedLightAlongAxis(delta);
    }
}

pub fn toggleRenderOverlay(renderer: *Renderer) void {
    renderer.show_render_overlay = !renderer.show_render_overlay;
    renderer_logger.infoSub(
        "overlay",
        "render overlay {s}",
        .{if (renderer.show_render_overlay) "enabled" else "disabled"},
    );
}

pub fn toggleHybridShadowDebug(renderer: *Renderer) void {
    renderer.hybrid_shadow_debug.enabled = !renderer.hybrid_shadow_debug.enabled;
    renderer.hybrid_shadow_debug.reset();
    renderer_logger.infoSub(
        "shadow_debug",
        "hybrid shadow stepping {s}",
        .{if (renderer.hybrid_shadow_debug.enabled) "enabled" else "disabled"},
    );
}

pub fn advanceHybridShadowDebug(renderer: *Renderer) void {
    if (renderer.hybrid_shadow_debug.enabled) {
        renderer.hybrid_shadow_debug.advance_requested = true;
    }
}

/// Handles handle mouse move.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleMouseMove(renderer: *Renderer, x: i32, y: i32) void {
    _ = renderer.mouse_input.setPosition(x, y);
    if (renderer.camera_control_mode == .first_person) return;

    const pointer_view = renderer.computePointerViewState();
    var pointer_ctx = SceneItemGizmoDrawContext{
        .renderer = renderer,
        .camera_position = renderer.camera_position,
        .basis_right = pointer_view.right,
        .basis_up = pointer_view.up,
        .basis_forward = pointer_view.forward,
        .projection = pointer_view.projection,
    };
    renderer.scene_item_gizmo.handlePointerMove(
        x,
        y,
        renderer.bitmap.width,
        renderer.bitmap.height,
        @as(i32, @intCast(config.WINDOW_WIDTH)),
        @as(i32, @intCast(config.WINDOW_HEIGHT)),
        @ptrCast(&pointer_ctx),
        Renderer.projectSceneItemWorld,
    );

    const mapped_pointer = renderer.mapWindowPointToBackbuffer(x, y) orelse {
        if (renderer.light_gizmo.drag_axis == null) renderer.light_gizmo.hover_axis = null;
        return;
    };
    renderer.updateLightGizmoPointer(
        math.Vec2.new(
            @as(f32, @floatFromInt(mapped_pointer.x)),
            @as(f32, @floatFromInt(mapped_pointer.y)),
        ),
        pointer_view,
    );
}

/// Handles handle raw mouse delta.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleRawMouseDelta(renderer: *Renderer, delta_x: i32, delta_y: i32) void {
    camera_runtime.handleRawMouseDelta(renderer, delta_x, delta_y);
}

/// Handles handle mouse left click.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleMouseLeftClick(renderer: *Renderer, x: i32, y: i32) void {
    _ = renderer.mouse_input.setButton(.left, true);
    if (camera_runtime.handleFirstPersonLeftPress(renderer)) return;
    const pointer_view = renderer.computePointerViewState();
    if (renderer.beginLightGizmoDrag(x, y, pointer_view)) return;
    var pointer_ctx = SceneItemGizmoDrawContext{
        .renderer = renderer,
        .camera_position = renderer.camera_position,
        .basis_right = pointer_view.right,
        .basis_up = pointer_view.up,
        .basis_forward = pointer_view.forward,
        .projection = pointer_view.projection,
    };
    _ = renderer.scene_item_gizmo.handlePointerDown(
        x,
        y,
        renderer.bitmap.width,
        renderer.bitmap.height,
        @as(i32, @intCast(config.WINDOW_WIDTH)),
        @as(i32, @intCast(config.WINDOW_HEIGHT)),
        @ptrCast(&pointer_ctx),
        Renderer.projectSceneItemWorld,
    );
}

/// Handles handle mouse left release.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleMouseLeftRelease(renderer: *Renderer, x: i32, y: i32) void {
    _ = renderer.mouse_input.setButton(.left, false);
    _ = x;
    _ = y;
    if (camera_runtime.handleFirstPersonLeftRelease(renderer)) return;
    renderer.scene_item_gizmo.handlePointerUp();
    renderer.clearLightGizmoInteraction();
}

/// Handles handle mouse right click.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleMouseRightClick(renderer: *Renderer, x: i32, y: i32) void {
    _ = renderer.mouse_input.setButton(.right, true);
    _ = x;
    _ = y;
    _ = camera_runtime.handleFirstPersonRightPress(renderer);
}

/// Handles handle mouse right release.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleMouseRightRelease(renderer: *Renderer, x: i32, y: i32) void {
    _ = renderer.mouse_input.setButton(.right, false);
    _ = x;
    _ = y;
    _ = camera_runtime.handleFirstPersonRightRelease(renderer);
}

/// Handles handle focus lost.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleFocusLost(renderer: *Renderer) void {
    renderer.scene_item_gizmo.handlePointerUp();
    renderer.clearLightGizmoInteraction();
    camera_runtime.handleFocusLost(renderer);
}

/// Handles handle focus gained.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn handleFocusGained(renderer: *Renderer) void {
    camera_runtime.handleFocusGained(renderer);
}

/// Performs desired cursor style.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn desiredCursorStyle(renderer: *const Renderer) CursorStyle {
    return camera_runtime.desiredCursorStyle(
        CursorStyle,
        scene_item_gizmo.CursorHint,
        LightGizmoAxis,
        renderer,
        renderer.scene_item_gizmo.cursorHint(),
        renderer.light_gizmo.drag_axis,
        renderer.light_gizmo.hover_axis,
        .arrow,
        .grab,
        .grabbing,
        .hidden,
    );
}

/// Sets s et sc en ei te mb in di ng s.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setSceneItemBindings(renderer: *Renderer, bindings: []const SceneItemBinding, triangle_count: usize) !void {
    try renderer.scene_item_gizmo.setBindings(renderer.allocator, bindings, triangle_count);
}

/// Propagates an external state change into local bookkeeping and dependent systems.
/// It propagates an external state change into the local subsystem bookkeeping.
pub fn notifySceneItemTranslated(renderer: *Renderer, item_index: usize, delta: math.Vec3) void {
    renderer.scene_item_gizmo.notifyItemTranslated(item_index, delta);
}

/// Sets s et sc en ei te mc en te r.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setSceneItemCenter(renderer: *Renderer, item_index: usize, center: math.Vec3) void {
    renderer.scene_item_gizmo.setItemOrigin(item_index, center);
}

/// Returns pending data and advances internal cursors/flags to avoid reprocessing.
/// It returns pending data and clears or advances the underlying queue/state.
pub fn consumeSceneItemTranslateRequest(renderer: *Renderer) ?SceneItemTranslateRequest {
    return renderer.scene_item_gizmo.consumeTranslateRequest();
}

pub fn selectedSceneItemSelectionId(renderer: *const Renderer) ?u64 {
    return renderer.scene_item_gizmo.selectedSelectionId();
}

/// Sets s et ca me ra po si ti on.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setCameraPosition(renderer: *Renderer, position: math.Vec3) void {
    camera_runtime.setCameraPosition(renderer, position);
}

/// Sets s et ca me ra or ie nt at io n.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setCameraOrientation(renderer: *Renderer, pitch: f32, yaw: f32) void {
    camera_runtime.setCameraOrientation(renderer, pitch, yaw);
}

pub fn setCameraFov(renderer: *Renderer, fov_deg: f32) void {
    camera_runtime.setCameraFov(renderer, fov_deg);
}

pub fn setPresentSize(renderer: *Renderer, width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    if (renderer.present_state.width == width and renderer.present_state.height == height) return;

    const saved = ResizeStateSnapshot{
        .camera_position = renderer.camera_position,
        .camera_pitch = renderer.rotation_x,
        .camera_yaw = renderer.rotation_angle,
        .camera_fov_deg = renderer.camera_fov_deg,
        .camera_control_mode = renderer.camera_control_mode,
        .scene_camera_script_active = renderer.scene_camera_script_active,
        .show_tile_borders = renderer.show_tile_borders,
        .show_wireframe = renderer.show_wireframe,
        .show_light_orb = renderer.show_light_orb,
        .cull_light_orb = renderer.cull_light_orb,
        .use_tiled_rendering = renderer.use_tiled_rendering,
        .show_frame_pacing_overlay = renderer.show_frame_pacing_overlay,
        .show_render_overlay = renderer.show_render_overlay,
        .present_minimized = renderer.present_state.minimized,
    };

    renderer.recreateForPresentSize(width, height, saved) catch |err| {
        renderer_logger.errorSub("resize", "failed to resize renderer to {d}x{d}: {s}", .{
            width,
            height,
            @errorName(err),
        });
    };
}

pub fn setPresentMinimized(renderer: *Renderer, minimized: bool) void {
    renderer.present_state.setMinimized(minimized);
}
