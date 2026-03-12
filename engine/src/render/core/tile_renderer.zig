//! # Tile-Based Rendering Infrastructure
//!
//! This module provides the data structures and core functions for a tile-based renderer.
//! Tile-based rendering is a technique where the screen is divided into a grid of smaller
//! rectangles called "tiles". Each tile can then be rendered independently.
//!
//! ## Why Use Tiles? (JavaScript Analogy)
//!
//! Imagine you have a team of artists painting a giant mural (the screen). You could have
//! one artist paint the whole thing, or you could divide the mural into a grid of squares
//! and assign one square to each artist. The team will finish much faster because they
//! can all work in parallel. This is the primary benefit of tile-based rendering.
//!
//! Additionally, each artist only needs to keep their small set of paints and brushes nearby
//! (the CPU cache), which is much faster than walking back and forth to a central supply room.
//! This module defines the `Tile`, the `TileGrid`, and the `TileBuffer` (each artist's
//! personal canvas and paint set).

const std = @import("std");
const Bitmap = @import("../../assets/bitmap.zig").Bitmap;
const cpu_features = @import("../../core/cpu_features.zig");
const scanline = @import("scanline.zig");
const math = @import("../../core/math.zig");
const texture = @import("../../assets/texture.zig");
const lighting = @import("lighting.zig");

pub const invalid_surface_id: u32 = std.math.maxInt(u32);

pub const SurfaceHandle = packed struct {
    triangle_id: u32,
    meshlet_id: u32,
    bary_u: u16,
    bary_v: u16,

    /// Returns the invalid sentinel value for this handle/id type.
    /// Keeps invalid as the single implementation point so call-site behavior stays consistent.
    pub fn invalid() SurfaceHandle {
        return .{
            .triangle_id = invalid_surface_id,
            .meshlet_id = invalid_surface_id,
            .bary_u = 0,
            .bary_v = 0,
        };
    }

    /// init initializes Tile Renderer state and returns the configured value.
    pub fn init(triangle_id: usize, meshlet_id: usize, bary: math.Vec3) SurfaceHandle {
        const u = std.math.clamp(bary.x, 0.0, 1.0);
        const v = std.math.clamp(bary.y, 0.0, 1.0 - u);
        return .{
            .triangle_id = @intCast(@min(triangle_id, invalid_surface_id - 1)),
            .meshlet_id = @intCast(@min(meshlet_id, invalid_surface_id - 1)),
            .bary_u = @intFromFloat(u * 65535.0 + 0.5),
            .bary_v = @intFromFloat(v * 65535.0 + 0.5),
        };
    }

    /// Returns whether i sv al id.
    /// The check is side-effect free so callers can gate expensive follow-up work cheaply.
    pub fn isValid(self: SurfaceHandle) bool {
        return self.triangle_id != invalid_surface_id and self.meshlet_id != invalid_surface_id;
    }

    /// Performs barycentrics.
    /// Keeps barycentrics as the single implementation point so call-site behavior stays consistent.
    pub fn barycentrics(self: SurfaceHandle) math.Vec3 {
        const u = @as(f32, @floatFromInt(self.bary_u)) / 65535.0;
        const v = @as(f32, @floatFromInt(self.bary_v)) / 65535.0;
        return math.Vec3.new(u, v, @max(0.0, 1.0 - u - v));
    }
};

// The width and height of a single tile in pixels.
// 64x64 is a common choice that balances several factors:
// - **Cache Locality**: A 64x64 tile with a 32-bit color and 32-bit depth buffer fits well
//   within modern CPU L1/L2 caches, which is great for performance.
// - **Parallelism**: It creates enough tiles on a typical screen to keep many CPU cores busy.
// - **Overhead**: It's not so small that the overhead of managing the tiles becomes a bottleneck.
pub const TILE_SIZE: i32 = 64;

/// A struct to pass all necessary shading parameters to the rasterizer.
pub const ShadingParams = struct {
    base_color: u32,
    texture: ?*const texture.Texture,
    uv0: math.Vec2,
    uv1: math.Vec2,
    uv2: math.Vec2,
    surface_bary0: math.Vec3,
    surface_bary1: math.Vec3,
    surface_bary2: math.Vec3,
    triangle_id: usize,
    meshlet_id: usize,
    intensity: f32,
    normals: [3]math.Vec3,
    metallic: f32,
    roughness: f32,
};

pub const RasterizePerfStats = struct {
    triangles_rasterized: usize = 0,
    covered_pixels: usize = 0,
    depth_tests_passed: usize = 0,
    alpha_pixels: usize = 0,
};

// ========== TILE STRUCTURES ==========

/// Represents a single rectangular tile in the screen grid.
pub const Tile = struct {
    x: i32, // The screen-space X coordinate of the tile's top-left corner.
    y: i32, // The screen-space Y coordinate of the tile's top-left corner.
    width: i32, // The width of the tile. Can be less than TILE_SIZE for tiles at the screen edge.
    height: i32, // The height of the tile.
    index: usize, // The unique index of this tile within the grid.

    /// init initializes Tile Renderer state and returns the configured value.
    pub fn init(x: i32, y: i32, width: i32, height: i32, index: usize) Tile {
        return Tile{ .x = x, .y = y, .width = width, .height = height, .index = index };
    }

    /// Performs right.
    /// Keeps right as the single implementation point so call-site behavior stays consistent.
    pub fn right(self: Tile) i32 {
        return self.x + self.width;
    }

    /// Performs bottom.
    /// Keeps bottom as the single implementation point so call-site behavior stays consistent.
    pub fn bottom(self: Tile) i32 {
        return self.y + self.height;
    }
};

/// A per-tile rendering buffer. Each worker thread renders into one of these.
/// JS Analogy: This is like a small, off-screen `<canvas>` for a single worker.
pub const PixelData = struct {
    color: math.Vec4,
    camera: math.Vec3,
    normal: math.Vec3,
    surface: SurfaceHandle,
};

pub const TileBuffer = struct {
    data: []PixelData, // The fat buffer for colors, camera, and normal
    depth: []f32, // Kept separate for fast dense Early-Z testing
    width: i32,
    height: i32,
    allocator: std.mem.Allocator,

    /// init initializes Tile Renderer state and returns the configured value.
    pub fn init(width: i32, height: i32, allocator: std.mem.Allocator) !TileBuffer {
        const pixel_count = @as(usize, @intCast(width * height));
        const data = try allocator.alloc(PixelData, pixel_count);
        errdefer allocator.free(data);
        const depth = try allocator.alloc(f32, pixel_count);

        return TileBuffer{ .data = data, .depth = depth, .width = width, .height = height, .allocator = allocator };
    }

    /// Clears the tile for a new frame.
    pub fn clear(self: *TileBuffer) void {
        @memset(self.data, .{
            .color = math.Vec4.new(0.0, 0.0, 0.0, 1.0),
            .camera = math.Vec3.new(0, 0, 0),
            .normal = math.Vec3.new(0, 0, 0),
            .surface = SurfaceHandle.invalid(),
        });
        @memset(self.depth, std.math.inf(f32));
    }

    /// deinit releases resources owned by Tile Renderer.
    pub fn deinit(self: *TileBuffer) void {
        self.allocator.free(self.data);
        self.allocator.free(self.depth);
    }
};

/// Manages the grid of all tiles that cover the screen.
pub const TileGrid = struct {
    tiles: []Tile,
    cols: usize, // Number of tiles horizontally.
    rows: usize, // Number of tiles vertically.
    screen_width: i32,
    screen_height: i32,
    allocator: std.mem.Allocator,

    /// Calculates and creates the tile grid based on screen dimensions.
    pub fn init(screen_width: i32, screen_height: i32, allocator: std.mem.Allocator) !TileGrid {
        const cols = @as(usize, @intCast((@divTrunc(screen_width + TILE_SIZE - 1, TILE_SIZE))));
        const rows = @as(usize, @intCast((@divTrunc(screen_height + TILE_SIZE - 1, TILE_SIZE))));
        const tile_count = cols * rows;
        const tiles = try allocator.alloc(Tile, tile_count);

        var index: usize = 0;
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            var col: usize = 0;
            while (col < cols) : (col += 1) {
                const tile_x = @as(i32, @intCast(col)) * TILE_SIZE;
                const tile_y = @as(i32, @intCast(row)) * TILE_SIZE;
                const tile_width = @min(TILE_SIZE, screen_width - tile_x);
                const tile_height = @min(TILE_SIZE, screen_height - tile_y);
                tiles[index] = Tile.init(tile_x, tile_y, tile_width, tile_height, index);
                index += 1;
            }
        }

        return TileGrid{ .tiles = tiles, .cols = cols, .rows = rows, .screen_width = screen_width, .screen_height = screen_height, .allocator = allocator };
    }

    /// deinit releases resources owned by Tile Renderer.
    pub fn deinit(self: *TileGrid) void {
        self.allocator.free(self.tiles);
    }
};

// ========== TILE RENDERING UTILITIES ==========

/// Copies the pixels and geometry buffers from a completed tile buffer to the main screen surfaces.
/// JS Analogy: `main_context.drawImage(tile_canvas, tile.x, tile.y);`
pub fn compositeTileToScreen(tile: *const Tile, tile_buffer: *const TileBuffer, bitmap: *Bitmap, depth_buffer: ?[]f32, camera_buffer: ?[]math.Vec3, normal_buffer: ?[]math.Vec3, surface_buffer: ?[]SurfaceHandle) void {
    var y: i32 = 0;
    while (y < tile.height) : (y += 1) {
        const tile_row_start = @as(usize, @intCast(y * tile_buffer.width));
        const tile_row_end = tile_row_start + @as(usize, @intCast(tile.width));
        const screen_row_start = @as(usize, @intCast((tile.y + y) * bitmap.width + tile.x));
        const screen_row_end = screen_row_start + @as(usize, @intCast(tile.width));

        const tile_row_data = tile_buffer.data[tile_row_start..tile_row_end];
        const screen_pixels = bitmap.pixels[screen_row_start..screen_row_end];

        // Tonemap & pack: SIMD batch (Reinhard + sqrt gamma) into screen bitmap
        const batch_lanes = 8;
        const row_len = tile_row_data.len;
        var i: usize = 0;
        while (i + batch_lanes <= row_len) : (i += batch_lanes) {
            var cx: [batch_lanes]f32 = undefined;
            var cy: [batch_lanes]f32 = undefined;
            var cz: [batch_lanes]f32 = undefined;
            var alphas: [batch_lanes]u32 = undefined;
            inline for (0..batch_lanes) |lane| {
                const pd = tile_row_data[i + lane];
                cx[lane] = pd.color.x;
                cy[lane] = pd.color.y;
                cz[lane] = pd.color.z;
                alphas[lane] = @intFromFloat(pd.color.w * 255.0);
            }
            const batch_result = lighting.packColorTonemappedBatch(batch_lanes, &cx, &cy, &cz, &alphas);
            @memcpy(screen_pixels[i..][0..batch_lanes], &batch_result);
        }
        // Scalar tail
        while (i < row_len) : (i += 1) {
            const pd = tile_row_data[i];
            const final_color_rgb = math.Vec3.new(pd.color.x, pd.color.y, pd.color.z);
            const a = @as(u32, @intFromFloat(pd.color.w * 255.0));
            screen_pixels[i] = lighting.packColorTonemapped(final_color_rgb, a);
        }

        // Scatter structural data from AoS tile buffer into SoA global buffers.
        // Each buffer is handled as a separate tight loop to keep the
        // read stride predictable and give the prefetcher a chance.
        if (camera_buffer) |camera_out| {
            for (tile_row_data, 0..) |pd, cx| {
                camera_out[screen_row_start + cx] = pd.camera;
            }
        }
        if (normal_buffer) |normal_out| {
            for (tile_row_data, 0..) |pd, cx| {
                normal_out[screen_row_start + cx] = pd.normal;
            }
        }
        if (surface_buffer) |surface_out| {
            for (tile_row_data, 0..) |pd, cx| {
                surface_out[screen_row_start + cx] = pd.surface;
            }
        }
        if (depth_buffer) |buffer| {
            @memcpy(buffer[screen_row_start..screen_row_end], tile_buffer.depth[tile_row_start..tile_row_end]);
        }
    }
}

/// Draws green borders around all tiles for debugging purposes.
pub fn drawTileBoundaries(grid: *const TileGrid, bitmap: *Bitmap) void {
    const color: u32 = 0xFF00FF00;

    for (grid.tiles) |tile| {
        const min_x = tile.x;
        const max_x = tile.x + tile.width - 1;
        const min_y = tile.y;
        const max_y = tile.y + tile.height - 1;

        if (tile.width <= 0 or tile.height <= 0) continue;

        var x = min_x;
        while (x <= max_x) : (x += 1) {
            if (min_y >= 0 and min_y < bitmap.height and x >= 0 and x < bitmap.width) {
                const top_idx = @as(usize, @intCast(min_y * bitmap.width + x));
                if (top_idx < bitmap.pixels.len) bitmap.pixels[top_idx] = color;
            }
            if (max_y >= 0 and max_y < bitmap.height and x >= 0 and x < bitmap.width) {
                const bottom_idx = @as(usize, @intCast(max_y * bitmap.width + x));
                if (bottom_idx < bitmap.pixels.len) bitmap.pixels[bottom_idx] = color;
            }
        }

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            if (y >= 0 and y < bitmap.height and min_x >= 0 and min_x < bitmap.width) {
                const left_idx = @as(usize, @intCast(y * bitmap.width + min_x));
                if (left_idx < bitmap.pixels.len) bitmap.pixels[left_idx] = color;
            }
            if (y >= 0 and y < bitmap.height and max_x >= 0 and max_x < bitmap.width) {
                const right_idx = @as(usize, @intCast(y * bitmap.width + max_x));
                if (right_idx < bitmap.pixels.len) bitmap.pixels[right_idx] = color;
            }
        }
    }
}

// ========== TILE RASTERIZATION ==========

const max_span_batch_lanes = 8;
const raster_light_dir = math.Vec3.new(0.40824828, 0.40824828, -0.81649655);
const raster_light_color = math.Vec3.new(4.0, 4.0, 4.0);

/// Returns runtime span batch lanes.
/// Keeps runtime span batch lanes as the single implementation point so call-site behavior stays consistent.
fn runtimeSpanBatchLanes() usize {
    return switch (cpu_features.detect().preferredVectorBackend()) {
        .avx512, .avx2 => 8,
        .sse2, .neon => 4,
        .scalar => 1,
    };
}

fn interpolateVec2BatchSimd(comptime lanes: usize, a: math.Vec2, b: math.Vec2, c: math.Vec2, weight0: *const [lanes]f32, weight1: *const [lanes]f32, weight2: *const [lanes]f32) [lanes]math.Vec2 {
    const FloatVec = @Vector(lanes, f32);
    const w0: FloatVec = @bitCast(weight0.*);
    const w1: FloatVec = @bitCast(weight1.*);
    const w2: FloatVec = @bitCast(weight2.*);
    const out_x: [lanes]f32 = @bitCast(@as(FloatVec, @splat(a.x)) * w0 + @as(FloatVec, @splat(b.x)) * w1 + @as(FloatVec, @splat(c.x)) * w2);
    const out_y: [lanes]f32 = @bitCast(@as(FloatVec, @splat(a.y)) * w0 + @as(FloatVec, @splat(b.y)) * w1 + @as(FloatVec, @splat(c.y)) * w2);

    var out: [lanes]math.Vec2 = undefined;
    inline for (0..lanes) |lane| {
        out[lane] = math.Vec2.new(out_x[lane], out_y[lane]);
    }
    return out;
}

fn interpolateVec2Batch(a: math.Vec2, b: math.Vec2, c: math.Vec2, weight0: []const f32, weight1: []const f32, weight2: []const f32, out: []math.Vec2) void {
    std.debug.assert(weight0.len == weight1.len and weight0.len == weight2.len and weight0.len == out.len);

    var index: usize = 0;
    while (index + 8 <= weight0.len) : (index += 8) {
        const result = interpolateVec2BatchSimd(8, a, b, c, @ptrCast(weight0[index..][0..8]), @ptrCast(weight1[index..][0..8]), @ptrCast(weight2[index..][0..8]));
        const out_ptr: *[8]math.Vec2 = @ptrCast(out[index..][0..8]);
        out_ptr.* = result;
    }
    while (index + 4 <= weight0.len) : (index += 4) {
        const result = interpolateVec2BatchSimd(4, a, b, c, @ptrCast(weight0[index..][0..4]), @ptrCast(weight1[index..][0..4]), @ptrCast(weight2[index..][0..4]));
        const out_ptr: *[4]math.Vec2 = @ptrCast(out[index..][0..4]);
        out_ptr.* = result;
    }
    while (index < weight0.len) : (index += 1) {
        out[index] = math.Vec2.new(
            a.x * weight0[index] + b.x * weight1[index] + c.x * weight2[index],
            a.y * weight0[index] + b.y * weight1[index] + c.y * weight2[index],
        );
    }
}

fn interpolateVec3BatchSimd(comptime lanes: usize, a: math.Vec3, b: math.Vec3, c: math.Vec3, weight0: *const [lanes]f32, weight1: *const [lanes]f32, weight2: *const [lanes]f32) [lanes]math.Vec3 {
    const FloatVec = @Vector(lanes, f32);
    const w0: FloatVec = @bitCast(weight0.*);
    const w1: FloatVec = @bitCast(weight1.*);
    const w2: FloatVec = @bitCast(weight2.*);
    const out_x: [lanes]f32 = @bitCast(@as(FloatVec, @splat(a.x)) * w0 + @as(FloatVec, @splat(b.x)) * w1 + @as(FloatVec, @splat(c.x)) * w2);
    const out_y: [lanes]f32 = @bitCast(@as(FloatVec, @splat(a.y)) * w0 + @as(FloatVec, @splat(b.y)) * w1 + @as(FloatVec, @splat(c.y)) * w2);
    const out_z: [lanes]f32 = @bitCast(@as(FloatVec, @splat(a.z)) * w0 + @as(FloatVec, @splat(b.z)) * w1 + @as(FloatVec, @splat(c.z)) * w2);

    var out: [lanes]math.Vec3 = undefined;
    inline for (0..lanes) |lane| {
        out[lane] = math.Vec3.new(out_x[lane], out_y[lane], out_z[lane]);
    }
    return out;
}

fn interpolateVec3Batch(a: math.Vec3, b: math.Vec3, c: math.Vec3, weight0: []const f32, weight1: []const f32, weight2: []const f32, out: []math.Vec3) void {
    std.debug.assert(weight0.len == weight1.len and weight0.len == weight2.len and weight0.len == out.len);

    var index: usize = 0;
    while (index + 8 <= weight0.len) : (index += 8) {
        const result = interpolateVec3BatchSimd(8, a, b, c, @ptrCast(weight0[index..][0..8]), @ptrCast(weight1[index..][0..8]), @ptrCast(weight2[index..][0..8]));
        const out_ptr: *[8]math.Vec3 = @ptrCast(out[index..][0..8]);
        out_ptr.* = result;
    }
    while (index + 4 <= weight0.len) : (index += 4) {
        const result = interpolateVec3BatchSimd(4, a, b, c, @ptrCast(weight0[index..][0..4]), @ptrCast(weight1[index..][0..4]), @ptrCast(weight2[index..][0..4]));
        const out_ptr: *[4]math.Vec3 = @ptrCast(out[index..][0..4]);
        out_ptr.* = result;
    }
    while (index < weight0.len) : (index += 1) {
        out[index] = math.Vec3.new(
            a.x * weight0[index] + b.x * weight1[index] + c.x * weight2[index],
            a.y * weight0[index] + b.y * weight1[index] + c.y * weight2[index],
            a.z * weight0[index] + b.z * weight1[index] + c.z * weight2[index],
        );
    }
}

fn normalizeVec3BatchSimd(comptime lanes: usize, values: *const [lanes]math.Vec3) [lanes]math.Vec3 {
    const FloatVec = @Vector(lanes, f32);
    const eps: FloatVec = @splat(1e-8);
    const one: FloatVec = @splat(1.0);

    var x_arr: [lanes]f32 = undefined;
    var y_arr: [lanes]f32 = undefined;
    var z_arr: [lanes]f32 = undefined;
    inline for (0..lanes) |lane| {
        x_arr[lane] = values[lane].x;
        y_arr[lane] = values[lane].y;
        z_arr[lane] = values[lane].z;
    }

    const x_vec: FloatVec = @bitCast(x_arr);
    const y_vec: FloatVec = @bitCast(y_arr);
    const z_vec: FloatVec = @bitCast(z_arr);
    const len_sq = x_vec * x_vec + y_vec * y_vec + z_vec * z_vec;
    const inv_len = one / @sqrt(@max(len_sq, eps));
    const out_x_arr: [lanes]f32 = @bitCast(x_vec * inv_len);
    const out_y_arr: [lanes]f32 = @bitCast(y_vec * inv_len);
    const out_z_arr: [lanes]f32 = @bitCast(z_vec * inv_len);
    const len_sq_arr: [lanes]f32 = @bitCast(len_sq);

    var out: [lanes]math.Vec3 = undefined;
    inline for (0..lanes) |lane| {
        if (len_sq_arr[lane] <= 1e-8) {
            out[lane] = math.Vec3.new(0.0, 0.0, 0.0);
        } else {
            out[lane] = math.Vec3.new(out_x_arr[lane], out_y_arr[lane], out_z_arr[lane]);
        }
    }
    return out;
}

fn normalizeVec3Batch(values: []const math.Vec3, out: []math.Vec3) void {
    std.debug.assert(values.len == out.len);

    var index: usize = 0;
    while (index + 8 <= values.len) : (index += 8) {
        const result = normalizeVec3BatchSimd(8, @ptrCast(values[index..][0..8]));
        const out_ptr: *[8]math.Vec3 = @ptrCast(out[index..][0..8]);
        out_ptr.* = result;
    }
    while (index + 4 <= values.len) : (index += 4) {
        const result = normalizeVec3BatchSimd(4, @ptrCast(values[index..][0..4]));
        const out_ptr: *[4]math.Vec3 = @ptrCast(out[index..][0..4]);
        out_ptr.* = result;
    }
    while (index < values.len) : (index += 1) {
        out[index] = values[index].normalize();
    }
}

/// Rasterizes a single triangle into a specific tile's local buffer.
/// This is the core "drawing" function for the tiled pipeline.
pub fn rasterizeTriangleToTile(
    tile: *const Tile,
    tile_buffer: *TileBuffer,
    p0_screen: math.Vec2,
    p1_screen: math.Vec2,
    p2_screen: math.Vec2,
    camera_positions: [3]math.Vec3,
    depths: [3]f32,
    shading: ShadingParams,
    perf_stats: ?*RasterizePerfStats,
) void {
    // 1. Convert vertex coordinates from screen space to tile-local space.
    const v0x = p0_screen.x - @as(f32, @floatFromInt(tile.x));
    const v0y = p0_screen.y - @as(f32, @floatFromInt(tile.y));
    const v1x = p1_screen.x - @as(f32, @floatFromInt(tile.x));
    const v1y = p1_screen.y - @as(f32, @floatFromInt(tile.y));
    const v2x = p2_screen.x - @as(f32, @floatFromInt(tile.x));
    const v2y = p2_screen.y - @as(f32, @floatFromInt(tile.y));

    // 2. Calculate the triangle's bounding box within the tile to minimize pixel checks.
    const raw_min_x = @min(v0x, @min(v1x, v2x));
    const raw_min_y = @min(v0y, @min(v1y, v2y));
    const raw_max_x = @max(v0x, @max(v1x, v2x));
    const raw_max_y = @max(v0y, @max(v1y, v2y));

    const min_x = scanline.maxI32(0, scanline.minI32(tile_buffer.width - 1, @as(i32, @intFromFloat(@floor(raw_min_x)))));
    const min_y = scanline.maxI32(0, scanline.minI32(tile_buffer.height - 1, @as(i32, @intFromFloat(@floor(raw_min_y)))));
    const max_x = scanline.minI32(tile_buffer.width - 1, scanline.maxI32(0, @as(i32, @intFromFloat(@ceil(raw_max_x)))));
    const max_y = scanline.minI32(tile_buffer.height - 1, scanline.maxI32(0, @as(i32, @intFromFloat(@ceil(raw_max_y)))));

    if (min_x > max_x or min_y > max_y) return; // Bounding box is empty.

    // 3. Pre-calculate values for barycentric coordinate calculation.
    const denom = (v1y - v2y) * (v0x - v2x) + (v2x - v1x) * (v0y - v2y);
    if (@abs(denom) < 1e-6) return; // Degenerate triangle.

    // Per-triangle LOD selection for memory locality (drastically improves cache hits)
    var lod: f32 = 0.0;
    if (shading.texture) |tex| {
        const tex_w = @as(f32, @floatFromInt(tex.width));
        const tex_h = @as(f32, @floatFromInt(tex.height));
        const uvx0 = shading.uv0.x * tex_w;
        const uvy0 = shading.uv0.y * tex_h;
        const uvx1 = shading.uv1.x * tex_w;
        const uvy1 = shading.uv1.y * tex_h;
        const uvx2 = shading.uv2.x * tex_w;
        const uvy2 = shading.uv2.y * tex_h;

        const uv_denom = (uvy1 - uvy2) * (uvx0 - uvx2) + (uvx2 - uvx1) * (uvy0 - uvy2);

        const screen_area = @abs(denom);
        const uv_area = @abs(uv_denom);

        if (uv_area > screen_area) {
            const ratio = uv_area / screen_area;
            lod = 0.5 * @log2(ratio);
        }
    }

    const inv_denom = 1.0 / denom;
    const lambda0_dx = (v1y - v2y) * inv_denom;
    const lambda0_dy = (v2x - v1x) * inv_denom;
    const lambda1_dx = (v2y - v0y) * inv_denom;
    const lambda1_dy = (v0x - v2x) * inv_denom;
    const lambda2_dx = -lambda0_dx - lambda1_dx;
    const lambda2_dy = -lambda0_dy - lambda1_dy;
    const inv_depth0 = 1.0 / @max(depths[0], 1e-6);
    const inv_depth1 = 1.0 / @max(depths[1], 1e-6);
    const inv_depth2 = 1.0 / @max(depths[2], 1e-6);
    const batch_lanes = runtimeSpanBatchLanes();
    const has_texture = shading.texture != null;
    const uniform_albedo = lighting.unpackColorLinear(shading.base_color);
    const triangle_id = shading.triangle_id;
    const meshlet_id = shading.meshlet_id;
    const tile_width = tile_buffer.width;
    const tile_data = tile_buffer.data;
    const tile_depth = tile_buffer.depth;
    const count_perf = perf_stats != null;
    var covered_pixels_local: usize = 0;
    var depth_tests_passed_local: usize = 0;
    var alpha_pixels_local: usize = 0;
    const start_x_center = @as(f32, @floatFromInt(min_x)) + 0.5;
    const start_y_center = @as(f32, @floatFromInt(min_y)) + 0.5;
    var lambda0_row = ((v1y - v2y) * (start_x_center - v2x) + (v2x - v1x) * (start_y_center - v2y)) * inv_denom;
    var lambda1_row = ((v2y - v0y) * (start_x_center - v2x) + (v0x - v2x) * (start_y_center - v2y)) * inv_denom;
    var lambda2_row = 1.0 - lambda0_row - lambda1_row;

    // 4. Iterate over every pixel within the triangle's bounding box.
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        var lambda0_x = lambda0_row;
        var lambda1_x = lambda1_row;
        var lambda2_x = lambda2_row;
        while (x <= max_x) {
            const batch_end = @min(max_x + 1, x + @as(i32, @intCast(batch_lanes)));
            var batch_weight0: [max_span_batch_lanes]f32 = undefined;
            var batch_weight1: [max_span_batch_lanes]f32 = undefined;
            var batch_weight2: [max_span_batch_lanes]f32 = undefined;
            var batch_indices: [max_span_batch_lanes]usize = undefined;
            var gather_count: usize = 0;

            while (x < batch_end) : (x += 1) {
                const lambda0 = lambda0_x;
                const lambda1 = lambda1_x;
                const lambda2 = lambda2_x;
                lambda0_x += lambda0_dx;
                lambda1_x += lambda1_dx;
                lambda2_x += lambda2_dx;
                if (lambda0 < 0 or lambda1 < 0 or lambda2 < 0) continue;

                const persp0 = lambda0 * inv_depth0;
                const persp1 = lambda1 * inv_depth1;
                const persp2 = lambda2 * inv_depth2;
                const persp_sum = persp0 + persp1 + persp2;
                if (persp_sum <= 1e-6) continue;

                const inv_persp_sum = 1.0 / persp_sum;
                const w0 = persp0 * inv_persp_sum;
                const w1 = persp1 * inv_persp_sum;
                const w2 = persp2 * inv_persp_sum;

                // Early depth reject: interpolate camera Z cheaply and skip
                // pixels already behind the depth buffer. This avoids all
                // downstream interpolation, texture sampling, and PBR work.
                const interp_z = camera_positions[0].z * w0 + camera_positions[1].z * w1 + camera_positions[2].z * w2;
                const idx = @as(usize, @intCast(y * tile_width + x));
                if (interp_z >= tile_depth[idx]) continue;

                batch_weight0[gather_count] = w0;
                batch_weight1[gather_count] = w1;
                batch_weight2[gather_count] = w2;
                batch_indices[gather_count] = idx;
                gather_count += 1;
                if (count_perf) covered_pixels_local += 1;
            }

            if (gather_count == 0) continue;

            var batch_camera_pos: [max_span_batch_lanes]math.Vec3 = undefined;
            var batch_uvs: [max_span_batch_lanes]math.Vec2 = undefined;
            var batch_normals: [max_span_batch_lanes]math.Vec3 = undefined;
            var batch_surface_bary: [max_span_batch_lanes]math.Vec3 = undefined;
            interpolateVec3Batch(camera_positions[0], camera_positions[1], camera_positions[2], batch_weight0[0..gather_count], batch_weight1[0..gather_count], batch_weight2[0..gather_count], batch_camera_pos[0..gather_count]);
            interpolateVec2Batch(shading.uv0, shading.uv1, shading.uv2, batch_weight0[0..gather_count], batch_weight1[0..gather_count], batch_weight2[0..gather_count], batch_uvs[0..gather_count]);
            interpolateVec3Batch(shading.normals[0], shading.normals[1], shading.normals[2], batch_weight0[0..gather_count], batch_weight1[0..gather_count], batch_weight2[0..gather_count], batch_normals[0..gather_count]);
            interpolateVec3Batch(shading.surface_bary0, shading.surface_bary1, shading.surface_bary2, batch_weight0[0..gather_count], batch_weight1[0..gather_count], batch_weight2[0..gather_count], batch_surface_bary[0..gather_count]);
            normalizeVec3Batch(batch_normals[0..gather_count], batch_normals[0..gather_count]);

            var batch_base_color_u32: [max_span_batch_lanes]u32 = undefined;
            if (shading.texture) |tex| {
                tex.sampleLodBatch(batch_uvs[0..gather_count], lod, batch_base_color_u32[0..gather_count]);
            } else {
                @memset(batch_base_color_u32[0..gather_count], shading.base_color);
            }

            var active_indices: [max_span_batch_lanes]usize = undefined;
            var active_camera_pos: [max_span_batch_lanes]math.Vec3 = undefined;
            var active_normals: [max_span_batch_lanes]math.Vec3 = undefined;
            var active_surface_bary: [max_span_batch_lanes]math.Vec3 = undefined;
            var active_view_inputs: [max_span_batch_lanes]math.Vec3 = undefined;
            var active_albedos: [max_span_batch_lanes]math.Vec3 = undefined;
            var active_alpha: [max_span_batch_lanes]u32 = undefined;
            var active_depth: [max_span_batch_lanes]f32 = undefined;
            var opaque_lanes: [max_span_batch_lanes]usize = undefined;
            var translucent_lanes: [max_span_batch_lanes]usize = undefined;
            var opaque_count: usize = 0;
            var translucent_count: usize = 0;
            var active_count: usize = 0;

            for (0..gather_count) |lane| {
                const idx = batch_indices[lane];
                const depth = batch_camera_pos[lane].z;
                if (depth >= tile_depth[idx]) continue;
                if (count_perf) depth_tests_passed_local += 1;

                const alpha = (batch_base_color_u32[lane] >> 24) & 0xFF;
                if (alpha == 0) continue;

                active_indices[active_count] = idx;
                active_camera_pos[active_count] = batch_camera_pos[lane];
                active_normals[active_count] = batch_normals[lane];
                active_surface_bary[active_count] = batch_surface_bary[lane];
                active_view_inputs[active_count] = math.Vec3.scale(batch_camera_pos[lane], -1.0);
                active_albedos[active_count] = if (has_texture) lighting.unpackColorLinear(batch_base_color_u32[lane]) else uniform_albedo;
                active_alpha[active_count] = alpha;
                active_depth[active_count] = depth;
                if (alpha == 255) {
                    opaque_lanes[opaque_count] = active_count;
                    opaque_count += 1;
                } else {
                    if (count_perf) alpha_pixels_local += 1;
                    translucent_lanes[translucent_count] = active_count;
                    translucent_count += 1;
                }
                active_count += 1;
            }

            if (active_count == 0) continue;

            var active_view_dirs: [max_span_batch_lanes]math.Vec3 = undefined;
            var shaded_colors: [max_span_batch_lanes]math.Vec3 = undefined;
            normalizeVec3Batch(active_view_inputs[0..active_count], active_view_dirs[0..active_count]);
            lighting.computePBRBatch(active_albedos[0..active_count], active_normals[0..active_count], active_view_dirs[0..active_count], raster_light_dir, raster_light_color, shading.metallic, shading.roughness, shaded_colors[0..active_count]);

            for (opaque_lanes[0..opaque_count]) |lane| {
                const final_color_rgb = shaded_colors[lane];
                const idx = active_indices[lane];
                tile_depth[idx] = active_depth[lane];
                tile_data[idx].camera = active_camera_pos[lane];
                tile_data[idx].color = math.Vec4.new(final_color_rgb.x, final_color_rgb.y, final_color_rgb.z, 1.0);
                tile_data[idx].normal = active_normals[lane];
                tile_data[idx].surface = SurfaceHandle.init(triangle_id, meshlet_id, active_surface_bary[lane]);
            }

            for (translucent_lanes[0..translucent_count]) |lane| {
                const final_color_rgb = shaded_colors[lane];
                const alpha_f = @as(f32, @floatFromInt(active_alpha[lane])) / 255.0;
                const inv_alpha = 1.0 - alpha_f;
                const idx = active_indices[lane];
                const dst_c = tile_data[idx].color;
                tile_data[idx].color = math.Vec4.new(
                    final_color_rgb.x * alpha_f + dst_c.x * inv_alpha,
                    final_color_rgb.y * alpha_f + dst_c.y * inv_alpha,
                    final_color_rgb.z * alpha_f + dst_c.z * inv_alpha,
                    1.0,
                );
            }
        }
        lambda0_row += lambda0_dy;
        lambda1_row += lambda1_dy;
        lambda2_row += lambda2_dy;
    }

    if (perf_stats) |stats| {
        stats.triangles_rasterized += 1;
        stats.covered_pixels += covered_pixels_local;
        stats.depth_tests_passed += depth_tests_passed_local;
        stats.alpha_pixels += alpha_pixels_local;
    }
}

/// Draws a line into a tile buffer (used for wireframes).
pub fn drawLineToTile(tile: *const Tile, tile_buffer: *TileBuffer, p0_screen: math.Vec2, p1_screen: math.Vec2, color: u32) void {
    var x0 = @as(i32, @intFromFloat(p0_screen.x)) - tile.x;
    var y0 = @as(i32, @intFromFloat(p0_screen.y)) - tile.y;
    const x1 = @as(i32, @intFromFloat(p1_screen.x)) - tile.x;
    const y1 = @as(i32, @intFromFloat(p1_screen.y)) - tile.y;

    const clamp = struct {
        fn inBounds(x: i32, y: i32, width: i32, height: i32) bool {
            return x >= 0 and x < width and y >= 0 and y < height;
        }
    };

    const dx = if (x0 < x1) x1 - x0 else x0 - x1;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = if (y0 < y1) y1 - y0 else y0 - y1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = if (dx > dy) dx else -dy;

    while (true) {
        if (clamp.inBounds(x0, y0, tile_buffer.width, tile_buffer.height)) {
            const idx = @as(usize, @intCast(y0 * tile_buffer.width + x0));
            if (idx < tile_buffer.data.len) {
                const r = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                const g = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                const b = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
                const a = @as(f32, @floatFromInt((color >> 24) & 0xFF)) / 255.0;
                tile_buffer.data[idx].color = math.Vec4.new(r, g, b, a);
            }
        }

        if (x0 == x1 and y0 == y1) break;

        const err2 = err;
        if (err2 > -dx) {
            err -= dy;
            x0 += sx;
        }
        if (err2 < dy) {
            err += dx;
            y0 += sy;
        }
    }
}
