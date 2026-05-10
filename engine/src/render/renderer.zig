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
const scene_item_gizmo = @import("scene/item_gizmo.zig");
const camera_controller = @import("camera/controller.zig");
const camera_runtime = @import("camera/runtime.zig");
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
const renderer_init = @import("renderer/init.zig");
const renderer_lights = @import("renderer/lights.zig");
const renderer_hud = @import("renderer/hud.zig");
const renderer_orchestrator = @import("renderer/orchestrator.zig");
const renderer_scene_dispatch = @import("renderer/scene_dispatch.zig");
const renderer_pacing = @import("renderer/pacing.zig");
const renderer_draw = @import("renderer/draw.zig");
const frame_resources = @import("frame/resources.zig");
const frame_setup_stage = @import("stages/frame_setup_stage.zig");
const presentation_stage = @import("stages/presentation_stage.zig");
const direct_backend = @import("backends/direct_backend.zig");
const scene_tiled_backend = @import("backends/scene_tiled_backend.zig");
const present_d3d11 = @import("present/present_d3d11.zig");
const present_state = @import("present/state.zig");
const log = @import("../core/log.zig");
pub const renderer_logger = log.get("renderer.core");
pub const pipeline_logger = log.get("renderer.pipeline");
const meshlet_logger = log.get("renderer.meshlet");
pub const ground_logger = log.get("renderer.ground");

pub const NEAR_CLIP: f32 = 0.01;
pub const NEAR_EPSILON: f32 = 1e-4;
pub const INVALID_PROJECTED_COORD: i32 = -1000;
const ENABLE_MESHLET_CONE_CULL = false;
const fps_camera_floor_y: f32 = 0.0;
const fps_camera_eye_height: f32 = 1.6;
pub const shadow_rebuild_dot_threshold: f32 = 0.9986; // about 3 degrees
const hybrid_shadow_grid_dim: usize = 32;
pub const hybrid_shadow_grid_cells: usize = hybrid_shadow_grid_dim * hybrid_shadow_grid_dim;

pub const HybridShadowCasterBounds = struct {
    meshlet_index: usize,
    min_u: f32,
    max_u: f32,
    min_v: f32,
    max_v: f32,
    max_depth: f32,
};

pub const HybridShadowTileRange = struct {
    offset: usize = 0,
    count: usize = 0,
};

pub const min_rows_per_parallel_job: usize = 16;

const LightSpaceSample = struct {
    u: f32,
    v: f32,
    depth: f32,
};

pub const CameraToLightTransform = struct {
    origin_u: f32,
    origin_v: f32,
    origin_depth: f32,
    camera_u: math.Vec3,
    camera_v: math.Vec3,
    camera_depth: math.Vec3,

    /// init initializes Renderer state and returns the configured value.
    pub fn init(
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

pub const HybridShadowGrid = struct {
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

pub const HybridShadowStats = struct {
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

pub const HybridShadowDebugState = struct {
    enabled: bool = false,
    advance_requested: bool = false,
    completed_jobs: usize = 0,

    pub fn reset(self: *HybridShadowDebugState) void {
        self.advance_requested = false;
        self.completed_jobs = 0;
    }
};

pub const GroundReason = struct {
    pub const near_plane: u8 = 1 << 0;
    pub const backface: u8 = 1 << 1;
    pub const cross_near: u8 = 1 << 2;
};

const GroundDebugState = struct {
    last_mask: u8 = 0,
    frames_since_log: u32 = 0,
};

pub const MeshletTelemetry = struct {
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

pub const LightGizmoState = struct {
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

pub fn lightGizmoAxisColor(axis: LightGizmoAxis, active_axis: LightGizmoAxis, hot_axis: ?LightGizmoAxis) u32 {
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

pub const LightWorkStats = struct {
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

pub const LoadingOverlayState = struct {
    enabled: bool = false,
    progress: f32 = 0.0,
    completed_steps: usize = 0,
    total_steps: usize = 1,
    spinner_tick: u32 = 0,
    scene_text_len: usize = 0,
    scene_text_buf: [64]u8 = [_]u8{0} ** 64,
    phase_text_len: usize = 0,
    phase_text_buf: [96]u8 = [_]u8{0} ** 96,

    pub fn sceneText(self: *const LoadingOverlayState) []const u8 {
        return self.scene_text_buf[0..self.scene_text_len];
    }

    pub fn phaseText(self: *const LoadingOverlayState) []const u8 {
        return self.phase_text_buf[0..self.phase_text_len];
    }
};

pub const max_render_passes = 32;

pub const RenderPassTiming = struct {
    name: []const u8,
    frame_duration_ms: f32,
    accumulated_ms: f32,
    sampled_ms_per_frame: f32,
    has_sample: bool,
};

pub const ColorGradeProfile = struct {
    base_curve: [256]u8,
    tone_add_r: [256]i16,
    tone_add_g: [256]i16,
    tone_add_b: [256]i16,
};

pub const BloomScratch = struct {
    width: usize,
    height: usize,
    ping: []u32,
    pong: []u32,
};

pub const AOScratch = struct {
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

pub const SSGIJobContext = struct {
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

pub const SSRJobContext = struct {
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

pub const DepthOfFieldJobContext = struct {
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

pub const FrameViewCache = struct {
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

pub const DepthFogConfig = struct {
    near: f32,
    far: f32,
    inv_range: f32,
    strength: f32,
    color_r: i32,
    color_g: i32,
    color_b: i32,
};

pub const ShadowMap = struct {
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

pub const ShadowResolveConfig = struct {
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
    pub fn init(
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

pub fn taaJitterForFrame(frame_index: u64) math.Vec2 {
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
pub const TRANSPARENT = 1;

// ========== WINDOWS API DECLARATIONS ==========
// These are external function definitions for the Windows Graphics Device Interface (GDI).
// JS Analogy: This is like the low-level native browser code that the Canvas API calls.
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;
pub extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;
pub extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;
pub extern "gdi32" fn SetBkMode(hdc: windows.HDC, mode: i32) i32;
pub extern "gdi32" fn SetTextColor(hdc: windows.HDC, color: u32) u32;
pub extern "gdi32" fn TextOutW(hdc: windows.HDC, x: i32, y: i32, lpString: [*]const u16, c: i32) bool;
pub extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) bool;
pub extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
pub extern "kernel32" fn CreateWaitableTimerExW(lpTimerAttributes: ?*anyopaque, lpTimerName: ?[*:0]const u16, dwFlags: u32, dwDesiredAccess: u32) ?windows.HANDLE;
pub extern "kernel32" fn SetWaitableTimerEx(hTimer: windows.HANDLE, lpDueTime: *const i64, lPeriod: i32, pfnCompletionRoutine: ?*const anyopaque, lpArgToCompletionRoutine: ?*anyopaque, wakeContext: ?*const anyopaque, tolerableDelay: u32) windows.BOOL;
pub extern "dwmapi" fn DwmFlush() callconv(.winapi) windows.HRESULT;

pub const TIMER_MODIFY_STATE: u32 = 0x0002;
pub const SYNCHRONIZE_ACCESS: u32 = 0x0010_0000;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: u32 = 0x0000_0002;

// ========== MODULE IMPORTS ==========
const Bitmap = @import("../assets/bitmap.zig").Bitmap;
const TileRenderer = @import("core/tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("core/tile_binning.zig");
const job_system_module = @import("job_system");
const JobSystem = job_system_module.JobSystem;
const Job = job_system_module.Job;

pub const ColorGradeJobContext = struct {
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

pub const FogJobContext = struct {
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

pub const ShadowLightDispatchContext = struct {
    renderer: *Renderer,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    projection: ProjectionParams,
    shadow_build_elapsed_ns: []const i128,
};

pub const HybridShadowDispatchContext = struct {
    renderer: *Renderer,
    mesh: *const Mesh,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    light_dir_world: math.Vec3,
};

pub const CompositionScratchBindings = struct {
    ssgi_scratch_pixels: []u32,
    ssr_scratch_pixels: []u32,
    moblur_scratch_pixels: []u32,
    god_rays_scratch_pixels: []u32,
    lens_flare_scratch_pixels: []u32,
};

pub const PostPassExecutionContext = struct {
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

pub const AOJobContext = ssao_pass.JobContext(
    Renderer,
    renderAmbientOcclusionRows,
    blurAmbientOcclusionHorizontalRows,
    blurAmbientOcclusionVerticalRows,
    compositeAmbientOcclusionRows,
);

pub const TAAJobContext = struct {
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

pub const ShadowResolveJobContext = shadow_resolve_pass.JobContext(ShadowResolveConfig, ShadowMap);

pub const ShadowRasterJobContext = shadow_map_pass.RasterJobContext(Mesh, ShadowMap);

pub const AdaptiveShadowTileJob = struct {
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

pub const BloomJobContext = bloom_pass.JobContext(BloomScratch);

pub const CompositeJobContext = struct {
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

pub const LightSoA = struct {
    dir_x: []f32,
    dir_y: []f32,
    dir_z: []f32,
    dir_cam_x: []f32,
    dir_cam_y: []f32,
    dir_cam_z: []f32,
    distance: []f32,
    shadow_mode: []u8,
};

pub const TileLightRange = struct {
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
    skybox_job_contexts: []renderer_scene_dispatch.SkyboxJobContext,
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
    pub const init = renderer_init.init;

    // ====== light + texture setup (impl in renderer/lights.zig) ======
    pub const defaultLightColor = renderer_lights.defaultLightColor;
    pub const defaultLightShadowMode = renderer_lights.defaultLightShadowMode;
    pub const initLightInfo = renderer_lights.initLightInfo;
    pub const syncLightCameraSoA = renderer_lights.syncLightCameraSoA;
    pub const countLightsWithShadowMode = renderer_lights.countLightsWithShadowMode;
    pub const setTexture = renderer_lights.setTexture;
    pub const setHdriMap = renderer_lights.setHdriMap;
    pub const setTextures = renderer_lights.setTextures;
    pub const setLightCapacity = renderer_lights.setLightCapacity;
    pub const setDirectionalLight = renderer_lights.setDirectionalLight;
    pub const setLightShadowMode = renderer_lights.setLightShadowMode;
    pub const setLightShadowUpdateInterval = renderer_lights.setLightShadowUpdateInterval;
    pub const setLightShadowMapSize = renderer_lights.setLightShadowMapSize;
    pub const setLightGlow = renderer_lights.setLightGlow;

    // ====== render orchestration + frame lifecycle (impl in renderer/orchestrator.zig) ======
    pub const render3DMesh = renderer_orchestrator.render3DMesh;
    pub const render3DMeshWithPump = renderer_orchestrator.render3DMeshWithPump;
    pub const recordRenderPassTiming = renderer_orchestrator.recordRenderPassTiming;
    pub const recordRenderPassDuration = renderer_orchestrator.recordRenderPassDuration;
    pub const renderPassSortMetric = renderer_orchestrator.renderPassSortMetric;

    // ====== scene / post-pass dispatchers + stage methods (impl in renderer/scene_dispatch.zig) ======
    pub const applySkyboxPass = renderer_scene_dispatch.applySkyboxPass;
    pub const runShadowResolvePass = renderer_scene_dispatch.runShadowResolvePass;
    pub const runHybridShadowPass = renderer_scene_dispatch.runHybridShadowPass;
    pub const runPostProcessStage = renderer_scene_dispatch.runPostProcessStage;
    pub const stageBuildShadowMaps = renderer_scene_dispatch.stageBuildShadowMaps;
    pub const stageRenderScene = renderer_scene_dispatch.stageRenderScene;
    pub const stageOverlayAndPresent = renderer_scene_dispatch.stageOverlayAndPresent;

    // ====== frame pacing helpers (impl in renderer/pacing.zig) ======
    pub const currentPacingMode = renderer_pacing.currentPacingMode;
    pub const usesSoftwareFramePacing = renderer_pacing.usesSoftwareFramePacing;
    pub const effectiveFramePacingTargetNs = renderer_pacing.effectiveFramePacingTargetNs;
    pub const waitUntilNextFrame = renderer_pacing.waitUntilNextFrame;
    pub const advanceFrameDeadline = renderer_pacing.advanceFrameDeadline;
    pub const notePresentedFrame = renderer_pacing.notePresentedFrame;

    // ====== light + scene-item draw helpers (impl in renderer/draw.zig) ======
    pub const drawLightMarker = renderer_draw.drawLightMarker;
    pub const drawLightGizmo = renderer_draw.drawLightGizmo;
    pub const drawSceneItemGizmo = renderer_draw.drawSceneItemGizmo;
    pub const drawLightGlow = renderer_draw.drawLightGlow;

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

    pub const FrameExecutionContext = struct {
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

    pub fn ensureTemporalMeshVertexCapacity(self: *Renderer, vertex_count: usize) !void {
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
        const origin_screen = renderer_draw.projectWorldToScreen(self, 
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
            const endpoint_screen = renderer_draw.projectWorldToScreen(self, 
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
        const origin_screen = renderer_draw.projectWorldToScreen(self, 
            self.camera_position,
            pointer_view.right,
            pointer_view.up,
            pointer_view.forward,
            pointer_view.projection,
            origin_world,
        ) orelse return 0.0;
        const endpoint_screen = renderer_draw.projectWorldToScreen(self, 
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
        renderer_hud.drawBitmap(self);

        const now = std.time.nanoTimestamp();
        self.notePresentedFrame(now);
        renderer_orchestrator.finalizeFrame(self, now);
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
        renderer_orchestrator.finalizeFrame(self, std.time.nanoTimestamp());
    }

    pub fn presentFrame(self: *Renderer, use_direct_dirty_rect: bool) !presentation_stage.Result {
        if (self.hdc_mem) |hdc_mem| {
            if (self.show_render_overlay or self.hybrid_shadow_debug.enabled or self.scene_item_gizmo.enabled or self.loading_overlay.enabled) {
                renderer_hud.drawRenderPassOverlay(self, hdc_mem);
            }
            if (self.show_frame_pacing_overlay) {
                renderer_hud.drawFramePacingPanel(self, hdc_mem);
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
        return renderer_draw.projectWorldToScreen(
            ctx.renderer,
            ctx.camera_position,
            ctx.basis_right,
            ctx.basis_up,
            ctx.basis_forward,
            ctx.projection,
            world_position,
        );
    }

    pub fn drawSceneItemGizmoLine(ctx_ptr: *anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        const ctx: *SceneItemGizmoDrawContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.renderer.drawLineColored(x0, y0, x1, y1, color);
    }


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
    pub fn renderTiled(
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
    pub fn renderDirect(
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

    pub fn drawLineColored(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
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