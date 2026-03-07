//! # The Main Renderer Module
//!
//! This module is the heart and brain of the entire rendering engine. It orchestrates
//! the entire 3D pipeline, from handling user input to update the camera, transforming
//! 3D vertices, dispatching work to the job system, and finally presenting the
//! rendered image to the screen.
//!
//! ## JavaScript Analogy
//!
//! Think of this as the main class in a rendering library like `three.js` (e.g., `WebGLRenderer`)
//! combined with the scene update and render loop logic. It holds the application state
//! and contains the main `render()` method that gets called every frame.
//!
//! ```javascript
//! class App {
//!   constructor() {
//!     this.renderer = new THREE.WebGLRenderer();
//!     this.scene = new THREE.Scene();
//!     this.camera = new THREE.PerspectiveCamera(...);
//!     this.state = { rotation: 0, lightPosition: ... };
//!   }
//!
//!   render() {
//!     // This is what our `render3DMeshWithPump` function does:
//!     this.updateStateFromInput();
//!     this.renderer.render(this.scene, this.camera);
//!   }
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const math = @import("math.zig");
const MeshModule = @import("mesh.zig");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;
const config = @import("app_config.zig");
const input = @import("input.zig");
const lighting = @import("lighting.zig");
const scanline = @import("scanline.zig");
const texture = @import("texture.zig");
const WorkTypes = @import("mesh_work_types.zig");
const TrianglePacket = WorkTypes.TrianglePacket;
const TriangleFlags = WorkTypes.TriangleFlags;
const MeshletPacket = WorkTypes.MeshletPacket;
const log = @import("log.zig");
const renderer_logger = log.get("renderer.core");
const pipeline_logger = log.get("renderer.pipeline");
const meshlet_logger = log.get("renderer.meshlet");
const ground_logger = log.get("renderer.ground");

const NEAR_CLIP: f32 = 0.01;
const NEAR_EPSILON: f32 = 1e-4;
const INVALID_PROJECTED_COORD: i32 = -1000;
const ENABLE_MESHLET_CONE_CULL = false;
const shadow_rebuild_dot_threshold: f32 = 0.9986; // about 3 degrees
const hybrid_shadow_grid_dim: usize = 32;
const hybrid_shadow_grid_cells: usize = hybrid_shadow_grid_dim * hybrid_shadow_grid_dim;

const HybridShadowCasterBounds = struct {
    meshlet_index: usize,
    min_u: f32,
    max_u: f32,
    min_v: f32,
    max_v: f32,
    max_depth: f32,
};

const HybridShadowTileRange = struct {
    offset: usize = 0,
    count: usize = 0,
};

const HybridShadowReceiverBounds = struct {
    valid_min_x: i32,
    valid_min_y: i32,
    valid_max_x: i32,
    valid_max_y: i32,
    min_u: f32,
    max_u: f32,
    min_v: f32,
    max_v: f32,
    min_depth: f32,
};

const min_rows_per_parallel_job: usize = 16;

const LightSpaceSample = struct {
    u: f32,
    v: f32,
    depth: f32,
};

const CameraToLightTransform = struct {
    origin_u: f32,
    origin_v: f32,
    origin_depth: f32,
    camera_u: math.Vec3,
    camera_v: math.Vec3,
    camera_depth: math.Vec3,

    fn init(
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        light_basis_right: math.Vec3,
        light_basis_up: math.Vec3,
        light_dir_world: math.Vec3,
    ) CameraToLightTransform {
        return .{
            .origin_u = math.Vec3.dot(camera_position, light_basis_right),
            .origin_v = math.Vec3.dot(camera_position, light_basis_up),
            .origin_depth = math.Vec3.dot(camera_position, light_dir_world),
            .camera_u = math.Vec3.new(
                math.Vec3.dot(basis_right, light_basis_right),
                math.Vec3.dot(basis_up, light_basis_right),
                math.Vec3.dot(basis_forward, light_basis_right),
            ),
            .camera_v = math.Vec3.new(
                math.Vec3.dot(basis_right, light_basis_up),
                math.Vec3.dot(basis_up, light_basis_up),
                math.Vec3.dot(basis_forward, light_basis_up),
            ),
            .camera_depth = math.Vec3.new(
                math.Vec3.dot(basis_right, light_dir_world),
                math.Vec3.dot(basis_up, light_dir_world),
                math.Vec3.dot(basis_forward, light_dir_world),
            ),
        };
    }

    fn project(self: CameraToLightTransform, camera_pos: math.Vec3) LightSpaceSample {
        return .{
            .u = self.origin_u + math.Vec3.dot(camera_pos, self.camera_u),
            .v = self.origin_v + math.Vec3.dot(camera_pos, self.camera_v),
            .depth = self.origin_depth + math.Vec3.dot(camera_pos, self.camera_depth),
        };
    }
};

const HybridShadowGrid = struct {
    basis_right: math.Vec3 = math.Vec3.new(1.0, 0.0, 0.0),
    basis_up: math.Vec3 = math.Vec3.new(0.0, 1.0, 0.0),
    min_u: f32 = 0.0,
    max_u: f32 = 0.0,
    min_v: f32 = 0.0,
    max_v: f32 = 0.0,
    inv_cell_u: f32 = 0.0,
    inv_cell_v: f32 = 0.0,
    active: bool = false,
};

const HybridShadowStats = struct {
    active_tile_count: usize = 0,
    job_count: usize = 0,
    grid_candidate_count: usize = 0,
    unique_candidate_count: usize = 0,
    final_candidate_count: usize = 0,
    accel_rebuild_ms: f32 = 0.0,
    candidate_ms: f32 = 0.0,
    cache_clear_ms: f32 = 0.0,
    execute_ms: f32 = 0.0,
};

const HybridShadowDebugState = struct {
    enabled: bool = false,
    advance_requested: bool = false,
    completed_jobs: usize = 0,

    fn reset(self: *HybridShadowDebugState) void {
        self.advance_requested = false;
        self.completed_jobs = 0;
    }
};

const GroundReason = struct {
    pub const near_plane: u8 = 1 << 0;
    pub const backface: u8 = 1 << 1;
    pub const cross_near: u8 = 1 << 2;
};

const GroundDebugState = struct {
    last_mask: u8 = 0,
    frames_since_log: u32 = 0,
};

const MeshletTelemetry = struct {
    total_meshlets: usize = 0,
    visible_meshlets: usize = 0,
    culled_meshlets: usize = 0,
    emitted_triangles: usize = 0,
    touched_tiles: usize = 0,
};

const max_render_passes = 10;

const RenderPassTiming = struct {
    name: []const u8,
    frame_duration_ms: f32,
    accumulated_ms: f32,
    sampled_ms_per_frame: f32,
    has_sample: bool,
};

const ColorGradeProfile = struct {
    base_curve: [256]u8,
    tone_add_r: [256]i16,
    tone_add_g: [256]i16,
    tone_add_b: [256]i16,
};

const BloomScratch = struct {
    width: usize,
    height: usize,
    ping: []u32,
    pong: []u32,
};

const AOScratch = struct {
    width: usize,
    height: usize,
    ping: []u8,
    pong: []u8,
    depth: []f32,
};

const TemporalAAScratch = struct {
    history_pixels: []u32,
    resolve_pixels: []u32,
    history_depth: []f32,
    valid: bool,
};

const AmbientOcclusionConfig = struct {
    downsample: usize,
    radius: f32,
    strength: f32,
    bias: f32,
    blur_depth_threshold: f32,
};

const DepthOfFieldScratch = struct {
    pixels: []u32,
    width: usize,
    height: usize,
};

const DepthOfFieldJobContext = struct {
    scene_pixels: []u32,
    scratch_pixels: []u32,
    scene_depth: []f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    focal_distance: f32,
    focal_range: f32,
    max_blur_radius: i32,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *DepthOfFieldJobContext = @ptrCast(@alignCast(ctx_ptr));
        const pixels = ctx.scene_pixels;
        const out_pixels = ctx.scratch_pixels;
        const depth = ctx.scene_depth;
        const w = ctx.width;
        const h = ctx.height;
                const max_rad = @as(f32, @floatFromInt(ctx.max_blur_radius));

        for (ctx.start_row..ctx.end_row) |y| {
            for (0..w) |x| {
                const idx = y * w + x;
                const d = depth[idx];
                const dist_from_focal = @abs(d - ctx.focal_distance);
                
                var blur_amount: f32 = 0.0;
                if (dist_from_focal > ctx.focal_range) {
                    blur_amount = @min(1.0, (dist_from_focal - ctx.focal_range) / ctx.focal_range);
                }
                
                const blur_radius = blur_amount * max_rad;
                
                if (blur_radius < 1.0) {
                    out_pixels[idx] = pixels[idx];
                } else {
                    const irad = @as(i32, @intFromFloat(blur_radius));
                    var r_sum: u32 = 0;
                    var g_sum: u32 = 0;
                    var b_sum: u32 = 0;
                    var count: u32 = 0;
                    
                    const min_y = @max(0, @as(i32, @intCast(y)) - irad);
                    const max_y = @min(@as(i32, @intCast(h)) - 1, @as(i32, @intCast(y)) + irad);
                    const min_x = @max(0, @as(i32, @intCast(x)) - irad);
                    const max_x = @min(@as(i32, @intCast(w)) - 1, @as(i32, @intCast(x)) + irad);
                    
                    var sy: i32 = min_y;
                    while (sy <= max_y) : (sy += 1) {
                        var sx: i32 = min_x;
                        while (sx <= max_x) : (sx += 1) {
                            const sidx = @as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx));
                            const p = pixels[sidx];
                            r_sum += (p >> 16) & 0xFF;
                            g_sum += (p >> 8) & 0xFF;
                            b_sum += p & 0xFF;
                            count += 1;
                        }
                    }
                    
                    const out_r = r_sum / count;
                    const out_g = g_sum / count;
                    const out_b = b_sum / count;
                    out_pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
                }
            }
        }
    }
};

const TemporalAAConfig = struct {
    history_weight: f32,
    depth_threshold: f32,
};

const ProjectionParams = struct {
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    near_plane: f32,
    jitter_x: f32,
    jitter_y: f32,
};

const DepthFogConfig = struct {
    near: f32,
    far: f32,
    inv_range: f32,
    strength: f32,
    color_r: i32,
    color_g: i32,
    color_b: i32,
};

const ShadowMap = struct {
    width: usize,
    height: usize,
    depth: []f32,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    min_z: f32,
    max_z: f32,
    inv_extent_x: f32,
    inv_extent_y: f32,
    depth_bias: f32,
    texel_bias: f32,
    active: bool,
};

const ShadowResolveConfig = struct {
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    near_plane: f32,
    darkness_percent: i32,
};

const max_shadow_meshlet_vertices: usize = 64;
const hybrid_shadow_cache_unknown: u8 = 0xFF;
const hybrid_shadow_cache_invalid: u8 = 0xFE;

const ShadowSample = struct {
    valid: bool,
    coverage: f32,

    fn occluded(self: ShadowSample) bool {
        return self.coverage >= 0.5;
    }
};

fn fastScale255(value: u32, factor: u32) u8 {
    const scaled = ((value * factor) + 128) * 257;
    return @intCast(@min(scaled >> 16, 255));
}

fn averageBlur5(sum: i32) u8 {
    return @intCast(@divTrunc(sum + 2, 5));
}

fn buildBloomThresholdCurve(threshold: i32) [256]u8 {
    var lut: [256]u8 = undefined;
    for (0..lut.len) |idx| {
        const luma: i32 = @intCast(idx);
        if (luma <= threshold) {
            lut[idx] = 0;
        } else {
            lut[idx] = clampByte(@divTrunc((luma - threshold) * 255, @max(1, 255 - threshold)));
        }
    }
    return lut;
}

fn buildBloomIntensityLut(intensity_percent: i32) [256]u8 {
    var lut: [256]u8 = undefined;
    for (0..lut.len) |idx| {
        lut[idx] = clampByte(@divTrunc(@as(i32, @intCast(idx)) * intensity_percent, 100));
    }
    return lut;
}

fn validSceneCameraSample(camera_pos: math.Vec3) bool {
    return std.math.isFinite(camera_pos.x) and
        std.math.isFinite(camera_pos.y) and
        std.math.isFinite(camera_pos.z) and
        camera_pos.z > NEAR_CLIP;
}

fn sampleSceneCameraClamped(scene_camera: []const math.Vec3, width: usize, height: usize, x: i32, y: i32) math.Vec3 {
    const clamped_x: usize = @intCast(@min(@as(i32, @intCast(width - 1)), @max(0, x)));
    const clamped_y: usize = @intCast(@min(@as(i32, @intCast(height - 1)), @max(0, y)));
    return scene_camera[clamped_y * width + clamped_x];
}

fn estimateSceneNormal(scene_camera: []const math.Vec3, width: usize, height: usize, center: math.Vec3, x: i32, y: i32, step: i32) math.Vec3 {
    const left = sampleSceneCameraClamped(scene_camera, width, height, x - step, y);
    const right = sampleSceneCameraClamped(scene_camera, width, height, x + step, y);
    const up = sampleSceneCameraClamped(scene_camera, width, height, x, y - step);
    const down = sampleSceneCameraClamped(scene_camera, width, height, x, y + step);

    const tangent_x = if (validSceneCameraSample(left) and validSceneCameraSample(right))
        math.Vec3.sub(right, left)
    else if (validSceneCameraSample(right))
        math.Vec3.sub(right, center)
    else if (validSceneCameraSample(left))
        math.Vec3.sub(center, left)
    else
        math.Vec3.new(0.0, 0.0, 0.0);

    const tangent_y = if (validSceneCameraSample(up) and validSceneCameraSample(down))
        math.Vec3.sub(down, up)
    else if (validSceneCameraSample(down))
        math.Vec3.sub(down, center)
    else if (validSceneCameraSample(up))
        math.Vec3.sub(center, up)
    else
        math.Vec3.new(0.0, 0.0, 0.0);

    var normal = math.Vec3.cross(tangent_x, tangent_y);
    if (math.Vec3.length(normal) <= 1e-4) {
        normal = math.Vec3.scale(center, -1.0);
        if (math.Vec3.length(normal) <= 1e-4) return math.Vec3.new(0.0, 0.0, -1.0);
    }

    normal = math.Vec3.normalize(normal);
    if (math.Vec3.dot(normal, center) > 0.0) {
        normal = math.Vec3.scale(normal, -1.0);
    }
    return normal;
}

const ao_sample_offsets = [_][2]i32{
    .{ 1, 0 },
    .{ -1, 0 },
    .{ 0, 1 },
    .{ 0, -1 },
    .{ 1, 1 },
    .{ -1, 1 },
    .{ 1, -1 },
    .{ -1, -1 },
};

const TemporalAAViewState = struct {
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,

    fn init(
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    ) TemporalAAViewState {
        return .{
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .projection = projection,
        };
    }
};

fn chooseShadowBasis(light_dir_world: math.Vec3) struct { right: math.Vec3, up: math.Vec3, forward: math.Vec3 } {
    const forward = math.Vec3.normalize(math.Vec3.scale(light_dir_world, -1.0));
    const world_up = if (@abs(forward.y) > 0.98)
        math.Vec3.new(1.0, 0.0, 0.0)
    else
        math.Vec3.new(0.0, 1.0, 0.0);
    const right = math.Vec3.normalize(math.Vec3.cross(world_up, forward));
    const up = math.Vec3.normalize(math.Vec3.cross(forward, right));
    return .{ .right = right, .up = up, .forward = forward };
}

fn shadowEdge(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
}

fn rasterizeShadowTriangleRows(shadow: *ShadowMap, start_row: usize, end_row: usize, p0: math.Vec3, p1: math.Vec3, p2: math.Vec3) void {
    if (!shadow.active) return;
    if (start_row >= end_row or end_row > shadow.height) return;

    const scale_x = @as(f32, @floatFromInt(shadow.width - 1)) * shadow.inv_extent_x;
    const scale_y = @as(f32, @floatFromInt(shadow.height - 1)) * shadow.inv_extent_y;

    const s0 = [2]f32{ (p0.x - shadow.min_x) * scale_x, (shadow.max_y - p0.y) * scale_y };
    const s1 = [2]f32{ (p1.x - shadow.min_x) * scale_x, (shadow.max_y - p1.y) * scale_y };
    const s2 = [2]f32{ (p2.x - shadow.min_x) * scale_x, (shadow.max_y - p2.y) * scale_y };

    const area = shadowEdge(s0, s1, s2);
    if (@abs(area) < 1e-5) return;

    const min_x = std.math.clamp(@as(i32, @intFromFloat(@floor(@min(s0[0], @min(s1[0], s2[0]))))), 0, @as(i32, @intCast(shadow.width - 1)));
    const max_x = std.math.clamp(@as(i32, @intFromFloat(@ceil(@max(s0[0], @max(s1[0], s2[0]))))), 0, @as(i32, @intCast(shadow.width - 1)));
    const min_y = std.math.clamp(
        @as(i32, @intFromFloat(@floor(@min(s0[1], @min(s1[1], s2[1]))))),
        @as(i32, @intCast(start_row)),
        @as(i32, @intCast(end_row - 1)),
    );
    const max_y = std.math.clamp(
        @as(i32, @intFromFloat(@ceil(@max(s0[1], @max(s1[1], s2[1]))))),
        @as(i32, @intCast(start_row)),
        @as(i32, @intCast(end_row - 1)),
    );
    if (min_y > max_y) return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const sample = [2]f32{
                @as(f32, @floatFromInt(x)) + 0.5,
                @as(f32, @floatFromInt(y)) + 0.5,
            };
            const w0 = shadowEdge(s1, s2, sample);
            const w1 = shadowEdge(s2, s0, sample);
            const w2 = shadowEdge(s0, s1, sample);

            if ((area > 0.0 and (w0 < 0.0 or w1 < 0.0 or w2 < 0.0)) or
                (area < 0.0 and (w0 > 0.0 or w1 > 0.0 or w2 > 0.0)))
            {
                continue;
            }

            const inv_area = 1.0 / area;
            const depth = (w0 * p0.z + w1 * p1.z + w2 * p2.z) * inv_area;
            const idx = @as(usize, @intCast(y)) * shadow.width + @as(usize, @intCast(x));
            if (depth < shadow.depth[idx]) shadow.depth[idx] = depth;
        }
    }
}

fn reconstructWorldPosition(
    x: usize,
    y: usize,
    depth: f32,
    config_value: ShadowResolveConfig,
) math.Vec3 {
    const sample_x = @as(f32, @floatFromInt(x)) + 0.5;
    const sample_y = @as(f32, @floatFromInt(y)) + 0.5;
    const ndc_x = (sample_x - config_value.center_x) / config_value.center_x;
    const ndc_y = (sample_y - config_value.center_y) / config_value.center_y;
    const camera_x = ndc_x * depth / config_value.x_scale;
    const camera_y = -ndc_y * depth / config_value.y_scale;
    const camera_z = depth;
    return math.Vec3.add(
        config_value.camera_position,
        math.Vec3.add(
            math.Vec3.add(
                math.Vec3.scale(config_value.basis_right, camera_x),
                math.Vec3.scale(config_value.basis_up, camera_y),
            ),
            math.Vec3.scale(config_value.basis_forward, camera_z),
        ),
    );
}

fn sampleShadowOcclusion(shadow: *const ShadowMap, world_pos: math.Vec3) f32 {
    if (!shadow.active) return 0.0;

    const lx = math.Vec3.dot(world_pos, shadow.basis_right);
    const ly = math.Vec3.dot(world_pos, shadow.basis_up);
    const lz = math.Vec3.dot(world_pos, shadow.basis_forward);
    if (lx < shadow.min_x or lx > shadow.max_x or ly < shadow.min_y or ly > shadow.max_y or lz < shadow.min_z or lz > shadow.max_z) return 0.0;

    const tex_x = (lx - shadow.min_x) * shadow.inv_extent_x * @as(f32, @floatFromInt(shadow.width - 1));
    const tex_y = (shadow.max_y - ly) * shadow.inv_extent_y * @as(f32, @floatFromInt(shadow.height - 1));
    const center_x = @as(i32, @intFromFloat(@round(tex_x)));
    const center_y = @as(i32, @intFromFloat(@round(tex_y)));

    const offsets = [_][2]i32{
        .{ 0, 0 },
        .{ -1, 0 },
        .{ 1, 0 },
        .{ 0, -1 },
        .{ 0, 1 },
    };

    var occluded: f32 = 0.0;
    var weight_sum: f32 = 0.0;
    for (offsets, 0..) |offset, tap_index| {
        const sx = std.math.clamp(center_x + offset[0], 0, @as(i32, @intCast(shadow.width - 1)));
        const sy = std.math.clamp(center_y + offset[1], 0, @as(i32, @intCast(shadow.height - 1)));
        const sample_idx = @as(usize, @intCast(sy)) * shadow.width + @as(usize, @intCast(sx));
        const stored_depth = shadow.depth[sample_idx];
        if (!std.math.isFinite(stored_depth)) continue;

        const weight: f32 = if (tap_index == 0) 0.4 else 0.15;
        weight_sum += weight;
        if (lz > stored_depth + shadow.depth_bias + shadow.texel_bias) occluded += weight;
    }

    if (weight_sum <= 0.0) return 0.0;
    return occluded / weight_sum;
}

fn darkenPackedColor(pixel: u32, scale: f32) u32 {
    const alpha = pixel & 0xFF000000;
    const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * scale));
    const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * scale));
    const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * scale));
    return alpha |
        (@as(u32, clampByte(r)) << 16) |
        (@as(u32, clampByte(g)) << 8) |
        @as(u32, clampByte(b));
}

fn darkenPixelSpan(pixels: []u32, start_index: usize, end_index: usize, scale: f32) void {
    if (start_index >= end_index) return;

    const scale_vec: ShadowFloatVec = @splat(scale);
    const max_channel: ShadowFloatVec = @splat(255.0);
    var i = start_index;
    while (i + color_grade_simd_lanes <= end_index) : (i += color_grade_simd_lanes) {
        var alpha: [color_grade_simd_lanes]u32 = undefined;
        var r_arr: [color_grade_simd_lanes]f32 = undefined;
        var g_arr: [color_grade_simd_lanes]f32 = undefined;
        var b_arr: [color_grade_simd_lanes]f32 = undefined;

        inline for (0..color_grade_simd_lanes) |lane| {
            const pixel = pixels[i + lane];
            alpha[lane] = pixel & 0xFF000000;
            r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
            g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
            b_arr[lane] = @floatFromInt(pixel & 0xFF);
        }

        const r_scaled = @min(@as(ShadowFloatVec, @bitCast(r_arr)) * scale_vec, max_channel);
        const g_scaled = @min(@as(ShadowFloatVec, @bitCast(g_arr)) * scale_vec, max_channel);
        const b_scaled = @min(@as(ShadowFloatVec, @bitCast(b_arr)) * scale_vec, max_channel);
        const r_out: [color_grade_simd_lanes]i32 = @bitCast(@as(ShadowIntVec, @intFromFloat(r_scaled)));
        const g_out: [color_grade_simd_lanes]i32 = @bitCast(@as(ShadowIntVec, @intFromFloat(g_scaled)));
        const b_out: [color_grade_simd_lanes]i32 = @bitCast(@as(ShadowIntVec, @intFromFloat(b_scaled)));

        inline for (0..color_grade_simd_lanes) |lane| {
            pixels[i + lane] = alpha[lane] |
                (@as(u32, @intCast(r_out[lane])) << 16) |
                (@as(u32, @intCast(g_out[lane])) << 8) |
                @as(u32, @intCast(b_out[lane]));
        }
    }

    while (i < end_index) : (i += 1) {
        pixels[i] = darkenPackedColor(pixels[i], scale);
    }
}

fn cameraToWorldPosition(
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    camera_pos: math.Vec3,
) math.Vec3 {
    return math.Vec3.add(
        camera_position,
        math.Vec3.add(
            math.Vec3.add(
                math.Vec3.scale(basis_right, camera_pos.x),
                math.Vec3.scale(basis_up, camera_pos.y),
            ),
            math.Vec3.scale(basis_forward, camera_pos.z),
        ),
    );
}

const taa_jitter_sequence = [_]math.Vec2{
    .{ .x = 0.0, .y = -0.083333334 },
    .{ .x = -0.125, .y = 0.083333334 },
    .{ .x = 0.125, .y = -0.19444445 },
    .{ .x = -0.1875, .y = -0.027777778 },
    .{ .x = 0.0625, .y = 0.1388889 },
    .{ .x = -0.0625, .y = -0.1388889 },
    .{ .x = 0.1875, .y = 0.027777778 },
    .{ .x = -0.21875, .y = 0.19444445 },
};

fn taaJitterForFrame(frame_index: u64) math.Vec2 {
    return taa_jitter_sequence[@as(usize, @intCast(frame_index % taa_jitter_sequence.len))];
}

fn projectCameraPositionFloat(position: math.Vec3, projection: ProjectionParams) math.Vec2 {
    const clamped_z = if (position.z < projection.near_plane + NEAR_EPSILON)
        projection.near_plane + NEAR_EPSILON
    else
        position.z;
    const inv_z = 1.0 / clamped_z;
    const ndc_x = position.x * inv_z * projection.x_scale;
    const ndc_y = position.y * inv_z * projection.y_scale;
    return .{
        .x = ndc_x * projection.center_x + projection.center_x + projection.jitter_x,
        .y = -ndc_y * projection.center_y + projection.center_y + projection.jitter_y,
    };
}

fn sampleHistoryColor(history: []const u32, width: usize, height: usize, screen: math.Vec2) ?[3]f32 {
    if (screen.x < 0.0 or screen.y < 0.0) return null;
    const max_x = @as(f32, @floatFromInt(width - 1));
    const max_y = @as(f32, @floatFromInt(height - 1));
    if (screen.x > max_x or screen.y > max_y) return null;

    const x0_i = @as(i32, @intFromFloat(@floor(screen.x)));
    const y0_i = @as(i32, @intFromFloat(@floor(screen.y)));
    const x1_i = @min(@as(i32, @intCast(width - 1)), x0_i + 1);
    const y1_i = @min(@as(i32, @intCast(height - 1)), y0_i + 1);
    const frac_x = std.math.clamp(screen.x - @as(f32, @floatFromInt(x0_i)), 0.0, 1.0);
    const frac_y = std.math.clamp(screen.y - @as(f32, @floatFromInt(y0_i)), 0.0, 1.0);
    const x0: usize = @intCast(x0_i);
    const y0: usize = @intCast(y0_i);
    const x1: usize = @intCast(x1_i);
    const y1: usize = @intCast(y1_i);

    const c00 = history[y0 * width + x0];
    const c10 = history[y0 * width + x1];
    const c01 = history[y1 * width + x0];
    const c11 = history[y1 * width + x1];

    const top_r = @as(f32, @floatFromInt((c00 >> 16) & 0xFF)) + (@as(f32, @floatFromInt((c10 >> 16) & 0xFF)) - @as(f32, @floatFromInt((c00 >> 16) & 0xFF))) * frac_x;
    const top_g = @as(f32, @floatFromInt((c00 >> 8) & 0xFF)) + (@as(f32, @floatFromInt((c10 >> 8) & 0xFF)) - @as(f32, @floatFromInt((c00 >> 8) & 0xFF))) * frac_x;
    const top_b = @as(f32, @floatFromInt(c00 & 0xFF)) + (@as(f32, @floatFromInt(c10 & 0xFF)) - @as(f32, @floatFromInt(c00 & 0xFF))) * frac_x;
    const bottom_r = @as(f32, @floatFromInt((c01 >> 16) & 0xFF)) + (@as(f32, @floatFromInt((c11 >> 16) & 0xFF)) - @as(f32, @floatFromInt((c01 >> 16) & 0xFF))) * frac_x;
    const bottom_g = @as(f32, @floatFromInt((c01 >> 8) & 0xFF)) + (@as(f32, @floatFromInt((c11 >> 8) & 0xFF)) - @as(f32, @floatFromInt((c01 >> 8) & 0xFF))) * frac_x;
    const bottom_b = @as(f32, @floatFromInt(c01 & 0xFF)) + (@as(f32, @floatFromInt(c11 & 0xFF)) - @as(f32, @floatFromInt(c01 & 0xFF))) * frac_x;

    return .{
        top_r + (bottom_r - top_r) * frac_y,
        top_g + (bottom_g - top_g) * frac_y,
        top_b + (bottom_b - top_b) * frac_y,
    };
}

fn sampleHistoryDepthNearest(history_depth: []const f32, width: usize, height: usize, screen: math.Vec2) ?f32 {
    const x = @as(i32, @intFromFloat(@floor(screen.x + 0.5)));
    const y = @as(i32, @intFromFloat(@floor(screen.y + 0.5)));
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return null;
    const sample = history_depth[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
    if (!std.math.isFinite(sample)) return null;
    return sample;
}

fn clampHistoryToNeighborhood(pixels: []const u32, width: usize, height: usize, x: usize, y: usize, history_color: [3]f32) [3]f32 {
    var min_r: f32 = 255.0;
    var min_g: f32 = 255.0;
    var min_b: f32 = 255.0;
    var max_r: f32 = 0.0;
    var max_g: f32 = 0.0;
    var max_b: f32 = 0.0;

    var offset_y: i32 = -1;
    while (offset_y <= 1) : (offset_y += 1) {
        const sample_y = @min(@as(i32, @intCast(height - 1)), @max(0, @as(i32, @intCast(y)) + offset_y));
        var offset_x: i32 = -1;
        while (offset_x <= 1) : (offset_x += 1) {
            const sample_x = @min(@as(i32, @intCast(width - 1)), @max(0, @as(i32, @intCast(x)) + offset_x));
            const pixel = pixels[@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))];
            const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF));
            const g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF));
            const b = @as(f32, @floatFromInt(pixel & 0xFF));
            min_r = @min(min_r, r);
            min_g = @min(min_g, g);
            min_b = @min(min_b, b);
            max_r = @max(max_r, r);
            max_g = @max(max_g, g);
            max_b = @max(max_b, b);
        }
    }

    return .{
        std.math.clamp(history_color[0], min_r, max_r),
        std.math.clamp(history_color[1], min_g, max_g),
        std.math.clamp(history_color[2], min_b, max_b),
    };
}

fn blendTemporalColor(current_pixel: u32, history_color: [3]f32, history_weight: f32) u32 {
    const alpha = current_pixel & 0xFF000000;
    const current_weight = 1.0 - history_weight;
    const current_r = @as(f32, @floatFromInt((current_pixel >> 16) & 0xFF));
    const current_g = @as(f32, @floatFromInt((current_pixel >> 8) & 0xFF));
    const current_b = @as(f32, @floatFromInt(current_pixel & 0xFF));
    const out_r = @as(i32, @intFromFloat(current_r * current_weight + history_color[0] * history_weight + 0.5));
    const out_g = @as(i32, @intFromFloat(current_g * current_weight + history_color[1] * history_weight + 0.5));
    const out_b = @as(i32, @intFromFloat(current_b * current_weight + history_color[2] * history_weight + 0.5));
    return alpha |
        (@as(u32, clampByte(out_r)) << 16) |
        (@as(u32, clampByte(out_g)) << 8) |
        @as(u32, clampByte(out_b));
}

fn rayIntersectsSphere(origin: math.Vec3, direction: math.Vec3, center: math.Vec3, radius: f32) bool {
    const oc = math.Vec3.sub(origin, center);
    const b = math.Vec3.dot(oc, direction);
    const c = math.Vec3.dot(oc, oc) - radius * radius;
    if (c <= 0.0) return true;
    const discriminant = b * b - c;
    if (discriminant < 0.0) return false;
    const t = -b - @sqrt(discriminant);
    return t > 0.0;
}

fn rayIntersectsTriangle8(
    orig_x: @Vector(8, f32), orig_y: @Vector(8, f32), orig_z: @Vector(8, f32),
    dir_x: @Vector(8, f32), dir_y: @Vector(8, f32), dir_z: @Vector(8, f32),
    v0x: @Vector(8, f32), v0y: @Vector(8, f32), v0z: @Vector(8, f32),
    v1x: @Vector(8, f32), v1y: @Vector(8, f32), v1z: @Vector(8, f32),
    v2x: @Vector(8, f32), v2y: @Vector(8, f32), v2z: @Vector(8, f32),
    active_mask: @Vector(8, bool),
) bool {
    const eps: @Vector(8, f32) = @splat(1e-6);
    const zeros: @Vector(8, f32) = @splat(0.0);
    const ones: @Vector(8, f32) = @splat(1.0);

    const edge1_x = v1x - v0x;
    const edge1_y = v1y - v0y;
    const edge1_z = v1z - v0z;

    const edge2_x = v2x - v0x;
    const edge2_y = v2y - v0y;
    const edge2_z = v2z - v0z;

    const pvec_x = dir_y * edge2_z - dir_z * edge2_y;
    const pvec_y = dir_z * edge2_x - dir_x * edge2_z;
    const pvec_z = dir_x * edge2_y - dir_y * edge2_x;

    const det = edge1_x * pvec_x + edge1_y * pvec_y + edge1_z * pvec_z;
    const valid_det = @abs(det) >= eps;

    const inv_det = ones / det;

    const tvec_x = orig_x - v0x;
    const tvec_y = orig_y - v0y;
    const tvec_z = orig_z - v0z;

    const u = (tvec_x * pvec_x + tvec_y * pvec_y + tvec_z * pvec_z) * inv_det;
    const valid_u_min = u >= zeros;
    const valid_u_max = u <= ones;

    const qvec_x = tvec_y * edge1_z - tvec_z * edge1_y;
    const qvec_y = tvec_z * edge1_x - tvec_x * edge1_z;
    const qvec_z = tvec_x * edge1_y - tvec_y * edge1_x;

    const v = (dir_x * qvec_x + dir_y * qvec_y + dir_z * qvec_z) * inv_det;
    const valid_v_min = v >= zeros;
    const valid_v_max = (u + v) <= ones;

    const t = (edge2_x * qvec_x + edge2_y * qvec_y + edge2_z * qvec_z) * inv_det;
    const valid_t = t > eps;
    
    var hit = active_mask;
    hit = @select(bool, hit, valid_det, @as(@Vector(8, bool), @splat(false)));
    hit = @select(bool, hit, valid_u_min, @as(@Vector(8, bool), @splat(false)));
    hit = @select(bool, hit, valid_u_max, @as(@Vector(8, bool), @splat(false)));
    hit = @select(bool, hit, valid_v_min, @as(@Vector(8, bool), @splat(false)));
    hit = @select(bool, hit, valid_v_max, @as(@Vector(8, bool), @splat(false)));
    hit = @select(bool, hit, valid_t, @as(@Vector(8, bool), @splat(false)));

    return @reduce(.Or, hit);
}

fn rayIntersectsTriangle(origin: math.Vec3, direction: math.Vec3, v0: math.Vec3, v1: math.Vec3, v2: math.Vec3) bool {
    const eps: f32 = 1e-6;
    const edge1 = math.Vec3.sub(v1, v0);
    const edge2 = math.Vec3.sub(v2, v0);
    const pvec = math.Vec3.cross(direction, edge2);
    const det = math.Vec3.dot(edge1, pvec);
    if (@abs(det) < eps) return false;

    const inv_det = 1.0 / det;
    const tvec = math.Vec3.sub(origin, v0);
    const u = math.Vec3.dot(tvec, pvec) * inv_det;
    if (u < 0.0 or u > 1.0) return false;

    const qvec = math.Vec3.cross(tvec, edge1);
    const v = math.Vec3.dot(direction, qvec) * inv_det;
    if (v < 0.0 or (u + v) > 1.0) return false;

    const t = math.Vec3.dot(edge2, qvec) * inv_det;
    return t > eps;
}

fn rasterizeShadowMeshRange(mesh: *const Mesh, shadow: *ShadowMap, start_row: usize, end_row: usize, light_dir_world: math.Vec3) void {
    if (!shadow.active) return;

    const basis = shadow.basis_right;
    const basis_up = shadow.basis_up;
    const basis_forward = shadow.basis_forward;

    for (mesh.meshlets) |*meshlet| {
        const meshlet_vertices = mesh.meshletVertexSlice(meshlet);
        if (meshlet_vertices.len > max_shadow_meshlet_vertices) continue;

        var local_light_vertices: [max_shadow_meshlet_vertices]math.Vec3 = undefined;
        for (meshlet_vertices, 0..) |global_idx, local_idx| {
            const world = mesh.vertices[global_idx];
            local_light_vertices[local_idx] = math.Vec3.new(
                math.Vec3.dot(world, basis),
                math.Vec3.dot(world, basis_up),
                math.Vec3.dot(world, basis_forward),
            );
        }

        for (mesh.meshletPrimitiveSlice(meshlet)) |primitive| {
            const tri_idx = primitive.triangle_index;
            if (tri_idx >= mesh.normals.len) continue;

            const normal = mesh.normals[tri_idx];
            if (math.Vec3.dot(normal, light_dir_world) <= 0.0) continue;

            const p0 = local_light_vertices[@as(usize, primitive.local_v0)];
            const p1 = local_light_vertices[@as(usize, primitive.local_v1)];
            const p2 = local_light_vertices[@as(usize, primitive.local_v2)];
            rasterizeShadowTriangleRows(shadow, start_row, end_row, p0, p1, p2);
        }
    }
}

fn extractBloomDownsampleRows(
    src: []u32,
    src_width: usize,
    src_height: usize,
    bloom: *BloomScratch,
    threshold_curve: *const [256]u8,
    start_row: usize,
    end_row: usize,
) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const sy0 = @min(src_height - 1, y << 2);
        const sy1 = @min(src_height - 1, sy0 + 1);
        const sy2 = @min(src_height - 1, sy0 + 2);
        const sy3 = @min(src_height - 1, sy0 + 3);
        const row0 = sy0 * src_width;
        const row1 = sy1 * src_width;
        const row2 = sy2 * src_width;
        const row3 = sy3 * src_width;
        const dst_row = y * bloom.width;
        var x: usize = 0;
        while (x < bloom.width) : (x += 1) {
            const sx = x << 2;
            var r_sum: u32 = 0;
            var g_sum: u32 = 0;
            var b_sum: u32 = 0;

            if (sx + 3 < src_width) {
                inline for (0..4) |dx| {
                    const p0 = src[row0 + sx + dx];
                    const p1 = src[row1 + sx + dx];
                    const p2 = src[row2 + sx + dx];
                    const p3 = src[row3 + sx + dx];

                    r_sum += (p0 >> 16) & 0xFF;
                    g_sum += (p0 >> 8) & 0xFF;
                    b_sum += p0 & 0xFF;

                    r_sum += (p1 >> 16) & 0xFF;
                    g_sum += (p1 >> 8) & 0xFF;
                    b_sum += p1 & 0xFF;

                    r_sum += (p2 >> 16) & 0xFF;
                    g_sum += (p2 >> 8) & 0xFF;
                    b_sum += p2 & 0xFF;

                    r_sum += (p3 >> 16) & 0xFF;
                    g_sum += (p3 >> 8) & 0xFF;
                    b_sum += p3 & 0xFF;
                }
            } else {
                inline for (0..4) |dx| {
                    const sample_x = @min(src_width - 1, sx + dx);
                    const p0 = src[row0 + sample_x];
                    const p1 = src[row1 + sample_x];
                    const p2 = src[row2 + sample_x];
                    const p3 = src[row3 + sample_x];

                    r_sum += (p0 >> 16) & 0xFF;
                    g_sum += (p0 >> 8) & 0xFF;
                    b_sum += p0 & 0xFF;

                    r_sum += (p1 >> 16) & 0xFF;
                    g_sum += (p1 >> 8) & 0xFF;
                    b_sum += p1 & 0xFF;

                    r_sum += (p2 >> 16) & 0xFF;
                    g_sum += (p2 >> 8) & 0xFF;
                    b_sum += p2 & 0xFF;

                    r_sum += (p3 >> 16) & 0xFF;
                    g_sum += (p3 >> 8) & 0xFF;
                    b_sum += p3 & 0xFF;
                }
            }

            const r = r_sum >> 4;
            const g = g_sum >> 4;
            const b = b_sum >> 4;
            const luma: usize = @intCast((r_sum * 77 + g_sum * 150 + b_sum * 29) >> 12);
            const factor = threshold_curve[luma];

            if (factor == 0) {
                bloom.ping[dst_row + x] = 0xFF000000;
                continue;
            }

            const br = fastScale255(r, factor);
            const bg = fastScale255(g, factor);
            const bb = fastScale255(b, factor);
            bloom.ping[dst_row + x] = 0xFF000000 |
                (@as(u32, br) << 16) |
                (@as(u32, bg) << 8) |
                @as(u32, bb);
        }
    }
}

fn blurBloomHorizontalRows(bloom: *BloomScratch, start_row: usize, end_row: usize) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * bloom.width;
        const src_row = bloom.ping[row_start .. row_start + bloom.width];
        const dst_row = bloom.pong[row_start .. row_start + bloom.width];
        const edge1 = @min(bloom.width - 1, @as(usize, 1));
        const edge2 = @min(bloom.width - 1, @as(usize, 2));
        const p0 = src_row[0];
        const p1 = src_row[edge1];
        const p2 = src_row[edge2];
        var r: i32 = @intCast(((p0 >> 16) & 0xFF) * 3 + ((p1 >> 16) & 0xFF) + ((p2 >> 16) & 0xFF));
        var g: i32 = @intCast(((p0 >> 8) & 0xFF) * 3 + ((p1 >> 8) & 0xFF) + ((p2 >> 8) & 0xFF));
        var b: i32 = @intCast((p0 & 0xFF) * 3 + (p1 & 0xFF) + (p2 & 0xFF));
        var x: usize = 0;
        while (x < bloom.width) : (x += 1) {
            dst_row[x] = 0xFF000000 |
                (@as(u32, averageBlur5(r)) << 16) |
                (@as(u32, averageBlur5(g)) << 8) |
                @as(u32, averageBlur5(b));

            if (x + 1 >= bloom.width) break;
            const remove_idx = if (x >= 2) x - 2 else 0;
            const add_idx = @min(bloom.width - 1, x + 3);
            const remove_pixel = src_row[remove_idx];
            const add_pixel = src_row[add_idx];
            r += @as(i32, @intCast((add_pixel >> 16) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 16) & 0xFF));
            g += @as(i32, @intCast((add_pixel >> 8) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 8) & 0xFF));
            b += @as(i32, @intCast(add_pixel & 0xFF)) - @as(i32, @intCast(remove_pixel & 0xFF));
        }
    }
}

fn blurBloomVerticalRows(bloom: *BloomScratch, start_row: usize, end_row: usize) void {
    var x: usize = 0;
    while (x < bloom.width) : (x += 1) {
        var r: i32 = 0;
        var g: i32 = 0;
        var b: i32 = 0;
        var offset: i32 = -2;
        while (offset <= 2) : (offset += 1) {
            const sample_y = @min(
                bloom.height - 1,
                @as(usize, @intCast(@max(0, @as(i32, @intCast(start_row)) + offset))),
            );
            const pixel = bloom.pong[sample_y * bloom.width + x];
            r += @intCast((pixel >> 16) & 0xFF);
            g += @intCast((pixel >> 8) & 0xFF);
            b += @intCast(pixel & 0xFF);
        }

        var current_y = start_row;
        while (current_y < end_row) : (current_y += 1) {
            bloom.ping[current_y * bloom.width + x] = 0xFF000000 |
                (@as(u32, averageBlur5(r)) << 16) |
                (@as(u32, averageBlur5(g)) << 8) |
                @as(u32, averageBlur5(b));

            if (current_y + 1 >= end_row) break;
            const remove_idx = if (current_y >= 2) current_y - 2 else 0;
            const add_idx = @min(bloom.height - 1, current_y + 3);
            const remove_pixel = bloom.pong[remove_idx * bloom.width + x];
            const add_pixel = bloom.pong[add_idx * bloom.width + x];
            r += @as(i32, @intCast((add_pixel >> 16) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 16) & 0xFF));
            g += @as(i32, @intCast((add_pixel >> 8) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 8) & 0xFF));
            b += @as(i32, @intCast(add_pixel & 0xFF)) - @as(i32, @intCast(remove_pixel & 0xFF));
        }
    }
}

fn compositeBloomRows(
    dst: []u32,
    dst_width: usize,
    bloom: *const BloomScratch,
    intensity_lut: *const [256]u8,
    start_row: usize,
    end_row: usize,
) void {
    const max_channel: GradeVec = @splat(255);
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const by = @min(bloom.height - 1, y >> 2);
        const bloom_row = bloom.ping[by * bloom.width ..][0..bloom.width];
        const row_start = y * dst_width;
        var x: usize = 0;
        while (x + color_grade_simd_lanes <= dst_width) : (x += color_grade_simd_lanes) {
            var alpha: [color_grade_simd_lanes]u32 = undefined;
            var r_arr: [color_grade_simd_lanes]i16 = undefined;
            var g_arr: [color_grade_simd_lanes]i16 = undefined;
            var b_arr: [color_grade_simd_lanes]i16 = undefined;
            var add_r_arr: [color_grade_simd_lanes]i16 = undefined;
            var add_g_arr: [color_grade_simd_lanes]i16 = undefined;
            var add_b_arr: [color_grade_simd_lanes]i16 = undefined;

            inline for (0..color_grade_simd_lanes) |lane| {
                const dst_idx = row_start + x + lane;
                const dst_pixel = dst[dst_idx];
                const bloom_pixel = bloom_row[@min(bloom.width - 1, (x + lane) >> 2)];
                alpha[lane] = dst_pixel & 0xFF000000;
                r_arr[lane] = @intCast((dst_pixel >> 16) & 0xFF);
                g_arr[lane] = @intCast((dst_pixel >> 8) & 0xFF);
                b_arr[lane] = @intCast(dst_pixel & 0xFF);
                add_r_arr[lane] = intensity_lut[(bloom_pixel >> 16) & 0xFF];
                add_g_arr[lane] = intensity_lut[(bloom_pixel >> 8) & 0xFF];
                add_b_arr[lane] = intensity_lut[bloom_pixel & 0xFF];
            }

            const r_src: GradeVec = @bitCast(r_arr);
            const g_src: GradeVec = @bitCast(g_arr);
            const b_src: GradeVec = @bitCast(b_arr);
            const add_r_vec: GradeVec = @bitCast(add_r_arr);
            const add_g_vec: GradeVec = @bitCast(add_g_arr);
            const add_b_vec: GradeVec = @bitCast(add_b_arr);
            const r_vec: GradeVec = @as(GradeVec, @min(r_src + add_r_vec, max_channel));
            const g_vec: GradeVec = @as(GradeVec, @min(g_src + add_g_vec, max_channel));
            const b_vec: GradeVec = @as(GradeVec, @min(b_src + add_b_vec, max_channel));
            const r_out: [color_grade_simd_lanes]i16 = @bitCast(r_vec);
            const g_out: [color_grade_simd_lanes]i16 = @bitCast(g_vec);
            const b_out: [color_grade_simd_lanes]i16 = @bitCast(b_vec);

            inline for (0..color_grade_simd_lanes) |lane| {
                dst[row_start + x + lane] = alpha[lane] |
                    (@as(u32, @intCast(r_out[lane])) << 16) |
                    (@as(u32, @intCast(g_out[lane])) << 8) |
                    @as(u32, @intCast(b_out[lane]));
            }
        }

        while (x < dst_width) : (x += 1) {
            const bloom_pixel = bloom_row[@min(bloom.width - 1, x >> 2)];
            const idx = row_start + x;
            const dst_pixel = dst[idx];
            const a = dst_pixel & 0xFF000000;
            const r = @as(i32, @intCast((dst_pixel >> 16) & 0xFF)) + intensity_lut[(bloom_pixel >> 16) & 0xFF];
            const g = @as(i32, @intCast((dst_pixel >> 8) & 0xFF)) + intensity_lut[(bloom_pixel >> 8) & 0xFF];
            const b = @as(i32, @intCast(dst_pixel & 0xFF)) + intensity_lut[bloom_pixel & 0xFF];
            dst[idx] = a |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        }
    }
}

fn renderAmbientOcclusionRows(
    scene_camera: []const math.Vec3,
    scene_width: usize,
    scene_height: usize,
    ao: *AOScratch,
    config_value: AmbientOcclusionConfig,
    start_row: usize,
    end_row: usize,
) void {
    const radius_sq = config_value.radius * config_value.radius;
    const half_step: i32 = @intCast(config_value.downsample / 2);
    const sample_step: i32 = @intCast(@max(@as(usize, 1), config_value.downsample));

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const scene_y = @min(scene_height - 1, y * config_value.downsample + @as(usize, @intCast(half_step)));
        const dst_row = y * ao.width;
        var x: usize = 0;
        while (x < ao.width) : (x += 1) {
            const scene_x = @min(scene_width - 1, x * config_value.downsample + @as(usize, @intCast(half_step)));
            const dst_idx = dst_row + x;
            const center = scene_camera[scene_y * scene_width + scene_x];
            if (!validSceneCameraSample(center)) {
                ao.ping[dst_idx] = 255;
                ao.depth[dst_idx] = std.math.inf(f32);
                continue;
            }

            ao.depth[dst_idx] = center.z;
            const normal = estimateSceneNormal(
                scene_camera,
                scene_width,
                scene_height,
                center,
                @intCast(scene_x),
                @intCast(scene_y),
                sample_step,
            );

            var occlusion: f32 = 0.0;
            var sample_count: usize = 0;
            for (ao_sample_offsets) |offset| {
                const sample = sampleSceneCameraClamped(
                    scene_camera,
                    scene_width,
                    scene_height,
                    @as(i32, @intCast(scene_x)) + offset[0] * sample_step,
                    @as(i32, @intCast(scene_y)) + offset[1] * sample_step,
                );
                if (!validSceneCameraSample(sample)) continue;

                const delta = math.Vec3.sub(sample, center);
                const distance_sq = math.Vec3.dot(delta, delta);
                if (distance_sq <= 1e-5 or distance_sq > radius_sq) continue;

                const distance = @sqrt(distance_sq);
                const ndot = math.Vec3.dot(normal, math.Vec3.scale(delta, 1.0 / distance)) - config_value.bias;
                if (ndot <= 0.0) continue;

                const range_weight = 1.0 - (distance_sq / radius_sq);
                occlusion += ndot * range_weight;
                sample_count += 1;
            }

            if (sample_count == 0) {
                ao.ping[dst_idx] = 255;
                continue;
            }

            const normalized = occlusion / @as(f32, @floatFromInt(sample_count));
            const visibility = @max(0.0, 1.0 - @min(1.0, normalized * config_value.strength));
            ao.ping[dst_idx] = @intFromFloat(visibility * 255.0 + 0.5);
        }
    }
}

fn blurAmbientOcclusionHorizontalRows(ao: *AOScratch, depth_threshold: f32, start_row: usize, end_row: usize) void {
    const weights = [_]u32{ 1, 2, 3, 2, 1 };
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * ao.width;
        var x: usize = 0;
        while (x < ao.width) : (x += 1) {
            const idx = row_start + x;
            const center_depth = ao.depth[idx];
            if (!std.math.isFinite(center_depth)) {
                ao.pong[idx] = 255;
                continue;
            }

            var sum: u32 = 0;
            var weight_sum: u32 = 0;
            var tap: usize = 0;
            while (tap < weights.len) : (tap += 1) {
                const offset: i32 = @intCast(tap);
                const sample_x: usize = @intCast(@min(
                    @as(i32, @intCast(ao.width - 1)),
                    @max(0, @as(i32, @intCast(x)) + offset - 2),
                ));
                const sample_idx = row_start + sample_x;
                const sample_depth = ao.depth[sample_idx];
                if (!std.math.isFinite(sample_depth) or @abs(sample_depth - center_depth) > depth_threshold) continue;
                sum += @as(u32, ao.ping[sample_idx]) * weights[tap];
                weight_sum += weights[tap];
            }

            ao.pong[idx] = if (weight_sum == 0) ao.ping[idx] else @intCast(@divTrunc(sum + (weight_sum / 2), weight_sum));
        }
    }
}

fn blurAmbientOcclusionVerticalRows(ao: *AOScratch, depth_threshold: f32, start_row: usize, end_row: usize) void {
    const weights = [_]u32{ 1, 2, 3, 2, 1 };
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * ao.width;
        var x: usize = 0;
        while (x < ao.width) : (x += 1) {
            const idx = row_start + x;
            const center_depth = ao.depth[idx];
            if (!std.math.isFinite(center_depth)) {
                ao.ping[idx] = 255;
                continue;
            }

            var sum: u32 = 0;
            var weight_sum: u32 = 0;
            var tap: usize = 0;
            while (tap < weights.len) : (tap += 1) {
                const offset: i32 = @intCast(tap);
                const sample_y: usize = @intCast(@min(
                    @as(i32, @intCast(ao.height - 1)),
                    @max(0, @as(i32, @intCast(y)) + offset - 2),
                ));
                const sample_idx = sample_y * ao.width + x;
                const sample_depth = ao.depth[sample_idx];
                if (!std.math.isFinite(sample_depth) or @abs(sample_depth - center_depth) > depth_threshold) continue;
                sum += @as(u32, ao.pong[sample_idx]) * weights[tap];
                weight_sum += weights[tap];
            }

            ao.ping[idx] = if (weight_sum == 0) ao.pong[idx] else @intCast(@divTrunc(sum + (weight_sum / 2), weight_sum));
        }
    }
}

fn sampleAmbientOcclusionVisibility(ao: *const AOScratch, scene_width: usize, scene_height: usize, x: usize, y: usize) f32 {
    const u = ((@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(ao.width))) / @as(f32, @floatFromInt(scene_width)) - 0.5;
    const v = ((@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(ao.height))) / @as(f32, @floatFromInt(scene_height)) - 0.5;
    const x0_i = @max(0, @as(i32, @intFromFloat(@floor(u))));
    const y0_i = @max(0, @as(i32, @intFromFloat(@floor(v))));
    const x1_i = @min(@as(i32, @intCast(ao.width - 1)), x0_i + 1);
    const y1_i = @min(@as(i32, @intCast(ao.height - 1)), y0_i + 1);
    const frac_x = @max(0.0, @min(1.0, u - @as(f32, @floatFromInt(x0_i))));
    const frac_y = @max(0.0, @min(1.0, v - @as(f32, @floatFromInt(y0_i))));
    const x0: usize = @intCast(x0_i);
    const y0: usize = @intCast(y0_i);
    const x1: usize = @intCast(x1_i);
    const y1: usize = @intCast(y1_i);

    const s00 = @as(f32, @floatFromInt(ao.ping[y0 * ao.width + x0])) / 255.0;
    const s10 = @as(f32, @floatFromInt(ao.ping[y0 * ao.width + x1])) / 255.0;
    const s01 = @as(f32, @floatFromInt(ao.ping[y1 * ao.width + x0])) / 255.0;
    const s11 = @as(f32, @floatFromInt(ao.ping[y1 * ao.width + x1])) / 255.0;
    const top = s00 + (s10 - s00) * frac_x;
    const bottom = s01 + (s11 - s01) * frac_x;
    return top + (bottom - top) * frac_y;
}

fn compositeAmbientOcclusionRows(
    dst: []u32,
    scene_camera: []const math.Vec3,
    dst_width: usize,
    dst_height: usize,
    ao: *const AOScratch,
    start_row: usize,
    end_row: usize,
) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * dst_width;
        var x: usize = 0;
        while (x < dst_width) : (x += 1) {
            const idx = row_start + x;
            if (!validSceneCameraSample(scene_camera[idx])) continue;

            const visibility = sampleAmbientOcclusionVisibility(ao, dst_width, dst_height, x, y);
            if (visibility >= 0.999) continue;

            const pixel = dst[idx];
            const alpha = pixel & 0xFF000000;
            const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * visibility + 0.5));
            const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * visibility + 0.5));
            const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * visibility + 0.5));
            dst[idx] = alpha |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        }
    }
}

fn colorGradeSimdLanes() comptime_int {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => blk: {
            const features = builtin.target.cpu.features;
            if (std.Target.x86.featureSetHas(features, .avx512bw)) break :blk 32;
            if (std.Target.x86.featureSetHas(features, .avx2)) break :blk 16;
            break :blk 8;
        },
        .aarch64 => 8,
        else => 8,
    };
}

const color_grade_simd_lanes = colorGradeSimdLanes();
const GradeVec = @Vector(color_grade_simd_lanes, i16);
const ShadowFloatVec = @Vector(color_grade_simd_lanes, f32);
const ShadowIntVec = @Vector(color_grade_simd_lanes, i32);

// HGDIOBJ: A "handle" (like an ID) to a Windows graphics object.
const HGDIOBJ = *anyopaque;

// SRCCOPY: A Windows constant that tells BitBlt to do a direct pixel copy.
const SRCCOPY = 0x00CC0020;
const TRANSPARENT = 1;

// ========== WINDOWS API DECLARATIONS ==========
// These are external function definitions for the Windows Graphics Device Interface (GDI).
// JS Analogy: This is like the low-level native browser code that the Canvas API calls.
extern "user32" fn GetDC(hWnd: windows.HWND) ?windows.HDC;
extern "user32" fn ReleaseDC(hWnd: windows.HWND, hDC: windows.HDC) i32;
extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;
extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;
extern "gdi32" fn BitBlt(hdcDest: windows.HDC, nXDest: i32, nYDest: i32, nWidth: i32, nHeight: i32, hdcSrc: windows.HDC, nXSrc: i32, nYSrc: i32, dwRop: u32) bool;
extern "gdi32" fn StretchBlt(hdcDest: windows.HDC, nXOriginDest: i32, nYOriginDest: i32, nWidthDest: i32, nHeightDest: i32, hdcSrc: windows.HDC, nXOriginSrc: i32, nYOriginSrc: i32, nWidthSrc: i32, nHeightSrc: i32, dwRop: u32) bool;
extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;
extern "gdi32" fn SetBkMode(hdc: windows.HDC, mode: i32) i32;
extern "gdi32" fn SetTextColor(hdc: windows.HDC, color: u32) u32;
extern "gdi32" fn TextOutW(hdc: windows.HDC, x: i32, y: i32, lpString: [*]const u16, c: i32) bool;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) bool;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// ========== MODULE IMPORTS ==========
const Bitmap = @import("bitmap.zig").Bitmap;
const TileRenderer = @import("tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("binning_stage.zig");
const job_system_module = @import("job_system.zig");
const JobSystem = job_system_module.JobSystem;
const Job = job_system_module.Job;

const ColorGradeJobContext = struct {
    pixels: []u32,
    start_index: usize,
    end_index: usize,
    profile: *const ColorGradeProfile,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *ColorGradeJobContext = @ptrCast(@alignCast(ctx_ptr));
        applyBlockbusterGradeRange(ctx.pixels, ctx.start_index, ctx.end_index, ctx.profile);
    }
};

const BloomPassStage = enum {
    extract,
    blur_horizontal,
    blur_vertical,
    composite,
};

const AOPassStage = enum {
    generate,
    blur_horizontal,
    blur_vertical,
    composite,
};

const FogJobContext = struct {
    pixels: []u32,
    depth: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    config: DepthFogConfig,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *FogJobContext = @ptrCast(@alignCast(ctx_ptr));
        applyDepthFogRows(ctx.pixels, ctx.depth, ctx.width, ctx.start_row, ctx.end_row, ctx.config);
    }
};

const AOJobContext = struct {
    renderer: *Renderer,
    stage: AOPassStage,
    scene_width: usize,
    scene_height: usize,
    start_row: usize,
    end_row: usize,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *AOJobContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.runAmbientOcclusionStageRange(ctx.stage, ctx.start_row, ctx.end_row, ctx.scene_width, ctx.scene_height);
    }
};

const TAAJobContext = struct {
    renderer: *Renderer,
    current_view: TemporalAAViewState,
    previous_view: TemporalAAViewState,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *TAAJobContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.applyTemporalAARows(
            ctx.current_view,
            ctx.previous_view,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            ctx.height,
        );
    }
};

const ShadowResolveJobContext = struct {
    pixels: []u32,
    camera_buffer: []const math.Vec3,
    width: usize,
    start_row: usize,
    end_row: usize,
    config: ShadowResolveConfig,
    shadow: *const ShadowMap,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *ShadowResolveJobContext = @ptrCast(@alignCast(ctx_ptr));
        applyShadowRows(ctx.pixels, ctx.camera_buffer, ctx.width, ctx.start_row, ctx.end_row, ctx.config, ctx.shadow);
    }
};

const ShadowRasterJobContext = struct {
    mesh: *const Mesh,
    shadow: *ShadowMap,
    start_row: usize,
    end_row: usize,
    light_dir_world: math.Vec3,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *ShadowRasterJobContext = @ptrCast(@alignCast(ctx_ptr));
        rasterizeShadowMeshRange(ctx.mesh, ctx.shadow, ctx.start_row, ctx.end_row, ctx.light_dir_world);
    }
};

const AdaptiveShadowTileJob = struct {
    renderer: *Renderer,
    mesh: *const Mesh,
    tile: *const TileRenderer.Tile,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    light_dir_world: math.Vec3,
    camera_to_light: CameraToLightTransform,
    darkness_scale: f32,
    valid_min_x: i32,
    valid_min_y: i32,
    valid_max_x: i32,
    valid_max_y: i32,
    candidate_offset: usize,
    candidate_count: usize,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *AdaptiveShadowTileJob = @ptrCast(@alignCast(ctx_ptr));
        if (ctx.candidate_count == 0 or ctx.valid_max_x < ctx.valid_min_x or ctx.valid_max_y < ctx.valid_min_y) return;
        const width = ctx.valid_max_x - ctx.valid_min_x + 1;
        const height = ctx.valid_max_y - ctx.valid_min_y + 1;
        if (width <= 0 or height <= 0) return;
        ctx.processBlock(ctx.valid_min_x, ctx.valid_min_y, width, height, 0);
    }

    fn processBlock(ctx: *AdaptiveShadowTileJob, x: i32, y: i32, width: i32, height: i32, depth: u32) void {
        if (width <= 0 or height <= 0) return;

        const classification = ctx.classifyBlock(x, y, width, height);
        if (!classification.mixed) {
            if (classification.shadowed) ctx.darkenBlock(x, y, width, height);
            return;
        }

        if (width <= config.POST_HYBRID_SHADOW_MIN_BLOCK_SIZE or height <= config.POST_HYBRID_SHADOW_MIN_BLOCK_SIZE or depth >= config.POST_HYBRID_SHADOW_MAX_DEPTH) {
            ctx.resolveBlockExact(x, y, width, height);
            return;
        }

        const half_w = @max(1, @divTrunc(width, 2));
        const half_h = @max(1, @divTrunc(height, 2));
        const rem_w = width - half_w;
        const rem_h = height - half_h;
        ctx.processBlock(x, y, half_w, half_h, depth + 1);
        if (rem_w > 0) ctx.processBlock(x + half_w, y, rem_w, half_h, depth + 1);
        if (rem_h > 0) ctx.processBlock(x, y + half_h, half_w, rem_h, depth + 1);
        if (rem_w > 0 and rem_h > 0) ctx.processBlock(x + half_w, y + half_h, rem_w, rem_h, depth + 1);
    }

    const BlockClassification = struct {
        mixed: bool,
        shadowed: bool,
    };

    fn classifyBlock(ctx: *AdaptiveShadowTileJob, x: i32, y: i32, width: i32, height: i32) BlockClassification {
        const max_x = x + width - 1;
        const max_y = y + height - 1;
        const center_x = x + @divTrunc(width - 1, 2);
        const center_y = y + @divTrunc(height - 1, 2);
        const sample_points = [_][2]i32{
            .{ x, y },
            .{ max_x, y },
            .{ x, max_y },
            .{ max_x, max_y },
            .{ center_x, center_y },
        };

        var any_valid = false;
        var any_occluded = false;
        var any_lit = false;
        var any_invalid = false;
        for (sample_points) |point| {
            const sample = ctx.sampleShadow(point[0], point[1]);
            if (!sample.valid) {
                any_invalid = true;
                continue;
            }
            any_valid = true;
            if (sample.coverage >= 0.65) any_occluded = true;
            if (sample.coverage <= 0.15) any_lit = true;
            if (sample.coverage > 0.15 and sample.coverage < 0.65) {
                any_occluded = true;
                any_lit = true;
            }
        }

        if (!any_valid) return .{ .mixed = false, .shadowed = false };
        if (any_invalid) return .{ .mixed = true, .shadowed = false };
        if (any_occluded and any_lit) return .{ .mixed = true, .shadowed = false };
        return .{ .mixed = false, .shadowed = any_occluded };
    }

    fn evaluateShadowPoint(ctx: *AdaptiveShadowTileJob, screen_x: i32, screen_y: i32) ShadowSample {
        if (screen_x < 0 or screen_y < 0 or screen_x >= ctx.renderer.bitmap.width or screen_y >= ctx.renderer.bitmap.height) {
            return .{ .valid = false, .coverage = 0.0 };
        }

        const scene_idx = @as(usize, @intCast(screen_y * ctx.renderer.bitmap.width + screen_x));
        if (scene_idx >= ctx.renderer.scene_camera.len) return .{ .valid = false, .coverage = 0.0 };

        const camera_pos = ctx.renderer.scene_camera[scene_idx];
        if (!std.math.isFinite(camera_pos.z) or camera_pos.z <= NEAR_CLIP) {
            return .{ .valid = false, .coverage = 0.0 };
        }

        const light_sample = ctx.camera_to_light.project(camera_pos);
        return .{ .valid = true, .coverage = if (ctx.isPointShadowed(camera_pos, light_sample)) 1.0 else 0.0 };
    }

    fn evaluateShadowCellAtScale(ctx: *AdaptiveShadowTileJob, cache_x: usize, cache_y: usize, shadow_scale: i32) ShadowSample {
        const origin_x = @as(i32, @intCast(cache_x * @as(usize, @intCast(shadow_scale))));
        const origin_y = @as(i32, @intCast(cache_y * @as(usize, @intCast(shadow_scale))));
        const max_x = @min(origin_x + shadow_scale - 1, ctx.renderer.bitmap.width - 1);
        const max_y = @min(origin_y + shadow_scale - 1, ctx.renderer.bitmap.height - 1);
        const center_x = @min(origin_x + @divTrunc(shadow_scale, 2), ctx.renderer.bitmap.width - 1);
        const center_y = @min(origin_y + @divTrunc(shadow_scale, 2), ctx.renderer.bitmap.height - 1);
        const center = ctx.evaluateShadowPoint(center_x, center_y);
        if (!center.valid) return .{ .valid = false, .coverage = 0.0 };
        if (center.coverage >= 1.0) return center;
        if (shadow_scale <= 2) return center;

        const corner_a = ctx.evaluateShadowPoint(origin_x, origin_y);
        const corner_b = ctx.evaluateShadowPoint(max_x, max_y);
        var max_coverage = center.coverage;
        if (corner_a.valid and corner_a.coverage > max_coverage) max_coverage = corner_a.coverage;
        if (corner_b.valid and corner_b.coverage > max_coverage) max_coverage = corner_b.coverage;
        if (max_coverage <= 0.0) return .{ .valid = true, .coverage = 0.0 };
        if (max_coverage >= 1.0) return .{ .valid = true, .coverage = 0.5 };
        return .{ .valid = true, .coverage = max_coverage };
    }

    fn sampleShadowCache(
        ctx: *AdaptiveShadowTileJob,
        cache: []u8,
        cache_width: usize,
        cache_height: usize,
        shadow_scale: i32,
        screen_x: i32,
        screen_y: i32,
    ) ShadowSample {
        if (screen_x < 0 or screen_y < 0 or screen_x >= ctx.renderer.bitmap.width or screen_y >= ctx.renderer.bitmap.height) {
            return .{ .valid = false, .coverage = 0.0 };
        }

        const sample_x = @as(f32, @floatFromInt(screen_x)) / @as(f32, @floatFromInt(shadow_scale));
        const sample_y = @as(f32, @floatFromInt(screen_y)) / @as(f32, @floatFromInt(shadow_scale));
        const base_x = std.math.clamp(@as(i32, @intFromFloat(@floor(sample_x))), 0, @as(i32, @intCast(cache_width - 1)));
        const base_y = std.math.clamp(@as(i32, @intFromFloat(@floor(sample_y))), 0, @as(i32, @intCast(cache_height - 1)));
        const next_x = @min(base_x + 1, @as(i32, @intCast(cache_width - 1)));
        const next_y = @min(base_y + 1, @as(i32, @intCast(cache_height - 1)));
        const frac_x = std.math.clamp(sample_x - @as(f32, @floatFromInt(base_x)), 0.0, 1.0);
        const frac_y = std.math.clamp(sample_y - @as(f32, @floatFromInt(base_y)), 0.0, 1.0);

        const CacheTap = struct { valid: bool, coverage: f32 };
        var taps: [4]CacheTap = undefined;
        const coords = [_][2]i32{
            .{ base_x, base_y },
            .{ next_x, base_y },
            .{ base_x, next_y },
            .{ next_x, next_y },
        };

        for (coords, 0..) |coord, tap_index| {
            const cache_idx = @as(usize, @intCast(coord[1])) * cache_width + @as(usize, @intCast(coord[0]));
            var cached = cache[cache_idx];
            if (cached == hybrid_shadow_cache_unknown) {
                const evaluated = ctx.evaluateShadowCellAtScale(@intCast(coord[0]), @intCast(coord[1]), shadow_scale);
                cached = if (!evaluated.valid)
                    hybrid_shadow_cache_invalid
                else
                    @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(evaluated.coverage * 253.0))), 0, 253));
                cache[cache_idx] = cached;
            }

            if (cached == hybrid_shadow_cache_invalid) {
                taps[tap_index] = .{ .valid = false, .coverage = 0.0 };
            } else {
                taps[tap_index] = .{ .valid = true, .coverage = @as(f32, @floatFromInt(cached)) / 253.0 };
            }
        }

        const weights = [_]f32{
            (1.0 - frac_x) * (1.0 - frac_y),
            frac_x * (1.0 - frac_y),
            (1.0 - frac_x) * frac_y,
            frac_x * frac_y,
        };
        var weight_sum: f32 = 0.0;
        var coverage_sum: f32 = 0.0;
        for (taps, 0..) |tap, tap_index| {
            if (!tap.valid) continue;
            weight_sum += weights[tap_index];
            coverage_sum += tap.coverage * weights[tap_index];
        }

        if (weight_sum <= 1e-5) return .{ .valid = false, .coverage = 0.0 };
        return .{ .valid = true, .coverage = coverage_sum / weight_sum };
    }

    fn sampleShadowCacheNearest(
        ctx: *AdaptiveShadowTileJob,
        cache: []u8,
        cache_width: usize,
        cache_height: usize,
        shadow_scale: i32,
        screen_x: i32,
        screen_y: i32,
    ) ShadowSample {
        if (screen_x < 0 or screen_y < 0 or screen_x >= ctx.renderer.bitmap.width or screen_y >= ctx.renderer.bitmap.height) {
            return .{ .valid = false, .coverage = 0.0 };
        }

        const cache_x = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(screen_x)) / @as(f32, @floatFromInt(shadow_scale))))), 0, @as(i32, @intCast(cache_width - 1)));
        const cache_y = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(screen_y)) / @as(f32, @floatFromInt(shadow_scale))))), 0, @as(i32, @intCast(cache_height - 1)));
        const cache_idx = @as(usize, @intCast(cache_y)) * cache_width + @as(usize, @intCast(cache_x));
        var cached = cache[cache_idx];
        if (cached == hybrid_shadow_cache_unknown) {
            const evaluated = ctx.evaluateShadowCellAtScale(@intCast(cache_x), @intCast(cache_y), shadow_scale);
            cached = if (!evaluated.valid)
                hybrid_shadow_cache_invalid
            else
                @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(evaluated.coverage * 253.0))), 0, 253));
            cache[cache_idx] = cached;
        }

        if (cached == hybrid_shadow_cache_invalid) return .{ .valid = false, .coverage = 0.0 };
        return .{ .valid = true, .coverage = @as(f32, @floatFromInt(cached)) / 253.0 };
    }

    fn sampleShadowCoarse(ctx: *AdaptiveShadowTileJob, screen_x: i32, screen_y: i32) ShadowSample {
        return ctx.sampleShadowCacheNearest(
            ctx.renderer.hybrid_shadow_coarse_cache,
            ctx.renderer.hybrid_shadow_coarse_cache_width,
            ctx.renderer.hybrid_shadow_coarse_cache_height,
            @max(1, config.POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE),
            screen_x,
            screen_y,
        );
    }

    fn sampleShadowRefined(ctx: *AdaptiveShadowTileJob, screen_x: i32, screen_y: i32) ShadowSample {
        const coarse = ctx.sampleShadowCoarse(screen_x, screen_y);
        if (!coarse.valid) return coarse;
        if (coarse.coverage <= config.POST_HYBRID_SHADOW_EDGE_MIN_COVERAGE or coarse.coverage >= config.POST_HYBRID_SHADOW_EDGE_MAX_COVERAGE) return coarse;

        // Apply a small 3x3 PCF-style box filter in the edge cache to anti-alias the outline
        var coverage_sum: f32 = 0.0;
        var valid_count: f32 = 0.0;
        
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const sample = ctx.sampleShadowCacheNearest(
                    ctx.renderer.hybrid_shadow_edge_cache,
                    ctx.renderer.hybrid_shadow_edge_cache_width,
                    ctx.renderer.hybrid_shadow_edge_cache_height,
                    @max(1, config.POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE),
                    screen_x + dx,
                    screen_y + dy,
                );
                if (sample.valid) {
                    coverage_sum += sample.coverage;
                    valid_count += 1.0;
                }
            }
        }
        
        if (valid_count == 0.0) return coarse;
        
        const avg_coverage = coverage_sum / valid_count;
        const blend = std.math.clamp(config.POST_HYBRID_SHADOW_EDGE_BLEND, 0.0, 1.0);
        
        return .{
            .valid = true,
            .coverage = avg_coverage * (1.0 - blend) + coarse.coverage * blend,
        };
    }

    fn sampleShadow(ctx: *AdaptiveShadowTileJob, screen_x: i32, screen_y: i32) ShadowSample {
        return ctx.sampleShadowCoarse(screen_x, screen_y);
    }

    fn isPointShadowed(ctx: *AdaptiveShadowTileJob, camera_pos: math.Vec3, light_sample: LightSpaceSample) bool {
        if (ctx.candidate_count == 0) return false;

        const candidates = ctx.renderer.hybrid_shadow_tile_candidates[ctx.candidate_offset .. ctx.candidate_offset + ctx.candidate_count];
        var ray_origin: math.Vec3 = undefined;
        var ray_origin_ready = false;
        for (candidates) |caster_index| {
            if (caster_index >= ctx.renderer.hybrid_shadow_caster_count) continue;
            const caster = ctx.renderer.hybrid_shadow_caster_bounds[caster_index];
            if (caster.max_depth <= light_sample.depth + config.POST_HYBRID_SHADOW_RAY_BIAS) continue;
            if (light_sample.u < caster.min_u or light_sample.u > caster.max_u or light_sample.v < caster.min_v or light_sample.v > caster.max_v) continue;

            if (!ray_origin_ready) {
                const world_pos = cameraToWorldPosition(
                    ctx.camera_position,
                    ctx.basis_right,
                    ctx.basis_up,
                    ctx.basis_forward,
                    camera_pos,
                );
                ray_origin = math.Vec3.add(world_pos, math.Vec3.scale(ctx.light_dir_world, config.POST_HYBRID_SHADOW_RAY_BIAS));
                ray_origin_ready = true;
            }

            const meshlet = &ctx.mesh.meshlets[caster.meshlet_index];
            if (!rayIntersectsSphere(ray_origin, ctx.light_dir_world, meshlet.bounds_center, meshlet.bounds_radius)) continue;
            const primitives = ctx.mesh.meshletPrimitiveSlice(meshlet);
            var prim_i: usize = 0;
            const dir_x: @Vector(8, f32) = @splat(ctx.light_dir_world.x);
            const dir_y: @Vector(8, f32) = @splat(ctx.light_dir_world.y);
            const dir_z: @Vector(8, f32) = @splat(ctx.light_dir_world.z);
            const orig_x: @Vector(8, f32) = @splat(ray_origin.x);
            const orig_y: @Vector(8, f32) = @splat(ray_origin.y);
            const orig_z: @Vector(8, f32) = @splat(ray_origin.z);

            while (prim_i < primitives.len) : (prim_i += 8) {
                var v0x: @Vector(8, f32) = @splat(0);
                var v0y: @Vector(8, f32) = @splat(0);
                var v0z: @Vector(8, f32) = @splat(0);
                var v1x: @Vector(8, f32) = @splat(0);
                var v1y: @Vector(8, f32) = @splat(0);
                var v1z: @Vector(8, f32) = @splat(0);
                var v2x: @Vector(8, f32) = @splat(0);
                var v2y: @Vector(8, f32) = @splat(0);
                var v2z: @Vector(8, f32) = @splat(0);
                var active_mask: @Vector(8, bool) = @splat(false);

                const count = @min(8, primitives.len - prim_i);
                for (0..count) |j| {
                    const tri = ctx.mesh.triangles[primitives[prim_i + j].triangle_index];
                    const v0 = ctx.mesh.vertices[tri.v0];
                    const v1 = ctx.mesh.vertices[tri.v1];
                    const v2 = ctx.mesh.vertices[tri.v2];
                    v0x[j] = v0.x; v0y[j] = v0.y; v0z[j] = v0.z;
                    v1x[j] = v1.x; v1y[j] = v1.y; v1z[j] = v1.z;
                    v2x[j] = v2.x; v2y[j] = v2.y; v2z[j] = v2.z;
                    active_mask[j] = true;
                }

                if (rayIntersectsTriangle8(
                    orig_x, orig_y, orig_z,
                    dir_x, dir_y, dir_z,
                    v0x, v0y, v0z,
                    v1x, v1y, v1z,
                    v2x, v2y, v2z,
                    active_mask
                )) return true;
            }
        }
        return false;
    }

    fn resolveBlockExact(ctx: *AdaptiveShadowTileJob, x: i32, y: i32, width: i32, height: i32) void {
        const sample_stride = @max(1, config.POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE);
        const max_x = x + width;
        const max_y = y + height;

        var block_y = y;
        while (block_y < max_y) : (block_y += sample_stride) {
            if (block_y >= ctx.renderer.bitmap.height) break;
            const block_h = @min(sample_stride, max_y - block_y);
            if (block_h <= 0) continue;

            var block_x = x;
            while (block_x < max_x) : (block_x += sample_stride) {
                if (block_x >= ctx.renderer.bitmap.width) break;
                const block_w = @min(sample_stride, max_x - block_x);
                if (block_w <= 0) continue;

                const sample_x = block_x + @divTrunc(block_w - 1, 2);
                const sample_y = block_y + @divTrunc(block_h - 1, 2);
                const sample = ctx.sampleShadowRefined(sample_x, sample_y);
                if (!sample.valid) continue;
                const coverage = sample.coverage;
                if (coverage <= 0.02) continue;
                if (coverage >= 0.98) {
                    ctx.darkenBlock(block_x, block_y, block_w, block_h);
                    continue;
                }

                const pixel_scale = 1.0 - ((1.0 - ctx.darkness_scale) * coverage);
                var py = block_y;
                while (py < block_y + block_h) : (py += 1) {
                    if (py < 0 or py >= ctx.renderer.bitmap.height) continue;
                    const row_start = @as(usize, @intCast(py * ctx.renderer.bitmap.width + block_x));
                    const row_end = @min(
                        @as(usize, @intCast(py * ctx.renderer.bitmap.width + block_x + block_w)),
                        ctx.renderer.bitmap.pixels.len,
                    );
                    var idx = row_start;
                    while (idx < row_end) : (idx += 1) {
                        ctx.renderer.bitmap.pixels[idx] = darkenPackedColor(ctx.renderer.bitmap.pixels[idx], pixel_scale);
                    }
                }
            }
        }
    }

    fn darkenBlock(ctx: *AdaptiveShadowTileJob, x: i32, y: i32, width: i32, height: i32) void {
        var py = y;
        while (py < y + height) : (py += 1) {
            if (py < 0 or py >= ctx.renderer.bitmap.height) continue;
            const row_start = @as(usize, @intCast(py * ctx.renderer.bitmap.width + x));
            const row_end = @as(usize, @intCast(py * ctx.renderer.bitmap.width + x + width));
            darkenPixelSpan(ctx.renderer.bitmap.pixels, row_start, row_end, ctx.darkness_scale);
        }
    }
};

const BloomJobContext = struct {
    stage: BloomPassStage,
    scene_pixels: []u32,
    scene_width: usize,
    scene_height: usize,
    bloom: *BloomScratch,
    threshold_curve: *const [256]u8,
    intensity_lut: *const [256]u8,
    start_row: usize,
    end_row: usize,

    fn run(ctx_ptr: *anyopaque) void {
        const ctx: *BloomJobContext = @ptrCast(@alignCast(ctx_ptr));
        switch (ctx.stage) {
            .extract => extractBloomDownsampleRows(
                ctx.scene_pixels,
                ctx.scene_width,
                ctx.scene_height,
                ctx.bloom,
                ctx.threshold_curve,
                ctx.start_row,
                ctx.end_row,
            ),
            .blur_horizontal => blurBloomHorizontalRows(ctx.bloom, ctx.start_row, ctx.end_row),
            .blur_vertical => blurBloomVerticalRows(ctx.bloom, ctx.start_row, ctx.end_row),
            .composite => compositeBloomRows(
                ctx.scene_pixels,
                ctx.scene_width,
                ctx.bloom,
                ctx.intensity_lut,
                ctx.start_row,
                ctx.end_row,
            ),
        }
    }
};

fn noopRenderPassJob(ctx: *anyopaque) void {
    _ = ctx;
}

fn applyDepthFogRows(
    pixels: []u32,
    depth_buffer: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    fog: DepthFogConfig,
) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const row_end = row_start + width;
        var idx = row_start;
        while (idx < row_end) : (idx += 1) {
            const depth = depth_buffer[idx];
            if (!std.math.isFinite(depth) or depth <= fog.near) continue;

            const normalized = std.math.clamp((depth - fog.near) * fog.inv_range, 0.0, 1.0);
            if (normalized <= 0.0) continue;

            const factor = normalized * fog.strength;
            if (factor <= 0.001) continue;

            const pixel = pixels[idx];
            const alpha = pixel & 0xFF000000;
            const inv = 1.0 - factor;

            const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * inv + @as(f32, @floatFromInt(fog.color_r)) * factor));
            const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * inv + @as(f32, @floatFromInt(fog.color_g)) * factor));
            const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * inv + @as(f32, @floatFromInt(fog.color_b)) * factor));

            pixels[idx] = alpha |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        }
    }
}

fn applyShadowRows(
    pixels: []u32,
    camera_buffer: []const math.Vec3,
    width: usize,
    start_row: usize,
    end_row: usize,
    config_value: ShadowResolveConfig,
    shadow: *const ShadowMap,
) void {
    if (!shadow.active) return;
    const max_channel: ShadowFloatVec = @splat(255.0);
    const darkness_scale = @as(f32, @floatFromInt(config_value.darkness_percent)) / 100.0;

    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * width;
        const row_end = row_start + width;
        var x: usize = 0;
        while (x + color_grade_simd_lanes <= width) : (x += color_grade_simd_lanes) {
            var alpha: [color_grade_simd_lanes]u32 = undefined;
            var r_arr: [color_grade_simd_lanes]f32 = undefined;
            var g_arr: [color_grade_simd_lanes]f32 = undefined;
            var b_arr: [color_grade_simd_lanes]f32 = undefined;
            var scale_arr: [color_grade_simd_lanes]f32 = undefined;

            inline for (0..color_grade_simd_lanes) |lane| {
                const idx = row_start + x + lane;
                const pixel = pixels[idx];
                alpha[lane] = pixel & 0xFF000000;
                r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
                g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
                b_arr[lane] = @floatFromInt(pixel & 0xFF);
                scale_arr[lane] = 1.0;

                const camera_pos = camera_buffer[idx];
                if (std.math.isFinite(camera_pos.z) and camera_pos.z > config_value.near_plane) {
                    const world_pos = math.Vec3.add(
                        config_value.camera_position,
                        math.Vec3.add(
                            math.Vec3.add(
                                math.Vec3.scale(config_value.basis_right, camera_pos.x),
                                math.Vec3.scale(config_value.basis_up, camera_pos.y),
                            ),
                            math.Vec3.scale(config_value.basis_forward, camera_pos.z),
                        ),
                    );
                    const occlusion = sampleShadowOcclusion(shadow, world_pos);
                    if (occlusion > 0.0) scale_arr[lane] = 1.0 - darkness_scale * occlusion;
                }
            }

            const scale_vec: ShadowFloatVec = @bitCast(scale_arr);
            const r_scaled = @min(@as(ShadowFloatVec, @bitCast(r_arr)) * scale_vec, max_channel);
            const g_scaled = @min(@as(ShadowFloatVec, @bitCast(g_arr)) * scale_vec, max_channel);
            const b_scaled = @min(@as(ShadowFloatVec, @bitCast(b_arr)) * scale_vec, max_channel);
            const r_out: [color_grade_simd_lanes]i32 = @bitCast(@as(ShadowIntVec, @intFromFloat(r_scaled)));
            const g_out: [color_grade_simd_lanes]i32 = @bitCast(@as(ShadowIntVec, @intFromFloat(g_scaled)));
            const b_out: [color_grade_simd_lanes]i32 = @bitCast(@as(ShadowIntVec, @intFromFloat(b_scaled)));

            inline for (0..color_grade_simd_lanes) |lane| {
                pixels[row_start + x + lane] = alpha[lane] |
                    (@as(u32, @intCast(r_out[lane])) << 16) |
                    (@as(u32, @intCast(g_out[lane])) << 8) |
                    @as(u32, @intCast(b_out[lane]));
            }
        }

        while (row_start + x < row_end) : (x += 1) {
            const idx = row_start + x;
            const camera_pos = camera_buffer[idx];
            if (!std.math.isFinite(camera_pos.z) or camera_pos.z <= config_value.near_plane) continue;

            const world_pos = math.Vec3.add(
                config_value.camera_position,
                math.Vec3.add(
                    math.Vec3.add(
                        math.Vec3.scale(config_value.basis_right, camera_pos.x),
                        math.Vec3.scale(config_value.basis_up, camera_pos.y),
                    ),
                    math.Vec3.scale(config_value.basis_forward, camera_pos.z),
                ),
            );
            const occlusion = sampleShadowOcclusion(shadow, world_pos);
            if (occlusion <= 0.0) continue;

            const shadow_scale = 1.0 - darkness_scale * occlusion;
            const pixel = pixels[idx];
            const alpha = pixel & 0xFF000000;
            const r = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * shadow_scale));
            const g = @as(i32, @intFromFloat(@as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * shadow_scale));
            const b = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pixel & 0xFF)) * shadow_scale));

            pixels[idx] = alpha |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        }
    }
}

fn applyBlockbusterGradeRange(pixels: []u32, start_index: usize, end_index: usize, grade: *const ColorGradeProfile) void {
    var i = start_index;
    const zero: GradeVec = @splat(0);
    const max_channel: GradeVec = @splat(255);
    const three: GradeVec = @splat(3);
    const sat_r: GradeVec = @splat(110);
    const sat_g: GradeVec = @splat(104);
    const sat_b: GradeVec = @splat(96);
    const hundred: GradeVec = @splat(100);

    while (i + color_grade_simd_lanes <= end_index) : (i += color_grade_simd_lanes) {
        var alpha: [color_grade_simd_lanes]u32 = undefined;
        var r_arr: [color_grade_simd_lanes]i16 = undefined;
        var g_arr: [color_grade_simd_lanes]i16 = undefined;
        var b_arr: [color_grade_simd_lanes]i16 = undefined;
        var add_r_arr: [color_grade_simd_lanes]i16 = undefined;
        var add_g_arr: [color_grade_simd_lanes]i16 = undefined;
        var add_b_arr: [color_grade_simd_lanes]i16 = undefined;

        inline for (0..color_grade_simd_lanes) |lane| {
            const pixel = pixels[i + lane];
            alpha[lane] = pixel & 0xFF000000;

            const r0 = grade.base_curve[@intCast((pixel >> 16) & 0xFF)];
            const g0 = grade.base_curve[@intCast((pixel >> 8) & 0xFF)];
            const b0 = grade.base_curve[@intCast(pixel & 0xFF)];
            const luma_index: usize = @intCast((@as(u32, r0) * 77 + @as(u32, g0) * 150 + @as(u32, b0) * 29) >> 8);

            r_arr[lane] = r0;
            g_arr[lane] = g0;
            b_arr[lane] = b0;
            add_r_arr[lane] = grade.tone_add_r[luma_index];
            add_g_arr[lane] = grade.tone_add_g[luma_index];
            add_b_arr[lane] = grade.tone_add_b[luma_index];
        }

        var r_vec: GradeVec = @bitCast(r_arr);
        var g_vec: GradeVec = @bitCast(g_arr);
        var b_vec: GradeVec = @bitCast(b_arr);
        r_vec += @bitCast(add_r_arr);
        g_vec += @bitCast(add_g_arr);
        b_vec += @bitCast(add_b_arr);

        const mean = @divTrunc(r_vec + g_vec + b_vec, three);
        r_vec = mean + @divTrunc((r_vec - mean) * sat_r, hundred);
        g_vec = mean + @divTrunc((g_vec - mean) * sat_g, hundred);
        b_vec = mean + @divTrunc((b_vec - mean) * sat_b, hundred);

        const r_clamped: GradeVec = @min(@max(r_vec, zero), max_channel);
        const g_clamped: GradeVec = @min(@max(g_vec, zero), max_channel);
        const b_clamped: GradeVec = @min(@max(b_vec, zero), max_channel);
        const r_out: [color_grade_simd_lanes]i16 = @bitCast(r_clamped);
        const g_out: [color_grade_simd_lanes]i16 = @bitCast(g_clamped);
        const b_out: [color_grade_simd_lanes]i16 = @bitCast(b_clamped);

        inline for (0..color_grade_simd_lanes) |lane| {
            pixels[i + lane] = alpha[lane] |
                (@as(u32, @intCast(r_out[lane])) << 16) |
                (@as(u32, @intCast(g_out[lane])) << 8) |
                @as(u32, @intCast(b_out[lane]));
        }
    }

    while (i < end_index) : (i += 1) {
        const pixel = pixels[i];
        const a: u32 = pixel & 0xFF000000;

        const r0: u8 = grade.base_curve[@intCast((pixel >> 16) & 0xFF)];
        const g0: u8 = grade.base_curve[@intCast((pixel >> 8) & 0xFF)];
        const b0: u8 = grade.base_curve[@intCast(pixel & 0xFF)];

        const luma_index: usize = @intCast((@as(u32, r0) * 77 + @as(u32, g0) * 150 + @as(u32, b0) * 29) >> 8);
        var r: i32 = @as(i32, r0) + grade.tone_add_r[luma_index];
        var g: i32 = @as(i32, g0) + grade.tone_add_g[luma_index];
        var b: i32 = @as(i32, b0) + grade.tone_add_b[luma_index];

        const mean = @divTrunc(r + g + b, 3);
        r = mean + @divTrunc((r - mean) * 110, 100);
        g = mean + @divTrunc((g - mean) * 104, 100);
        b = mean + @divTrunc((b - mean) * 96, 100);

        pixels[i] = a |
            (@as(u32, clampByte(r)) << 16) |
            (@as(u32, clampByte(g)) << 8) |
            @as(u32, clampByte(b));
    }
}

fn clampByte(value: i32) u8 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return @intCast(value);
}

/// The `Renderer` struct holds the entire state of the rendering engine.
/// It manages the window connection, the pixel buffer, the rendering pipeline, and application state.
pub const LightInfo = struct {
    orbit_x: f32,
    orbit_speed: f32,
    distance: f32,
    elevation: f32,
    color: math.Vec3,
    direction: math.Vec3 = math.Vec3.new(0, -1, 0),
    shadow_map: ShadowMap,
};

pub const Renderer = struct {
    // Core rendering resources
    hwnd: windows.HWND, // Handle to the window we are drawing to.
    bitmap: Bitmap, // The main pixel buffer we draw into (our "canvas").
    hdc: ?windows.HDC, // The window's "device context" for drawing.
    hdc_mem: ?windows.HDC, // An in-memory device context for faster drawing operations.
    allocator: std.mem.Allocator,

    // Camera and object state
    rotation_angle: f32, // Camera yaw (left/right rotation).
    rotation_x: f32, // Camera pitch (up/down rotation).
    camera_position: math.Vec3, // Camera world position.
    camera_move_speed: f32, // Units per second for keyboard movement.
    mouse_sensitivity: f32, // Mouse look sensitivity factor.
    pending_mouse_delta: math.Vec2, // Accumulated mouse delta since last frame.
    mouse_initialized: bool, // Tracks whether the initial mouse position has been captured.
    mouse_last_pos: windows.POINT, // Last mouse position in client coordinates.

    // Light state
    lights: std.ArrayList(LightInfo),

    // Input and timing state
    keys_pressed: u32, // Bitmask of currently pressed keys.
    camera_fov_deg: f32,
    frame_count: u32,
    total_frames_rendered: u64,
    last_time: i128,
    last_frame_time: i128,
    current_fps: u32,
    target_frame_time_ns: i128,
    pending_fov_delta: f32,
    profile_capture_frame: u64,
    profile_capture_emitted: bool,

    // Tiled rendering resources
    tile_grid: ?TileGrid, // The grid layout of tiles on the screen.
    tile_buffers: ?[]TileBuffer, // A buffer for each tile to be rendered into in parallel.
    job_system: ?*JobSystem, // The multi-threaded job system.
    tile_jobs_buffer: ?[]TileRenderJob,
    shadow_tile_jobs_buffer: ?[]AdaptiveShadowTileJob,
    job_buffer: ?[]Job,
    job_completion_buffer: ?[]bool,
    tile_triangle_lists: ?[]BinningStage.TileTriangleList,
    active_tile_flags: ?[]bool,
    active_tile_indices: ?[]usize,
    mesh_work_cache: MeshWorkCache = MeshWorkCache.init(),

    // Rendering options and data
    single_texture_binding: [1]?*const texture.Texture,
    textures: []const ?*const texture.Texture,
    show_tile_borders: bool = false,
    show_wireframe: bool = false,
    show_light_orb: bool = true,
    cull_light_orb: bool = true,
    use_tiled_rendering: bool = true,
    show_render_overlay: bool = builtin.mode == .Debug,

    ground_debug: GroundDebugState = .{},
    meshlet_telemetry: MeshletTelemetry = .{},
    render_pass_timings: [max_render_passes]RenderPassTiming,
    render_pass_count: usize,
    color_grade_profile: ColorGradeProfile,
    ambient_occlusion_config: AmbientOcclusionConfig,
    temporal_aa_config: TemporalAAConfig,
    depth_fog_config: DepthFogConfig,
    scene_depth: []f32,
    scene_camera: []math.Vec3,
    taa_scratch: TemporalAAScratch,
    taa_previous_view: TemporalAAViewState,
    hybrid_shadow_coarse_cache: []u8,
    hybrid_shadow_coarse_cache_width: usize,
    hybrid_shadow_coarse_cache_height: usize,
    hybrid_shadow_edge_cache: []u8,
    hybrid_shadow_edge_cache_width: usize,
    hybrid_shadow_edge_cache_height: usize,
    hybrid_shadow_caster_indices: []usize,
    hybrid_shadow_caster_bounds: []HybridShadowCasterBounds,
    hybrid_shadow_caster_count: usize,
    hybrid_shadow_tile_ranges: []HybridShadowTileRange,
    hybrid_shadow_tile_candidates: []usize,
    hybrid_shadow_grid: HybridShadowGrid,
    hybrid_shadow_grid_ranges: [hybrid_shadow_grid_cells]HybridShadowTileRange,
    hybrid_shadow_grid_candidates: []usize,
    hybrid_shadow_candidate_marks: []u32,
    hybrid_shadow_candidate_mark_generation: u32,
    hybrid_shadow_accel_valid: bool,
    hybrid_shadow_cached_light_dir: math.Vec3,
    hybrid_shadow_cached_meshlet_count: usize,
    hybrid_shadow_cached_meshlet_vertex_count: usize,
    hybrid_shadow_cached_meshlet_primitive_count: usize,
    hybrid_shadow_stats: HybridShadowStats = .{},
    hybrid_shadow_debug: HybridShadowDebugState = .{},
    ao_scratch: AOScratch,
    bloom_scratch: BloomScratch,
    ao_job_contexts: []AOJobContext,
    bloom_threshold_curve: [256]u8,
    bloom_intensity_lut: [256]u8,
    fog_job_contexts: []FogJobContext,
    shadow_resolve_job_contexts: []ShadowResolveJobContext,
    shadow_raster_job_contexts: []ShadowRasterJobContext,
    bloom_job_contexts: []BloomJobContext,
    dof_scratch: DepthOfFieldScratch,
    dof_job_contexts: []DepthOfFieldJobContext,
    dof_focal_distance: f32,
    dof_target_focal_distance: f32,
    taa_job_contexts: []TAAJobContext,
    color_grade_job_contexts: []ColorGradeJobContext,
    color_grade_jobs: []Job,

    // Unused state from previous versions
    last_brightness_min: f32,
    last_brightness_max: f32,
    last_brightness_avg: f32,
    last_reported_fov_deg: f32,
    light_marker_visible_last_frame: bool,

    /// Initializes the renderer, creating all necessary resources.
    /// JS Analogy: The `constructor` for our main rendering class.
    pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
        const hdc = GetDC(hwnd) orelse return error.DCNotFound;
        const hdc_mem = CreateCompatibleDC(hdc) orelse {
            _ = ReleaseDC(hwnd, hdc);
            return error.MemoryDCCreationFailed;
        };

        const bitmap = try Bitmap.init(width, height);
        const current_time = std.time.nanoTimestamp();
        const tile_grid = try TileGrid.init(width, height, allocator);

        const tile_buffers = try allocator.alloc(TileBuffer, tile_grid.tiles.len);
        errdefer allocator.free(tile_buffers);
        for (tile_buffers, tile_grid.tiles) |*buf, *tile| {
            buf.* = try TileBuffer.init(tile.width, tile.height, allocator);
        }

        const tile_count = tile_grid.tiles.len;
        const tile_jobs_buffer = try allocator.alloc(TileRenderJob, tile_count);
        errdefer allocator.free(tile_jobs_buffer);
        const shadow_tile_jobs_buffer = try allocator.alloc(AdaptiveShadowTileJob, tile_count);
        errdefer allocator.free(shadow_tile_jobs_buffer);
        const hybrid_shadow_tile_ranges = try allocator.alloc(HybridShadowTileRange, tile_count);
        errdefer allocator.free(hybrid_shadow_tile_ranges);
        const job_buffer = try allocator.alloc(Job, tile_count);
        errdefer allocator.free(job_buffer);
        const job_completion_buffer = try allocator.alloc(bool, tile_count);
        errdefer allocator.free(job_completion_buffer);
        @memset(job_completion_buffer, false);
        const tile_triangle_lists = try BinningStage.createTileTriangleLists(&tile_grid, allocator);
        errdefer BinningStage.freeTileTriangleLists(tile_triangle_lists, allocator);
        const active_tile_flags = try allocator.alloc(bool, tile_count);
        errdefer allocator.free(active_tile_flags);
        @memset(active_tile_flags, false);
        const active_tile_indices = try allocator.alloc(usize, tile_count);
        errdefer allocator.free(active_tile_indices);

        const job_system = try JobSystem.init(allocator);
        const color_grade_job_count = @max(@as(usize, 1), @as(usize, @intCast(job_system.worker_count * 2)));
        const color_grade_job_contexts = try allocator.alloc(ColorGradeJobContext, color_grade_job_count);
        errdefer allocator.free(color_grade_job_contexts);
        const ao_job_contexts = try allocator.alloc(AOJobContext, color_grade_job_count);
        errdefer allocator.free(ao_job_contexts);
        const fog_job_contexts = try allocator.alloc(FogJobContext, color_grade_job_count);
        errdefer allocator.free(fog_job_contexts);
        const taa_job_contexts = try allocator.alloc(TAAJobContext, color_grade_job_count);
        errdefer allocator.free(taa_job_contexts);
        const shadow_resolve_job_contexts = try allocator.alloc(ShadowResolveJobContext, color_grade_job_count);
        errdefer allocator.free(shadow_resolve_job_contexts);
        const shadow_raster_job_contexts = try allocator.alloc(ShadowRasterJobContext, color_grade_job_count);
        errdefer allocator.free(shadow_raster_job_contexts);
        const bloom_job_contexts = try allocator.alloc(BloomJobContext, color_grade_job_count);
        errdefer allocator.free(bloom_job_contexts);
        const fb_pix_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
        const dof_scratch_pixels = try allocator.alloc(u32, fb_pix_count);
        errdefer allocator.free(dof_scratch_pixels);
        const dof_job_contexts = try allocator.alloc(DepthOfFieldJobContext, color_grade_job_count);
        errdefer allocator.free(dof_job_contexts);
        const color_grade_jobs = try allocator.alloc(Job, color_grade_job_count);
        errdefer allocator.free(color_grade_jobs);
        const scene_depth = try allocator.alloc(f32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_depth);
        const scene_camera = try allocator.alloc(math.Vec3, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_camera);
        const taa_history_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_pixels);
        const taa_resolve_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_resolve_pixels);
        const taa_history_depth = try allocator.alloc(f32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_depth);
        const hybrid_shadow_coarse_downsample = @max(1, config.POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE);
        const hybrid_shadow_coarse_cache_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + hybrid_shadow_coarse_downsample - 1, hybrid_shadow_coarse_downsample))));
        const hybrid_shadow_coarse_cache_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + hybrid_shadow_coarse_downsample - 1, hybrid_shadow_coarse_downsample))));
        const hybrid_shadow_coarse_cache = try allocator.alloc(u8, hybrid_shadow_coarse_cache_width * hybrid_shadow_coarse_cache_height);
        errdefer allocator.free(hybrid_shadow_coarse_cache);
        const hybrid_shadow_edge_downsample = @max(1, config.POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE);
        const hybrid_shadow_edge_cache_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + hybrid_shadow_edge_downsample - 1, hybrid_shadow_edge_downsample))));
        const hybrid_shadow_edge_cache_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + hybrid_shadow_edge_downsample - 1, hybrid_shadow_edge_downsample))));
        const hybrid_shadow_edge_cache = try allocator.alloc(u8, hybrid_shadow_edge_cache_width * hybrid_shadow_edge_cache_height);
        errdefer allocator.free(hybrid_shadow_edge_cache);
        var lights = std.ArrayList(LightInfo){};
        for (0..2) |light_idx| {
            const sm_depth = try allocator.alloc(f32, config.POST_SHADOW_MAP_SIZE * config.POST_SHADOW_MAP_SIZE);
            errdefer allocator.free(sm_depth);
            try lights.append(allocator, LightInfo{ .orbit_x = @as(f32, @floatFromInt(light_idx)) * 3.14159, .orbit_speed = 0.5 + @as(f32, @floatFromInt(light_idx)) * 0.2, .distance = config.LIGHT_DISTANCE_INITIAL, .elevation = 0.65, .color = if (light_idx == 0) math.Vec3.new(1.0, 0.9, 0.8) else math.Vec3.new(0.5, 0.6, 1.0), .shadow_map = .{
                .width = config.POST_SHADOW_MAP_SIZE,
                .height = config.POST_SHADOW_MAP_SIZE,
                .depth = sm_depth,
                .basis_right = math.Vec3.new(1.0, 0.0, 0.0),
                .basis_up = math.Vec3.new(0.0, 1.0, 0.0),
                .basis_forward = math.Vec3.new(0.0, 0.0, 1.0),
                .min_x = -1.0,
                .max_x = 1.0,
                .min_y = -1.0,
                .max_y = 1.0,
                .min_z = -1.0,
                .max_z = 1.0,
                .inv_extent_x = 1.0,
                .inv_extent_y = 1.0,
                .depth_bias = config.POST_SHADOW_DEPTH_BIAS,
                .texel_bias = 0.0,
                .active = false,
            } });
        }
        const ao_downsample = @max(1, config.POST_SSAO_DOWNSAMPLE);
        const ao_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + ao_downsample - 1, ao_downsample))));
        const ao_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + ao_downsample - 1, ao_downsample))));
        const ao_pixel_count = ao_width * ao_height;
        const ao_ping = try allocator.alloc(u8, ao_pixel_count);
        errdefer allocator.free(ao_ping);
        const ao_pong = try allocator.alloc(u8, ao_pixel_count);
        errdefer allocator.free(ao_pong);
        const ao_depth = try allocator.alloc(f32, ao_pixel_count);
        errdefer allocator.free(ao_depth);
        const bloom_width = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(width + 3, 4))));
        const bloom_height = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(height + 3, 4))));
        const bloom_pixel_count = bloom_width * bloom_height;
        const bloom_ping = try allocator.alloc(u32, bloom_pixel_count);
        errdefer allocator.free(bloom_ping);
        const bloom_pong = try allocator.alloc(u32, bloom_pixel_count);
        errdefer allocator.free(bloom_pong);

        renderer_logger.infoSub(
            "init",
            "initialized renderer {d}x{d} tiles={} grid={}x{} workers={}",
            .{
                width,
                height,
                tile_count,
                tile_grid.cols,
                tile_grid.rows,
                job_system.worker_count,
            },
        );

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
            .hdc_mem = hdc_mem,
            .allocator = allocator,
            .rotation_angle = 0,
            .rotation_x = 0,
            .camera_position = math.Vec3.new(0.0, 1.5, -5.0),
            .camera_move_speed = 6.0,
            .mouse_sensitivity = 0.0025,
            .pending_mouse_delta = math.Vec2.new(0.0, 0.0),
            .mouse_initialized = false,
            .mouse_last_pos = .{ .x = 0, .y = 0 },
            .lights = lights,
            .camera_fov_deg = config.CAMERA_FOV_INITIAL,
            .keys_pressed = 0,
            .frame_count = 0,
            .total_frames_rendered = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .current_fps = 0,
            .target_frame_time_ns = config.targetFrameTimeNs(),
            .last_brightness_min = 0,
            .last_brightness_max = 0,
            .last_brightness_avg = 0,
            .last_reported_fov_deg = config.CAMERA_FOV_INITIAL,
            .light_marker_visible_last_frame = true,
            .pending_fov_delta = 0.0,
            .profile_capture_frame = try parseProfileCaptureFrame(allocator),
            .profile_capture_emitted = false,
            .tile_grid = tile_grid,
            .tile_buffers = tile_buffers,
            .single_texture_binding = .{null},
            .textures = &.{},
            .use_tiled_rendering = true,
            .job_system = job_system,
            .tile_jobs_buffer = tile_jobs_buffer,
            .shadow_tile_jobs_buffer = shadow_tile_jobs_buffer,
            .job_buffer = job_buffer,
            .job_completion_buffer = job_completion_buffer,
            .tile_triangle_lists = tile_triangle_lists,
            .active_tile_flags = active_tile_flags,
            .active_tile_indices = active_tile_indices,
            .render_pass_timings = [_]RenderPassTiming{.{
                .name = "",
                .frame_duration_ms = 0.0,
                .accumulated_ms = 0.0,
                .sampled_ms_per_frame = 0.0,
                .has_sample = false,
            }} ** max_render_passes,
            .render_pass_count = 0,
            .color_grade_profile = buildBlockbusterGradeProfile(),
            .ambient_occlusion_config = .{
                .downsample = @intCast(ao_downsample),
                .radius = config.POST_SSAO_RADIUS,
                .strength = @as(f32, @floatFromInt(config.POST_SSAO_STRENGTH_PERCENT)) / 100.0,
                .bias = config.POST_SSAO_BIAS,
                .blur_depth_threshold = config.POST_SSAO_BLUR_DEPTH_THRESHOLD,
            },
            .temporal_aa_config = .{
                .history_weight = @as(f32, @floatFromInt(config.POST_TAA_HISTORY_PERCENT)) / 100.0,
                .depth_threshold = config.POST_TAA_DEPTH_THRESHOLD,
            },
            .depth_fog_config = .{
                .near = config.POST_DEPTH_FOG_NEAR,
                .far = config.POST_DEPTH_FOG_FAR,
                .inv_range = 1.0 / @max(0.001, config.POST_DEPTH_FOG_FAR - config.POST_DEPTH_FOG_NEAR),
                .strength = @as(f32, @floatFromInt(config.POST_DEPTH_FOG_STRENGTH_PERCENT)) / 100.0,
                .color_r = config.POST_DEPTH_FOG_COLOR_R,
                .color_g = config.POST_DEPTH_FOG_COLOR_G,
                .color_b = config.POST_DEPTH_FOG_COLOR_B,
            },
            .scene_depth = scene_depth,
            .scene_camera = scene_camera,
            .taa_scratch = .{
                .history_pixels = taa_history_pixels,
                .resolve_pixels = taa_resolve_pixels,
                .history_depth = taa_history_depth,
                .valid = false,
            },
            .taa_previous_view = TemporalAAViewState.init(
                math.Vec3.new(0.0, 1.5, -5.0),
                math.Vec3.new(1.0, 0.0, 0.0),
                math.Vec3.new(0.0, 1.0, 0.0),
                math.Vec3.new(0.0, 0.0, 1.0),
                .{
                    .center_x = 0.0,
                    .center_y = 0.0,
                    .x_scale = 1.0,
                    .y_scale = 1.0,
                    .near_plane = NEAR_CLIP,
                    .jitter_x = 0.0,
                    .jitter_y = 0.0,
                },
            ),
            .hybrid_shadow_coarse_cache = hybrid_shadow_coarse_cache,
            .hybrid_shadow_coarse_cache_width = hybrid_shadow_coarse_cache_width,
            .hybrid_shadow_coarse_cache_height = hybrid_shadow_coarse_cache_height,
            .hybrid_shadow_edge_cache = hybrid_shadow_edge_cache,
            .hybrid_shadow_edge_cache_width = hybrid_shadow_edge_cache_width,
            .hybrid_shadow_edge_cache_height = hybrid_shadow_edge_cache_height,
            .hybrid_shadow_caster_indices = &[_]usize{},
            .hybrid_shadow_caster_bounds = &[_]HybridShadowCasterBounds{},
            .hybrid_shadow_caster_count = 0,
            .hybrid_shadow_tile_ranges = hybrid_shadow_tile_ranges,
            .hybrid_shadow_tile_candidates = &[_]usize{},
            .hybrid_shadow_grid = .{},
            .hybrid_shadow_grid_ranges = [_]HybridShadowTileRange{.{}} ** hybrid_shadow_grid_cells,
            .hybrid_shadow_grid_candidates = &[_]usize{},
            .hybrid_shadow_candidate_marks = &[_]u32{},
            .hybrid_shadow_candidate_mark_generation = 0,
            .hybrid_shadow_accel_valid = false,
            .hybrid_shadow_cached_light_dir = math.Vec3.new(0.0, 0.0, 0.0),
            .hybrid_shadow_cached_meshlet_count = 0,
            .hybrid_shadow_cached_meshlet_vertex_count = 0,
            .hybrid_shadow_cached_meshlet_primitive_count = 0,
            .hybrid_shadow_stats = .{},
            .hybrid_shadow_debug = .{},
            .ao_scratch = .{
                .width = ao_width,
                .height = ao_height,
                .ping = ao_ping,
                .pong = ao_pong,
                .depth = ao_depth,
            },
            .bloom_scratch = .{
                .width = bloom_width,
                .height = bloom_height,
                .ping = bloom_ping,
                .pong = bloom_pong,
            },
            .ao_job_contexts = ao_job_contexts,
            .bloom_threshold_curve = buildBloomThresholdCurve(config.POST_BLOOM_THRESHOLD),
            .bloom_intensity_lut = buildBloomIntensityLut(config.POST_BLOOM_INTENSITY_PERCENT),
            .fog_job_contexts = fog_job_contexts,
            .shadow_resolve_job_contexts = shadow_resolve_job_contexts,
            .shadow_raster_job_contexts = shadow_raster_job_contexts,
            .bloom_job_contexts = bloom_job_contexts,
            .dof_scratch = .{ .pixels = dof_scratch_pixels, .width = @intCast(width), .height = @intCast(height) },
            .dof_job_contexts = dof_job_contexts,
            .dof_focal_distance = config.POST_DOF_FOCAL_DISTANCE,
            .dof_target_focal_distance = config.POST_DOF_FOCAL_DISTANCE,
            .taa_job_contexts = taa_job_contexts,
            .color_grade_job_contexts = color_grade_job_contexts,
            .color_grade_jobs = color_grade_jobs,
        };
    }

    fn parseProfileCaptureFrame(allocator: std.mem.Allocator) !u64 {
        const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_PROFILE_FRAME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return 0,
            else => return err,
        };
        defer allocator.free(raw_value);
        return std.fmt.parseUnsigned(u64, raw_value, 10) catch 0;
    }

    /// Cleans up all renderer resources in the reverse order of creation.
    pub fn deinit(self: *Renderer) void {
        renderer_logger.infoSub("shutdown", "deinitializing renderer frame_counter={}", .{self.frame_count});
        self.mesh_work_cache.deinit(self.allocator);
        if (self.job_system) |js| js.deinit();
        if (self.job_buffer) |jobs| self.allocator.free(jobs);
        if (self.tile_jobs_buffer) |tile_jobs| self.allocator.free(tile_jobs);
        if (self.shadow_tile_jobs_buffer) |shadow_jobs| self.allocator.free(shadow_jobs);
        if (self.job_completion_buffer) |completion| self.allocator.free(completion);
        if (self.tile_triangle_lists) |lists| BinningStage.freeTileTriangleLists(lists, self.allocator);
        if (self.active_tile_flags) |flags| self.allocator.free(flags);
        if (self.active_tile_indices) |indices| self.allocator.free(indices);
        self.allocator.free(self.scene_depth);
        self.allocator.free(self.scene_camera);
        self.allocator.free(self.taa_scratch.history_pixels);
        self.allocator.free(self.taa_scratch.resolve_pixels);
        self.allocator.free(self.taa_scratch.history_depth);
        self.allocator.free(self.hybrid_shadow_coarse_cache);
        self.allocator.free(self.hybrid_shadow_edge_cache);
        if (self.hybrid_shadow_caster_indices.len != 0) self.allocator.free(self.hybrid_shadow_caster_indices);
        if (self.hybrid_shadow_caster_bounds.len != 0) self.allocator.free(self.hybrid_shadow_caster_bounds);
        self.allocator.free(self.hybrid_shadow_tile_ranges);
        if (self.hybrid_shadow_tile_candidates.len != 0) self.allocator.free(self.hybrid_shadow_tile_candidates);
        if (self.hybrid_shadow_grid_candidates.len != 0) self.allocator.free(self.hybrid_shadow_grid_candidates);
        if (self.hybrid_shadow_candidate_marks.len != 0) self.allocator.free(self.hybrid_shadow_candidate_marks);
        for (self.lights.items) |light| {
            self.allocator.free(light.shadow_map.depth);
        }
        self.lights.deinit(self.allocator);
        self.allocator.free(self.ao_scratch.ping);
        self.allocator.free(self.ao_scratch.pong);
        self.allocator.free(self.ao_scratch.depth);
        self.allocator.free(self.bloom_scratch.ping);
        self.allocator.free(self.bloom_scratch.pong);
        self.allocator.free(self.ao_job_contexts);
        self.allocator.free(self.fog_job_contexts);
        self.allocator.free(self.shadow_resolve_job_contexts);
        self.allocator.free(self.shadow_raster_job_contexts);
        self.allocator.free(self.bloom_job_contexts);
        self.allocator.free(self.dof_scratch.pixels);
        self.allocator.free(self.dof_job_contexts);
        self.allocator.free(self.taa_job_contexts);
        self.allocator.free(self.color_grade_job_contexts);
        self.allocator.free(self.color_grade_jobs);
        if (self.tile_buffers) |buffers| {
            for (buffers) |*buf| buf.deinit();
            self.allocator.free(buffers);
        }
        if (self.tile_grid) |*grid| grid.deinit();
        self.bitmap.deinit();
        if (self.hdc_mem) |hdc_mem| _ = DeleteDC(hdc_mem);
        if (self.hdc) |hdc| _ = ReleaseDC(self.hwnd, hdc);
    }

    // ========== TILE RENDER JOB ==========

    /// This struct is the "context object" for a single tile rendering job.
    /// It packages up all the data a worker thread needs to render one tile.
    /// JS Analogy: The data object you would `postMessage` to a Web Worker.
    const TileRenderJob = struct {
        tile: *const TileRenderer.Tile,
        tile_buffer: *TileBuffer,
        tri_list: *const BinningStage.TileTriangleList,
        packets: []const TrianglePacket,
        draw_wireframe: bool,
        textures: []const ?*const texture.Texture,
        projection: ProjectionParams,

        const max_clipped_vertices: usize = 5;
        const wire_color: u32 = 0xFFFFFFFF;

        const ClipVertex = struct {
            position: math.Vec3,
            uv: math.Vec2,
        };

        fn interpolateClipVertex(a: ClipVertex, b: ClipVertex, near_plane: f32) ClipVertex {
            const denom = b.position.z - a.position.z;
            const t_raw = if (@abs(denom) < 1e-6) 0.0 else (near_plane - a.position.z) / denom;
            const t = std.math.clamp(t_raw, 0.0, 1.0);
            const direction = math.Vec3.sub(b.position, a.position);
            const position = math.Vec3.add(a.position, math.Vec3.scale(direction, t));
            const uv_delta = math.Vec2.sub(b.uv, a.uv);
            const uv = math.Vec2.add(a.uv, math.Vec2.scale(uv_delta, t));
            return ClipVertex{ .position = position, .uv = uv };
        }

        fn textureForIndex(job: *const TileRenderJob, texture_index: u16) ?*const texture.Texture {
            if (texture_index == MeshModule.Triangle.no_texture_index) return null;
            const idx: usize = @intCast(texture_index);
            if (idx >= job.textures.len) return null;
            return job.textures[idx];
        }

        fn clipPolygonToNearPlane(vertices: []ClipVertex, near_plane: f32, output: *[max_clipped_vertices]ClipVertex) usize {
            if (vertices.len == 0) return 0;

            var out_count: usize = 0;
            var prev = vertices[vertices.len - 1];
            var prev_inside = prev.position.z >= near_plane - NEAR_EPSILON;

            for (vertices) |curr| {
                const curr_inside = curr.position.z >= near_plane - NEAR_EPSILON;
                if (curr_inside) {
                    if (!prev_inside and out_count < max_clipped_vertices) {
                        output[out_count] = interpolateClipVertex(prev, curr, near_plane);
                        out_count += 1;
                    }
                    if (out_count < max_clipped_vertices) {
                        output[out_count] = curr;
                        out_count += 1;
                    }
                } else if (prev_inside and out_count < max_clipped_vertices) {
                    output[out_count] = interpolateClipVertex(prev, curr, near_plane);
                    out_count += 1;
                }

                prev = curr;
                prev_inside = curr_inside;
            }

            return out_count;
        }

        fn projectToScreen(self: *const TileRenderJob, position: math.Vec3) [2]i32 {
            const clamped_z = if (position.z < self.projection.near_plane + NEAR_EPSILON)
                self.projection.near_plane + NEAR_EPSILON
            else
                position.z;
            const inv_z = 1.0 / clamped_z;
            const ndc_x = position.x * inv_z * self.projection.x_scale;
            const ndc_y = position.y * inv_z * self.projection.y_scale;
            const screen_x = ndc_x * self.projection.center_x + self.projection.center_x + self.projection.jitter_x;
            const screen_y = -ndc_y * self.projection.center_y + self.projection.center_y + self.projection.jitter_y;
            return .{
                @as(i32, @intFromFloat(screen_x)),
                @as(i32, @intFromFloat(screen_y)),
            };
        }

        fn isDegenerate(p0: [2]i32, p1: [2]i32, p2: [2]i32) bool {
            const ax = @as(i64, p1[0]) - @as(i64, p0[0]);
            const ay = @as(i64, p1[1]) - @as(i64, p0[1]);
            const bx = @as(i64, p2[0]) - @as(i64, p0[0]);
            const by = @as(i64, p2[1]) - @as(i64, p0[1]);
            const cross = ax * by - ay * bx;
            return cross == 0;
        }

        fn rasterizeFan(job: *TileRenderJob, vertices: []ClipVertex, base_color: u32, texture_index: u16, intensity: f32) void {
            if (vertices.len < 3) return;

            var screen_pts: [max_clipped_vertices][2]i32 = undefined;
            var depths: [max_clipped_vertices]f32 = undefined;
            var camera_positions: [max_clipped_vertices]math.Vec3 = undefined;
            for (vertices, 0..) |v, idx| {
                screen_pts[idx] = job.projectToScreen(v.position);
                depths[idx] = v.position.z;
                camera_positions[idx] = v.position;
            }

            var tri_idx: usize = 1;
            while (tri_idx < vertices.len - 1) : (tri_idx += 1) {
                const p0 = screen_pts[0];
                const p1 = screen_pts[tri_idx];
                const p2 = screen_pts[tri_idx + 1];
                if (isDegenerate(p0, p1, p2)) continue;

                const shading = TileRenderer.ShadingParams{
                    .base_color = base_color,
                    .texture = job.textureForIndex(texture_index),
                    .uv0 = vertices[0].uv,
                    .uv1 = vertices[tri_idx].uv,
                    .uv2 = vertices[tri_idx + 1].uv,
                    .intensity = intensity,
                };
                const depth_values = [3]f32{
                    depths[0],
                    depths[tri_idx],
                    depths[tri_idx + 1],
                };
                const camera_values = [3]math.Vec3{
                    camera_positions[0],
                    camera_positions[tri_idx],
                    camera_positions[tri_idx + 1],
                };
                TileRenderer.rasterizeTriangleToTile(job.tile, job.tile_buffer, p0, p1, p2, camera_values, depth_values, shading);
            }
        }

        fn renderTileJob(ctx: *anyopaque) void {
            const job: *TileRenderJob = @ptrCast(@alignCast(ctx));
            const near_plane = job.projection.near_plane;
            job.tile_buffer.clear();

            for (job.tri_list.triangles.items) |tri_idx| {
                if (tri_idx >= job.packets.len) continue;
                const packet = job.packets[tri_idx];
                if (packet.flags.cull_fill) continue;

                const camera_positions = packet.camera;
                const front0 = camera_positions[0].z >= near_plane - NEAR_EPSILON;
                const front1 = camera_positions[1].z >= near_plane - NEAR_EPSILON;
                const front2 = camera_positions[2].z >= near_plane - NEAR_EPSILON;
                if (!front0 and !front1 and !front2) continue;

                var clip_input = [_]ClipVertex{
                    ClipVertex{ .position = camera_positions[0], .uv = packet.uv[0] },
                    ClipVertex{ .position = camera_positions[1], .uv = packet.uv[1] },
                    ClipVertex{ .position = camera_positions[2], .uv = packet.uv[2] },
                };

                var clipped: [max_clipped_vertices]ClipVertex = undefined;
                const clipped_count = clipPolygonToNearPlane(clip_input[0..], near_plane, &clipped);
                if (clipped_count < 3) continue;

                rasterizeFan(job, clipped[0..clipped_count], packet.base_color, packet.texture_index, packet.intensity);

                if (job.draw_wireframe and !packet.flags.cull_wire) {
                    const p0 = job.projectToScreen(camera_positions[0]);
                    const p1 = job.projectToScreen(camera_positions[1]);
                    const p2 = job.projectToScreen(camera_positions[2]);
                    TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p0, p1, wire_color);
                    TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p1, p2, wire_color);
                    TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p2, p0, wire_color);
                }
            }
        }
    };

    fn vertexReadyTag(generation: u32) u32 {
        return generation << 1;
    }

    fn vertexWorkingTag(generation: u32) u32 {
        return (generation << 1) | 1;
    }

    fn ensureVertex(
        idx: usize,
        states: []std.atomic.Value(u32),
        generation: u32,
        mesh_vertices: []const math.Vec3,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        vertex_cache: []math.Vec3,
        projected_slice: [][2]i32,
        projection_params: ProjectionParams,
    ) void {
        const ready_tag = vertexReadyTag(generation);
        const working_tag = vertexWorkingTag(generation);

        while (true) {
            const state = states[idx].load(.acquire);
            if (state == ready_tag) return;
            if (state == working_tag) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (states[idx].cmpxchgStrong(state, working_tag, .acq_rel, .acquire) != null) continue;

            const vertex = mesh_vertices[idx];
            const relative = math.Vec3.sub(vertex, camera_position);
            const camera_space = math.Vec3.new(
                math.Vec3.dot(relative, basis_right),
                math.Vec3.dot(relative, basis_up),
                math.Vec3.dot(relative, basis_forward),
            );
            vertex_cache[idx] = camera_space;

            if (camera_space.z <= NEAR_CLIP) {
                projected_slice[idx] = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
            } else {
                const inv_z = 1.0 / camera_space.z;
                const ndc_x = camera_space.x * inv_z * projection_params.x_scale;
                const ndc_y = camera_space.y * inv_z * projection_params.y_scale;
                const screen_x = ndc_x * projection_params.center_x + projection_params.center_x + projection_params.jitter_x;
                const screen_y = -ndc_y * projection_params.center_y + projection_params.center_y + projection_params.jitter_y;
                projected_slice[idx][0] = @as(i32, @intFromFloat(screen_x));
                projected_slice[idx][1] = @as(i32, @intFromFloat(screen_y));
            }

            states[idx].store(ready_tag, .release);
            return;
        }
    }

    fn transformNormalFromBasis(basis_right: math.Vec3, basis_up: math.Vec3, basis_forward: math.Vec3, normal: math.Vec3) math.Vec3 {
        const transformed = math.Vec3.new(
            math.Vec3.dot(normal, basis_right),
            math.Vec3.dot(normal, basis_up),
            math.Vec3.dot(normal, basis_forward),
        );
        const len = math.Vec3.length(transformed);
        if (len < 1e-6) return math.Vec3.new(0.0, 0.0, 1.0);
        return math.Vec3.scale(transformed, 1.0 / len);
    }

    fn triangleNormalCamera(
        mesh: *const Mesh,
        tri_idx: usize,
        tri: MeshModule.Triangle,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        p0_cam: math.Vec3,
        p1_cam: math.Vec3,
        p2_cam: math.Vec3,
    ) math.Vec3 {
        if (tri_idx < mesh.normals.len) {
            return transformNormalFromBasis(basis_right, basis_up, basis_forward, mesh.normals[tri_idx]);
        }

        const edge0 = math.Vec3.sub(p1_cam, p0_cam);
        const edge1 = math.Vec3.sub(p2_cam, p0_cam);
        const fallback = math.Vec3.cross(edge0, edge1);
        const len = math.Vec3.length(fallback);
        if (len > 1e-6) return math.Vec3.scale(fallback, 1.0 / len);
        _ = tri;
        return math.Vec3.new(0.0, 0.0, 1.0);
    }

    fn emitPreparedTriangleToWork(
        writer: *MeshWorkWriter,
        tri_idx: usize,
        tri: MeshModule.Triangle,
        p0_cam: math.Vec3,
        p1_cam: math.Vec3,
        p2_cam: math.Vec3,
        screen0_input: [2]i32,
        screen1_input: [2]i32,
        screen2_input: [2]i32,
        uv: [3]math.Vec2,
        normal_cam: math.Vec3,
        projection_params: ProjectionParams,
        light_dir: math.Vec3,
        output_cursor: ?*usize,
    ) !?usize {
        const front0 = p0_cam.z >= projection_params.near_plane - NEAR_EPSILON;
        const front1 = p1_cam.z >= projection_params.near_plane - NEAR_EPSILON;
        const front2 = p2_cam.z >= projection_params.near_plane - NEAR_EPSILON;
        if (!front0 and !front1 and !front2) return null;

        const crosses_near = (front0 or front1 or front2) and !(front0 and front1 and front2);

        var screen0 = screen0_input;
        var screen1 = screen1_input;
        var screen2 = screen2_input;
        if (screen0[0] == INVALID_PROJECTED_COORD or screen0[1] == INVALID_PROJECTED_COORD) screen0 = projectCameraPosition(p0_cam, projection_params);
        if (screen1[0] == INVALID_PROJECTED_COORD or screen1[1] == INVALID_PROJECTED_COORD) screen1 = projectCameraPosition(p1_cam, projection_params);
        if (screen2[0] == INVALID_PROJECTED_COORD or screen2[1] == INVALID_PROJECTED_COORD) screen2 = projectCameraPosition(p2_cam, projection_params);

        var backface = false;
        if (!crosses_near) {
            var centroid = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
            centroid = math.Vec3.scale(centroid, 1.0 / 3.0);
            const view_dir = math.Vec3.scale(centroid, -1.0);
            const view_len = math.Vec3.length(view_dir);
            if (view_len > 1e-6) {
                const view_vector = math.Vec3.scale(view_dir, 1.0 / view_len);
                if (math.Vec3.dot(normal_cam, view_vector) < -1e-4) backface = true;
            }
        }
        if (backface) return null;

        const brightness = math.Vec3.dot(normal_cam, light_dir);
        const intensity = lighting.computeIntensity(brightness);

        const flags = TriangleFlags{
            .cull_fill = tri.cull_flags.cull_fill,
            .cull_wire = tri.cull_flags.cull_wireframe,
            .backface = backface,
            .reserved = 0,
        };

        const write_index = blk: {
            if (output_cursor) |cursor| {
                const idx = cursor.*;
                cursor.* = idx + 1;
                break :blk idx;
            } else {
                break :blk try writer.reserveIndex();
            }
        };

        try writer.writeAtIndex(
            write_index,
            tri_idx,
            screen0,
            screen1,
            screen2,
            p0_cam,
            p1_cam,
            p2_cam,
            uv,
            tri.base_color,
            tri.texture_index,
            intensity,
            flags,
        );
        return write_index;
    }

    fn emitTriangleToWork(
        writer: *MeshWorkWriter,
        mesh: *const Mesh,
        tri_idx: usize,
        tri: MeshModule.Triangle,
        states: []std.atomic.Value(u32),
        vertex_generation: u32,
        mesh_vertices: []const math.Vec3,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        vertex_cache: []math.Vec3,
        projected_slice: [][2]i32,
        projection_params: ProjectionParams,
        light_dir: math.Vec3,
        output_cursor: ?*usize,
    ) !?usize {
        ensureVertex(tri.v0, states, vertex_generation, mesh_vertices, camera_position, basis_right, basis_up, basis_forward, vertex_cache, projected_slice, projection_params);
        ensureVertex(tri.v1, states, vertex_generation, mesh_vertices, camera_position, basis_right, basis_up, basis_forward, vertex_cache, projected_slice, projection_params);
        ensureVertex(tri.v2, states, vertex_generation, mesh_vertices, camera_position, basis_right, basis_up, basis_forward, vertex_cache, projected_slice, projection_params);

        const p0_cam = vertex_cache[tri.v0];
        const p1_cam = vertex_cache[tri.v1];
        const p2_cam = vertex_cache[tri.v2];
        const screen0 = projected_slice[tri.v0];
        const screen1 = projected_slice[tri.v1];
        const screen2 = projected_slice[tri.v2];

        const uv = [3]math.Vec2{
            if (tri.v0 < mesh.tex_coords.len) mesh.tex_coords[tri.v0] else math.Vec2.new(0.0, 0.0),
            if (tri.v1 < mesh.tex_coords.len) mesh.tex_coords[tri.v1] else math.Vec2.new(0.0, 0.0),
            if (tri.v2 < mesh.tex_coords.len) mesh.tex_coords[tri.v2] else math.Vec2.new(0.0, 0.0),
        };

        const normal_cam = triangleNormalCamera(mesh, tri_idx, tri, basis_right, basis_up, basis_forward, p0_cam, p1_cam, p2_cam);
        return emitPreparedTriangleToWork(
            writer,
            tri_idx,
            tri,
            p0_cam,
            p1_cam,
            p2_cam,
            screen0,
            screen1,
            screen2,
            uv,
            normal_cam,
            projection_params,
            light_dir,
            output_cursor,
        );
    }

    fn emitMeshletPrimitiveToWork(
        writer: *MeshWorkWriter,
        mesh: *const Mesh,
        tri_idx: usize,
        tri: MeshModule.Triangle,
        primitive: MeshModule.MeshletPrimitive,
        local_camera_vertices: []const math.Vec3,
        local_projected_vertices: []const [2]i32,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection_params: ProjectionParams,
        light_dir: math.Vec3,
        output_cursor: ?*usize,
    ) !?usize {
        const local_v0 = @as(usize, primitive.local_v0);
        const local_v1 = @as(usize, primitive.local_v1);
        const local_v2 = @as(usize, primitive.local_v2);
        const p0_cam = local_camera_vertices[local_v0];
        const p1_cam = local_camera_vertices[local_v1];
        const p2_cam = local_camera_vertices[local_v2];
        const screen0 = local_projected_vertices[local_v0];
        const screen1 = local_projected_vertices[local_v1];
        const screen2 = local_projected_vertices[local_v2];

        const uv = [3]math.Vec2{
            if (tri.v0 < mesh.tex_coords.len) mesh.tex_coords[tri.v0] else math.Vec2.new(0.0, 0.0),
            if (tri.v1 < mesh.tex_coords.len) mesh.tex_coords[tri.v1] else math.Vec2.new(0.0, 0.0),
            if (tri.v2 < mesh.tex_coords.len) mesh.tex_coords[tri.v2] else math.Vec2.new(0.0, 0.0),
        };
        const normal_cam = triangleNormalCamera(mesh, tri_idx, tri, basis_right, basis_up, basis_forward, p0_cam, p1_cam, p2_cam);
        return emitPreparedTriangleToWork(
            writer,
            tri_idx,
            tri,
            p0_cam,
            p1_cam,
            p2_cam,
            screen0,
            screen1,
            screen2,
            uv,
            normal_cam,
            projection_params,
            light_dir,
            output_cursor,
        );
    }

    fn projectCameraPosition(position: math.Vec3, projection: ProjectionParams) [2]i32 {
        const clamped_z = if (position.z < projection.near_plane + NEAR_EPSILON)
            projection.near_plane + NEAR_EPSILON
        else
            position.z;
        const inv_z = 1.0 / clamped_z;
        const ndc_x = position.x * inv_z * projection.x_scale;
        const ndc_y = position.y * inv_z * projection.y_scale;
        const screen_x = ndc_x * projection.center_x + projection.center_x + projection.jitter_x;
        const screen_y = -ndc_y * projection.center_y + projection.center_y + projection.jitter_y;
        return .{
            @as(i32, @intFromFloat(screen_x)),
            @as(i32, @intFromFloat(screen_y)),
        };
    }

    const MESHLETS_PER_CULL_JOB: usize = 32;

    const MeshletCullJob = struct {
        renderer: *Renderer,
        meshlets: []const Meshlet,
        visibility: []bool,
        start_index: usize,
        end_index: usize,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,

        fn process(job: *MeshletCullJob) void {
            var idx = job.start_index;
            while (idx < job.end_index) : (idx += 1) {
                const meshlet_ptr = &job.meshlets[idx];
                const visible = job.renderer.meshletVisible(
                    meshlet_ptr,
                    job.camera_position,
                    job.basis_right,
                    job.basis_up,
                    job.basis_forward,
                    job.projection,
                );
                job.visibility[idx] = visible;
            }
        }

        fn run(ctx: *anyopaque) void {
            const job: *MeshletCullJob = @ptrCast(@alignCast(ctx));
            job.process();
        }
    };

    const MeshletRenderJob = struct {
        mesh: *const Mesh,
        meshlet: *const Meshlet,
        mesh_work: *MeshWork,
        local_projected_vertices: [][2]i32,
        local_camera_vertices: []math.Vec3,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
        light_dir: math.Vec3,
        output_start: usize,
        written_count: usize = 0,
        grid: ?*const TileRenderer.TileGrid,
        contribution: *MeshletContribution,

        fn process(job: *MeshletRenderJob) void {
            job.contribution.clear();
            var writer = MeshWorkWriter.init(job.mesh_work);
            const mesh_vertices = job.mesh.vertices;
            const meshlet_vertices = job.mesh.meshletVertexSlice(job.meshlet);
            std.debug.assert(job.local_camera_vertices.len == meshlet_vertices.len);
            std.debug.assert(job.local_projected_vertices.len == meshlet_vertices.len);

            for (meshlet_vertices, 0..) |global_vertex_idx, local_idx| {
                const vertex = mesh_vertices[global_vertex_idx];
                const relative = math.Vec3.sub(vertex, job.camera_position);
                const camera_space = math.Vec3.new(
                    math.Vec3.dot(relative, job.basis_right),
                    math.Vec3.dot(relative, job.basis_up),
                    math.Vec3.dot(relative, job.basis_forward),
                );
                job.local_camera_vertices[local_idx] = camera_space;

                if (camera_space.z <= NEAR_CLIP) {
                    job.local_projected_vertices[local_idx] = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
                } else {
                    const inv_z = 1.0 / camera_space.z;
                    const ndc_x = camera_space.x * inv_z * job.projection.x_scale;
                    const ndc_y = camera_space.y * inv_z * job.projection.y_scale;
                    const screen_x = ndc_x * job.projection.center_x + job.projection.center_x;
                    const screen_y = -ndc_y * job.projection.center_y + job.projection.center_y;
                    job.local_projected_vertices[local_idx] = .{
                        @as(i32, @intFromFloat(screen_x)),
                        @as(i32, @intFromFloat(screen_y)),
                    };
                }
            }

            var cursor = job.output_start;
            for (job.mesh.meshletPrimitiveSlice(job.meshlet)) |primitive| {
                const tri_idx = primitive.triangle_index;
                const tri = job.mesh.triangles[tri_idx];
                const result = emitMeshletPrimitiveToWork(
                    &writer,
                    job.mesh,
                    tri_idx,
                    tri,
                    primitive,
                    job.local_camera_vertices,
                    job.local_projected_vertices,
                    job.basis_right,
                    job.basis_up,
                    job.basis_forward,
                    job.projection,
                    job.light_dir,
                    &cursor,
                ) catch |err| {
                    meshlet_logger.errorSub("emit", "meshlet emit failed: {s}", .{@errorName(err)});
                    continue;
                };
                if (result) |write_index| {
                    job.recordTriangleContribution(write_index);
                }
            }
            job.written_count = cursor - job.output_start;
        }

        fn recordTriangleContribution(job: *MeshletRenderJob, tri_index: usize) void {
            const grid_ptr = job.grid orelse return;
            if (tri_index >= job.mesh_work.triangles.len) return;
            const packet = job.mesh_work.triangles[tri_index];
            const screen_tri = packet.screen;

            const bounds = BinningStage.TriangleBounds.fromVertices(screen_tri[0], screen_tri[1], screen_tri[2]);
            if (bounds.isOffscreen(grid_ptr.screen_width, grid_ptr.screen_height)) return;

            const screen_max_x = grid_ptr.screen_width - 1;
            const screen_max_y = grid_ptr.screen_height - 1;

            const clamped_min_x = std.math.clamp(bounds.min_x, 0, screen_max_x);
            const clamped_max_x = std.math.clamp(bounds.max_x, 0, screen_max_x);
            const clamped_min_y = std.math.clamp(bounds.min_y, 0, screen_max_y);
            const clamped_max_y = std.math.clamp(bounds.max_y, 0, screen_max_y);

            const min_col = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_min_x, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid_ptr.cols)) - 1)));
            const max_col = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_max_x, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid_ptr.cols)) - 1)));
            const min_row = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_min_y, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid_ptr.rows)) - 1)));
            const max_row = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_max_y, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid_ptr.rows)) - 1)));

            var row = min_row;
            while (row <= max_row) : (row += 1) {
                const base_idx = row * grid_ptr.cols;
                var col = min_col;
                while (col <= max_col) : (col += 1) {
                    const tile_index = base_idx + col;
                    const tile_ptr = &grid_ptr.tiles[tile_index];
                    if (!bounds.overlapsTile(tile_ptr)) continue;
                    job.contribution.addTriangle(tile_index, tri_index) catch |err| {
                        meshlet_logger.errorSub(
                            "contrib",
                            "meshlet contribution failed triangle {} tile {}: {s}",
                            .{ tri_index, tile_index, @errorName(err) },
                        );
                    };
                }
            }
        }

        fn run(ctx: *anyopaque) void {
            const job: *MeshletRenderJob = @ptrCast(@alignCast(ctx));
            job.process();
        }
    };

    const MeshletContribution = struct {
        const Entry = struct {
            tile_index: usize,
            triangles: std.ArrayList(usize),
        };

        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry),
        lookup_keys: []usize,
        lookup_values: []usize,
        lookup_stamps: []u32,
        lookup_generation: u32,
        active_count: usize,

        fn init(allocator: std.mem.Allocator) MeshletContribution {
            return MeshletContribution{
                .allocator = allocator,
                .entries = std.ArrayList(Entry){},
                .lookup_keys = &[_]usize{},
                .lookup_values = &[_]usize{},
                .lookup_stamps = &[_]u32{},
                .lookup_generation = 1,
                .active_count = 0,
            };
        }

        fn deinit(self: *MeshletContribution) void {
            const storage = self.entries.items;
            for (storage) |*entry| {
                entry.triangles.deinit(self.allocator);
            }
            self.entries.deinit(self.allocator);
            if (self.lookup_keys.len != 0) self.allocator.free(self.lookup_keys);
            if (self.lookup_values.len != 0) self.allocator.free(self.lookup_values);
            if (self.lookup_stamps.len != 0) self.allocator.free(self.lookup_stamps);
            self.entries = std.ArrayList(Entry){};
            self.lookup_keys = &[_]usize{};
            self.lookup_values = &[_]usize{};
            self.lookup_stamps = &[_]u32{};
            self.lookup_generation = 1;
            self.active_count = 0;
        }

        fn clear(self: *MeshletContribution) void {
            var idx: usize = 0;
            while (idx < self.active_count) : (idx += 1) {
                self.entries.items[idx].triangles.clearRetainingCapacity();
            }
            self.active_count = 0;
            self.advanceLookupGeneration();
        }

        fn addTriangle(self: *MeshletContribution, tile_index: usize, tri_index: usize) !void {
            if (self.findEntryIndex(tile_index)) |entry_index| {
                try self.entries.items[entry_index].triangles.append(self.allocator, tri_index);
                return;
            }

            try self.ensureLookupCapacity(self.active_count + 1);

            const entry_index = self.active_count;
            if (self.active_count < self.entries.items.len) {
                var reuse_entry = &self.entries.items[entry_index];
                reuse_entry.tile_index = tile_index;
                reuse_entry.triangles.clearRetainingCapacity();
                try reuse_entry.triangles.append(self.allocator, tri_index);
            } else {
                var new_entry = Entry{
                    .tile_index = tile_index,
                    .triangles = std.ArrayList(usize){},
                };
                try new_entry.triangles.append(self.allocator, tri_index);
                try self.entries.append(self.allocator, new_entry);
            }

            self.insertLookup(tile_index, entry_index);
            self.active_count += 1;
        }

        fn remapRange(self: *MeshletContribution, original_start: usize, count: usize, new_start: usize) void {
            if (count == 0) {
                self.clear();
                return;
            }

            const original_end = original_start + count;
            for (self.entries.items[0..self.active_count]) |*entry| {
                var idx: usize = 0;
                while (idx < entry.triangles.items.len) : (idx += 1) {
                    const tri_idx = entry.triangles.items[idx];
                    if (tri_idx < original_start or tri_idx >= original_end) continue;
                    const offset = tri_idx - original_start;
                    entry.triangles.items[idx] = new_start + offset;
                }
            }
        }

        fn advanceLookupGeneration(self: *MeshletContribution) void {
            if (self.lookup_stamps.len == 0) return;
            if (self.lookup_generation == std.math.maxInt(u32)) {
                @memset(self.lookup_stamps, 0);
                self.lookup_generation = 1;
                return;
            }
            self.lookup_generation += 1;
        }

        fn ensureLookupCapacity(self: *MeshletContribution, min_entries: usize) !void {
            const min_lookup_capacity = if (min_entries < 4) 8 else min_entries * 2;
            const required_capacity = nextPowerOfTwo(min_lookup_capacity);
            if (self.lookup_keys.len >= required_capacity) return;

            const new_keys = try self.allocator.alloc(usize, required_capacity);
            errdefer self.allocator.free(new_keys);
            const new_values = try self.allocator.alloc(usize, required_capacity);
            errdefer self.allocator.free(new_values);
            const new_stamps = try self.allocator.alloc(u32, required_capacity);
            errdefer self.allocator.free(new_stamps);
            @memset(new_stamps, 0);

            if (self.lookup_keys.len != 0) self.allocator.free(self.lookup_keys);
            if (self.lookup_values.len != 0) self.allocator.free(self.lookup_values);
            if (self.lookup_stamps.len != 0) self.allocator.free(self.lookup_stamps);

            self.lookup_keys = new_keys;
            self.lookup_values = new_values;
            self.lookup_stamps = new_stamps;
            self.lookup_generation = 1;

            var idx: usize = 0;
            while (idx < self.active_count) : (idx += 1) {
                self.insertLookup(self.entries.items[idx].tile_index, idx);
            }
        }

        fn findEntryIndex(self: *const MeshletContribution, tile_index: usize) ?usize {
            if (self.lookup_keys.len == 0) return null;

            const mask = self.lookup_keys.len - 1;
            var slot = std.hash_map.hashString(std.mem.asBytes(&tile_index)) & mask;
            while (self.lookup_stamps[slot] == self.lookup_generation) {
                if (self.lookup_keys[slot] == tile_index) {
                    return self.lookup_values[slot];
                }
                slot = (slot + 1) & mask;
            }
            return null;
        }

        fn insertLookup(self: *MeshletContribution, tile_index: usize, entry_index: usize) void {
            std.debug.assert(self.lookup_keys.len != 0);

            const mask = self.lookup_keys.len - 1;
            var slot = std.hash_map.hashString(std.mem.asBytes(&tile_index)) & mask;
            while (self.lookup_stamps[slot] == self.lookup_generation and self.lookup_keys[slot] != tile_index) {
                slot = (slot + 1) & mask;
            }

            self.lookup_stamps[slot] = self.lookup_generation;
            self.lookup_keys[slot] = tile_index;
            self.lookup_values[slot] = entry_index;
        }

        fn nextPowerOfTwo(value: usize) usize {
            var capacity: usize = 1;
            while (capacity < value) : (capacity <<= 1) {}
            return capacity;
        }
    };

    const MeshletBinningJob = struct {
        mesh_work: *const MeshWork,
        meshlet_packet: *const MeshletPacket,
        grid: *const TileGrid,
        contribution: *MeshletContribution,

        fn process(job: *MeshletBinningJob) void {
            const triangles = job.mesh_work.triangles;
            const packet = job.meshlet_packet.*;

            if (packet.triangle_count == 0) return;

            const screen_width = job.grid.screen_width;
            const screen_height = job.grid.screen_height;

            var offset: usize = 0;
            while (offset < packet.triangle_count) : (offset += 1) {
                const tri_index = packet.triangle_start + offset;
                if (tri_index >= triangles.len) continue;
                const tri_packet = triangles[tri_index];
                const screen_tri = tri_packet.screen;

                const bounds = BinningStage.TriangleBounds.fromVertices(screen_tri[0], screen_tri[1], screen_tri[2]);
                if (bounds.isOffscreen(screen_width, screen_height)) {
                    continue;
                }

                const screen_max_x = screen_width - 1;
                const screen_max_y = screen_height - 1;

                const clamped_min_x = std.math.clamp(bounds.min_x, 0, screen_max_x);
                const clamped_max_x = std.math.clamp(bounds.max_x, 0, screen_max_x);
                const clamped_min_y = std.math.clamp(bounds.min_y, 0, screen_max_y);
                const clamped_max_y = std.math.clamp(bounds.max_y, 0, screen_max_y);

                const min_col = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_min_x, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(job.grid.cols)) - 1)));
                const max_col = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_max_x, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(job.grid.cols)) - 1)));
                const min_row = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_min_y, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(job.grid.rows)) - 1)));
                const max_row = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_max_y, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(job.grid.rows)) - 1)));

                var row = min_row;
                while (row <= max_row) : (row += 1) {
                    const base_idx = row * job.grid.cols;
                    var col = min_col;
                    while (col <= max_col) : (col += 1) {
                        const tile_index = base_idx + col;
                        const tile_ptr = &job.grid.tiles[tile_index];
                        if (!bounds.overlapsTile(tile_ptr)) continue;
                        job.contribution.addTriangle(tile_index, tri_index) catch |err| {
                            meshlet_logger.errorSub(
                                "binning",
                                "meshlet binning failed triangle {} tile {}: {s}",
                                .{ tri_index, tile_index, @errorName(err) },
                            );
                        };
                    }
                }
            }
        }

        fn run(ctx: *anyopaque) void {
            const job: *MeshletBinningJob = @ptrCast(@alignCast(ctx));
            job.process();
        }
    };

    const MeshWork = struct {
        triangles: []TrianglePacket,
        meshlet_packets: []MeshletPacket,
        triangle_len: usize,
        triangle_reserved: usize,
        meshlet_len: usize,
        meshlet_reserved: usize,
        next_triangle: std.atomic.Value(usize),

        fn init() MeshWork {
            return MeshWork{
                .triangles = &[_]TrianglePacket{},
                .meshlet_packets = &[_]MeshletPacket{},
                .triangle_len = 0,
                .triangle_reserved = 0,
                .meshlet_len = 0,
                .meshlet_reserved = 0,
                .next_triangle = std.atomic.Value(usize).init(0),
            };
        }

        fn deinit(self: *MeshWork, allocator: std.mem.Allocator) void {
            if (self.triangles.len != 0) allocator.free(self.triangles);
            if (self.meshlet_packets.len != 0) allocator.free(self.meshlet_packets);
            self.* = MeshWork.init();
        }

        fn clear(self: *MeshWork) void {
            self.triangle_len = 0;
            self.triangle_reserved = 0;
            self.meshlet_len = 0;
            self.meshlet_reserved = 0;
            self.next_triangle.store(0, .release);
        }

        fn ensureTriangleCapacity(self: *MeshWork, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.triangles.len < capacity) {
                if (self.triangles.len == 0) {
                    self.triangles = try allocator.alloc(TrianglePacket, capacity);
                } else {
                    self.triangles = try allocator.realloc(self.triangles, capacity);
                }
            }
        }

        fn ensureMeshletCapacity(self: *MeshWork, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.meshlet_packets.len < capacity) {
                if (self.meshlet_packets.len == 0) {
                    self.meshlet_packets = try allocator.alloc(MeshletPacket, capacity);
                } else {
                    self.meshlet_packets = try allocator.realloc(self.meshlet_packets, capacity);
                }
            }
        }

        fn beginWrite(self: *MeshWork, allocator: std.mem.Allocator, meshlet_capacity: usize, triangle_capacity: usize) !void {
            self.clear();
            if (meshlet_capacity == 0 and triangle_capacity == 0) return;
            if (meshlet_capacity != 0) try self.ensureMeshletCapacity(allocator, meshlet_capacity);
            if (triangle_capacity != 0) try self.ensureTriangleCapacity(allocator, triangle_capacity);
            self.meshlet_reserved = meshlet_capacity;
            self.triangle_reserved = triangle_capacity;
            self.triangle_len = 0;
            self.meshlet_len = meshlet_capacity;
            self.next_triangle.store(0, .release);
        }

        fn finalize(self: *MeshWork, meshlet_count: usize) void {
            const produced = self.next_triangle.load(.acquire);
            const limit = if (self.triangle_reserved == 0) self.triangles.len else self.triangle_reserved;
            self.triangle_len = if (produced > limit) limit else produced;
            self.meshlet_len = meshlet_count;
        }

        fn triangleSlice(self: *const MeshWork) []const TrianglePacket {
            return self.triangles[0..self.triangle_len];
        }

        fn meshletSlice(self: *const MeshWork) []const MeshletPacket {
            return self.meshlet_packets[0..self.meshlet_len];
        }
    };

    const MeshWorkWriter = struct {
        work: *MeshWork,

        fn init(work: *MeshWork) MeshWorkWriter {
            return MeshWorkWriter{ .work = work };
        }

        fn reserveIndex(self: *MeshWorkWriter) !usize {
            const idx = self.work.next_triangle.fetchAdd(1, .acq_rel);
            if (idx >= self.work.triangles.len) {
                return error.MeshWorkOverflow;
            }
            return idx;
        }

        fn writeAtIndex(
            self: *MeshWorkWriter,
            idx: usize,
            tri_idx: usize,
            screen0: [2]i32,
            screen1: [2]i32,
            screen2: [2]i32,
            p0: math.Vec3,
            p1: math.Vec3,
            p2: math.Vec3,
            uv: [3]math.Vec2,
            base_color: u32,
            texture_index: u16,
            intensity: f32,
            flags: TriangleFlags,
        ) !void {
            if (idx >= self.work.triangles.len) {
                return error.MeshWorkOverflow;
            }
            self.work.triangles[idx] = TrianglePacket{
                .screen = .{ screen0, screen1, screen2 },
                .camera = .{ p0, p1, p2 },
                .uv = uv,
                .base_color = base_color,
                .texture_index = texture_index,
                .intensity = intensity,
                .flags = flags,
                .triangle_id = tri_idx,
            };
        }
    };

    const MeshWorkCache = struct {
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        vertex_ready: []std.atomic.Value(u32),
        meshlet_jobs: []MeshletRenderJob,
        meshlet_job_handles: []Job,
        meshlet_job_completion: []bool,
        meshlet_contributions: []MeshletContribution,
        meshlet_visibility: []bool,
        visible_meshlet_indices: []usize,
        visible_meshlet_offsets: []usize,
        visible_meshlet_vertex_offsets: []usize,
        meshlet_cull_jobs: []MeshletCullJob,
        meshlet_cull_job_handles: []Job,
        meshlet_cull_job_completion: []bool,
        meshlet_local_camera_scratch: []math.Vec3,
        meshlet_local_projected_scratch: [][2]i32,
        work: MeshWork,
        mesh: ?*const Mesh,
        camera_position: math.Vec3,
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        light_dir: math.Vec3,
        projection: ProjectionParams,
        vertex_generation: u32,
        full_vertex_cache_valid: bool,
        valid: bool,

        fn init() MeshWorkCache {
            return MeshWorkCache{
                .projected = &[_][2]i32{},
                .transformed_vertices = &[_]math.Vec3{},
                .vertex_ready = &[_]std.atomic.Value(u32){},
                .meshlet_jobs = &[_]MeshletRenderJob{},
                .meshlet_job_handles = &[_]Job{},
                .meshlet_job_completion = &[_]bool{},
                .meshlet_contributions = &[_]MeshletContribution{},
                .meshlet_visibility = &[_]bool{},
                .visible_meshlet_indices = &[_]usize{},
                .visible_meshlet_offsets = &[_]usize{},
                .visible_meshlet_vertex_offsets = &[_]usize{},
                .meshlet_cull_jobs = &[_]MeshletCullJob{},
                .meshlet_cull_job_handles = &[_]Job{},
                .meshlet_cull_job_completion = &[_]bool{},
                .meshlet_local_camera_scratch = &[_]math.Vec3{},
                .meshlet_local_projected_scratch = &[_][2]i32{},
                .work = MeshWork.init(),
                .mesh = null,
                .camera_position = math.Vec3.new(0.0, 0.0, 0.0),
                .right = math.Vec3.new(0.0, 0.0, 0.0),
                .up = math.Vec3.new(0.0, 0.0, 0.0),
                .forward = math.Vec3.new(0.0, 0.0, 0.0),
                .light_dir = math.Vec3.new(0.0, 0.0, 0.0),
                .projection = ProjectionParams{
                    .center_x = 0.0,
                    .center_y = 0.0,
                    .x_scale = 0.0,
                    .y_scale = 0.0,
                    .near_plane = NEAR_CLIP,
                    .jitter_x = 0.0,
                    .jitter_y = 0.0,
                },
                .vertex_generation = 0,
                .full_vertex_cache_valid = false,
                .valid = false,
            };
        }

        fn deinit(self: *MeshWorkCache, allocator: std.mem.Allocator) void {
            self.work.deinit(allocator);
            if (self.projected.len != 0) allocator.free(self.projected);
            if (self.transformed_vertices.len != 0) allocator.free(self.transformed_vertices);
            if (self.vertex_ready.len != 0) allocator.free(self.vertex_ready);
            if (self.meshlet_jobs.len != 0) allocator.free(self.meshlet_jobs);
            if (self.meshlet_job_handles.len != 0) allocator.free(self.meshlet_job_handles);
            if (self.meshlet_job_completion.len != 0) allocator.free(self.meshlet_job_completion);
            if (self.meshlet_visibility.len != 0) allocator.free(self.meshlet_visibility);
            if (self.visible_meshlet_indices.len != 0) allocator.free(self.visible_meshlet_indices);
            if (self.visible_meshlet_offsets.len != 0) allocator.free(self.visible_meshlet_offsets);
            if (self.visible_meshlet_vertex_offsets.len != 0) allocator.free(self.visible_meshlet_vertex_offsets);
            if (self.meshlet_cull_jobs.len != 0) allocator.free(self.meshlet_cull_jobs);
            if (self.meshlet_cull_job_handles.len != 0) allocator.free(self.meshlet_cull_job_handles);
            if (self.meshlet_cull_job_completion.len != 0) allocator.free(self.meshlet_cull_job_completion);
            if (self.meshlet_local_camera_scratch.len != 0) allocator.free(self.meshlet_local_camera_scratch);
            if (self.meshlet_local_projected_scratch.len != 0) allocator.free(self.meshlet_local_projected_scratch);
            if (self.meshlet_contributions.len != 0) {
                for (self.meshlet_contributions) |*contrib| contrib.deinit();
                allocator.free(self.meshlet_contributions);
            }
            self.projected = &[_][2]i32{};
            self.transformed_vertices = &[_]math.Vec3{};
            self.vertex_ready = &[_]std.atomic.Value(u32){};
            self.meshlet_jobs = &[_]MeshletRenderJob{};
            self.meshlet_job_handles = &[_]Job{};
            self.meshlet_job_completion = &[_]bool{};
            self.meshlet_contributions = &[_]MeshletContribution{};
            self.meshlet_visibility = &[_]bool{};
            self.visible_meshlet_indices = &[_]usize{};
            self.visible_meshlet_offsets = &[_]usize{};
            self.visible_meshlet_vertex_offsets = &[_]usize{};
            self.meshlet_cull_jobs = &[_]MeshletCullJob{};
            self.meshlet_cull_job_handles = &[_]Job{};
            self.meshlet_cull_job_completion = &[_]bool{};
            self.meshlet_local_camera_scratch = &[_]math.Vec3{};
            self.meshlet_local_projected_scratch = &[_][2]i32{};
            self.mesh = null;
            self.light_dir = math.Vec3.new(0.0, 0.0, 0.0);
            self.vertex_generation = 0;
            self.full_vertex_cache_valid = false;
            self.valid = false;
        }

        fn ensureCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, vertex_count: usize) !void {
            if (self.projected.len != vertex_count) {
                if (self.projected.len != 0) allocator.free(self.projected);
                self.projected = if (vertex_count == 0)
                    &[_][2]i32{}
                else
                    try allocator.alloc([2]i32, vertex_count);
                self.valid = false;
            }
            if (self.transformed_vertices.len != vertex_count) {
                if (self.transformed_vertices.len != 0) allocator.free(self.transformed_vertices);
                self.transformed_vertices = if (vertex_count == 0)
                    &[_]math.Vec3{}
                else
                    try allocator.alloc(math.Vec3, vertex_count);
                self.valid = false;
            }
            if (self.vertex_ready.len != vertex_count) {
                if (self.vertex_ready.len != 0) allocator.free(self.vertex_ready);
                self.vertex_ready = if (vertex_count == 0)
                    &[_]std.atomic.Value(u32){}
                else blk: {
                    const states = try allocator.alloc(std.atomic.Value(u32), vertex_count);
                    for (states) |*state| state.* = std.atomic.Value(u32).init(0);
                    break :blk states;
                };
                self.vertex_generation = 0;
                self.full_vertex_cache_valid = false;
                self.valid = false;
            }
        }

        fn ensureMeshletVisibilityCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.meshlet_visibility.len < capacity) {
                if (self.meshlet_visibility.len == 0) {
                    self.meshlet_visibility = try allocator.alloc(bool, capacity);
                } else {
                    self.meshlet_visibility = try allocator.realloc(self.meshlet_visibility, capacity);
                }
            }
        }

        fn ensureVisibleMeshletCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.visible_meshlet_indices.len < capacity) {
                if (self.visible_meshlet_indices.len == 0) {
                    self.visible_meshlet_indices = try allocator.alloc(usize, capacity);
                } else {
                    self.visible_meshlet_indices = try allocator.realloc(self.visible_meshlet_indices, capacity);
                }
            }

            if (self.visible_meshlet_offsets.len < capacity) {
                if (self.visible_meshlet_offsets.len == 0) {
                    self.visible_meshlet_offsets = try allocator.alloc(usize, capacity);
                } else {
                    self.visible_meshlet_offsets = try allocator.realloc(self.visible_meshlet_offsets, capacity);
                }
            }

            if (self.visible_meshlet_vertex_offsets.len < capacity) {
                if (self.visible_meshlet_vertex_offsets.len == 0) {
                    self.visible_meshlet_vertex_offsets = try allocator.alloc(usize, capacity);
                } else {
                    self.visible_meshlet_vertex_offsets = try allocator.realloc(self.visible_meshlet_vertex_offsets, capacity);
                }
            }
        }

        fn ensureMeshletLocalScratchCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, vertex_capacity: usize) !void {
            if (vertex_capacity == 0) return;

            if (self.meshlet_local_camera_scratch.len < vertex_capacity) {
                if (self.meshlet_local_camera_scratch.len == 0) {
                    self.meshlet_local_camera_scratch = try allocator.alloc(math.Vec3, vertex_capacity);
                } else {
                    self.meshlet_local_camera_scratch = try allocator.realloc(self.meshlet_local_camera_scratch, vertex_capacity);
                }
            }

            if (self.meshlet_local_projected_scratch.len < vertex_capacity) {
                if (self.meshlet_local_projected_scratch.len == 0) {
                    self.meshlet_local_projected_scratch = try allocator.alloc([2]i32, vertex_capacity);
                } else {
                    self.meshlet_local_projected_scratch = try allocator.realloc(self.meshlet_local_projected_scratch, vertex_capacity);
                }
            }
        }

        fn ensureMeshletCullJobCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.meshlet_cull_jobs.len < capacity) {
                if (self.meshlet_cull_jobs.len == 0) {
                    self.meshlet_cull_jobs = try allocator.alloc(MeshletCullJob, capacity);
                } else {
                    self.meshlet_cull_jobs = try allocator.realloc(self.meshlet_cull_jobs, capacity);
                }
            }

            if (self.meshlet_cull_job_handles.len < capacity) {
                if (self.meshlet_cull_job_handles.len == 0) {
                    self.meshlet_cull_job_handles = try allocator.alloc(Job, capacity);
                } else {
                    self.meshlet_cull_job_handles = try allocator.realloc(self.meshlet_cull_job_handles, capacity);
                }
            }

            if (self.meshlet_cull_job_completion.len < capacity) {
                if (self.meshlet_cull_job_completion.len == 0) {
                    self.meshlet_cull_job_completion = try allocator.alloc(bool, capacity);
                } else {
                    self.meshlet_cull_job_completion = try allocator.realloc(self.meshlet_cull_job_completion, capacity);
                }
            }
        }

        fn ensureMeshletJobCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.meshlet_jobs.len < capacity) {
                if (self.meshlet_jobs.len == 0) {
                    self.meshlet_jobs = try allocator.alloc(MeshletRenderJob, capacity);
                } else {
                    self.meshlet_jobs = try allocator.realloc(self.meshlet_jobs, capacity);
                }
            }

            if (self.meshlet_job_handles.len < capacity) {
                if (self.meshlet_job_handles.len == 0) {
                    self.meshlet_job_handles = try allocator.alloc(Job, capacity);
                } else {
                    self.meshlet_job_handles = try allocator.realloc(self.meshlet_job_handles, capacity);
                }
            }

            if (self.meshlet_job_completion.len < capacity) {
                if (self.meshlet_job_completion.len == 0) {
                    self.meshlet_job_completion = try allocator.alloc(bool, capacity);
                } else {
                    self.meshlet_job_completion = try allocator.realloc(self.meshlet_job_completion, capacity);
                }
            }

            if (self.meshlet_contributions.len < capacity) {
                const old_len = self.meshlet_contributions.len;
                if (old_len == 0) {
                    self.meshlet_contributions = try allocator.alloc(MeshletContribution, capacity);
                    for (self.meshlet_contributions) |*contrib| contrib.* = MeshletContribution.init(allocator);
                } else {
                    const new_slice = try allocator.realloc(self.meshlet_contributions, capacity);
                    for (new_slice[old_len..capacity]) |*contrib| contrib.* = MeshletContribution.init(allocator);
                    self.meshlet_contributions = new_slice;
                }
            }
        }

        fn approxEqVec3(a: math.Vec3, b: math.Vec3, epsilon: f32) bool {
            return @abs(a.x - b.x) <= epsilon and @abs(a.y - b.y) <= epsilon and @abs(a.z - b.z) <= epsilon;
        }

        fn approxEqProjection(a: ProjectionParams, b: ProjectionParams, epsilon: f32) bool {
            return @abs(a.center_x - b.center_x) <= epsilon and
                @abs(a.center_y - b.center_y) <= epsilon and
                @abs(a.x_scale - b.x_scale) <= epsilon and
                @abs(a.y_scale - b.y_scale) <= epsilon and
                @abs(a.near_plane - b.near_plane) <= epsilon;
        }

        fn needsUpdate(
            self: *const MeshWorkCache,
            mesh: *const Mesh,
            camera_position: math.Vec3,
            right: math.Vec3,
            up: math.Vec3,
            forward: math.Vec3,
            light_dir: math.Vec3,
            projection: ProjectionParams,
        ) bool {
            const epsilon: f32 = 1e-5;
            if (!self.valid) return true;
            if (self.mesh != mesh) return true;
            if (!approxEqVec3(self.camera_position, camera_position, epsilon)) return true;
            if (!approxEqVec3(self.right, right, epsilon)) return true;
            if (!approxEqVec3(self.up, up, epsilon)) return true;
            if (!approxEqVec3(self.forward, forward, epsilon)) return true;
            if (!approxEqVec3(self.light_dir, light_dir, epsilon)) return true;
            if (!approxEqProjection(self.projection, projection, epsilon)) return true;
            return false;
        }

        fn invalidate(self: *MeshWorkCache) void {
            self.valid = false;
        }

        fn beginUpdate(self: *MeshWorkCache) void {
            self.valid = false;
            self.work.clear();
            self.advanceVertexGeneration();
            self.full_vertex_cache_valid = false;
        }

        fn advanceVertexGeneration(self: *MeshWorkCache) void {
            if (self.vertex_generation >= (std.math.maxInt(u32) >> 1) - 1) {
                for (self.vertex_ready) |*state| {
                    state.store(0, .release);
                }
                self.vertex_generation = 1;
                return;
            }
            self.vertex_generation += 1;
        }

        fn finalizeUpdate(
            self: *MeshWorkCache,
            mesh: *const Mesh,
            camera_position: math.Vec3,
            right: math.Vec3,
            up: math.Vec3,
            forward: math.Vec3,
            light_dir: math.Vec3,
            projection: ProjectionParams,
        ) void {
            self.mesh = mesh;
            self.camera_position = camera_position;
            self.right = right;
            self.up = up;
            self.forward = forward;
            self.light_dir = light_dir;
            self.projection = projection;
            self.valid = true;
        }
    };

    pub fn handleKeyInput(self: *Renderer, key: u32, is_down: bool) void {
        _ = input.updateKeyState(&self.keys_pressed, key, is_down);
    }

    pub fn handleMouseMove(self: *Renderer, x: i32, y: i32) void {
        const current = windows.POINT{ .x = x, .y = y };
        if (!self.mouse_initialized) {
            self.mouse_last_pos = current;
            self.mouse_initialized = true;
            return;
        }

        const dx = @as(f32, @floatFromInt(current.x - self.mouse_last_pos.x));
        const dy = @as(f32, @floatFromInt(current.y - self.mouse_last_pos.y));
        self.pending_mouse_delta = math.Vec2.new(self.pending_mouse_delta.x + dx, self.pending_mouse_delta.y + dy);
        self.mouse_last_pos = current;
    }

    pub fn setCameraPosition(self: *Renderer, position: math.Vec3) void {
        self.camera_position = position;
    }

    pub fn setCameraOrientation(self: *Renderer, pitch: f32, yaw: f32) void {
        self.rotation_x = std.math.clamp(pitch, -1.5, 1.5);
        self.rotation_angle = yaw;
    }

    fn consumeMouseDelta(self: *Renderer) math.Vec2 {
        const delta = self.pending_mouse_delta;
        self.pending_mouse_delta = math.Vec2.new(0.0, 0.0);
        return delta;
    }

    pub fn shouldRenderFrame(self: *Renderer) bool {
        if (self.target_frame_time_ns <= 0) return true;
        const now = std.time.nanoTimestamp();
        return now - self.last_frame_time >= self.target_frame_time_ns;
    }

    pub fn handleCharInput(self: *Renderer, char_code: u32) void {
        switch (char_code) {
            'q', 'Q' => self.pending_fov_delta -= config.CAMERA_FOV_STEP,
            'e', 'E' => self.pending_fov_delta += config.CAMERA_FOV_STEP,
            'p', 'P' => {
                self.show_render_overlay = !self.show_render_overlay;
                renderer_logger.infoSub(
                    "overlay",
                    "render overlay {s}",
                    .{if (self.show_render_overlay) "enabled" else "disabled"},
                );
            },
            'h', 'H' => {
                self.hybrid_shadow_debug.enabled = !self.hybrid_shadow_debug.enabled;
                self.hybrid_shadow_debug.reset();
                renderer_logger.infoSub(
                    "shadow_debug",
                    "hybrid shadow stepping {s}",
                    .{if (self.hybrid_shadow_debug.enabled) "enabled" else "disabled"},
                );
            },
            'n', 'N' => if (self.hybrid_shadow_debug.enabled) {
                self.hybrid_shadow_debug.advance_requested = true;
            },
            else => {},
        }
    }

    pub fn setTexture(self: *Renderer, tex: *const texture.Texture) void {
        self.single_texture_binding[0] = tex;
        self.textures = self.single_texture_binding[0..];
    }

    pub fn setTextures(self: *Renderer, textures: []const ?*const texture.Texture) void {
        self.textures = textures;
    }

    /// The main render loop function for a single frame.
    pub fn render3DMesh(self: *Renderer, mesh: *const Mesh) !void {
        try self.render3DMeshWithPump(mesh, null);
    }

    /// The main render loop function, with an added callback to process OS messages.
    /// This is the heart of the engine, executing the full 3D pipeline each frame.
    pub fn render3DMeshWithPump(self: *Renderer, mesh: *const Mesh, pump: ?*const fn (*Renderer) bool) !void {
        @memset(self.bitmap.pixels, 0xFF000000);
        self.resetRenderPassTimings();

        const delta_seconds = self.beginFrame();
        const simulation_delta_seconds: f32 = if (self.hybrid_shadow_debug.enabled) 0.0 else delta_seconds;

        renderer_logger.debugSub(
            "frame",
            "begin frame {} camera=({d:.2},{d:.2},{d:.2}) fov={d:.1}",
            .{
                self.frame_count + 1,
                self.camera_position.x,
                self.camera_position.y,
                self.camera_position.z,
                self.camera_fov_deg,
            },
        );

        const rotation_speed = 2.0;
        if ((self.keys_pressed & input.KeyBits.left) != 0) self.rotation_angle -= rotation_speed * simulation_delta_seconds;
        if ((self.keys_pressed & input.KeyBits.right) != 0) self.rotation_angle += rotation_speed * simulation_delta_seconds;
        if ((self.keys_pressed & input.KeyBits.up) != 0) self.rotation_x -= rotation_speed * simulation_delta_seconds;
        if ((self.keys_pressed & input.KeyBits.down) != 0) self.rotation_x += rotation_speed * simulation_delta_seconds;

        const mouse_delta = self.consumeMouseDelta();
        self.rotation_angle += mouse_delta.x * self.mouse_sensitivity;
        self.rotation_x -= mouse_delta.y * self.mouse_sensitivity;
        self.rotation_x = std.math.clamp(self.rotation_x, -1.5, 1.5);

        const fov_delta = self.consumePendingFovDelta();
        if (fov_delta != 0.0) self.adjustCameraFov(fov_delta);

        const sweep_half_angle = std.math.pi / 2.0;
        for (self.lights.items) |*light| {
            light.orbit_x += light.orbit_speed * simulation_delta_seconds;
            const sweep_angle = @sin(light.orbit_x) * sweep_half_angle;
            const horizontal_radius = light.distance * @cos(light.elevation);
            const light_height = @max(0.35, light.distance * @sin(light.elevation));
            const light_pos = math.Vec3.new(
                @sin(sweep_angle) * horizontal_radius,
                light_height,
                @cos(sweep_angle) * horizontal_radius,
            );
            light.direction = math.Vec3.normalize(light_pos);
        }
        const light_distance_0 = if (self.lights.items.len > 0) self.lights.items[0].distance else 10.0;
        const light_dir_world = if (self.lights.items.len > 0) self.lights.items[0].direction else math.Vec3.new(0, -1, 0);
        const light_pos_world = math.Vec3.scale(light_dir_world, light_distance_0);

        const yaw = self.rotation_angle;
        const pitch = self.rotation_x;
        const cos_pitch = @cos(pitch);
        const sin_pitch = @sin(pitch);
        const cos_yaw = @cos(yaw);
        const sin_yaw = @sin(yaw);

        var forward = math.Vec3.new(sin_yaw * cos_pitch, sin_pitch, cos_yaw * cos_pitch);
        forward = math.Vec3.normalize(forward);

        const world_up = math.Vec3.new(0.0, 1.0, 0.0);
        var right = math.Vec3.cross(world_up, forward);
        const right_len = math.Vec3.length(right);
        if (right_len < 0.0001) {
            right = math.Vec3.new(1.0, 0.0, 0.0);
        } else {
            right = math.Vec3.scale(right, 1.0 / right_len);
        }

        var up = math.Vec3.cross(forward, right);
        up = math.Vec3.normalize(up);

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
        if ((self.keys_pressed & input.KeyBits.w) != 0) movement_dir = math.Vec3.add(movement_dir, forward_flat);
        if ((self.keys_pressed & input.KeyBits.s) != 0) movement_dir = math.Vec3.sub(movement_dir, forward_flat);
        if ((self.keys_pressed & input.KeyBits.d) != 0) movement_dir = math.Vec3.add(movement_dir, right_flat);
        if ((self.keys_pressed & input.KeyBits.a) != 0) movement_dir = math.Vec3.sub(movement_dir, right_flat);
        if ((self.keys_pressed & input.KeyBits.space) != 0) movement_dir = math.Vec3.add(movement_dir, world_up);
        if ((self.keys_pressed & input.KeyBits.ctrl) != 0) movement_dir = math.Vec3.sub(movement_dir, world_up);

        const movement_mag = math.Vec3.length(movement_dir);
        if (movement_mag > 0.0001) {
            const normalized_move = math.Vec3.scale(movement_dir, 1.0 / movement_mag);
            const move_step = math.Vec3.scale(normalized_move, self.camera_move_speed * simulation_delta_seconds);
            self.camera_position = math.Vec3.add(self.camera_position, move_step);
        }

        var view_rotation = math.Mat4.identity();
        view_rotation.data[0] = right.x;
        view_rotation.data[1] = right.y;
        view_rotation.data[2] = right.z;
        view_rotation.data[4] = up.x;
        view_rotation.data[5] = up.y;
        view_rotation.data[6] = up.z;
        view_rotation.data[8] = forward.x;
        view_rotation.data[9] = forward.y;
        view_rotation.data[10] = forward.z;

        const light_relative = math.Vec3.sub(light_pos_world, self.camera_position);
        const light_camera = math.Vec3.new(
            math.Vec3.dot(light_relative, right),
            math.Vec3.dot(light_relative, up),
            math.Vec3.dot(light_relative, forward),
        );

        const light_dir = math.Vec3.normalize(math.Vec3.new(
            math.Vec3.dot(light_dir_world, right),
            math.Vec3.dot(light_dir_world, up),
            math.Vec3.dot(light_dir_world, forward),
        ));

        const width_f = @as(f32, @floatFromInt(self.bitmap.width));
        const height_f = @as(f32, @floatFromInt(self.bitmap.height));
        const aspect_ratio = if (height_f > 0.0) width_f / height_f else 1.0;
        const fov_rad = self.camera_fov_deg * (std.math.pi / 180.0);
        const half_fov = fov_rad * 0.5;
        const tan_half_fov = std.math.tan(half_fov);
        const y_scale = if (tan_half_fov > 0.0) 1.0 / tan_half_fov else 1.0;
        const x_scale = y_scale / aspect_ratio;
        const center_x = width_f * 0.5;
        const center_y = height_f * 0.5;

        const cache_projection = ProjectionParams{
            .center_x = center_x,
            .center_y = center_y,
            .x_scale = x_scale,
            .y_scale = y_scale,
            .near_plane = NEAR_CLIP,
            .jitter_x = 0.0,
            .jitter_y = 0.0,
        };
        const taa_jitter = if (config.POST_TAA_ENABLED) taaJitterForFrame(self.total_frames_rendered) else math.Vec2.new(0.0, 0.0);
        const raster_projection = ProjectionParams{
            .center_x = center_x,
            .center_y = center_y,
            .x_scale = x_scale,
            .y_scale = y_scale,
            .near_plane = NEAR_CLIP,
            .jitter_x = taa_jitter.x,
            .jitter_y = taa_jitter.y,
        };
        const taa_view = TemporalAAViewState.init(self.camera_position, right, up, forward, raster_projection);

        var cache = &self.mesh_work_cache;
        try cache.ensureCapacity(self.allocator, mesh.vertices.len);

        const needs_update = cache.needsUpdate(
            mesh,
            self.camera_position,
            right,
            up,
            forward,
            light_dir,
            cache_projection,
        );
        if (needs_update) {
            const mesh_work_start = std.time.nanoTimestamp();
            meshlet_logger.debugSub(
                "work",
                "refreshing mesh work cache (vertices={} triangles={})",
                .{ mesh.vertices.len, mesh.triangles.len },
            );
            cache.beginUpdate();
            try self.generateMeshWork(
                mesh,
                cache.projected,
                cache.transformed_vertices,
                cache.vertex_ready,
                right,
                up,
                forward,
                cache_projection,
                &cache.work,
                light_dir,
            );
            cache.finalizeUpdate(mesh, self.camera_position, right, up, forward, light_dir, cache_projection);
            self.recordRenderPassTiming("mesh_work_update", mesh_work_start);
        } else {
            meshlet_logger.debugSub("work", "reusing cached mesh work", .{});
        }

        if (builtin.mode == .Debug and cache.full_vertex_cache_valid and cache.transformed_vertices.len == mesh.vertices.len) {
            self.debugGroundPlane(mesh, cache.transformed_vertices, view_rotation);
        }

        const mesh_work = &cache.work;
        var shadow_elapsed_ns: i128 = 0;
        if (config.POST_SHADOW_ENABLED) {
            for (self.lights.items) |*light| {
                shadow_elapsed_ns += self.buildShadowMap(mesh, light.direction, &light.shadow_map);
            }
        }

        const scene_pass_start = std.time.nanoTimestamp();
        if (self.use_tiled_rendering and self.tile_grid != null and self.tile_buffers != null) {
            const tri_count = mesh_work.triangleSlice().len;
            pipeline_logger.debugSub("dispatch", "rendering tiled path triangles={} meshlets={}", .{ tri_count, mesh_work.*.meshlet_len });
            try self.renderTiled(mesh, view_rotation, light_dir, pump, raster_projection, mesh_work);
            self.recordRenderPassTiming("meshlet_tiled", scene_pass_start);
        } else {
            const tri_count = mesh_work.triangleSlice().len;
            pipeline_logger.debugSub("dispatch", "rendering direct path triangles={} meshlets={}", .{ tri_count, mesh_work.*.meshlet_len });
            try self.renderDirect(mesh, view_rotation, light_dir, raster_projection, mesh_work);
            self.recordRenderPassTiming("meshlet_direct", scene_pass_start);
        }

        self.applyPostProcessingPasses(mesh, self.camera_position, right, up, forward, taa_view, raster_projection, light_dir_world, shadow_elapsed_ns);
        if (self.show_light_orb) {
            const light_camera_z = light_camera.z;
            if (light_camera_z > NEAR_CLIP) {
                self.drawLightMarker(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale);
            }
        }
        const present_start = std.time.nanoTimestamp();
        self.drawBitmap();
        self.recordRenderPassTiming("present", present_start);
        pipeline_logger.debugSub("present", "bitmap presented", .{});

        self.frame_count += 1;
        self.total_frames_rendered += 1;
        self.maybeEmitSingleFrameProfile();
        const current_time = std.time.nanoTimestamp();
        self.finalizeFrame(current_time);

        renderer_logger.debugSub(
            "frame",
            "finish frame {} delta={d:.3}ms fps={}",
            .{
                self.frame_count,
                delta_seconds * 1000.0,
                self.current_fps,
            },
        );
    }

    fn beginFrame(self: *Renderer) f32 {
        const now = std.time.nanoTimestamp();
        var delta_ns = now - self.last_frame_time;
        if (delta_ns < 0) delta_ns = 0;
        self.last_frame_time = now;

        const delta_ns_f = @as(f64, @floatFromInt(delta_ns));
        var delta_seconds = @as(f32, @floatCast(delta_ns_f / 1_000_000_000.0));
        if (delta_seconds > 0.1) delta_seconds = 0.1;
        if (delta_seconds <= 0.0) delta_seconds = 1.0 / 120.0;
        return delta_seconds;
    }

    fn maybeEmitSingleFrameProfile(self: *Renderer) void {
        if (self.profile_capture_emitted or self.profile_capture_frame == 0) return;
        if (self.total_frames_rendered != self.profile_capture_frame) return;

        self.profile_capture_emitted = true;
        renderer_logger.infoSub("frame_profile", "frame={} exact pass timings follow", .{self.total_frames_rendered});

        for (self.render_pass_timings[0..self.render_pass_count]) |pass| {
            renderer_logger.infoSub("frame_profile", "{s}: {d:.3} ms", .{ pass.name, pass.frame_duration_ms });
        }

        if (self.hybrid_shadow_stats.job_count != 0) {
            renderer_logger.infoSub(
                "frame_profile",
                "hybrid_shadow detail accel={d:.3} candidate={d:.3} clear={d:.3} execute={d:.3} jobs={} active_tiles={} grid={} unique={} final={}",
                .{
                    self.hybrid_shadow_stats.accel_rebuild_ms,
                    self.hybrid_shadow_stats.candidate_ms,
                    self.hybrid_shadow_stats.cache_clear_ms,
                    self.hybrid_shadow_stats.execute_ms,
                    self.hybrid_shadow_stats.job_count,
                    self.hybrid_shadow_stats.active_tile_count,
                    self.hybrid_shadow_stats.grid_candidate_count,
                    self.hybrid_shadow_stats.unique_candidate_count,
                    self.hybrid_shadow_stats.final_candidate_count,
                },
            );
        }
    }

    fn consumePendingFovDelta(self: *Renderer) f32 {
        const delta = self.pending_fov_delta;
        self.pending_fov_delta = 0.0;
        return delta;
    }

    fn adjustCameraFov(self: *Renderer, delta: f32) void {
        const new_fov = std.math.clamp(self.camera_fov_deg + delta, config.CAMERA_FOV_MIN, config.CAMERA_FOV_MAX);
        if (!std.math.approxEqAbs(f32, new_fov, self.camera_fov_deg, 0.0001)) {
            self.camera_fov_deg = new_fov;
            self.last_reported_fov_deg = new_fov;
        }
    }

    fn finalizeFrame(self: *Renderer, current_time: i128) void {
        const elapsed_ns = current_time - self.last_time;
        if (elapsed_ns < 1_000_000_000 or self.frame_count == 0) return;

        const elapsed_us = @divTrunc(elapsed_ns, 1000);
        if (elapsed_us == 0) return;
        self.current_fps = @as(u32, @intCast((self.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));

        const frame_count_f = @as(f32, @floatFromInt(self.frame_count));
        const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const avg_frame_time_ms = if (frame_count_f > 0.0) elapsed_ms / frame_count_f else 0.0;

        self.sampleRenderPassTimings(self.frame_count);
        self.frame_count = 0;
        self.last_time = current_time;
        self.updateWindowTitle(avg_frame_time_ms);
    }

    fn updateWindowTitle(self: *Renderer, avg_frame_time_ms: f32) void {
        var title_buffer: [256]u8 = undefined;
        const telemetry = self.meshlet_telemetry;
        const title = std.fmt.bufPrint(&title_buffer, "{s} | FPS: {} | Frame: {d:.2}ms | Meshlets: {}/{} | Tris: {} | Tiles: {}", .{
            config.WINDOW_TITLE,
            self.current_fps,
            avg_frame_time_ms,
            telemetry.visible_meshlets,
            telemetry.total_meshlets,
            telemetry.emitted_triangles,
            telemetry.touched_tiles,
        }) catch config.WINDOW_TITLE;

        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch 0;
        title_wide[title_len] = 0;
        _ = SetWindowTextW(self.hwnd, &title_wide);
    }

    fn resetRenderPassTimings(self: *Renderer) void {
        self.render_pass_count = 0;
    }

    fn recordRenderPassTiming(self: *Renderer, name: []const u8, start_ns: i128) void {
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        self.recordRenderPassDuration(name, elapsed_ns);
    }

    fn nanosecondsToMs(elapsed_ns: i128) f32 {
        return @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    }

    fn computeStripeCount(max_jobs: usize, row_count: usize) usize {
        if (row_count == 0 or max_jobs == 0) return 0;
        const desired = @max(@as(usize, 1), (row_count + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job);
        return @min(max_jobs, desired);
    }

    fn recordRenderPassDuration(self: *Renderer, name: []const u8, elapsed_ns: i128) void {
        if (self.render_pass_count >= self.render_pass_timings.len) return;
        const elapsed_ms = nanosecondsToMs(elapsed_ns);
        var timing = &self.render_pass_timings[self.render_pass_count];
        if (timing.name.len == 0 or !std.mem.eql(u8, timing.name, name)) {
            timing.* = .{
                .name = name,
                .frame_duration_ms = 0.0,
                .accumulated_ms = 0.0,
                .sampled_ms_per_frame = 0.0,
                .has_sample = false,
            };
        }
        timing.frame_duration_ms = elapsed_ms;
        timing.accumulated_ms += elapsed_ms;
        self.render_pass_count += 1;
    }

    fn sampleRenderPassTimings(self: *Renderer, frame_samples: u32) void {
        if (frame_samples == 0) return;
        const sample_count = @as(f32, @floatFromInt(frame_samples));
        for (self.render_pass_timings[0..self.render_pass_count]) |*pass| {
            pass.sampled_ms_per_frame = pass.accumulated_ms / sample_count;
            pass.accumulated_ms = 0.0;
            pass.has_sample = true;
        }
    }

    fn debugGroundPlane(self: *Renderer, mesh: *const Mesh, transformed_vertices: []math.Vec3, transform: math.Mat4) void {
        if (mesh.triangles.len < 2 or transformed_vertices.len < mesh.vertices.len) return;

        const tri_limit = @min(mesh.triangles.len, @as(usize, 2));
        var mask: u8 = 0;

        const TriDebug = struct {
            index: usize,
            mask: u8,
            z: [3]f32,
            dot: ?f32,
            front: [3]bool,
            crosses: bool,
        };

        var tri_debug: [2]TriDebug = undefined;
        var tri_debug_count: usize = 0;

        var tri_idx: usize = 0;
        while (tri_idx < tri_limit) : (tri_idx += 1) {
            const tri = mesh.triangles[tri_idx];
            const p0 = transformed_vertices[tri.v0];
            const p1 = transformed_vertices[tri.v1];
            const p2 = transformed_vertices[tri.v2];

            const front0 = p0.z >= NEAR_CLIP - NEAR_EPSILON;
            const front1 = p1.z >= NEAR_CLIP - NEAR_EPSILON;
            const front2 = p2.z >= NEAR_CLIP - NEAR_EPSILON;

            var tri_mask: u8 = 0;

            if (!front0 or !front1 or !front2) {
                tri_mask |= GroundReason.near_plane;
            }

            const crosses_near = (front0 or front1 or front2) and !(front0 and front1 and front2);
            if (crosses_near) tri_mask |= GroundReason.cross_near;
            var dot_value: ?f32 = null;

            if (!crosses_near) {
                const normal = mesh.normals[tri_idx];
                const normal_transformed_raw = math.Vec3.new(
                    transform.data[0] * normal.x + transform.data[1] * normal.y + transform.data[2] * normal.z,
                    transform.data[4] * normal.x + transform.data[5] * normal.y + transform.data[6] * normal.z,
                    transform.data[8] * normal.x + transform.data[9] * normal.y + transform.data[10] * normal.z,
                );
                const normal_transformed = normal_transformed_raw.normalize();

                const centroid = math.Vec3.scale(math.Vec3.add(math.Vec3.add(p0, p1), p2), 1.0 / 3.0);
                const view_dir = math.Vec3.scale(centroid, -1.0);
                const view_dir_len = math.Vec3.length(view_dir);
                if (view_dir_len > 1e-6) {
                    const view_vector = math.Vec3.scale(view_dir, 1.0 / view_dir_len);
                    const view_dot = normal_transformed.dot(view_vector);
                    dot_value = view_dot;
                    if (view_dot < -1e-4) tri_mask |= GroundReason.backface;
                }
            }

            if (tri_mask != 0 and tri_debug_count < tri_debug.len) {
                tri_debug[tri_debug_count] = TriDebug{
                    .index = tri_idx,
                    .mask = tri_mask,
                    .z = .{ p0.z, p1.z, p2.z },
                    .dot = dot_value,
                    .front = .{ front0, front1, front2 },
                    .crosses = crosses_near,
                };
                tri_debug_count += 1;
            }

            mask |= tri_mask;
        }

        self.ground_debug.frames_since_log += 1;
        const first_frame = self.frame_count == 0;
        const should_log = first_frame or mask != self.ground_debug.last_mask or (mask != 0 and self.ground_debug.frames_since_log >= 60);
        if (!should_log) return;

        self.ground_debug.frames_since_log = 0;
        self.ground_debug.last_mask = mask;

        if (mask == 0) {
            ground_logger.debug("ground plane visible (frame {})", .{self.frame_count});
            return;
        }

        for (tri_debug[0..tri_debug_count]) |info| {
            if (info.dot) |d| {
                ground_logger.debug(
                    "ground tri {} issue mask {b:0>3} z[{d:.3},{d:.3},{d:.3}] front[{},{},{}] crosses={} dot={d:.4}",
                    .{
                        info.index,
                        info.mask,
                        info.z[0],
                        info.z[1],
                        info.z[2],
                        info.front[0],
                        info.front[1],
                        info.front[2],
                        info.crosses,
                        d,
                    },
                );
            } else {
                ground_logger.debug(
                    "ground tri {} issue mask {b:0>3} z[{d:.3},{d:.3},{d:.3}] front[{},{},{}] crosses={} dot=n/a",
                    .{
                        info.index,
                        info.mask,
                        info.z[0],
                        info.z[1],
                        info.z[2],
                        info.front[0],
                        info.front[1],
                        info.front[2],
                        info.crosses,
                    },
                );
            }
        }
    }

    fn drawLightMarker(
        self: *Renderer,
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
            if (py < 0 or py >= self.bitmap.height) continue;
            var px = light_x - radius;
            while (px <= light_x + radius) : (px += 1) {
                if (px < 0 or px >= self.bitmap.width) continue;
                const dx = @as(f32, @floatFromInt(px - light_x));
                const dy = @as(f32, @floatFromInt(py - light_y));
                if ((dx * dx + dy * dy) > @as(f32, @floatFromInt(radius * radius))) continue;
                const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(px));
                if (idx < self.bitmap.pixels.len) self.bitmap.pixels[idx] = color;
            }
        }
    }

    fn buildShadowMap(self: *Renderer, mesh: *const Mesh, light_dir_world: math.Vec3, target_shadow_map: *ShadowMap) i128 {
        if (!config.POST_SHADOW_ENABLED or mesh.meshlets.len == 0) {
            target_shadow_map.*.active = false;
            return 0;
        }

        const pass_start = std.time.nanoTimestamp();
        const basis = chooseShadowBasis(light_dir_world);
        var min_x = std.math.inf(f32);
        var max_x = -std.math.inf(f32);
        var min_y = std.math.inf(f32);
        var max_y = -std.math.inf(f32);
        var min_z = std.math.inf(f32);
        var max_z = -std.math.inf(f32);

        for (mesh.vertices) |vertex| {
            const lx = math.Vec3.dot(vertex, basis.right);
            const ly = math.Vec3.dot(vertex, basis.up);
            const lz = math.Vec3.dot(vertex, basis.forward);
            min_x = @min(min_x, lx);
            max_x = @max(max_x, lx);
            min_y = @min(min_y, ly);
            max_y = @max(max_y, ly);
            min_z = @min(min_z, lz);
            max_z = @max(max_z, lz);
        }

        if (!std.math.isFinite(min_x) or !std.math.isFinite(max_x)) {
            target_shadow_map.*.active = false;
            return std.time.nanoTimestamp() - pass_start;
        }

        const range_x = @max(0.001, max_x - min_x);
        const range_y = @max(0.001, max_y - min_y);
        const range_z = @max(0.001, max_z - min_z);
        const margin = @max(0.25, @max(range_x, @max(range_y, range_z)) * 0.08);

        target_shadow_map.*.basis_right = basis.right;
        target_shadow_map.*.basis_up = basis.up;
        target_shadow_map.*.basis_forward = basis.forward;
        target_shadow_map.*.min_x = min_x - margin;
        target_shadow_map.*.max_x = max_x + margin;
        target_shadow_map.*.min_y = min_y - margin;
        target_shadow_map.*.max_y = max_y + margin;
        target_shadow_map.*.min_z = min_z - margin;
        target_shadow_map.*.max_z = max_z + margin;
        target_shadow_map.*.inv_extent_x = 1.0 / @max(0.001, target_shadow_map.*.max_x - target_shadow_map.*.min_x);
        target_shadow_map.*.inv_extent_y = 1.0 / @max(0.001, target_shadow_map.*.max_y - target_shadow_map.*.min_y);
        target_shadow_map.*.depth_bias = config.POST_SHADOW_DEPTH_BIAS;
        target_shadow_map.*.texel_bias = @max(
            0.001,
            @max(
                (target_shadow_map.*.max_x - target_shadow_map.*.min_x) / @as(f32, @floatFromInt(target_shadow_map.*.width)),
                (target_shadow_map.*.max_y - target_shadow_map.*.min_y) / @as(f32, @floatFromInt(target_shadow_map.*.height)),
            ) * 0.35,
        );
        target_shadow_map.*.active = true;
        @memset(target_shadow_map.*.depth, std.math.inf(f32));

        const stripe_count = computeStripeCount(self.shadow_raster_job_contexts.len, target_shadow_map.*.height);
        const rows_per_job = if (stripe_count <= 1) target_shadow_map.*.height else (target_shadow_map.*.height + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            rasterizeShadowMeshRange(mesh, target_shadow_map, 0, target_shadow_map.*.height, light_dir_world);
            return std.time.nanoTimestamp() - pass_start;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= target_shadow_map.*.height) break;
            const end_row = @min(target_shadow_map.*.height, start_row + rows_per_job);

            self.shadow_raster_job_contexts[stripe_index] = .{
                .mesh = mesh,
                .shadow = target_shadow_map,
                .start_row = start_row,
                .end_row = end_row,
                .light_dir_world = light_dir_world,
            };

            if (stripe_index == 0) continue;

            self.color_grade_jobs[stripe_index] = Job.init(
                ShadowRasterJobContext.run,
                @ptrCast(&self.shadow_raster_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                ShadowRasterJobContext.run(@ptrCast(&self.shadow_raster_job_contexts[stripe_index]));
            }
        }

        ShadowRasterJobContext.run(@ptrCast(&self.shadow_raster_job_contexts[0]));
        parent_job.complete();
        parent_job.wait();

        return std.time.nanoTimestamp() - pass_start;
    }

    fn applyShadowPass(
        self: *Renderer,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
        build_elapsed_ns: i128,
        target_shadow_map: *const ShadowMap,
        pass_index: usize,
    ) void {
        if (!target_shadow_map.*.active or self.bitmap.pixels.len == 0 or self.scene_depth.len != self.bitmap.pixels.len) return;

        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        const stripe_count = computeStripeCount(self.shadow_resolve_job_contexts.len, height);
        const rows_per_job = if (stripe_count <= 1) height else (height + stripe_count - 1) / stripe_count;
        const resolve_config = ShadowResolveConfig{
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .center_x = projection.center_x,
            .center_y = projection.center_y,
            .x_scale = projection.x_scale,
            .y_scale = projection.y_scale,
            .near_plane = projection.near_plane,
            .darkness_percent = config.POST_SHADOW_STRENGTH_PERCENT,
        };

        if (stripe_count <= 1 or self.job_system == null) {
            applyShadowRows(self.bitmap.pixels, self.scene_camera, width, 0, height, resolve_config, target_shadow_map);
            self.recordRenderPassDuration(if (pass_index == 0) "shadow_pass_0" else "shadow_pass_1", build_elapsed_ns + (std.time.nanoTimestamp() - pass_start));
            return;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= height) break;
            const end_row = @min(height, start_row + rows_per_job);

            self.shadow_resolve_job_contexts[stripe_index] = .{
                .pixels = self.bitmap.pixels,
                .camera_buffer = self.scene_camera,
                .width = width,
                .start_row = start_row,
                .end_row = end_row,
                .config = resolve_config,
                .shadow = target_shadow_map,
            };

            if (stripe_index == 0) continue;

            self.color_grade_jobs[stripe_index] = Job.init(
                ShadowResolveJobContext.run,
                @ptrCast(&self.shadow_resolve_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                ShadowResolveJobContext.run(@ptrCast(&self.shadow_resolve_job_contexts[stripe_index]));
            }
        }

        ShadowResolveJobContext.run(@ptrCast(&self.shadow_resolve_job_contexts[0]));
        parent_job.complete();
        parent_job.wait();
        self.recordRenderPassDuration(if (pass_index == 0) "shadow_pass_0" else "shadow_pass_1", build_elapsed_ns + (std.time.nanoTimestamp() - pass_start));
    }

    fn ensureHybridShadowScratch(self: *Renderer, caster_capacity: usize, tile_candidate_capacity: usize, grid_candidate_capacity: usize) !void {
        if (caster_capacity > self.hybrid_shadow_caster_indices.len) {
            self.hybrid_shadow_caster_indices = if (self.hybrid_shadow_caster_indices.len == 0)
                try self.allocator.alloc(usize, caster_capacity)
            else
                try self.allocator.realloc(self.hybrid_shadow_caster_indices, caster_capacity);
        }

        if (caster_capacity > self.hybrid_shadow_caster_bounds.len) {
            self.hybrid_shadow_caster_bounds = if (self.hybrid_shadow_caster_bounds.len == 0)
                try self.allocator.alloc(HybridShadowCasterBounds, caster_capacity)
            else
                try self.allocator.realloc(self.hybrid_shadow_caster_bounds, caster_capacity);
        }

        if (caster_capacity > self.hybrid_shadow_candidate_marks.len) {
            self.hybrid_shadow_candidate_marks = if (self.hybrid_shadow_candidate_marks.len == 0)
                try self.allocator.alloc(u32, caster_capacity)
            else
                try self.allocator.realloc(self.hybrid_shadow_candidate_marks, caster_capacity);
            @memset(self.hybrid_shadow_candidate_marks, 0);
            self.hybrid_shadow_candidate_mark_generation = 0;
        }

        if (tile_candidate_capacity > self.hybrid_shadow_tile_candidates.len) {
            self.hybrid_shadow_tile_candidates = if (self.hybrid_shadow_tile_candidates.len == 0)
                try self.allocator.alloc(usize, tile_candidate_capacity)
            else
                try self.allocator.realloc(self.hybrid_shadow_tile_candidates, tile_candidate_capacity);
        }

        if (grid_candidate_capacity > self.hybrid_shadow_grid_candidates.len) {
            self.hybrid_shadow_grid_candidates = if (self.hybrid_shadow_grid_candidates.len == 0)
                try self.allocator.alloc(usize, grid_candidate_capacity)
            else
                try self.allocator.realloc(self.hybrid_shadow_grid_candidates, grid_candidate_capacity);
        }
    }

    fn nextHybridShadowCandidateMark(self: *Renderer) u32 {
        if (self.hybrid_shadow_candidate_marks.len == 0) return 0;

        if (self.hybrid_shadow_candidate_mark_generation == std.math.maxInt(u32)) {
            @memset(self.hybrid_shadow_candidate_marks, 0);
            self.hybrid_shadow_candidate_mark_generation = 1;
        } else {
            self.hybrid_shadow_candidate_mark_generation += 1;
            if (self.hybrid_shadow_candidate_mark_generation == 0) self.hybrid_shadow_candidate_mark_generation = 1;
        }
        return self.hybrid_shadow_candidate_mark_generation;
    }

    fn collectHybridShadowTileCandidates(
        self: *Renderer,
        receiver_bounds: HybridShadowReceiverBounds,
        candidate_write: *usize,
    ) HybridShadowStats {
        var stats = HybridShadowStats{};
        if (!self.hybrid_shadow_grid.active or self.hybrid_shadow_caster_count == 0) return stats;

        const grid = self.hybrid_shadow_grid;
        const mark = self.nextHybridShadowCandidateMark();
        if (mark == 0) return stats;

        const min_cell_x = std.math.clamp(
            @as(i32, @intFromFloat(@floor((receiver_bounds.min_u - grid.min_u) * grid.inv_cell_u))),
            0,
            @as(i32, hybrid_shadow_grid_dim - 1),
        );
        const max_cell_x = std.math.clamp(
            @as(i32, @intFromFloat(@floor((receiver_bounds.max_u - grid.min_u) * grid.inv_cell_u))),
            0,
            @as(i32, hybrid_shadow_grid_dim - 1),
        );
        const min_cell_y = std.math.clamp(
            @as(i32, @intFromFloat(@floor((receiver_bounds.min_v - grid.min_v) * grid.inv_cell_v))),
            0,
            @as(i32, hybrid_shadow_grid_dim - 1),
        );
        const max_cell_y = std.math.clamp(
            @as(i32, @intFromFloat(@floor((receiver_bounds.max_v - grid.min_v) * grid.inv_cell_v))),
            0,
            @as(i32, hybrid_shadow_grid_dim - 1),
        );

        var cell_y = min_cell_y;
        while (cell_y <= max_cell_y) : (cell_y += 1) {
            var cell_x = min_cell_x;
            while (cell_x <= max_cell_x) : (cell_x += 1) {
                const cell_index = @as(usize, @intCast(cell_y)) * hybrid_shadow_grid_dim + @as(usize, @intCast(cell_x));
                const cell_range = self.hybrid_shadow_grid_ranges[cell_index];
                if (cell_range.count == 0) continue;

                const caster_indices = self.hybrid_shadow_grid_candidates[cell_range.offset .. cell_range.offset + cell_range.count];
                stats.grid_candidate_count += caster_indices.len;
                for (caster_indices) |caster_index| {
                    if (caster_index >= self.hybrid_shadow_caster_count) continue;
                    if (self.hybrid_shadow_candidate_marks[caster_index] == mark) continue;
                    self.hybrid_shadow_candidate_marks[caster_index] = mark;
                    stats.unique_candidate_count += 1;

                    const caster = self.hybrid_shadow_caster_bounds[caster_index];
                    if (caster.max_depth <= receiver_bounds.min_depth + config.POST_HYBRID_SHADOW_RAY_BIAS) continue;
                    if (caster.max_u < receiver_bounds.min_u or caster.min_u > receiver_bounds.max_u) continue;
                    if (caster.max_v < receiver_bounds.min_v or caster.min_v > receiver_bounds.max_v) continue;

                    self.hybrid_shadow_tile_candidates[candidate_write.*] = caster_index;
                    candidate_write.* += 1;
                    stats.final_candidate_count += 1;
                }
            }
        }

        return stats;
    }

    fn buildHybridShadowReceiverBounds(
        self: *Renderer,
        tile: *const TileRenderer.Tile,
        camera_to_light: CameraToLightTransform,
    ) ?HybridShadowReceiverBounds {
        const tile_min_x = std.math.clamp(tile.x, 0, self.bitmap.width - 1);
        const tile_min_y = std.math.clamp(tile.y, 0, self.bitmap.height - 1);
        const tile_max_x = std.math.clamp(tile.x + tile.width - 1, 0, self.bitmap.width - 1);
        const tile_max_y = std.math.clamp(tile.y + tile.height - 1, 0, self.bitmap.height - 1);
        const sample_stride = @max(1, config.POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE);
        var min_u = std.math.inf(f32);
        var max_u = -std.math.inf(f32);
        var min_v = std.math.inf(f32);
        var max_v = -std.math.inf(f32);
        var min_depth = std.math.inf(f32);
        var found_valid = false;

        var screen_y = tile_min_y;
        while (screen_y <= tile_max_y) {
            const row_base = @as(usize, @intCast(screen_y * self.bitmap.width));
            var screen_x = tile_min_x;
            while (screen_x <= tile_max_x) {
                const idx = row_base + @as(usize, @intCast(screen_x));
                const camera_pos = self.scene_camera[idx];
                if (std.math.isFinite(camera_pos.z) and camera_pos.z > NEAR_CLIP) {
                    const light_sample = camera_to_light.project(camera_pos);

                    found_valid = true;
                    if (light_sample.u < min_u) min_u = light_sample.u;
                    if (light_sample.u > max_u) max_u = light_sample.u;
                    if (light_sample.v < min_v) min_v = light_sample.v;
                    if (light_sample.v > max_v) max_v = light_sample.v;
                    if (light_sample.depth < min_depth) min_depth = light_sample.depth;
                }

                if (screen_x == tile_max_x) break;
                screen_x = @min(tile_max_x, screen_x + sample_stride);
            }

            if (screen_y == tile_max_y) break;
            screen_y = @min(tile_max_y, screen_y + sample_stride);
        }

        if (!found_valid) return null;
        return .{
            .valid_min_x = tile_min_x,
            .valid_min_y = tile_min_y,
            .valid_max_x = tile_max_x,
            .valid_max_y = tile_max_y,
            .min_u = min_u,
            .max_u = max_u,
            .min_v = min_v,
            .max_v = max_v,
            .min_depth = min_depth,
        };
    }

    fn buildHybridShadowGrid(self: *Renderer, caster_count: usize, light_basis_right: math.Vec3, light_basis_up: math.Vec3) void {
        if (caster_count == 0) {
            self.hybrid_shadow_grid.active = false;
            return;
        }

        var min_u = std.math.inf(f32);
        var max_u = -std.math.inf(f32);
        var min_v = std.math.inf(f32);
        var max_v = -std.math.inf(f32);
        for (self.hybrid_shadow_caster_bounds[0..caster_count]) |caster| {
            if (caster.min_u < min_u) min_u = caster.min_u;
            if (caster.max_u > max_u) max_u = caster.max_u;
            if (caster.min_v < min_v) min_v = caster.min_v;
            if (caster.max_v > max_v) max_v = caster.max_v;
        }

        const extent_u = @max(1e-3, max_u - min_u);
        const extent_v = @max(1e-3, max_v - min_v);
        self.hybrid_shadow_grid = .{
            .basis_right = light_basis_right,
            .basis_up = light_basis_up,
            .min_u = min_u,
            .max_u = max_u,
            .min_v = min_v,
            .max_v = max_v,
            .inv_cell_u = @as(f32, @floatFromInt(hybrid_shadow_grid_dim)) / extent_u,
            .inv_cell_v = @as(f32, @floatFromInt(hybrid_shadow_grid_dim)) / extent_v,
            .active = true,
        };

        var counts = [_]usize{0} ** hybrid_shadow_grid_cells;
        for (self.hybrid_shadow_caster_bounds[0..caster_count]) |caster| {
            const min_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, hybrid_shadow_grid_dim - 1));
            const max_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, hybrid_shadow_grid_dim - 1));
            const min_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, hybrid_shadow_grid_dim - 1));
            const max_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, hybrid_shadow_grid_dim - 1));

            var cell_y = min_cell_y;
            while (cell_y <= max_cell_y) : (cell_y += 1) {
                var cell_x = min_cell_x;
                while (cell_x <= max_cell_x) : (cell_x += 1) {
                    const cell_index = @as(usize, @intCast(cell_y)) * hybrid_shadow_grid_dim + @as(usize, @intCast(cell_x));
                    counts[cell_index] += 1;
                }
            }
        }

        var offset: usize = 0;
        for (&self.hybrid_shadow_grid_ranges, 0..) |*range, cell_index| {
            range.offset = offset;
            range.count = counts[cell_index];
            offset += counts[cell_index];
        }

        var write_offsets = [_]usize{0} ** hybrid_shadow_grid_cells;
        for (self.hybrid_shadow_caster_bounds[0..caster_count], 0..) |caster, caster_index| {
            const min_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, hybrid_shadow_grid_dim - 1));
            const max_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, hybrid_shadow_grid_dim - 1));
            const min_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, hybrid_shadow_grid_dim - 1));
            const max_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, hybrid_shadow_grid_dim - 1));

            var cell_y = min_cell_y;
            while (cell_y <= max_cell_y) : (cell_y += 1) {
                var cell_x = min_cell_x;
                while (cell_x <= max_cell_x) : (cell_x += 1) {
                    const cell_index = @as(usize, @intCast(cell_y)) * hybrid_shadow_grid_dim + @as(usize, @intCast(cell_x));
                    const write_index = self.hybrid_shadow_grid_ranges[cell_index].offset + write_offsets[cell_index];
                    self.hybrid_shadow_grid_candidates[write_index] = caster_index;
                    write_offsets[cell_index] += 1;
                }
            }
        }
    }

    fn applyAdaptiveShadowPass(
        self: *Renderer,
        mesh: *const Mesh,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        light_dir_world: math.Vec3,
    ) void {
        if (!config.POST_HYBRID_SHADOW_ENABLED or self.bitmap.pixels.len == 0 or self.tile_grid == null or self.active_tile_flags == null) return;

        const pass_start = std.time.nanoTimestamp();
        self.hybrid_shadow_stats = .{};
        const grid = self.tile_grid.?;
        const active_flags = self.active_tile_flags.?;
        const active_indices = self.active_tile_indices.?;
        const shadow_jobs = self.shadow_tile_jobs_buffer.?;
        const tile_ranges = self.hybrid_shadow_tile_ranges;
        const jobs = self.job_buffer.?;
        const darkness_scale = 1.0 - (@as(f32, @floatFromInt(config.POST_SHADOW_STRENGTH_PERCENT)) / 100.0);
        const normalized_light_dir = math.Vec3.normalize(light_dir_world);
        const light_basis = chooseShadowBasis(normalized_light_dir);
        const camera_to_light = CameraToLightTransform.init(
            camera_position,
            basis_right,
            basis_up,
            basis_forward,
            light_basis.right,
            light_basis.up,
            normalized_light_dir,
        );
        var accel_elapsed_ns: i128 = 0;
        var active_tile_capacity: usize = 0;
        for (grid.tiles, 0..) |_, tile_index| {
            if (tile_index < active_flags.len and active_flags[tile_index]) active_tile_capacity += 1;
        }

        if (active_tile_capacity == 0 or mesh.meshlets.len == 0) return;
        self.ensureHybridShadowScratch(mesh.meshlets.len, active_tile_capacity * mesh.meshlets.len, mesh.meshlets.len * hybrid_shadow_grid_cells) catch |err| {
            pipeline_logger.errorSub("hybrid_shadow", "scratch allocation failed: {s}", .{@errorName(err)});
            return;
        };

        const accel_needs_rebuild = !self.hybrid_shadow_accel_valid or
            self.hybrid_shadow_cached_meshlet_count != mesh.meshlets.len or
            self.hybrid_shadow_cached_meshlet_vertex_count != mesh.meshlet_vertices.len or
            self.hybrid_shadow_cached_meshlet_primitive_count != mesh.meshlet_primitives.len or
            math.Vec3.dot(self.hybrid_shadow_cached_light_dir, normalized_light_dir) < shadow_rebuild_dot_threshold;

        if (accel_needs_rebuild) {
            const accel_start = std.time.nanoTimestamp();
            var caster_count: usize = 0;
            for (mesh.meshlets, 0..) |meshlet, meshlet_index| {
                if (meshlet.primitive_count == 0 or meshlet.bounds_radius <= 0.0) continue;
                const center_u = math.Vec3.dot(meshlet.bounds_center, light_basis.right);
                const center_v = math.Vec3.dot(meshlet.bounds_center, light_basis.up);
                const center_depth = math.Vec3.dot(meshlet.bounds_center, normalized_light_dir);

                self.hybrid_shadow_caster_indices[caster_count] = meshlet_index;
                self.hybrid_shadow_caster_bounds[caster_count] = .{
                    .meshlet_index = meshlet_index,
                    .min_u = center_u - meshlet.bounds_radius,
                    .max_u = center_u + meshlet.bounds_radius,
                    .min_v = center_v - meshlet.bounds_radius,
                    .max_v = center_v + meshlet.bounds_radius,
                    .max_depth = center_depth + meshlet.bounds_radius,
                };
                caster_count += 1;
            }
            self.hybrid_shadow_caster_count = caster_count;
            self.hybrid_shadow_cached_light_dir = normalized_light_dir;
            self.hybrid_shadow_cached_meshlet_count = mesh.meshlets.len;
            self.hybrid_shadow_cached_meshlet_vertex_count = mesh.meshlet_vertices.len;
            self.hybrid_shadow_cached_meshlet_primitive_count = mesh.meshlet_primitives.len;
            self.hybrid_shadow_accel_valid = caster_count != 0;
            if (caster_count == 0) return;
            self.buildHybridShadowGrid(caster_count, light_basis.right, light_basis.up);
            accel_elapsed_ns = std.time.nanoTimestamp() - accel_start;
        }

        const caster_count = self.hybrid_shadow_caster_count;
        if (caster_count == 0) return;

        const candidate_start = std.time.nanoTimestamp();
        var candidate_write: usize = 0;
        var shadow_job_count: usize = 0;
        for (grid.tiles, 0..) |*tile, tile_index| {
            tile_ranges[tile_index] = .{};
            if (tile_index >= active_flags.len or !active_flags[tile_index]) continue;
            self.hybrid_shadow_stats.active_tile_count += 1;

            const receiver_bounds = self.buildHybridShadowReceiverBounds(
                tile,
                camera_to_light,
            ) orelse continue;

            const candidate_offset = candidate_write;
            const candidate_stats = self.collectHybridShadowTileCandidates(receiver_bounds, &candidate_write);
            self.hybrid_shadow_stats.grid_candidate_count += candidate_stats.grid_candidate_count;
            self.hybrid_shadow_stats.unique_candidate_count += candidate_stats.unique_candidate_count;
            self.hybrid_shadow_stats.final_candidate_count += candidate_stats.final_candidate_count;

            const candidate_count = candidate_write - candidate_offset;
            if (candidate_count == 0) continue;

            tile_ranges[tile_index] = .{ .offset = candidate_offset, .count = candidate_count };
            shadow_jobs[tile_index] = .{
                .renderer = self,
                .mesh = mesh,
                .tile = tile,
                .camera_position = camera_position,
                .basis_right = basis_right,
                .basis_up = basis_up,
                .basis_forward = basis_forward,
                .light_dir_world = normalized_light_dir,
                .camera_to_light = camera_to_light,
                .darkness_scale = darkness_scale,
                .valid_min_x = receiver_bounds.valid_min_x,
                .valid_min_y = receiver_bounds.valid_min_y,
                .valid_max_x = receiver_bounds.valid_max_x,
                .valid_max_y = receiver_bounds.valid_max_y,
                .candidate_offset = candidate_offset,
                .candidate_count = candidate_count,
            };
            active_indices[shadow_job_count] = tile_index;
            shadow_job_count += 1;
        }

        self.hybrid_shadow_stats.accel_rebuild_ms = nanosecondsToMs(accel_elapsed_ns);
        self.hybrid_shadow_stats.candidate_ms = nanosecondsToMs(std.time.nanoTimestamp() - candidate_start);
        self.hybrid_shadow_stats.job_count = shadow_job_count;
        if (shadow_job_count == 0) return;
        const cache_clear_start = std.time.nanoTimestamp();
        @memset(self.hybrid_shadow_coarse_cache, 0xFF);
        @memset(self.hybrid_shadow_edge_cache, 0xFF);
        self.hybrid_shadow_stats.cache_clear_ms = nanosecondsToMs(std.time.nanoTimestamp() - cache_clear_start);

        if (self.hybrid_shadow_debug.enabled) {
            const execute_start = std.time.nanoTimestamp();
            if (self.hybrid_shadow_debug.completed_jobs > shadow_job_count) {
                self.hybrid_shadow_debug.completed_jobs = shadow_job_count;
            }
            if (self.hybrid_shadow_debug.advance_requested) {
                self.hybrid_shadow_debug.completed_jobs = @min(shadow_job_count, self.hybrid_shadow_debug.completed_jobs + 1);
            }
            self.hybrid_shadow_debug.advance_requested = false;

            for (active_indices[0..self.hybrid_shadow_debug.completed_jobs]) |tile_index| {
                AdaptiveShadowTileJob.run(@ptrCast(&shadow_jobs[tile_index]));
            }
            self.hybrid_shadow_stats.execute_ms = nanosecondsToMs(std.time.nanoTimestamp() - execute_start);
            self.recordRenderPassTiming("hybrid_shadow_step", pass_start);
            return;
        }

        const execute_start = std.time.nanoTimestamp();
        if (self.job_system) |job_sys| {
            var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
            const main_tile_idx = active_indices[0];

            for (active_indices[1..shadow_job_count]) |tile_index| {
                jobs[tile_index] = Job.init(
                    AdaptiveShadowTileJob.run,
                    @ptrCast(&shadow_jobs[tile_index]),
                    &parent_job,
                );
                if (!job_sys.submitJobAuto(&jobs[tile_index])) {
                    AdaptiveShadowTileJob.run(@ptrCast(&shadow_jobs[tile_index]));
                }
            }

            AdaptiveShadowTileJob.run(@ptrCast(&shadow_jobs[main_tile_idx]));
            parent_job.complete();
            parent_job.wait();
        } else {
            for (active_indices[0..shadow_job_count]) |tile_index| {
                AdaptiveShadowTileJob.run(@ptrCast(&shadow_jobs[tile_index]));
            }
        }

        self.hybrid_shadow_stats.execute_ms = nanosecondsToMs(std.time.nanoTimestamp() - execute_start);
        self.recordRenderPassTiming("hybrid_shadow", pass_start);
    }

    fn applyPostProcessingPasses(
        self: *Renderer,
        mesh: *const Mesh,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        current_view: TemporalAAViewState,
        projection: ProjectionParams,
        light_dir_world: math.Vec3,
        shadow_elapsed_ns: i128,
    ) void {
        if (config.POST_SHADOW_ENABLED) {
            for (self.lights.items, 0..) |*light, pass_index| {
                self.applyShadowPass(camera_position, basis_right, basis_up, basis_forward, projection, shadow_elapsed_ns, &light.shadow_map, pass_index);
            }
        }
        if (config.POST_HYBRID_SHADOW_ENABLED) self.applyAdaptiveShadowPass(mesh, camera_position, basis_right, basis_up, basis_forward, light_dir_world);
        if (config.POST_SSAO_ENABLED) self.applyAmbientOcclusionPass();
        if (config.POST_DEPTH_FOG_ENABLED) self.applyDepthFogPass();
        if (config.POST_TAA_ENABLED) self.applyTemporalAAPass(current_view);
        if (config.POST_BLOOM_ENABLED) self.applyBloomPass();
        if (config.POST_DOF_ENABLED) self.applyDepthOfFieldPass();
        if (!config.POST_COLOR_CORRECTION_ENABLED) return;
        self.applyBlockbusterColorGradePass();
    }

    fn applyAmbientOcclusionPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0 or self.scene_camera.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const scene_width: usize = @intCast(self.bitmap.width);
        const scene_height: usize = @intCast(self.bitmap.height);
        const ao = &self.ao_scratch;
        self.dispatchAmbientOcclusionStage(.generate, ao.height, scene_width, scene_height);
        self.dispatchAmbientOcclusionStage(.blur_horizontal, ao.height, scene_width, scene_height);
        self.dispatchAmbientOcclusionStage(.blur_vertical, ao.height, scene_width, scene_height);
        self.dispatchAmbientOcclusionStage(.composite, scene_height, scene_width, scene_height);
        self.recordRenderPassTiming("ssao", pass_start);
    }

    fn dispatchAmbientOcclusionStage(
        self: *Renderer,
        stage: AOPassStage,
        row_count: usize,
        scene_width: usize,
        scene_height: usize,
    ) void {
        if (row_count == 0) return;
        const stripe_count = computeStripeCount(self.ao_job_contexts.len, row_count);
        const rows_per_job = if (stripe_count <= 1) row_count else (row_count + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            self.runAmbientOcclusionStageRange(stage, 0, row_count, scene_width, scene_height);
            return;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= row_count) break;
            const end_row = @min(row_count, start_row + rows_per_job);

            self.ao_job_contexts[stripe_index] = .{
                .renderer = self,
                .stage = stage,
                .scene_width = scene_width,
                .scene_height = scene_height,
                .start_row = start_row,
                .end_row = end_row,
            };

            if (stripe_index == 0) continue;

            self.color_grade_jobs[stripe_index] = Job.init(
                AOJobContext.run,
                @ptrCast(&self.ao_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                self.runAmbientOcclusionStageRange(stage, start_row, end_row, scene_width, scene_height);
            }
        }

        self.runAmbientOcclusionStageRange(
            stage,
            self.ao_job_contexts[0].start_row,
            self.ao_job_contexts[0].end_row,
            scene_width,
            scene_height,
        );
        parent_job.complete();
        parent_job.wait();
    }

    fn runAmbientOcclusionStageRange(
        self: *Renderer,
        stage: AOPassStage,
        start_row: usize,
        end_row: usize,
        scene_width: usize,
        scene_height: usize,
    ) void {
        switch (stage) {
            .generate => renderAmbientOcclusionRows(
                self.scene_camera,
                scene_width,
                scene_height,
                &self.ao_scratch,
                self.ambient_occlusion_config,
                start_row,
                end_row,
            ),
            .blur_horizontal => blurAmbientOcclusionHorizontalRows(
                &self.ao_scratch,
                self.ambient_occlusion_config.blur_depth_threshold,
                start_row,
                end_row,
            ),
            .blur_vertical => blurAmbientOcclusionVerticalRows(
                &self.ao_scratch,
                self.ambient_occlusion_config.blur_depth_threshold,
                start_row,
                end_row,
            ),
            .composite => compositeAmbientOcclusionRows(
                self.bitmap.pixels,
                self.scene_camera,
                scene_width,
                scene_height,
                &self.ao_scratch,
                start_row,
                end_row,
            ),
        }
    }

    fn applyDepthFogPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0 or self.scene_depth.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        const stripe_count = computeStripeCount(self.fog_job_contexts.len, height);
        const rows_per_job = if (stripe_count <= 1) height else (height + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            applyDepthFogRows(self.bitmap.pixels, self.scene_depth, width, 0, height, self.depth_fog_config);
            self.recordRenderPassTiming("depth_fog", pass_start);
            return;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= height) break;
            const end_row = @min(height, start_row + rows_per_job);

            self.fog_job_contexts[stripe_index] = .{
                .pixels = self.bitmap.pixels,
                .depth = self.scene_depth,
                .width = width,
                .start_row = start_row,
                .end_row = end_row,
                .config = self.depth_fog_config,
            };

            if (stripe_index == 0) continue;

            self.color_grade_jobs[stripe_index] = Job.init(
                FogJobContext.run,
                @ptrCast(&self.fog_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                FogJobContext.run(@ptrCast(&self.fog_job_contexts[stripe_index]));
            }
        }

        FogJobContext.run(@ptrCast(&self.fog_job_contexts[0]));
        parent_job.complete();
        parent_job.wait();
        self.recordRenderPassTiming("depth_fog", pass_start);
    }

    fn applyTemporalAARows(
        self: *Renderer,
        current_view: TemporalAAViewState,
        previous_view: TemporalAAViewState,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,
    ) void {
        var y = start_row;
        while (y < end_row) : (y += 1) {
            const row_start = y * width;
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const idx = row_start + x;
                const current_pixel = self.bitmap.pixels[idx];
                self.taa_scratch.resolve_pixels[idx] = current_pixel;

                const current_camera = self.scene_camera[idx];
                if (!validSceneCameraSample(current_camera)) continue;

                const world_pos = cameraToWorldPosition(
                    current_view.camera_position,
                    current_view.basis_right,
                    current_view.basis_up,
                    current_view.basis_forward,
                    current_camera,
                );
                const previous_relative = math.Vec3.sub(world_pos, previous_view.camera_position);
                const previous_camera = math.Vec3.new(
                    math.Vec3.dot(previous_relative, previous_view.basis_right),
                    math.Vec3.dot(previous_relative, previous_view.basis_up),
                    math.Vec3.dot(previous_relative, previous_view.basis_forward),
                );
                if (previous_camera.z <= previous_view.projection.near_plane + NEAR_EPSILON) continue;

                const previous_screen = projectCameraPositionFloat(previous_camera, previous_view.projection);
                const previous_depth = sampleHistoryDepthNearest(self.taa_scratch.history_depth, width, height, previous_screen) orelse continue;
                if (@abs(previous_depth - previous_camera.z) > self.temporal_aa_config.depth_threshold) continue;

                const previous_color = sampleHistoryColor(self.taa_scratch.history_pixels, width, height, previous_screen) orelse continue;
                const clamped_history = clampHistoryToNeighborhood(self.bitmap.pixels, width, height, x, y, previous_color);
                self.taa_scratch.resolve_pixels[idx] = blendTemporalColor(current_pixel, clamped_history, self.temporal_aa_config.history_weight);
            }
        }
    }

    fn applyTemporalAAPass(self: *Renderer, current_view: TemporalAAViewState) void {
        if (self.bitmap.pixels.len == 0 or self.scene_camera.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);

        if (!self.taa_scratch.valid) {
            @memcpy(self.taa_scratch.history_pixels, self.bitmap.pixels);
            @memcpy(self.taa_scratch.history_depth, self.scene_depth);
            self.taa_previous_view = current_view;
            self.taa_scratch.valid = true;
            self.recordRenderPassTiming("taa", pass_start);
            return;
        }

        const stripe_count = computeStripeCount(self.taa_job_contexts.len, height);
        const rows_per_job = if (stripe_count <= 1) height else (height + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            self.applyTemporalAARows(current_view, self.taa_previous_view, 0, height, width, height);
        } else {
            var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
            var stripe_index: usize = 0;
            while (stripe_index < stripe_count) : (stripe_index += 1) {
                const start_row = stripe_index * rows_per_job;
                if (start_row >= height) break;
                const end_row = @min(height, start_row + rows_per_job);

                self.taa_job_contexts[stripe_index] = .{
                    .renderer = self,
                    .current_view = current_view,
                    .previous_view = self.taa_previous_view,
                    .start_row = start_row,
                    .end_row = end_row,
                    .width = width,
                    .height = height,
                };

                if (stripe_index == 0) continue;

                self.color_grade_jobs[stripe_index] = Job.init(
                    TAAJobContext.run,
                    @ptrCast(&self.taa_job_contexts[stripe_index]),
                    &parent_job,
                );
                if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                    TAAJobContext.run(@ptrCast(&self.taa_job_contexts[stripe_index]));
                }
            }

            TAAJobContext.run(@ptrCast(&self.taa_job_contexts[0]));
            parent_job.complete();
            parent_job.wait();
        }

        @memcpy(self.bitmap.pixels, self.taa_scratch.resolve_pixels);
        @memcpy(self.taa_scratch.history_pixels, self.bitmap.pixels);
        @memcpy(self.taa_scratch.history_depth, self.scene_depth);
        self.taa_previous_view = current_view;
        self.taa_scratch.valid = true;
        self.recordRenderPassTiming("taa", pass_start);
    }

    fn applyDepthOfFieldPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0 or self.scene_depth.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        
        const scene_width: usize = @intCast(self.bitmap.width);
        const scene_height: usize = @intCast(self.bitmap.height);
        
        const center_x = scene_width / 2;
        const center_y = scene_height / 2;
        var center_depth = self.scene_depth[center_y * scene_width + center_x];
        
        // Safety guard for extreme depths
        if (center_depth > 1000.0) center_depth = 1000.0;
        
        // Check a 3x3 region in center to ensure targeting isn't noisy
        var min_depth: f32 = 1000.0;
        const box_size: i32 = 4;
        
        var cy: i32 = -box_size;
        while (cy <= box_size) : (cy += 1) {
            var cx: i32 = -box_size;
            while (cx <= box_size) : (cx += 1) {
                const py = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(scene_height)) - 1, @as(i32, @intCast(center_y)) + cy))));
                const px = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(scene_width)) - 1, @as(i32, @intCast(center_x)) + cx))));
                const d = self.scene_depth[py * scene_width + px];
                if (d < min_depth) {
                    min_depth = d;
                }
            }
        }
        
        if (min_depth > 1000.0) min_depth = 1000.0;
        
        self.dof_target_focal_distance = min_depth;
        
        // Smooth lerp (Eye Accommodation)
        self.dof_focal_distance = self.dof_focal_distance + (self.dof_target_focal_distance - self.dof_focal_distance) * 0.1;
        
        const auto_focal_distance = self.dof_focal_distance;
        
        const stripe_count = computeStripeCount(self.dof_job_contexts.len, scene_height);
        const rows_per_job = if (stripe_count <= 1) scene_height else (scene_height + stripe_count - 1) / stripe_count;
        
        if (stripe_count <= 1 or self.job_system == null) {
            self.dof_job_contexts[0] = .{
                .scene_pixels = self.bitmap.pixels,
                .scratch_pixels = self.dof_scratch.pixels,
                .scene_depth = self.scene_depth,
                .width = scene_width,
                .height = scene_height,
                .start_row = 0,
                .end_row = scene_height,
                .focal_distance = auto_focal_distance,
                .focal_range = config.POST_DOF_FOCAL_RANGE,
                .max_blur_radius = config.POST_DOF_BLUR_RADIUS,
            };
            DepthOfFieldJobContext.run(&self.dof_job_contexts[0]);
        } else {
            var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
            var stripe_index: usize = 0;
            while (stripe_index < stripe_count) : (stripe_index += 1) {
                const start_row = stripe_index * rows_per_job;
                if (start_row >= scene_height) break;
                const end_row = @min(scene_height, start_row + rows_per_job);
                
                self.dof_job_contexts[stripe_index] = .{
                    .scene_pixels = self.bitmap.pixels,
                    .scratch_pixels = self.dof_scratch.pixels,
                    .scene_depth = self.scene_depth,
                    .width = scene_width,
                    .height = scene_height,
                    .start_row = start_row,
                    .end_row = end_row,
                    .focal_distance = auto_focal_distance,
                    .focal_range = config.POST_DOF_FOCAL_RANGE,
                    .max_blur_radius = config.POST_DOF_BLUR_RADIUS,
                };
                
                self.color_grade_jobs[stripe_index] = Job.init(
                    DepthOfFieldJobContext.run,
                    @ptrCast(&self.dof_job_contexts[stripe_index]),
                    &parent_job,
                );
                
                if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                    DepthOfFieldJobContext.run(@ptrCast(&self.dof_job_contexts[stripe_index]));
                }
            }
            DepthOfFieldJobContext.run(@ptrCast(&self.dof_job_contexts[0]));
            parent_job.complete();
            parent_job.wait();
        }
        
        // Copy back to main framebuffer
        @memcpy(self.bitmap.pixels, self.dof_scratch.pixels);
        
        self.recordRenderPassTiming("dof", pass_start);
    }
    
    fn applyBloomPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const bloom = &self.bloom_scratch;
        const scene_width: usize = @intCast(self.bitmap.width);
        const scene_height: usize = @intCast(self.bitmap.height);
        self.dispatchBloomStage(.extract, bloom.height, scene_width, scene_height, config.POST_BLOOM_THRESHOLD, 0);
        self.dispatchBloomStage(.blur_horizontal, bloom.height, scene_width, scene_height, 0, 0);
        self.dispatchBloomStage(.blur_vertical, bloom.height, scene_width, scene_height, 0, 0);
        self.dispatchBloomStage(.composite, scene_height, scene_width, scene_height, 0, config.POST_BLOOM_INTENSITY_PERCENT);
        self.recordRenderPassTiming("bloom", pass_start);
    }

    fn dispatchBloomStage(
        self: *Renderer,
        stage: BloomPassStage,
        row_count: usize,
        scene_width: usize,
        scene_height: usize,
        threshold: i32,
        intensity_percent: i32,
    ) void {
        if (row_count == 0) return;
        const stripe_count = computeStripeCount(self.bloom_job_contexts.len, row_count);
        const rows_per_job = if (stripe_count <= 1) row_count else (row_count + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            self.runBloomStageRange(stage, 0, row_count, scene_width, scene_height, threshold, intensity_percent);
            return;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= row_count) break;
            const end_row = @min(row_count, start_row + rows_per_job);

            self.bloom_job_contexts[stripe_index] = .{
                .stage = stage,
                .scene_pixels = self.bitmap.pixels,
                .scene_width = scene_width,
                .scene_height = scene_height,
                .bloom = &self.bloom_scratch,
                .threshold_curve = &self.bloom_threshold_curve,
                .intensity_lut = &self.bloom_intensity_lut,
                .start_row = start_row,
                .end_row = end_row,
            };

            if (stripe_index == 0) continue;

            self.color_grade_jobs[stripe_index] = Job.init(
                BloomJobContext.run,
                @ptrCast(&self.bloom_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                BloomJobContext.run(@ptrCast(&self.bloom_job_contexts[stripe_index]));
            }
        }

        BloomJobContext.run(@ptrCast(&self.bloom_job_contexts[0]));
        parent_job.complete();
        parent_job.wait();
    }

    fn runBloomStageRange(
        self: *Renderer,
        stage: BloomPassStage,
        start_row: usize,
        end_row: usize,
        scene_width: usize,
        scene_height: usize,
        threshold: i32,
        intensity_percent: i32,
    ) void {
        switch (stage) {
            .extract => {
                _ = threshold;
                extractBloomDownsampleRows(
                    self.bitmap.pixels,
                    scene_width,
                    scene_height,
                    &self.bloom_scratch,
                    &self.bloom_threshold_curve,
                    start_row,
                    end_row,
                );
            },
            .blur_horizontal => blurBloomHorizontalRows(&self.bloom_scratch, start_row, end_row),
            .blur_vertical => blurBloomVerticalRows(&self.bloom_scratch, start_row, end_row),
            .composite => {
                _ = intensity_percent;
                compositeBloomRows(
                    self.bitmap.pixels,
                    scene_width,
                    &self.bloom_scratch,
                    &self.bloom_intensity_lut,
                    start_row,
                    end_row,
                );
            },
        }
    }

    fn applyBlockbusterColorGradePass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        const stripe_count = computeStripeCount(self.color_grade_job_contexts.len, height);
        const rows_per_job = if (stripe_count <= 1) height else (height + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            applyBlockbusterGradeRange(self.bitmap.pixels, 0, self.bitmap.pixels.len, &self.color_grade_profile);
            self.recordRenderPassTiming(config.POST_COLOR_PROFILE_NAME, pass_start);
            return;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);

        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= height) break;
            const end_row = @min(height, start_row + rows_per_job);

            self.color_grade_job_contexts[stripe_index] = .{
                .pixels = self.bitmap.pixels,
                .start_index = start_row * width,
                .end_index = end_row * width,
                .profile = &self.color_grade_profile,
            };

            if (stripe_index == 0) continue;

            self.color_grade_jobs[stripe_index] = Job.init(
                ColorGradeJobContext.run,
                @ptrCast(&self.color_grade_job_contexts[stripe_index]),
                &parent_job,
            );

            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                applyBlockbusterGradeRange(
                    self.bitmap.pixels,
                    self.color_grade_job_contexts[stripe_index].start_index,
                    self.color_grade_job_contexts[stripe_index].end_index,
                    &self.color_grade_profile,
                );
            }
        }

        applyBlockbusterGradeRange(
            self.bitmap.pixels,
            self.color_grade_job_contexts[0].start_index,
            self.color_grade_job_contexts[0].end_index,
            &self.color_grade_profile,
        );

        parent_job.complete();
        parent_job.wait();

        self.recordRenderPassTiming(config.POST_COLOR_PROFILE_NAME, pass_start);
    }

    fn drawBitmap(self: *Renderer) void {
        if (self.hdc) |hdc| {
            if (self.hdc_mem) |hdc_mem| {
                const old_bitmap = SelectObject(hdc_mem, self.bitmap.hbitmap);
                defer _ = SelectObject(hdc_mem, old_bitmap);
                if (self.show_render_overlay or self.hybrid_shadow_debug.enabled) {
                    self.drawRenderPassOverlay(hdc_mem);
                }

                const window_w = @as(i32, @intCast(config.WINDOW_WIDTH));
                const window_h = @as(i32, @intCast(config.WINDOW_HEIGHT));
                if (window_w != self.bitmap.width or window_h != self.bitmap.height) {
                    _ = StretchBlt(
                        hdc,
                        0,
                        0,
                        window_w,
                        window_h,
                        hdc_mem,
                        0,
                        0,
                        self.bitmap.width,
                        self.bitmap.height,
                        SRCCOPY,
                    );
                } else {
                    _ = BitBlt(
                        hdc,
                        0,
                        0,
                        self.bitmap.width,
                        self.bitmap.height,
                        hdc_mem,
                        0,
                        0,
                        SRCCOPY,
                    );
                }
            }
        }
    }

    fn drawRenderPassOverlay(self: *Renderer, hdc_mem: windows.HDC) void {
        if (self.render_pass_count == 0 and !self.hybrid_shadow_debug.enabled and self.hybrid_shadow_stats.job_count == 0) return;

        _ = SetBkMode(hdc_mem, TRANSPARENT);

        var y: i32 = 12;
        if (self.render_pass_count != 0) {
            self.drawOverlayTextLine(hdc_mem, 12, y, "Render Passes (1s avg ms/frame)");
            y += 20;

            var line_buffer: [160]u8 = undefined;
            for (self.render_pass_timings[0..self.render_pass_count]) |pass| {
                const line = if (pass.has_sample)
                    std.fmt.bufPrint(&line_buffer, "{s}: {d:.2} ms/frame", .{ pass.name, pass.sampled_ms_per_frame }) catch continue
                else
                    std.fmt.bufPrint(&line_buffer, "{s}: sampling...", .{pass.name}) catch continue;
                self.drawOverlayTextLine(hdc_mem, 12, y, line);
                y += 16;
            }
        }

        if (self.hybrid_shadow_debug.enabled or self.hybrid_shadow_stats.job_count != 0) {
            var line_buffer: [160]u8 = undefined;
            if (self.render_pass_count != 0) y += 8;
            self.drawOverlayTextLine(hdc_mem, 12, y, "Hybrid Shadow");
            y += 20;

            const mode_line = if (self.hybrid_shadow_debug.enabled)
                std.fmt.bufPrint(
                    &line_buffer,
                    "step mode: H toggle, N advance ({}/{} jobs)",
                    .{ self.hybrid_shadow_debug.completed_jobs, self.hybrid_shadow_stats.job_count },
                ) catch ""
            else
                std.fmt.bufPrint(&line_buffer, "jobs={} active_tiles={}", .{ self.hybrid_shadow_stats.job_count, self.hybrid_shadow_stats.active_tile_count }) catch "";
            if (mode_line.len != 0) {
                self.drawOverlayTextLine(hdc_mem, 12, y, mode_line);
                y += 16;
            }

            const stats_line = std.fmt.bufPrint(
                &line_buffer,
                "grid={} unique={} final={}",
                .{
                    self.hybrid_shadow_stats.grid_candidate_count,
                    self.hybrid_shadow_stats.unique_candidate_count,
                    self.hybrid_shadow_stats.final_candidate_count,
                },
            ) catch "";
            if (stats_line.len != 0) {
                self.drawOverlayTextLine(hdc_mem, 12, y, stats_line);
                y += 16;
            }
        }
    }

    fn drawOverlayTextLine(self: *Renderer, hdc_mem: windows.HDC, x: i32, y: i32, text: []const u8) void {
        _ = self;
        var wide_buffer: [128:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&wide_buffer, text) catch return;
        wide_buffer[len] = 0;

        _ = SetTextColor(hdc_mem, 0x00000000);
        _ = TextOutW(hdc_mem, x + 1, y + 1, &wide_buffer, @intCast(len));
        _ = SetTextColor(hdc_mem, 0x00F0F0F0);
        _ = TextOutW(hdc_mem, x, y, &wide_buffer, @intCast(len));
    }

    fn buildBlockbusterGradeProfile() ColorGradeProfile {
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
        self: *const Renderer,
        meshlet: *const Meshlet,
        camera_position: math.Vec3,
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        projection: ProjectionParams,
    ) bool {
        _ = self;
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

    /// Renders the scene using the parallel, tile-based pipeline.
    fn renderTiled(
        self: *Renderer,
        mesh: *const Mesh,
        transform: math.Mat4,
        light_dir: math.Vec3,
        pump: ?*const fn (*Renderer) bool,
        projection: ProjectionParams,
        mesh_work: *const MeshWork,
    ) !void {
        _ = mesh;
        _ = transform;
        _ = light_dir;
        const grid = self.tile_grid.?;
        const tile_buffers = self.tile_buffers.?;
        const tile_lists = self.tile_triangle_lists.?;
        const active_flags = self.active_tile_flags.?;
        const active_indices = self.active_tile_indices.?;
        BinningStage.clearTileTriangleLists(tile_lists);
        @memset(active_flags, false);
        @memset(self.scene_depth, std.math.inf(f32));
        @memset(self.scene_camera, math.Vec3.new(0.0, 0.0, 0.0));

        const triangles = mesh_work.triangleSlice();
        self.meshlet_telemetry.touched_tiles = 0;

        if (triangles.len == 0) {
            pipeline_logger.debugSub("tiled", "no triangles; bitmap cleared", .{});
            return;
        }

        if (self.job_system != null and mesh_work.*.meshlet_len != 0) {
            self.populateTilesFromMeshlets(tile_lists, mesh_work);
        } else {
            BinningStage.binTrianglesRangeToTiles(triangles, 0, triangles.len, &grid, tile_lists) catch |err| {
                pipeline_logger.errorSub("binning", "triangle binning failed: {s}", .{@errorName(err)});
            };
        }

        const tile_jobs = self.tile_jobs_buffer.?;
        const jobs = self.job_buffer.?;
        std.debug.assert(tile_jobs.len == grid.tiles.len);
        std.debug.assert(jobs.len == grid.tiles.len);
        var active_tile_count: usize = 0;
        for (tile_lists, 0..) |*tile_list, tile_idx| {
            if (tile_list.count() == 0) continue;
            active_flags[tile_idx] = true;
            active_indices[active_tile_count] = tile_idx;
            active_tile_count += 1;
        }

        for (active_indices[0..active_tile_count]) |tile_idx| {
            if (pump) |p| {
                if ((tile_idx & 7) == 0 and !p(self)) return error.RenderInterrupted;
            }
            const tile = &grid.tiles[tile_idx];
            tile_jobs[tile_idx] = TileRenderJob{
                .tile = tile,
                .tile_buffer = &tile_buffers[tile_idx],
                .tri_list = &tile_lists[tile_idx],
                .packets = triangles,
                .draw_wireframe = self.show_wireframe,
                .textures = self.textures,
                .projection = projection,
            };
        }

        if (active_tile_count == 0) {
            pipeline_logger.debugSub("tiled", "triangles binned to zero active tiles", .{});
            return;
        }

        if (self.job_system) |job_sys| {
            var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
            const main_tile_idx = active_indices[0];

            for (active_indices[1..active_tile_count]) |tile_idx| {
                jobs[tile_idx] = Job.init(
                    TileRenderJob.renderTileJob,
                    @ptrCast(&tile_jobs[tile_idx]),
                    &parent_job,
                );

                if (!job_sys.submitJobAuto(&jobs[tile_idx])) {
                    TileRenderJob.renderTileJob(@ptrCast(&tile_jobs[tile_idx]));
                }
            }

            TileRenderJob.renderTileJob(@ptrCast(&tile_jobs[main_tile_idx]));
            parent_job.complete();

            var interrupted = false;
            while (!parent_job.isComplete()) {
                if (pump) |p| {
                    if (!p(self)) interrupted = true;
                }
                std.Thread.yield() catch {};
            }
            if (interrupted) return error.RenderInterrupted;
        } else {
            for (active_indices[0..active_tile_count]) |tile_idx| {
                TileRenderJob.renderTileJob(@ptrCast(&tile_jobs[tile_idx]));
            }
        }

        // 4. Compositing: Copy the pixels from each completed tile buffer to the main screen bitmap.
        for (active_indices[0..active_tile_count]) |tile_idx| {
            const tile = &grid.tiles[tile_idx];
            TileRenderer.compositeTileToScreen(tile, &tile_buffers[tile_idx], &self.bitmap, self.scene_depth, self.scene_camera);
        }
    }

    fn populateTilesFromMeshlets(
        self: *Renderer,
        tile_lists: []BinningStage.TileTriangleList,
        mesh_work: *const MeshWork,
    ) void {
        const meshlet_count = mesh_work.*.meshlet_len;
        if (meshlet_count == 0) return;

        const contributions = self.mesh_work_cache.meshlet_contributions;
        if (contributions.len < meshlet_count) {
            meshlet_logger.errorSub(
                "contrib",
                "meshlet contribution capacity {} insufficient for packets {}",
                .{ contributions.len, meshlet_count },
            );
            return;
        }

        const triangles = mesh_work.triangleSlice();

        for (contributions[0..meshlet_count]) |contrib| {
            self.meshlet_telemetry.touched_tiles += contrib.active_count;
            for (contrib.entries.items[0..contrib.active_count]) |entry| {
                if (entry.tile_index >= tile_lists.len) {
                    meshlet_logger.errorSub(
                        "contrib",
                        "meshlet contribution tile {} outside tile list {}",
                        .{ entry.tile_index, tile_lists.len },
                    );
                    continue;
                }

                for (entry.triangles.items) |tri_idx| {
                    if (tri_idx >= triangles.len) continue;
                    tile_lists[entry.tile_index].append(tri_idx) catch |err| {
                        meshlet_logger.errorSub(
                            "contrib",
                            "failed to append triangle {} to tile {}: {s}",
                            .{ tri_idx, entry.tile_index, @errorName(err) },
                        );
                    };
                }
            }
        }
    }

    fn generateMeshWork(
        self: *Renderer,
        mesh: *const Mesh,
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        vertex_ready: []std.atomic.Value(u32),
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        projection: ProjectionParams,
        work: *MeshWork,
        light_dir: math.Vec3,
    ) !void {
        std.debug.assert(mesh.vertices.len == vertex_ready.len);
        std.debug.assert(mesh.vertices.len == projected.len);
        std.debug.assert(mesh.vertices.len == transformed_vertices.len);

        work.clear();
        const cache_ptr = &self.mesh_work_cache;
        const vertex_generation = cache_ptr.vertex_generation;

        if (mesh.vertices.len == 0 or mesh.triangles.len == 0) {
            self.meshlet_telemetry = .{};
            cache_ptr.full_vertex_cache_valid = false;
            for (projected) |*p| {
                p.* = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
            }
            return;
        }

        const mesh_vertices = mesh.vertices;

        if (mesh.meshlets.len == 0) {
            const mesh_mut: *Mesh = @constCast(mesh);
            mesh_mut.generateMeshlets(64, 126) catch |err| {
                meshlet_logger.errorSub("build", "generateMeshlets failed: {s}", .{@errorName(err)});
            };
            self.mesh_work_cache.invalidate();
        }

        if (mesh.meshlets.len == 0) {
            const reserve = mesh.triangles.len;
            try work.beginWrite(self.allocator, 0, reserve);
            var writer = MeshWorkWriter.init(work);
            for (mesh.triangles, 0..) |tri, tri_idx| {
                _ = try emitTriangleToWork(
                    &writer,
                    mesh,
                    tri_idx,
                    tri,
                    vertex_ready,
                    vertex_generation,
                    mesh_vertices,
                    self.camera_position,
                    right,
                    up,
                    forward,
                    transformed_vertices,
                    projected,
                    projection,
                    light_dir,
                    null,
                );
            }
            self.meshlet_telemetry = .{
                .emitted_triangles = work.next_triangle.load(.acquire),
            };
            cache_ptr.full_vertex_cache_valid = true;
            work.finalize(0);
            return;
        }

        const meshlets = mesh.meshlets;
        const meshlet_count = meshlets.len;
        cache_ptr.full_vertex_cache_valid = false;
        try cache_ptr.ensureMeshletVisibilityCapacity(self.allocator, meshlet_count);
        const visibility = cache_ptr.meshlet_visibility[0..meshlet_count];
        if (meshlet_count != 0) @memset(visibility, false);

        var visible_meshlet_count: usize = 0;
        var visible_triangle_budget: usize = 0;
        var visible_vertex_budget: usize = 0;

        if (self.job_system) |js| {
            if (meshlet_count != 0) {
                const job_count = (meshlet_count + MESHLETS_PER_CULL_JOB - 1) / MESHLETS_PER_CULL_JOB;
                try cache_ptr.ensureMeshletCullJobCapacity(self.allocator, job_count);
                var cull_jobs = cache_ptr.meshlet_cull_jobs[0..job_count];
                var jobs = cache_ptr.meshlet_cull_job_handles[0..job_count];
                var job_completion = cache_ptr.meshlet_cull_job_completion[0..job_count];
                @memset(job_completion, false);

                var job_idx: usize = 0;
                while (job_idx < job_count) : (job_idx += 1) {
                    const start = job_idx * MESHLETS_PER_CULL_JOB;
                    const end = @min(start + MESHLETS_PER_CULL_JOB, meshlet_count);
                    cull_jobs[job_idx] = MeshletCullJob{
                        .renderer = self,
                        .meshlets = meshlets,
                        .visibility = visibility,
                        .start_index = start,
                        .end_index = end,
                        .camera_position = self.camera_position,
                        .basis_right = right,
                        .basis_up = up,
                        .basis_forward = forward,
                        .projection = projection,
                    };
                    jobs[job_idx] = Job.init(MeshletCullJob.run, @ptrCast(&cull_jobs[job_idx]), null);
                    if (!js.submitJobAuto(&jobs[job_idx])) {
                        cull_jobs[job_idx].process();
                        job_completion[job_idx] = true;
                    }
                }

                var remaining = job_count;
                while (remaining > 0) {
                    var progress = false;
                    for (jobs, 0..) |*job_entry, idx| {
                        if (job_completion[idx]) continue;
                        if (job_entry.isComplete()) {
                            job_completion[idx] = true;
                            remaining -= 1;
                            progress = true;
                        }
                    }
                    if (!progress) std.Thread.yield() catch {};
                }
            }
        } else {
            var meshlet_idx: usize = 0;
            while (meshlet_idx < meshlet_count) : (meshlet_idx += 1) {
                const meshlet_ptr = &meshlets[meshlet_idx];
                const visible = self.meshletVisible(meshlet_ptr, self.camera_position, right, up, forward, projection);
                visibility[meshlet_idx] = visible;
            }
        }

        visible_meshlet_count = 0;
        visible_triangle_budget = 0;
        visible_vertex_budget = 0;
        var visibility_index: usize = 0;
        while (visibility_index < meshlet_count) : (visibility_index += 1) {
            if (!visibility[visibility_index]) continue;
            visible_meshlet_count += 1;
            visible_triangle_budget += meshlets[visibility_index].primitive_count;
            visible_vertex_budget += meshlets[visibility_index].vertex_count;
        }

        if (visible_triangle_budget == 0) {
            self.meshlet_telemetry = .{
                .total_meshlets = meshlet_count,
                .visible_meshlets = visible_meshlet_count,
                .culled_meshlets = meshlet_count - visible_meshlet_count,
            };
            work.clear();
            return;
        }

        var visible_indices: []usize = &[_]usize{};
        var meshlet_offsets: []usize = &[_]usize{};
        var meshlet_vertex_offsets: []usize = &[_]usize{};
        if (visible_meshlet_count > 0) {
            try cache_ptr.ensureVisibleMeshletCapacity(self.allocator, visible_meshlet_count);
            try cache_ptr.ensureMeshletLocalScratchCapacity(self.allocator, visible_vertex_budget);
            visible_indices = cache_ptr.visible_meshlet_indices[0..visible_meshlet_count];
            meshlet_offsets = cache_ptr.visible_meshlet_offsets[0..visible_meshlet_count];
            meshlet_vertex_offsets = cache_ptr.visible_meshlet_vertex_offsets[0..visible_meshlet_count];

            var fill: usize = 0;
            var running_triangles: usize = 0;
            var running_vertices: usize = 0;
            var idx: usize = 0;
            while (idx < meshlet_count) : (idx += 1) {
                if (!visibility[idx]) continue;
                visible_indices[fill] = idx;
                meshlet_offsets[fill] = running_triangles;
                meshlet_vertex_offsets[fill] = running_vertices;
                running_triangles += meshlets[idx].primitive_count;
                running_vertices += meshlets[idx].vertex_count;
                fill += 1;
            }
            if (fill != visible_meshlet_count) {
                meshlet_logger.errorSub(
                    "visibility",
                    "visible meshlet fill mismatch fill={} expected={}",
                    .{ fill, visible_meshlet_count },
                );
            }
            if (running_triangles != visible_triangle_budget) {
                meshlet_logger.errorSub(
                    "visibility",
                    "triangle budget mismatch running={} expected={}",
                    .{ running_triangles, visible_triangle_budget },
                );
            }
            if (running_vertices != visible_vertex_budget) {
                meshlet_logger.errorSub(
                    "visibility",
                    "vertex budget mismatch running={} expected={}",
                    .{ running_vertices, visible_vertex_budget },
                );
            }
        }

        try work.beginWrite(self.allocator, visible_meshlet_count, visible_triangle_budget);

        if (visible_meshlet_count > 0) {
            for (visible_indices, 0..) |meshlet_index, packet_idx| {
                const triangle_start = meshlet_offsets[packet_idx];
                const triangle_count = meshlets[meshlet_index].primitive_count;
                work.meshlet_packets[packet_idx] = MeshletPacket{
                    .triangle_start = triangle_start,
                    .triangle_count = triangle_count,
                    .meshlet_index = meshlet_index,
                };
            }
        }

        if (self.job_system) |js| {
            if (visible_meshlet_count == 0) {
                work.finalize(0);
                return;
            }
            try cache_ptr.ensureMeshletJobCapacity(self.allocator, visible_meshlet_count);
            var meshlet_jobs = cache_ptr.meshlet_jobs[0..visible_meshlet_count];
            var jobs = cache_ptr.meshlet_job_handles[0..visible_meshlet_count];
            var job_completion = cache_ptr.meshlet_job_completion[0..visible_meshlet_count];
            var contributions = cache_ptr.meshlet_contributions[0..visible_meshlet_count];
            @memset(job_completion, false);
            for (contributions) |*contrib| contrib.clear();

            var job_idx: usize = 0;
            while (job_idx < visible_meshlet_count) : (job_idx += 1) {
                const meshlet_index = visible_indices[job_idx];
                if (meshlet_index >= meshlet_count) {
                    meshlet_logger.errorSub(
                        "dispatch",
                        "visible meshlet index {} out of range (count {})",
                        .{ meshlet_index, meshlet_count },
                    );
                    continue;
                }
                const meshlet_ptr = &meshlets[meshlet_index];
                meshlet_jobs[job_idx] = MeshletRenderJob{
                    .mesh = mesh,
                    .meshlet = meshlet_ptr,
                    .mesh_work = work,
                    .local_projected_vertices = cache_ptr.meshlet_local_projected_scratch[meshlet_vertex_offsets[job_idx] .. meshlet_vertex_offsets[job_idx] + meshlet_ptr.vertex_count],
                    .local_camera_vertices = cache_ptr.meshlet_local_camera_scratch[meshlet_vertex_offsets[job_idx] .. meshlet_vertex_offsets[job_idx] + meshlet_ptr.vertex_count],
                    .camera_position = self.camera_position,
                    .basis_right = right,
                    .basis_up = up,
                    .basis_forward = forward,
                    .projection = projection,
                    .light_dir = light_dir,
                    .output_start = meshlet_offsets[job_idx],
                    .written_count = 0,
                    .grid = if (self.tile_grid) |*grid_ref| grid_ref else null,
                    .contribution = &contributions[job_idx],
                };
                jobs[job_idx] = Job.init(MeshletRenderJob.run, @ptrCast(&meshlet_jobs[job_idx]), null);
                if (!js.submitJobAuto(&jobs[job_idx])) {
                    meshlet_logger.errorSub("dispatch", "meshlet job {} failed to submit", .{job_idx});
                    meshlet_jobs[job_idx].process();
                    job_completion[job_idx] = true;
                }
            }

            var remaining = visible_meshlet_count;
            while (remaining > 0) {
                var progress = false;
                for (jobs, 0..) |*job_entry, idx| {
                    if (job_completion[idx]) continue;
                    if (job_entry.isComplete()) {
                        job_completion[idx] = true;
                        remaining -= 1;
                        progress = true;
                    }
                }
                if (!progress) std.Thread.yield() catch {};
            }

            var packed_offset: usize = 0;
            for (meshlet_jobs[0..visible_meshlet_count], 0..) |job_info, idx| {
                const original_start = meshlet_offsets[idx];
                const count = job_info.written_count;
                if (count != 0 and original_start != packed_offset) {
                    const src = work.triangles[original_start .. original_start + count];
                    const dest = work.triangles[packed_offset .. packed_offset + count];
                    std.mem.copyForwards(TrianglePacket, dest, src);
                }
                contributions[idx].remapRange(original_start, count, packed_offset);
                work.meshlet_packets[idx].triangle_start = packed_offset;
                work.meshlet_packets[idx].triangle_count = count;
                packed_offset += count;
            }

            work.next_triangle.store(packed_offset, .release);
        } else {
            var writer = MeshWorkWriter.init(work);
            var cursor: usize = 0;
            var visible_idx: usize = 0;
            while (visible_idx < visible_meshlet_count) : (visible_idx += 1) {
                const meshlet_index = visible_indices[visible_idx];
                if (meshlet_index >= meshlet_count) {
                    meshlet_logger.errorSub(
                        "dispatch",
                        "sequential meshlet index {} out of range (count {})",
                        .{ meshlet_index, meshlet_count },
                    );
                    continue;
                }
                const meshlet_ptr = &meshlets[meshlet_index];
                const local_vertex_start = meshlet_vertex_offsets[visible_idx];
                const local_camera_vertices = cache_ptr.meshlet_local_camera_scratch[local_vertex_start .. local_vertex_start + meshlet_ptr.vertex_count];
                const local_projected_vertices = cache_ptr.meshlet_local_projected_scratch[local_vertex_start .. local_vertex_start + meshlet_ptr.vertex_count];
                const meshlet_vertices = mesh.meshletVertexSlice(meshlet_ptr);

                for (meshlet_vertices, 0..) |global_vertex_idx, local_idx| {
                    const vertex = mesh_vertices[global_vertex_idx];
                    const relative = math.Vec3.sub(vertex, self.camera_position);
                    const camera_space = math.Vec3.new(
                        math.Vec3.dot(relative, right),
                        math.Vec3.dot(relative, up),
                        math.Vec3.dot(relative, forward),
                    );
                    local_camera_vertices[local_idx] = camera_space;

                    if (camera_space.z <= NEAR_CLIP) {
                        local_projected_vertices[local_idx] = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
                    } else {
                        const inv_z = 1.0 / camera_space.z;
                        const ndc_x = camera_space.x * inv_z * projection.x_scale;
                        const ndc_y = camera_space.y * inv_z * projection.y_scale;
                        const screen_x = ndc_x * projection.center_x + projection.center_x;
                        const screen_y = -ndc_y * projection.center_y + projection.center_y;
                        local_projected_vertices[local_idx] = .{
                            @as(i32, @intFromFloat(screen_x)),
                            @as(i32, @intFromFloat(screen_y)),
                        };
                    }
                }

                for (mesh.meshletPrimitiveSlice(meshlet_ptr)) |primitive| {
                    const tri_idx = primitive.triangle_index;
                    const tri = mesh.triangles[tri_idx];
                    _ = emitMeshletPrimitiveToWork(
                        &writer,
                        mesh,
                        tri_idx,
                        tri,
                        primitive,
                        local_camera_vertices,
                        local_projected_vertices,
                        right,
                        up,
                        forward,
                        projection,
                        light_dir,
                        &cursor,
                    ) catch |err| {
                        meshlet_logger.errorSub("emit", "meshlet emit failed: {s}", .{@errorName(err)});
                        continue;
                    };
                }
            }

            work.next_triangle.store(cursor, .release);
        }

        self.meshlet_telemetry = .{
            .total_meshlets = meshlet_count,
            .visible_meshlets = visible_meshlet_count,
            .culled_meshlets = meshlet_count - visible_meshlet_count,
            .emitted_triangles = work.next_triangle.load(.acquire),
            .touched_tiles = self.meshlet_telemetry.touched_tiles,
        };
        work.finalize(visible_meshlet_count);
    }

    fn renderDirect(
        self: *Renderer,
        mesh: *const Mesh,
        transform: math.Mat4,
        light_dir: math.Vec3,
        projection: ProjectionParams,
        mesh_work: *const MeshWork,
    ) !void {
        _ = self;
        _ = mesh;
        _ = transform;
        _ = light_dir;
        _ = projection;
        _ = mesh_work;
    }

    fn drawShadedTriangle(self: *Renderer, p0: [2]i32, p1: [2]i32, p2: [2]i32, shading: TileRenderer.ShadingParams) void {
        _ = self;
        _ = p0;
        _ = p1;
        _ = p2;
        _ = shading;
    }

    fn drawLineColored(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        _ = self;
        _ = x0;
        _ = y0;
        _ = x1;
        _ = y1;
        _ = color;
    }
};
