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
pub const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;
const config = @import("../core/app_config.zig");
const input = @import("platform_input");
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
const pass_graph = @import("pipeline/pass_graph.zig");
const frame_graph = @import("graph/frame_graph.zig");
const frame_plan = @import("graph/frame_plan.zig");
const frame_pipeline = @import("frame/pipeline.zig");
const frame_executor = @import("frame/executor.zig");
const frame_dispatchers = @import("frame/dispatchers.zig");
const render_utils = @import("core/utils.zig");
const scene_item_gizmo = @import("scene_item_gizmo.zig");
const camera_controller = @import("camera_controller.zig");
const camera_runtime = @import("camera_runtime.zig");
const frame_pacing_hud = @import("frame/pacing_hud.zig");
const frame_pacing = @import("frame/pacing.zig");
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
const direct_primitives = @import("direct/primitives.zig");
const direct_showcase = @import("direct/showcase.zig");
const post_dispatch = @import("renderer/post_dispatch.zig");
const renderer_input = @import("renderer/input.zig");
const frame_resources = @import("frame/resources.zig");
const frame_setup_stage = @import("stages/frame_setup_stage.zig");
const presentation_stage = @import("stages/presentation_stage.zig");
const direct_backend = @import("backends/direct_backend.zig");
const scene_tiled_backend = @import("backends/scene_tiled_backend.zig");
const present_d3d11 = @import("present/present_d3d11.zig");
const present_state = @import("present/state.zig");
const log = @import("../core/log.zig");
pub const renderer_logger = log.get("renderer.core");
const pipeline_logger = log.get("renderer.pipeline");
const meshlet_logger = log.get("renderer.meshlet");
const ground_logger = log.get("renderer.ground");

const NEAR_CLIP: f32 = 0.01;
pub const NEAR_EPSILON: f32 = 1e-4;
const INVALID_PROJECTED_COORD: i32 = -1000;
const ENABLE_MESHLET_CONE_CULL = false;
const fps_camera_floor_y: f32 = 0.0;
const fps_camera_eye_height: f32 = 1.6;
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

    /// init initializes Renderer state and returns the configured value.
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

    /// project projects coordinates for Renderer calculations.
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

    pub fn reset(self: *HybridShadowDebugState) void {
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

pub const LightGizmoAxis = enum(u8) {
    x = 0,
    y = 1,
    z = 2,
};

const LightGizmoState = struct {
    enabled: bool = true,
    selected_light_index: usize = 0,
    active_axis: LightGizmoAxis = .x,
    move_step: f32 = 0.2,
    hover_axis: ?LightGizmoAxis = null,
    drag_axis: ?LightGizmoAxis = null,
    drag_last_pointer: ?math.Vec2 = null,
};

const CameraControlMode = camera_controller.ControlMode;

pub const CursorStyle = enum(u8) {
    arrow = 0,
    grab = 1,
    grabbing = 2,
    hidden = 3,
};

pub fn lightGizmoAxisName(axis: LightGizmoAxis) []const u8 {
    return switch (axis) {
        .x => "x",
        .y => "y",
        .z => "z",
    };
}

fn lightGizmoAxisUnit(axis: LightGizmoAxis) math.Vec3 {
    return switch (axis) {
        .x => math.Vec3.new(1.0, 0.0, 0.0),
        .y => math.Vec3.new(0.0, 1.0, 0.0),
        .z => math.Vec3.new(0.0, 0.0, 1.0),
    };
}

fn lightGizmoAxisColor(axis: LightGizmoAxis, active_axis: LightGizmoAxis, hot_axis: ?LightGizmoAxis) u32 {
    if (hot_axis != null and hot_axis.? == axis) return 0xFFFFFF66;
    if (axis == active_axis) {
        return switch (axis) {
            .x => 0xFFFFA0A0,
            .y => 0xFFA0FFA0,
            .z => 0xFFA0B8FF,
        };
    }
    return switch (axis) {
        .x => 0xFFDD4040,
        .y => 0xFF40DD40,
        .z => 0xFF4060DD,
    };
}

pub const SceneItemBinding = scene_item_gizmo.ItemBinding;
pub const SceneItemTranslateRequest = scene_item_gizmo.TranslateRequest;

const LightWorkStats = struct {
    active_lights: usize = 0,
    shadow_map_lights: usize = 0,
    meshlet_shadow_lights: usize = 0,
    shadow_map_reused_lights: usize = 0,
    shadow_budget_skipped_lights: usize = 0,
    shadow_map_downscaled_lights: usize = 0,
    shadow_map_upscaled_lights: usize = 0,
    shadow_cadence_increased_lights: usize = 0,
    shadow_cadence_decreased_lights: usize = 0,
    shadow_queries: usize = 0,
    meshlet_ray_tests: usize = 0,
    meshlet_shadow_chunks: usize = 0,
    meshlet_shadow_chunk_pixels: usize = 0,
    meshlet_shadow_chunk_active_rays: usize = 0,
    meshlet_shadow_packets: usize = 0,
    meshlet_shadow_packets_skipped: usize = 0,
    meshlet_shadow_packet_active_lanes: usize = 0,
    meshlet_shadow_packet_occluded_lanes: usize = 0,
    meshlet_shadow_trace_us: u64 = 0,
    meshlet_shadow_apply_us: u64 = 0,
    triangles_rasterized: usize = 0,
    covered_pixels: usize = 0,
    depth_tests_passed: usize = 0,
    alpha_pixels: usize = 0,
    shadow_budget_ns: i128 = 0,
    shadow_build_ns: i128 = 0,
    shadow_resolve_ns: i128 = 0,
    active_tiles: usize = 0,
    tile_light_candidates: usize = 0,
    tile_light_final: usize = 0,
    tile_light_rejected: usize = 0,
    tile_light_overflow_tiles: usize = 0,
};

const LoadingOverlayState = struct {
    enabled: bool = false,
    progress: f32 = 0.0,
    completed_steps: usize = 0,
    total_steps: usize = 1,
    spinner_tick: u32 = 0,
    scene_text_len: usize = 0,
    scene_text_buf: [64]u8 = [_]u8{0} ** 64,
    phase_text_len: usize = 0,
    phase_text_buf: [96]u8 = [_]u8{0} ** 96,

    fn sceneText(self: *const LoadingOverlayState) []const u8 {
        return self.scene_text_buf[0..self.scene_text_len];
    }

    fn phaseText(self: *const LoadingOverlayState) []const u8 {
        return self.phase_text_buf[0..self.phase_text_len];
    }
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

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
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

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
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

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
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

pub const ProjectionParams = struct {
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

    pub fn invalidate(self: *FrameViewCache) void {
        self.valid = false;
    }

    pub fn needsUpdate(
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

    /// update updates Renderer state for the current tick/frame.
    pub fn update(
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
        const basis = camera_controller.computeViewBasis(rotation_angle, rotation_x);
        const right = basis.right;
        const up = basis.up;
        const forward = basis.forward;

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

        const projection_scalars = camera_controller.computeProjectionScalars(bitmap_width, bitmap_height, camera_fov_deg);
        const center_x = projection_scalars.center_x;
        const center_y = projection_scalars.center_y;
        const x_scale = projection_scalars.x_scale;
        const y_scale = projection_scalars.y_scale;
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

pub fn validSceneCameraSample(camera_pos: math.Vec3) bool {
    return render_utils.validSceneCameraSample(camera_pos, NEAR_CLIP);
}

const sampleSceneCameraClamped = render_utils.sampleSceneCameraClamped;

/// Estimates scene normal.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
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

pub const TemporalAAViewState = struct {
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,

    /// init initializes Renderer state and returns the configured value.
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

pub const cameraToWorldPosition = render_utils.cameraToWorldPosition;

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

/// projectCameraPositionFloat projects coordinates for Renderer calculations.
pub fn projectCameraPositionFloat(position: math.Vec3, projection: ProjectionParams) math.Vec2 {
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

/// Processes pack shifted color batch simd.
/// Keeps pack shifted color batch simd as the single implementation point so call-site behavior stays consistent.
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

/// Processes pack shifted color batch.
/// Keeps pack shifted color batch as the single implementation point so call-site behavior stays consistent.
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

pub fn tryApplyTemporalAAMeshletBatch(
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

/// renderAmbientOcclusionRows renders Renderer output.
pub fn renderAmbientOcclusionRows(
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

pub fn blurAmbientOcclusionHorizontalRows(ao: *AOScratch, depth_threshold: f32, start_row: usize, end_row: usize) void {
    ssao_rows.blurHorizontalRows(ao, depth_threshold, start_row, end_row);
}

pub fn blurAmbientOcclusionVerticalRows(ao: *AOScratch, depth_threshold: f32, start_row: usize, end_row: usize) void {
    ssao_rows.blurVerticalRows(ao, depth_threshold, start_row, end_row);
}

pub fn compositeAmbientOcclusionRows(
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
extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;
extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;
extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;
extern "gdi32" fn SetBkMode(hdc: windows.HDC, mode: i32) i32;
extern "gdi32" fn SetTextColor(hdc: windows.HDC, color: u32) u32;
extern "gdi32" fn TextOutW(hdc: windows.HDC, x: i32, y: i32, lpString: [*]const u16, c: i32) bool;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) bool;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
extern "kernel32" fn CreateWaitableTimerExW(lpTimerAttributes: ?*anyopaque, lpTimerName: ?[*:0]const u16, dwFlags: u32, dwDesiredAccess: u32) ?windows.HANDLE;
extern "kernel32" fn SetWaitableTimerEx(hTimer: windows.HANDLE, lpDueTime: *const i64, lPeriod: i32, pfnCompletionRoutine: ?*const anyopaque, lpArgToCompletionRoutine: ?*anyopaque, wakeContext: ?*const anyopaque, tolerableDelay: u32) windows.BOOL;
extern "dwmapi" fn DwmFlush() callconv(.winapi) windows.HRESULT;

const TIMER_MODIFY_STATE: u32 = 0x0002;
const SYNCHRONIZE_ACCESS: u32 = 0x0010_0000;
const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: u32 = 0x0000_0002;

// ========== MODULE IMPORTS ==========
const Bitmap = @import("../assets/bitmap.zig").Bitmap;
const TileRenderer = @import("core/tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("core/tile_binning.zig");
const job_system_module = @import("job_system");
const JobSystem = job_system_module.JobSystem;
const Job = job_system_module.Job;

const ColorGradeJobContext = struct {
    pixels: []u32,
    start_index: usize,
    end_index: usize,
    profile: *const ColorGradeProfile,

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
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

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
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
    shadow_build_elapsed_ns: []const i128,
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
    shadow_build_elapsed_ns: []const i128,
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

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
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

    /// Runs this module step with the currently bound configuration.
    /// Keeps run as the single implementation point so call-site behavior stays consistent.
    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *AdaptiveShadowTileJob = @ptrCast(@alignCast(ctx_ptr));
        adaptive_shadow_tile_pass.run(ctx);
    }
};

const BloomJobContext = bloom_pass.JobContext(BloomScratch);

const CompositeJobContext = struct {
    tile: *const TileRenderer.Tile,
    tile_buffer: *const TileRenderer.TileBuffer,
    bitmap: *Bitmap,
    scene_depth: ?[]f32,
    scene_camera: ?[]math.Vec3,
    scene_normal: ?[]math.Vec3,
    scene_surface: ?[]TileRenderer.SurfaceHandle,

    pub fn run(ctx_ptr: *anyopaque) void {
        const ctx: *CompositeJobContext = @ptrCast(@alignCast(ctx_ptr));
        TileRenderer.compositeTileToScreen(ctx.tile, ctx.tile_buffer, ctx.bitmap, ctx.scene_depth, ctx.scene_camera, ctx.scene_normal, ctx.scene_surface);
    }
};

pub fn noopRenderPassJob(ctx: *anyopaque) void {
    _ = ctx;
}

const clampByte = render_utils.clampByte;

/// The `Renderer` struct holds the entire state of the rendering engine.
/// It manages the window connection, the pixel buffer, the rendering pipeline, and application state.
pub const LightInfo = struct {
    pub const ShadowMode = enum(u8) {
        none = 0,
        shadow_map = 1,
        meshlet_ray = 2,
    };

    orbit_x: f32,
    orbit_speed: f32,
    distance: f32,
    elevation: f32,
    color: math.Vec3,
    direction: math.Vec3 = math.Vec3.new(0, -1, 0),
    manual_direction: bool = false,
    glow_radius: f32 = 0.0,
    glow_intensity: f32 = 0.0,
    shadow_mode: ShadowMode = .meshlet_ray,
    shadow_update_interval_frames: u32 = 1,
    shadow_dynamic_interval_scale: u32 = 1,
    shadow_last_build_frame: u64 = 0,
    shadow_last_build_ns: i128 = 0,
    shadow_map_target_size: usize,
    shadow_map: ShadowMap,
};

const LightSoA = struct {
    dir_x: []f32,
    dir_y: []f32,
    dir_z: []f32,
    dir_cam_x: []f32,
    dir_cam_y: []f32,
    dir_cam_z: []f32,
    distance: []f32,
    shadow_mode: []u8,
};

const TileLightRange = struct {
    offset: usize = 0,
    count: usize = 0,
};

pub const Renderer = struct {
    // Core rendering resources
    hwnd: windows.HWND, // Handle to the window we are drawing to.
    bitmap: Bitmap, // The main pixel buffer we draw into (our "canvas").
    hdc_mem: ?windows.HDC, // An in-memory device context for faster drawing operations.
    hdc_mem_old_bitmap: ?HGDIOBJ,
    present_backend: present_d3d11.Backend,
    allocator: std.mem.Allocator,

    // Camera and object state
    rotation_angle: f32, // Camera yaw (left/right rotation).
    rotation_x: f32, // Camera pitch (up/down rotation).
    camera_position: math.Vec3, // Camera world position.
    camera_move_speed: f32, // Units per second for keyboard movement.
    mouse_state: camera_controller.MouseState, // First-person mouse accumulation/smoothing state.
    mouse_input: input.MouseState,
    fps_body_state: camera_controller.FpsBodyState,

    // Light state
    lights: std.ArrayList(LightInfo),
    light_soa: LightSoA,
    shadow_build_elapsed_ns: []i128,
    shadow_resolve_elapsed_ns: []i128,
    sys_shadows: shadow_system.ShadowSystem,

    // Input and timing state
    keys_pressed: input.KeyboardState, // Typed keyboard state snapshot.
    camera_fov_deg: f32,
    frame_count: u32,
    total_frames_rendered: u64,
    last_time: i128,
    last_frame_time: i128,
    next_frame_time: i128,
    last_completed_frame_time: i128,
    current_frame_start_time: i128,
    pending_software_wait_ns: i128 = 0,
    active_software_wait_ns: i128 = 0,
    frame_pacing_sleep_bias_ns: i128 = 0,
    frame_deadline_error_ns: i128 = 0,
    present_cost_ema_ns: i128 = 500_000,
    current_fps: u32,
    target_frame_time_ns: i128,
    frame_pacing: frame_pacing_hud.Tracker = .{},
    frame_pacing_timer: ?windows.HANDLE = null,
    fps_zoom_state: camera_controller.FpsZoomState = .{},
    pending_fov_delta: f32,
    camera_control_mode: CameraControlMode = .editor,
    scene_camera_script_active: bool = false,
    profile_capture_frame: u64,
    profile_capture_emitted: bool,
    shadow_budget_pressure_frames: u32 = 0,
    shadow_budget_relief_frames: u32 = 0,

    // Tiled rendering resources
    tile_grid: ?TileGrid, // The grid layout of tiles on the screen.
    tile_buffers: ?[]TileBuffer, // A buffer for each tile to be rendered into in parallel.
    job_system: ?*JobSystem, // The multi-threaded job system.
    shadow_tile_jobs_buffer: ?[]AdaptiveShadowTileJob,
    job_buffer: ?[]Job,
    shadow_job_buffer: ?[]Job,
    composite_job_contexts: ?[]CompositeJobContext,
    job_completion_buffer: ?[]bool,
    tile_triangle_lists: ?[]BinningStage.TileTriangleList,
    active_tile_flags: ?[]bool,
    active_tile_indices: ?[]usize,
    tile_light_ranges: []TileLightRange,
    tile_light_indices: []usize,
    frame_view_cache: FrameViewCache = .{},
    cached_post_graph: frame_graph.CachedGraph = .{},
    cached_frame_plan: frame_plan.CachedPlan = .{},
    direct_backend: direct_backend.State,
    present_state: present_state.State,

    // Rendering options and data
    single_texture_binding: [1]?*const texture.Texture,
    hdri_map: ?texture.HdrTexture = null,
    textures: []const ?*const texture.Texture,
    show_tile_borders: bool = false,
    show_wireframe: bool = false,
    show_light_orb: bool = true,
    cull_light_orb: bool = true,
    use_tiled_rendering: bool = true,
    show_frame_pacing_overlay: bool = builtin.mode == .Debug or builtin.mode == .ReleaseFast,
    show_render_overlay: bool = builtin.mode == .Debug,
    loading_overlay: LoadingOverlayState = .{},

    ground_debug: GroundDebugState = .{},
    meshlet_telemetry: MeshletTelemetry = .{},
    light_gizmo: LightGizmoState = .{},
    scene_item_gizmo: scene_item_gizmo.State = .{},
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
    light_work_stats: LightWorkStats = .{},
    meshlet_ray_tests_counter: std.atomic.Value(usize),
    meshlet_shadow_chunk_counter: std.atomic.Value(usize),
    meshlet_shadow_chunk_pixels_counter: std.atomic.Value(usize),
    meshlet_shadow_chunk_active_rays_counter: std.atomic.Value(usize),
    meshlet_shadow_packet_counter: std.atomic.Value(usize),
    meshlet_shadow_packet_skipped_counter: std.atomic.Value(usize),
    meshlet_shadow_packet_active_lanes_counter: std.atomic.Value(usize),
    meshlet_shadow_packet_occluded_lanes_counter: std.atomic.Value(usize),
    meshlet_shadow_trace_ns_counter: std.atomic.Value(u64),
    meshlet_shadow_apply_ns_counter: std.atomic.Value(u64),
    triangles_rasterized_counter: std.atomic.Value(usize),
    covered_pixels_counter: std.atomic.Value(usize),
    depth_tests_passed_counter: std.atomic.Value(usize),
    alpha_pixels_counter: std.atomic.Value(usize),
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
    moblur_job_contexts: []post_dispatch.MotionBlurJobContext,
    moblur_scratch_pixels: []u32,
    god_rays_job_contexts: []post_dispatch.GodRaysJobContext,
    god_rays_scratch_pixels: []u32,
    chromatic_aberration_job_contexts: []post_dispatch.ChromaticAberrationJobContext,
    film_grain_job_contexts: []post_dispatch.FilmGrainVignetteJobContext,
    lens_flare_job_contexts: []post_dispatch.LensFlareJobContext,
    lens_flare_scratch_pixels: []u32,
    color_grade_jobs: []Job,

    // Unused state from previous versions
    last_brightness_min: f32,
    last_brightness_max: f32,
    last_brightness_avg: f32,
    last_reported_fov_deg: f32,
    light_marker_visible_last_frame: bool,
    light_capacity_log_initialized: bool = false,
    last_logged_light_capacity: usize = 0,
    last_logged_min_shadow_size: usize = 0,
    last_logged_max_shadow_size: usize = 0,
    last_logged_total_shadow_bytes: usize = 0,

    /// Initializes the renderer, creating all necessary resources.
    /// JS Analogy: The `constructor` for our main rendering class.
    fn defaultLightColor(light_idx: usize) math.Vec3 {
        return if ((light_idx & 1) == 0)
            math.Vec3.new(1.0, 0.9, 0.8)
        else
            math.Vec3.new(0.5, 0.6, 1.0);
    }

    fn defaultLightShadowMode() LightInfo.ShadowMode {
        if (config.MESHLET_SHADOWS_ENABLED) return .meshlet_ray;
        if (config.POST_SHADOW_ENABLED) return .shadow_map;
        return .none;
    }

    /// initLightInfo initializes Renderer state and returns the configured value.
    fn initLightInfo(allocator: std.mem.Allocator, light_idx: usize) !LightInfo {
        const sm_depth = try allocator.alloc(f32, config.POST_SHADOW_MAP_SIZE * config.POST_SHADOW_MAP_SIZE);
        return LightInfo{
            .orbit_x = @as(f32, @floatFromInt(light_idx)) * 3.14159,
            .orbit_speed = 0.0,
            .distance = config.LIGHT_DISTANCE_INITIAL,
            .elevation = 0.65,
            .color = defaultLightColor(light_idx),
            .shadow_mode = defaultLightShadowMode(),
            .shadow_map_target_size = config.POST_SHADOW_MAP_SIZE,
            .shadow_map = .{
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
            },
        };
    }

    fn syncLightSoA(self: *Renderer) void {
        for (self.lights.items, 0..) |light, i| {
            self.light_soa.dir_x[i] = light.direction.x;
            self.light_soa.dir_y[i] = light.direction.y;
            self.light_soa.dir_z[i] = light.direction.z;
            self.light_soa.distance[i] = light.distance;
            self.light_soa.shadow_mode[i] = @intFromEnum(light.shadow_mode);
        }
    }

    pub fn syncLightCameraSoA(self: *Renderer, basis_right: math.Vec3, basis_up: math.Vec3, basis_forward: math.Vec3) void {
        for (self.lights.items, 0..) |_, i| {
            const dir_x = self.light_soa.dir_x[i];
            const dir_y = self.light_soa.dir_y[i];
            const dir_z = self.light_soa.dir_z[i];
            self.light_soa.dir_cam_x[i] = dir_x * basis_right.x + dir_y * basis_right.y + dir_z * basis_right.z;
            self.light_soa.dir_cam_y[i] = dir_x * basis_up.x + dir_y * basis_up.y + dir_z * basis_up.z;
            self.light_soa.dir_cam_z[i] = dir_x * basis_forward.x + dir_y * basis_forward.y + dir_z * basis_forward.z;
        }
    }

    pub fn countLightsWithShadowMode(self: *const Renderer, mode: LightInfo.ShadowMode) usize {
        var count: usize = 0;
        for (self.lights.items) |light| {
            if (light.shadow_mode == mode) count += 1;
        }
        return count;
    }

    fn totalShadowMapBytes(self: *const Renderer) usize {
        var total_bytes: usize = 0;
        for (self.lights.items) |light| {
            total_bytes += light.shadow_map.width * light.shadow_map.height * @sizeOf(f32);
        }
        return total_bytes;
    }

    /// Computes shadow build budget ns.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    fn computeShadowBuildBudgetNs(self: *const Renderer) i128 {
        if (self.target_frame_time_ns <= 0) return -1;
        const budget_percent = std.math.clamp(config.POST_SHADOW_BUDGET_PERCENT, 0, 100);
        if (budget_percent <= 0) return 0;
        if (budget_percent >= 100) return self.target_frame_time_ns;
        return @divTrunc(self.target_frame_time_ns * @as(i128, @intCast(budget_percent)), 100);
    }

    /// Estimates shadow build cost ns.
    /// Keeps estimate shadow build cost ns as the single implementation point so call-site behavior stays consistent.
    fn estimateShadowBuildCostNs(light: *const LightInfo) i128 {
        if (light.shadow_last_build_ns > 0) return light.shadow_last_build_ns;
        const shadow_texel_count = light.shadow_map.width * light.shadow_map.height;
        const texel_estimate_ns: i128 = @intCast(shadow_texel_count);
        return @max(@as(i128, 100_000), texel_estimate_ns);
    }

    fn resizeLightShadowMap(
        self: *Renderer,
        index: usize,
        shadow_map_size: usize,
        update_target_size: bool,
        reason: []const u8,
    ) !bool {
        if (index >= self.lights.items.len) return false;
        const clamped_size = std.math.clamp(shadow_map_size, @as(usize, 64), @as(usize, 4096));
        const light = &self.lights.items[index];
        if (update_target_size) {
            light.shadow_map_target_size = clamped_size;
        }
        if (light.shadow_map.width == clamped_size and light.shadow_map.height == clamped_size) return false;

        const prev_width = light.shadow_map.width;
        const prev_height = light.shadow_map.height;
        light.shadow_map.depth = try self.allocator.realloc(light.shadow_map.depth, clamped_size * clamped_size);
        light.shadow_map.width = clamped_size;
        light.shadow_map.height = clamped_size;
        light.shadow_map.active = false;
        light.shadow_last_build_frame = 0;
        light.shadow_last_build_ns = 0;
        renderer_logger.infoSub(
            "lights",
            "light {} shadow_map resized {}x{} -> {}x{} ({s})",
            .{ index, prev_width, prev_height, clamped_size, clamped_size, reason },
        );
        return true;
    }

    fn tryDownscaleOneShadowMapLight(self: *Renderer) !bool {
        var candidate_index: ?usize = null;
        var candidate_size: usize = 0;
        const min_size = @max(@as(usize, 64), config.POST_SHADOW_ADAPTIVE_MIN_MAP_SIZE);
        for (self.lights.items, 0..) |light, light_index| {
            if (light.shadow_mode != .shadow_map) continue;
            if (light.shadow_map.width <= min_size) continue;
            if (light.shadow_map.width > candidate_size) {
                candidate_size = light.shadow_map.width;
                candidate_index = light_index;
            }
        }
        if (candidate_index == null) return false;
        const idx = candidate_index.?;
        const current_size = self.lights.items[idx].shadow_map.width;
        const next_size = @max(min_size, current_size / 2);
        if (next_size >= current_size) return false;
        return self.resizeLightShadowMap(idx, next_size, false, "budget_downscale");
    }

    fn tryUpscaleOneShadowMapLight(self: *Renderer) !bool {
        var candidate_index: ?usize = null;
        var candidate_size: usize = std.math.maxInt(usize);
        for (self.lights.items, 0..) |light, light_index| {
            if (light.shadow_mode != .shadow_map) continue;
            if (light.shadow_map.width >= light.shadow_map_target_size) continue;
            if (light.shadow_map.width < candidate_size) {
                candidate_size = light.shadow_map.width;
                candidate_index = light_index;
            }
        }
        if (candidate_index == null) return false;
        const idx = candidate_index.?;
        const current_size = self.lights.items[idx].shadow_map.width;
        const target_size = self.lights.items[idx].shadow_map_target_size;
        const next_size = @min(target_size, current_size * 2);
        if (next_size <= current_size) return false;
        return self.resizeLightShadowMap(idx, next_size, false, "budget_upscale");
    }

    fn tryIncreaseShadowCadenceScale(self: *Renderer) bool {
        var candidate_index: ?usize = null;
        var candidate_cost_ns: i128 = 0;
        for (self.lights.items, 0..) |light, light_index| {
            if (light.shadow_mode != .shadow_map) continue;
            if (light.shadow_dynamic_interval_scale >= config.POST_SHADOW_ADAPTIVE_MAX_INTERVAL_SCALE) continue;
            const est_ns = estimateShadowBuildCostNs(&light);
            if (est_ns > candidate_cost_ns) {
                candidate_cost_ns = est_ns;
                candidate_index = light_index;
            }
        }
        if (candidate_index == null) return false;
        const idx = candidate_index.?;
        const light = &self.lights.items[idx];
        light.shadow_dynamic_interval_scale = @min(config.POST_SHADOW_ADAPTIVE_MAX_INTERVAL_SCALE, light.shadow_dynamic_interval_scale * 2);
        renderer_logger.infoSub(
            "lights",
            "light {} shadow cadence scale increased to {}x",
            .{ idx, light.shadow_dynamic_interval_scale },
        );
        return true;
    }

    fn tryDecreaseShadowCadenceScale(self: *Renderer) bool {
        var candidate_index: ?usize = null;
        var candidate_scale: u32 = 1;
        for (self.lights.items, 0..) |light, light_index| {
            if (light.shadow_mode != .shadow_map) continue;
            if (light.shadow_dynamic_interval_scale <= 1) continue;
            if (light.shadow_dynamic_interval_scale > candidate_scale) {
                candidate_scale = light.shadow_dynamic_interval_scale;
                candidate_index = light_index;
            }
        }
        if (candidate_index == null) return false;
        const idx = candidate_index.?;
        const light = &self.lights.items[idx];
        light.shadow_dynamic_interval_scale = @max(@as(u32, 1), light.shadow_dynamic_interval_scale / 2);
        renderer_logger.infoSub(
            "lights",
            "light {} shadow cadence scale decreased to {}x",
            .{ idx, light.shadow_dynamic_interval_scale },
        );
        return true;
    }

    /// Applies adaptive shadow budget policy.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    fn applyAdaptiveShadowBudgetPolicy(self: *Renderer) !void {
        if (!config.POST_SHADOW_ENABLED) return;
        if (!config.POST_SHADOW_ADAPTIVE_RESOLUTION_ENABLED) return;
        if (self.light_work_stats.shadow_map_lights == 0) return;
        const shadow_budget_ns = self.light_work_stats.shadow_budget_ns;
        if (shadow_budget_ns <= 0) return;

        if (self.light_work_stats.shadow_budget_skipped_lights > 0) {
            self.shadow_budget_pressure_frames += 1;
            self.shadow_budget_relief_frames = 0;
            if (self.shadow_budget_pressure_frames >= config.POST_SHADOW_ADAPTIVE_PRESSURE_FRAMES) {
                if (try self.tryDownscaleOneShadowMapLight()) {
                    self.light_work_stats.shadow_map_downscaled_lights += 1;
                } else if (self.tryIncreaseShadowCadenceScale()) {
                    self.light_work_stats.shadow_cadence_increased_lights += 1;
                }
                self.shadow_budget_pressure_frames = 0;
            }
            return;
        }

        const recovery_budget_percent = std.math.clamp(config.POST_SHADOW_ADAPTIVE_RECOVERY_BUDGET_PERCENT, 1, 100);
        const within_recovery_budget = (self.light_work_stats.shadow_build_ns * 100) <=
            (shadow_budget_ns * @as(i128, @intCast(recovery_budget_percent)));
        if (!within_recovery_budget) {
            self.shadow_budget_relief_frames = 0;
            return;
        }

        self.shadow_budget_relief_frames += 1;
        if (self.shadow_budget_relief_frames < config.POST_SHADOW_ADAPTIVE_RECOVERY_FRAMES) return;
        if (try self.tryUpscaleOneShadowMapLight()) {
            self.light_work_stats.shadow_map_upscaled_lights += 1;
        } else if (self.tryDecreaseShadowCadenceScale()) {
            self.light_work_stats.shadow_cadence_decreased_lights += 1;
        }
        self.shadow_budget_relief_frames = 0;
    }

    /// init initializes Renderer state and returns the configured value.
    pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
        var bitmap = try Bitmap.init(width, height);
        errdefer bitmap.deinit();
        const hdc_mem = CreateCompatibleDC(null) orelse return error.MemoryDCCreationFailed;
        errdefer _ = DeleteDC(hdc_mem);
        const hdc_mem_old_bitmap = SelectObject(hdc_mem, bitmap.hbitmap);
        var present_backend = try present_d3d11.Backend.init(hwnd, width, height);
        errdefer present_backend.deinit();
        const current_time = std.time.nanoTimestamp();
        const tile_grid = try TileGrid.init(width, height, allocator);

        const tile_buffers = try allocator.alloc(TileBuffer, tile_grid.tiles.len);
        errdefer allocator.free(tile_buffers);
        for (tile_buffers, tile_grid.tiles) |*buf, *tile| {
            buf.* = try TileBuffer.init(tile.width, tile.height, allocator);
        }

        const tile_count = tile_grid.tiles.len;
        const shadow_chunk_job_capacity = tile_count * 4;
        const shadow_tile_jobs_buffer = try allocator.alloc(AdaptiveShadowTileJob, tile_count);
        errdefer allocator.free(shadow_tile_jobs_buffer);
        const hybrid_shadow_tile_ranges = try allocator.alloc(HybridShadowTileRange, tile_count);
        errdefer allocator.free(hybrid_shadow_tile_ranges);
        const job_buffer = try allocator.alloc(Job, tile_count);
        errdefer allocator.free(job_buffer);
        const shadow_job_buffer = try allocator.alloc(Job, shadow_chunk_job_capacity);
        errdefer allocator.free(shadow_job_buffer);
        const composite_job_contexts = try allocator.alloc(CompositeJobContext, tile_count);
        errdefer allocator.free(composite_job_contexts);
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
        const tile_light_ranges = try allocator.alloc(TileLightRange, tile_count);
        errdefer allocator.free(tile_light_ranges);
        @memset(tile_light_ranges, .{});

        const job_system = try JobSystem.init(allocator);
        const color_grade_job_count = @max(@as(usize, 1), @as(usize, @intCast(job_system.worker_count * 2)));
        const color_grade_job_contexts = try allocator.alloc(ColorGradeJobContext, color_grade_job_count);
        errdefer allocator.free(color_grade_job_contexts);
        const moblur_job_contexts = try allocator.alloc(post_dispatch.MotionBlurJobContext, color_grade_job_count);
        errdefer allocator.free(moblur_job_contexts);
        const moblur_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(moblur_scratch_pixels);

        const god_rays_job_contexts = try allocator.alloc(post_dispatch.GodRaysJobContext, color_grade_job_count);
        errdefer allocator.free(god_rays_job_contexts);
        const god_rays_scratch_pixels = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(god_rays_scratch_pixels);

        const chromatic_aberration_job_contexts = try allocator.alloc(post_dispatch.ChromaticAberrationJobContext, color_grade_job_count);
        errdefer allocator.free(chromatic_aberration_job_contexts);

        const film_grain_job_contexts = try allocator.alloc(post_dispatch.FilmGrainVignetteJobContext, color_grade_job_count);
        errdefer allocator.free(film_grain_job_contexts);

        const lens_flare_job_contexts = try allocator.alloc(post_dispatch.LensFlareJobContext, color_grade_job_count);
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
        const scene_depth = try allocator.alignedAlloc(f32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_depth);
        const scene_camera = try allocator.alignedAlloc(math.Vec3, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_camera);
        const scene_normal = try allocator.alignedAlloc(math.Vec3, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_normal);
        const scene_surface = try allocator.alignedAlloc(TileRenderer.SurfaceHandle, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(scene_surface);
        const taa_history_pixels = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_pixels);
        const taa_resolve_pixels = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_resolve_pixels);
        const taa_history_depth = try allocator.alignedAlloc(f32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_depth);
        const taa_history_surface_tags = try allocator.alignedAlloc(u64, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        errdefer allocator.free(taa_history_surface_tags);
        const taa_history_normals = try allocator.alignedAlloc(u32, std.mem.Alignment.@"64", @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
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
            try lights.append(allocator, try initLightInfo(allocator, light_idx));
        }
        const light_dir_x = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_dir_x);
        const light_dir_y = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_dir_y);
        const light_dir_z = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_dir_z);
        const light_dir_cam_x = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_dir_cam_x);
        const light_dir_cam_y = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_dir_cam_y);
        const light_dir_cam_z = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_dir_cam_z);
        const light_distance = try allocator.alloc(f32, lights.items.len);
        errdefer allocator.free(light_distance);
        const light_shadow_mode = try allocator.alloc(u8, lights.items.len);
        errdefer allocator.free(light_shadow_mode);
        for (lights.items, 0..) |light, i| {
            light_dir_x[i] = light.direction.x;
            light_dir_y[i] = light.direction.y;
            light_dir_z[i] = light.direction.z;
            light_dir_cam_x[i] = light.direction.x;
            light_dir_cam_y[i] = light.direction.y;
            light_dir_cam_z[i] = light.direction.z;
            light_distance[i] = light.distance;
            light_shadow_mode[i] = @intFromEnum(light.shadow_mode);
        }
        const shadow_build_elapsed_ns = try allocator.alloc(i128, lights.items.len);
        errdefer allocator.free(shadow_build_elapsed_ns);
        @memset(shadow_build_elapsed_ns, 0);
        const shadow_resolve_elapsed_ns = try allocator.alloc(i128, lights.items.len);
        errdefer allocator.free(shadow_resolve_elapsed_ns);
        @memset(shadow_resolve_elapsed_ns, 0);
        const tile_light_index_capacity = @max(@as(usize, 1), tile_count * lights.items.len);
        const tile_light_indices = try allocator.alloc(usize, tile_light_index_capacity);
        errdefer allocator.free(tile_light_indices);
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

        const profile_capture_frame = try parseProfileCaptureFrame(allocator);
        const frame_pacing_timer = createFramePacingTimer();
        const configured_target_frame_time_ns = config.targetFrameTimeNs();
        const pacing_mode = frame_pacing.resolveMode(config.WINDOW_VSYNC, configured_target_frame_time_ns);

        if (config.WINDOW_VSYNC and configured_target_frame_time_ns > 0) {
            renderer_logger.warnSub(
                "pacing",
                "vsync=true with fps_limit={} keeps compositor pacing active; software cap is disabled",
                .{config.TARGET_FPS},
            );
        } else {
            renderer_logger.infoSub(
                "pacing",
                "mode={s} target_fps={} target_ms={d:.3}",
                .{
                    pacing_mode.label(),
                    config.TARGET_FPS,
                    if (configured_target_frame_time_ns > 0)
                        @as(f32, @floatFromInt(configured_target_frame_time_ns)) / 1_000_000.0
                    else
                        @as(f32, 0.0),
                },
            );
        }

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc_mem = hdc_mem,
            .hdc_mem_old_bitmap = hdc_mem_old_bitmap,
            .present_backend = present_backend,
            .allocator = allocator,
            .rotation_angle = 0,
            .rotation_x = 0,
            .camera_position = math.Vec3.new(0.0, 1.5, -5.0),
            .camera_move_speed = 6.0,
            .mouse_state = .{
                .sensitivity = config.CAMERA_MOUSE_SENSITIVITY,
            },
            .mouse_input = .{},
            .fps_body_state = .{},
            .lights = lights,
            .light_soa = .{
                .dir_x = light_dir_x,
                .dir_y = light_dir_y,
                .dir_z = light_dir_z,
                .dir_cam_x = light_dir_cam_x,
                .dir_cam_y = light_dir_cam_y,
                .dir_cam_z = light_dir_cam_z,
                .distance = light_distance,
                .shadow_mode = light_shadow_mode,
            },
            .shadow_build_elapsed_ns = shadow_build_elapsed_ns,
            .shadow_resolve_elapsed_ns = shadow_resolve_elapsed_ns,
            .sys_shadows = shadow_system.ShadowSystem.init(allocator),
            .camera_fov_deg = config.CAMERA_FOV_INITIAL,
            .keys_pressed = .{},
            .frame_count = 0,
            .total_frames_rendered = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .next_frame_time = current_time,
            .last_completed_frame_time = current_time,
            .current_frame_start_time = current_time,
            .current_fps = 0,
            .target_frame_time_ns = configured_target_frame_time_ns,
            .frame_pacing_timer = frame_pacing_timer,
            .last_brightness_min = 0,
            .last_brightness_max = 0,
            .last_brightness_avg = 0,
            .last_reported_fov_deg = config.CAMERA_FOV_INITIAL,
            .light_marker_visible_last_frame = true,
            .pending_fov_delta = 0.0,
            .profile_capture_frame = profile_capture_frame,
            .profile_capture_emitted = false,
            .tile_grid = tile_grid,
            .tile_buffers = tile_buffers,
            .single_texture_binding = .{null},
            .textures = &.{},
            .use_tiled_rendering = true,
            .job_system = job_system,
            .shadow_tile_jobs_buffer = shadow_tile_jobs_buffer,
            .job_buffer = job_buffer,
            .shadow_job_buffer = shadow_job_buffer,
            .composite_job_contexts = composite_job_contexts,
            .job_completion_buffer = job_completion_buffer,
            .tile_triangle_lists = tile_triangle_lists,
            .active_tile_flags = active_tile_flags,
            .active_tile_indices = active_tile_indices,
            .tile_light_ranges = tile_light_ranges,
            .tile_light_indices = tile_light_indices,
            .direct_backend = direct_backend.State.init(allocator),
            .present_state = present_state.State.init(width, height),
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
            .meshlet_ray_tests_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_chunk_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_chunk_pixels_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_chunk_active_rays_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_packet_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_packet_skipped_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_packet_active_lanes_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_packet_occluded_lanes_counter = std.atomic.Value(usize).init(0),
            .meshlet_shadow_trace_ns_counter = std.atomic.Value(u64).init(0),
            .meshlet_shadow_apply_ns_counter = std.atomic.Value(u64).init(0),
            .triangles_rasterized_counter = std.atomic.Value(usize).init(0),
            .covered_pixels_counter = std.atomic.Value(usize).init(0),
            .depth_tests_passed_counter = std.atomic.Value(usize).init(0),
            .alpha_pixels_counter = std.atomic.Value(usize).init(0),
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

    /// Parses p ar se pr of il ec ap tu re fr am e into typed runtime values.
    /// Validates inputs and applies fallback/default rules before exposing results to callers.
    fn parseProfileCaptureFrame(allocator: std.mem.Allocator) !u64 {
        const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_PROFILE_FRAME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return 0,
            else => return err,
        };
        defer allocator.free(raw_value);
        return std.fmt.parseUnsigned(u64, raw_value, 10) catch 0;
    }

    /// createFramePacingTimer creates a new value used by Renderer.
    fn createFramePacingTimer() ?windows.HANDLE {
        const desired_access = TIMER_MODIFY_STATE | SYNCHRONIZE_ACCESS;
        return CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, desired_access) orelse
            CreateWaitableTimerExW(null, null, 0, desired_access);
    }

    /// Cleans up all renderer resources in the reverse order of creation.
    pub fn deinit(self: *Renderer) void {
        renderer_logger.infoSub("shutdown", "deinitializing renderer frame_counter={}", .{self.frame_count});
        self.frame_pacing.exportCsv("artifacts/perf/frame_times.csv");
        self.direct_backend.deinit();
        self.sys_shadows.deinit();
        if (self.job_system) |js| js.deinit();
        if (self.job_buffer) |jobs| self.allocator.free(jobs);
        if (self.shadow_job_buffer) |jobs| self.allocator.free(jobs);
        if (self.composite_job_contexts) |ctxs| self.allocator.free(ctxs);
        if (self.shadow_tile_jobs_buffer) |shadow_jobs| self.allocator.free(shadow_jobs);
        if (self.job_completion_buffer) |completion| self.allocator.free(completion);
        if (self.tile_triangle_lists) |lists| BinningStage.freeTileTriangleLists(lists, self.allocator);
        if (self.active_tile_flags) |flags| self.allocator.free(flags);
        if (self.active_tile_indices) |indices| self.allocator.free(indices);
        self.allocator.free(self.tile_light_ranges);
        self.allocator.free(self.tile_light_indices);
        self.allocator.free(self.scene_depth);
        self.allocator.free(self.scene_camera);
        self.allocator.free(self.scene_normal);
        self.allocator.free(self.scene_surface);
        self.scene_item_gizmo.deinit(self.allocator);
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
        self.allocator.free(self.light_soa.dir_x);
        self.allocator.free(self.light_soa.dir_y);
        self.allocator.free(self.light_soa.dir_z);
        self.allocator.free(self.light_soa.dir_cam_x);
        self.allocator.free(self.light_soa.dir_cam_y);
        self.allocator.free(self.light_soa.dir_cam_z);
        self.allocator.free(self.light_soa.distance);
        self.allocator.free(self.light_soa.shadow_mode);
        self.allocator.free(self.shadow_build_elapsed_ns);
        self.allocator.free(self.shadow_resolve_elapsed_ns);
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
        self.present_backend.deinit();
        if (self.hdc_mem) |hdc_mem| {
            if (self.hdc_mem_old_bitmap) |old_bitmap| {
                _ = SelectObject(hdc_mem, old_bitmap);
            }
            _ = DeleteDC(hdc_mem);
        }
        if (self.frame_pacing_timer) |timer| _ = windows.CloseHandle(timer);
    }

    const FrameExecutionContext = struct {
        renderer: *Renderer,
        mesh: *const Mesh,
        view_rotation: math.Mat4,
        light_dir: math.Vec3,
        pump: ?*const fn (*Renderer) bool,
        raster_projection: ProjectionParams,
        is_editor_mode: bool,
        light_camera: math.Vec3,
        center_x: f32,
        center_y: f32,
        x_scale: f32,
        y_scale: f32,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        taa_view: TemporalAAViewState,
        shadow_map_light_count: usize,
        light_dir_world: math.Vec3,
        cache_projection: ProjectionParams,
    };

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

    // ====== input/gizmo/scene-item/camera setter handlers (impl in renderer/input.zig) ======
    pub const handleKeyInput = renderer_input.handleKeyInput;
    pub const isFirstPersonMode = renderer_input.isFirstPersonMode;
    pub const isSceneItemDragActive = renderer_input.isSceneItemDragActive;
    pub const setSceneCameraScriptActive = renderer_input.setSceneCameraScriptActive;
    pub const applyCameraModeCommand = renderer_input.applyCameraModeCommand;
    pub const toggleSceneItemGizmo = renderer_input.toggleSceneItemGizmo;
    pub const toggleLightGizmo = renderer_input.toggleLightGizmo;
    pub const setActiveGizmoAxis = renderer_input.setActiveGizmoAxis;
    pub const cycleLightGizmoSelection = renderer_input.cycleLightGizmoSelection;
    pub const nudgeActiveGizmo = renderer_input.nudgeActiveGizmo;
    pub const toggleRenderOverlay = renderer_input.toggleRenderOverlay;
    pub const toggleHybridShadowDebug = renderer_input.toggleHybridShadowDebug;
    pub const advanceHybridShadowDebug = renderer_input.advanceHybridShadowDebug;
    pub const handleMouseMove = renderer_input.handleMouseMove;
    pub const handleRawMouseDelta = renderer_input.handleRawMouseDelta;
    pub const handleMouseLeftClick = renderer_input.handleMouseLeftClick;
    pub const handleMouseLeftRelease = renderer_input.handleMouseLeftRelease;
    pub const handleMouseRightClick = renderer_input.handleMouseRightClick;
    pub const handleMouseRightRelease = renderer_input.handleMouseRightRelease;
    pub const handleFocusLost = renderer_input.handleFocusLost;
    pub const handleFocusGained = renderer_input.handleFocusGained;
    pub const desiredCursorStyle = renderer_input.desiredCursorStyle;
    pub const setSceneItemBindings = renderer_input.setSceneItemBindings;
    pub const notifySceneItemTranslated = renderer_input.notifySceneItemTranslated;
    pub const setSceneItemCenter = renderer_input.setSceneItemCenter;
    pub const consumeSceneItemTranslateRequest = renderer_input.consumeSceneItemTranslateRequest;
    pub const selectedSceneItemSelectionId = renderer_input.selectedSceneItemSelectionId;
    pub const setCameraPosition = renderer_input.setCameraPosition;
    pub const setCameraOrientation = renderer_input.setCameraOrientation;
    pub const setCameraFov = renderer_input.setCameraFov;
    pub const setPresentSize = renderer_input.setPresentSize;
    pub const setPresentMinimized = renderer_input.setPresentMinimized;

    pub fn lastDirectFrameTimings(self: *const Renderer) direct_backend.FrameTimings {
        return self.direct_backend.lastTimings();
    }

    /// Marks cached/derived data stale so it is recomputed on the next usage.
    pub fn invalidateMeshDerivedCaches(self: *Renderer) void {
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

    pub const ResizeStateSnapshot = struct {
        camera_position: math.Vec3,
        camera_pitch: f32,
        camera_yaw: f32,
        camera_fov_deg: f32,
        camera_control_mode: CameraControlMode,
        scene_camera_script_active: bool,
        show_tile_borders: bool,
        show_wireframe: bool,
        show_light_orb: bool,
        cull_light_orb: bool,
        use_tiled_rendering: bool,
        show_frame_pacing_overlay: bool,
        show_render_overlay: bool,
        present_minimized: bool,
    };

    pub fn recreateForPresentSize(self: *Renderer, present_width: i32, present_height: i32, saved: ResizeStateSnapshot) !void {
        const scale_percent: i32 = @intCast(@max(config.RENDER_RESOLUTION_SCALE_PERCENT, 1));
        const render_width = @max(1, @divTrunc(present_width * scale_percent, 100));
        const render_height = @max(1, @divTrunc(present_height * scale_percent, 100));

        if (self.bitmap.width == render_width and self.bitmap.height == render_height) {
            self.present_state.applyResize(present_width, present_height);
            return;
        }

        renderer_logger.infoSub("resize", "recreating renderer surfaces present={d}x{d} render={d}x{d}", .{
            present_width,
            present_height,
            render_width,
            render_height,
        });

        var replacement = try Renderer.init(self.hwnd, render_width, render_height, self.allocator);
        errdefer replacement.deinit();

        replacement.setCameraPosition(saved.camera_position);
        replacement.setCameraOrientation(saved.camera_pitch, saved.camera_yaw);
        replacement.setCameraFov(saved.camera_fov_deg);
        replacement.camera_control_mode = saved.camera_control_mode;
        replacement.scene_camera_script_active = saved.scene_camera_script_active;
        replacement.show_tile_borders = saved.show_tile_borders;
        replacement.show_wireframe = saved.show_wireframe;
        replacement.show_light_orb = saved.show_light_orb;
        replacement.cull_light_orb = saved.cull_light_orb;
        replacement.use_tiled_rendering = saved.use_tiled_rendering;
        replacement.show_frame_pacing_overlay = saved.show_frame_pacing_overlay;
        replacement.show_render_overlay = saved.show_render_overlay;
        replacement.present_state.applyResize(present_width, present_height);
        replacement.present_state.setMinimized(saved.present_minimized);

        var old = self.*;
        self.* = replacement;
        old.deinit();
    }

    /// Performs capture temporal mesh state.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
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

    fn consumeMouseDelta(self: *Renderer, frame_dt_seconds: f32) math.Vec2 {
        return camera_controller.consumeLookDelta(&self.mouse_state, self.camera_control_mode, frame_dt_seconds);
    }

    pub fn consumeSceneCameraLookDelta(self: *Renderer, frame_dt_seconds: f32) math.Vec2 {
        return camera_runtime.consumeSceneCameraLookDelta(self, frame_dt_seconds);
    }

    fn effectiveMouseSensitivity(self: *const Renderer) f32 {
        return camera_controller.effectiveSensitivity(&self.mouse_state);
    }

    const PointerViewState = struct {
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        projection: ProjectionParams,
    };

    /// Computes pointer view state.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn computePointerViewState(self: *const Renderer) PointerViewState {
        const basis = camera_controller.computeViewBasis(self.rotation_angle, self.rotation_x);
        const projection = camera_controller.computeProjectionScalars(self.bitmap.width, self.bitmap.height, self.camera_fov_deg);
        return .{
            .right = basis.right,
            .up = basis.up,
            .forward = basis.forward,
            .projection = .{
                .center_x = projection.center_x,
                .center_y = projection.center_y,
                .x_scale = projection.x_scale,
                .y_scale = projection.y_scale,
                .near_plane = NEAR_CLIP,
                .jitter_x = 0.0,
                .jitter_y = 0.0,
            },
        };
    }

    pub fn clearLightGizmoInteraction(self: *Renderer) void {
        self.light_gizmo.hover_axis = null;
        self.light_gizmo.drag_axis = null;
        self.light_gizmo.drag_last_pointer = null;
    }

    pub fn mapWindowPointToBackbuffer(self: *const Renderer, window_x: i32, window_y: i32) ?windows.POINT {
        if (window_x < 0 or window_y < 0) return null;
        if (self.bitmap.width <= 0 or self.bitmap.height <= 0) return null;
        const window_width: i32 = @intCast(config.WINDOW_WIDTH);
        const window_height: i32 = @intCast(config.WINDOW_HEIGHT);
        if (window_width <= 0 or window_height <= 0) return null;
        if (window_x >= window_width or window_y >= window_height) return null;

        const x_scale = @as(f32, @floatFromInt(self.bitmap.width)) / @as(f32, @floatFromInt(window_width));
        const y_scale = @as(f32, @floatFromInt(self.bitmap.height)) / @as(f32, @floatFromInt(window_height));
        const mapped_x = std.math.clamp(
            @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(window_x)) * x_scale))),
            0,
            self.bitmap.width - 1,
        );
        const mapped_y = std.math.clamp(
            @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(window_y)) * y_scale))),
            0,
            self.bitmap.height - 1,
        );
        return .{ .x = mapped_x, .y = mapped_y };
    }

    fn lightGizmoAxisEndpoint(origin: math.Vec3, axis: LightGizmoAxis, axis_extent: f32) math.Vec3 {
        return math.Vec3.add(origin, math.Vec3.scale(lightGizmoAxisUnit(axis), axis_extent));
    }

    fn distancePointToSegment2D(point: math.Vec2, seg_a: math.Vec2, seg_b: math.Vec2) f32 {
        const ab = math.Vec2.sub(seg_b, seg_a);
        const ap = math.Vec2.sub(point, seg_a);
        const ab_len_sq = ab.x * ab.x + ab.y * ab.y;
        if (ab_len_sq <= 1e-6) {
            const dx = point.x - seg_a.x;
            const dy = point.y - seg_a.y;
            return @sqrt(dx * dx + dy * dy);
        }
        const t = std.math.clamp((ap.x * ab.x + ap.y * ab.y) / ab_len_sq, 0.0, 1.0);
        const closest = math.Vec2.new(seg_a.x + ab.x * t, seg_a.y + ab.y * t);
        const dx = point.x - closest.x;
        const dy = point.y - closest.y;
        return @sqrt(dx * dx + dy * dy);
    }

    fn lightGizmoOriginWorld(self: *Renderer) ?math.Vec3 {
        if (!self.light_gizmo.enabled or self.lights.items.len == 0) return null;
        self.clampLightGizmoSelection();
        const light = self.lights.items[self.light_gizmo.selected_light_index];
        return math.Vec3.scale(light.direction, light.distance);
    }

    fn hoverLightGizmoAxisAtPointer(self: *Renderer, pointer: math.Vec2, pointer_view: PointerViewState) ?LightGizmoAxis {
        const origin_world = self.lightGizmoOriginWorld() orelse return null;
        const origin_screen = self.projectWorldToScreen(
            self.camera_position,
            pointer_view.right,
            pointer_view.up,
            pointer_view.forward,
            pointer_view.projection,
            origin_world,
        ) orelse return null;
        const origin_v = math.Vec2.new(@floatFromInt(origin_screen[0]), @floatFromInt(origin_screen[1]));
        const light = self.lights.items[self.light_gizmo.selected_light_index];
        const axis_extent = std.math.clamp(light.distance * 0.18, 0.3, 1.25);

        var best_axis: ?LightGizmoAxis = null;
        var best_dist: f32 = 8.0;
        for ([_]LightGizmoAxis{ .x, .y, .z }) |axis| {
            const endpoint_world = lightGizmoAxisEndpoint(origin_world, axis, axis_extent);
            const endpoint_screen = self.projectWorldToScreen(
                self.camera_position,
                pointer_view.right,
                pointer_view.up,
                pointer_view.forward,
                pointer_view.projection,
                endpoint_world,
            ) orelse continue;
            const endpoint_v = math.Vec2.new(@floatFromInt(endpoint_screen[0]), @floatFromInt(endpoint_screen[1]));
            const dist = distancePointToSegment2D(pointer, origin_v, endpoint_v);
            if (dist <= best_dist) {
                best_dist = dist;
                best_axis = axis;
            }
        }
        return best_axis;
    }

    /// Computes light gizmo drag delta.
    /// Keeps compute light gizmo drag delta as the single implementation point so call-site behavior stays consistent.
    fn computeLightGizmoDragDelta(
        self: *Renderer,
        axis: LightGizmoAxis,
        prev: math.Vec2,
        current: math.Vec2,
        pointer_view: PointerViewState,
    ) f32 {
        const origin_world = self.lightGizmoOriginWorld() orelse return 0.0;
        const light = self.lights.items[self.light_gizmo.selected_light_index];
        const axis_extent = std.math.clamp(light.distance * 0.18, 0.3, 1.25);
        const endpoint_world = lightGizmoAxisEndpoint(origin_world, axis, axis_extent);
        const origin_screen = self.projectWorldToScreen(
            self.camera_position,
            pointer_view.right,
            pointer_view.up,
            pointer_view.forward,
            pointer_view.projection,
            origin_world,
        ) orelse return 0.0;
        const endpoint_screen = self.projectWorldToScreen(
            self.camera_position,
            pointer_view.right,
            pointer_view.up,
            pointer_view.forward,
            pointer_view.projection,
            endpoint_world,
        ) orelse return 0.0;
        const origin_v = math.Vec2.new(@floatFromInt(origin_screen[0]), @floatFromInt(origin_screen[1]));
        const endpoint_v = math.Vec2.new(@floatFromInt(endpoint_screen[0]), @floatFromInt(endpoint_screen[1]));
        const axis_screen = math.Vec2.sub(endpoint_v, origin_v);
        const axis_screen_len = @sqrt(axis_screen.x * axis_screen.x + axis_screen.y * axis_screen.y);
        if (axis_screen_len < 1.0) return 0.0;
        const axis_dir = math.Vec2.new(axis_screen.x / axis_screen_len, axis_screen.y / axis_screen_len);
        const mouse_delta = math.Vec2.sub(current, prev);
        const pixels_along_axis = mouse_delta.x * axis_dir.x + mouse_delta.y * axis_dir.y;
        return pixels_along_axis * (axis_extent / axis_screen_len);
    }

    /// updateLightGizmoPointer updates Renderer state for the current tick/frame.
    pub fn updateLightGizmoPointer(self: *Renderer, pointer: math.Vec2, pointer_view: PointerViewState) void {
        if (!self.light_gizmo.enabled or self.lights.items.len == 0) {
            self.clearLightGizmoInteraction();
            return;
        }
        if (self.scene_item_gizmo.isDragging() and self.light_gizmo.drag_axis == null) {
            self.light_gizmo.hover_axis = null;
            return;
        }
        if (self.light_gizmo.drag_axis) |axis| {
            if (self.light_gizmo.drag_last_pointer) |prev| {
                const delta = self.computeLightGizmoDragDelta(axis, prev, pointer, pointer_view);
                if (@abs(delta) > 1e-6) {
                    self.light_gizmo.active_axis = axis;
                    self.moveSelectedLightAlongAxis(delta);
                }
            }
            self.light_gizmo.drag_last_pointer = pointer;
            self.light_gizmo.hover_axis = axis;
            return;
        }
        self.light_gizmo.hover_axis = self.hoverLightGizmoAxisAtPointer(pointer, pointer_view);
    }

    /// Begins an operation and captures temporary context used until completion.
    /// It marks the start of an operation and prepares transient state used until completion.
    pub fn beginLightGizmoDrag(self: *Renderer, window_x: i32, window_y: i32, pointer_view: PointerViewState) bool {
        if (!self.light_gizmo.enabled or self.lights.items.len == 0) return false;
        const mapped = self.mapWindowPointToBackbuffer(window_x, window_y) orelse return false;
        const pointer = math.Vec2.new(
            @as(f32, @floatFromInt(mapped.x)),
            @as(f32, @floatFromInt(mapped.y)),
        );
        const hovered = self.hoverLightGizmoAxisAtPointer(pointer, pointer_view) orelse return false;
        self.light_gizmo.active_axis = hovered;
        self.light_gizmo.hover_axis = hovered;
        self.light_gizmo.drag_axis = hovered;
        self.light_gizmo.drag_last_pointer = pointer;
        return true;
    }

    /// Returns whether s ho ul dr en de rf ra me.
    /// The check is side-effect free so callers can gate expensive follow-up work cheaply.
    pub fn shouldRenderFrame(self: *Renderer) bool {
        const now = std.time.nanoTimestamp();
        return frame_pacing.shouldRender(self.currentPacingMode(), self.next_frame_time, now);
    }

    /// renderLoadingOverlayFrame renders Renderer output.
    pub fn renderLoadingOverlayFrame(self: *Renderer, pump: ?*const fn (*Renderer) bool) bool {
        if (pump) |pump_fn| {
            if (!pump_fn(self)) return false;
        }
        if (!self.shouldRenderFrame()) {
            self.waitUntilNextFrame();
            return true;
        }

        @memset(self.bitmap.pixels, 0xFF0A1017);
        self.drawBitmap();

        const now = std.time.nanoTimestamp();
        self.notePresentedFrame(now);
        self.finalizeFrame(now);
        return true;
    }

    pub fn renderMinimalPrimitiveFrame(self: *Renderer, pump: ?*const fn (*Renderer) bool) !void {
        if (pump) |pump_fn| {
            if (!pump_fn(self)) return error.RenderInterrupted;
        }

        const now = std.time.nanoTimestamp();
        self.current_frame_start_time = now;
        try self.renderDirectPrimitiveShowcase();
        const present = try self.presentFrame(true);
        self.direct_backend.notePresentTime(present.present_ns);
        self.notePresentedFrame(std.time.nanoTimestamp());
        self.finalizeFrame(std.time.nanoTimestamp());
    }

    fn presentFrame(self: *Renderer, use_direct_dirty_rect: bool) !presentation_stage.Result {
        if (self.hdc_mem) |hdc_mem| {
            if (self.show_render_overlay or self.hybrid_shadow_debug.enabled or self.scene_item_gizmo.enabled or self.loading_overlay.enabled) {
                self.drawRenderPassOverlay(hdc_mem);
            }
            if (self.show_frame_pacing_overlay) {
                self.drawFramePacingPanel(hdc_mem);
            }
        }
        return presentation_stage.execute(
            &self.present_backend,
            &self.present_state,
            &self.bitmap,
            config.WINDOW_VSYNC,
            if (use_direct_dirty_rect)
                if (self.direct_backend.lastDirtyRect()) |rect| .{
                    .min_x = rect.min_x,
                    .min_y = rect.min_y,
                    .max_x = rect.max_x,
                    .max_y = rect.max_y,
                } else null
            else
                null,
        ) catch .{};
    }

    /// Moves data for copy text truncate.
    /// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
    fn copyTextTruncate(dest: []u8, src: []const u8) usize {
        const copy_len = @min(dest.len, src.len);
        if (copy_len > 0) std.mem.copyForwards(u8, dest[0..copy_len], src[0..copy_len]);
        return copy_len;
    }

    /// Begins an operation and captures temporary context used until completion.
    /// It marks the start of an operation and prepares transient state used until completion.
    pub fn beginSceneLoadingOverlay(self: *Renderer, scene_key: []const u8, total_steps: usize) void {
        self.loading_overlay.enabled = true;
        self.loading_overlay.total_steps = @max(@as(usize, 1), total_steps);
        self.loading_overlay.completed_steps = 0;
        self.loading_overlay.progress = 0.0;
        self.loading_overlay.spinner_tick = 0;
        self.loading_overlay.scene_text_len = copyTextTruncate(&self.loading_overlay.scene_text_buf, scene_key);
        self.loading_overlay.phase_text_len = copyTextTruncate(&self.loading_overlay.phase_text_buf, "Preparing assets...");
    }

    /// updateSceneLoadingOverlay updates Renderer state for the current tick/frame.
    pub fn updateSceneLoadingOverlay(self: *Renderer, completed_steps: usize, total_steps: usize, phase: []const u8) void {
        if (!self.loading_overlay.enabled) return;
        const resolved_total = @max(@as(usize, 1), total_steps);
        const resolved_completed = @min(completed_steps, resolved_total);
        self.loading_overlay.total_steps = resolved_total;
        self.loading_overlay.completed_steps = resolved_completed;
        self.loading_overlay.progress = @as(f32, @floatFromInt(resolved_completed)) / @as(f32, @floatFromInt(resolved_total));
        self.loading_overlay.phase_text_len = copyTextTruncate(&self.loading_overlay.phase_text_buf, phase);
        self.loading_overlay.spinner_tick +%= 1;
    }

    /// Finalizes the current operation and commits or clears temporary state.
    /// It finalizes an in-flight operation and commits/clears temporary state.
    pub fn endSceneLoadingOverlay(self: *Renderer) void {
        self.loading_overlay.enabled = false;
        self.loading_overlay.progress = 0.0;
        self.loading_overlay.completed_steps = 0;
        self.loading_overlay.total_steps = 1;
        self.loading_overlay.scene_text_len = 0;
        self.loading_overlay.phase_text_len = 0;
    }

    fn currentPacingMode(self: *const Renderer) frame_pacing_hud.Mode {
        return frame_pacing.resolveMode(config.WINDOW_VSYNC, self.target_frame_time_ns);
    }

    fn usesSoftwareFramePacing(self: *const Renderer) bool {
        return frame_pacing.usesSoftwarePacing(self.currentPacingMode());
    }

    fn effectiveFramePacingTargetNs(self: *const Renderer) i128 {
        return frame_pacing.effectiveTargetNs(self.currentPacingMode(), self.target_frame_time_ns);
    }

    fn waitWithFramePacingTimer(self: *Renderer, sleep_ns: i128) bool {
        const timer = self.frame_pacing_timer orelse return false;
        if (sleep_ns <= 0) return false;

        const relative_100ns = @max(@as(i128, 1), @divTrunc(sleep_ns, 100));
        const due_time: i64 = -@as(i64, @intCast(relative_100ns));
        if (SetWaitableTimerEx(timer, &due_time, 0, null, null, null, 0) == 0) return false;
        windows.WaitForSingleObject(timer, windows.INFINITE) catch return false;
        return true;
    }

    fn framePacingCoarseThresholdNs(self: *const Renderer) i128 {
        return frame_pacing.coarseThresholdNs(self.target_frame_time_ns);
    }

    fn framePacingRequestedSleepNs(self: *const Renderer, remaining_ns: i128) i128 {
        return frame_pacing.requestedSleepNs(self.target_frame_time_ns, self.frame_pacing_sleep_bias_ns, remaining_ns);
    }

    /// updateFramePacingSleepBias updates Renderer state for the current tick/frame.
    fn updateFramePacingSleepBias(self: *Renderer, requested_sleep_ns: i128, actual_wait_ns: i128) void {
        self.frame_pacing_sleep_bias_ns = frame_pacing.updateSleepBias(
            self.frame_pacing_sleep_bias_ns,
            requested_sleep_ns,
            actual_wait_ns,
        );
    }

    /// Performs wait until next frame.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn waitUntilNextFrame(self: *Renderer) void {
        if (!self.usesSoftwareFramePacing()) return;

        const wait_start = std.time.nanoTimestamp();
        const coarse_threshold_ns = self.framePacingCoarseThresholdNs();

        while (true) {
            const now = std.time.nanoTimestamp();
            const remaining_ns = self.next_frame_time - now;
            if (remaining_ns <= 0) {
                self.pending_software_wait_ns += std.time.nanoTimestamp() - wait_start;
                return;
            }

            if (remaining_ns > coarse_threshold_ns) {
                const sleep_ns = self.framePacingRequestedSleepNs(remaining_ns);
                if (sleep_ns > 0) {
                    const sleep_begin = std.time.nanoTimestamp();
                    if (!self.waitWithFramePacingTimer(sleep_ns)) {
                        const sleep_ms = @max(@as(i128, 1), @divTrunc(sleep_ns, 1_000_000));
                        Sleep(@intCast(sleep_ms));
                    }
                    const sleep_end = std.time.nanoTimestamp();
                    self.updateFramePacingSleepBias(sleep_ns, @max(sleep_end - sleep_begin, @as(i128, 0)));
                    continue;
                } else {
                    self.frame_pacing_sleep_bias_ns = frame_pacing.decaySleepBias(self.frame_pacing_sleep_bias_ns);
                }
            }

            std.atomic.spinLoopHint();
        }
    }

    fn advanceFrameDeadline(self: *Renderer, now_ns: i128) void {
        self.next_frame_time = frame_pacing.advanceDeadline(
            self.currentPacingMode(),
            self.next_frame_time,
            self.target_frame_time_ns,
            now_ns,
        );
    }

    fn notePresentedFrame(self: *Renderer, current_time: i128) void {
        self.frame_count += 1;
        self.total_frames_rendered += 1;
        self.last_completed_frame_time = current_time;
        self.active_software_wait_ns = 0;
        self.advanceFrameDeadline(current_time);
    }

    /// Handles handle char input.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn handleCharInput(self: *Renderer, char_code: u32) void {
        _ = self;
        _ = char_code;
    }

    pub fn setCameraControlMode(self: *Renderer, next_mode: CameraControlMode) void {
        if (!camera_runtime.setCameraControlMode(self, next_mode)) return;
        renderer_logger.infoSub(
            "camera_mode",
            "mode={s}",
            .{if (self.camera_control_mode == .first_person) "first_person" else "editor"},
        );
    }

    /// Clamps light gizmo selection to a valid range for downstream code.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn clampLightGizmoSelection(self: *Renderer) void {
        if (self.lights.items.len == 0) {
            self.light_gizmo.selected_light_index = 0;
            self.clearLightGizmoInteraction();
            return;
        }
        if (self.light_gizmo.selected_light_index >= self.lights.items.len) {
            self.light_gizmo.selected_light_index = self.lights.items.len - 1;
        }
    }

    pub fn moveSelectedLightAlongAxis(self: *Renderer, delta: f32) void {
        if (self.lights.items.len == 0) return;
        self.clampLightGizmoSelection();
        const light_index = self.light_gizmo.selected_light_index;
        const light = self.lights.items[light_index];

        var light_position = math.Vec3.scale(light.direction, light.distance);
        switch (self.light_gizmo.active_axis) {
            .x => light_position.x += delta,
            .y => light_position.y += delta,
            .z => light_position.z += delta,
        }

        const updated_distance = @max(@as(f32, 0.01), math.Vec3.length(light_position));
        self.setDirectionalLight(light_index, light_position, updated_distance, null);
    }

    pub const SceneItemGizmoDrawContext = struct {
        renderer: *Renderer,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    };

    /// projectSceneItemWorld projects coordinates for Renderer calculations.
    pub fn projectSceneItemWorld(ctx_ptr: *anyopaque, world_position: math.Vec3) ?[2]i32 {
        const ctx: *const SceneItemGizmoDrawContext = @ptrCast(@alignCast(ctx_ptr));
        return ctx.renderer.projectWorldToScreen(
            ctx.camera_position,
            ctx.basis_right,
            ctx.basis_up,
            ctx.basis_forward,
            ctx.projection,
            world_position,
        );
    }

    fn drawSceneItemGizmoLine(ctx_ptr: *anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        const ctx: *SceneItemGizmoDrawContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.drawLineColored(x0, y0, x1, y1, color);
    }

    /// Sets s et te xt ur e.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setTexture(self: *Renderer, tex: *const texture.Texture) void {
        self.single_texture_binding[0] = tex;
        self.textures = self.single_texture_binding[0..];
    }

    /// Sets s et hd ri ma p.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setHdriMap(self: *Renderer, hdri_map: texture.HdrTexture) void {
        self.hdri_map = hdri_map;
    }

    /// Sets s et te xt ur es.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setTextures(self: *Renderer, textures: []const ?*const texture.Texture) void {
        self.textures = textures;
    }

    /// Sets s et li gh tc ap ac it y.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setLightCapacity(self: *Renderer, light_count: usize) !void {
        const requested_count = @max(@as(usize, 1), light_count);
        const light_count_max = @max(config.LIGHT_COUNT_MIN, config.LIGHT_COUNT_MAX);
        const desired_count = std.math.clamp(requested_count, config.LIGHT_COUNT_MIN, light_count_max);
        if (desired_count != requested_count) {
            renderer_logger.infoSub(
                "lights",
                "clamped requested light capacity {} to {} (min={}, max={})",
                .{ requested_count, desired_count, config.LIGHT_COUNT_MIN, light_count_max },
            );
        }
        if (desired_count > self.shadow_build_elapsed_ns.len) {
            const prev_len = self.shadow_build_elapsed_ns.len;
            self.shadow_build_elapsed_ns = try self.allocator.realloc(self.shadow_build_elapsed_ns, desired_count);
            @memset(self.shadow_build_elapsed_ns[prev_len..], 0);
        }
        if (desired_count > self.shadow_resolve_elapsed_ns.len) {
            const prev_len = self.shadow_resolve_elapsed_ns.len;
            self.shadow_resolve_elapsed_ns = try self.allocator.realloc(self.shadow_resolve_elapsed_ns, desired_count);
            @memset(self.shadow_resolve_elapsed_ns[prev_len..], 0);
        }
        if (desired_count > self.light_soa.distance.len) {
            self.light_soa.dir_x = try self.allocator.realloc(self.light_soa.dir_x, desired_count);
            self.light_soa.dir_y = try self.allocator.realloc(self.light_soa.dir_y, desired_count);
            self.light_soa.dir_z = try self.allocator.realloc(self.light_soa.dir_z, desired_count);
            self.light_soa.dir_cam_x = try self.allocator.realloc(self.light_soa.dir_cam_x, desired_count);
            self.light_soa.dir_cam_y = try self.allocator.realloc(self.light_soa.dir_cam_y, desired_count);
            self.light_soa.dir_cam_z = try self.allocator.realloc(self.light_soa.dir_cam_z, desired_count);
            self.light_soa.distance = try self.allocator.realloc(self.light_soa.distance, desired_count);
            self.light_soa.shadow_mode = try self.allocator.realloc(self.light_soa.shadow_mode, desired_count);
        }
        const tile_count = self.tile_light_ranges.len;
        const tile_light_capacity = @max(@as(usize, 1), tile_count * desired_count);
        if (tile_light_capacity > self.tile_light_indices.len) {
            self.tile_light_indices = try self.allocator.realloc(self.tile_light_indices, tile_light_capacity);
        }
        while (self.lights.items.len > desired_count) {
            const remove_index = self.lights.items.len - 1;
            const removed = self.lights.items[remove_index];
            self.allocator.free(removed.shadow_map.depth);
            self.lights.items.len = remove_index;
        }
        while (self.lights.items.len < desired_count) {
            const light_idx = self.lights.items.len;
            try self.lights.append(self.allocator, try initLightInfo(self.allocator, light_idx));
        }
        var min_shadow_size: usize = config.POST_SHADOW_MAP_SIZE;
        var max_shadow_size: usize = config.POST_SHADOW_MAP_SIZE;
        if (self.lights.items.len > 0) {
            min_shadow_size = self.lights.items[0].shadow_map.width;
            max_shadow_size = self.lights.items[0].shadow_map.width;
            for (self.lights.items[1..]) |light| {
                min_shadow_size = @min(min_shadow_size, light.shadow_map.width);
                max_shadow_size = @max(max_shadow_size, light.shadow_map.width);
            }
        }
        const total_shadow_bytes = self.totalShadowMapBytes();
        const should_log_light_capacity = !self.light_capacity_log_initialized or
            self.last_logged_light_capacity != self.lights.items.len or
            self.last_logged_min_shadow_size != min_shadow_size or
            self.last_logged_max_shadow_size != max_shadow_size or
            self.last_logged_total_shadow_bytes != total_shadow_bytes;
        if (should_log_light_capacity) {
            renderer_logger.infoSub(
                "lights",
                "capacity={} shadow_map_range={}..{} total_shadow_mem={d:.2} MiB",
                .{
                    self.lights.items.len,
                    min_shadow_size,
                    max_shadow_size,
                    @as(f64, @floatFromInt(total_shadow_bytes)) / (1024.0 * 1024.0),
                },
            );
            self.light_capacity_log_initialized = true;
            self.last_logged_light_capacity = self.lights.items.len;
            self.last_logged_min_shadow_size = min_shadow_size;
            self.last_logged_max_shadow_size = max_shadow_size;
            self.last_logged_total_shadow_bytes = total_shadow_bytes;
        }
        self.syncLightSoA();
        self.frame_view_cache.invalidate();
    }

    /// Sets s et di re ct io na ll ig ht.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setDirectionalLight(self: *Renderer, index: usize, direction: math.Vec3, distance: f32, color: ?math.Vec3) void {
        if (index >= self.lights.items.len) return;
        const dir_len = math.Vec3.length(direction);
        const normalized = if (dir_len > 1e-6)
            math.Vec3.scale(direction, 1.0 / dir_len)
        else
            math.Vec3.new(0.0, 1.0, 0.0);
        self.lights.items[index].direction = normalized;
        self.lights.items[index].distance = @max(distance, 0.01);
        if (color) |c| self.lights.items[index].color = c;
        self.lights.items[index].manual_direction = true;
        self.lights.items[index].shadow_map.active = false;
        self.lights.items[index].shadow_last_build_frame = 0;
        self.lights.items[index].shadow_last_build_ns = 0;
        if (index < self.shadow_build_elapsed_ns.len) self.shadow_build_elapsed_ns[index] = 0;
        if (index < self.shadow_resolve_elapsed_ns.len) self.shadow_resolve_elapsed_ns[index] = 0;
        self.syncLightSoA();
        self.frame_view_cache.invalidate();
    }

    /// Sets s et li gh ts ha do wm od e.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setLightShadowMode(self: *Renderer, index: usize, mode: LightInfo.ShadowMode) void {
        if (index >= self.lights.items.len) return;
        self.lights.items[index].shadow_mode = mode;
        self.light_soa.shadow_mode[index] = @intFromEnum(mode);
    }

    /// Sets s et li gh ts ha do wu pd at ei nt er va l.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setLightShadowUpdateInterval(self: *Renderer, index: usize, interval_frames: u32) void {
        if (index >= self.lights.items.len) return;
        self.lights.items[index].shadow_update_interval_frames = @max(@as(u32, 1), interval_frames);
        self.lights.items[index].shadow_dynamic_interval_scale = 1;
    }

    /// Sets s et li gh ts ha do wm ap si ze.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setLightShadowMapSize(self: *Renderer, index: usize, shadow_map_size: usize) !void {
        _ = try self.resizeLightShadowMap(index, shadow_map_size, true, "config");
    }

    /// Sets s et li gh tg lo w.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn setLightGlow(self: *Renderer, index: usize, radius: f32, intensity: f32) void {
        if (index >= self.lights.items.len) return;
        self.lights.items[index].glow_radius = std.math.clamp(radius, 0.0, 256.0);
        self.lights.items[index].glow_intensity = std.math.clamp(intensity, 0.0, 8.0);
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

        const sweep_half_angle = std.math.pi / 2.0;
        for (self.lights.items) |*light| {
            if (!light.manual_direction) {
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
        }
        self.syncLightSoA();
        const light_distance_0 = if (self.lights.items.len > 0) self.light_soa.distance[0] else 10.0;
        const light_dir_world = if (self.lights.items.len > 0)
            math.Vec3.new(self.light_soa.dir_x[0], self.light_soa.dir_y[0], self.light_soa.dir_z[0])
        else
            math.Vec3.new(0, -1, 0);
        camera_runtime.prepareCameraForFrame(self, delta_seconds, simulation_delta_seconds, light_dir_world, light_distance_0);
        const right = self.frame_view_cache.state.right;
        const up = self.frame_view_cache.state.up;
        const forward = self.frame_view_cache.state.forward;

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
        if (config.POST_TAA_ENABLED) try self.ensureTemporalMeshVertexCapacity(mesh.vertices.len);
        const shadow_map_light_count = if (config.POST_SHADOW_ENABLED)
            self.countLightsWithShadowMode(.shadow_map)
        else
            0;
        const meshlet_shadow_light_count = if (config.MESHLET_SHADOWS_ENABLED)
            self.countLightsWithShadowMode(.meshlet_ray)
        else
            0;
        self.light_work_stats.active_lights = self.lights.items.len;
        self.light_work_stats.shadow_map_lights = shadow_map_light_count;
        self.light_work_stats.meshlet_shadow_lights = meshlet_shadow_light_count;
        self.light_work_stats.shadow_map_reused_lights = 0;
        self.light_work_stats.shadow_budget_skipped_lights = 0;
        self.light_work_stats.shadow_map_downscaled_lights = 0;
        self.light_work_stats.shadow_map_upscaled_lights = 0;
        self.light_work_stats.shadow_cadence_increased_lights = 0;
        self.light_work_stats.shadow_cadence_decreased_lights = 0;
        self.light_work_stats.shadow_queries = self.bitmap.pixels.len * shadow_map_light_count;
        self.light_work_stats.meshlet_ray_tests = 0;
        self.light_work_stats.meshlet_shadow_chunks = 0;
        self.light_work_stats.meshlet_shadow_chunk_pixels = 0;
        self.light_work_stats.meshlet_shadow_chunk_active_rays = 0;
        self.light_work_stats.meshlet_shadow_packets = 0;
        self.light_work_stats.meshlet_shadow_packets_skipped = 0;
        self.light_work_stats.meshlet_shadow_packet_active_lanes = 0;
        self.light_work_stats.meshlet_shadow_packet_occluded_lanes = 0;
        self.light_work_stats.meshlet_shadow_trace_us = 0;
        self.light_work_stats.meshlet_shadow_apply_us = 0;
        self.light_work_stats.triangles_rasterized = 0;
        self.light_work_stats.covered_pixels = 0;
        self.light_work_stats.depth_tests_passed = 0;
        self.light_work_stats.alpha_pixels = 0;
        self.light_work_stats.shadow_budget_ns = 0;
        self.light_work_stats.shadow_build_ns = 0;
        self.light_work_stats.shadow_resolve_ns = 0;
        self.light_work_stats.active_tiles = 0;
        self.light_work_stats.tile_light_candidates = 0;
        self.light_work_stats.tile_light_final = 0;
        self.light_work_stats.tile_light_rejected = 0;
        self.light_work_stats.tile_light_overflow_tiles = 0;
        @memset(self.shadow_resolve_elapsed_ns[0..self.lights.items.len], 0);
        const is_editor_mode = self.camera_control_mode != .first_person;
        const using_tiled_backend = self.use_tiled_rendering and self.tile_grid != null and self.tile_buffers != null;
        const compiled_frame_plan = frame_pipeline.compileCachedFramePlan(&self.cached_frame_plan, .{
            .has_shadow_map_lights = shadow_map_light_count > 0,
            .backend = if (using_tiled_backend) .tiled else .direct,
            .include_post_process = false,
            .include_present = true,
        });
        const frame_exec_ctx = FrameExecutionContext{
            .renderer = self,
            .mesh = mesh,
            .view_rotation = view_rotation,
            .light_dir = light_dir,
            .pump = pump,
            .raster_projection = raster_projection,
            .is_editor_mode = is_editor_mode,
            .light_camera = light_camera,
            .center_x = center_x,
            .center_y = center_y,
            .x_scale = x_scale,
            .y_scale = y_scale,
            .basis_right = right,
            .basis_up = up,
            .basis_forward = forward,
            .taa_view = taa_view,
            .shadow_map_light_count = shadow_map_light_count,
            .light_dir_world = light_dir_world,
            .cache_projection = resolved_frame_view.cache_projection,
        };
        const current_time = try frame_executor.executeFramePlan(
            FrameExecutionContext,
            compiled_frame_plan,
            frame_exec_ctx,
            frame_stage_dispatcher,
            std.time.nanoTimestamp(),
        );
        self.finalizeFrame(current_time);
        self.advanceFrameDeadline(current_time);

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

    /// Begins an operation and captures temporary context used until completion.
    /// It marks the start of an operation and prepares transient state used until completion.
    fn beginFrame(self: *Renderer) f32 {
        const now = std.time.nanoTimestamp();
        var delta_ns = now - self.last_frame_time;
        if (delta_ns < 0) delta_ns = 0;
        self.last_frame_time = now;
        self.current_frame_start_time = now;
        self.active_software_wait_ns = self.pending_software_wait_ns;
        self.pending_software_wait_ns = 0;
        self.frame_deadline_error_ns = if (self.next_frame_time > 0) now - self.next_frame_time else 0;

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
        const packet_count = @max(@as(usize, 1), self.light_work_stats.meshlet_shadow_packets);
        const avg_active_lanes = @as(f32, @floatFromInt(self.light_work_stats.meshlet_shadow_packet_active_lanes)) /
            @as(f32, @floatFromInt(packet_count));
        const avg_occluded_lanes = @as(f32, @floatFromInt(self.light_work_stats.meshlet_shadow_packet_occluded_lanes)) /
            @as(f32, @floatFromInt(packet_count));
        renderer_logger.infoSub(
            "frame_profile",
            "light_work active={} shadow_map_lights={} meshlet_shadow_lights={} shadow_map_reused={} shadow_budget_skipped={} shadow_map_downscaled={} shadow_map_upscaled={} shadow_cadence_increased={} shadow_cadence_decreased={} shadow_queries={} meshlet_ray_tests={} meshlet_shadow_chunks={} meshlet_shadow_chunk_pixels={} meshlet_shadow_chunk_active_rays={} meshlet_shadow_packets={} meshlet_shadow_packets_skipped={} meshlet_shadow_avg_active_lanes={d:.2} meshlet_shadow_avg_occluded_lanes={d:.2} meshlet_shadow_trace={d:.3} ms meshlet_shadow_apply={d:.3} ms shadow_budget={d:.3} ms shadow_build={d:.3} ms shadow_resolve={d:.3} ms active_tiles={} tile_light_candidates={} tile_light_final={} tile_light_rejected={} tile_light_overflow_tiles={}",
            .{
                self.light_work_stats.active_lights,
                self.light_work_stats.shadow_map_lights,
                self.light_work_stats.meshlet_shadow_lights,
                self.light_work_stats.shadow_map_reused_lights,
                self.light_work_stats.shadow_budget_skipped_lights,
                self.light_work_stats.shadow_map_downscaled_lights,
                self.light_work_stats.shadow_map_upscaled_lights,
                self.light_work_stats.shadow_cadence_increased_lights,
                self.light_work_stats.shadow_cadence_decreased_lights,
                self.light_work_stats.shadow_queries,
                self.light_work_stats.meshlet_ray_tests,
                self.light_work_stats.meshlet_shadow_chunks,
                self.light_work_stats.meshlet_shadow_chunk_pixels,
                self.light_work_stats.meshlet_shadow_chunk_active_rays,
                self.light_work_stats.meshlet_shadow_packets,
                self.light_work_stats.meshlet_shadow_packets_skipped,
                avg_active_lanes,
                avg_occluded_lanes,
                @as(f32, @floatFromInt(self.light_work_stats.meshlet_shadow_trace_us)) / 1000.0,
                @as(f32, @floatFromInt(self.light_work_stats.meshlet_shadow_apply_us)) / 1000.0,
                render_utils.nanosecondsToMs(self.light_work_stats.shadow_budget_ns),
                render_utils.nanosecondsToMs(self.light_work_stats.shadow_build_ns),
                render_utils.nanosecondsToMs(self.light_work_stats.shadow_resolve_ns),
                self.light_work_stats.active_tiles,
                self.light_work_stats.tile_light_candidates,
                self.light_work_stats.tile_light_final,
                self.light_work_stats.tile_light_rejected,
                self.light_work_stats.tile_light_overflow_tiles,
            },
        );
        renderer_logger.infoSub(
            "frame_profile",
            "raster_work triangles_rasterized={} covered_pixels={} depth_tests_passed={} alpha_pixels={}",
            .{
                self.light_work_stats.triangles_rasterized,
                self.light_work_stats.covered_pixels,
                self.light_work_stats.depth_tests_passed,
                self.light_work_stats.alpha_pixels,
            },
        );
        for (0..self.lights.items.len) |light_index| {
            const build_ns = self.shadow_build_elapsed_ns[light_index];
            const resolve_ns = self.shadow_resolve_elapsed_ns[light_index];
            if (build_ns == 0 and resolve_ns == 0) continue;
            renderer_logger.infoSub(
                "frame_profile",
                "shadow_light {} build={d:.3} ms resolve={d:.3} ms",
                .{
                    light_index,
                    render_utils.nanosecondsToMs(build_ns),
                    render_utils.nanosecondsToMs(resolve_ns),
                },
            );
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

    /// updateWindowTitle updates Renderer state for the current tick/frame.
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

    /// Records telemetry/sample data and updates aggregate counters/statistics.
    /// It appends telemetry/sample data and updates aggregate counters/statistics.
    pub fn recordRenderPassTiming(self: *Renderer, name: []const u8, start_ns: i128) void {
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        self.recordRenderPassDuration(name, elapsed_ns);
    }

    /// Computes stripe count.
    /// Keeps compute stripe count as the single implementation point so call-site behavior stays consistent.
    fn computeStripeCount(max_jobs: usize, row_count: usize) usize {
        if (row_count == 0 or max_jobs == 0) return 0;
        const desired = @max(@as(usize, 1), (row_count + min_rows_per_parallel_job - 1) / min_rows_per_parallel_job);
        return @min(max_jobs, desired);
    }

    /// Records telemetry/sample data and updates aggregate counters/statistics.
    /// It appends telemetry/sample data and updates aggregate counters/statistics.
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

    /// renderPassSortMetric renders Renderer output.
    fn renderPassSortMetric(pass: RenderPassTiming) f32 {
        return if (pass.has_sample) pass.sampled_ms_per_frame else pass.frame_duration_ms;
    }

    /// sampleRenderPassTimings samples values used by Renderer.
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

    fn worldToCameraPosition(
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
    fn projectWorldToScreen(
        self: *Renderer,
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

        const max_x = @as(f32, @floatFromInt(self.bitmap.width * 8));
        const max_y = @as(f32, @floatFromInt(self.bitmap.height * 8));
        if (projected.x < -max_x or projected.x > max_x or projected.y < -max_y or projected.y > max_y) return null;

        return .{
            @as(i32, @intFromFloat(projected.x)),
            @as(i32, @intFromFloat(projected.y)),
        };
    }

    fn drawLightGizmo(
        self: *Renderer,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    ) void {
        if (self.lights.items.len == 0) return;
        self.clampLightGizmoSelection();
        const light = self.lights.items[self.light_gizmo.selected_light_index];
        const origin_world = math.Vec3.scale(light.direction, light.distance);
        const origin_screen = self.projectWorldToScreen(
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
        const hot_axis = self.light_gizmo.drag_axis orelse self.light_gizmo.hover_axis;

        if (self.projectWorldToScreen(camera_position, basis_right, basis_up, basis_forward, projection, x_endpoint)) |p| {
            const color = lightGizmoAxisColor(.x, self.light_gizmo.active_axis, hot_axis);
            self.drawLineColored(origin_screen[0], origin_screen[1], p[0], p[1], color);
            self.drawLightGizmoHandle(p[0], p[1], color);
        }
        if (self.projectWorldToScreen(camera_position, basis_right, basis_up, basis_forward, projection, y_endpoint)) |p| {
            const color = lightGizmoAxisColor(.y, self.light_gizmo.active_axis, hot_axis);
            self.drawLineColored(origin_screen[0], origin_screen[1], p[0], p[1], color);
            self.drawLightGizmoHandle(p[0], p[1], color);
        }
        if (self.projectWorldToScreen(camera_position, basis_right, basis_up, basis_forward, projection, z_endpoint)) |p| {
            const color = lightGizmoAxisColor(.z, self.light_gizmo.active_axis, hot_axis);
            self.drawLineColored(origin_screen[0], origin_screen[1], p[0], p[1], color);
            self.drawLightGizmoHandle(p[0], p[1], color);
        }

        self.drawLineColored(origin_screen[0] - 2, origin_screen[1], origin_screen[0] + 2, origin_screen[1], 0xFFFFFFFF);
        self.drawLineColored(origin_screen[0], origin_screen[1] - 2, origin_screen[0], origin_screen[1] + 2, 0xFFFFFFFF);
    }

    fn drawLightGizmoHandle(self: *Renderer, x: i32, y: i32, color: u32) void {
        self.drawLineColored(x - 3, y, x + 3, y, color);
        self.drawLineColored(x, y - 3, x, y + 3, color);
    }

    fn drawSceneItemGizmo(
        self: *Renderer,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    ) void {
        var draw_ctx = SceneItemGizmoDrawContext{
            .renderer = self,
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .projection = projection,
        };
        self.scene_item_gizmo.drawGizmo(
            @ptrCast(&draw_ctx),
            projectSceneItemWorld,
            drawSceneItemGizmoLine,
        );
    }

    fn drawLightGlow(
        self: *Renderer,
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
            if (py < 0 or py >= self.bitmap.height) continue;
            var px = cx - radius;
            while (px <= cx + radius) : (px += 1) {
                if (px < 0 or px >= self.bitmap.width) continue;
                const dx = @as(f32, @floatFromInt(px - cx));
                const dy = @as(f32, @floatFromInt(py - cy));
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist > radius_px) continue;
                const falloff = (1.0 - dist * inv_radius);
                const glow = falloff * falloff * intensity;
                const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(px));
                if (idx >= self.bitmap.pixels.len) continue;

                const src = self.bitmap.pixels[idx];
                const sr: i32 = @intCast((src >> 16) & 0xFF);
                const sg: i32 = @intCast((src >> 8) & 0xFF);
                const sb: i32 = @intCast(src & 0xFF);
                const add_r: i32 = @intFromFloat(std.math.clamp(glow_color.x * 255.0 * glow, 0.0, 255.0));
                const add_g: i32 = @intFromFloat(std.math.clamp(glow_color.y * 255.0 * glow, 0.0, 255.0));
                const add_b: i32 = @intFromFloat(std.math.clamp(glow_color.z * 255.0 * glow, 0.0, 255.0));
                const out_r: u32 = @intCast(std.math.clamp(sr + add_r, 0, 255));
                const out_g: u32 = @intCast(std.math.clamp(sg + add_g, 0, 255));
                const out_b: u32 = @intCast(std.math.clamp(sb + add_b, 0, 255));
                self.bitmap.pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
            }
        }
    }

    /// buildShadowMap builds data structures used by Renderer.
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

    /// Applies shadow pass.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    fn applyShadowPass(
        self: *Renderer,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
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
        const resolve_elapsed_ns = shadow_map_pass.runPipeline(
            self,
            width,
            height,
            resolve_config,
            target_shadow_map,
            noopRenderPassJob,
        );
        if (pass_index < self.shadow_resolve_elapsed_ns.len) {
            self.shadow_resolve_elapsed_ns[pass_index] = resolve_elapsed_ns;
        }
        self.light_work_stats.shadow_resolve_ns += resolve_elapsed_ns;
    }

    /// Applies adaptive shadow pass.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
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

    /// Applies skybox pass.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    pub fn applySkyboxPass(
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

    pub fn runShadowResolvePass(
        self: *Renderer,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
        shadow_build_elapsed_ns: []const i128,
    ) void {
        const shadow_ctx = ShadowLightDispatchContext{
            .renderer = self,
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .projection = projection,
            .shadow_build_elapsed_ns = shadow_build_elapsed_ns,
        };
        shadow_map_pass.runPerLight(self.lights.items.len, shadow_ctx, applyShadowLightFromPass);
        if (self.light_work_stats.shadow_resolve_ns > 0) {
            self.recordRenderPassDuration("shadow_map_resolve_total", self.light_work_stats.shadow_resolve_ns);
        }
    }

    pub fn runHybridShadowPass(
        self: *Renderer,
        mesh: *const Mesh,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        light_dir_world: math.Vec3,
    ) void {
        const hybrid_ctx = HybridShadowDispatchContext{
            .renderer = self,
            .mesh = mesh,
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .light_dir_world = light_dir_world,
        };
        hybrid_shadow_pass.run(hybrid_ctx, applyHybridShadowFromPass);
    }

    pub fn runPostProcessStage(
        self: *Renderer,
        is_editor_mode: bool,
        mesh: *const Mesh,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        current_view: TemporalAAViewState,
        projection: ProjectionParams,
        shadow_map_light_count: usize,
        light_dir_world: math.Vec3,
    ) void {
        if (is_editor_mode) {
            self.scene_item_gizmo.resolvePendingPick(
                self.bitmap.width,
                self.bitmap.height,
                @as(i32, @intCast(config.WINDOW_WIDTH)),
                @as(i32, @intCast(config.WINDOW_HEIGHT)),
                self.scene_surface,
            );
        }
        self.applyPostProcessingPasses(
            mesh,
            self.camera_position,
            basis_right,
            basis_up,
            basis_forward,
            current_view,
            projection,
            shadow_map_light_count,
            light_dir_world,
            self.shadow_build_elapsed_ns[0..self.lights.items.len],
        );
    }

    /// Applies shadow light from pass.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    fn applyShadowLightFromPass(ctx: ShadowLightDispatchContext, pass_index: usize) void {
        if (pass_index >= ctx.renderer.lights.items.len) return;
        if (ctx.renderer.lights.items[pass_index].shadow_mode != .shadow_map) return;
        const shadow_map_ptr = &ctx.renderer.lights.items[pass_index].shadow_map;
        _ = ctx.shadow_build_elapsed_ns;
        ctx.renderer.applyShadowPass(
            ctx.camera_position,
            ctx.basis_right,
            ctx.basis_up,
            ctx.basis_forward,
            ctx.projection,
            shadow_map_ptr,
            pass_index,
        );
    }

    /// Applies hybrid shadow from pass.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
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

    /// Returns whether i sp os tp as se na bl ed.
    /// The check is side-effect free so callers can gate expensive follow-up work cheaply.
    fn snapshotScratchBindings(self: *Renderer) CompositionScratchBindings {
        return .{
            .ssgi_scratch_pixels = self.ssgi_scratch_pixels,
            .ssr_scratch_pixels = self.ssr_scratch_pixels,
            .moblur_scratch_pixels = self.moblur_scratch_pixels,
            .god_rays_scratch_pixels = self.god_rays_scratch_pixels,
            .lens_flare_scratch_pixels = self.lens_flare_scratch_pixels,
        };
    }

    /// Applies composition scratch bindings.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    fn applyCompositionScratchBindings(self: *Renderer, scratch_a: []u32, scratch_b: []u32) void {
        const applied = frame_pipeline.applyScratchBindings(.{ .scratch_a = scratch_a, .scratch_b = scratch_b });
        self.ssgi_scratch_pixels = applied.scratch_a;
        self.ssr_scratch_pixels = applied.scratch_b;
        self.moblur_scratch_pixels = applied.scratch_a;
        self.god_rays_scratch_pixels = applied.scratch_a;
        self.lens_flare_scratch_pixels = applied.scratch_a;
    }

    fn recordPostPhaseTiming(ctx: *anyopaque, phase: pass_graph.PassPhase, duration_ns: i128) void {
        const self: *Renderer = @ptrCast(@alignCast(ctx));
        self.recordRenderPassDuration(frame_pipeline.phaseTimingName(phase), duration_ns);
    }

    fn shouldRecordPostPhaseTimings(self: *const Renderer) bool {
        if (self.show_render_overlay) return true;
        if (profiler.Profiler.instance) |instance| {
            if (instance.active) return true;
        }
        return self.profile_capture_frame != 0 and self.total_frames_rendered + 1 == self.profile_capture_frame;
    }

    fn restoreScratchBindings(self: *Renderer, saved: CompositionScratchBindings) void {
        self.ssgi_scratch_pixels = saved.ssgi_scratch_pixels;
        self.ssr_scratch_pixels = saved.ssr_scratch_pixels;
        self.moblur_scratch_pixels = saved.moblur_scratch_pixels;
        self.god_rays_scratch_pixels = saved.god_rays_scratch_pixels;
        self.lens_flare_scratch_pixels = saved.lens_flare_scratch_pixels;
    }
    const post_pass_dispatcher = frame_dispatchers.makePostPassDispatcher(PostPassExecutionContext);
    const frame_stage_dispatcher = frame_dispatchers.makeFrameStageDispatcher(FrameExecutionContext);

    /// Applies post processing passes.
    /// Mutates owned state and keeps dependent cached values coherent for downstream systems.
    fn applyPostProcessingPasses(
        self: *Renderer,
        mesh: *const Mesh,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        current_view: TemporalAAViewState,
        projection: ProjectionParams,
        shadow_map_light_count: usize,
        light_dir_world: math.Vec3,
        shadow_build_elapsed_ns: []const i128,
    ) void {
        const compiled_graph = frame_pipeline.compileCachedPostGraph(&self.cached_post_graph, .{
            .shadow_map_light_count = shadow_map_light_count,
            .taa_history_valid = self.taa_scratch.valid,
        }) catch |err| {
            pipeline_logger.errorSub("graph", "failed to compile post graph: {s}", .{@errorName(err)});
            return;
        };

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
            .shadow_build_elapsed_ns = shadow_build_elapsed_ns,
        };
        const saved_bindings = snapshotScratchBindings(self);
        defer restoreScratchBindings(self, saved_bindings);
        applyCompositionScratchBindings(self, saved_bindings.moblur_scratch_pixels, saved_bindings.ssr_scratch_pixels);
        frame_executor.executePostGraph(
            PostPassExecutionContext,
            compiled_graph,
            .{
                .front = &self.bitmap.pixels,
                .scratch_a = &self.moblur_scratch_pixels,
                .scratch_b = &self.ssr_scratch_pixels,
            },
            .{
                .enabled = self.shouldRecordPostPhaseTimings(),
                .ctx = self,
                .record = recordPostPhaseTiming,
            },
            ctx,
            post_pass_dispatcher,
        );
    }

    pub fn stageBuildShadowMaps(self: *Renderer, mesh: *const Mesh) void {
        if (!config.POST_SHADOW_ENABLED) return;

        const shadow_budget_ns = self.computeShadowBuildBudgetNs();
        const enforce_shadow_budget = shadow_budget_ns >= 0;
        if (shadow_budget_ns > 0) {
            self.light_work_stats.shadow_budget_ns = shadow_budget_ns;
        }
        var shadow_budget_spent_ns: i128 = 0;
        @memset(self.shadow_build_elapsed_ns[0..self.lights.items.len], 0);
        const frame_number = self.total_frames_rendered + 1;
        for (self.lights.items, 0..) |*light, light_index| {
            if (light.shadow_mode != .shadow_map) continue;
            const base_cadence = @max(@as(u64, 1), @as(u64, light.shadow_update_interval_frames));
            const cadence_scale = @max(@as(u64, 1), @as(u64, light.shadow_dynamic_interval_scale));
            const cadence = @max(@as(u64, 1), @min(std.math.maxInt(u64), base_cadence * cadence_scale));
            const frames_since_last_build = if (light.shadow_last_build_frame == 0)
                cadence
            else
                frame_number - light.shadow_last_build_frame;
            const should_rebuild = !light.shadow_map.active or frames_since_last_build >= cadence;
            if (!should_rebuild) {
                self.light_work_stats.shadow_map_reused_lights += 1;
                continue;
            }
            if (enforce_shadow_budget and light.shadow_map.active) {
                const estimated_build_ns = estimateShadowBuildCostNs(light);
                if (shadow_budget_spent_ns + estimated_build_ns > shadow_budget_ns) {
                    self.light_work_stats.shadow_map_reused_lights += 1;
                    self.light_work_stats.shadow_budget_skipped_lights += 1;
                    continue;
                }
            }
            const light_dir_world_for_shadow = math.Vec3.new(
                self.light_soa.dir_x[light_index],
                self.light_soa.dir_y[light_index],
                self.light_soa.dir_z[light_index],
            );
            self.shadow_build_elapsed_ns[light_index] = self.buildShadowMap(mesh, light_dir_world_for_shadow, &light.shadow_map);
            light.shadow_last_build_frame = frame_number;
            light.shadow_last_build_ns = self.shadow_build_elapsed_ns[light_index];
            self.light_work_stats.shadow_build_ns += self.shadow_build_elapsed_ns[light_index];
            shadow_budget_spent_ns += self.shadow_build_elapsed_ns[light_index];
        }
        if (self.light_work_stats.shadow_build_ns > 0) {
            self.recordRenderPassDuration("shadow_map_build_total", self.light_work_stats.shadow_build_ns);
        }
    }

    pub fn stageRenderScene(
        self: *Renderer,
        backend: frame_plan.BackendKind,
        mesh: *const Mesh,
        view_rotation: math.Mat4,
        light_dir: math.Vec3,
        pump: ?*const fn (*Renderer) bool,
        raster_projection: ProjectionParams,
    ) !void {
        const scene_pass_start = std.time.nanoTimestamp();
        const tri_count = mesh.triangles.len;
        const meshlet_count = mesh.meshlets.len;
        switch (backend) {
            .tiled => {
                pipeline_logger.debugSub("dispatch", "rendering tiled path triangles={} meshlets={}", .{ tri_count, meshlet_count });
                const shadow_pass_elapsed_ns = try self.renderTiled(mesh, view_rotation, light_dir, pump, raster_projection);
                const scene_pass_elapsed_ns = std.time.nanoTimestamp() - scene_pass_start;
                self.recordRenderPassDuration("meshlet_tiled", scene_pass_elapsed_ns - @as(i128, @intCast(shadow_pass_elapsed_ns)));
                if (config.MESHLET_SHADOWS_ENABLED) {
                    self.recordRenderPassDuration("meshlet_shadows", @as(i128, @intCast(shadow_pass_elapsed_ns)));
                }
            },
            .direct => {
                pipeline_logger.debugSub("dispatch", "rendering direct path triangles={} meshlets={}", .{ tri_count, meshlet_count });
                try self.renderDirect(mesh, view_rotation, light_dir, raster_projection);
                self.recordRenderPassTiming("meshlet_direct", scene_pass_start);
            },
        }
    }

    pub fn stageOverlayAndPresent(
        self: *Renderer,
        is_editor_mode: bool,
        light_camera: math.Vec3,
        center_x: f32,
        center_y: f32,
        x_scale: f32,
        y_scale: f32,
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        cache_projection: ProjectionParams,
    ) !i128 {
        if (is_editor_mode) {
            self.scene_item_gizmo.applyOutline(
                self.bitmap.pixels,
                self.bitmap.width,
                self.bitmap.height,
                self.scene_surface,
            );
        }
        try self.applyAdaptiveShadowBudgetPolicy();
        if (self.show_light_orb) {
            const light_camera_z = light_camera.z;
            if (light_camera_z > NEAR_CLIP) {
                var glow_color = math.Vec3.new(1.0, 1.0, 1.0);
                var glow_radius: f32 = 0.0;
                var glow_intensity: f32 = 0.0;
                if (self.lights.items.len > 0) {
                    glow_color = self.lights.items[0].color;
                    glow_radius = self.lights.items[0].glow_radius;
                    glow_intensity = self.lights.items[0].glow_intensity;
                }
                if (glow_radius > 0.0 and glow_intensity > 0.0) {
                    self.drawLightGlow(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale, glow_color, glow_radius, glow_intensity);
                }
                self.drawLightMarker(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale);
            }
        }
        if (is_editor_mode and self.light_gizmo.enabled) {
            self.drawLightGizmo(self.camera_position, right, up, forward, cache_projection);
        }
        if (is_editor_mode and self.scene_item_gizmo.isActive()) {
            self.drawSceneItemGizmo(self.camera_position, right, up, forward, cache_projection);
        }

        const present_start = std.time.nanoTimestamp();
        const cpu_frame_ns = present_start - self.current_frame_start_time;

        if (self.usesSoftwareFramePacing() and self.last_completed_frame_time > 0) {
            const ideal_present_time = self.last_completed_frame_time + self.target_frame_time_ns - self.present_cost_ema_ns;
            var spin_now = std.time.nanoTimestamp();
            while (spin_now < ideal_present_time) {
                std.atomic.spinLoopHint();
                spin_now = std.time.nanoTimestamp();
            }
        }

        const pre_present_time = std.time.nanoTimestamp();
        self.drawBitmap();
        const present_end = std.time.nanoTimestamp();
        const draw_cost_ns = @max(present_end - pre_present_time, @as(i128, 0));
        self.present_cost_ema_ns = @divTrunc(self.present_cost_ema_ns * 7 + draw_cost_ns, 8);
        self.recordRenderPassTiming("present", present_start);
        pipeline_logger.debugSub("present", "bitmap presented", .{});

        const current_time = present_end;
        const frame_interval_ns = current_time - self.last_completed_frame_time;
        self.notePresentedFrame(current_time);
        self.maybeEmitSingleFrameProfile();
        self.frame_pacing.recordSample(.{
            .total_ms = @as(f32, @floatFromInt(@max(frame_interval_ns, @as(i128, 0)))) / 1_000_000.0,
            .cpu_ms = @as(f32, @floatFromInt(@max(cpu_frame_ns, @as(i128, 0)))) / 1_000_000.0,
            .software_wait_ms = @as(f32, @floatFromInt(@max(self.active_software_wait_ns, @as(i128, 0)))) / 1_000_000.0,
            .present_wait_ms = @as(f32, @floatFromInt(@max(present_end - present_start, @as(i128, 0)))) / 1_000_000.0,
            .deadline_error_ms = @as(f32, @floatFromInt(self.frame_deadline_error_ns)) / 1_000_000.0,
        }, self.effectiveFramePacingTargetNs());
        return current_time;
    }
// ====== post-process pass dispatchers (impl in renderer/post_dispatch.zig) ======
    pub const applySSGIPass = post_dispatch.applySSGIPass;
    pub const applyAmbientOcclusionPass = post_dispatch.applyAmbientOcclusionPass;
    pub const applyDepthFogPass = post_dispatch.applyDepthFogPass;
    pub const applyTemporalAARows = post_dispatch.applyTemporalAARows;
    pub const applyGodRaysPass = post_dispatch.applyGodRaysPass;
    pub const applyLensFlarePass = post_dispatch.applyLensFlarePass;
    pub const applyChromaticAberrationPass = post_dispatch.applyChromaticAberrationPass;
    pub const applyFilmGrainVignettePass = post_dispatch.applyFilmGrainVignettePass;
    pub const applyMotionBlurPass = post_dispatch.applyMotionBlurPass;
    pub const applyTemporalAAPass = post_dispatch.applyTemporalAAPass;
    pub const applySSRPass = post_dispatch.applySSRPass;
    pub const applyDepthOfFieldPass = post_dispatch.applyDepthOfFieldPass;
    pub const applyBloomPass = post_dispatch.applyBloomPass;
    pub const applyBlockbusterColorGradePass = post_dispatch.applyBlockbusterColorGradePass;



    fn drawBitmap(self: *Renderer) void {
        _ = self.presentFrame(false) catch {
            // The renderer should remain operational even if a present fails transiently.
        };
        if (config.WINDOW_VSYNC and self.present_state.canPresent()) {
            _ = DwmFlush();
        }
    }

    const FramePacingDrawContext = struct {
        renderer: *Renderer,
        hdc_mem: windows.HDC,
    };

    fn fillRectSolid(self: *Renderer, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        if (w <= 0 or h <= 0) return;
        const min_x = std.math.clamp(x, 0, self.bitmap.width);
        const min_y = std.math.clamp(y, 0, self.bitmap.height);
        const max_x = std.math.clamp(x + w, 0, self.bitmap.width);
        const max_y = std.math.clamp(y + h, 0, self.bitmap.height);
        if (max_x <= min_x or max_y <= min_y) return;

        var py = min_y;
        while (py < max_y) : (py += 1) {
            const row_start = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width));
            var px = min_x;
            while (px < max_x) : (px += 1) {
                const idx = row_start + @as(usize, @intCast(px));
                if (idx < self.bitmap.pixels.len) self.bitmap.pixels[idx] = color;
            }
        }
    }

    fn framePacingFillRect(ctx_ptr: *anyopaque, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        const ctx: *FramePacingDrawContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.fillRectSolid(x, y, w, h, color);
    }

    fn framePacingDrawLine(ctx_ptr: *anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        const ctx: *FramePacingDrawContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.drawLineColored(x0, y0, x1, y1, color);
    }

    fn framePacingDrawText(ctx_ptr: *anyopaque, x: i32, y: i32, text: []const u8) void {
        const ctx: *FramePacingDrawContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.drawOverlayTextLine(ctx.hdc_mem, x, y, text);
    }

    fn drawFramePacingPanel(self: *Renderer, hdc_mem: windows.HDC) void {
        var draw_ctx = FramePacingDrawContext{
            .renderer = self,
            .hdc_mem = hdc_mem,
        };
        frame_pacing_hud.drawPanel(&self.frame_pacing, .{
            .bitmap_width = self.bitmap.width,
            .bitmap_height = self.bitmap.height,
            .vsync_enabled = config.WINDOW_VSYNC,
            .pacing_mode = self.currentPacingMode(),
            .show_overlay = self.show_frame_pacing_overlay,
            .draw_ctx = @ptrCast(&draw_ctx),
            .fns = .{
                .fillRectSolid = framePacingFillRect,
                .drawLineColored = framePacingDrawLine,
                .drawTextLine = framePacingDrawText,
            },
        });
    }

    fn drawRenderPassOverlay(self: *Renderer, hdc_mem: windows.HDC) void {
        if (self.render_pass_count == 0 and !self.hybrid_shadow_debug.enabled and self.hybrid_shadow_stats.job_count == 0 and !self.light_gizmo.enabled and !self.scene_item_gizmo.enabled and !self.show_render_overlay and !self.loading_overlay.enabled) return;

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

        if (self.light_gizmo.enabled) {
            var line_buffer: [192]u8 = undefined;
            if (self.render_pass_count != 0 or self.hybrid_shadow_debug.enabled or self.hybrid_shadow_stats.job_count != 0) y += 8;
            self.drawOverlayTextLine(hdc_mem, 12, y, "Light Gizmo");
            y += 20;
            self.drawOverlayTextLine(hdc_mem, 12, y, "G toggle, L cycle, X/Y/Z axis, J/K move");
            y += 16;

            if (self.lights.items.len > 0) {
                self.clampLightGizmoSelection();
                const status_line = std.fmt.bufPrint(
                    &line_buffer,
                    "light={}/{} axis={s} step={d:.2}",
                    .{
                        self.light_gizmo.selected_light_index + 1,
                        self.lights.items.len,
                        lightGizmoAxisName(self.light_gizmo.active_axis),
                        self.light_gizmo.move_step,
                    },
                ) catch "";
                if (status_line.len != 0) {
                    self.drawOverlayTextLine(hdc_mem, 12, y, status_line);
                    y += 16;
                }
            } else {
                self.drawOverlayTextLine(hdc_mem, 12, y, "no lights available");
                y += 16;
            }
        }

        if (self.scene_item_gizmo.enabled) {
            var line_buffer: [192]u8 = undefined;
            if (self.render_pass_count != 0 or self.hybrid_shadow_debug.enabled or self.hybrid_shadow_stats.job_count != 0 or self.light_gizmo.enabled) y += 8;
            self.drawOverlayTextLine(hdc_mem, 12, y, "Scene Gizmo");
            y += 20;
            self.drawOverlayTextLine(hdc_mem, 12, y, "click select, M toggle, X/Y/Z axis, J/K move");
            y += 16;

            if (self.scene_item_gizmo.selectedItemIndex()) |selected_item| {
                const status_line = std.fmt.bufPrint(
                    &line_buffer,
                    "item={}/{} axis={s} step={d:.2}",
                    .{
                        selected_item + 1,
                        self.scene_item_gizmo.itemCount(),
                        scene_item_gizmo.axisName(self.scene_item_gizmo.active_axis),
                        self.scene_item_gizmo.move_step,
                    },
                ) catch "";
                if (status_line.len != 0) {
                    self.drawOverlayTextLine(hdc_mem, 12, y, status_line);
                    y += 16;
                }
            } else {
                self.drawOverlayTextLine(hdc_mem, 12, y, "no selected item");
                y += 16;
            }
        }

        if (self.show_render_overlay or self.scene_item_gizmo.enabled) {
            var line_buffer: [160]u8 = undefined;
            if (self.render_pass_count != 0 or self.hybrid_shadow_debug.enabled or self.hybrid_shadow_stats.job_count != 0 or self.light_gizmo.enabled or self.scene_item_gizmo.enabled) y += 8;
            const mode_line = std.fmt.bufPrint(
                &line_buffer,
                "Camera Mode: {s} (V toggle)",
                .{if (self.camera_control_mode == .first_person) "first_person" else "editor"},
            ) catch "";
            if (mode_line.len != 0) {
                self.drawOverlayTextLine(hdc_mem, 12, y, mode_line);
                y += 16;
            }
            if (self.camera_control_mode == .first_person) {
                const mouse_line = std.fmt.bufPrint(
                    &line_buffer,
                    "Mouse sens={d:.4} dpi_scale={d:.2} smooth={d:.2}",
                    .{
                        self.mouse_state.sensitivity,
                        config.CAMERA_MOUSE_DPI_SCALE,
                        config.CAMERA_MOUSE_SMOOTHING,
                    },
                ) catch "";
                if (mouse_line.len != 0) self.drawOverlayTextLine(hdc_mem, 12, y, mouse_line);
            }
        }

        if (self.loading_overlay.enabled) {
            self.drawSceneLoadingOverlay(hdc_mem);
        }
    }

    fn drawSceneLoadingOverlay(self: *Renderer, hdc_mem: windows.HDC) void {
        if (!self.loading_overlay.enabled) return;

        const panel_w = std.math.clamp(@divTrunc(self.bitmap.width * 56, 100), 300, 620);
        const panel_h: i32 = 120;
        const panel_x = @divTrunc(self.bitmap.width - panel_w, 2);
        const panel_y = @divTrunc(self.bitmap.height - panel_h, 2);
        self.fillRectSolid(panel_x, panel_y, panel_w, panel_h, 0xDD0E141C);
        self.drawLineColored(panel_x, panel_y, panel_x + panel_w - 1, panel_y, 0xFF2F435A);
        self.drawLineColored(panel_x, panel_y + panel_h - 1, panel_x + panel_w - 1, panel_y + panel_h - 1, 0xFF2F435A);
        self.drawLineColored(panel_x, panel_y, panel_x, panel_y + panel_h - 1, 0xFF2F435A);
        self.drawLineColored(panel_x + panel_w - 1, panel_y, panel_x + panel_w - 1, panel_y + panel_h - 1, 0xFF2F435A);

        const spinner_center_x = panel_x + 28;
        const spinner_center_y = panel_y + 46;
        const spinner_segments: u32 = 12;
        const spinner_radius_inner: f32 = 7.0;
        const spinner_radius_outer: f32 = 12.0;
        const spinner_phase = self.loading_overlay.spinner_tick % spinner_segments;

        var seg: u32 = 0;
        while (seg < spinner_segments) : (seg += 1) {
            const angle = (@as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(spinner_segments))) * std.math.tau;
            const c = @cos(angle);
            const s = @sin(angle);
            const x0 = spinner_center_x + @as(i32, @intFromFloat(c * spinner_radius_inner));
            const y0 = spinner_center_y + @as(i32, @intFromFloat(s * spinner_radius_inner));
            const x1 = spinner_center_x + @as(i32, @intFromFloat(c * spinner_radius_outer));
            const y1 = spinner_center_y + @as(i32, @intFromFloat(s * spinner_radius_outer));
            const dist_a = if (seg >= spinner_phase) seg - spinner_phase else spinner_segments - (spinner_phase - seg);
            const shade: u32 = 64 + (spinner_segments - dist_a) * 12;
            const color: u32 = 0xFF000000 | (shade << 16) | (shade << 8) | shade;
            self.drawLineColored(x0, y0, x1, y1, color);
        }

        var line_buffer: [192]u8 = undefined;
        const title_line = std.fmt.bufPrint(
            &line_buffer,
            "Loading scene: {s}",
            .{self.loading_overlay.sceneText()},
        ) catch "Loading scene...";
        self.drawOverlayTextLine(hdc_mem, panel_x + 52, panel_y + 16, title_line);

        const status_line = std.fmt.bufPrint(
            &line_buffer,
            "Assets {}/{}",
            .{ self.loading_overlay.completed_steps, self.loading_overlay.total_steps },
        ) catch "";
        if (status_line.len != 0) self.drawOverlayTextLine(hdc_mem, panel_x + 52, panel_y + 34, status_line);

        const phase = self.loading_overlay.phaseText();
        if (phase.len != 0) self.drawOverlayTextLine(hdc_mem, panel_x + 52, panel_y + 52, phase);

        const bar_x = panel_x + 16;
        const bar_w = panel_w - 32;
        const bar_y = panel_y + panel_h - 28;
        const bar_h: i32 = 14;
        self.fillRectSolid(bar_x, bar_y, bar_w, bar_h, 0xFF0A0E14);
        self.drawLineColored(bar_x, bar_y, bar_x + bar_w - 1, bar_y, 0xFF304458);
        self.drawLineColored(bar_x, bar_y + bar_h - 1, bar_x + bar_w - 1, bar_y + bar_h - 1, 0xFF304458);
        self.drawLineColored(bar_x, bar_y, bar_x, bar_y + bar_h - 1, 0xFF304458);
        self.drawLineColored(bar_x + bar_w - 1, bar_y, bar_x + bar_w - 1, bar_y + bar_h - 1, 0xFF304458);

        const fill_max = @max(@as(i32, 0), bar_w - 2);
        const fill_w = std.math.clamp(
            @as(i32, @intFromFloat(self.loading_overlay.progress * @as(f32, @floatFromInt(fill_max)))),
            0,
            fill_max,
        );
        if (fill_w > 0) self.fillRectSolid(bar_x + 1, bar_y + 1, fill_w, bar_h - 2, 0xFF4ECFB5);
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

    /// buildBlockbusterGradeProfile builds data structures used by Renderer.
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

    pub fn firstTileLightWithMode(self: *const Renderer, range: TileLightRange, mode: LightInfo.ShadowMode) ?usize {
        var i: usize = 0;
        while (i < range.count) : (i += 1) {
            const light_index = self.tile_light_indices[range.offset + i];
            if (light_index >= self.lights.items.len) continue;
            if (self.lights.items[light_index].shadow_mode == mode) return light_index;
        }
        return null;
    }

    /// Renders the scene using the parallel, tile-based pipeline.
    fn renderTiled(
        self: *Renderer,
        mesh: *const Mesh,
        transform: math.Mat4,
        light_dir: math.Vec3,
        pump: ?*const fn (*Renderer) bool,
        projection: ProjectionParams,
    ) !u64 {
        return scene_tiled_backend.execute(
            self,
            mesh,
            transform,
            light_dir,
            pump,
            projection,
            noopRenderPassJob,
        );
    }

    /// renderDirect renders Renderer output.
    fn renderDirect(
        self: *Renderer,
        mesh: *const Mesh,
        transform: math.Mat4,
        light_dir: math.Vec3,
        projection: ProjectionParams,
    ) !void {
        _ = try self.renderTiled(mesh, transform, light_dir, null, projection);
    }

    fn clearDirectFrame(self: *Renderer, clear: direct_primitives.ClearConfig) void {
        _ = frame_setup_stage.execute(self.directFrameResources(), .{
            .clear_color = clear.color,
            .clear_depth = clear.depth orelse std.math.inf(f32),
        });
    }

    fn renderDirectPrimitiveShowcase(self: *Renderer) !void {
        const plan = direct_showcase.defaultPlan(
            self.camera_position,
            self.rotation_angle,
            self.rotation_x,
            self.camera_fov_deg,
            self.bitmap.width,
            self.bitmap.height,
            &self.direct_backend.suzanne_mesh,
        );
        try self.direct_backend.renderPrimitiveShowcase(
            self.directFrameResources(),
            plan.camera,
            self.job_system,
            .{
                .raster_mode = plan.raster_mode,
                .scene_kind = plan.scene_kind,
            },
        );
    }

    pub fn directFrameResources(self: *Renderer) frame_resources.FrameResources {
        return .{
            .target = .{
                .width = self.bitmap.width,
                .height = self.bitmap.height,
                .color = self.bitmap.pixels,
                .depth = self.scene_depth,
            },
            .aux = .{
                .scene_camera = self.scene_camera,
                .scene_normal = self.scene_normal,
                .scene_surface = self.scene_surface,
            },
        };
    }

    fn drawShadedTriangle(self: *Renderer, p0: [2]i32, p1: [2]i32, p2: [2]i32, shading: TileRenderer.ShadingParams) void {
        _ = self;
        _ = p0;
        _ = p1;
        _ = p2;
        _ = shading;
    }

    fn drawLineColored(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        var cx = x0;
        var cy = y0;

        const dx = if (x1 >= x0) (x1 - x0) else (x0 - x1);
        const dy = if (y1 >= y0) (y1 - y0) else (y0 - y1);
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err: i32 = dx - dy;

        while (true) {
            if (cx >= 0 and cx < self.bitmap.width and cy >= 0 and cy < self.bitmap.height) {
                const idx = @as(usize, @intCast(cy)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(cx));
                if (idx < self.bitmap.pixels.len) {
                    self.bitmap.pixels[idx] = color;
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
};