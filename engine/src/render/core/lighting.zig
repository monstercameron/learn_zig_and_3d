//! # Basic Lighting Module
//!
//! This module handles simple lighting calculations for the 3D scene. It implements
//! a basic "flat shading" model, where each triangle has a single, uniform color
//! based on its angle to a light source.
//!
//! ## Key Concepts
//!
//! - **Diffuse Light**: The brightness of a surface depends on the angle at which light
//!   hits it. A surface directly facing a light source is bright; a surface at a steep
//!   angle is dim. This is calculated using the dot product of the surface normal and
//!   the light direction.
//! - **Ambient Light**: A constant amount of light that is added to the entire scene.
//!   This ensures that even surfaces facing away from the light are not pure black,
//!   simulating indirect light bouncing around the environment.

const std = @import("std");
const cpu_features = @import("../../core/cpu_features.zig");
const math = @import("../../core/math.zig");

/// The minimum amount of light a surface receives, even if it's facing away from the light source.
/// A value of 0.25 means that surfaces will have at least 25% of their full brightness.
pub const AMBIENT_LIGHT: f32 = 0.25;

/// The default color of objects before lighting is applied. This is a yellowish color.
/// The format is 0xAARRGGBB (Alpha, Red, Green, Blue), but Windows bitmaps use BGRA order in memory,
/// so the hex literal is written with components in 0xRRGGBB order and then packed.
pub const DEFAULT_BASE_COLOR: u32 = 0xFFFFDC28; // 255,220,40 in BGRA packing

/// Calculates the final light intensity for a surface.
/// - `brightness`: The raw brightness from the dot product, typically from -1.0 to 1.0.
/// Returns a final intensity value, including ambient light, from `AMBIENT_LIGHT` to 1.0.
pub fn computeIntensity(brightness: f32) f32 {
    // Clamp the dot product result to be between 0.0 (facing 90 degrees away) and 1.0 (facing light directly).
    const clamped = std.math.clamp(brightness, 0.0, 1.0);

    // Combine the diffuse light with the ambient light.
    // The diffuse portion is scaled to fit in the remaining range (1.0 - AMBIENT_LIGHT).
    return AMBIENT_LIGHT + clamped * (1.0 - AMBIENT_LIGHT);
}

/// Applies a calculated light intensity to a given base color.
/// - `color`: The original 32-bit integer color of the object (in 0xAARRGGBB format).
/// - `intensity`: The light intensity to apply, from 0.0 to 1.0.
/// Returns the new 32-bit integer color after applying the lighting.
// TODO(SIMD): This function is a prime candidate for SIMD. Multiple pixels (4 or 8) could be processed at once.
// The process of unpacking a u32 to four u8/f32 components, multiplying, and repacking is a classic use case for PSHUFB, PMUL, etc.
pub fn applyIntensity(color: u32, intensity: f32) u32 {
    const clamped_intensity = std.math.clamp(intensity, AMBIENT_LIGHT, 1.0);

    // Extract the Red, Green, and Blue components from the 32-bit integer color.
    // JS Analogy: This is manual bit manipulation to do what `(color >> 16) & 0xFF` does.
    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF));
    const b = @as(f32, @floatFromInt(color & 0xFF));

    // Multiply each color component by the intensity and clamp to the valid 0-255 range.
    const r_val = std.math.clamp(r * clamped_intensity, 0.0, 255.0);
    const g_val = std.math.clamp(g * clamped_intensity, 0.0, 255.0);
    const b_val = std.math.clamp(b * clamped_intensity, 0.0, 255.0);

    // Re-pack the components into a single 32-bit integer, with full alpha (0xFF).
    return (255 << 24) | (@as(u32, @intFromFloat(r_val)) << 16) | (@as(u32, @intFromFloat(g_val)) << 8) | @as(u32, @intFromFloat(b_val));
}

fn runtimeIntensityBatchLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512, .avx2 => 8,
        .sse2, .neon => 4,
        .scalar => 1,
    };
}

fn applyIntensityBatchSimd(comptime lanes: usize, colors: *const [lanes]u32, intensities: *const [lanes]f32) [lanes]u32 {
    const VecF32 = @Vector(lanes, f32);
    const VecU32 = @Vector(lanes, u32);

    const ambient: VecF32 = @splat(AMBIENT_LIGHT);
    const max_intensity: VecF32 = @splat(1.0);
    const zero: VecF32 = @splat(0.0);
    const clamp255: VecF32 = @splat(255.0);
    const mask_ff: VecU32 = @splat(0xFF);
    const shift8: VecU32 = @splat(8);
    const shift16: VecU32 = @splat(16);
    const color_vec: VecU32 = @bitCast(colors.*);
    const intensity_vec: VecF32 = @bitCast(intensities.*);

    const clamped_intensity = @min(@max(intensity_vec, ambient), max_intensity);
    const r_int = (color_vec >> shift16) & mask_ff;
    const g_int = (color_vec >> shift8) & mask_ff;
    const b_int = color_vec & mask_ff;

    const r = @as(VecF32, @floatFromInt(r_int));
    const g = @as(VecF32, @floatFromInt(g_int));
    const b = @as(VecF32, @floatFromInt(b_int));

    const r_scaled = @min(@max(r * clamped_intensity, zero), clamp255);
    const g_scaled = @min(@max(g * clamped_intensity, zero), clamp255);
    const b_scaled = @min(@max(b * clamped_intensity, zero), clamp255);

    const r_packed = @as(VecU32, @intFromFloat(r_scaled)) << shift16;
    const g_packed = @as(VecU32, @intFromFloat(g_scaled)) << shift8;
    const b_packed = @as(VecU32, @intFromFloat(b_scaled));
    return @bitCast(@as(VecU32, @splat(0xFF000000)) | r_packed | g_packed | b_packed);
}

pub fn applyIntensityBatch(colors: []const u32, intensities: []const f32, out: []u32) void {
    std.debug.assert(colors.len == intensities.len and colors.len == out.len);

    const lanes = runtimeIntensityBatchLanes();
    var index: usize = 0;
    while (index + lanes <= colors.len) : (index += lanes) {
        switch (lanes) {
            8 => {
                const result = applyIntensityBatchSimd(8, @ptrCast(colors[index..][0..8]), @ptrCast(intensities[index..][0..8]));
                const out_ptr: *[8]u32 = @ptrCast(out[index..][0..8]);
                out_ptr.* = result;
            },
            4 => {
                const result = applyIntensityBatchSimd(4, @ptrCast(colors[index..][0..4]), @ptrCast(intensities[index..][0..4]));
                const out_ptr: *[4]u32 = @ptrCast(out[index..][0..4]);
                out_ptr.* = result;
            },
            else => out[index] = applyIntensity(colors[index], intensities[index]),
        }
    }

    while (index < colors.len) : (index += 1) {
        out[index] = applyIntensity(colors[index], intensities[index]);
    }
}

/// A convenience function to shade the `DEFAULT_BASE_COLOR` with a given brightness.
pub fn shadeSolid(brightness: f32) u32 {
    return applyIntensity(DEFAULT_BASE_COLOR, computeIntensity(brightness));
}


/// Physically Based Rendering (PBR) metallic-roughness BRDF calculations.

const PI: f32 = 3.14159265359;

/// Schlick's approximation for Fresnel. 
/// f0 is the base reflectivity (typically 0.04 for non-metals, or the albedo color for metals).
pub fn fresnelSchlick(cos_theta: f32, f0: math.Vec3) math.Vec3 {
    const clamp_cos = std.math.clamp(1.0 - cos_theta, 0.0, 1.0);
    const pow5 = clamp_cos * clamp_cos * clamp_cos * clamp_cos * clamp_cos;
    return math.Vec3.new(
        f0.x + (1.0 - f0.x) * pow5,
        f0.y + (1.0 - f0.y) * pow5,
        f0.z + (1.0 - f0.z) * pow5,
    );
}

/// GGX Normal Distribution Function (NDF). 
/// Determines how many microfacets are aligned to the half-vector.
pub fn distributionGGX(normal: math.Vec3, halfway: math.Vec3, roughness: f32) f32 {
    const a = roughness * roughness;
    const a2 = a * a;
    const NdotH = @max(math.Vec3.dot(normal, halfway), 0.0);
    const NdotH2 = NdotH * NdotH;

    const num = a2;
    var denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return num / @max(denom, 0.000001);
}

/// Geometry function (Schlick-GGX). 
/// Calculates microfacet shadowing.
pub fn geometrySchlickGGX(NdotV: f32, roughness: f32) f32 {
    const r = (roughness + 1.0);
    const k = (r * r) / 8.0;

    const num = NdotV;
    const denom = NdotV * (1.0 - k) + k;

    return num / denom;
}

pub fn geometrySmith(normal: math.Vec3, view_dir: math.Vec3, light_dir: math.Vec3, roughness: f32) f32 {
    const NdotV = @max(math.Vec3.dot(normal, view_dir), 0.0);
    const NdotL = @max(math.Vec3.dot(normal, light_dir), 0.0);
    const ggx2 = geometrySchlickGGX(NdotV, roughness);
    const ggx1 = geometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}

/// Unpack an 8-bit ARGB u32 color to a floating point Vec3 (RGB in 0.0-1.0 range).
pub fn unpackColorLinear(color: u32) math.Vec3 {
    // Note: We square it for rough sRGB to Linear conversion
    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
    return math.Vec3.new(r * r, g * g, b * b);
}

/// Pack a floating point linear color back to 8-bit ARGB with Tonemapping.
pub fn packColorTonemapped(color: math.Vec3, alpha: u32) u32 {
    // Reinhard tonemapping (HDR -> LDR) with exposure
    const exposure: f32 = 2.5;
    const mapped_x = (color.x * exposure) / ((color.x * exposure) + 1.0);
    const mapped_y = (color.y * exposure) / ((color.y * exposure) + 1.0);
    const mapped_z = (color.z * exposure) / ((color.z * exposure) + 1.0);

    // Gamma correction (Linear -> sRGB, approx 1/2.2)
    const r = std.math.sqrt(mapped_x);
    const g = std.math.sqrt(mapped_y);
    const b = std.math.sqrt(mapped_z);

    const r_val = std.math.clamp(r * 255.0, 0.0, 255.0);
    const g_val = std.math.clamp(g * 255.0, 0.0, 255.0);
    const b_val = std.math.clamp(b * 255.0, 0.0, 255.0);
    
    return (alpha << 24) | (@as(u32, @intFromFloat(r_val)) << 16) | (@as(u32, @intFromFloat(g_val)) << 8) | @as(u32, @intFromFloat(b_val));
}

/// The core PBR shading function for a single light source.
pub fn computePBR(
    albedo: math.Vec3, 
    normal: math.Vec3, 
    view_dir: math.Vec3, 
    light_dir: math.Vec3, 
    light_color: math.Vec3, 
    metallic: f32, 
    roughness: f32
) math.Vec3 {
    // F0 is base reflectivity
    var f0 = math.Vec3.new(0.04, 0.04, 0.04);
    f0 = math.Vec3.new(
        f0.x * (1.0 - metallic) + albedo.x * metallic,
        f0.y * (1.0 - metallic) + albedo.y * metallic,
        f0.z * (1.0 - metallic) + albedo.z * metallic,
    );

    const halfway = math.Vec3.normalize(math.Vec3.add(view_dir, light_dir));

    // Cook-Torrance BRDF components
    const NDF = distributionGGX(normal, halfway, roughness);
    const G   = geometrySmith(normal, view_dir, light_dir, roughness);
    const F   = fresnelSchlick(@max(math.Vec3.dot(halfway, view_dir), 0.0), f0);

    // Diffuse / Specular ratio
    const kS = F;
    var kD = math.Vec3.new(1.0 - kS.x, 1.0 - kS.y, 1.0 - kS.z);
    kD = math.Vec3.scale(kD, 1.0 - metallic); // Metals have no diffuse light

    // Specular equation
    const numerator = math.Vec3.scale(F, NDF * G);
    const denominator = 4.0 * @max(math.Vec3.dot(normal, view_dir), 0.0) * @max(math.Vec3.dot(normal, light_dir), 0.0) + 0.0001;
    const specular = math.Vec3.scale(numerator, 1.0 / denominator);

    // Radiance (NdotL)
    const NdotL = @max(math.Vec3.dot(normal, light_dir), 0.0);

    // Outgoing light (Lo)
    const diffuse = math.Vec3.scale(albedo, 1.0 / PI);
    const diffuse_scaled = math.Vec3.new(diffuse.x * kD.x, diffuse.y * kD.y, diffuse.z * kD.z);
    const combined = math.Vec3.add(diffuse_scaled, specular);

    const radiance = math.Vec3.new(light_color.x * NdotL, light_color.y * NdotL, light_color.z * NdotL);
    
    const direct = math.Vec3.new(combined.x * radiance.x, combined.y * radiance.y, combined.z * radiance.z);
    const ambient = math.Vec3.scale(albedo, 0.2); // Brighten ambient significantly // Ambient term to prevent pure black
    return math.Vec3.add(direct, ambient);
}

fn runtimePbrBatchLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512, .avx2 => 8,
        .sse2, .neon => 4,
        .scalar => 1,
    };
}

fn computePBRBatchSimd(
    comptime lanes: usize,
    albedos: *const [lanes]math.Vec3,
    normals: *const [lanes]math.Vec3,
    view_dirs: *const [lanes]math.Vec3,
    light_dir: math.Vec3,
    light_color: math.Vec3,
    metallic: f32,
    roughness: f32,
) [lanes]math.Vec3 {
    const FloatVec = @Vector(lanes, f32);
    const eps: FloatVec = @splat(0.000001);
    const zero: FloatVec = @splat(0.0);
    const one: FloatVec = @splat(1.0);
    const pi: FloatVec = @splat(PI);
    const base_f0: FloatVec = @splat(0.04);
    const metallic_vec: FloatVec = @splat(metallic);
    const roughness_vec: FloatVec = @splat(roughness);
    const light_x: FloatVec = @splat(light_dir.x);
    const light_y: FloatVec = @splat(light_dir.y);
    const light_z: FloatVec = @splat(light_dir.z);
    const light_color_x: FloatVec = @splat(light_color.x);
    const light_color_y: FloatVec = @splat(light_color.y);
    const light_color_z: FloatVec = @splat(light_color.z);
    const ambient_scale: FloatVec = @splat(0.2);

    var albedo_x_arr: [lanes]f32 = undefined;
    var albedo_y_arr: [lanes]f32 = undefined;
    var albedo_z_arr: [lanes]f32 = undefined;
    var normal_x_arr: [lanes]f32 = undefined;
    var normal_y_arr: [lanes]f32 = undefined;
    var normal_z_arr: [lanes]f32 = undefined;
    var view_x_arr: [lanes]f32 = undefined;
    var view_y_arr: [lanes]f32 = undefined;
    var view_z_arr: [lanes]f32 = undefined;

    inline for (0..lanes) |lane| {
        albedo_x_arr[lane] = albedos[lane].x;
        albedo_y_arr[lane] = albedos[lane].y;
        albedo_z_arr[lane] = albedos[lane].z;
        normal_x_arr[lane] = normals[lane].x;
        normal_y_arr[lane] = normals[lane].y;
        normal_z_arr[lane] = normals[lane].z;
        view_x_arr[lane] = view_dirs[lane].x;
        view_y_arr[lane] = view_dirs[lane].y;
        view_z_arr[lane] = view_dirs[lane].z;
    }

    const albedo_x: FloatVec = @bitCast(albedo_x_arr);
    const albedo_y: FloatVec = @bitCast(albedo_y_arr);
    const albedo_z: FloatVec = @bitCast(albedo_z_arr);
    const normal_x: FloatVec = @bitCast(normal_x_arr);
    const normal_y: FloatVec = @bitCast(normal_y_arr);
    const normal_z: FloatVec = @bitCast(normal_z_arr);
    const view_x: FloatVec = @bitCast(view_x_arr);
    const view_y: FloatVec = @bitCast(view_y_arr);
    const view_z: FloatVec = @bitCast(view_z_arr);

    const f0_x = base_f0 * (one - metallic_vec) + albedo_x * metallic_vec;
    const f0_y = base_f0 * (one - metallic_vec) + albedo_y * metallic_vec;
    const f0_z = base_f0 * (one - metallic_vec) + albedo_z * metallic_vec;

    const halfway_x_raw = view_x + light_x;
    const halfway_y_raw = view_y + light_y;
    const halfway_z_raw = view_z + light_z;
    const halfway_len_sq = halfway_x_raw * halfway_x_raw + halfway_y_raw * halfway_y_raw + halfway_z_raw * halfway_z_raw;
    const halfway_inv_len = one / @sqrt(@max(halfway_len_sq, eps));
    const halfway_x = halfway_x_raw * halfway_inv_len;
    const halfway_y = halfway_y_raw * halfway_inv_len;
    const halfway_z = halfway_z_raw * halfway_inv_len;

    const roughness_sq = roughness_vec * roughness_vec;
    const a2 = roughness_sq * roughness_sq;
    const n_dot_h = @max(normal_x * halfway_x + normal_y * halfway_y + normal_z * halfway_z, zero);
    const n_dot_h2 = n_dot_h * n_dot_h;
    const ndf_denom_base = n_dot_h2 * (a2 - one) + one;
    const ndf = a2 / @max(pi * ndf_denom_base * ndf_denom_base, eps);

    const n_dot_v = @max(normal_x * view_x + normal_y * view_y + normal_z * view_z, zero);
    const n_dot_l = @max(normal_x * light_x + normal_y * light_y + normal_z * light_z, zero);
    const geometry_r = roughness_vec + one;
    const geometry_k = (geometry_r * geometry_r) / @as(FloatVec, @splat(8.0));
    const ggx_v = n_dot_v / @max(n_dot_v * (one - geometry_k) + geometry_k, eps);
    const ggx_l = n_dot_l / @max(n_dot_l * (one - geometry_k) + geometry_k, eps);
    const geometry = ggx_v * ggx_l;

    const cos_theta = @max(halfway_x * view_x + halfway_y * view_y + halfway_z * view_z, zero);
    const one_minus_cos = @max(zero, one - cos_theta);
    const one_minus_cos2 = one_minus_cos * one_minus_cos;
    const one_minus_cos5 = one_minus_cos2 * one_minus_cos2 * one_minus_cos;
    const fresnel_x = f0_x + (one - f0_x) * one_minus_cos5;
    const fresnel_y = f0_y + (one - f0_y) * one_minus_cos5;
    const fresnel_z = f0_z + (one - f0_z) * one_minus_cos5;

    const kd_scale = one - metallic_vec;
    const kd_x = (one - fresnel_x) * kd_scale;
    const kd_y = (one - fresnel_y) * kd_scale;
    const kd_z = (one - fresnel_z) * kd_scale;

    const specular_scale = (ndf * geometry) / @max(@as(FloatVec, @splat(4.0)) * n_dot_v * n_dot_l + @as(FloatVec, @splat(0.0001)), eps);
    const specular_x = fresnel_x * specular_scale;
    const specular_y = fresnel_y * specular_scale;
    const specular_z = fresnel_z * specular_scale;

    const diffuse_scale = one / pi;
    const diffuse_x = albedo_x * diffuse_scale * kd_x;
    const diffuse_y = albedo_y * diffuse_scale * kd_y;
    const diffuse_z = albedo_z * diffuse_scale * kd_z;

    const radiance_x = light_color_x * n_dot_l;
    const radiance_y = light_color_y * n_dot_l;
    const radiance_z = light_color_z * n_dot_l;

    const direct_x = (diffuse_x + specular_x) * radiance_x;
    const direct_y = (diffuse_y + specular_y) * radiance_y;
    const direct_z = (diffuse_z + specular_z) * radiance_z;

    const out_x_arr: [lanes]f32 = @bitCast(direct_x + albedo_x * ambient_scale);
    const out_y_arr: [lanes]f32 = @bitCast(direct_y + albedo_y * ambient_scale);
    const out_z_arr: [lanes]f32 = @bitCast(direct_z + albedo_z * ambient_scale);

    var out: [lanes]math.Vec3 = undefined;
    inline for (0..lanes) |lane| {
        out[lane] = math.Vec3.new(out_x_arr[lane], out_y_arr[lane], out_z_arr[lane]);
    }
    return out;
}

pub fn computePBRBatch(
    albedos: []const math.Vec3,
    normals: []const math.Vec3,
    view_dirs: []const math.Vec3,
    light_dir: math.Vec3,
    light_color: math.Vec3,
    metallic: f32,
    roughness: f32,
    out: []math.Vec3,
) void {
    std.debug.assert(albedos.len == normals.len);
    std.debug.assert(albedos.len == view_dirs.len);
    std.debug.assert(albedos.len == out.len);

    const lanes = runtimePbrBatchLanes();
    var index: usize = 0;
    while (index + lanes <= albedos.len) : (index += lanes) {
        switch (lanes) {
            8 => {
                const result = computePBRBatchSimd(8, @ptrCast(albedos[index..][0..8]), @ptrCast(normals[index..][0..8]), @ptrCast(view_dirs[index..][0..8]), light_dir, light_color, metallic, roughness);
                const out_ptr: *[8]math.Vec3 = @ptrCast(out[index..][0..8]);
                out_ptr.* = result;
            },
            4 => {
                const result = computePBRBatchSimd(4, @ptrCast(albedos[index..][0..4]), @ptrCast(normals[index..][0..4]), @ptrCast(view_dirs[index..][0..4]), light_dir, light_color, metallic, roughness);
                const out_ptr: *[4]math.Vec3 = @ptrCast(out[index..][0..4]);
                out_ptr.* = result;
            },
            else => out[index] = computePBR(albedos[index], normals[index], view_dirs[index], light_dir, light_color, metallic, roughness),
        }
    }

    while (index < albedos.len) : (index += 1) {
        out[index] = computePBR(albedos[index], normals[index], view_dirs[index], light_dir, light_color, metallic, roughness);
    }
}
