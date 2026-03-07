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
    normals: [3]math.Vec3,
    metallic: f32,
    roughness: f32,
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
pub const PixelData = struct {
    color: math.Vec4,
    camera: math.Vec3,
    normal: math.Vec3,
};

pub const TileBuffer = struct {
    data: []PixelData, // The fat buffer for colors, camera, and normal
    depth: []f32, // Kept separate for fast dense Early-Z testing
    width: i32,
    height: i32,
    allocator: std.mem.Allocator,

    pub fn init(width: i32, height: i32, allocator: std.mem.Allocator) !TileBuffer {
        const pixel_count = @as(usize, @intCast(width * height));
        const data = try allocator.alloc(PixelData, pixel_count);
        errdefer allocator.free(data);
        const depth = try allocator.alloc(f32, pixel_count);
        
        return TileBuffer{ 
            .data = data, 
            .depth = depth, 
            .width = width, 
            .height = height, 
            .allocator = allocator 
        };
    }

    /// Clears the tile for a new frame.
    pub fn clear(self: *TileBuffer) void {
        @memset(self.data, .{ .color = math.Vec4.new(0.0, 0.0, 0.0, 1.0), .camera = math.Vec3.new(0,0,0), .normal = math.Vec3.new(0,0,0) });
        @memset(self.depth, std.math.inf(f32));
    }

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

    pub fn deinit(self: *TileGrid) void {
        self.allocator.free(self.tiles);
    }
};

// ========== TILE RENDERING UTILITIES ==========

/// Copies the pixels and geometry buffers from a completed tile buffer to the main screen surfaces.
/// JS Analogy: `main_context.drawImage(tile_canvas, tile.x, tile.y);`
pub fn compositeTileToScreen(tile: *const Tile, tile_buffer: *const TileBuffer, bitmap: *Bitmap, depth_buffer: ?[]f32, camera_buffer: ?[]math.Vec3, normal_buffer: ?[]math.Vec3) void {
    var y: i32 = 0;
    while (y < tile.height) : (y += 1) {
        const tile_row_start = @as(usize, @intCast(y * tile_buffer.width));
        const tile_row_end = tile_row_start + @as(usize, @intCast(tile.width));
        const screen_row_start = @as(usize, @intCast((tile.y + y) * bitmap.width + tile.x));
        const screen_row_end = screen_row_start + @as(usize, @intCast(tile.width));

        var cx: usize = 0;
        const width_usize = @as(usize, @intCast(tile.width));
        while (cx < width_usize) : (cx += 1) {
            const final_color_hdr = tile_buffer.data[tile_row_start + cx].color;
            const final_color_rgb = math.Vec3.new(final_color_hdr.x, final_color_hdr.y, final_color_hdr.z);
            const a = @as(u32, @intFromFloat(final_color_hdr.w * 255.0));
            // pack and tonemap to sRGB
            const packed_u32 = lighting.packColorTonemapped(final_color_rgb, a);
            bitmap.pixels[screen_row_start + cx] = packed_u32;
            
            // Re-interleave the structural data out from AoS to SoA Global buffers
            if (camera_buffer) |camera_out| {
                camera_out[screen_row_start + cx] = tile_buffer.data[tile_row_start + cx].camera;
            }
            if (normal_buffer) |normal_out| {
                normal_out[screen_row_start + cx] = tile_buffer.data[tile_row_start + cx].normal;
            }
        }
        if (depth_buffer) |buffer| {
            std.mem.copyForwards(f32, buffer[screen_row_start..screen_row_end], tile_buffer.depth[tile_row_start..tile_row_end]);
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
pub fn rasterizeTriangleToTile(
    tile: *const Tile,
    tile_buffer: *TileBuffer,
    p0_screen: math.Vec2,
    p1_screen: math.Vec2,
    p2_screen: math.Vec2,
    camera_positions: [3]math.Vec3,
    depths: [3]f32,
    shading: ShadingParams,
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
    const inv_depth0 = 1.0 / @max(depths[0], 1e-6);
    const inv_depth1 = 1.0 / @max(depths[1], 1e-6);
    const inv_depth2 = 1.0 / @max(depths[2], 1e-6);

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

            const persp0 = lambda0 * inv_depth0;
            const persp1 = lambda1 * inv_depth1;
            const persp2 = lambda2 * inv_depth2;
            const persp_sum = persp0 + persp1 + persp2;
            if (persp_sum <= 1e-6) continue;
            const inv_persp_sum = 1.0 / persp_sum;
            const weight0 = persp0 * inv_persp_sum;
            const weight1 = persp1 * inv_persp_sum;
            const weight2 = persp2 * inv_persp_sum;

            const camera_pos = math.Vec3.new(
                camera_positions[0].x * weight0 + camera_positions[1].x * weight1 + camera_positions[2].x * weight2,
                camera_positions[0].y * weight0 + camera_positions[1].y * weight1 + camera_positions[2].y * weight2,
                camera_positions[0].z * weight0 + camera_positions[1].z * weight1 + camera_positions[2].z * weight2,
            );
            const depth = camera_pos.z;

            // 7. Interpolate UV coordinates using the barycentric weights.
            const uv = math.Vec2.new(
                shading.uv0.x * weight0 + shading.uv1.x * weight1 + shading.uv2.x * weight2,
                shading.uv0.y * weight0 + shading.uv1.y * weight1 + shading.uv2.y * weight2,
            );

            // 8. Sample the texture and apply lighting to get the final pixel color.
            var base_color_u32 = shading.base_color;
            if (shading.texture) |tex| base_color_u32 = tex.sampleLod(uv, lod);
            const a = (base_color_u32 >> 24) & 0xFF;
            if (a == 0) continue;

            const base_color_linear = lighting.unpackColorLinear(base_color_u32);

            const n0 = shading.normals[0];
            const n1 = shading.normals[1];
            const n2 = shading.normals[2];
            const normal = math.Vec3.new(
                n0.x * weight0 + n1.x * weight1 + n2.x * weight2,
                n0.y * weight0 + n1.y * weight1 + n2.y * weight2,
                n0.z * weight0 + n1.z * weight1 + n2.z * weight2,
            ).normalize();

            // hardcoded light for now, or we can use shading.intensity later
            const light_dir = math.Vec3.new(0.5, 0.5, -1.0).normalize();
            const light_color = math.Vec3.new(4.0, 4.0, 4.0);
            
            const view_dir = math.Vec3.scale(camera_pos, -1.0).normalize();
            
            const final_color_rgb = lighting.computePBR(
                base_color_linear, normal, view_dir, light_dir, light_color,
                shading.metallic, shading.roughness
            );
            const final_color = math.Vec4.new(final_color_rgb.x, final_color_rgb.y, final_color_rgb.z, @as(f32, @floatFromInt(a)) / 255.0);

            // 9. Write the final color to the tile's local pixel buffer.
            const idx = @as(usize, @intCast(y * tile_buffer.width + x));
            if (idx >= tile_buffer.data.len or idx >= tile_buffer.depth.len) continue;

            if (depth >= tile_buffer.depth[idx]) continue;

            if (a == 255) {
                // Opaque: Overwrite and update depth
                tile_buffer.depth[idx] = depth;
                tile_buffer.data[idx].camera = camera_pos;
                tile_buffer.data[idx].color = final_color;
                tile_buffer.data[idx].normal = normal;
            } else {
                // Alpha blend with background
                const dst_c = tile_buffer.data[idx].color;
                const alpha = final_color.w;
                const inv_alpha = 1.0 - alpha;
                tile_buffer.data[idx].color = math.Vec4.new(
                    final_color.x * alpha + dst_c.x * inv_alpha,
                    final_color.y * alpha + dst_c.y * inv_alpha,
                    final_color.z * alpha + dst_c.z * inv_alpha,
                    1.0
                );
            }
}
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
