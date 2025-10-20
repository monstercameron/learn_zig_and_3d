//! # Tile Renderer Module
//!
//! This module implements tile-based rendering infrastructure.
//! The screen is divided into fixed-size tiles that can be rendered independently,
//! enabling better cache locality and future parallelization.
//!
//! **Key Concepts**:
//! - Screen divided into NxM grid of tiles
//! - Each tile has local pixel/depth buffer
//! - Triangles are binned to tiles they overlap
//! - Tiles can be rendered independently (embarrassingly parallel)

const std = @import("std");
const Bitmap = @import("bitmap.zig").Bitmap;

// ========== CONSTANTS ==========

/// Tile size in pixels (width and height)
/// 64x64 provides good balance between:
/// - Cache locality (4KB per tile at 32bpp = L1 cache friendly)
/// - Parallelism granularity (enough tiles for many threads)
/// - Overhead (not too many tiles to manage)
pub const TILE_SIZE: i32 = 64;

// ========== TILE STRUCTURE ==========

/// Represents a single tile in the screen grid
pub const Tile = struct {
    /// X position in screen space (top-left corner)
    x: i32,
    /// Y position in screen space (top-left corner)
    y: i32,
    /// Width in pixels (may be less than TILE_SIZE for edge tiles)
    width: i32,
    /// Height in pixels (may be less than TILE_SIZE for edge tiles)
    height: i32,
    /// Tile index in grid (for debugging and identification)
    index: usize,

    /// Create a new tile
    pub fn init(x: i32, y: i32, width: i32, height: i32, index: usize) Tile {
        return Tile{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .index = index,
        };
    }

    /// Check if a point is inside this tile
    pub fn contains(self: Tile, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + self.width and
            y >= self.y and y < self.y + self.height;
    }

    /// Get the right edge of the tile
    pub fn right(self: Tile) i32 {
        return self.x + self.width;
    }

    /// Get the bottom edge of the tile
    pub fn bottom(self: Tile) i32 {
        return self.y + self.height;
    }
};

// ========== TILE BUFFER ==========

/// Per-tile rendering buffer
/// Each tile has its own pixel buffer for independent rendering
pub const TileBuffer = struct {
    /// Pixel data (BGRA format, same as main bitmap)
    pixels: []u32,
    /// Depth buffer for z-testing (one float per pixel)
    depth: []f32,
    /// Width of tile buffer in pixels
    width: i32,
    /// Height of tile buffer in pixels
    height: i32,
    /// Allocator for memory management
    allocator: std.mem.Allocator,

    /// Initialize a tile buffer with given dimensions
    pub fn init(width: i32, height: i32, allocator: std.mem.Allocator) !TileBuffer {
        const pixel_count = @as(usize, @intCast(width * height));

        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);

        const depth = try allocator.alloc(f32, pixel_count);

        return TileBuffer{
            .pixels = pixels,
            .depth = depth,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Clear tile buffer to background color and reset depth
    pub fn clear(self: *TileBuffer) void {
        const black: u32 = 0xFF000000;
        @memset(self.pixels, black);
        @memset(self.depth, std.math.inf(f32));
    }

    /// Free tile buffer resources
    pub fn deinit(self: *TileBuffer) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.depth);
    }
};

// ========== TILE GRID ==========

/// Manages the grid of tiles covering the screen
pub const TileGrid = struct {
    /// Array of all tiles in the grid
    tiles: []Tile,
    /// Number of tiles horizontally
    cols: usize,
    /// Number of tiles vertically
    rows: usize,
    /// Screen width in pixels
    screen_width: i32,
    /// Screen height in pixels
    screen_height: i32,
    /// Allocator for memory management
    allocator: std.mem.Allocator,

    /// Calculate and create tile grid for given screen dimensions
    pub fn init(screen_width: i32, screen_height: i32, allocator: std.mem.Allocator) !TileGrid {
        // Calculate how many tiles we need (round up)
        const cols = @as(usize, @intCast((@divTrunc(screen_width + TILE_SIZE - 1, TILE_SIZE))));
        const rows = @as(usize, @intCast((@divTrunc(screen_height + TILE_SIZE - 1, TILE_SIZE))));
        const tile_count = cols * rows;

        // Allocate tile array
        const tiles = try allocator.alloc(Tile, tile_count);

        // Initialize each tile
        var index: usize = 0;
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            var col: usize = 0;
            while (col < cols) : (col += 1) {
                const tile_x = @as(i32, @intCast(col)) * TILE_SIZE;
                const tile_y = @as(i32, @intCast(row)) * TILE_SIZE;

                // Calculate tile dimensions (edge tiles may be smaller)
                const tile_width = @min(TILE_SIZE, screen_width - tile_x);
                const tile_height = @min(TILE_SIZE, screen_height - tile_y);

                tiles[index] = Tile.init(tile_x, tile_y, tile_width, tile_height, index);
                index += 1;
            }
        }

        return TileGrid{
            .tiles = tiles,
            .cols = cols,
            .rows = rows,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .allocator = allocator,
        };
    }

    /// Get tile at specific grid position
    pub fn getTile(self: *const TileGrid, col: usize, row: usize) ?*const Tile {
        if (col >= self.cols or row >= self.rows) return null;
        const index = row * self.cols + col;
        return &self.tiles[index];
    }

    /// Free tile grid resources
    pub fn deinit(self: *TileGrid) void {
        self.allocator.free(self.tiles);
    }
};

// ========== TILE RENDERING UTILITIES ==========

/// Composite a tile buffer to the main screen bitmap
pub fn compositeTileToScreen(tile: *const Tile, tile_buffer: *const TileBuffer, bitmap: *Bitmap) void {
    // Copy tile pixels to screen at tile position
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

/// Draw tile boundaries for debugging (visualize tile grid)
pub fn drawTileBoundaries(grid: *const TileGrid, bitmap: *Bitmap) void {
    const border_color: u32 = 0xFF00FF00; // Green borders

    for (grid.tiles) |tile| {
        // Draw top border
        var x: i32 = tile.x;
        while (x < tile.right() and x < bitmap.width) : (x += 1) {
            const y = tile.y;
            if (y >= 0 and y < bitmap.height) {
                const idx = @as(usize, @intCast(y * bitmap.width + x));
                if (idx < bitmap.pixels.len) {
                    bitmap.pixels[idx] = border_color;
                }
            }
        }

        // Draw left border
        var y: i32 = tile.y;
        while (y < tile.bottom() and y < bitmap.height) : (y += 1) {
            x = tile.x;
            if (x >= 0 and x < bitmap.width) {
                const idx = @as(usize, @intCast(y * bitmap.width + x));
                if (idx < bitmap.pixels.len) {
                    bitmap.pixels[idx] = border_color;
                }
            }
        }
    }
}

// ========== TILE RASTERIZATION ==========

/// Helper: min of two i32 values
fn minI32(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

/// Helper: max of two i32 values
fn maxI32(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}

/// Helper: clamp value between min and max
fn clampI32(val: i32, min_val: i32, max_val: i32) i32 {
    return maxI32(min_val, minI32(max_val, val));
}

/// Calculate X intersection of line segment with horizontal scanline
fn lineIntersectionX(x1: i32, y1: i32, x2: i32, y2: i32, y: i32) i32 {
    if (y1 == y2) return x1;
    const dy = y2 - y1;
    const dx = x2 - x1;
    const t_num = y - y1;
    return x1 + @divTrunc(t_num * dx, dy);
}

/// Rasterize a filled triangle into a tile buffer
/// Vertices are in SCREEN space, will be converted to tile-local coordinates
pub fn rasterizeTriangleToTile(
    tile: *const Tile,
    tile_buffer: *TileBuffer,
    p0_screen: [2]i32,
    p1_screen: [2]i32,
    p2_screen: [2]i32,
    color: u32,
) void {
    // Convert screen coordinates to tile-local coordinates
    var v0 = [2]i32{ p0_screen[0] - tile.x, p0_screen[1] - tile.y };
    var v1 = [2]i32{ p1_screen[0] - tile.x, p1_screen[1] - tile.y };
    var v2 = [2]i32{ p2_screen[0] - tile.x, p2_screen[1] - tile.y };

    // Sort vertices by Y coordinate (bubble sort)
    if (v0[1] > v1[1]) {
        const temp = v0;
        v0 = v1;
        v1 = temp;
    }
    if (v1[1] > v2[1]) {
        const temp = v1;
        v1 = v2;
        v2 = temp;
    }
    if (v0[1] > v1[1]) {
        const temp = v0;
        v0 = v1;
        v1 = temp;
    }

    const top_x = v0[0];
    const top_y = v0[1];
    const mid_x = v1[0];
    const mid_y = v1[1];
    const bot_x = v2[0];
    const bot_y = v2[1];

    // Skip degenerate triangles
    if (top_y == mid_y and mid_y == bot_y) return;

    // Clamp Y range to tile bounds
    const y_start = maxI32(0, top_y);
    const y_end = minI32(tile_buffer.height - 1, bot_y);

    // Draw upper half (from top to middle)
    if (top_y < mid_y) {
        var y = maxI32(y_start, top_y);
        while (y <= minI32(y_end, mid_y)) : (y += 1) {
            const x_left_edge = lineIntersectionX(top_x, top_y, mid_x, mid_y, y);
            const x_right_edge = lineIntersectionX(top_x, top_y, bot_x, bot_y, y);

            var x_left = minI32(x_left_edge, x_right_edge);
            var x_right = maxI32(x_left_edge, x_right_edge);

            // Clamp to tile bounds
            x_left = maxI32(0, x_left);
            x_right = minI32(tile_buffer.width - 1, x_right);

            // Fill scanline
            var x = x_left;
            while (x <= x_right) : (x += 1) {
                const idx = @as(usize, @intCast(y * tile_buffer.width + x));
                if (idx < tile_buffer.pixels.len) {
                    tile_buffer.pixels[idx] = color;
                }
            }
        }
    }

    // Draw lower half (from middle to bottom)
    if (mid_y < bot_y) {
        var y = maxI32(y_start, mid_y);
        while (y <= minI32(y_end, bot_y)) : (y += 1) {
            const x_left_edge = lineIntersectionX(mid_x, mid_y, bot_x, bot_y, y);
            const x_right_edge = lineIntersectionX(top_x, top_y, bot_x, bot_y, y);

            var x_left = minI32(x_left_edge, x_right_edge);
            var x_right = maxI32(x_left_edge, x_right_edge);

            // Clamp to tile bounds
            x_left = maxI32(0, x_left);
            x_right = minI32(tile_buffer.width - 1, x_right);

            // Fill scanline
            var x = x_left;
            while (x <= x_right) : (x += 1) {
                const idx = @as(usize, @intCast(y * tile_buffer.width + x));
                if (idx < tile_buffer.pixels.len) {
                    tile_buffer.pixels[idx] = color;
                }
            }
        }
    }
}

/// Draw a line into a tile buffer (for wireframe)
pub fn drawLineToTile(
    tile: *const Tile,
    tile_buffer: *TileBuffer,
    p0_screen: [2]i32,
    p1_screen: [2]i32,
    color: u32,
) void {
    // Convert to tile-local coordinates
    const x0_init = p0_screen[0] - tile.x;
    const y0_init = p0_screen[1] - tile.y;
    const x1 = p1_screen[0] - tile.x;
    const y1 = p1_screen[1] - tile.y;

    const dx = if (x0_init < x1) x1 - x0_init else x0_init - x1;
    const dy = if (y0_init < y1) y1 - y0_init else y0_init - y1;

    const sx = if (x0_init < x1) @as(i32, 1) else @as(i32, -1);
    const sy = if (y0_init < y1) @as(i32, 1) else @as(i32, -1);

    var err = dx - dy;

    var x = x0_init;
    var y = y0_init;

    while (true) {
        // Plot if within tile bounds
        if (x >= 0 and x < tile_buffer.width and y >= 0 and y < tile_buffer.height) {
            const idx = @as(usize, @intCast(y * tile_buffer.width + x));
            if (idx < tile_buffer.pixels.len) {
                tile_buffer.pixels[idx] = color;
            }
        }

        if (x == x1 and y == y1) break;

        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            x += sx;
        }
        if (e2 < dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Highlight a tile with a semi-transparent overlay color (for visualization)
/// Draws a filled rectangle over the tile area on the main bitmap
pub fn highlightTile(tile: *const Tile, bitmap: *Bitmap, color: u32) void {
    const y_start = tile.y;
    const y_end = tile.y + tile.height;
    const x_start = tile.x;
    const x_end = tile.x + tile.width;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        if (y < 0 or y >= bitmap.height) continue;

        var x = x_start;
        while (x < x_end) : (x += 1) {
            if (x < 0 or x >= bitmap.width) continue;

            const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(bitmap.width)) + @as(usize, @intCast(x));
            if (idx < bitmap.pixels.len) {
                // Blend with existing pixel (50% opacity)
                const existing = bitmap.pixels[idx];
                const existing_r = (existing >> 16) & 0xFF;
                const existing_g = (existing >> 8) & 0xFF;
                const existing_b = (existing >> 0) & 0xFF;

                const highlight_r = (color >> 16) & 0xFF;
                const highlight_g = (color >> 8) & 0xFF;
                const highlight_b = (color >> 0) & 0xFF;

                const blended_r = ((existing_r + highlight_r) / 2) << 16;
                const blended_g = ((existing_g + highlight_g) / 2) << 8;
                const blended_b = (existing_b + highlight_b) / 2;

                bitmap.pixels[idx] = 0xFF000000 | blended_r | blended_g | blended_b;
            }
        }
    }
}
