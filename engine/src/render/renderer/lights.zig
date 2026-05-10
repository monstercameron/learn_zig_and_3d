const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const texture = @import("../../assets/texture.zig");

const Renderer = renderer_module.Renderer;
const LightInfo = renderer_module.LightInfo;
const ShadowMap = renderer_module.ShadowMap;
const renderer_logger = renderer_module.renderer_logger;
pub fn defaultLightColor(light_idx: usize) math.Vec3 {
    return if ((light_idx & 1) == 0)
        math.Vec3.new(1.0, 0.9, 0.8)
    else
        math.Vec3.new(0.5, 0.6, 1.0);
}

pub fn defaultLightShadowMode() LightInfo.ShadowMode {
    if (config.MESHLET_SHADOWS_ENABLED) return .meshlet_ray;
    if (config.POST_SHADOW_ENABLED) return .shadow_map;
    return .none;
}

/// initLightInfo initializes Renderer state and returns the configured value.
pub fn initLightInfo(allocator: std.mem.Allocator, light_idx: usize) !LightInfo {
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

pub fn syncLightSoA(renderer: *Renderer) void {
    for (renderer.lights.items, 0..) |light, i| {
        renderer.light_soa.dir_x[i] = light.direction.x;
        renderer.light_soa.dir_y[i] = light.direction.y;
        renderer.light_soa.dir_z[i] = light.direction.z;
        renderer.light_soa.distance[i] = light.distance;
        renderer.light_soa.shadow_mode[i] = @intFromEnum(light.shadow_mode);
    }
}

pub fn syncLightCameraSoA(renderer: *Renderer, basis_right: math.Vec3, basis_up: math.Vec3, basis_forward: math.Vec3) void {
    for (renderer.lights.items, 0..) |_, i| {
        const dir_x = renderer.light_soa.dir_x[i];
        const dir_y = renderer.light_soa.dir_y[i];
        const dir_z = renderer.light_soa.dir_z[i];
        renderer.light_soa.dir_cam_x[i] = dir_x * basis_right.x + dir_y * basis_right.y + dir_z * basis_right.z;
        renderer.light_soa.dir_cam_y[i] = dir_x * basis_up.x + dir_y * basis_up.y + dir_z * basis_up.z;
        renderer.light_soa.dir_cam_z[i] = dir_x * basis_forward.x + dir_y * basis_forward.y + dir_z * basis_forward.z;
    }
}

pub fn countLightsWithShadowMode(renderer: *const Renderer, mode: LightInfo.ShadowMode) usize {
    var count: usize = 0;
    for (renderer.lights.items) |light| {
        if (light.shadow_mode == mode) count += 1;
    }
    return count;
}

fn totalShadowMapBytes(renderer: *const Renderer) usize {
    var total_bytes: usize = 0;
    for (renderer.lights.items) |light| {
        total_bytes += light.shadow_map.width * light.shadow_map.height * @sizeOf(f32);
    }
    return total_bytes;
}

/// Computes shadow build budget ns.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn computeShadowBuildBudgetNs(renderer: *const Renderer) i128 {
    if (renderer.target_frame_time_ns <= 0) return -1;
    const budget_percent = std.math.clamp(config.POST_SHADOW_BUDGET_PERCENT, 0, 100);
    if (budget_percent <= 0) return 0;
    if (budget_percent >= 100) return renderer.target_frame_time_ns;
    return @divTrunc(renderer.target_frame_time_ns * @as(i128, @intCast(budget_percent)), 100);
}

/// Estimates shadow build cost ns.
/// Keeps estimate shadow build cost ns as the single implementation point so call-site behavior stays consistent.
pub fn estimateShadowBuildCostNs(light: *const LightInfo) i128 {
    if (light.shadow_last_build_ns > 0) return light.shadow_last_build_ns;
    const shadow_texel_count = light.shadow_map.width * light.shadow_map.height;
    const texel_estimate_ns: i128 = @intCast(shadow_texel_count);
    return @max(@as(i128, 100_000), texel_estimate_ns);
}

fn resizeLightShadowMap(
    renderer: *Renderer,
    index: usize,
    shadow_map_size: usize,
    update_target_size: bool,
    reason: []const u8,
) !bool {
    if (index >= renderer.lights.items.len) return false;
    const clamped_size = std.math.clamp(shadow_map_size, @as(usize, 64), @as(usize, 4096));
    const light = &renderer.lights.items[index];
    if (update_target_size) {
        light.shadow_map_target_size = clamped_size;
    }
    if (light.shadow_map.width == clamped_size and light.shadow_map.height == clamped_size) return false;

    const prev_width = light.shadow_map.width;
    const prev_height = light.shadow_map.height;
    light.shadow_map.depth = try renderer.allocator.realloc(light.shadow_map.depth, clamped_size * clamped_size);
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

fn tryDownscaleOneShadowMapLight(renderer: *Renderer) !bool {
    var candidate_index: ?usize = null;
    var candidate_size: usize = 0;
    const min_size = @max(@as(usize, 64), config.POST_SHADOW_ADAPTIVE_MIN_MAP_SIZE);
    for (renderer.lights.items, 0..) |light, light_index| {
        if (light.shadow_mode != .shadow_map) continue;
        if (light.shadow_map.width <= min_size) continue;
        if (light.shadow_map.width > candidate_size) {
            candidate_size = light.shadow_map.width;
            candidate_index = light_index;
        }
    }
    if (candidate_index == null) return false;
    const idx = candidate_index.?;
    const current_size = renderer.lights.items[idx].shadow_map.width;
    const next_size = @max(min_size, current_size / 2);
    if (next_size >= current_size) return false;
    return resizeLightShadowMap(renderer, idx, next_size, false, "budget_downscale");
}

fn tryUpscaleOneShadowMapLight(renderer: *Renderer) !bool {
    var candidate_index: ?usize = null;
    var candidate_size: usize = std.math.maxInt(usize);
    for (renderer.lights.items, 0..) |light, light_index| {
        if (light.shadow_mode != .shadow_map) continue;
        if (light.shadow_map.width >= light.shadow_map_target_size) continue;
        if (light.shadow_map.width < candidate_size) {
            candidate_size = light.shadow_map.width;
            candidate_index = light_index;
        }
    }
    if (candidate_index == null) return false;
    const idx = candidate_index.?;
    const current_size = renderer.lights.items[idx].shadow_map.width;
    const target_size = renderer.lights.items[idx].shadow_map_target_size;
    const next_size = @min(target_size, current_size * 2);
    if (next_size <= current_size) return false;
    return resizeLightShadowMap(renderer, idx, next_size, false, "budget_upscale");
}

fn tryIncreaseShadowCadenceScale(renderer: *Renderer) bool {
    var candidate_index: ?usize = null;
    var candidate_cost_ns: i128 = 0;
    for (renderer.lights.items, 0..) |light, light_index| {
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
    const light = &renderer.lights.items[idx];
    light.shadow_dynamic_interval_scale = @min(config.POST_SHADOW_ADAPTIVE_MAX_INTERVAL_SCALE, light.shadow_dynamic_interval_scale * 2);
    renderer_logger.infoSub(
        "lights",
        "light {} shadow cadence scale increased to {}x",
        .{ idx, light.shadow_dynamic_interval_scale },
    );
    return true;
}

fn tryDecreaseShadowCadenceScale(renderer: *Renderer) bool {
    var candidate_index: ?usize = null;
    var candidate_scale: u32 = 1;
    for (renderer.lights.items, 0..) |light, light_index| {
        if (light.shadow_mode != .shadow_map) continue;
        if (light.shadow_dynamic_interval_scale <= 1) continue;
        if (light.shadow_dynamic_interval_scale > candidate_scale) {
            candidate_scale = light.shadow_dynamic_interval_scale;
            candidate_index = light_index;
        }
    }
    if (candidate_index == null) return false;
    const idx = candidate_index.?;
    const light = &renderer.lights.items[idx];
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
pub fn applyAdaptiveShadowBudgetPolicy(renderer: *Renderer) !void {
    if (!config.POST_SHADOW_ENABLED) return;
    if (!config.POST_SHADOW_ADAPTIVE_RESOLUTION_ENABLED) return;
    if (renderer.light_work_stats.shadow_map_lights == 0) return;
    const shadow_budget_ns = renderer.light_work_stats.shadow_budget_ns;
    if (shadow_budget_ns <= 0) return;

    if (renderer.light_work_stats.shadow_budget_skipped_lights > 0) {
        renderer.shadow_budget_pressure_frames += 1;
        renderer.shadow_budget_relief_frames = 0;
        if (renderer.shadow_budget_pressure_frames >= config.POST_SHADOW_ADAPTIVE_PRESSURE_FRAMES) {
            if (try tryDownscaleOneShadowMapLight(renderer)) {
                renderer.light_work_stats.shadow_map_downscaled_lights += 1;
            } else if (tryIncreaseShadowCadenceScale(renderer)) {
                renderer.light_work_stats.shadow_cadence_increased_lights += 1;
            }
            renderer.shadow_budget_pressure_frames = 0;
        }
        return;
    }

    const recovery_budget_percent = std.math.clamp(config.POST_SHADOW_ADAPTIVE_RECOVERY_BUDGET_PERCENT, 1, 100);
    const within_recovery_budget = (renderer.light_work_stats.shadow_build_ns * 100) <=
        (shadow_budget_ns * @as(i128, @intCast(recovery_budget_percent)));
    if (!within_recovery_budget) {
        renderer.shadow_budget_relief_frames = 0;
        return;
    }

    renderer.shadow_budget_relief_frames += 1;
    if (renderer.shadow_budget_relief_frames < config.POST_SHADOW_ADAPTIVE_RECOVERY_FRAMES) return;
    if (try tryUpscaleOneShadowMapLight(renderer)) {
        renderer.light_work_stats.shadow_map_upscaled_lights += 1;
    } else if (tryDecreaseShadowCadenceScale(renderer)) {
        renderer.light_work_stats.shadow_cadence_decreased_lights += 1;
    }
    renderer.shadow_budget_relief_frames = 0;
}

/// init initializes Renderer state and returns the configured value.

pub fn setTexture(renderer: *Renderer, tex: *const texture.Texture) void {
    renderer.single_texture_binding[0] = tex;
    renderer.textures = renderer.single_texture_binding[0..];
}

/// Sets s et hd ri ma p.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setHdriMap(renderer: *Renderer, hdri_map: texture.HdrTexture) void {
    renderer.hdri_map = hdri_map;
}

/// Sets s et te xt ur es.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setTextures(renderer: *Renderer, textures: []const ?*const texture.Texture) void {
    renderer.textures = textures;
}

/// Sets s et li gh tc ap ac it y.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setLightCapacity(renderer: *Renderer, light_count: usize) !void {
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
    if (desired_count > renderer.shadow_build_elapsed_ns.len) {
        const prev_len = renderer.shadow_build_elapsed_ns.len;
        renderer.shadow_build_elapsed_ns = try renderer.allocator.realloc(renderer.shadow_build_elapsed_ns, desired_count);
        @memset(renderer.shadow_build_elapsed_ns[prev_len..], 0);
    }
    if (desired_count > renderer.shadow_resolve_elapsed_ns.len) {
        const prev_len = renderer.shadow_resolve_elapsed_ns.len;
        renderer.shadow_resolve_elapsed_ns = try renderer.allocator.realloc(renderer.shadow_resolve_elapsed_ns, desired_count);
        @memset(renderer.shadow_resolve_elapsed_ns[prev_len..], 0);
    }
    if (desired_count > renderer.light_soa.distance.len) {
        renderer.light_soa.dir_x = try renderer.allocator.realloc(renderer.light_soa.dir_x, desired_count);
        renderer.light_soa.dir_y = try renderer.allocator.realloc(renderer.light_soa.dir_y, desired_count);
        renderer.light_soa.dir_z = try renderer.allocator.realloc(renderer.light_soa.dir_z, desired_count);
        renderer.light_soa.dir_cam_x = try renderer.allocator.realloc(renderer.light_soa.dir_cam_x, desired_count);
        renderer.light_soa.dir_cam_y = try renderer.allocator.realloc(renderer.light_soa.dir_cam_y, desired_count);
        renderer.light_soa.dir_cam_z = try renderer.allocator.realloc(renderer.light_soa.dir_cam_z, desired_count);
        renderer.light_soa.distance = try renderer.allocator.realloc(renderer.light_soa.distance, desired_count);
        renderer.light_soa.shadow_mode = try renderer.allocator.realloc(renderer.light_soa.shadow_mode, desired_count);
    }
    const tile_count = renderer.tile_light_ranges.len;
    const tile_light_capacity = @max(@as(usize, 1), tile_count * desired_count);
    if (tile_light_capacity > renderer.tile_light_indices.len) {
        renderer.tile_light_indices = try renderer.allocator.realloc(renderer.tile_light_indices, tile_light_capacity);
    }
    while (renderer.lights.items.len > desired_count) {
        const remove_index = renderer.lights.items.len - 1;
        const removed = renderer.lights.items[remove_index];
        renderer.allocator.free(removed.shadow_map.depth);
        renderer.lights.items.len = remove_index;
    }
    while (renderer.lights.items.len < desired_count) {
        const light_idx = renderer.lights.items.len;
        try renderer.lights.append(renderer.allocator, try initLightInfo(renderer.allocator, light_idx));
    }
    var min_shadow_size: usize = config.POST_SHADOW_MAP_SIZE;
    var max_shadow_size: usize = config.POST_SHADOW_MAP_SIZE;
    if (renderer.lights.items.len > 0) {
        min_shadow_size = renderer.lights.items[0].shadow_map.width;
        max_shadow_size = renderer.lights.items[0].shadow_map.width;
        for (renderer.lights.items[1..]) |light| {
            min_shadow_size = @min(min_shadow_size, light.shadow_map.width);
            max_shadow_size = @max(max_shadow_size, light.shadow_map.width);
        }
    }
    const total_shadow_bytes = totalShadowMapBytes(renderer);
    const should_log_light_capacity = !renderer.light_capacity_log_initialized or
        renderer.last_logged_light_capacity != renderer.lights.items.len or
        renderer.last_logged_min_shadow_size != min_shadow_size or
        renderer.last_logged_max_shadow_size != max_shadow_size or
        renderer.last_logged_total_shadow_bytes != total_shadow_bytes;
    if (should_log_light_capacity) {
        renderer_logger.infoSub(
            "lights",
            "capacity={} shadow_map_range={}..{} total_shadow_mem={d:.2} MiB",
            .{
                renderer.lights.items.len,
                min_shadow_size,
                max_shadow_size,
                @as(f64, @floatFromInt(total_shadow_bytes)) / (1024.0 * 1024.0),
            },
        );
        renderer.light_capacity_log_initialized = true;
        renderer.last_logged_light_capacity = renderer.lights.items.len;
        renderer.last_logged_min_shadow_size = min_shadow_size;
        renderer.last_logged_max_shadow_size = max_shadow_size;
        renderer.last_logged_total_shadow_bytes = total_shadow_bytes;
    }
    syncLightSoA(renderer);
    renderer.frame_view_cache.invalidate();
}

/// Sets s et di re ct io na ll ig ht.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setDirectionalLight(renderer: *Renderer, index: usize, direction: math.Vec3, distance: f32, color: ?math.Vec3) void {
    if (index >= renderer.lights.items.len) return;
    const dir_len = math.Vec3.length(direction);
    const normalized = if (dir_len > 1e-6)
        math.Vec3.scale(direction, 1.0 / dir_len)
    else
        math.Vec3.new(0.0, 1.0, 0.0);
    renderer.lights.items[index].direction = normalized;
    renderer.lights.items[index].distance = @max(distance, 0.01);
    if (color) |c| renderer.lights.items[index].color = c;
    renderer.lights.items[index].manual_direction = true;
    renderer.lights.items[index].shadow_map.active = false;
    renderer.lights.items[index].shadow_last_build_frame = 0;
    renderer.lights.items[index].shadow_last_build_ns = 0;
    if (index < renderer.shadow_build_elapsed_ns.len) renderer.shadow_build_elapsed_ns[index] = 0;
    if (index < renderer.shadow_resolve_elapsed_ns.len) renderer.shadow_resolve_elapsed_ns[index] = 0;
    syncLightSoA(renderer);
    renderer.frame_view_cache.invalidate();
}

/// Sets s et li gh ts ha do wm od e.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setLightShadowMode(renderer: *Renderer, index: usize, mode: LightInfo.ShadowMode) void {
    if (index >= renderer.lights.items.len) return;
    renderer.lights.items[index].shadow_mode = mode;
    renderer.light_soa.shadow_mode[index] = @intFromEnum(mode);
}

/// Sets s et li gh ts ha do wu pd at ei nt er va l.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setLightShadowUpdateInterval(renderer: *Renderer, index: usize, interval_frames: u32) void {
    if (index >= renderer.lights.items.len) return;
    renderer.lights.items[index].shadow_update_interval_frames = @max(@as(u32, 1), interval_frames);
    renderer.lights.items[index].shadow_dynamic_interval_scale = 1;
}

/// Sets s et li gh ts ha do wm ap si ze.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setLightShadowMapSize(renderer: *Renderer, index: usize, shadow_map_size: usize) !void {
    _ = try resizeLightShadowMap(renderer, index, shadow_map_size, true, "config");
}

/// Sets s et li gh tg lo w.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
pub fn setLightGlow(renderer: *Renderer, index: usize, radius: f32, intensity: f32) void {
    if (index >= renderer.lights.items.len) return;
    renderer.lights.items[index].glow_radius = std.math.clamp(radius, 0.0, 256.0);
    renderer.lights.items[index].glow_intensity = std.math.clamp(intensity, 0.0, 8.0);
}
