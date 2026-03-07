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
const math = @import("math.zig");

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

