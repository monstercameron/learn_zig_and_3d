const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const scene_item_gizmo = @import("../scene/item_gizmo.zig");
const TileRenderer = @import("../core/tile_renderer.zig");

const Renderer = renderer_module.Renderer;
const LightGizmoAxis = renderer_module.LightGizmoAxis;
const ProjectionParams = renderer_module.ProjectionParams;
const lightGizmoAxisName = renderer_module.lightGizmoAxisName;
const NEAR_CLIP = renderer_module.NEAR_CLIP;
const NEAR_EPSILON = renderer_module.NEAR_EPSILON;
const lightGizmoAxisColor = renderer_module.lightGizmoAxisColor;
const SceneItemGizmoDrawContext = renderer_module.Renderer.SceneItemGizmoDrawContext;
const post_dispatch = @import("post_dispatch.zig");
const projectCameraPositionFloat = renderer_module.projectCameraPositionFloat;
pub fn drawLightMarker(
    renderer: *Renderer,
    light_pos: math.Vec3,
    light_camera_z: f32,
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
) void {
    if (light_camera_z <= NEAR_CLIP) return;

    const ndc_x = (light_pos.x / light_camera_z) * x_scale;
    const ndc_y = (light_pos.y / light_camera_z) * y_scale;
    const screen_x = ndc_x * center_x + center_x;
    const screen_y = -ndc_y * center_y + center_y;

    const light_x = @as(i32, @intFromFloat(screen_x));
    const light_y = @as(i32, @intFromFloat(screen_y));
    const radius: i32 = 4;
    const color: u32 = 0xFF00FFFF;

    var py = light_y - radius;
    while (py <= light_y + radius) : (py += 1) {
        if (py < 0 or py >= renderer.bitmap.height) continue;
        var px = light_x - radius;
        while (px <= light_x + radius) : (px += 1) {
            if (px < 0 or px >= renderer.bitmap.width) continue;
            const dx = @as(f32, @floatFromInt(px - light_x));
            const dy = @as(f32, @floatFromInt(py - light_y));
            if ((dx * dx + dy * dy) > @as(f32, @floatFromInt(radius * radius))) continue;
            const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(renderer.bitmap.width)) + @as(usize, @intCast(px));
            if (idx < renderer.bitmap.pixels.len) renderer.bitmap.pixels[idx] = color;
        }
    }
}

pub fn worldToCameraPosition(
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    world_position: math.Vec3,
) math.Vec3 {
    const relative = math.Vec3.sub(world_position, camera_position);
    return math.Vec3.new(
        math.Vec3.dot(relative, basis_right),
        math.Vec3.dot(relative, basis_up),
        math.Vec3.dot(relative, basis_forward),
    );
}

/// projectWorldToScreen projects coordinates for Renderer calculations.
pub fn projectWorldToScreen(
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
    world_position: math.Vec3,
) ?[2]i32 {
    const camera_space = worldToCameraPosition(camera_position, basis_right, basis_up, basis_forward, world_position);
    if (camera_space.z <= NEAR_CLIP) return null;

    const projected = projectCameraPositionFloat(camera_space, projection);
    if (!std.math.isFinite(projected.x) or !std.math.isFinite(projected.y)) return null;

    const max_x = @as(f32, @floatFromInt(renderer.bitmap.width * 8));
    const max_y = @as(f32, @floatFromInt(renderer.bitmap.height * 8));
    if (projected.x < -max_x or projected.x > max_x or projected.y < -max_y or projected.y > max_y) return null;

    return .{
        @as(i32, @intFromFloat(projected.x)),
        @as(i32, @intFromFloat(projected.y)),
    };
}

pub fn drawLightGizmo(
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
) void {
    if (renderer.lights.items.len == 0) return;
    renderer.clampLightGizmoSelection();
    const light = renderer.lights.items[renderer.light_gizmo.selected_light_index];
    const origin_world = math.Vec3.scale(light.direction, light.distance);
    const origin_screen = projectWorldToScreen(renderer, 
        camera_position,
        basis_right,
        basis_up,
        basis_forward,
        projection,
        origin_world,
    ) orelse return;

    const axis_extent = std.math.clamp(light.distance * 0.18, 0.3, 1.25);
    const x_endpoint = math.Vec3.add(origin_world, math.Vec3.new(axis_extent, 0.0, 0.0));
    const y_endpoint = math.Vec3.add(origin_world, math.Vec3.new(0.0, axis_extent, 0.0));
    const z_endpoint = math.Vec3.add(origin_world, math.Vec3.new(0.0, 0.0, axis_extent));
    const hot_axis = renderer.light_gizmo.drag_axis orelse renderer.light_gizmo.hover_axis;

    if (projectWorldToScreen(renderer, camera_position, basis_right, basis_up, basis_forward, projection, x_endpoint)) |p| {
        const color = lightGizmoAxisColor(.x, renderer.light_gizmo.active_axis, hot_axis);
        renderer.drawLineColored(origin_screen[0], origin_screen[1], p[0], p[1], color);
        drawLightGizmoHandle(renderer, p[0], p[1], color);
    }
    if (projectWorldToScreen(renderer, camera_position, basis_right, basis_up, basis_forward, projection, y_endpoint)) |p| {
        const color = lightGizmoAxisColor(.y, renderer.light_gizmo.active_axis, hot_axis);
        renderer.drawLineColored(origin_screen[0], origin_screen[1], p[0], p[1], color);
        drawLightGizmoHandle(renderer, p[0], p[1], color);
    }
    if (projectWorldToScreen(renderer, camera_position, basis_right, basis_up, basis_forward, projection, z_endpoint)) |p| {
        const color = lightGizmoAxisColor(.z, renderer.light_gizmo.active_axis, hot_axis);
        renderer.drawLineColored(origin_screen[0], origin_screen[1], p[0], p[1], color);
        drawLightGizmoHandle(renderer, p[0], p[1], color);
    }

    renderer.drawLineColored(origin_screen[0] - 2, origin_screen[1], origin_screen[0] + 2, origin_screen[1], 0xFFFFFFFF);
    renderer.drawLineColored(origin_screen[0], origin_screen[1] - 2, origin_screen[0], origin_screen[1] + 2, 0xFFFFFFFF);
}

fn drawLightGizmoHandle(renderer: *Renderer, x: i32, y: i32, color: u32) void {
    renderer.drawLineColored(x - 3, y, x + 3, y, color);
    renderer.drawLineColored(x, y - 3, x, y + 3, color);
}

pub fn drawSceneItemGizmo(
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
) void {
    var draw_ctx = SceneItemGizmoDrawContext{
        .renderer = renderer,
        .camera_position = camera_position,
        .basis_right = basis_right,
        .basis_up = basis_up,
        .basis_forward = basis_forward,
        .projection = projection,
    };
    renderer.scene_item_gizmo.drawGizmo(
        @ptrCast(&draw_ctx),
        Renderer.projectSceneItemWorld,
        Renderer.drawSceneItemGizmoLine,
    );
}

pub fn drawLightGlow(
    renderer: *Renderer,
    light_pos: math.Vec3,
    light_camera_z: f32,
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    glow_color: math.Vec3,
    radius_px: f32,
    intensity: f32,
) void {
    if (light_camera_z <= NEAR_CLIP) return;
    if (radius_px <= 0.5 or intensity <= 0.0) return;

    const ndc_x = (light_pos.x / light_camera_z) * x_scale;
    const ndc_y = (light_pos.y / light_camera_z) * y_scale;
    const screen_x = ndc_x * center_x + center_x;
    const screen_y = -ndc_y * center_y + center_y;
    const cx = @as(i32, @intFromFloat(screen_x));
    const cy = @as(i32, @intFromFloat(screen_y));
    const radius: i32 = @intFromFloat(radius_px);
    const inv_radius = 1.0 / @max(radius_px, 1.0);

    var py = cy - radius;
    while (py <= cy + radius) : (py += 1) {
        if (py < 0 or py >= renderer.bitmap.height) continue;
        var px = cx - radius;
        while (px <= cx + radius) : (px += 1) {
            if (px < 0 or px >= renderer.bitmap.width) continue;
            const dx = @as(f32, @floatFromInt(px - cx));
            const dy = @as(f32, @floatFromInt(py - cy));
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist > radius_px) continue;
            const falloff = (1.0 - dist * inv_radius);
            const glow = falloff * falloff * intensity;
            const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(renderer.bitmap.width)) + @as(usize, @intCast(px));
            if (idx >= renderer.bitmap.pixels.len) continue;

            const src = renderer.bitmap.pixels[idx];
            const sr: i32 = @intCast((src >> 16) & 0xFF);
            const sg: i32 = @intCast((src >> 8) & 0xFF);
            const sb: i32 = @intCast(src & 0xFF);
            const add_r: i32 = @intFromFloat(std.math.clamp(glow_color.x * 255.0 * glow, 0.0, 255.0));
            const add_g: i32 = @intFromFloat(std.math.clamp(glow_color.y * 255.0 * glow, 0.0, 255.0));
            const add_b: i32 = @intFromFloat(std.math.clamp(glow_color.z * 255.0 * glow, 0.0, 255.0));
            const out_r: u32 = @intCast(std.math.clamp(sr + add_r, 0, 255));
            const out_g: u32 = @intCast(std.math.clamp(sg + add_g, 0, 255));
            const out_b: u32 = @intCast(std.math.clamp(sb + add_b, 0, 255));
            renderer.bitmap.pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
        }
    }
}

