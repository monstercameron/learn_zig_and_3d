const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const direct_primitives = @import("../direct/primitives.zig");
const direct_showcase = @import("../direct/showcase.zig");
const direct_backend = @import("../backends/direct_backend.zig");
const scene_tiled_backend = @import("../backends/scene_tiled_backend.zig");
const TileRenderer = @import("../core/tile_renderer.zig");
const frame_resources = @import("../frame/resources.zig");
const frame_setup_stage = @import("../stages/frame_setup_stage.zig");

const Renderer = renderer_module.Renderer;
const ColorGradeProfile = renderer_module.ColorGradeProfile;
const Mesh = renderer_module.Mesh;
const ProjectionParams = renderer_module.ProjectionParams;
const LightInfo = renderer_module.LightInfo;
const TileLightRange = renderer_module.TileLightRange;
const noopRenderPassJob = renderer_module.noopRenderPassJob;
const NEAR_CLIP = renderer_module.NEAR_CLIP;
const NEAR_EPSILON = renderer_module.NEAR_EPSILON;
const clampByte = renderer_module.clampByte;
const Meshlet = renderer_module.Meshlet;
const cpu_features = @import("../../core/cpu_features.zig");
const ENABLE_MESHLET_CONE_CULL = renderer_module.ENABLE_MESHLET_CONE_CULL;
const transformNormalFromBasis = Renderer.transformNormalFromBasis;
/// buildBlockbusterGradeProfile builds data structures used by Renderer.
pub fn buildBlockbusterGradeProfile() ColorGradeProfile {
    var profile: ColorGradeProfile = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const value: i32 = @intCast(i);
        const contrasted = @divTrunc((value - 128) * config.POST_COLOR_CONTRAST_PERCENT, 100) + 128 + config.POST_COLOR_BRIGHTNESS_BIAS;
        profile.base_curve[i] = clampByte(contrasted);

        const shadow_span = 124 - value;
        const highlight_span = value - 96;
        const shadow = std.math.clamp(@divTrunc(shadow_span * 255, 124), 0, 255);
        const highlight = std.math.clamp(@divTrunc(highlight_span * 255, 159), 0, 255);
        profile.tone_add_r[i] = @intCast(@divTrunc(highlight * 26, 255) - @divTrunc(shadow * 10, 255));
        profile.tone_add_g[i] = @intCast(@divTrunc(highlight * 8, 255) + @divTrunc(shadow * 10, 255));
        profile.tone_add_b[i] = @intCast(-@divTrunc(highlight * 18, 255) + @divTrunc(shadow * 24, 255));
    }
    return profile;
}

fn meshletVisible(
    renderer: *const Renderer,
    meshlet: *const Meshlet,
    camera_position: math.Vec3,
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    projection: ProjectionParams,
) bool {
    _ = renderer;
    const relative_center = math.Vec3.sub(meshlet.bounds_center, camera_position);
    const center_cam = math.Vec3.new(
        math.Vec3.dot(relative_center, right),
        math.Vec3.dot(relative_center, up),
        math.Vec3.dot(relative_center, forward),
    );

    const radius = meshlet.bounds_radius;
    const safety_margin = radius * 0.5 + 1.0; // generous guard against over-eager clipping near the screen edges
    const sphere_radius = radius + safety_margin;

    if (center_cam.z + sphere_radius <= projection.near_plane - NEAR_EPSILON) return false;
    if (projection.x_scale <= 0.0 or projection.y_scale <= 0.0) return true;

    const side_plane_x_len = @sqrt(projection.x_scale * projection.x_scale + 1.0);
    const side_plane_y_len = @sqrt(projection.y_scale * projection.y_scale + 1.0);
    if (projection.x_scale * center_cam.x - center_cam.z > sphere_radius * side_plane_x_len) return false;
    if (-projection.x_scale * center_cam.x - center_cam.z > sphere_radius * side_plane_x_len) return false;
    if (projection.y_scale * center_cam.y - center_cam.z > sphere_radius * side_plane_y_len) return false;
    if (-projection.y_scale * center_cam.y - center_cam.z > sphere_radius * side_plane_y_len) return false;

    if (ENABLE_MESHLET_CONE_CULL and meshlet.normal_cone_cutoff > -1.0) {
        const axis_cam = transformNormalFromBasis(right, up, forward, meshlet.normal_cone_axis);
        const view_to_camera = math.Vec3.scale(center_cam, -1.0);
        const view_len = math.Vec3.length(view_to_camera);
        if (view_len > 1e-6) {
            const view_dir = math.Vec3.scale(view_to_camera, 1.0 / view_len);
            const cone_sine = @sqrt(@max(0.0, 1.0 - meshlet.normal_cone_cutoff * meshlet.normal_cone_cutoff));
            if (math.Vec3.dot(axis_cam, view_dir) < -cone_sine) return false;
        }
    }

    return true;
}

/// Returns runtime tile light cull lanes.
/// Keeps runtime tile light cull lanes as the single implementation point so call-site behavior stays consistent.
fn runtimeTileLightCullLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512, .avx2 => 8,
        .sse2, .neon => 4,
        .scalar => 1,
    };
}

fn tileLightBroadphaseMaskSimd(
    comptime lanes: usize,
    dir_cam_x: []const f32,
    dir_cam_y: []const f32,
    dir_cam_z: []const f32,
    shadow_mode: []const u8,
    start_index: usize,
    min_nx: f32,
    max_nx: f32,
    min_ny: f32,
    max_ny: f32,
    min_nz: f32,
    max_nz: f32,
) u32 {
    const FloatVec = @Vector(lanes, f32);
    const x_ptr: *const [lanes]f32 = @ptrCast(dir_cam_x[start_index..][0..lanes]);
    const y_ptr: *const [lanes]f32 = @ptrCast(dir_cam_y[start_index..][0..lanes]);
    const z_ptr: *const [lanes]f32 = @ptrCast(dir_cam_z[start_index..][0..lanes]);
    const dx: FloatVec = @bitCast(x_ptr.*);
    const dy: FloatVec = @bitCast(y_ptr.*);
    const dz: FloatVec = @bitCast(z_ptr.*);

    const zero: FloatVec = @splat(0.0);
    const bound_x = @select(f32, dx >= zero, @as(FloatVec, @splat(max_nx)), @as(FloatVec, @splat(min_nx)));
    const bound_y = @select(f32, dy >= zero, @as(FloatVec, @splat(max_ny)), @as(FloatVec, @splat(min_ny)));
    const bound_z = @select(f32, dz >= zero, @as(FloatVec, @splat(max_nz)), @as(FloatVec, @splat(min_nz)));
    const dot_max = bound_x * dx + bound_y * dy + bound_z * dz;

    var mask: u32 = 0;
    inline for (0..lanes) |lane| {
        const light_mode: LightInfo.ShadowMode = @enumFromInt(shadow_mode[start_index + lane]);
        if (light_mode != .none and dot_max[lane] > 0.0) {
            mask |= (@as(u32, 1) << @as(u5, @intCast(lane)));
        }
    }
    return mask;
}

fn tileLightBroadphaseAccept(
    dir_cam_x: f32,
    dir_cam_y: f32,
    dir_cam_z: f32,
    min_nx: f32,
    max_nx: f32,
    min_ny: f32,
    max_ny: f32,
    min_nz: f32,
    max_nz: f32,
) bool {
    const bound_x = (if (dir_cam_x >= 0.0) max_nx else min_nx) * dir_cam_x;
    const bound_y = (if (dir_cam_y >= 0.0) max_ny else min_ny) * dir_cam_y;
    const bound_z = (if (dir_cam_z >= 0.0) max_nz else min_nz) * dir_cam_z;
    return (bound_x + bound_y + bound_z) > 0.0;
}

pub fn firstTileLightWithMode(renderer: *const Renderer, range: TileLightRange, mode: LightInfo.ShadowMode) ?usize {
    var i: usize = 0;
    while (i < range.count) : (i += 1) {
        const light_index = renderer.tile_light_indices[range.offset + i];
        if (light_index >= renderer.lights.items.len) continue;
        if (renderer.lights.items[light_index].shadow_mode == mode) return light_index;
    }
    return null;
}

/// Renders the scene using the parallel, tile-based pipeline.
pub fn renderTiled(
    renderer: *Renderer,
    mesh: *const Mesh,
    transform: math.Mat4,
    light_dir: math.Vec3,
    pump: ?*const fn (*Renderer) bool,
    projection: ProjectionParams,
) !u64 {
    return scene_tiled_backend.execute(
        renderer,
        mesh,
        transform,
        light_dir,
        pump,
        projection,
        noopRenderPassJob,
    );
}

/// renderDirect renders Renderer output.
pub fn renderDirect(
    renderer: *Renderer,
    mesh: *const Mesh,
    transform: math.Mat4,
    light_dir: math.Vec3,
    projection: ProjectionParams,
) !void {
    _ = try renderer.renderTiled(mesh, transform, light_dir, null, projection);
}

fn clearDirectFrame(renderer: *Renderer, clear: direct_primitives.ClearConfig) void {
    _ = frame_setup_stage.execute(directFrameResources(renderer), .{
        .clear_color = clear.color,
        .clear_depth = clear.depth orelse std.math.inf(f32),
    });
}

fn renderDirectPrimitiveShowcase(renderer: *Renderer) !void {
    const plan = direct_showcase.defaultPlan(
        renderer.camera_position,
        renderer.rotation_angle,
        renderer.rotation_x,
        renderer.camera_fov_deg,
        renderer.bitmap.width,
        renderer.bitmap.height,
        &renderer.direct_backend.suzanne_mesh,
    );
    try renderer.direct_backend.renderPrimitiveShowcase(
        directFrameResources(renderer),
        plan.camera,
        renderer.job_system,
        .{
            .raster_mode = plan.raster_mode,
            .scene_kind = plan.scene_kind,
        },
    );
}

pub fn directFrameResources(renderer: *Renderer) frame_resources.FrameResources {
    return .{
        .target = .{
            .width = renderer.bitmap.width,
            .height = renderer.bitmap.height,
            .color = renderer.bitmap.pixels,
            .depth = renderer.scene_depth,
        },
        .aux = .{
            .scene_camera = renderer.scene_camera,
            .scene_normal = renderer.scene_normal,
            .scene_surface = renderer.scene_surface,
        },
    };
}

fn drawShadedTriangle(renderer: *Renderer, p0: [2]i32, p1: [2]i32, p2: [2]i32, shading: TileRenderer.ShadingParams) void {
    _ = renderer;
    _ = p0;
    _ = p1;
    _ = p2;
    _ = shading;
}

pub fn drawLineColored(renderer: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    var cx = x0;
    var cy = y0;

    const dx = if (x1 >= x0) (x1 - x0) else (x0 - x1);
    const dy = if (y1 >= y0) (y1 - y0) else (y0 - y1);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err: i32 = dx - dy;

    while (true) {
        if (cx >= 0 and cx < renderer.bitmap.width and cy >= 0 and cy < renderer.bitmap.height) {
            const idx = @as(usize, @intCast(cy)) * @as(usize, @intCast(renderer.bitmap.width)) + @as(usize, @intCast(cx));
            if (idx < renderer.bitmap.pixels.len) {
                renderer.bitmap.pixels[idx] = color;
            }
        }

        if (cx == x1 and cy == y1) break;
        const doubled_err = err * 2;
        if (doubled_err > -dy) {
            err -= dy;
            cx += sx;
        }
        if (doubled_err < dx) {
            err += dx;
            cy += sy;
        }
    }
}