const std = @import("std");
const math = @import("../core/math.zig");
const config = @import("../core/app_config.zig");
const camera_controller = @import("camera_controller.zig");

const fps_camera_floor_y: f32 = 0.0;
const fps_camera_eye_height: f32 = 1.6;

pub fn handleRawMouseDelta(self: anytype, delta_x: i32, delta_y: i32) void {
    _ = self.mouse_input.addRawDelta(delta_x, delta_y);
    if (self.camera_control_mode != .first_person) return;
    camera_controller.accumulateFirstPersonDelta(
        &self.mouse_state,
        math.Vec2.new(
            @as(f32, @floatFromInt(delta_x)),
            @as(f32, @floatFromInt(delta_y)),
        ),
    );
}

pub fn handleFocusLost(self: anytype) void {
    self.keys_pressed.clear();
    self.mouse_input.clear();
    camera_controller.cancelHoldZoom(&self.fps_zoom_state, &self.camera_fov_deg, true);
    self.last_reported_fov_deg = self.camera_fov_deg;
    camera_controller.setJumpHeldState(&self.fps_body_state, false);
    camera_controller.resetForModeToggle(&self.mouse_state);
}

pub fn handleFocusGained(self: anytype) void {
    camera_controller.resetForModeToggle(&self.mouse_state);
}

pub fn handleFirstPersonLeftPress(self: anytype) bool {
    if (self.camera_control_mode != .first_person) return false;
    camera_controller.beginHoldZoom(&self.fps_zoom_state, self.camera_fov_deg, .left_button);
    return true;
}

pub fn handleFirstPersonLeftRelease(self: anytype) bool {
    if (self.camera_control_mode != .first_person) return false;
    camera_controller.endHoldZoom(&self.fps_zoom_state, self.camera_fov_deg, .left_button);
    return true;
}

pub fn handleFirstPersonRightPress(self: anytype) bool {
    if (self.camera_control_mode != .first_person) return false;
    camera_controller.beginHoldZoom(&self.fps_zoom_state, self.camera_fov_deg, .right_button);
    return true;
}

pub fn handleFirstPersonRightRelease(self: anytype) bool {
    if (self.camera_control_mode != .first_person) return false;
    camera_controller.endHoldZoom(&self.fps_zoom_state, self.camera_fov_deg, .right_button);
    return true;
}

pub fn wantsHiddenCursor(self: anytype) bool {
    return self.camera_control_mode == .first_person;
}

pub fn desiredCursorStyle(comptime Style: type, comptime ItemHint: type, comptime LightAxis: type, self: anytype, item_hint: ItemHint, light_drag_axis: ?LightAxis, light_hover_axis: ?LightAxis, arrow_style: Style, grab_style: Style, grabbing_style: Style, hidden_style: Style) Style {
    if (wantsHiddenCursor(self)) return hidden_style;
    if (item_hint == .grabbing or light_drag_axis != null) return grabbing_style;
    if (item_hint == .grab or light_hover_axis != null) return grab_style;
    return arrow_style;
}

pub fn resolveCameraModeCommand(current_mode: anytype, mode_tag: u8) ?@TypeOf(current_mode) {
    return switch (mode_tag) {
        2 => if (current_mode == .first_person) .editor else .first_person,
        0 => .editor,
        1 => .first_person,
        else => null,
    };
}

pub fn setCameraControlMode(self: anytype, next_mode: anytype) bool {
    if (self.camera_control_mode == next_mode) return false;
    self.camera_control_mode = next_mode;
    if (self.camera_control_mode == .first_person) {
        self.scene_item_gizmo.cancelInteraction();
        self.clearLightGizmoInteraction();
        if (!self.scene_camera_script_active) {
            camera_controller.resetFpsBody(&self.fps_body_state, self.camera_position, fps_camera_floor_y, fps_camera_eye_height);
            const jump_down = self.keys_pressed.isDown(.space);
            camera_controller.setJumpHeldState(&self.fps_body_state, jump_down);
        }
        camera_controller.onEnterFirstPerson(&self.fps_zoom_state, self.camera_fov_deg);
    } else {
        camera_controller.cancelHoldZoom(&self.fps_zoom_state, &self.camera_fov_deg, true);
        self.last_reported_fov_deg = self.camera_fov_deg;
    }
    camera_controller.resetForModeToggle(&self.mouse_state);
    return true;
}

pub fn setCameraPosition(self: anytype, position: math.Vec3) void {
    self.camera_position = position;
    if (!self.scene_camera_script_active) {
        camera_controller.resetFpsBody(&self.fps_body_state, self.camera_position, fps_camera_floor_y, fps_camera_eye_height);
    }
}

pub fn setCameraOrientation(self: anytype, pitch: f32, yaw: f32) void {
    self.rotation_x = camera_controller.clampPitch(pitch);
    self.rotation_angle = yaw;
}

pub fn setCameraFov(self: anytype, fov_deg: f32) void {
    const normalized = std.math.clamp(fov_deg, config.CAMERA_FOV_MIN, config.CAMERA_FOV_MAX);
    if (std.math.approxEqAbs(f32, normalized, self.camera_fov_deg, 0.0001)) return;
    self.camera_fov_deg = normalized;
    self.last_reported_fov_deg = normalized;
    self.frame_view_cache.valid = false;
}

pub fn consumeSceneCameraLookDelta(self: anytype, frame_dt_seconds: f32) math.Vec2 {
    if (!self.scene_camera_script_active or self.camera_control_mode != .first_person) return math.Vec2.new(0.0, 0.0);
    return consumeMouseDelta(self, frame_dt_seconds);
}

pub fn prepareCameraForFrame(
    self: anytype,
    delta_seconds: f32,
    simulation_delta_seconds: f32,
    light_dir_world: math.Vec3,
    light_distance: f32,
) void {
    if (!self.scene_camera_script_active) {
        const rotation_speed = 2.0;
        if (self.keys_pressed.isDown(.left)) self.rotation_angle -= rotation_speed * simulation_delta_seconds;
        if (self.keys_pressed.isDown(.right)) self.rotation_angle += rotation_speed * simulation_delta_seconds;
        if (self.keys_pressed.isDown(.up)) self.rotation_x -= rotation_speed * simulation_delta_seconds;
        if (self.keys_pressed.isDown(.down)) self.rotation_x += rotation_speed * simulation_delta_seconds;
    }

    const mouse_delta = if (self.scene_camera_script_active)
        math.Vec2.new(0.0, 0.0)
    else
        consumeMouseDelta(self, delta_seconds);
    if (self.camera_control_mode == .first_person and !self.scene_camera_script_active) {
        camera_controller.applyFirstPersonLook(
            &self.rotation_angle,
            &self.rotation_x,
            mouse_delta,
            effectiveMouseSensitivity(self),
        );
    }
    self.rotation_x = camera_controller.clampPitch(self.rotation_x);

    const fov_delta = consumePendingFovDelta(self);
    if (fov_delta != 0.0) adjustCameraFov(self, fov_delta);
    camera_controller.updateHoldZoom(&self.fps_zoom_state, &self.camera_fov_deg, delta_seconds);
    self.last_reported_fov_deg = self.camera_fov_deg;

    const frame_view = if (self.frame_view_cache.needsUpdate(
        self.camera_position,
        self.rotation_angle,
        self.rotation_x,
        self.camera_fov_deg,
        self.bitmap.width,
        self.bitmap.height,
        light_dir_world,
        light_distance,
    ))
        self.frame_view_cache.update(
            self.camera_position,
            self.rotation_angle,
            self.rotation_x,
            self.camera_fov_deg,
            self.bitmap.width,
            self.bitmap.height,
            light_dir_world,
            light_distance,
        )
    else
        self.frame_view_cache.state;

    const right = frame_view.right;
    const up = frame_view.up;
    const forward = frame_view.forward;
    if (self.camera_control_mode == .first_person) {
        if (!self.scene_camera_script_active) {
            const basis = camera_controller.ViewBasis{
                .right = right,
                .up = up,
                .forward = forward,
            };
            const fps_params = camera_controller.FpsStepParams{
                .dt = simulation_delta_seconds,
                .move_speed = self.camera_move_speed,
                .floor_y = fps_camera_floor_y,
                .eye_height = fps_camera_eye_height,
            };
            camera_controller.stepFpsBody(&self.fps_body_state, &self.camera_position, basis, self.keys_pressed, fps_params);
        }
    } else if (!self.scene_camera_script_active) {
        const world_up = math.Vec3.new(0.0, 1.0, 0.0);

        var forward_flat = math.Vec3.new(forward.x, 0.0, forward.z);
        const forward_flat_len = math.Vec3.length(forward_flat);
        if (forward_flat_len > 0.0001) {
            forward_flat = math.Vec3.scale(forward_flat, 1.0 / forward_flat_len);
        } else {
            forward_flat = math.Vec3.new(0.0, 0.0, 0.0);
        }

        var right_flat = math.Vec3.new(right.x, 0.0, right.z);
        const right_flat_len = math.Vec3.length(right_flat);
        if (right_flat_len > 0.0001) {
            right_flat = math.Vec3.scale(right_flat, 1.0 / right_flat_len);
        } else {
            right_flat = math.Vec3.new(0.0, 0.0, 0.0);
        }

        var movement_dir = math.Vec3.new(0.0, 0.0, 0.0);
        if (self.keys_pressed.isDown(.w)) movement_dir = math.Vec3.add(movement_dir, forward_flat);
        if (self.keys_pressed.isDown(.s)) movement_dir = math.Vec3.sub(movement_dir, forward_flat);
        if (self.keys_pressed.isDown(.d)) movement_dir = math.Vec3.add(movement_dir, right_flat);
        if (self.keys_pressed.isDown(.a)) movement_dir = math.Vec3.sub(movement_dir, right_flat);
        if (self.keys_pressed.isDown(.space)) movement_dir = math.Vec3.add(movement_dir, world_up);
        if (self.keys_pressed.isDown(.ctrl)) movement_dir = math.Vec3.sub(movement_dir, world_up);

        const movement_mag = math.Vec3.length(movement_dir);
        if (movement_mag > 0.0001) {
            const normalized_move = math.Vec3.scale(movement_dir, 1.0 / movement_mag);
            const move_step = math.Vec3.scale(normalized_move, self.camera_move_speed * simulation_delta_seconds);
            self.camera_position = math.Vec3.add(self.camera_position, move_step);
        }
    }
}

fn consumeMouseDelta(self: anytype, frame_dt_seconds: f32) math.Vec2 {
    return camera_controller.consumeLookDelta(&self.mouse_state, self.camera_control_mode, frame_dt_seconds);
}

fn effectiveMouseSensitivity(self: anytype) f32 {
    return camera_controller.effectiveSensitivity(&self.mouse_state);
}

fn consumePendingFovDelta(self: anytype) f32 {
    const delta = self.pending_fov_delta;
    self.pending_fov_delta = 0.0;
    return delta;
}

fn adjustCameraFov(self: anytype, delta: f32) void {
    const new_fov = std.math.clamp(self.camera_fov_deg + delta, config.CAMERA_FOV_MIN, config.CAMERA_FOV_MAX);
    if (!std.math.approxEqAbs(f32, new_fov, self.camera_fov_deg, 0.0001)) {
        self.camera_fov_deg = new_fov;
        self.last_reported_fov_deg = new_fov;
        self.frame_view_cache.valid = false;
    }
}
