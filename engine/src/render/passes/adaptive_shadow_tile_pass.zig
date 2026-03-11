const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const hybrid_shadow_resolve_kernel = @import("../kernels/hybrid_shadow_resolve_kernel.zig");
const render_utils = @import("../utils.zig");

const near_clip: f32 = 0.01;
const hybrid_shadow_cache_unknown: u8 = 0xFF;
const hybrid_shadow_cache_invalid: u8 = 0xFE;

const ShadowSample = struct {
    valid: bool,
    coverage: f32,
};

const BlockClassification = struct {
    mixed: bool,
    shadowed: bool,
};

pub fn run(ctx: anytype) void {
    if (ctx.candidate_count == 0 or ctx.valid_max_x < ctx.valid_min_x or ctx.valid_max_y < ctx.valid_min_y) return;
    const width = ctx.valid_max_x - ctx.valid_min_x + 1;
    const height = ctx.valid_max_y - ctx.valid_min_y + 1;
    if (width <= 0 or height <= 0) return;
    processBlock(ctx, ctx.valid_min_x, ctx.valid_min_y, width, height, 0);
}

fn processBlock(ctx: anytype, x: i32, y: i32, width: i32, height: i32, depth: u32) void {
    if (width <= 0 or height <= 0) return;

    const classification = classifyBlock(ctx, x, y, width, height);
    if (!classification.mixed) {
        if (classification.shadowed) darkenBlock(ctx, x, y, width, height);
        return;
    }

    if (width <= config.POST_HYBRID_SHADOW_MIN_BLOCK_SIZE or height <= config.POST_HYBRID_SHADOW_MIN_BLOCK_SIZE or depth >= config.POST_HYBRID_SHADOW_MAX_DEPTH) {
        resolveBlockExact(ctx, x, y, width, height);
        return;
    }

    const half_w = @max(1, @divTrunc(width, 2));
    const half_h = @max(1, @divTrunc(height, 2));
    const rem_w = width - half_w;
    const rem_h = height - half_h;
    processBlock(ctx, x, y, half_w, half_h, depth + 1);
    if (rem_w > 0) processBlock(ctx, x + half_w, y, rem_w, half_h, depth + 1);
    if (rem_h > 0) processBlock(ctx, x, y + half_h, half_w, rem_h, depth + 1);
    if (rem_w > 0 and rem_h > 0) processBlock(ctx, x + half_w, y + half_h, rem_w, rem_h, depth + 1);
}

fn classifyBlock(ctx: anytype, x: i32, y: i32, width: i32, height: i32) BlockClassification {
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
        .{ x, center_y },
        .{ max_x, center_y },
        .{ center_x, y },
        .{ center_x, max_y },
    };

    var any_valid = false;
    var any_occluded = false;
    var any_lit = false;
    var any_invalid = false;
    for (sample_points) |point| {
        const sample = sampleShadow(ctx, point[0], point[1]);
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
    if (any_occluded) return .{ .mixed = false, .shadowed = true };
    return .{ .mixed = false, .shadowed = false };
}

fn evaluateShadowPoint(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
    if (screen_x < 0 or screen_y < 0 or screen_x >= ctx.renderer.bitmap.width or screen_y >= ctx.renderer.bitmap.height) {
        return .{ .valid = false, .coverage = 0.0 };
    }
    const scene_idx = @as(usize, @intCast(screen_y * ctx.renderer.bitmap.width + screen_x));
    if (scene_idx >= ctx.renderer.scene_camera.len) return .{ .valid = false, .coverage = 0.0 };

    const camera_pos = ctx.renderer.scene_camera[scene_idx];
    if (!std.math.isFinite(camera_pos.z) or camera_pos.z <= near_clip) {
        return .{ .valid = false, .coverage = 0.0 };
    }

    const light_sample = ctx.camera_to_light.project(camera_pos);
    return .{ .valid = true, .coverage = if (isPointShadowed(ctx, camera_pos, light_sample)) 1.0 else 0.0 };
}

fn evaluateShadowCellAtScale(ctx: anytype, cache_x: usize, cache_y: usize, shadow_scale: i32) ShadowSample {
    const origin_x = @as(i32, @intCast(cache_x * @as(usize, @intCast(shadow_scale))));
    const origin_y = @as(i32, @intCast(cache_y * @as(usize, @intCast(shadow_scale))));
    const max_x = @min(origin_x + shadow_scale - 1, ctx.renderer.bitmap.width - 1);
    const max_y = @min(origin_y + shadow_scale - 1, ctx.renderer.bitmap.height - 1);
    const center_x = @min(origin_x + @divTrunc(shadow_scale, 2), ctx.renderer.bitmap.width - 1);
    const center_y = @min(origin_y + @divTrunc(shadow_scale, 2), ctx.renderer.bitmap.height - 1);
    const center = evaluateShadowPoint(ctx, center_x, center_y);
    if (!center.valid or shadow_scale <= 2) return center;

    const corner_a = evaluateShadowPoint(ctx, origin_x, origin_y);
    const corner_b = evaluateShadowPoint(ctx, max_x, origin_y);
    const corner_c = evaluateShadowPoint(ctx, origin_x, max_y);
    const corner_d = evaluateShadowPoint(ctx, max_x, max_y);

    var min_c = center.coverage;
    var max_c = center.coverage;
    if (corner_a.valid) {
        min_c = @min(min_c, corner_a.coverage);
        max_c = @max(max_c, corner_a.coverage);
    }
    if (corner_b.valid) {
        min_c = @min(min_c, corner_b.coverage);
        max_c = @max(max_c, corner_b.coverage);
    }
    if (corner_c.valid) {
        min_c = @min(min_c, corner_c.coverage);
        max_c = @max(max_c, corner_c.coverage);
    }
    if (corner_d.valid) {
        min_c = @min(min_c, corner_d.coverage);
        max_c = @max(max_c, corner_d.coverage);
    }

    if (min_c == max_c) return .{ .valid = true, .coverage = min_c };
    return .{ .valid = true, .coverage = 0.5 };
}

fn sampleShadowCache(ctx: anytype, cache: []u8, cache_width: usize, cache_height: usize, shadow_scale: i32, screen_x: i32, screen_y: i32) ShadowSample {
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
            const evaluated = evaluateShadowCellAtScale(ctx, @intCast(coord[0]), @intCast(coord[1]), shadow_scale);
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

fn sampleShadowCacheNearest(ctx: anytype, cache: []u8, cache_width: usize, cache_height: usize, shadow_scale: i32, screen_x: i32, screen_y: i32) ShadowSample {
    if (screen_x < 0 or screen_y < 0 or screen_x >= ctx.renderer.bitmap.width or screen_y >= ctx.renderer.bitmap.height) {
        return .{ .valid = false, .coverage = 0.0 };
    }

    const cache_x = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(screen_x)) / @as(f32, @floatFromInt(shadow_scale))))), 0, @as(i32, @intCast(cache_width - 1)));
    const cache_y = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(screen_y)) / @as(f32, @floatFromInt(shadow_scale))))), 0, @as(i32, @intCast(cache_height - 1)));
    const cache_idx = @as(usize, @intCast(cache_y)) * cache_width + @as(usize, @intCast(cache_x));
    var cached = cache[cache_idx];
    if (cached == hybrid_shadow_cache_unknown) {
        const evaluated = evaluateShadowCellAtScale(ctx, @intCast(cache_x), @intCast(cache_y), shadow_scale);
        cached = if (!evaluated.valid)
            hybrid_shadow_cache_invalid
        else
            @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(evaluated.coverage * 253.0))), 0, 253));
        cache[cache_idx] = cached;
    }

    if (cached == hybrid_shadow_cache_invalid) return .{ .valid = false, .coverage = 0.0 };
    return .{ .valid = true, .coverage = @as(f32, @floatFromInt(cached)) / 253.0 };
}

fn sampleShadowCoarse(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
    return sampleShadowCacheNearest(
        ctx,
        ctx.renderer.hybrid_shadow_coarse_cache,
        ctx.renderer.hybrid_shadow_coarse_cache_width,
        ctx.renderer.hybrid_shadow_coarse_cache_height,
        @max(1, config.POST_HYBRID_SHADOW_COARSE_DOWNSAMPLE),
        screen_x,
        screen_y,
    );
}

fn sampleShadowRefined(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
    const coarse = sampleShadowCoarse(ctx, screen_x, screen_y);
    if (!coarse.valid) return coarse;
    if (coarse.coverage <= config.POST_HYBRID_SHADOW_EDGE_MIN_COVERAGE or coarse.coverage >= config.POST_HYBRID_SHADOW_EDGE_MAX_COVERAGE) return coarse;

    var coverage_sum: f32 = 0.0;
    var valid_count: f32 = 0.0;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const sample = sampleShadowCacheNearest(
                ctx,
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
    return .{ .valid = true, .coverage = hybrid_shadow_resolve_kernel.blendCoverage(coarse.coverage, avg_coverage, blend) };
}

fn sampleShadow(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
    return sampleShadowCoarse(ctx, screen_x, screen_y);
}

fn isPointShadowed(ctx: anytype, camera_pos: math.Vec3, light_sample: anytype) bool {
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
            const world_pos = render_utils.cameraToWorldPosition(ctx.camera_position, ctx.basis_right, ctx.basis_up, ctx.basis_forward, camera_pos);
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
                v0x[j] = v0.x;
                v0y[j] = v0.y;
                v0z[j] = v0.z;
                v1x[j] = v1.x;
                v1y[j] = v1.y;
                v1z[j] = v1.z;
                v2x[j] = v2.x;
                v2y[j] = v2.y;
                v2z[j] = v2.z;
                active_mask[j] = true;
            }
            if (rayIntersectsTriangle8(orig_x, orig_y, orig_z, dir_x, dir_y, dir_z, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, active_mask)) return true;
        }
    }
    return false;
}

fn resolveBlockExact(ctx: anytype, x: i32, y: i32, width: i32, height: i32) void {
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
            const sample = sampleShadowRefined(ctx, sample_x, sample_y);
            if (!sample.valid) continue;
            const coverage = sample.coverage;
            if (coverage <= 0.02) continue;
            if (coverage >= 0.98) {
                darkenBlock(ctx, block_x, block_y, block_w, block_h);
                continue;
            }

            const pixel_scale = 1.0 - ((1.0 - ctx.darkness_scale) * coverage);
            var py = block_y;
            while (py < block_y + block_h) : (py += 1) {
                if (py < 0 or py >= ctx.renderer.bitmap.height) continue;
                const row_start = @as(usize, @intCast(py * ctx.renderer.bitmap.width + block_x));
                const row_end = @min(@as(usize, @intCast(py * ctx.renderer.bitmap.width + block_x + block_w)), ctx.renderer.bitmap.pixels.len);
                var idx = row_start;
                while (idx < row_end) : (idx += 1) {
                    ctx.renderer.bitmap.pixels[idx] = render_utils.darkenPackedColor(ctx.renderer.bitmap.pixels[idx], pixel_scale);
                }
            }
        }
    }
}

fn darkenBlock(ctx: anytype, x: i32, y: i32, width: i32, height: i32) void {
    var py = y;
    while (py < y + height) : (py += 1) {
        if (py < 0 or py >= ctx.renderer.bitmap.height) continue;
        const row_start = @as(usize, @intCast(py * ctx.renderer.bitmap.width + x));
        const row_end = @as(usize, @intCast(py * ctx.renderer.bitmap.width + x + width));
        darkenPixelSpan(ctx.renderer.bitmap.pixels, row_start, row_end, ctx.darkness_scale);
    }
}

fn darkenPixelSpan(pixels: []u32, start_index: usize, end_index: usize, scale: f32) void {
    if (start_index >= end_index) return;
    var i = start_index;
    while (i < end_index and i < pixels.len) : (i += 1) {
        pixels[i] = render_utils.darkenPackedColor(pixels[i], scale);
    }
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
    orig_x: @Vector(8, f32),
    orig_y: @Vector(8, f32),
    orig_z: @Vector(8, f32),
    dir_x: @Vector(8, f32),
    dir_y: @Vector(8, f32),
    dir_z: @Vector(8, f32),
    v0x: @Vector(8, f32),
    v0y: @Vector(8, f32),
    v0z: @Vector(8, f32),
    v1x: @Vector(8, f32),
    v1y: @Vector(8, f32),
    v1z: @Vector(8, f32),
    v2x: @Vector(8, f32),
    v2y: @Vector(8, f32),
    v2z: @Vector(8, f32),
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
