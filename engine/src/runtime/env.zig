const std = @import("std");
const log = @import("../core/log.zig");
const renderer_module = @import("../render/renderer.zig");

const Renderer = renderer_module.Renderer;
const app_logger = log.get("app.main");

pub fn loadRendererTtlNs(allocator: std.mem.Allocator) ?i128 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_TTL_SECONDS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => {
            app_logger.warn("failed to read ZIG_RENDER_TTL_SECONDS: {s}", .{@errorName(err)});
            return null;
        },
    };
    defer allocator.free(raw_value);

    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    const ttl_seconds = std.fmt.parseFloat(f64, trimmed) catch {
        app_logger.warn("invalid ZIG_RENDER_TTL_SECONDS value: {s}", .{trimmed});
        return null;
    };
    if (!std.math.isFinite(ttl_seconds) or ttl_seconds <= 0.0) {
        app_logger.warn("ignoring non-positive ZIG_RENDER_TTL_SECONDS: {d}", .{ttl_seconds});
        return null;
    }

    const ttl_ns_f64 = ttl_seconds * @as(f64, @floatFromInt(std.time.ns_per_s));
    return @as(i128, @intFromFloat(ttl_ns_f64));
}

pub fn dumpFramebufferIfRequested(renderer: *Renderer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const path = std.process.getEnvVarOwned(allocator, "ZIG_DUMP_FRAMEBUFFER_PPM") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(path);

    try writeBitmapPpm(path, renderer.bitmap.width, renderer.bitmap.height, renderer.bitmap.pixels);
    app_logger.info("wrote framebuffer dump to {s}", .{path});
}

fn writeBitmapPpm(path: []const u8, width: i32, height: i32, pixels: []const u32) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{} {}\n255\n", .{ width, height });
    try file.writeAll(header);
    var rgb: [3]u8 = undefined;
    for (pixels) |pixel| {
        rgb[0] = @intCast((pixel >> 16) & 0xFF);
        rgb[1] = @intCast((pixel >> 8) & 0xFF);
        rgb[2] = @intCast(pixel & 0xFF);
        try file.writeAll(&rgb);
    }
}

pub fn defaultRendererTtlNs() i128 {
    return 15 * std.time.ns_per_s;
}

/// Loads l oa dr en de re rt tl fr am es from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
pub fn loadRendererTtlFrames(allocator: std.mem.Allocator) ?u64 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_TTL_FRAMES") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => {
            app_logger.warn("failed to read ZIG_RENDER_TTL_FRAMES: {s}", .{@errorName(err)});
            return null;
        },
    };
    defer allocator.free(raw_value);

    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    const ttl_frames = std.fmt.parseUnsigned(u64, trimmed, 10) catch {
        app_logger.warn("invalid ZIG_RENDER_TTL_FRAMES value: {s}", .{trimmed});
        return null;
    };
    if (ttl_frames == 0) {
        app_logger.warn("ignoring zero ZIG_RENDER_TTL_FRAMES value", .{});
        return null;
    }
    return ttl_frames;
}

/// Loads l oa dp ro fi le fr am et ar ge t from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
pub fn loadProfileFrameTarget(allocator: std.mem.Allocator) ?u64 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_PROFILE_FRAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    defer allocator.free(raw_value);
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch null;
}