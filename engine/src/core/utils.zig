//! # General Utility Functions
//! 
//! This module provides a collection of general-purpose helper functions that are
//! useful across various parts of the engine. These functions aim to reduce code
//! duplication, improve readability, and simplify common tasks in graphics and game development.

const std = @import("std");
const math = @import("math.zig");

// ========== Math Utilities ========== 

/// Linearly interpolates between two floating-point values.
/// Given `a` and `b`, and a `t` value (typically 0.0 to 1.0),
/// returns a value smoothly blended between `a` and `b`.
///
/// `result = a + (b - a) * t`
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Performs inverse linear interpolation.
/// Given a `value` between `a` and `b`, returns the `t` value (0.0 to 1.0)
/// that corresponds to it.
///
/// `t = (value - a) / (b - a)`
pub fn inverse_lerp(a: f32, b: f32, value: f32) f32 {
    if (std.math.approxEqAbs(f32, a, b, 0.00001)) return 0.0; // Avoid division by zero
    return (value - a) / (b - a);
}

/// Remaps a value from one range to another.
/// For example, remap a value from [0, 100] to [0, 1].
pub fn remap(in_min: f32, in_max: f32, out_min: f32, out_max: f32, value: f32) f32 {
    const t = inverse_lerp(in_min, in_max, value);
    return lerp(out_min, out_max, t);
}

/// Performs a smooth Hermite interpolation between 0 and 1.
/// Commonly used for blending effects, providing a smoother transition
/// than linear interpolation at the edges.
///
/// `result = x * x * (3 - 2 * x)`
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// ========== Color Conversion Utilities ========== 

/// Converts a normalized RGB `Vec3` (components 0.0-1.0) to a packed `u32` color (0xAARRGGBB).
/// Alpha is set to full (0xFF).
pub fn vec_to_color(rgb: math.Vec3) u32 {
    const r = @as(u32, @intFromFloat(std.math.clamp(rgb.x, 0.0, 1.0) * 255.0));
    const g = @as(u32, @intFromFloat(std.math.clamp(rgb.y, 0.0, 1.0) * 255.0));
    const b = @as(u32, @intFromFloat(std.math.clamp(rgb.z, 0.0, 1.0) * 255.0));
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Converts a packed `u32` color (0xAARRGGBB) to a normalized RGB `Vec3` (components 0.0-1.0).
pub fn color_to_vec(color: u32) math.Vec3 {
    const r = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
    return math.Vec3.new(r, g, b);
}

// ========== File System Utilities ========== 

/// Reads the entire content of a file into a dynamically allocated byte buffer.
/// This function centralizes file reading logic and handles common errors.
pub fn read_file_to_buffer(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    return contents;
}

// ========== Debugging / Logging Utilities ========== 

/// Logs a `Vec3` to `std.debug.print` with a descriptive name.
pub fn log_vec3(name: []const u8, vec: math.Vec3) void {
    std.debug.print("{s}: (x={d:.3}, y={d:.3}, z={d:.3})\n", .{ name, vec.x, vec.y, vec.z });
}

/// Logs a `Mat4` to `std.debug.print` with a descriptive name.
pub fn log_mat4(name: []const u8, mat: math.Mat4) void {
    std.debug.print("{s}:\n", .{name});
    std.debug.print("  {d:.3} {d:.3} {d:.3} {d:.3}\n", .{ mat.data[0], mat.data[1], mat.data[2], mat.data[3] });
    std.debug.print("  {d:.3} {d:.3} {d:.3} {d:.3}\n", .{ mat.data[4], mat.data[5], mat.data[6], mat.data[7] });
    std.debug.print("  {d:.3} {d:.3} {d:.3} {d:.3}\n", .{ mat.data[8], mat.data[9], mat.data[10], mat.data[11] });
    std.debug.print("  {d:.3} {d:.3} {d:.3} {d:.3}\n", .{ mat.data[12], mat.data[13], mat.data[14], mat.data[15] });
}
