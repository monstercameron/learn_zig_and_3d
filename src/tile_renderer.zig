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
const Bitmap = @import("bitmap.zig").Bitmap;
const scanline = @import("scanline.zig");
const math = @import("math.zig");
const texture = @import("texture.zig");
const lighting = @import("lighting.zig");

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
    intensity: f32,
};

// ========== TILE STRUCTURES ==========

/// Represents a single rectangular tile in the screen grid.
pub const Tile = struct {
    x: i32, // The screen-space X coordinate of the tile's top-left corner.
    y: i32, // The screen-space Y coordinate of the tile's top-left corner.
    width: i32, // The width of the tile. Can be less than TILE_SIZE for tiles at the screen edge.
    height: i32, // The height of the tile.
    index: usize, // The unique index of this tile within the grid.

    pub fn init(x: i32, y: i32, width: i32, height: i32, index: usize) Tile {
        return Tile{ .x = x, .y = y, .width = width, .height = height, .index = index };
    }

    pub fn right(self: Tile) i32 {
        return self.x + self.width;
    }

    pub fn bottom(self: Tile) i32 {
        return self.y + self.height;
    }
};

/// A per-tile rendering buffer. Each worker thread renders into one of these.
/// JS Analogy: This is like a small, off-screen `<canvas>` for a single worker.
pub const TileBuffer = struct {
    pixels: []u32, // The local pixel buffer for this tile.
    depth: []f32, // The local depth buffer (z-buffer) for this tile.
    width: i32,
    height: i32,
    allocator: std.mem.Allocator,

    pub fn init(width: i32, height: i32, allocator: std.mem.Allocator) !TileBuffer {
        const pixel_count = @as(usize, @intCast(width * height));
        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);
        const depth = try allocator.alloc(f32, pixel_count);
        return TileBuffer{ .pixels = pixels, .depth = depth, .width = width, .height = height, .allocator = allocator };
    }

    /// Clears the tile for a new frame. Fills with a background color and resets the depth buffer.
    pub fn clear(self: *TileBuffer) void {
        @memset(self.pixels, 0xFF000000); // Black background.
        // Reset all depth values to infinity. The first pixel drawn at any location will always be closer.
        @memset(self.depth, std.math.inf(f32));
    }

    pub fn deinit(self: *TileBuffer) void {
        self.allocator.free(self.pixels);
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

    pub fn deinit(self: *TileGrid) void {
        self.allocator.free(self.tiles);
    }
};

// ========== TILE RENDERING UTILITIES ==========

/// Copies the pixels from a completed tile buffer to the main screen bitmap.
/// JS Analogy: `main_context.drawImage(tile_canvas, tile.x, tile.y);`
pub fn compositeTileToScreen(tile: *const Tile, tile_buffer: *const TileBuffer, bitmap: *Bitmap) void {
    var y: i32 = 0;
    while (y < tile.height) : (y += 1) {
        const screen_y = tile.y + y;
        if (screen_y < 0 or screen_y >= bitmap.height) continue;
        var x: i32 = 0;
        while (x < tile.width) : (x += 1) {
            const screen_x = tile.x + x;
            if (screen_x < 0 or screen_x >= bitmap.width) continue;

            const tile_idx = @as(usize, @intCast(y * tile_buffer.width + x));
            const screen_idx = @as(usize, @intCast(screen_y * bitmap.width + screen_x));

            if (tile_idx < tile_buffer.pixels.len and screen_idx < bitmap.pixels.len) {
                bitmap.pixels[screen_idx] = tile_buffer.pixels[tile_idx];
            }
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

/// Rasterizes a single triangle into a specific tile's local buffer.
/// This is the core "drawing" function for the tiled pipeline.
pub fn rasterizeTriangleToTile(tile: *const Tile, tile_buffer: *TileBuffer, p0_screen: [2]i32, p1_screen: [2]i32, p2_screen: [2]i32, shading: ShadingParams) void {
    // 1. Convert vertex coordinates from screen space to tile-local space.
    const v0 = [2]i32{ p0_screen[0] - tile.x, p0_screen[1] - tile.y };
    const v1 = [2]i32{ p1_screen[0] - tile.x, p1_screen[1] - tile.y };
    const v2 = [2]i32{ p2_screen[0] - tile.x, p2_screen[1] - tile.y };

    // 2. Calculate the triangle's bounding box within the tile to minimize pixel checks.
    const min_x = scanline.maxI32(0, scanline.minI32(v0[0], scanline.minI32(v1[0], v2[0])));
    const min_y = scanline.maxI32(0, scanline.minI32(v0[1], scanline.minI32(v1[1], v2[1])));
    const max_x = scanline.minI32(tile_buffer.width - 1, scanline.maxI32(v0[0], scanline.maxI32(v1[0], v2[0])));
    const max_y = scanline.minI32(tile_buffer.height - 1, scanline.maxI32(v0[1], scanline.maxI32(v1[1], v2[1])));

    if (min_x > max_x or min_y > max_y) return; // Bounding box is empty.

    // 3. Pre-calculate values for barycentric coordinate calculation.
    const v0x = @as(f32, @floatFromInt(v0[0]));
    const v0y = @as(f32, @floatFromInt(v0[1]));
    const v1x = @as(f32, @floatFromInt(v1[0]));
    const v1y = @as(f32, @floatFromInt(v1[1]));
    const v2x = @as(f32, @floatFromInt(v2[0]));
    const v2y = @as(f32, @floatFromInt(v2[1]));
    const denom = (v1y - v2y) * (v0x - v2x) + (v2x - v1x) * (v0y - v2y);
    if (@abs(denom) < 1e-6) return; // Degenerate triangle.
    const inv_denom = 1.0 / denom;

    // 4. Iterate over every pixel within the triangle's bounding box.
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;

            // 5. Calculate barycentric coordinates (lambda0, lambda1, lambda2).
            // These are weights that describe the current pixel's position relative to the
            // triangle's vertices. If all weights are between 0 and 1, the pixel is inside.
            const lambda0 = ((v1y - v2y) * (px - v2x) + (v2x - v1x) * (py - v2y)) * inv_denom;
            const lambda1 = ((v2y - v0y) * (px - v2x) + (v0x - v2x) * (py - v2y)) * inv_denom;
            const lambda2 = 1.0 - lambda0 - lambda1;

            // 6. Check if the pixel is inside the triangle.
            if (lambda0 < 0 or lambda1 < 0 or lambda2 < 0) continue;

            // TODO: Implement Z-buffering here by interpolating vertex depths using
            // the barycentric coordinates and comparing with the value in `tile_buffer.depth`.

            // 7. Interpolate UV coordinates using the barycentric weights.
            const uv = math.Vec2.new(
                shading.uv0.x * lambda0 + shading.uv1.x * lambda1 + shading.uv2.x * lambda2,
                shading.uv0.y * lambda0 + shading.uv1.y * lambda1 + shading.uv2.y * lambda2,
            );

            // 8. Sample the texture and apply lighting to get the final pixel color.
            var base_color = shading.base_color;
            if (shading.texture) |tex| base_color = tex.sample(uv);
            const final_color = lighting.applyIntensity(base_color, shading.intensity);

            // 9. Write the final color to the tile's local pixel buffer.
            const idx = @as(usize, @intCast(y * tile_buffer.width + x));
            if (idx < tile_buffer.pixels.len) {
                tile_buffer.pixels[idx] = final_color;
            }
        }
    }
}

/// Draws a line into a tile buffer (used for wireframes).
pub fn drawLineToTile(tile: *const Tile, tile_buffer: *TileBuffer, p0_screen: [2]i32, p1_screen: [2]i32, color: u32) void {
    var x0 = p0_screen[0] - tile.x;
    var y0 = p0_screen[1] - tile.y;
    const x1 = p1_screen[0] - tile.x;
    const y1 = p1_screen[1] - tile.y;

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
            if (idx < tile_buffer.pixels.len) tile_buffer.pixels[idx] = color;
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