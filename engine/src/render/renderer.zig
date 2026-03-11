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
const cpu_features = @import("../core/cpu_features.zig");
const shadow_system = @import("core/shadow_system.zig");
const profiler = @import("../core/profiler.zig");
const builtin = @import("builtin");
const windows = std.os.windows;
const math = @import("../core/math.zig");
const MeshModule = @import("core/mesh.zig");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;
const config = @import("../core/app_config.zig");
const input = @import("../platform/input.zig");
const skybox_pass = @import("passes/skybox_pass.zig");
const color_grade_pass = @import("passes/color_grade_pass.zig");
const chromatic_aberration_pass = @import("passes/chromatic_aberration_pass.zig");
const lens_flare_pass = @import("passes/lens_flare_pass.zig");
const film_grain_vignette_pass = @import("passes/film_grain_vignette_pass.zig");
const god_rays_pass = @import("passes/god_rays_pass.zig");
const depth_of_field_pass = @import("passes/depth_of_field_pass.zig");
const motion_blur_pass = @import("passes/motion_blur_pass.zig");
const ssgi_pass = @import("passes/ssgi_pass.zig");
const ssr_pass = @import("passes/ssr_pass.zig");
const ssao_pass = @import("passes/ssao_pass.zig");
const ssao_rows = @import("passes/ssao_rows.zig");
const bloom_pass = @import("passes/bloom_pass.zig");
const bloom_rows = @import("passes/bloom_rows.zig");
const taa_pass = @import("passes/taa_pass.zig");
const taa_helpers = @import("passes/taa_helpers.zig");
const taa_meshlet_batch = @import("passes/taa_meshlet_batch.zig");
const shadow_map_pass = @import("passes/shadow_map_pass.zig");
const shadow_resolve_pass = @import("passes/shadow_resolve_pass.zig");
const hybrid_shadow_pass = @import("passes/hybrid_shadow_pass.zig");
const adaptive_shadow_tile_pass = @import("passes/adaptive_shadow_tile_pass.zig");
const pass_registry = @import("pipeline/pass_registry.zig");
const pass_graph = @import("pipeline/pass_graph.zig");
const render_utils = @import("core/utils.zig");
const shadow_raster_kernel = @import("kernels/shadow_raster_kernel.zig");
const shadow_sample_kernel = @import("kernels/shadow_sample_kernel.zig");
const hybrid_shadow_cache_kernel = @import("kernels/hybrid_shadow_cache_kernel.zig");
const hybrid_shadow_resolve_kernel = @import("kernels/hybrid_shadow_resolve_kernel.zig");
const bloom_blur_h_kernel = @import("kernels/bloom_blur_h_kernel.zig");
const bloom_blur_v_kernel = @import("kernels/bloom_blur_v_kernel.zig");
const lighting_pass = @import("passes/lighting_pass.zig");
const depth_fog_pass = @import("passes/depth_fog_pass.zig");
const scanline = @import("core/scanline.zig");
const texture = @import("../assets/texture.zig");
const WorkTypes = @import("core/mesh_work_types.zig");
const TrianglePacket = WorkTypes.TrianglePacket;
const TriangleFlags = WorkTypes.TriangleFlags;
const MeshletPacket = WorkTypes.MeshletPacket;
const log = @import("../core/log.zig");
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

    pub fn project(self: CameraToLightTransform, camera_pos: math.Vec3) LightSpaceSample {
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

const max_render_passes = 32;

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
    history_surface_tags: []u64,
    history_normals: []u32,
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

const SSGIJobContext = struct {
    renderer: *Renderer,
    scene_pixels: []u32,
    scratch_pixels: []u32,
    scene_camera: []const math.Vec3,
    start_row: usize,
    end_row: usize,

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *SSGIJobContext = @ptrCast(@alignCast(ctx_ptr));
        const width: usize = @intCast(ctx.renderer.bitmap.width);
        const height: usize = @intCast(ctx.renderer.bitmap.height);
        ssgi_pass.runRows(ctx.scene_pixels, ctx.scratch_pixels, ctx.scene_camera, width, height, ctx.start_row, ctx.end_row);
    }
};

const SSRJobContext = struct {
    renderer: *Renderer,
    scene_pixels: []u32,
    scratch_pixels: []u32,
    scene_camera: []math.Vec3,
    scene_normal: []math.Vec3,
    scene_depth: []f32,
    width: usize,
    height: usize,
    start_row: usize,
    end_row: usize,
    projection: ProjectionParams,
    max_samples: i32,
    step_size: f32,
    max_distance: f32,
    thickness: f32,
    intensity: f32,

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *SSRJobContext = @ptrCast(@alignCast(ctx_ptr));
        ssr_pass.runRows(
            ctx.scene_pixels,
            ctx.scratch_pixels,
            ctx.scene_camera,
            ctx.scene_depth,
            ctx.width,
            ctx.height,
            ctx.start_row,
            ctx.end_row,
            ctx.projection,
            ctx.max_samples,
            ctx.step_size,
            ctx.max_distance,
            ctx.thickness,
            ctx.intensity,
        );
    }
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

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *DepthOfFieldJobContext = @ptrCast(@alignCast(ctx_ptr));
        depth_of_field_pass.runRows(
            ctx.scene_pixels,
            ctx.scratch_pixels,
            ctx.scene_depth,
            ctx.width,
            ctx.height,
            ctx.start_row,
            ctx.end_row,
            ctx.focal_distance,
            ctx.focal_range,
            ctx.max_blur_radius,
        );
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

const DerivedFrameViewState = struct {
    right: math.Vec3,
    up: math.Vec3,
    forward: math.Vec3,
    view_rotation: math.Mat4,
    light_camera: math.Vec3,
    light_dir_camera: math.Vec3,
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    cache_projection: ProjectionParams,
};

const FrameViewCache = struct {
    valid: bool = false,
    camera_position: math.Vec3 = math.Vec3.new(0.0, 0.0, 0.0),
    rotation_angle: f32 = 0.0,
    rotation_x: f32 = 0.0,
    camera_fov_deg: f32 = 0.0,
    bitmap_width: i32 = 0,
    bitmap_height: i32 = 0,
    light_dir_world: math.Vec3 = math.Vec3.new(0.0, -1.0, 0.0),
    light_distance: f32 = 0.0,
    state: DerivedFrameViewState = undefined,

    fn invalidate(self: *FrameViewCache) void {
        self.valid = false;
    }

    fn needsUpdate(
        self: *const FrameViewCache,
        camera_position: math.Vec3,
        rotation_angle: f32,
        rotation_x: f32,
        camera_fov_deg: f32,
        bitmap_width: i32,
        bitmap_height: i32,
        light_dir_world: math.Vec3,
        light_distance: f32,
    ) bool {
        const epsilon: f32 = 1e-5;
        if (!self.valid) return true;
        if (!approxEqFrameVec3(self.camera_position, camera_position, epsilon)) return true;
        if (!approxEqFrameF32(self.rotation_angle, rotation_angle, epsilon)) return true;
        if (!approxEqFrameF32(self.rotation_x, rotation_x, epsilon)) return true;
        if (!approxEqFrameF32(self.camera_fov_deg, camera_fov_deg, epsilon)) return true;
        if (self.bitmap_width != bitmap_width or self.bitmap_height != bitmap_height) return true;
        if (!approxEqFrameVec3(self.light_dir_world, light_dir_world, epsilon)) return true;
        if (!approxEqFrameF32(self.light_distance, light_distance, epsilon)) return true;
        return false;
    }

    fn update(
        self: *FrameViewCache,
        camera_position: math.Vec3,
        rotation_angle: f32,
        rotation_x: f32,
        camera_fov_deg: f32,
        bitmap_width: i32,
        bitmap_height: i32,
        light_dir_world: math.Vec3,
        light_distance: f32,
    ) DerivedFrameViewState {
        const yaw = rotation_angle;
        const pitch = rotation_x;
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

        const light_pos_world = math.Vec3.scale(light_dir_world, light_distance);
        const light_relative = math.Vec3.sub(light_pos_world, camera_position);
        const light_camera = math.Vec3.new(
            math.Vec3.dot(light_relative, right),
            math.Vec3.dot(light_relative, up),
            math.Vec3.dot(light_relative, forward),
        );
        const light_dir_camera = math.Vec3.normalize(math.Vec3.new(
            math.Vec3.dot(light_dir_world, right),
            math.Vec3.dot(light_dir_world, up),
            math.Vec3.dot(light_dir_world, forward),
        ));

        const width_f = @as(f32, @floatFromInt(bitmap_width));
        const height_f = @as(f32, @floatFromInt(bitmap_height));
        const aspect_ratio = if (height_f > 0.0) width_f / height_f else 1.0;
        const fov_rad = camera_fov_deg * (std.math.pi / 180.0);
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

        self.camera_position = camera_position;
        self.rotation_angle = rotation_angle;
        self.rotation_x = rotation_x;
        self.camera_fov_deg = camera_fov_deg;
        self.bitmap_width = bitmap_width;
        self.bitmap_height = bitmap_height;
        self.light_dir_world = light_dir_world;
        self.light_distance = light_distance;
        self.state = .{
            .right = right,
            .up = up,
            .forward = forward,
            .view_rotation = view_rotation,
            .light_camera = light_camera,
            .light_dir_camera = light_dir_camera,
            .center_x = center_x,
            .center_y = center_y,
            .x_scale = x_scale,
            .y_scale = y_scale,
            .cache_projection = cache_projection,
        };
        self.valid = true;
        return self.state;
    }
};

fn approxEqFrameF32(a: f32, b: f32, epsilon: f32) bool {
    return @abs(a - b) <= epsilon;
}

fn approxEqFrameVec3(a: math.Vec3, b: math.Vec3, epsilon: f32) bool {
    return approxEqFrameF32(a.x, b.x, epsilon) and approxEqFrameF32(a.y, b.y, epsilon) and approxEqFrameF32(a.z, b.z, epsilon);
}

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


const fastScale255 = render_utils.fastScale255;

fn averageBlur5(sum: i32) u8 {
    return @intCast(@divTrunc(sum + 2, 5));
}

fn validSceneCameraSample(camera_pos: math.Vec3) bool {
    return render_utils.validSceneCameraSample(camera_pos, NEAR_CLIP);
}

const sampleSceneCameraClamped = render_utils.sampleSceneCameraClamped;

fn estimateSceneNormal(scene_camera: []const math.Vec3, width: usize, height: usize, center: math.Vec3, x: i32, y: i32, step: i32) math.Vec3 {
    return render_utils.estimateSceneNormal(scene_camera, width, height, center, x, y, step, NEAR_CLIP);
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

const chooseShadowBasis = render_utils.chooseShadowBasis;


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


const darkenPackedColor = render_utils.darkenPackedColor;

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
        pixels[i] = render_utils.darkenPackedColor(pixels[i], scale);
    }
}

const cameraToWorldPosition = render_utils.cameraToWorldPosition;

const taa_jitter_sequence = [_]math.Vec2{
    .{ .x = 0.25, .y = -0.16666666 },
    .{ .x = -0.25, .y = 0.16666666 },
    .{ .x = 0.25, .y = -0.38888888 },
    .{ .x = -0.375, .y = -0.05555555 },
    .{ .x = 0.125, .y = 0.27777777 },
    .{ .x = -0.125, .y = -0.27777777 },
    .{ .x = 0.375, .y = 0.05555555 },
    .{ .x = -0.4375, .y = 0.38888888 },
};

const invalid_surface_tag: u64 = taa_helpers.invalid_surface_tag;

const ReprojectedHistorySample = struct {
    screen: math.Vec2,
    depth: f32,
    used_surface_path: bool,
};

fn taaJitterForFrame(frame_index: u64) math.Vec2 {
    const sample = taa_jitter_sequence[@as(usize, @intCast(frame_index % taa_jitter_sequence.len))];
    return .{
        .x = sample.x * 0.15,
        .y = sample.y * 0.35,
    };
}

fn projectCameraPositionFloat(position: math.Vec3, projection: ProjectionParams) math.Vec2 {
    return render_utils.projectCameraPositionFloat(position, projection, NEAR_EPSILON);
}


fn addPackedColorBatchSimd(
    comptime lanes: usize,
    current_pixels: *const [lanes]u32,
    add_r_arr: *const [lanes]f32,
    add_g_arr: *const [lanes]f32,
    add_b_arr: *const [lanes]f32,
) [lanes]u32 {
    const FloatVec = @Vector(lanes, f32);
    const IntVec = @Vector(lanes, i32);

    var alpha: [lanes]u32 = undefined;
    var current_r_arr: [lanes]f32 = undefined;
    var current_g_arr: [lanes]f32 = undefined;
    var current_b_arr: [lanes]f32 = undefined;

    inline for (0..lanes) |lane| {
        const pixel = current_pixels[lane];
        alpha[lane] = pixel & 0xFF000000;
        current_r_arr[lane] = @floatFromInt((pixel >> 16) & 0xFF);
        current_g_arr[lane] = @floatFromInt((pixel >> 8) & 0xFF);
        current_b_arr[lane] = @floatFromInt(pixel & 0xFF);
    }

    const max_channel: FloatVec = @as(FloatVec, @splat(255.0));
    const min_channel: FloatVec = @as(FloatVec, @splat(0.0));
    const out_r_vec = @max(min_channel, @min(max_channel, @as(FloatVec, @bitCast(current_r_arr)) + @as(FloatVec, @bitCast(add_r_arr.*))));
    const out_g_vec = @max(min_channel, @min(max_channel, @as(FloatVec, @bitCast(current_g_arr)) + @as(FloatVec, @bitCast(add_g_arr.*))));
    const out_b_vec = @max(min_channel, @min(max_channel, @as(FloatVec, @bitCast(current_b_arr)) + @as(FloatVec, @bitCast(add_b_arr.*))));

    const out_r: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(out_r_vec)));
    const out_g: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(out_g_vec)));
    const out_b: [lanes]i32 = @bitCast(@as(IntVec, @intFromFloat(out_b_vec)));

    var result: [lanes]u32 = undefined;
    inline for (0..lanes) |lane| {
        result[lane] = alpha[lane] |
            (@as(u32, clampByte(out_r[lane])) << 16) |
            (@as(u32, clampByte(out_g[lane])) << 8) |
            @as(u32, clampByte(out_b[lane]));
    }
    return result;
}

fn addPackedColorBatch(
    current_pixels: []const u32,
    add_r_arr: []const f32,
    add_g_arr: []const f32,
    add_b_arr: []const f32,
    output: []u32,
) void {
    std.debug.assert(current_pixels.len == add_r_arr.len);
    std.debug.assert(current_pixels.len == add_g_arr.len);
    std.debug.assert(current_pixels.len == add_b_arr.len);
    std.debug.assert(output.len >= current_pixels.len);

    switch (current_pixels.len) {
        0 => {},
        1 => {
            const pixel = current_pixels[0];
            const alpha = pixel & 0xFF000000;
            const r = @as(i32, @intFromFloat(@max(0.0, @min(255.0, @as(f32, @floatFromInt((pixel >> 16) & 0xFF)) + add_r_arr[0]))));
            const g = @as(i32, @intFromFloat(@max(0.0, @min(255.0, @as(f32, @floatFromInt((pixel >> 8) & 0xFF)) + add_g_arr[0]))));
            const b = @as(i32, @intFromFloat(@max(0.0, @min(255.0, @as(f32, @floatFromInt(pixel & 0xFF)) + add_b_arr[0]))));
            output[0] = alpha |
                (@as(u32, clampByte(r)) << 16) |
                (@as(u32, clampByte(g)) << 8) |
                @as(u32, clampByte(b));
        },
        8 => {
            const result = addPackedColorBatchSimd(8, @ptrCast(current_pixels.ptr), @ptrCast(add_r_arr.ptr), @ptrCast(add_g_arr.ptr), @ptrCast(add_b_arr.ptr));
            const out_ptr: *[8]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        16 => {
            const result = addPackedColorBatchSimd(16, @ptrCast(current_pixels.ptr), @ptrCast(add_r_arr.ptr), @ptrCast(add_g_arr.ptr), @ptrCast(add_b_arr.ptr));
            const out_ptr: *[16]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        32 => {
            const result = addPackedColorBatchSimd(32, @ptrCast(current_pixels.ptr), @ptrCast(add_r_arr.ptr), @ptrCast(add_g_arr.ptr), @ptrCast(add_b_arr.ptr));
            const out_ptr: *[32]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        else => unreachable,
    }
}

fn packShiftedColorBatchSimd(
    comptime lanes: usize,
    alpha: *const [lanes]u32,
    r_arr: *const [lanes]u32,
    g_arr: *const [lanes]u32,
    b_arr: *const [lanes]u32,
) [lanes]u32 {
    var result: [lanes]u32 = undefined;
    inline for (0..lanes) |lane| {
        result[lane] = alpha[lane] |
            (r_arr[lane] << 16) |
            (g_arr[lane] << 8) |
            b_arr[lane];
    }
    return result;
}

fn packShiftedColorBatch(
    alpha: []const u32,
    r_arr: []const u32,
    g_arr: []const u32,
    b_arr: []const u32,
    output: []u32,
) void {
    std.debug.assert(alpha.len == r_arr.len);
    std.debug.assert(alpha.len == g_arr.len);
    std.debug.assert(alpha.len == b_arr.len);
    std.debug.assert(output.len >= alpha.len);

    switch (alpha.len) {
        0 => {},
        1 => output[0] = alpha[0] | (r_arr[0] << 16) | (g_arr[0] << 8) | b_arr[0],
        8 => {
            const result = packShiftedColorBatchSimd(8, @ptrCast(alpha.ptr), @ptrCast(r_arr.ptr), @ptrCast(g_arr.ptr), @ptrCast(b_arr.ptr));
            const out_ptr: *[8]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        16 => {
            const result = packShiftedColorBatchSimd(16, @ptrCast(alpha.ptr), @ptrCast(r_arr.ptr), @ptrCast(g_arr.ptr), @ptrCast(b_arr.ptr));
            const out_ptr: *[16]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        32 => {
            const result = packShiftedColorBatchSimd(32, @ptrCast(alpha.ptr), @ptrCast(r_arr.ptr), @ptrCast(g_arr.ptr), @ptrCast(b_arr.ptr));
            const out_ptr: *[32]u32 = @ptrCast(output.ptr);
            out_ptr.* = result;
        },
        else => unreachable,
    }
}


fn tryApplyTemporalAAMeshletBatch(
    self: *Renderer,
    mesh: *const Mesh,
    current_view: TemporalAAViewState,
    previous_view: TemporalAAViewState,
    row_start: usize,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
) bool {
    return taa_meshlet_batch.tryApply(
        self,
        mesh,
        current_view,
        previous_view,
        row_start,
        x,
        y,
        width,
        height,
        runtimeColorGradeSimdLanes(),
        max_runtime_color_grade_simd_lanes,
        validSceneCameraSample,
        cameraToWorldPosition,
        projectCameraPositionFloat,
        NEAR_EPSILON,
    );
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
    ssao_rows.renderRows(scene_camera, scene_width, scene_height, ao, config_value, start_row, end_row);
}

fn blurAmbientOcclusionHorizontalRows(ao: *AOScratch, depth_threshold: f32, start_row: usize, end_row: usize) void {
    ssao_rows.blurHorizontalRows(ao, depth_threshold, start_row, end_row);
}

fn blurAmbientOcclusionVerticalRows(ao: *AOScratch, depth_threshold: f32, start_row: usize, end_row: usize) void {
    ssao_rows.blurVerticalRows(ao, depth_threshold, start_row, end_row);
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
    ssao_rows.compositeRows(dst, scene_camera, dst_width, dst_height, ao, start_row, end_row);
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

const max_runtime_color_grade_simd_lanes = 32;

const runtimeColorGradeSimdLanes = render_utils.runtimeColorGradeSimdLanes;

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
extern "dwmapi" fn DwmFlush() callconv(.winapi) windows.HRESULT;

// ========== MODULE IMPORTS ==========
const Bitmap = @import("../assets/bitmap.zig").Bitmap;
const TileRenderer = @import("core/tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("core/binning_stage.zig");
const job_system_module = @import("../core/job_system.zig");
const JobSystem = job_system_module.JobSystem;
const Job = job_system_module.Job;

const ColorGradeJobContext = struct {
    pixels: []u32,
    start_index: usize,
    end_index: usize,
    profile: *const ColorGradeProfile,

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *ColorGradeJobContext = @ptrCast(@alignCast(ctx_ptr));
        color_grade_pass.runRange(ctx.pixels, ctx.start_index, ctx.end_index, ctx.profile);
    }
};

const FogJobContext = struct {
    pixels: []u32,
    depth: []const f32,
    width: usize,
    start_row: usize,
    end_row: usize,
    config: DepthFogConfig,

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *FogJobContext = @ptrCast(@alignCast(ctx_ptr));
        depth_fog_pass.runRows(ctx.pixels, ctx.depth, ctx.width, ctx.start_row, ctx.end_row, ctx.config);
    }
};

const ShadowLightDispatchContext = struct {
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
    shadow_elapsed_ns: i128,
};

const HybridShadowDispatchContext = struct {
    renderer: *Renderer,
    mesh: *const Mesh,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    light_dir_world: math.Vec3,
};

const CompositionPlan = struct {
    enabled_mask: pass_registry.PassMask,
    uses_scratch_a: bool = false,
    uses_scratch_b: bool = false,
    uses_history: bool = false,
    scratch_pool_a: []u32 = &[_]u32{},
    scratch_pool_b: []u32 = &[_]u32{},
    scene_mask: pass_registry.PassMask = 0,
    geometry_post_mask: pass_registry.PassMask = 0,
    lighting_scatter_mask: pass_registry.PassMask = 0,
    final_color_mask: pass_registry.PassMask = 0,
};

const CompositionScratchBindings = struct {
    ssgi_scratch_pixels: []u32,
    ssr_scratch_pixels: []u32,
    moblur_scratch_pixels: []u32,
    god_rays_scratch_pixels: []u32,
    lens_flare_scratch_pixels: []u32,
};

const PostPassExecutionContext = struct {
    renderer: *Renderer,
    mesh: *const Mesh,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    current_view: TemporalAAViewState,
    projection: ProjectionParams,
    light_dir_world: math.Vec3,
    shadow_elapsed_ns: i128,
    plan: CompositionPlan,
};

const AOJobContext = ssao_pass.JobContext(
    Renderer,
    renderAmbientOcclusionRows,
    blurAmbientOcclusionHorizontalRows,
    blurAmbientOcclusionVerticalRows,
    compositeAmbientOcclusionRows,
);

const TAAJobContext = struct {
    renderer: *Renderer,
    mesh: *const Mesh,
    current_view: TemporalAAViewState,
    previous_view: TemporalAAViewState,
    start_row: usize,
    end_row: usize,
    width: usize,
    height: usize,

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *TAAJobContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.applyTemporalAARows(
            ctx.mesh,
            ctx.current_view,
            ctx.previous_view,
            ctx.start_row,
            ctx.end_row,
            ctx.width,
            ctx.height,
        );
    }
};

const ShadowResolveJobContext = shadow_resolve_pass.JobContext(ShadowResolveConfig, ShadowMap);

const ShadowRasterJobContext = shadow_map_pass.RasterJobContext(Mesh, ShadowMap);

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

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *AdaptiveShadowTileJob = @ptrCast(@alignCast(ctx_ptr));
        adaptive_shadow_tile_pass.run(ctx);
    }
};

const BloomJobContext = bloom_pass.JobContext(BloomScratch);

fn noopRenderPassJob(ctx: *anyopaque) void {
    _ = ctx;
}

const clampByte = render_utils.clampByte;

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
    hdc_mem_old_bitmap: ?HGDIOBJ,
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
    sys_shadows: shadow_system.ShadowSystem,

    // Input and timing state
    keys_pressed: u32, // Bitmask of currently pressed keys.
    camera_fov_deg: f32,
    frame_count: u32,
    total_frames_rendered: u64,
    last_time: i128,
    last_frame_time: i128,
    next_frame_time: i128,
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
    frame_view_cache: FrameViewCache = .{},

    // Rendering options and data
    single_texture_binding: [1]?*const texture.Texture,
    hdri_map: ?texture.HdrTexture = null,
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
    scene_normal: []math.Vec3,
    scene_surface: []TileRenderer.SurfaceHandle,
    scene_buffers_initialized: bool = false,
    taa_scratch: TemporalAAScratch,
    taa_previous_view: TemporalAAViewState,
    taa_previous_mesh_vertices: []math.Vec3,
    taa_previous_mesh_vertex_count: usize,
    taa_previous_mesh_triangle_count: usize,
    taa_previous_mesh_valid: bool,
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
    skybox_job_contexts: []SkyboxJobContext,
    shadow_resolve_job_contexts: []ShadowResolveJobContext,
    shadow_raster_job_contexts: []ShadowRasterJobContext,
    bloom_job_contexts: []BloomJobContext,
    dof_scratch: DepthOfFieldScratch,
    ssr_job_contexts: []SSRJobContext,
    ssr_scratch_pixels: []u32,
    ssgi_scratch_pixels: []u32,
    ssgi_job_contexts: []SSGIJobContext,
    dof_job_contexts: []DepthOfFieldJobContext,
    dof_focal_distance: f32,
    dof_target_focal_distance: f32,
    taa_job_contexts: []TAAJobContext,
    color_grade_job_contexts: []ColorGradeJobContext,
    moblur_job_contexts: []MotionBlurJobContext,
    moblur_scratch_pixels: []u32,
    god_rays_job_contexts: []GodRaysJobContext,
    god_rays_scratch_pixels: []u32,
    chromatic_aberration_job_contexts: []ChromaticAberrationJobContext,
    film_grain_job_contexts: []FilmGrainVignetteJobContext,
    lens_flare_job_contexts: []LensFlareJobContext,
    lens_flare_scratch_pixels: []u32,
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
        const hdc_mem_old_bitmap = SelectObject(hdc_mem, bitmap.hbitmap);
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
        const moblur_job_contexts = try allocator.alloc(MotionBlurJobContext, color_grade_job_count);
        errdefer allocator.free(moblur_job_contexts);
        const moblur_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(moblur_scratch_pixels);

        const god_rays_job_contexts = try allocator.alloc(GodRaysJobContext, color_grade_job_count);
        errdefer allocator.free(god_rays_job_contexts);
        const god_rays_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(god_rays_scratch_pixels);

        const chromatic_aberration_job_contexts = try allocator.alloc(ChromaticAberrationJobContext, color_grade_job_count);
        errdefer allocator.free(chromatic_aberration_job_contexts);

        const film_grain_job_contexts = try allocator.alloc(FilmGrainVignetteJobContext, color_grade_job_count);
        errdefer allocator.free(film_grain_job_contexts);

        const lens_flare_job_contexts = try allocator.alloc(LensFlareJobContext, color_grade_job_count);
        errdefer allocator.free(lens_flare_job_contexts);
        const lens_flare_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(lens_flare_scratch_pixels);
        const ao_job_contexts = try allocator.alloc(AOJobContext, color_grade_job_count);
        errdefer allocator.free(ao_job_contexts);
        const fog_job_contexts = try allocator.alloc(FogJobContext, color_grade_job_count);
        errdefer allocator.free(fog_job_contexts);
        const skybox_job_contexts = try allocator.alloc(SkyboxJobContext, color_grade_job_count);
        errdefer allocator.free(skybox_job_contexts);
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
        const ssr_scratch_pixels = try allocator.alloc(u32, fb_pix_count);
        errdefer allocator.free(ssr_scratch_pixels);
        const ssgi_scratch_pixels = try allocator.alloc(u32, fb_pix_count);
        errdefer allocator.free(ssgi_scratch_pixels);
        const ssgi_job_contexts = try allocator.alloc(SSGIJobContext, color_grade_job_count);
        errdefer allocator.free(ssgi_job_contexts);
        const dof_job_contexts = try allocator.alloc(DepthOfFieldJobContext, color_grade_job_count);
        const ssr_job_contexts = try allocator.alloc(SSRJobContext, color_grade_job_count);
        errdefer allocator.free(ssr_job_contexts);
        errdefer allocator.free(dof_job_contexts);
        const color_grade_jobs = try allocator.alloc(Job, color_grade_job_count);
        errdefer allocator.free(color_grade_jobs);
        const scene_depth = try allocator.alloc(f32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_depth);
        const scene_camera = try allocator.alloc(math.Vec3, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_camera);
        const scene_normal = try allocator.alloc(math.Vec3, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_normal);
        const scene_surface = try allocator.alloc(TileRenderer.SurfaceHandle, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_surface);
        const taa_history_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_pixels);
        const taa_resolve_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_resolve_pixels);
        const taa_history_depth = try allocator.alloc(f32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_depth);
        const taa_history_surface_tags = try allocator.alloc(u64, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_surface_tags);
        const taa_history_normals = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_normals);
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
            try lights.append(allocator, LightInfo{ .orbit_x = @as(f32, @floatFromInt(light_idx)) * 3.14159, .orbit_speed = 0.0, .distance = config.LIGHT_DISTANCE_INITIAL, .elevation = 0.65, .color = if (light_idx == 0) math.Vec3.new(1.0, 0.9, 0.8) else math.Vec3.new(0.5, 0.6, 1.0), .shadow_map = .{
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
            .hdc_mem_old_bitmap = hdc_mem_old_bitmap,
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
            .sys_shadows = shadow_system.ShadowSystem.init(allocator),
            .camera_fov_deg = config.CAMERA_FOV_INITIAL,
            .keys_pressed = 0,
            .frame_count = 0,
            .total_frames_rendered = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .next_frame_time = current_time,
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
            .scene_normal = scene_normal,
            .scene_surface = scene_surface,
            .taa_scratch = .{
                .history_pixels = taa_history_pixels,
                .resolve_pixels = taa_resolve_pixels,
                .history_depth = taa_history_depth,
                .history_surface_tags = taa_history_surface_tags,
                .history_normals = taa_history_normals,
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
            .taa_previous_mesh_vertices = &[_]math.Vec3{},
            .taa_previous_mesh_vertex_count = 0,
            .taa_previous_mesh_triangle_count = 0,
            .taa_previous_mesh_valid = false,
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
            .bloom_threshold_curve = bloom_pass.buildThresholdCurve(config.POST_BLOOM_THRESHOLD),
            .bloom_intensity_lut = bloom_pass.buildIntensityLut(config.POST_BLOOM_INTENSITY_PERCENT),
            .fog_job_contexts = fog_job_contexts,
            .skybox_job_contexts = skybox_job_contexts,
            .shadow_resolve_job_contexts = shadow_resolve_job_contexts,
            .shadow_raster_job_contexts = shadow_raster_job_contexts,
            .bloom_job_contexts = bloom_job_contexts,
            .dof_scratch = .{ .pixels = dof_scratch_pixels, .width = @intCast(width), .height = @intCast(height) },
            .dof_job_contexts = dof_job_contexts,
            .ssr_job_contexts = ssr_job_contexts,
            .ssr_scratch_pixels = ssr_scratch_pixels,
            .ssgi_scratch_pixels = ssgi_scratch_pixels,
            .ssgi_job_contexts = ssgi_job_contexts,
            .dof_focal_distance = config.POST_DOF_FOCAL_DISTANCE,
            .dof_target_focal_distance = config.POST_DOF_FOCAL_DISTANCE,
            .taa_job_contexts = taa_job_contexts,
            .color_grade_job_contexts = color_grade_job_contexts,
            .moblur_job_contexts = moblur_job_contexts,
            .moblur_scratch_pixels = moblur_scratch_pixels,
            .god_rays_job_contexts = god_rays_job_contexts,
            .god_rays_scratch_pixels = god_rays_scratch_pixels,
            .chromatic_aberration_job_contexts = chromatic_aberration_job_contexts,
            .film_grain_job_contexts = film_grain_job_contexts,
            .lens_flare_job_contexts = lens_flare_job_contexts,
            .lens_flare_scratch_pixels = lens_flare_scratch_pixels,
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
        self.sys_shadows.deinit();
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
        self.allocator.free(self.scene_normal);
        self.allocator.free(self.scene_surface);
        self.allocator.free(self.taa_scratch.history_pixels);
        self.allocator.free(self.taa_scratch.resolve_pixels);
        self.allocator.free(self.taa_scratch.history_depth);
        self.allocator.free(self.taa_scratch.history_surface_tags);
        self.allocator.free(self.taa_scratch.history_normals);
        if (self.taa_previous_mesh_vertices.len != 0) self.allocator.free(self.taa_previous_mesh_vertices);
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
        self.allocator.free(self.skybox_job_contexts);
        self.allocator.free(self.shadow_resolve_job_contexts);
        self.allocator.free(self.shadow_raster_job_contexts);
        self.allocator.free(self.bloom_job_contexts);
        self.allocator.free(self.dof_scratch.pixels);
        self.allocator.free(self.ssr_scratch_pixels);
        self.allocator.free(self.ssgi_scratch_pixels);
        self.allocator.free(self.ssgi_job_contexts);
        self.allocator.free(self.ssr_job_contexts);
        self.allocator.free(self.dof_job_contexts);
        self.allocator.free(self.taa_job_contexts);
        self.allocator.free(self.color_grade_job_contexts);
        self.allocator.free(self.moblur_job_contexts);
        self.allocator.free(self.moblur_scratch_pixels);
        self.allocator.free(self.god_rays_job_contexts);
        self.allocator.free(self.god_rays_scratch_pixels);
        self.allocator.free(self.chromatic_aberration_job_contexts);
        self.allocator.free(self.film_grain_job_contexts);
        self.allocator.free(self.lens_flare_job_contexts);
        self.allocator.free(self.lens_flare_scratch_pixels);
        self.allocator.free(self.color_grade_jobs);
        if (self.hdri_map) |*m| m.deinit();
        if (self.tile_buffers) |buffers| {
            for (buffers) |*buf| buf.deinit();
            self.allocator.free(buffers);
        }
        if (self.tile_grid) |*grid| grid.deinit();
        self.bitmap.deinit();
        if (self.hdc_mem) |hdc_mem| {
            if (self.hdc_mem_old_bitmap) |old_bitmap| {
                _ = SelectObject(hdc_mem, old_bitmap);
            }
            _ = DeleteDC(hdc_mem);
        }
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
        sys_shadows: ?*shadow_system.ShadowSystem,
        light_direction: math.Vec3,
        mesh_ptr: *const Mesh,
        cam_pos: math.Vec3,
        cam_right: math.Vec3,
        cam_up: math.Vec3,
        cam_fwd: math.Vec3,

        const max_clipped_vertices: usize = 5;
        const wire_color: u32 = 0xFFFFFFFF;

        const ClipVertex = struct {
            position: math.Vec3,
            uv: math.Vec2,
            normal: math.Vec3,
            surface_bary: math.Vec3,
        };

        fn interpolateClipVertex(a: ClipVertex, b: ClipVertex, near_plane: f32) ClipVertex {
            const denom = b.position.z - a.position.z;
            const t_raw = if (@abs(denom) < 1e-6) 0.0 else (near_plane - a.position.z) / denom;
            const t = std.math.clamp(t_raw, 0.0, 1.0);
            const direction = math.Vec3.sub(b.position, a.position);
            const position = math.Vec3.add(a.position, math.Vec3.scale(direction, t));
            const uv_delta = math.Vec2.sub(b.uv, a.uv);
            const uv = math.Vec2.add(a.uv, math.Vec2.scale(uv_delta, t));
            const normal_delta = math.Vec3.sub(b.normal, a.normal);
            const normal = math.Vec3.normalize(math.Vec3.add(a.normal, math.Vec3.scale(normal_delta, t)));
            const bary_delta = math.Vec3.sub(b.surface_bary, a.surface_bary);
            const surface_bary = math.Vec3.add(a.surface_bary, math.Vec3.scale(bary_delta, t));
            return ClipVertex{ .position = position, .uv = uv, .normal = normal, .surface_bary = surface_bary };
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

        fn projectToScreen(self: *const TileRenderJob, position: math.Vec3) math.Vec2 {
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
                .x = screen_x,
                .y = screen_y,
            };
        }

        fn isDegenerate(p0: math.Vec2, p1: math.Vec2, p2: math.Vec2) bool {
            const ax = p1.x - p0.x;
            const ay = p1.y - p0.y;
            const bx = p2.x - p0.x;
            const by = p2.y - p0.y;
            const cross = ax * by - ay * bx;
            return @abs(cross) < 0.5;
        }

        fn rasterizeFan(job: *TileRenderJob, vertices: []ClipVertex, base_color: u32, texture_index: u16, intensity: f32, triangle_id: usize, meshlet_id: usize) void {
            if (vertices.len < 3) return;

            var screen_pts: [max_clipped_vertices]math.Vec2 = undefined;
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
                    .surface_bary0 = vertices[0].surface_bary,
                    .surface_bary1 = vertices[tri_idx].surface_bary,
                    .surface_bary2 = vertices[tri_idx + 1].surface_bary,
                    .triangle_id = triangle_id,
                    .meshlet_id = meshlet_id,
                    .normals = [3]math.Vec3{ vertices[0].normal, vertices[tri_idx].normal, vertices[tri_idx + 1].normal },
                    .metallic = 0.0,
                    .roughness = 1.0,
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
            const _z_renderTileJob = profiler.zone("renderTileJob");
            defer if (_z_renderTileJob) |z| z.end();
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
                    ClipVertex{ .position = camera_positions[0], .uv = packet.uv[0], .normal = packet.normals[0], .surface_bary = math.Vec3.new(1.0, 0.0, 0.0) },
                    ClipVertex{ .position = camera_positions[1], .uv = packet.uv[1], .normal = packet.normals[1], .surface_bary = math.Vec3.new(0.0, 1.0, 0.0) },
                    ClipVertex{ .position = camera_positions[2], .uv = packet.uv[2], .normal = packet.normals[2], .surface_bary = math.Vec3.new(0.0, 0.0, 1.0) },
                };

                var clipped: [max_clipped_vertices]ClipVertex = undefined;
                const clipped_count = clipPolygonToNearPlane(clip_input[0..], near_plane, &clipped);
                if (clipped_count < 3) continue;

                rasterizeFan(job, clipped[0..clipped_count], packet.base_color, packet.texture_index, packet.intensity, packet.triangle_id, packet.meshlet_id);

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

        fn applyMeshletShadows(ctx: *anyopaque) void {
            const job: *TileRenderJob = @ptrCast(@alignCast(ctx));
            if (job.sys_shadows) |sys| {
                const _z_meshletShadowTile = profiler.zone("meshletShadowTile");
                defer if (_z_meshletShadowTile) |z| z.end();
                const total_pixels = @as(usize, @intCast(job.tile.width)) * @as(usize, @intCast(job.tile.height));
                var packet = shadow_system.RayPacket{
                    .origins_x = undefined,
                    .origins_y = undefined,
                    .origins_z = undefined,
                    .dirs_x = undefined,
                    .dirs_y = undefined,
                    .dirs_z = undefined,
                    .shared_dir = undefined,
                    .shared_inv_dir = undefined,
                    .skip_triangle_ids = undefined,
                    .active_mask = 0,
                    .occluded_mask = 0,
                };

                const ray_dir = math.Vec3.normalize(job.light_direction);
                const ray_inv_dir = math.Vec3.new(
                    if (@abs(ray_dir.x) < 1e-6) (if (ray_dir.x < 0.0) @as(f32, -1e6) else @as(f32, 1e6)) else 1.0 / ray_dir.x,
                    if (@abs(ray_dir.y) < 1e-6) (if (ray_dir.y < 0.0) @as(f32, -1e6) else @as(f32, 1e6)) else 1.0 / ray_dir.y,
                    if (@abs(ray_dir.z) < 1e-6) (if (ray_dir.z < 0.0) @as(f32, -1e6) else @as(f32, 1e6)) else 1.0 / ray_dir.z,
                );
                const light_dir_camera = math.Vec3.normalize(math.Vec3.new(
                    math.Vec3.dot(ray_dir, job.cam_right),
                    math.Vec3.dot(ray_dir, job.cam_up),
                    math.Vec3.dot(ray_dir, job.cam_fwd),
                ));

                var pixel_idx: usize = 0;
                while (pixel_idx < total_pixels) {
                    packet.active_mask = 0;
                    packet.occluded_mask = 0;
                    packet.shared_dir = ray_dir;
                    packet.shared_inv_dir = ray_inv_dir;

                    const batch_size = @min(64, total_pixels - pixel_idx);
                    for (0..batch_size) |i| {
                        const idx = pixel_idx + i;
                        const depth = job.tile_buffer.depth[idx];
                        if (depth < std.math.inf(f32) and depth > 0.0) {
                            const normal_camera = job.tile_buffer.data[idx].normal;
                            if (math.Vec3.dot(normal_camera, light_dir_camera) <= 0.0) continue;

                            const cs_pos = job.tile_buffer.data[idx].camera;
                            const xs = math.Vec3.scale(job.cam_right, cs_pos.x);
                            const ys = math.Vec3.scale(job.cam_up, cs_pos.y);
                            const zs = math.Vec3.scale(job.cam_fwd, cs_pos.z);
                            const ws_relative = math.Vec3.add(xs, math.Vec3.add(ys, zs));
                            const world_pos = math.Vec3.add(job.cam_pos, ws_relative);
                            const world_normal = math.Vec3.normalize(math.Vec3.add(
                                math.Vec3.scale(job.cam_right, normal_camera.x),
                                math.Vec3.add(
                                    math.Vec3.scale(job.cam_up, normal_camera.y),
                                    math.Vec3.scale(job.cam_fwd, normal_camera.z),
                                ),
                            ));
                            const origin_bias = math.Vec3.add(
                                math.Vec3.scale(world_normal, 0.02),
                                math.Vec3.scale(ray_dir, 0.005),
                            );
                            const surface = job.tile_buffer.data[idx].surface;

                            packet.origins_x[i] = world_pos.x + origin_bias.x;
                            packet.origins_y[i] = world_pos.y + origin_bias.y;
                            packet.origins_z[i] = world_pos.z + origin_bias.z;

                            packet.dirs_x[i] = ray_dir.x;
                            packet.dirs_y[i] = ray_dir.y;
                            packet.dirs_z[i] = ray_dir.z;
                            packet.skip_triangle_ids[i] = if (surface.isValid()) surface.triangle_id else TileRenderer.invalid_surface_id;

                            packet.active_mask |= (@as(u64, 1) << @intCast(i));
                        }
                    }

                    if (packet.active_mask != 0) {
                        {
                            const _z_meshletShadowTrace = profiler.zone("meshletShadowTrace");
                            defer if (_z_meshletShadowTrace) |z| z.end();
                            _ = job.mesh_ptr;
                            sys.tracePacketAnyHit(&packet);
                        }

                        if (packet.occluded_mask != 0) {
                            const _z_meshletShadowApply = profiler.zone("meshletShadowApply");
                            defer if (_z_meshletShadowApply) |z| z.end();
                            for (0..batch_size) |i| {
                                if ((packet.occluded_mask & (@as(u64, 1) << @intCast(i))) != 0) {
                                    const idx = pixel_idx + i;
                                    var color = job.tile_buffer.data[idx].color;
                                    color.x *= 0.2;
                                    color.y *= 0.2;
                                    color.z *= 0.2;
                                    job.tile_buffer.data[idx].color = color;
                                }
                            }
                        }
                    }

                    pixel_idx += batch_size;
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
        meshlet_idx: usize,
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
        const intensity = lighting_pass.computeIntensity(brightness);

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
            meshlet_idx,
            screen0,
            screen1,
            screen2,
            p0_cam,
            p1_cam,
            p2_cam,
            [3]math.Vec3{ normal_cam, normal_cam, normal_cam },
            uv,
            0.0, // metallic
            1.0, // roughness
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
        meshlet_idx: usize,
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
            meshlet_idx,
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
        meshlet_idx: usize,
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
            meshlet_idx,
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

    const max_meshlet_vertex_transform_lanes = 16;

    fn runtimeMeshletVertexTransformLanes() usize {
        return switch (cpu_features.detect().preferredVectorBackend()) {
            .avx512 => 16,
            .avx2 => 8,
            .sse2, .neon => 4,
            .scalar => 1,
        };
    }

    fn transformMeshletVerticesBatchSimd(
        comptime lanes: usize,
        mesh_vertices: []const math.Vec3,
        meshlet_vertices: *const [lanes]usize,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
        local_camera_vertices: *[lanes]math.Vec3,
        local_projected_vertices: *[lanes][2]i32,
    ) void {
        const FloatVec = @Vector(lanes, f32);

        var vertex_x_arr: [lanes]f32 = undefined;
        var vertex_y_arr: [lanes]f32 = undefined;
        var vertex_z_arr: [lanes]f32 = undefined;

        inline for (0..lanes) |lane| {
            const vertex = mesh_vertices[meshlet_vertices[lane]];
            vertex_x_arr[lane] = vertex.x;
            vertex_y_arr[lane] = vertex.y;
            vertex_z_arr[lane] = vertex.z;
        }

        const relative_x = @as(FloatVec, @bitCast(vertex_x_arr)) - @as(FloatVec, @splat(camera_position.x));
        const relative_y = @as(FloatVec, @bitCast(vertex_y_arr)) - @as(FloatVec, @splat(camera_position.y));
        const relative_z = @as(FloatVec, @bitCast(vertex_z_arr)) - @as(FloatVec, @splat(camera_position.z));

        const camera_x_arr: [lanes]f32 = @bitCast(relative_x * @as(FloatVec, @splat(basis_right.x)) + relative_y * @as(FloatVec, @splat(basis_right.y)) + relative_z * @as(FloatVec, @splat(basis_right.z)));
        const camera_y_arr: [lanes]f32 = @bitCast(relative_x * @as(FloatVec, @splat(basis_up.x)) + relative_y * @as(FloatVec, @splat(basis_up.y)) + relative_z * @as(FloatVec, @splat(basis_up.z)));
        const camera_z_arr: [lanes]f32 = @bitCast(relative_x * @as(FloatVec, @splat(basis_forward.x)) + relative_y * @as(FloatVec, @splat(basis_forward.y)) + relative_z * @as(FloatVec, @splat(basis_forward.z)));

        inline for (0..lanes) |lane| {
            const camera_space = math.Vec3.new(camera_x_arr[lane], camera_y_arr[lane], camera_z_arr[lane]);
            local_camera_vertices[lane] = camera_space;

            if (camera_space.z <= NEAR_CLIP) {
                local_projected_vertices[lane] = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
            } else {
                const inv_z = 1.0 / camera_space.z;
                const ndc_x = camera_space.x * inv_z * projection.x_scale;
                const ndc_y = camera_space.y * inv_z * projection.y_scale;
                const screen_x = ndc_x * projection.center_x + projection.center_x;
                const screen_y = -ndc_y * projection.center_y + projection.center_y;
                local_projected_vertices[lane] = .{
                    @as(i32, @intFromFloat(screen_x)),
                    @as(i32, @intFromFloat(screen_y)),
                };
            }
        }
    }

    fn transformMeshletVertices(
        mesh_vertices: []const math.Vec3,
        meshlet_vertices: []const usize,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
        local_camera_vertices: []math.Vec3,
        local_projected_vertices: [][2]i32,
    ) void {
        std.debug.assert(meshlet_vertices.len == local_camera_vertices.len);
        std.debug.assert(meshlet_vertices.len == local_projected_vertices.len);

        const lanes = runtimeMeshletVertexTransformLanes();
        var index: usize = 0;
        while (index + lanes <= meshlet_vertices.len) : (index += lanes) {
            switch (lanes) {
                16 => {
                    var camera_batch: [16]math.Vec3 = undefined;
                    var projected_batch: [16][2]i32 = undefined;
                    transformMeshletVerticesBatchSimd(16, mesh_vertices, @ptrCast(meshlet_vertices[index..][0..16]), camera_position, basis_right, basis_up, basis_forward, projection, &camera_batch, &projected_batch);
                    const camera_out: *[16]math.Vec3 = @ptrCast(local_camera_vertices[index..][0..16]);
                    const projected_out: *[16][2]i32 = @ptrCast(local_projected_vertices[index..][0..16]);
                    camera_out.* = camera_batch;
                    projected_out.* = projected_batch;
                },
                8 => {
                    var camera_batch: [8]math.Vec3 = undefined;
                    var projected_batch: [8][2]i32 = undefined;
                    transformMeshletVerticesBatchSimd(8, mesh_vertices, @ptrCast(meshlet_vertices[index..][0..8]), camera_position, basis_right, basis_up, basis_forward, projection, &camera_batch, &projected_batch);
                    const camera_out: *[8]math.Vec3 = @ptrCast(local_camera_vertices[index..][0..8]);
                    const projected_out: *[8][2]i32 = @ptrCast(local_projected_vertices[index..][0..8]);
                    camera_out.* = camera_batch;
                    projected_out.* = projected_batch;
                },
                4 => {
                    var camera_batch: [4]math.Vec3 = undefined;
                    var projected_batch: [4][2]i32 = undefined;
                    transformMeshletVerticesBatchSimd(4, mesh_vertices, @ptrCast(meshlet_vertices[index..][0..4]), camera_position, basis_right, basis_up, basis_forward, projection, &camera_batch, &projected_batch);
                    const camera_out: *[4]math.Vec3 = @ptrCast(local_camera_vertices[index..][0..4]);
                    const projected_out: *[4][2]i32 = @ptrCast(local_projected_vertices[index..][0..4]);
                    camera_out.* = camera_batch;
                    projected_out.* = projected_batch;
                },
                else => unreachable,
            }
        }

        while (index < meshlet_vertices.len) : (index += 1) {
            const vertex = mesh_vertices[meshlet_vertices[index]];
            const relative = math.Vec3.sub(vertex, camera_position);
            const camera_space = math.Vec3.new(
                math.Vec3.dot(relative, basis_right),
                math.Vec3.dot(relative, basis_up),
                math.Vec3.dot(relative, basis_forward),
            );
            local_camera_vertices[index] = camera_space;

            if (camera_space.z <= NEAR_CLIP) {
                local_projected_vertices[index] = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
            } else {
                const inv_z = 1.0 / camera_space.z;
                const ndc_x = camera_space.x * inv_z * projection.x_scale;
                const ndc_y = camera_space.y * inv_z * projection.y_scale;
                const screen_x = ndc_x * projection.center_x + projection.center_x;
                const screen_y = -ndc_y * projection.center_y + projection.center_y;
                local_projected_vertices[index] = .{
                    @as(i32, @intFromFloat(screen_x)),
                    @as(i32, @intFromFloat(screen_y)),
                };
            }
        }
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
        meshlet_index: usize,
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
            transformMeshletVertices(mesh_vertices, meshlet_vertices, job.camera_position, job.basis_right, job.basis_up, job.basis_forward, job.projection, job.local_camera_vertices, job.local_projected_vertices);

            var cursor = job.output_start;
            for (job.mesh.meshletPrimitiveSlice(job.meshlet)) |primitive| {
                const tri_idx = primitive.triangle_index;
                const tri = job.mesh.triangles[tri_idx];
                const result = emitMeshletPrimitiveToWork(
                    &writer,
                    job.mesh,
                    tri_idx,
                    job.meshlet_index,
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
            meshlet_idx: usize,
            screen0: [2]i32,
            screen1: [2]i32,
            screen2: [2]i32,
            p0: math.Vec3,
            p1: math.Vec3,
            p2: math.Vec3,
            normals: [3]math.Vec3,
            uv: [3]math.Vec2,
            metallic: f32,
            roughness: f32,
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
                .normals = normals,
                .uv = uv,
                .metallic = metallic,
                .roughness = roughness,
                .base_color = base_color,
                .texture_index = texture_index,
                .intensity = intensity,
                .flags = flags,
                .triangle_id = tri_idx,
                .meshlet_id = meshlet_idx,
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

    pub fn invalidateMeshWork(self: *Renderer) void {
        self.mesh_work_cache.invalidate();
        self.frame_view_cache.invalidate();
        self.sys_shadows.invalidateBLAS();
    }

    fn ensureTemporalMeshVertexCapacity(self: *Renderer, vertex_count: usize) !void {
        if (self.taa_previous_mesh_vertices.len == vertex_count) return;
        if (self.taa_previous_mesh_vertices.len != 0) self.allocator.free(self.taa_previous_mesh_vertices);
        self.taa_previous_mesh_vertices = if (vertex_count == 0)
            &[_]math.Vec3{}
        else
            try self.allocator.alloc(math.Vec3, vertex_count);
        self.taa_previous_mesh_vertex_count = 0;
        self.taa_previous_mesh_triangle_count = 0;
        self.taa_previous_mesh_valid = false;
    }

    pub fn captureTemporalMeshState(self: *Renderer, mesh: *const Mesh) void {
        if (self.taa_previous_mesh_vertices.len < mesh.vertices.len) {
            self.taa_previous_mesh_valid = false;
            return;
        }
        if (mesh.vertices.len != 0) {
            @memcpy(self.taa_previous_mesh_vertices[0..mesh.vertices.len], mesh.vertices);
        }
        self.taa_previous_mesh_vertex_count = mesh.vertices.len;
        self.taa_previous_mesh_triangle_count = mesh.triangles.len;
        self.taa_previous_mesh_valid = true;
    }

    fn consumeMouseDelta(self: *Renderer) math.Vec2 {
        const delta = self.pending_mouse_delta;
        self.pending_mouse_delta = math.Vec2.new(0.0, 0.0);
        return delta;
    }

    pub fn shouldRenderFrame(self: *Renderer) bool {
        if (self.target_frame_time_ns <= 0) return true;
        const now = std.time.nanoTimestamp();
        return now >= self.next_frame_time;
    }

    pub fn waitUntilNextFrame(self: *Renderer) void {
        if (self.target_frame_time_ns <= 0) return;

        while (true) {
            const now = std.time.nanoTimestamp();
            const remaining_ns = self.next_frame_time - now;
            if (remaining_ns <= 0) return;

            if (remaining_ns > 2_000_000) {
                const sleep_ns = remaining_ns - 500_000;
                const sleep_ms = @max(@as(i128, 1), @divTrunc(sleep_ns, 1_000_000));
                Sleep(@intCast(sleep_ms));
                continue;
            }

            if (remaining_ns > 250_000) {
                std.Thread.yield() catch {};
                continue;
            }

            std.atomic.spinLoopHint();
        }
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

    pub fn setHdriMap(self: *Renderer, hdri_map: texture.HdrTexture) void {
        self.hdri_map = hdri_map;
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
        if (self.total_frames_rendered == self.profile_capture_frame and profiler.Profiler.instance.?.active) {
            profiler.Profiler.stopCaptureAndSave("profile.json") catch {};
        }
        if (self.total_frames_rendered + 1 == self.profile_capture_frame) {
            profiler.Profiler.startCapture();
        }
        const _zone = profiler.zone("Renderer.render");
        defer if (_zone) |z| z.end();

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

        const frame_view = if (self.frame_view_cache.needsUpdate(
            self.camera_position,
            self.rotation_angle,
            self.rotation_x,
            self.camera_fov_deg,
            self.bitmap.width,
            self.bitmap.height,
            light_dir_world,
            light_distance_0,
        ))
            self.frame_view_cache.update(
                self.camera_position,
                self.rotation_angle,
                self.rotation_x,
                self.camera_fov_deg,
                self.bitmap.width,
                self.bitmap.height,
                light_dir_world,
                light_distance_0,
            )
        else
            self.frame_view_cache.state;

        const right = frame_view.right;
        const up = frame_view.up;
        const forward = frame_view.forward;
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

        const resolved_frame_view = if (self.frame_view_cache.needsUpdate(
            self.camera_position,
            self.rotation_angle,
            self.rotation_x,
            self.camera_fov_deg,
            self.bitmap.width,
            self.bitmap.height,
            light_dir_world,
            light_distance_0,
        ))
            self.frame_view_cache.update(
                self.camera_position,
                self.rotation_angle,
                self.rotation_x,
                self.camera_fov_deg,
                self.bitmap.width,
                self.bitmap.height,
                light_dir_world,
                light_distance_0,
            )
        else
            self.frame_view_cache.state;

        const view_rotation = resolved_frame_view.view_rotation;
        const light_camera = resolved_frame_view.light_camera;
        const light_dir = resolved_frame_view.light_dir_camera;
        const center_x = resolved_frame_view.center_x;
        const center_y = resolved_frame_view.center_y;
        const x_scale = resolved_frame_view.x_scale;
        const y_scale = resolved_frame_view.y_scale;
        const cache_projection = resolved_frame_view.cache_projection;
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
        if (config.POST_TAA_ENABLED) try self.ensureTemporalMeshVertexCapacity(mesh.vertices.len);

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

        if (config.MESHLET_SHADOWS_ENABLED and mesh.meshlets.len > 0) {
            _ = try self.sys_shadows.ensureBLAS(mesh);
            var instances = [_]math.Mat4{math.Mat4.identity()};
            try self.sys_shadows.ensureTLAS(&instances);
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
            const shadow_pass_elapsed_ns = try self.renderTiled(mesh, view_rotation, light_dir, pump, raster_projection, mesh_work);
            const scene_pass_elapsed_ns = std.time.nanoTimestamp() - scene_pass_start;
            self.recordRenderPassDuration("meshlet_tiled", scene_pass_elapsed_ns - @as(i128, @intCast(shadow_pass_elapsed_ns)));
            if (config.MESHLET_SHADOWS_ENABLED) {
                self.recordRenderPassDuration("meshlet_shadows", @as(i128, @intCast(shadow_pass_elapsed_ns)));
            }
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
        if (self.target_frame_time_ns > 0) {
            self.next_frame_time = current_time + self.target_frame_time_ns;
        }

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

    pub fn recordRenderPassTiming(self: *Renderer, name: []const u8, start_ns: i128) void {
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        self.recordRenderPassDuration(name, elapsed_ns);
    }

    fn computeStripeCount(max_jobs: usize, row_count: usize) usize {
        if (row_count == 0 or max_jobs == 0) return 0;
        const desired = @max(@as(usize, 1), (row_count + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job);
        return @min(max_jobs, desired);
    }

    pub fn recordRenderPassDuration(self: *Renderer, name: []const u8, elapsed_ns: i128) void {
        if (self.render_pass_count >= self.render_pass_timings.len) return;
        const elapsed_ms = render_utils.nanosecondsToMs(elapsed_ns);
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

    fn renderPassSortMetric(pass: RenderPassTiming) f32 {
        return if (pass.has_sample) pass.sampled_ms_per_frame else pass.frame_duration_ms;
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
        return shadow_map_pass.runBuild(
            self,
            mesh,
            light_dir_world,
            target_shadow_map,
            config.POST_SHADOW_ENABLED,
            config.POST_SHADOW_DEPTH_BIAS,
            chooseShadowBasis,
            computeStripeCount,
            noopRenderPassJob,
        );
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
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
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
        shadow_map_pass.runPipeline(
            self,
            width,
            height,
            resolve_config,
            target_shadow_map,
            pass_index,
            build_elapsed_ns,
            noopRenderPassJob,
        );
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
        const _z_applyAdaptiveShadowPass = profiler.zone("applyAdaptiveShadowPass");
        defer if (_z_applyAdaptiveShadowPass) |z| z.end();
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
        hybrid_shadow_pass.runPipeline(
            self,
            mesh,
            grid,
            active_flags,
            active_indices,
            shadow_jobs,
            tile_ranges,
            jobs,
            camera_position,
            basis_right,
            basis_up,
            basis_forward,
            normalized_light_dir,
            light_basis.right,
            light_basis.up,
            camera_to_light,
            darkness_scale,
            pass_start,
            shadow_rebuild_dot_threshold,
            noopRenderPassJob,
        );
    }

    const SkyboxJobContext = skybox_pass.JobContext(Renderer, ProjectionParams, texture.HdrTexture);

    fn applySkyboxPass(
        self: *Renderer,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    ) void {
        const hdri_map = self.hdri_map orelse return;
        const pass_start = std.time.nanoTimestamp();
        const height: usize = @intCast(self.bitmap.height);
        skybox_pass.runPipeline(
            self,
            basis_right,
            basis_up,
            basis_forward,
            projection,
            &hdri_map,
            height,
            noopRenderPassJob,
            skybox_pass.runJobWrapper(SkyboxJobContext),
        );
        self.recordRenderPassTiming("skybox", pass_start);
    }

    fn applyShadowLightFromPass(ctx: ShadowLightDispatchContext, pass_index: usize) void {
        const shadow_map_ptr = &ctx.renderer.lights.items[pass_index].shadow_map;
        ctx.renderer.applyShadowPass(
            ctx.camera_position,
            ctx.basis_right,
            ctx.basis_up,
            ctx.basis_forward,
            ctx.projection,
            ctx.shadow_elapsed_ns,
            shadow_map_ptr,
            pass_index,
        );
    }

    fn applyHybridShadowFromPass(ctx: HybridShadowDispatchContext) void {
        ctx.renderer.applyAdaptiveShadowPass(
            ctx.mesh,
            ctx.camera_position,
            ctx.basis_right,
            ctx.basis_up,
            ctx.basis_forward,
            ctx.light_dir_world,
        );
    }

    fn isPostPassEnabled(ctx: PostPassExecutionContext, pass_id: pass_registry.RenderPassId) bool {
        const enabled = switch (pass_id) {
            .skybox => config.POST_SKYBOX_ENABLED,
            .shadow_map => config.POST_SHADOW_ENABLED,
            .shadow_resolve => config.POST_SHADOW_ENABLED,
            .hybrid_shadow => config.POST_HYBRID_SHADOW_ENABLED,
            .ssao => config.POST_SSAO_ENABLED,
            .ssgi => config.POST_SSGI_ENABLED,
            .ssr => config.POST_SSR_ENABLED,
            .depth_fog => config.POST_DEPTH_FOG_ENABLED,
            .taa => config.POST_TAA_ENABLED,
            .motion_blur => config.POST_MOTION_BLUR_ENABLED,
            .god_rays => config.POST_GOD_RAYS_ENABLED,
            .bloom => config.POST_BLOOM_ENABLED,
            .lens_flare => config.POST_LENS_FLARE_ENABLED,
            .dof => config.POST_DOF_ENABLED,
            .chromatic_aberration => config.POST_CHROMATIC_ABERRATION_ENABLED,
            .film_grain_vignette => config.POST_FILM_GRAIN_VIGNETTE_ENABLED,
            .color_grade => config.POST_COLOR_CORRECTION_ENABLED,
        };
        if (!enabled) return false;
        if (pass_id == .motion_blur and !ctx.renderer.taa_scratch.valid) return false;
        return true;
    }

    fn onPostPassPhaseBoundary(ctx: PostPassExecutionContext, phase: pass_registry.PassPhase) void {
        _ = phase;
        _ = ctx.plan;
    }

    fn phaseMaskFor(plan: CompositionPlan, phase: pass_registry.PassPhase) pass_registry.PassMask {
        return switch (phase) {
            .scene => plan.scene_mask,
            .geometry_post => plan.geometry_post_mask,
            .lighting_scatter => plan.lighting_scatter_mask,
            .final_color => plan.final_color_mask,
        };
    }

    fn phaseTimingName(phase: pass_registry.PassPhase) []const u8 {
        return switch (phase) {
            .scene => "phase_scene",
            .geometry_post => "phase_geometry_post",
            .lighting_scatter => "phase_lighting_scatter",
            .final_color => "phase_final_color",
        };
    }

    fn snapshotScratchBindings(self: *Renderer) CompositionScratchBindings {
        return .{
            .ssgi_scratch_pixels = self.ssgi_scratch_pixels,
            .ssr_scratch_pixels = self.ssr_scratch_pixels,
            .moblur_scratch_pixels = self.moblur_scratch_pixels,
            .god_rays_scratch_pixels = self.god_rays_scratch_pixels,
            .lens_flare_scratch_pixels = self.lens_flare_scratch_pixels,
        };
    }

    fn applyCompositionScratchBindings(self: *Renderer, plan: CompositionPlan) void {
        _ = self;
        _ = plan;
    }

    fn chooseNonFrontScratch(ctx: PostPassExecutionContext) []u32 {
        const front = ctx.renderer.bitmap.pixels.ptr;
        if (ctx.plan.scratch_pool_a.len != 0 and front != ctx.plan.scratch_pool_a.ptr) return ctx.plan.scratch_pool_a;
        if (ctx.plan.scratch_pool_b.len != 0 and front != ctx.plan.scratch_pool_b.ptr) return ctx.plan.scratch_pool_b;
        return ctx.plan.scratch_pool_a;
    }

    fn bindScratchForPass(ctx: PostPassExecutionContext, pass_id: pass_registry.RenderPassId) void {
        const target = chooseNonFrontScratch(ctx);
        if (target.len == 0) return;
        switch (pass_id) {
            .ssgi => ctx.renderer.ssgi_scratch_pixels = target,
            .ssr => ctx.renderer.ssr_scratch_pixels = target,
            .motion_blur => ctx.renderer.moblur_scratch_pixels = target,
            .god_rays => ctx.renderer.god_rays_scratch_pixels = target,
            .lens_flare => ctx.renderer.lens_flare_scratch_pixels = target,
            .chromatic_aberration => ctx.renderer.moblur_scratch_pixels = target,
            else => {},
        }
    }

    fn restoreScratchBindings(self: *Renderer, saved: CompositionScratchBindings) void {
        self.ssgi_scratch_pixels = saved.ssgi_scratch_pixels;
        self.ssr_scratch_pixels = saved.ssr_scratch_pixels;
        self.moblur_scratch_pixels = saved.moblur_scratch_pixels;
        self.god_rays_scratch_pixels = saved.god_rays_scratch_pixels;
        self.lens_flare_scratch_pixels = saved.lens_flare_scratch_pixels;
    }

    fn runPostPassById(ctx: PostPassExecutionContext, pass_id: pass_registry.RenderPassId) void {
        bindScratchForPass(ctx, pass_id);
        switch (pass_id) {
            .skybox => ctx.renderer.applySkyboxPass(ctx.basis_right, ctx.basis_up, ctx.basis_forward, ctx.projection),
            .shadow_map, .shadow_resolve => {
                const shadow_ctx = ShadowLightDispatchContext{
                    .renderer = ctx.renderer,
                    .camera_position = ctx.camera_position,
                    .basis_right = ctx.basis_right,
                    .basis_up = ctx.basis_up,
                    .basis_forward = ctx.basis_forward,
                    .projection = ctx.projection,
                    .shadow_elapsed_ns = ctx.shadow_elapsed_ns,
                };
                shadow_map_pass.runPerLight(ctx.renderer.lights.items.len, shadow_ctx, applyShadowLightFromPass);
            },
            .hybrid_shadow => {
                const hybrid_ctx = HybridShadowDispatchContext{
                    .renderer = ctx.renderer,
                    .mesh = ctx.mesh,
                    .camera_position = ctx.camera_position,
                    .basis_right = ctx.basis_right,
                    .basis_up = ctx.basis_up,
                    .basis_forward = ctx.basis_forward,
                    .light_dir_world = ctx.light_dir_world,
                };
                hybrid_shadow_pass.run(hybrid_ctx, applyHybridShadowFromPass);
            },
            .ssao => ctx.renderer.applyAmbientOcclusionPass(),
            .ssgi => ctx.renderer.applySSGIPass(),
            .ssr => ctx.renderer.applySSRPass(ctx.projection),
            .depth_fog => ctx.renderer.applyDepthFogPass(),
            .taa => ctx.renderer.applyTemporalAAPass(ctx.mesh, ctx.current_view),
            .motion_blur => ctx.renderer.applyMotionBlurPass(ctx.current_view),
            .god_rays => ctx.renderer.applyGodRaysPass(ctx.projection, ctx.light_dir_world),
            .bloom => ctx.renderer.applyBloomPass(),
            .lens_flare => ctx.renderer.applyLensFlarePass(),
            .dof => ctx.renderer.applyDepthOfFieldPass(),
            .chromatic_aberration => ctx.renderer.applyChromaticAberrationPass(),
            .film_grain_vignette => ctx.renderer.applyFilmGrainVignettePass(),
            .color_grade => ctx.renderer.applyBlockbusterColorGradePass(),
        }
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
        const base_ctx = PostPassExecutionContext{
            .renderer = self,
            .mesh = mesh,
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .current_view = current_view,
            .projection = projection,
            .light_dir_world = light_dir_world,
            .shadow_elapsed_ns = shadow_elapsed_ns,
            .plan = .{ .enabled_mask = 0 },
        };
        const enabled_mask = pass_registry.buildEnabledMask(base_ctx, isPostPassEnabled);
        var plan = CompositionPlan{
            .enabled_mask = enabled_mask,
            .scratch_pool_a = self.moblur_scratch_pixels,
            .scratch_pool_b = self.ssr_scratch_pixels,
        };
        for (pass_registry.post_passes) |node| {
            if ((enabled_mask & pass_graph.passBit(node.id)) == 0) continue;
            switch (node.phase) {
                .scene => plan.scene_mask |= pass_graph.passBit(node.id),
                .geometry_post => plan.geometry_post_mask |= pass_graph.passBit(node.id),
                .lighting_scatter => plan.lighting_scatter_mask |= pass_graph.passBit(node.id),
                .final_color => plan.final_color_mask |= pass_graph.passBit(node.id),
            }
            switch (node.output_target) {
                .main => {},
                .scratch_a => plan.uses_scratch_a = true,
                .scratch_b => plan.uses_scratch_b = true,
                .history => plan.uses_history = true,
            }
        }

        const ctx = PostPassExecutionContext{
            .renderer = self,
            .mesh = mesh,
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .current_view = current_view,
            .projection = projection,
            .light_dir_world = light_dir_world,
            .shadow_elapsed_ns = shadow_elapsed_ns,
            .plan = plan,
        };
        const iface = pass_registry.PassInterface(PostPassExecutionContext){
            .is_enabled = isPostPassEnabled,
            .run = runPostPassById,
            .on_phase_boundary = onPostPassPhaseBoundary,
        };
        const saved_bindings = snapshotScratchBindings(self);
        defer restoreScratchBindings(self, saved_bindings);
        applyCompositionScratchBindings(self, plan);
        const phase_order = [_]pass_registry.PassPhase{
            .scene,
            .geometry_post,
            .lighting_scatter,
            .final_color,
        };
        for (phase_order) |phase| {
            const phase_mask = phaseMaskFor(plan, phase);
            if (phase_mask == 0) continue;
            const phase_start = std.time.nanoTimestamp();
            pass_registry.executeMaskWithInterface(ctx, phase_mask, iface);
            self.recordRenderPassDuration(phaseTimingName(phase), std.time.nanoTimestamp() - phase_start);
        }
    }

    fn applySSGIPass(self: *Renderer) void {
        const pass_start = std.time.nanoTimestamp();
        const height: usize = @intCast(self.bitmap.height);
        ssgi_pass.runPipeline(self, height, noopRenderPassJob);

        std.mem.swap([]u32, &self.bitmap.pixels, &self.ssgi_scratch_pixels);
        self.recordRenderPassTiming("ssgi", pass_start);
    }
    fn applyAmbientOcclusionPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0 or self.scene_camera.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const scene_width: usize = @intCast(self.bitmap.width);
        const scene_height: usize = @intCast(self.bitmap.height);
        ssao_pass.runPipeline(
            self,
            scene_width,
            scene_height,
            noopRenderPassJob,
            renderAmbientOcclusionRows,
            blurAmbientOcclusionHorizontalRows,
            blurAmbientOcclusionVerticalRows,
            compositeAmbientOcclusionRows,
        );
        self.recordRenderPassTiming("ssao", pass_start);
    }

    fn applyDepthFogPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0 or self.scene_depth.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        depth_fog_pass.runPipeline(self, width, height, noopRenderPassJob);
        self.recordRenderPassTiming("depth_fog", pass_start);
    }

    pub fn applyTemporalAARows(
        self: *Renderer,
        mesh: *const Mesh,
        current_view: TemporalAAViewState,
        previous_view: TemporalAAViewState,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,
    ) void {
        taa_pass.runRows(
            self,
            mesh,
            current_view,
            previous_view,
            start_row,
            end_row,
            width,
            height,
            tryApplyTemporalAAMeshletBatch,
            validSceneCameraSample,
            cameraToWorldPosition,
            projectCameraPositionFloat,
            NEAR_EPSILON,
        );
    }

    const GodRaysJobContext = struct {
        renderer: *Renderer,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,
        light_screen_pos: math.Vec2,

        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *GodRaysJobContext = @ptrCast(@alignCast(ctx_ptr));
            god_rays_pass.runRows(
                ctx.renderer.bitmap.pixels,
                ctx.renderer.god_rays_scratch_pixels,
                ctx.start_row,
                ctx.end_row,
                ctx.width,
                ctx.height,
                ctx.light_screen_pos.x,
                ctx.light_screen_pos.y,
                config.POST_GOD_RAYS_SAMPLES,
                config.POST_GOD_RAYS_DECAY,
                config.POST_GOD_RAYS_DENSITY,
                config.POST_GOD_RAYS_WEIGHT,
                config.POST_GOD_RAYS_EXPOSURE,
            );
        }
    };

    const ChromaticAberrationJobContext = struct {
        renderer: *Renderer,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,

        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *ChromaticAberrationJobContext = @ptrCast(@alignCast(ctx_ptr));
            chromatic_aberration_pass.runRows(
                ctx.renderer.bitmap.pixels,
                ctx.renderer.moblur_scratch_pixels,
                ctx.start_row,
                ctx.end_row,
                ctx.width,
                ctx.height,
                config.POST_CHROMATIC_ABERRATION_STRENGTH,
            );
        }
    };

    const FilmGrainVignetteJobContext = struct {
        renderer: *Renderer,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,

        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *FilmGrainVignetteJobContext = @ptrCast(@alignCast(ctx_ptr));
            film_grain_vignette_pass.runRows(
                ctx.renderer.bitmap.pixels,
                ctx.start_row,
                ctx.end_row,
                ctx.width,
                ctx.height,
                config.POST_FILM_GRAIN_STRENGTH,
                config.POST_VIGNETTE_STRENGTH,
                @as(u32, @intCast(ctx.renderer.total_frames_rendered % 1000)),
            );
        }
    };

    const LensFlareJobContext = struct {
        renderer: *Renderer,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,

        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *LensFlareJobContext = @ptrCast(@alignCast(ctx_ptr));
            _ = ctx.height;
            lens_flare_pass.runRows(
                ctx.renderer.bitmap.pixels,
                ctx.renderer.lens_flare_scratch_pixels,
                ctx.start_row,
                ctx.end_row,
                ctx.width,
                config.POST_LENS_FLARE_THRESHOLD,
                @as(f32, @floatFromInt(config.POST_LENS_FLARE_INTENSITY_PERCENT)) / 100.0,
            );
        }
    };

    const MotionBlurJobContext = struct {
        renderer: *Renderer,
        current_view: TemporalAAViewState,
        previous_view: TemporalAAViewState,
        start_row: usize,
        end_row: usize,
        width: usize,
        height: usize,

        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *MotionBlurJobContext = @ptrCast(@alignCast(ctx_ptr));
            motion_blur_pass.runRows(
                ctx.renderer.bitmap.pixels,
                ctx.renderer.moblur_scratch_pixels,
                ctx.renderer.scene_camera,
                ctx.start_row,
                ctx.end_row,
                ctx.width,
                ctx.height,
                ctx.current_view,
                ctx.previous_view,
            );
        }
    };

    // --- God Rays ---
    fn applyGodRaysPass(self: *Renderer, projection: ProjectionParams, light_dir_world: math.Vec3) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);

        // actually we can just project the light_dir_world as a point relative to camera since it's directional.
        // Actually, we already have self.scene_camera setup, so we know our view.
        // But for god rays we usually just want a screen coordinate where the light is. Let's simplify.
        const light_pos_view = math.Vec3.new(math.Vec3.dot(light_dir_world, self.taa_previous_view.basis_right), // just using any active view basis
            math.Vec3.dot(light_dir_world, self.taa_previous_view.basis_up), math.Vec3.dot(light_dir_world, self.taa_previous_view.basis_forward));

        var light_screen_pos = math.Vec2.new(-1000, -1000);
        if (light_pos_view.z > 0.0) {
            // Light is in front
            const light_proj = projectCameraPositionFloat(math.Vec3.scale(light_pos_view, 1000.0), projection);
            light_screen_pos = math.Vec2.new(light_proj.x, light_proj.y);
        }
        god_rays_pass.runPipeline(
            self,
            width,
            height,
            light_screen_pos.x,
            light_screen_pos.y,
            config.POST_GOD_RAYS_SAMPLES,
            config.POST_GOD_RAYS_DECAY,
            config.POST_GOD_RAYS_DENSITY,
            config.POST_GOD_RAYS_WEIGHT,
            config.POST_GOD_RAYS_EXPOSURE,
            noopRenderPassJob,
        );

        std.mem.swap([]u32, &self.bitmap.pixels, &self.god_rays_scratch_pixels);
        self.recordRenderPassTiming("god_rays", pass_start);
    }

    // --- Lens Flare ---
    fn applyLensFlarePass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        lens_flare_pass.runPipeline(
            self,
            width,
            height,
            config.POST_LENS_FLARE_THRESHOLD,
            @as(f32, @floatFromInt(config.POST_LENS_FLARE_INTENSITY_PERCENT)) / 100.0,
            noopRenderPassJob,
        );

        std.mem.swap([]u32, &self.bitmap.pixels, &self.lens_flare_scratch_pixels);
        self.recordRenderPassTiming("lens_flare", pass_start);
    }

    // --- Chromatic Aberration ---
    fn applyChromaticAberrationPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        chromatic_aberration_pass.runPipeline(
            self,
            width,
            height,
            config.POST_CHROMATIC_ABERRATION_STRENGTH,
            noopRenderPassJob,
        );

        std.mem.swap([]u32, &self.bitmap.pixels, &self.moblur_scratch_pixels);
        self.recordRenderPassTiming("chromatic_aberration", pass_start);
    }

    // --- Film Grain & Vignette ---
    fn applyFilmGrainVignettePass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        film_grain_vignette_pass.runPipeline(
            self,
            width,
            height,
            config.POST_FILM_GRAIN_STRENGTH,
            config.POST_VIGNETTE_STRENGTH,
            @as(u32, @intCast(self.total_frames_rendered % 1000)),
            noopRenderPassJob,
        );
        self.recordRenderPassTiming("film_grain_vignette", pass_start);
    }

    fn applyMotionBlurPass(self: *Renderer, current_view: TemporalAAViewState) void {
        if (self.bitmap.pixels.len == 0 or self.scene_camera.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);

        // If TAA isn't populated, we can't reliably do motion blur
        if (!self.taa_scratch.valid) return;

        motion_blur_pass.runPipeline(self, current_view, height, width, noopRenderPassJob);

        std.mem.swap([]u32, &self.bitmap.pixels, &self.moblur_scratch_pixels);

        self.recordRenderPassTiming("motion_blur", pass_start);
    }

    fn applyTemporalAAPass(self: *Renderer, mesh: *const Mesh, current_view: TemporalAAViewState) void {
        const _zone = profiler.zone("applyTemporalAAPass");
        defer if (_zone) |z| z.end();
        if (self.bitmap.pixels.len == 0 or self.scene_camera.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        taa_pass.runPipeline(
            self,
            mesh,
            current_view,
            width,
            height,
            noopRenderPassJob,
            taa_helpers.surfaceTagForHandle,
            taa_helpers.packHistoryNormal,
        );
        self.recordRenderPassTiming("taa", pass_start);
    }

    fn applySSRPass(self: *Renderer, projection: ProjectionParams) void {
        if (self.bitmap.pixels.len == 0 or self.scene_depth.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();

        const scene_height: usize = @intCast(self.bitmap.height);
        ssr_pass.runPipeline(self, projection, scene_height, noopRenderPassJob);

        std.mem.swap([]u32, &self.bitmap.pixels, &self.ssr_scratch_pixels);
        self.recordRenderPassTiming("ssr", pass_start);
    }

    fn applyDepthOfFieldPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0 or self.scene_depth.len != self.bitmap.pixels.len) return;
        const pass_start = std.time.nanoTimestamp();

        const scene_width: usize = @intCast(self.bitmap.width);
        const scene_height: usize = @intCast(self.bitmap.height);
        depth_of_field_pass.runPipeline(self, scene_width, scene_height, noopRenderPassJob);

        self.recordRenderPassTiming("dof", pass_start);
    }

    fn applyBloomPass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const scene_width: usize = @intCast(self.bitmap.width);
        const scene_height: usize = @intCast(self.bitmap.height);
        bloom_pass.runPipeline(
            self,
            scene_width,
            scene_height,
            config.POST_BLOOM_THRESHOLD,
            config.POST_BLOOM_INTENSITY_PERCENT,
            noopRenderPassJob,
            bloom_rows.extractDownsampleRows,
            bloom_rows.blurHorizontalRows,
            bloom_rows.blurVerticalRows,
            bloom_rows.compositeRows,
        );
        self.recordRenderPassTiming("bloom", pass_start);
    }

    fn applyBlockbusterColorGradePass(self: *Renderer) void {
        if (self.bitmap.pixels.len == 0) return;
        const pass_start = std.time.nanoTimestamp();
        const width: usize = @intCast(self.bitmap.width);
        const height: usize = @intCast(self.bitmap.height);
        color_grade_pass.runPipeline(self, width, height, noopRenderPassJob);

        self.recordRenderPassTiming(config.POST_COLOR_PROFILE_NAME, pass_start);
    }

    fn drawBitmap(self: *Renderer) void {
        if (self.hdc) |hdc| {
            if (self.hdc_mem) |hdc_mem| {
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

                if (config.WINDOW_VSYNC) {
                    _ = DwmFlush();
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
            var pass_order: [max_render_passes]usize = undefined;
            for (0..self.render_pass_count) |idx| {
                pass_order[idx] = idx;
            }

            var sort_idx: usize = 1;
            while (sort_idx < self.render_pass_count) : (sort_idx += 1) {
                const current_idx = pass_order[sort_idx];
                const current_metric = renderPassSortMetric(self.render_pass_timings[current_idx]);
                var insert_idx = sort_idx;
                while (insert_idx > 0) {
                    const prev_idx = pass_order[insert_idx - 1];
                    if (renderPassSortMetric(self.render_pass_timings[prev_idx]) >= current_metric) break;
                    pass_order[insert_idx] = prev_idx;
                    insert_idx -= 1;
                }
                pass_order[insert_idx] = current_idx;
            }

            for (pass_order[0..self.render_pass_count]) |pass_idx| {
                const pass = self.render_pass_timings[pass_idx];
                const display_name = if (config.POST_TAA_ENABLED and std.mem.eql(u8, pass.name, "taa"))
                    "meshlet_taa"
                else
                    pass.name;
                const line = if (pass.has_sample)
                    std.fmt.bufPrint(&line_buffer, "{s}: {d:.2} ms/frame", .{ display_name, pass.sampled_ms_per_frame }) catch continue
                else
                    std.fmt.bufPrint(&line_buffer, "{s}: sampling...", .{display_name}) catch continue;
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
    ) !u64 {
        const _z_renderTiled = profiler.zone("renderTiled");
        defer if (_z_renderTiled) |z| z.end();
        _ = light_dir;
        const grid = self.tile_grid.?;
        const tile_buffers = self.tile_buffers.?;
        const tile_lists = self.tile_triangle_lists.?;
        const active_flags = self.active_tile_flags.?;
        const active_indices = self.active_tile_indices.?;
        BinningStage.clearTileTriangleLists(tile_lists);
        if (!self.scene_buffers_initialized) {
            @memset(self.scene_depth, std.math.inf(f32));
            @memset(self.scene_camera, math.Vec3.new(0.0, 0.0, 0.0));
            @memset(self.scene_normal, math.Vec3.new(0.0, 0.0, 0.0));
            @memset(self.scene_surface, TileRenderer.SurfaceHandle.invalid());
            self.scene_buffers_initialized = true;
        } else {
            for (active_flags, 0..) |was_active, tile_idx| {
                if (!was_active) continue;
                self.clearSceneAttachmentsForTile(&grid.tiles[tile_idx]);
            }
        }
        @memset(active_flags, false);

        const triangles = mesh_work.triangleSlice();
        self.meshlet_telemetry.touched_tiles = 0;

        if (triangles.len == 0) {
            pipeline_logger.debugSub("tiled", "no triangles; bitmap cleared", .{});
            return 0;
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
                .sys_shadows = if (config.MESHLET_SHADOWS_ENABLED) &self.sys_shadows else null,
                .light_direction = if (self.lights.items.len > 0) self.lights.items[0].direction else math.Vec3.new(0, -1, 0),
                .mesh_ptr = mesh,
                .cam_pos = self.camera_position,
                .cam_right = math.Vec3.new(transform.data[0], transform.data[1], transform.data[2]),
                .cam_up = math.Vec3.new(transform.data[4], transform.data[5], transform.data[6]),
                .cam_fwd = math.Vec3.new(transform.data[8], transform.data[9], transform.data[10]),
            };
        }

        if (active_tile_count == 0) {
            pipeline_logger.debugSub("tiled", "triangles binned to zero active tiles", .{});
            return 0;
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

        var shadow_pass_elapsed_ns: u64 = 0;
        const run_meshlet_shadows = config.MESHLET_SHADOWS_ENABLED and mesh.meshlets.len > 0;
        if (run_meshlet_shadows) {
            const shadow_pass_start = std.time.nanoTimestamp();

            if (self.job_system) |job_sys| {
                var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
                const main_tile_idx = active_indices[0];

                for (active_indices[1..active_tile_count]) |tile_idx| {
                    jobs[tile_idx] = Job.init(
                        TileRenderJob.applyMeshletShadows,
                        @ptrCast(&tile_jobs[tile_idx]),
                        &parent_job,
                    );

                    if (!job_sys.submitJobAuto(&jobs[tile_idx])) {
                        TileRenderJob.applyMeshletShadows(@ptrCast(&tile_jobs[tile_idx]));
                    }
                }

                TileRenderJob.applyMeshletShadows(@ptrCast(&tile_jobs[main_tile_idx]));
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
                    TileRenderJob.applyMeshletShadows(@ptrCast(&tile_jobs[tile_idx]));
                }
            }

            const shadow_elapsed_ns = std.time.nanoTimestamp() - shadow_pass_start;
            if (shadow_elapsed_ns > 0) {
                shadow_pass_elapsed_ns = @intCast(shadow_elapsed_ns);
            }
        }

        // 4. Compositing: Copy the pixels from each completed tile buffer to the main screen bitmap.
        for (active_indices[0..active_tile_count]) |tile_idx| {
            const tile = &grid.tiles[tile_idx];
            TileRenderer.compositeTileToScreen(tile, &tile_buffers[tile_idx], &self.bitmap, self.scene_depth, self.scene_camera, self.scene_normal, self.scene_surface);
        }

        return shadow_pass_elapsed_ns;
    }

    fn clearSceneAttachmentsForTile(self: *Renderer, tile: *const TileRenderer.Tile) void {
        var y: i32 = 0;
        while (y < tile.height) : (y += 1) {
            const row_start = @as(usize, @intCast((tile.y + y) * self.bitmap.width + tile.x));
            const row_end = row_start + @as(usize, @intCast(tile.width));
            @memset(self.scene_depth[row_start..row_end], std.math.inf(f32));
            @memset(self.scene_camera[row_start..row_end], math.Vec3.new(0.0, 0.0, 0.0));
            @memset(self.scene_normal[row_start..row_end], math.Vec3.new(0.0, 0.0, 0.0));
            @memset(self.scene_surface[row_start..row_end], TileRenderer.SurfaceHandle.invalid());
        }
    }

    fn populateTilesFromMeshlets(
        self: *Renderer,
        tile_lists: []BinningStage.TileTriangleList,
        mesh_work: *const MeshWork,
    ) void {
        const _z_populateTilesFromMeshlets = profiler.zone("populateTilesFromMeshlets");
        defer if (_z_populateTilesFromMeshlets) |z| z.end();
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
                    .meshlet_index = meshlet_index,
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
                transformMeshletVertices(mesh_vertices, meshlet_vertices, self.camera_position, right, up, forward, projection, local_camera_vertices, local_projected_vertices);

                for (mesh.meshletPrimitiveSlice(meshlet_ptr)) |primitive| {
                    const tri_idx = primitive.triangle_index;
                    const tri = mesh.triangles[tri_idx];
                    _ = emitMeshletPrimitiveToWork(
                        &writer,
                        mesh,
                        tri_idx,
                        meshlet_index,
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
        _ = light_dir;
        _ = projection;
        _ = mesh_work;
        _ = transform;
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
