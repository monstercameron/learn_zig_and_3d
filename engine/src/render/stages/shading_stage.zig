const std = @import("std");
const job_system = @import("job_system");
const math = @import("../../core/math.zig");
const cpu_features = @import("../../core/cpu_features.zig");
const direct_primitives = @import("../direct/primitives.zig");
const frame_resources = @import("../frame/resources.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const Config = struct {
    clear_color: u32 = 0xFF0B1220,
    enabled: bool = true,
    ambient: f32 = 0.62,
    diffuse: f32 = 0.38,
    light_dir: math.Vec3 = math.Vec3.new(-0.35, -0.45, 0.82),
};

pub const Result = struct {
    shaded_rect: ?direct_primitives.Rect2i = null,
    shaded_pixels: usize = 0,
};

pub fn execute(
    resources: frame_resources.FrameResources,
    shaded_rect: ?direct_primitives.Rect2i,
    config: Config,
    job_sys: ?*JobSystem,
) Result {
    const rect = shaded_rect orelse return .{};
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    const width = bounds.max_x - bounds.min_x + 1;
    const height = bounds.max_y - bounds.min_y + 1;
    if (width <= 0 or height <= 0 or resources.target.color.len == 0) return .{};
    if (!config.enabled or config.diffuse == 0.0) {
        return .{ .shaded_rect = bounds, .shaded_pixels = 0 };
    }

    const normalized_light = normalizeLight(config.light_dir);
    const frame_width_f = @as(f32, @floatFromInt(@max(resources.target.width - 1, 1)));
    const frame_height_f = @as(f32, @floatFromInt(@max(resources.target.height - 1, 1)));
    const x_step = if (resources.target.width > 1) 2.0 / frame_width_f else 0.0;
    const delta_intensity = intensityToFixed(-(config.diffuse * 0.22 * normalized_light.x * x_step));
    if (shouldParallelShade(job_sys, width, height)) {
        return executeParallel(resources, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity, job_sys.?);
    }

    return .{
        .shaded_rect = bounds,
        .shaded_pixels = shadeRows(resources, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity),
    };
}

fn executeParallel(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
    job_sys: *JobSystem,
) Result {
    const total_rows: usize = @intCast(bounds.max_y - bounds.min_y + 1);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]ShadeJobContext = undefined;
    var parent_job = Job.init(noopShadeJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var shaded_pixels: usize = 0;
    var row_start = bounds.min_y;

    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const remaining_rows = @as(usize, @intCast(bounds.max_y - row_start + 1));
        const remaining_chunks = chunk_count - chunk_index;
        const chunk_rows = @max(remaining_rows / remaining_chunks, 1);
        const row_end = @min(bounds.max_y, row_start + @as(i32, @intCast(chunk_rows)) - 1);
        contexts[chunk_index] = .{
            .resources = resources,
            .bounds = .{
                .min_x = bounds.min_x,
                .min_y = row_start,
                .max_x = bounds.max_x,
                .max_y = row_end,
            },
            .config = config,
            .normalized_light = normalized_light,
            .frame_width_f = frame_width_f,
            .frame_height_f = frame_height_f,
            .delta_intensity = delta_intensity,
            .shaded_pixels = 0,
        };

        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(shadeRowsJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                shadeRowsJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }

    if (main_chunk) |idx| shadeRowsJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);

    for (contexts[0..chunk_count]) |ctx| shaded_pixels += ctx.shaded_pixels;
    return .{
        .shaded_rect = bounds,
        .shaded_pixels = shaded_pixels,
    };
}

fn shadeRows(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
) usize {
    if (resources.target.depth) |depth_buffer| {
        return shadeRowsDepth(resources, depth_buffer, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity);
    }
    return shadeRowsColorOnly(resources, bounds, config, normalized_light, frame_width_f, frame_height_f, delta_intensity);
}

fn shadeRowsDepth(
    resources: frame_resources.FrameResources,
    depth_buffer: []f32,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
) usize {
    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    const clear_color = config.clear_color;
    var shaded_pixels: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        const screen_y = if (resources.target.height > 1)
            (@as(f32, @floatFromInt(y)) / frame_height_f) * 2.0 - 1.0
        else
            0.0;
        var intensity = shadeIntensityStart(bounds.min_x, frame_width_f, screen_y, normalized_light, config);
        var x = bounds.min_x;
        while (x + 3 <= bounds.max_x) : (x += 4) {
            inline for (0..4) |lane| {
                const idx = row_start + @as(usize, @intCast(x + @as(i32, @intCast(lane))));
                const pixel = color[idx];
                if (pixel != clear_color and std.math.isFinite(depth_buffer[idx])) {
                    color[idx] = shadeColorFixed(pixel, intensity);
                    shaded_pixels += 1;
                }
                intensity = clampIntensityFixed(intensity + delta_intensity);
            }
        }
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const pixel = color[idx];
            if (pixel != clear_color and std.math.isFinite(depth_buffer[idx])) {
                color[idx] = shadeColorFixed(pixel, intensity);
                shaded_pixels += 1;
            }
            intensity = clampIntensityFixed(intensity + delta_intensity);
        }
    }
    return shaded_pixels;
}

fn shadeRowsColorOnly(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
) usize {
    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    const clear_color = config.clear_color;
    var shaded_pixels: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        const screen_y = if (resources.target.height > 1)
            (@as(f32, @floatFromInt(y)) / frame_height_f) * 2.0 - 1.0
        else
            0.0;
        var intensity = shadeIntensityStart(bounds.min_x, frame_width_f, screen_y, normalized_light, config);
        var x = bounds.min_x;
        while (x + 3 <= bounds.max_x) : (x += 4) {
            inline for (0..4) |lane| {
                const idx = row_start + @as(usize, @intCast(x + @as(i32, @intCast(lane))));
                const pixel = color[idx];
                if (pixel != clear_color) {
                    color[idx] = shadeColorFixed(pixel, intensity);
                    shaded_pixels += 1;
                }
                intensity = clampIntensityFixed(intensity + delta_intensity);
            }
        }
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const pixel = color[idx];
            if (pixel != clear_color) {
                color[idx] = shadeColorFixed(pixel, intensity);
                shaded_pixels += 1;
            }
            intensity = clampIntensityFixed(intensity + delta_intensity);
        }
    }
    return shaded_pixels;
}

const ShadeJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    config: Config,
    normalized_light: math.Vec3,
    frame_width_f: f32,
    frame_height_f: f32,
    delta_intensity: i32,
    shaded_pixels: usize,
};

fn noopShadeJob(_: *anyopaque) void {}

fn shadeRowsJob(ctx_ptr: *anyopaque) void {
    const ctx: *ShadeJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.shaded_pixels = shadeRows(
        ctx.resources,
        ctx.bounds,
        ctx.config,
        ctx.normalized_light,
        ctx.frame_width_f,
        ctx.frame_height_f,
        ctx.delta_intensity,
    );
}

inline fn shouldParallelShade(job_sys: ?*JobSystem, width: i32, height: i32) bool {
    if (job_sys == null) return false;
    const area = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    return area >= 32 * 1024 and job_sys.?.worker_count > 1;
}

inline fn normalizeLight(light: math.Vec3) math.Vec3 {
    const length_sq = light.x * light.x + light.y * light.y + light.z * light.z;
    if (length_sq <= 0.0) return math.Vec3.new(0.0, 0.0, 1.0);
    const inv_len = 1.0 / std.math.sqrt(length_sq);
    return math.Vec3.new(light.x * inv_len, light.y * inv_len, light.z * inv_len);
}

inline fn shadeIntensityStart(min_x: i32, frame_width_f: f32, screen_y: f32, light_dir: math.Vec3, config: Config) i32 {
    const screen_x = if (frame_width_f > 0.0)
        (@as(f32, @floatFromInt(min_x)) / frame_width_f) * 2.0 - 1.0
    else
        0.0;
    return intensityToFixed(shadeIntensity(screen_x, screen_y, light_dir, config));
}

inline fn intensityToFixed(intensity: f32) i32 {
    return @as(i32, @intFromFloat(@round(std.math.clamp(intensity, 0.0, 1.0) * 256.0)));
}

inline fn clampIntensityFixed(intensity: i32) i32 {
    return std.math.clamp(intensity, 0, 256);
}

inline fn shadeIntensity(screen_x: f32, screen_y: f32, light_dir: math.Vec3, config: Config) f32 {
    const directional = light_dir.z - (screen_x * 0.22 * light_dir.x) - (screen_y * 0.28 * light_dir.y);
    const diffuse = std.math.clamp(directional, 0.0, 1.0);
    return std.math.clamp(config.ambient + config.diffuse * diffuse, 0.0, 1.0);
}

inline fn shadeColorFixed(color: u32, intensity_fixed: i32) u32 {
    if (intensity_fixed >= 256) return color;
    if (intensity_fixed <= 0) return color & 0xFF000000;
    const a: u32 = color & 0xFF000000;
    const factor: u32 = @intCast(intensity_fixed);
    const r = (((color >> 16) & 0xFF) * factor + 128) >> 8;
    const g = (((color >> 8) & 0xFF) * factor + 128) >> 8;
    const b = (((color) & 0xFF) * factor + 128) >> 8;
    return a | (r << 16) | (g << 8) | b;
}

// === Deferred lighting MVP (ROADMAP §H4) ===
//
// Reads the G-buffer surfaces produced by the deferred rasterizer
// (scene_base_color, scene_normal, scene_depth) and writes a Phong-lit
// colour to the backbuffer. Lambertian diffuse + constant ambient with
// a single directional light. Per-tile job decomposition for N-core
// scaling. Telemetry: returns lit_pixel_count + caller times the call.
//
// Bigger lighting model (PBR / Cook-Torrance) lands in H8; this MVP
// just proves the data flow and the parallel decomposition.

pub const DeferredConfig = struct {
    ambient: f32 = 0.18,
    /// Direction TOWARDS the light from the surface (camera space).
    /// Lambert convention: n · l > 0 for surfaces facing the light.
    /// Default is a key light from upper-left-back of the camera.
    light_dir_camera: math.Vec3 = math.Vec3.new(0.35, 0.45, -0.82),
    light_color: math.Vec3 = math.Vec3.new(1.0, 0.97, 0.92),
    /// Scalar intensity multiplier on the direct contribution. >1 puts
    /// real HDR values (>1.0) into scene_hdr so downstream bloom and
    /// tone-map can produce a natural exposure curve. Ambient is NOT
    /// scaled (it's already a small term). PBR's `1/π` energy
    /// conservation eats roughly a factor of π in apparent brightness,
    /// so this default is tuned to give max_lum ~3 with the cornell
    /// scene at default materials.
    intensity: f32 = 10.0,
    /// tan(fov_y/2) — used to reconstruct per-pixel view direction in
    /// camera space for PBR's specular term. Defaults to a 60° FOV;
    /// caller should fill this with the actual camera FOV.
    fov_y_tan_half: f32 = 0.5773,
    /// Width / height aspect ratio of the rendered frame.
    aspect: f32 = 16.0 / 9.0,
};

pub const DeferredResult = struct {
    lit_pixels: usize = 0,
    bounds: ?direct_primitives.Rect2i = null,
};

pub fn executeDeferred(
    resources: frame_resources.FrameResources,
    dirty_rect: ?direct_primitives.Rect2i,
    config: DeferredConfig,
    job_sys: ?*JobSystem,
) DeferredResult {
    const rect = dirty_rect orelse return .{};
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    if (resources.target.depth == null) return .{};
    if (resources.aux.scene_base_color.len == 0 or resources.aux.scene_normal.len == 0) return .{};

    const light = normalizeLight(config.light_dir_camera);
    if (shouldParallelShade(job_sys, bounds.max_x - bounds.min_x + 1, bounds.max_y - bounds.min_y + 1)) {
        return executeDeferredParallel(resources, bounds, config, light, job_sys.?);
    }
    return .{
        .lit_pixels = lightRowsDeferred(resources, bounds, config, light),
        .bounds = bounds,
    };
}

fn executeDeferredParallel(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: DeferredConfig,
    light: math.Vec3,
    job_sys: *JobSystem,
) DeferredResult {
    const total_rows: usize = @intCast(bounds.max_y - bounds.min_y + 1);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]LightJobContext = undefined;
    var parent_job = Job.init(noopShadeJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var row_start = bounds.min_y;

    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const remaining_rows = @as(usize, @intCast(bounds.max_y - row_start + 1));
        const remaining_chunks = chunk_count - chunk_index;
        const chunk_rows = @max(remaining_rows / remaining_chunks, 1);
        const row_end = @min(bounds.max_y, row_start + @as(i32, @intCast(chunk_rows)) - 1);
        contexts[chunk_index] = .{
            .resources = resources,
            .bounds = .{
                .min_x = bounds.min_x,
                .min_y = row_start,
                .max_x = bounds.max_x,
                .max_y = row_end,
            },
            .config = config,
            .light = light,
            .lit_pixels = 0,
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(lightRowsDeferredJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                lightRowsDeferredJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }
    if (main_chunk) |idx| lightRowsDeferredJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);
    var total: usize = 0;
    for (contexts[0..chunk_count]) |ctx| total += ctx.lit_pixels;
    return .{ .lit_pixels = total, .bounds = bounds };
}

const LightJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    config: DeferredConfig,
    light: math.Vec3,
    lit_pixels: usize,
};

fn lightRowsDeferredJob(ctx_ptr: *anyopaque) void {
    const ctx: *LightJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.lit_pixels = lightRowsDeferred(ctx.resources, ctx.bounds, ctx.config, ctx.light);
}

fn lightRowsDeferred(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: DeferredConfig,
    light: math.Vec3,
) usize {
    // H8 PBR: Cook-Torrance microfacet (GGX D + Smith-Schlick G +
    // Schlick Fresnel). Explicit SIMD over N pixels per iteration where
    // N = cpu_features.SIMD_F32_LANES (4/8/16). Branchy fast-paths
    // (depth-miss skip, n·l ≤ 0 ambient-only) are replaced by @select
    // blends so the inner loop is pure straight-line SIMD.
    const depth = resources.target.depth.?;
    const base = resources.aux.scene_base_color;
    const normal = resources.aux.scene_normal;
    const material = resources.aux.scene_material;
    const hdr = resources.aux.scene_hdr;
    const stride: usize = @intCast(resources.target.width);
    const width_f: f32 = @floatFromInt(resources.target.width);
    const height_f: f32 = @floatFromInt(resources.target.height);
    const ambient = config.ambient;
    const intensity = config.intensity;
    const light_r = config.light_color.x;
    const light_g = config.light_color.y;
    const light_b = config.light_color.z;
    const inv_255: f32 = 1.0 / 255.0;
    const fov_t = config.fov_y_tan_half;
    const aspect = config.aspect;
    const pi = std.math.pi;

    // SIMD-wide constants set up once per call.
    const LANES: usize = cpu_features.SIMD_F32_LANES;
    const VF = @Vector(LANES, f32);
    const VU = @Vector(LANES, u32);
    const v_one: VF = @splat(1.0);
    const v_zero: VF = @splat(0.0);
    const v_eps: VF = @splat(1.0e-4);
    const v_inv_pi: VF = @splat(1.0 / pi);
    const v_ambient: VF = @splat(ambient);
    const v_intensity: VF = @splat(intensity);
    const v_light_r: VF = @splat(light_r);
    const v_light_g: VF = @splat(light_g);
    const v_light_b: VF = @splat(light_b);
    const v_light_x: VF = @splat(light.x);
    const v_light_y: VF = @splat(light.y);
    const v_light_z: VF = @splat(light.z);
    const v_inv_255: VF = @splat(inv_255);
    const v_byte_mask: VU = @splat(0xFF);
    const v_inf: VF = @splat(1.0e30);
    const v_f04: VF = @splat(0.04);
    const v_0125: VF = @splat(0.125);
    const v_4: VF = @splat(4.0);
    const v_pi: VF = @splat(pi);
    const v_inv_width: VF = @splat(2.0 / width_f);
    const v_neg1: VF = @splat(-1.0);
    const v_min04: VF = @splat(0.04); // minimum roughness floor (squared denom protection)
    var lit: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const ndc_y: f32 = 1.0 - (yf + 0.5) / height_f * 2.0;
        const view_y_s = ndc_y * fov_t;
        const v_view_y: VF = @splat(view_y_s);
        const row_start = @as(usize, @intCast(y)) * stride;
        var x = bounds.min_x;

        // ----- SIMD body: process LANES pixels per iteration -----
        const lanes_i: i32 = @intCast(LANES);
        while (x + lanes_i <= bounds.max_x + 1) : (x += lanes_i) {
            const base_idx = row_start + @as(usize, @intCast(x));
            // x indices (0..LANES) in the lane vector
            var v_x_idx: VF = undefined;
            comptime var li: usize = 0;
            inline while (li < LANES) : (li += 1) {
                v_x_idx[li] = @as(f32, @floatFromInt(x + @as(i32, @intCast(li))));
            }
            // NDC.x for each lane: (x+0.5)/W*2 - 1
            const v_ndc_x = (v_x_idx + @as(VF, @splat(0.5))) * v_inv_width + @as(VF, @splat(-1.0));
            const v_view_x = v_ndc_x * @as(VF, @splat(aspect * fov_t));
            // |ray| inv = 1 / sqrt(vx² + vy² + 1)
            const v_ray_len2 = v_view_x * v_view_x + v_view_y * v_view_y + v_one;
            const v_ray_len_inv = v_one / @sqrt(v_ray_len2);
            const v_vx = v_neg1 * v_view_x * v_ray_len_inv;
            const v_vy = v_neg1 * v_view_y * v_ray_len_inv;
            const v_vz = v_neg1 * v_ray_len_inv;

            // Gather depth + per-lane validity (finite & < far)
            var v_depth: VF = undefined;
            inline while (li < 2 * LANES) : (li += 1) {} // appease loop counter
            comptime var gi: usize = 0;
            inline while (gi < LANES) : (gi += 1) {
                v_depth[gi] = depth[base_idx + gi];
            }
            const finite_mask = v_depth == v_depth; // NaN test: NaN != NaN
            const within_mask = v_depth < v_inf;
            const lit_mask = @select(bool, finite_mask, within_mask, @as(@Vector(LANES, bool), @splat(false)));

            // Gather normals (Vec3 → 3 scalar reads per lane)
            var v_nx: VF = undefined;
            var v_ny: VF = undefined;
            var v_nz: VF = undefined;
            comptime var ni: usize = 0;
            inline while (ni < LANES) : (ni += 1) {
                const nrm = normal[base_idx + ni];
                v_nx[ni] = nrm.x;
                v_ny[ni] = nrm.y;
                v_nz[ni] = nrm.z;
            }

            // Gather albedo (packed u32 → 3 f32 channels)
            var v_albedo: VU = undefined;
            comptime var ai: usize = 0;
            inline while (ai < LANES) : (ai += 1) {
                v_albedo[ai] = base[base_idx + ai];
            }
            const v_ar = @as(VF, @floatFromInt((v_albedo >> @splat(16)) & v_byte_mask)) * v_inv_255;
            const v_ag = @as(VF, @floatFromInt((v_albedo >> @splat(8)) & v_byte_mask)) * v_inv_255;
            const v_ab = @as(VF, @floatFromInt(v_albedo & v_byte_mask)) * v_inv_255;

            // Material
            var v_mat: VU = undefined;
            comptime var mi: usize = 0;
            inline while (mi < LANES) : (mi += 1) {
                v_mat[mi] = material[base_idx + mi];
            }
            const v_rough_raw = @as(VF, @floatFromInt(v_mat & v_byte_mask)) * v_inv_255;
            const v_roughness = @max(v_min04, v_rough_raw);
            const v_metallic = @as(VF, @floatFromInt((v_mat >> @splat(8)) & v_byte_mask)) * v_inv_255;
            const v_ao = @as(VF, @floatFromInt((v_mat >> @splat(16)) & v_byte_mask)) * v_inv_255;

            // n·l (clamped)
            const v_ndotl_raw = v_nx * v_light_x + v_ny * v_light_y + v_nz * v_light_z;
            const v_ndotl = @max(v_zero, v_ndotl_raw);
            // n·v (clamped)
            const v_ndotv = @max(v_zero, v_nx * v_vx + v_ny * v_vy + v_nz * v_vz);

            // Half-vector H = normalize(L + V)
            const v_hx_raw = v_light_x + v_vx;
            const v_hy_raw = v_light_y + v_vy;
            const v_hz_raw = v_light_z + v_vz;
            const v_h_len2 = v_hx_raw * v_hx_raw + v_hy_raw * v_hy_raw + v_hz_raw * v_hz_raw;
            const v_h_len_inv = v_one / @max(v_eps, @sqrt(v_h_len2));
            const v_hx = v_hx_raw * v_h_len_inv;
            const v_hy = v_hy_raw * v_h_len_inv;
            const v_hz = v_hz_raw * v_h_len_inv;
            const v_ndoth = @max(v_zero, v_nx * v_hx + v_ny * v_hy + v_nz * v_hz);
            const v_vdoth = @max(v_zero, v_vx * v_hx + v_vy * v_hy + v_vz * v_hz);

            // F0 per-channel: lerp(0.04, albedo, metallic)
            const v_f0r = v_f04 + (v_ar - v_f04) * v_metallic;
            const v_f0g = v_f04 + (v_ag - v_f04) * v_metallic;
            const v_f0b = v_f04 + (v_ab - v_f04) * v_metallic;

            // GGX D
            const v_alpha = v_roughness * v_roughness;
            const v_alpha2 = v_alpha * v_alpha;
            const v_ndh2 = v_ndoth * v_ndoth;
            const v_d_denom = v_ndh2 * (v_alpha2 - v_one) + v_one;
            const v_D = v_alpha2 / @max(v_eps, v_pi * v_d_denom * v_d_denom);

            // Smith-Schlick G
            const v_r1 = v_roughness + v_one;
            const v_k = (v_r1 * v_r1) * v_0125;
            const v_g1v = v_ndotv / @max(v_eps, v_ndotv * (v_one - v_k) + v_k);
            const v_g1l = v_ndotl / @max(v_eps, v_ndotl * (v_one - v_k) + v_k);
            const v_G = v_g1v * v_g1l;

            // Fresnel-Schlick: f0 + (1-f0)*(1-v·h)⁵
            const v_omvdh = v_one - v_vdoth;
            const v_omvdh2 = v_omvdh * v_omvdh;
            const v_fs = v_omvdh2 * v_omvdh2 * v_omvdh;
            const v_Fr = v_f0r + (v_one - v_f0r) * v_fs;
            const v_Fg = v_f0g + (v_one - v_f0g) * v_fs;
            const v_Fb = v_f0b + (v_one - v_f0b) * v_fs;

            // Specular = D·G·F / (4 n·v n·l)
            const v_spec_denom = @max(v_eps, v_4 * v_ndotv * v_ndotl);
            const v_DG_over = v_D * v_G / v_spec_denom;
            const v_spec_r = v_DG_over * v_Fr;
            const v_spec_g = v_DG_over * v_Fg;
            const v_spec_b = v_DG_over * v_Fb;

            // Diffuse = kD·albedo/π, kD = (1-F)(1-metal)
            const v_kdr = (v_one - v_Fr) * (v_one - v_metallic);
            const v_kdg = (v_one - v_Fg) * (v_one - v_metallic);
            const v_kdb = (v_one - v_Fb) * (v_one - v_metallic);
            const v_diff_r = v_kdr * v_ar * v_inv_pi;
            const v_diff_g = v_kdg * v_ag * v_inv_pi;
            const v_diff_b = v_kdb * v_ab * v_inv_pi;

            // Final radiance (n·l == 0 → diffuse/spec terms are zero
            // already since they're multiplied by n_dot_l in radiance
            // scale; ambient term gives the dim ambient fall-through).
            const v_rad = v_ndotl * v_intensity;
            const v_out_r = v_ambient * v_ar * v_ao + (v_diff_r + v_spec_r) * v_light_r * v_rad;
            const v_out_g = v_ambient * v_ag * v_ao + (v_diff_g + v_spec_g) * v_light_g * v_rad;
            const v_out_b = v_ambient * v_ab * v_ao + (v_diff_b + v_spec_b) * v_light_b * v_rad;

            // Scatter results per-lane based on lit_mask. Skipped
            // lanes get a transparent zero so the tonemap leaves the
            // cleared backbuffer alone.
            comptime var wi: usize = 0;
            inline while (wi < LANES) : (wi += 1) {
                if (lit_mask[wi]) {
                    hdr[base_idx + wi] = math.Vec4.new(v_out_r[wi], v_out_g[wi], v_out_b[wi], 1.0);
                    lit += 1;
                } else {
                    hdr[base_idx + wi] = math.Vec4.new(0.0, 0.0, 0.0, 0.0);
                }
            }
        }

        // ----- Scalar tail: handle the last (width % LANES) pixels -----
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const d = depth[idx];
            if (!std.math.isFinite(d) or d >= 1.0e30) {
                hdr[idx] = math.Vec4.new(0.0, 0.0, 0.0, 0.0);
                continue;
            }
            const xf: f32 = @floatFromInt(x);
            const ndc_x: f32 = (xf + 0.5) / width_f * 2.0 - 1.0;
            const view_x_s = ndc_x * aspect * fov_t;
            const ray_len_inv = 1.0 / @sqrt(view_x_s * view_x_s + view_y_s * view_y_s + 1.0);
            const sv_x = -view_x_s * ray_len_inv;
            const sv_y = -view_y_s * ray_len_inv;
            const sv_z = -ray_len_inv;
            const n = normal[idx];
            const n_dot_l = @max(0.0, n.x * light.x + n.y * light.y + n.z * light.z);
            const albedo_u = base[idx];
            const ar: f32 = @as(f32, @floatFromInt((albedo_u >> 16) & 0xFF)) * inv_255;
            const ag: f32 = @as(f32, @floatFromInt((albedo_u >> 8) & 0xFF)) * inv_255;
            const ab: f32 = @as(f32, @floatFromInt(albedo_u & 0xFF)) * inv_255;
            const mat = material[idx];
            const roughness = @max(0.04, @as(f32, @floatFromInt(mat & 0xFF)) * inv_255);
            const metallic = @as(f32, @floatFromInt((mat >> 8) & 0xFF)) * inv_255;
            const ao = @as(f32, @floatFromInt((mat >> 16) & 0xFF)) * inv_255;
            if (n_dot_l <= 0.0) {
                hdr[idx] = math.Vec4.new(ar * ambient * ao, ag * ambient * ao, ab * ambient * ao, 1.0);
                lit += 1;
                continue;
            }
            const n_dot_v = @max(0.0, n.x * sv_x + n.y * sv_y + n.z * sv_z);
            const hx = light.x + sv_x;
            const hy = light.y + sv_y;
            const hz = light.z + sv_z;
            const h_len_inv = 1.0 / @max(1e-4, @sqrt(hx * hx + hy * hy + hz * hz));
            const h_x = hx * h_len_inv;
            const h_y = hy * h_len_inv;
            const h_z = hz * h_len_inv;
            const n_dot_h = @max(0.0, n.x * h_x + n.y * h_y + n.z * h_z);
            const v_dot_h = @max(0.0, sv_x * h_x + sv_y * h_y + sv_z * h_z);
            const f0_r = 0.04 + (ar - 0.04) * metallic;
            const f0_g = 0.04 + (ag - 0.04) * metallic;
            const f0_b = 0.04 + (ab - 0.04) * metallic;
            const alpha = roughness * roughness;
            const alpha2 = alpha * alpha;
            const ndh2 = n_dot_h * n_dot_h;
            const d_denom = ndh2 * (alpha2 - 1.0) + 1.0;
            const D = alpha2 / @max(1e-4, pi * d_denom * d_denom);
            const r1 = roughness + 1.0;
            const k = (r1 * r1) * 0.125;
            const g1_v = n_dot_v / @max(1e-4, n_dot_v * (1.0 - k) + k);
            const g1_l = n_dot_l / @max(1e-4, n_dot_l * (1.0 - k) + k);
            const G = g1_v * g1_l;
            const omvdh = 1.0 - v_dot_h;
            const t2 = omvdh * omvdh;
            const fs = t2 * t2 * omvdh;
            const F_r = f0_r + (1.0 - f0_r) * fs;
            const F_g = f0_g + (1.0 - f0_g) * fs;
            const F_b = f0_b + (1.0 - f0_b) * fs;
            const spec_denom = @max(1e-4, 4.0 * n_dot_v * n_dot_l);
            const spec_r = D * G * F_r / spec_denom;
            const spec_g = D * G * F_g / spec_denom;
            const spec_b = D * G * F_b / spec_denom;
            const kd_r = (1.0 - F_r) * (1.0 - metallic);
            const kd_g = (1.0 - F_g) * (1.0 - metallic);
            const kd_b = (1.0 - F_b) * (1.0 - metallic);
            const inv_pi: f32 = 1.0 / pi;
            const diff_r = kd_r * ar * inv_pi;
            const diff_g = kd_g * ag * inv_pi;
            const diff_b = kd_b * ab * inv_pi;
            const radiance_scale = n_dot_l * intensity;
            const out_r = ambient * ar * ao + (diff_r + spec_r) * light_r * radiance_scale;
            const out_g = ambient * ag * ao + (diff_g + spec_g) * light_g * radiance_scale;
            const out_b = ambient * ab * ao + (diff_b + spec_b) * light_b * radiance_scale;
            hdr[idx] = math.Vec4.new(out_r, out_g, out_b, 1.0);
            lit += 1;
        }
    }
    return lit;
}

// === Tone-map stage (ROADMAP §H5) ===
//
// Reads the HDR scene buffer (Vec4 linear, written by deferred
// lighting), maps it to 8-bit sRGB-ish output, and stores the packed
// u32 in target.color. Uses Reinhard (x / (1+x)) which is cheap, monotonic,
// and the obvious starting point — H6 will swap in an ACES filmic curve.
//
// Pixels with hdr.w == 0 are treated as "sky / untouched" and skipped
// so the renderer's clear colour shows through. The lighting pass
// promises to write w=1 on lit pixels and w=0 on miss pixels.

pub const TonemapConfig = struct {
    /// Multiplier applied to HDR before the curve. >1 brightens, <1 dims.
    exposure: f32 = 1.0,
};

pub const TonemapResult = struct {
    mapped_pixels: usize = 0,
    bounds: ?direct_primitives.Rect2i = null,
};

pub fn executeTonemap(
    resources: frame_resources.FrameResources,
    dirty_rect: ?direct_primitives.Rect2i,
    config: TonemapConfig,
    job_sys: ?*JobSystem,
) TonemapResult {
    const rect = dirty_rect orelse return .{};
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    if (resources.aux.scene_hdr.len == 0 or resources.target.color.len == 0) return .{};

    if (shouldParallelShade(job_sys, bounds.max_x - bounds.min_x + 1, bounds.max_y - bounds.min_y + 1)) {
        return executeTonemapParallel(resources, bounds, config, job_sys.?);
    }
    return .{
        .mapped_pixels = tonemapRows(resources, bounds, config),
        .bounds = bounds,
    };
}

fn executeTonemapParallel(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: TonemapConfig,
    job_sys: *JobSystem,
) TonemapResult {
    const total_rows: usize = @intCast(bounds.max_y - bounds.min_y + 1);
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(worker_count, total_rows);
    var jobs: [64]Job = undefined;
    var contexts: [64]TonemapJobContext = undefined;
    var parent_job = Job.init(noopShadeJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var row_start = bounds.min_y;

    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const remaining_rows = @as(usize, @intCast(bounds.max_y - row_start + 1));
        const remaining_chunks = chunk_count - chunk_index;
        const chunk_rows = @max(remaining_rows / remaining_chunks, 1);
        const row_end = @min(bounds.max_y, row_start + @as(i32, @intCast(chunk_rows)) - 1);
        contexts[chunk_index] = .{
            .resources = resources,
            .bounds = .{
                .min_x = bounds.min_x,
                .min_y = row_start,
                .max_x = bounds.max_x,
                .max_y = row_end,
            },
            .config = config,
            .mapped_pixels = 0,
        };
        if (main_chunk == null) {
            main_chunk = chunk_index;
        } else {
            jobs[chunk_index] = Job.init(tonemapRowsJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[chunk_index], .high)) {
                tonemapRowsJob(&contexts[chunk_index]);
            }
        }
        row_start = row_end + 1;
    }
    if (main_chunk) |idx| tonemapRowsJob(&contexts[idx]);
    parent_job.complete();
    job_sys.waitFor(&parent_job);
    var total: usize = 0;
    for (contexts[0..chunk_count]) |ctx| total += ctx.mapped_pixels;
    return .{ .mapped_pixels = total, .bounds = bounds };
}

const TonemapJobContext = struct {
    resources: frame_resources.FrameResources align(64),
    bounds: direct_primitives.Rect2i,
    config: TonemapConfig,
    mapped_pixels: usize,
};

fn tonemapRowsJob(ctx_ptr: *anyopaque) void {
    const ctx: *TonemapJobContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mapped_pixels = tonemapRows(ctx.resources, ctx.bounds, ctx.config);
}

fn tonemapRows(
    resources: frame_resources.FrameResources,
    bounds: direct_primitives.Rect2i,
    config: TonemapConfig,
) usize {
    // ISA-portable explicit SIMD: lane count comes from the build
    // target so the same source compiles to 4-wide (SSE2/NEON), 8-wide
    // (AVX/AVX2/SVE), or 16-wide (AVX-512). Process N pixels per
    // iteration. HDR is Vec4 AoS; we de-interleave into channel
    // vectors via lane-wise gathers (compiler emits a shuffle since
    // the access pattern is statically known). The branch-on-w is
    // replaced by a blend so the kernel is straight-line SIMD with no
    // scalar fallback inside the loop.
    const lanes: usize = cpu_features.SIMD_F32_LANES;
    const VecF = @Vector(lanes, f32);
    const VecU = @Vector(lanes, u32);
    const VecBool = @Vector(lanes, bool);

    const color = resources.target.color;
    const hdr = resources.aux.scene_hdr;
    const stride: usize = @intCast(resources.target.width);
    const exposure_v: VecF = @splat(config.exposure);
    const one_v: VecF = @splat(1.0);
    const z255_v: VecF = @splat(255.0);
    const zero_v: VecF = @splat(0.0);
    const opaque_alpha: VecU = @splat(0xFF000000);
    const eight_v: VecBool = @splat(true);
    _ = eight_v;
    var mapped: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        var x = bounds.min_x;
        // 8-pixel vectorized body.
        while (x + @as(i32, @intCast(lanes)) <= bounds.max_x + 1) : (x += @as(i32, @intCast(lanes))) {
            const base_idx = row_start + @as(usize, @intCast(x));
            // Lane-wise gather from AoS hdr buffer. Compiler emits a
            // tight set of moves into the YMM registers.
            var rv: VecF = undefined;
            var gv: VecF = undefined;
            var bv: VecF = undefined;
            var wv: VecF = undefined;
            comptime var lane: usize = 0;
            inline while (lane < lanes) : (lane += 1) {
                rv[lane] = hdr[base_idx + lane].x;
                gv[lane] = hdr[base_idx + lane].y;
                bv[lane] = hdr[base_idx + lane].z;
                wv[lane] = hdr[base_idx + lane].w;
            }
            const r = rv * exposure_v;
            const g = gv * exposure_v;
            const b = bv * exposure_v;
            const r_t = r / (one_v + r);
            const g_t = g / (one_v + g);
            const b_t = b / (one_v + b);
            const r_out_f = @min(z255_v, @max(zero_v, r_t * z255_v));
            const g_out_f = @min(z255_v, @max(zero_v, g_t * z255_v));
            const b_out_f = @min(z255_v, @max(zero_v, b_t * z255_v));
            const r_u: VecU = @intFromFloat(r_out_f);
            const g_u: VecU = @intFromFloat(g_out_f);
            const b_u: VecU = @intFromFloat(b_out_f);
            const new_color = opaque_alpha | (r_u << @splat(16)) | (g_u << @splat(8)) | b_u;
            // Mask: only overwrite pixels where the HDR write flag (w)
            // is non-zero. Skipping unwritten pixels keeps the clear
            // colour for sky / non-rasterized regions.
            const lit_mask = wv != zero_v;
            comptime var w_lane: usize = 0;
            inline while (w_lane < lanes) : (w_lane += 1) {
                if (lit_mask[w_lane]) {
                    color[base_idx + w_lane] = new_color[w_lane];
                    mapped += 1;
                }
            }
        }
        // Scalar tail for the final 0-7 pixels of the row.
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const v = hdr[idx];
            if (v.w == 0.0) continue;
            const r = v.x * config.exposure;
            const g = v.y * config.exposure;
            const b = v.z * config.exposure;
            const r_t = r / (1.0 + r);
            const g_t = g / (1.0 + g);
            const b_t = b / (1.0 + b);
            const r_out: u32 = @intFromFloat(@min(255.0, @max(0.0, r_t * 255.0)));
            const g_out: u32 = @intFromFloat(@min(255.0, @max(0.0, g_t * 255.0)));
            const b_out: u32 = @intFromFloat(@min(255.0, @max(0.0, b_t * 255.0)));
            color[idx] = 0xFF000000 | (r_out << 16) | (g_out << 8) | b_out;
            mapped += 1;
        }
    }
    return mapped;
}

test "shading stage shades non-clear pixels in dirty rect" {
    var color = [_]u32{
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
        0xFF0B1220, 0xFFFF0000, 0xFF00FF00, 0xFF0B1220,
        0xFF0B1220, 0xFF0000FF, 0xFFFFFFFF, 0xFF0B1220,
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
    };
    var depth = [_]f32{
        std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), std.math.inf(f32),
        std.math.inf(f32), 1.0, 1.0, std.math.inf(f32),
        std.math.inf(f32), 1.0, 1.0, std.math.inf(f32),
        std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), std.math.inf(f32),
    };
    const resources: frame_resources.FrameResources = .{
        .target = .{
            .width = 4,
            .height = 4,
            .color = color[0..],
            .depth = depth[0..],
        },
        .aux = .{
            .scene_camera = &.{},
            .scene_normal = &.{},
            .scene_surface = &.{},
            .scene_base_color = &.{},
            .scene_material = &.{},
            .scene_hdr = &.{},
        },
    };

    const result = execute(resources, .{
        .min_x = 1,
        .min_y = 1,
        .max_x = 2,
        .max_y = 3,
    }, .{}, null);

    try std.testing.expectEqual(@as(usize, 4), result.shaded_pixels);
    try std.testing.expect(color[5] != 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0B1220), color[0]);
}
