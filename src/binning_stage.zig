//! # Binning Stage: Assigning Work to Tiles
//!
//! This module is responsible for the "binning" or "tiling" stage of the renderer.
//! Its job is to figure out which triangles fall into which screen-space tiles.
//! This is a crucial step for a tile-based renderer because it divides the main
//! rendering problem into many smaller, independent problems that can be solved in parallel.
//!
//! ## JavaScript Analogy
//!
//! Imagine you have a giant canvas (the screen) and a list of thousands of shapes to draw (triangles).
//! Instead of drawing them one by one, you first divide your canvas into a grid of smaller squares (tiles).
//!
//! The binning stage is like going through your list of shapes and creating a separate to-do list for each square.
//! For each shape, you ask: "Which square(s) does this shape touch?" If a circle overlaps with squares 4 and 5,
//! you add "draw circle" to the to-do lists for both square 4 and square 5.
//!
//! After binning, each square has a list of all the shapes it needs to draw, and it can be rendered
//! completely independently of its neighbors.

const std = @import("std");
const TileRenderer = @import("tile_renderer.zig");
const Tile = TileRenderer.Tile;
const TileGrid = TileRenderer.TileGrid;
const WorkTypes = @import("mesh_work_types.zig");
const TrianglePacket = WorkTypes.TrianglePacket;

// ========== TRIANGLE BOUNDS ==========

/// An axis-aligned bounding box (AABB) for a triangle in 2D screen space.
/// This is a simple rectangle that completely encloses the triangle.
pub const TriangleBounds = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    /// Calculates the 2D bounding box that encloses a triangle's three vertices.
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

    /// Checks if this bounding box overlaps with a given tile's bounding box.
    /// This is a classic AABB intersection test.
    pub fn overlapsTile(self: TriangleBounds, tile: *const Tile) bool {
        // Two rectangles overlap if it's NOT the case that one is entirely to the
        // left, right, above, or below the other.
        const no_overlap = self.max_x < tile.x or // Triangle is entirely to the left of the tile
            self.min_x >= tile.right() or // Triangle is entirely to the right of the tile
            self.max_y < tile.y or // Triangle is entirely above the tile
            self.min_y >= tile.bottom(); // Triangle is entirely below the tile

        return !no_overlap;
    }

    /// Checks if the bounding box is completely outside the screen bounds.
    /// This is a quick way to reject triangles that are not visible.
    pub fn isOffscreen(self: TriangleBounds, screen_width: i32, screen_height: i32) bool {
        return self.max_x < 0 or self.min_x >= screen_width or
            self.max_y < 0 or self.min_y >= screen_height;
    }
};

// ========== TILE TRIANGLE LIST ==========

/// A list of triangle indices assigned to a specific tile.
/// JS Analogy: `class TileToDoList { constructor() { this.triangles = []; } }`
pub const TileTriangleList = struct {
    // JS Analogy: `this.triangles = [/* triangle IDs */];`
    triangles: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    /// Initializes an empty list.
    pub fn init(allocator: std.mem.Allocator) TileTriangleList {
        return TileTriangleList{
            .triangles = std.ArrayList(usize){},
            .allocator = allocator,
        };
    }

    /// Adds a triangle's index to this tile's to-do list.
    /// JS Analogy: `this.triangles.push(triangle_index);`
    pub fn append(self: *TileTriangleList, triangle_index: usize) !void {
        try self.triangles.append(self.allocator, triangle_index);
    }

    /// Returns the number of triangles in the list.
    /// JS Analogy: `return this.triangles.length;`
    pub fn count(self: *const TileTriangleList) usize {
        return self.triangles.items.len;
    }

    /// Clears the list for the next frame, but keeps the allocated memory for reuse.
    /// JS Analogy: `this.triangles.length = 0;`
    pub fn clear(self: *TileTriangleList) void {
        self.triangles.clearRetainingCapacity();
    }

    /// Frees the memory used by the list.
    pub fn deinit(self: *TileTriangleList) void {
        self.triangles.deinit(self.allocator);
    }
};

// ========== BINNING FUNCTIONS ==========

/// The main binning function. It takes all triangles and assigns them to the tiles they overlap.
/// Returns an array of `TileTriangleList`, one for each tile on the screen.
pub fn binTrianglesToTiles(
    triangle_packets: []const TrianglePacket,
    grid: *const TileGrid,
    allocator: std.mem.Allocator,
) ![]TileTriangleList {
    // 1. Create an empty to-do list for each tile.
    const tile_lists = try allocator.alloc(TileTriangleList, grid.tiles.len);
    for (tile_lists) |*list| {
        list.* = TileTriangleList.init(allocator);
    }

    // 2. Loop through every triangle in the scene.
    for (triangle_packets, 0..) |packet, tri_idx| {
        const tri = packet.screen;
        const p0 = tri[0];
        const p1 = tri[1];
        const p2 = tri[2];

        // 3. Calculate the triangle's 2D screen-space bounding box.
        const bounds = TriangleBounds.fromVertices(p0, p1, p2);

        // 4. Quick rejection: if the triangle is completely off-screen, ignore it.
        if (bounds.isOffscreen(grid.screen_width, grid.screen_height)) {
            continue;
        }

        const screen_max_x = grid.screen_width - 1;
        const screen_max_y = grid.screen_height - 1;

        const clamped_min_x = std.math.clamp(bounds.min_x, 0, screen_max_x);
        const clamped_max_x = std.math.clamp(bounds.max_x, 0, screen_max_x);
        const clamped_min_y = std.math.clamp(bounds.min_y, 0, screen_max_y);
        const clamped_max_y = std.math.clamp(bounds.max_y, 0, screen_max_y);

        const min_col = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_min_x, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid.cols)) - 1)));
        const max_col = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_max_x, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid.cols)) - 1)));
        const min_row = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_min_y, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid.rows)) - 1)));
        const max_row = @as(usize, @intCast(std.math.clamp(@divTrunc(clamped_max_y, TileRenderer.TILE_SIZE), 0, @as(i32, @intCast(grid.rows)) - 1)));

        var row = min_row;
        while (row <= max_row) : (row += 1) {
            const base_idx = row * grid.cols;
            var col = min_col;
            while (col <= max_col) : (col += 1) {
                const tile_idx = base_idx + col;
                const tile_ptr = &grid.tiles[tile_idx];
                if (!bounds.overlapsTile(tile_ptr)) continue;
                // Store the mesh-work triangle index; later stages look up full data from that slot.
                try tile_lists[tile_idx].append(tri_idx);
            }
        }
    }

    // 7. Return the array of to-do lists.
    return tile_lists;
}

/// Frees the memory allocated for the tile-triangle lists.
pub fn freeTileTriangleLists(lists: []TileTriangleList, allocator: std.mem.Allocator) void {
    for (lists) |*list| {
        list.deinit();
    }
    allocator.free(lists);
}