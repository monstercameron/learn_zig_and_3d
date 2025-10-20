//! # Binning Stage Module
//!
//! This module handles triangle-to-tile assignment (binning).
//! For each triangle, we determine which tiles it overlaps using bounding box tests.
//!
//! **Key Concepts**:
//! - Calculate 2D bounding box for each triangle in screen space
//! - Test which tiles the bounding box overlaps
//! - Build per-tile lists of triangles to render

const std = @import("std");
const TileRenderer = @import("tile_renderer.zig");
const Tile = TileRenderer.Tile;
const TileGrid = TileRenderer.TileGrid;

// ========== TRIANGLE BOUNDS ==========

/// Axis-aligned bounding box for a triangle in 2D screen space
pub const TriangleBounds = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    /// Calculate bounding box for a triangle given its 3 vertices
    pub fn fromVertices(p0: [2]i32, p1: [2]i32, p2: [2]i32) TriangleBounds {
        const min_x = @min(@min(p0[0], p1[0]), p2[0]);
        const min_y = @min(@min(p0[1], p1[1]), p2[1]);
        const max_x = @max(@max(p0[0], p1[0]), p2[0]);
        const max_y = @max(@max(p0[1], p1[1]), p2[1]);

        return TriangleBounds{
            .min_x = min_x,
            .min_y = min_y,
            .max_x = max_x,
            .max_y = max_y,
        };
    }

    /// Check if bounding box overlaps with a tile
    pub fn overlapsTile(self: TriangleBounds, tile: *const Tile) bool {
        // AABB overlap test: boxes overlap if they DON'T NOT overlap
        // No overlap if: left edge past right edge, or top edge past bottom edge
        const no_overlap = self.max_x < tile.x or // Triangle is left of tile
            self.min_x >= tile.right() or // Triangle is right of tile
            self.max_y < tile.y or // Triangle is above tile
            self.min_y >= tile.bottom(); // Triangle is below tile

        return !no_overlap;
    }

    /// Check if bounding box is completely outside screen bounds
    pub fn isOffscreen(self: TriangleBounds, screen_width: i32, screen_height: i32) bool {
        return self.max_x < 0 or self.min_x >= screen_width or
            self.max_y < 0 or self.min_y >= screen_height;
    }
};

// ========== TILE TRIANGLE LIST ==========

/// List of triangle indices assigned to a specific tile
pub const TileTriangleList = struct {
    /// Array of triangle indices that overlap this tile
    triangles: std.ArrayList(usize),
    /// Allocator for dynamic array
    allocator: std.mem.Allocator,

    /// Initialize an empty triangle list
    pub fn init(allocator: std.mem.Allocator) TileTriangleList {
        return TileTriangleList{
            .triangles = std.ArrayList(usize){},
            .allocator = allocator,
        };
    }

    /// Add a triangle index to the list
    pub fn append(self: *TileTriangleList, triangle_index: usize) !void {
        try self.triangles.append(self.allocator, triangle_index);
    }

    /// Get number of triangles in list
    pub fn count(self: *const TileTriangleList) usize {
        return self.triangles.items.len;
    }

    /// Clear the list (for reuse between frames)
    pub fn clear(self: *TileTriangleList) void {
        self.triangles.clearRetainingCapacity();
    }

    /// Free resources
    pub fn deinit(self: *TileTriangleList) void {
        self.triangles.deinit(self.allocator);
    }
};

// ========== BINNING FUNCTIONS ==========

/// Bin triangles to tiles based on their screen-space bounding boxes
/// Returns array of triangle lists (one per tile)
pub fn binTrianglesToTiles(
    projected_vertices: [][2]i32,
    triangle_indices: [][3]usize, // Array of [v0, v1, v2] index triplets
    grid: *const TileGrid,
    allocator: std.mem.Allocator,
) ![]TileTriangleList {
    // Allocate one triangle list per tile
    const tile_lists = try allocator.alloc(TileTriangleList, grid.tiles.len);
    for (tile_lists) |*list| {
        list.* = TileTriangleList.init(allocator);
    }

    // For each triangle, determine which tiles it overlaps
    for (triangle_indices, 0..) |tri, tri_idx| {
        const p0 = projected_vertices[tri[0]];
        const p1 = projected_vertices[tri[1]];
        const p2 = projected_vertices[tri[2]];

        // Calculate triangle bounding box
        const bounds = TriangleBounds.fromVertices(p0, p1, p2);

        // Early reject: completely offscreen
        if (bounds.isOffscreen(grid.screen_width, grid.screen_height)) {
            continue;
        }

        // Test against each tile
        for (grid.tiles, 0..) |*tile, tile_idx| {
            if (bounds.overlapsTile(tile)) {
                try tile_lists[tile_idx].append(tri_idx);
            }
        }
    }

    return tile_lists;
}

/// Free triangle lists allocated by binTrianglesToTiles
pub fn freeTileTriangleLists(lists: []TileTriangleList, allocator: std.mem.Allocator) void {
    for (lists) |*list| {
        list.deinit();
    }
    allocator.free(lists);
}
