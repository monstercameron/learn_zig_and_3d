const std = @import("std");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_draw_list = @import("../direct_draw_list.zig");
const direct_packets = @import("../direct_packets.zig");
const direct_primitives = @import("../direct_primitives.zig");

pub const TileRange = struct {
    start: usize = 0,
    len: usize = 0,
};

pub const DirtyRect = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
};

const Rect2i = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
};

pub const Result = struct {
    tile_cols: i32,
    tile_rows: i32,
    tile_count: usize,
    touched_tiles: usize,
    dirty_rect: ?DirtyRect,
};

pub fn execute(
    allocator: std.mem.Allocator,
    draw_list: *const direct_draw_list.DrawList,
    width: i32,
    height: i32,
    tile_counts: *std.ArrayListUnmanaged(usize),
    tile_cursors: *std.ArrayListUnmanaged(usize),
    tile_ranges: *std.ArrayListUnmanaged(TileRange),
    tile_command_indices: *std.ArrayListUnmanaged(usize),
) !Result {
    const tile_size = TileRenderer.TILE_SIZE;
    const cols = @max(@divTrunc(width + tile_size - 1, tile_size), 1);
    const rows = @max(@divTrunc(height + tile_size - 1, tile_size), 1);
    const tile_count: usize = @intCast(cols * rows);

    try tile_counts.resize(allocator, tile_count);
    try tile_cursors.resize(allocator, tile_count);
    try tile_ranges.resize(allocator, tile_count);
    @memset(tile_counts.items, 0);

    for (draw_list.items()) |command| {
        const bounds = commandBounds(command) orelse continue;
        const min_col = clampTileCoord(@divTrunc(bounds.min_x, tile_size), cols);
        const max_col = clampTileCoord(@divTrunc(bounds.max_x, tile_size), cols);
        const min_row = clampTileCoord(@divTrunc(bounds.min_y, tile_size), rows);
        const max_row = clampTileCoord(@divTrunc(bounds.max_y, tile_size), rows);
        var row = min_row;
        while (row <= max_row) : (row += 1) {
            var col = min_col;
            while (col <= max_col) : (col += 1) {
                const tile_index: usize = @intCast(row * cols + col);
                tile_counts.items[tile_index] += 1;
            }
        }
    }

    var total_refs: usize = 0;
    var touched_tiles: usize = 0;
    var min_touched_col: i32 = cols;
    var min_touched_row: i32 = rows;
    var max_touched_col: i32 = -1;
    var max_touched_row: i32 = -1;
    for (tile_counts.items, tile_ranges.items, 0..) |count, *range, tile_index| {
        range.* = .{ .start = total_refs, .len = count };
        total_refs += count;
        if (count != 0) {
            touched_tiles += 1;
            const row: i32 = @intCast(@divTrunc(@as(i32, @intCast(tile_index)), cols));
            const col: i32 = @intCast(@mod(@as(i32, @intCast(tile_index)), cols));
            min_touched_col = @min(min_touched_col, col);
            min_touched_row = @min(min_touched_row, row);
            max_touched_col = @max(max_touched_col, col);
            max_touched_row = @max(max_touched_row, row);
        }
    }
    try tile_command_indices.resize(allocator, total_refs);

    for (tile_counts.items, tile_ranges.items, tile_cursors.items) |*count, range, *cursor| {
        cursor.* = range.start;
        count.* = range.len;
    }

    for (draw_list.items(), 0..) |command, command_index| {
        const bounds = commandBounds(command) orelse continue;
        const min_col = clampTileCoord(@divTrunc(bounds.min_x, tile_size), cols);
        const max_col = clampTileCoord(@divTrunc(bounds.max_x, tile_size), cols);
        const min_row = clampTileCoord(@divTrunc(bounds.min_y, tile_size), rows);
        const max_row = clampTileCoord(@divTrunc(bounds.max_y, tile_size), rows);
        var row = min_row;
        while (row <= max_row) : (row += 1) {
            var col = min_col;
            while (col <= max_col) : (col += 1) {
                const tile_index: usize = @intCast(row * cols + col);
                const write_index = tile_cursors.items[tile_index];
                tile_command_indices.items[write_index] = command_index;
                tile_cursors.items[tile_index] = write_index + 1;
            }
        }
    }

    deterministicSortTileRefs(tile_command_indices.items, tile_ranges.items, draw_list.items());

    const dirty_rect = if (touched_tiles == 0)
        null
    else
        DirtyRect{
            .min_x = min_touched_col * tile_size,
            .min_y = min_touched_row * tile_size,
            .max_x = @min((max_touched_col + 1) * tile_size - 1, width - 1),
            .max_y = @min((max_touched_row + 1) * tile_size - 1, height - 1),
        };

    return .{
        .tile_cols = cols,
        .tile_rows = rows,
        .tile_count = tile_count,
        .touched_tiles = touched_tiles,
        .dirty_rect = dirty_rect,
    };
}

fn clampTileCoord(value: i32, axis_count: i32) i32 {
    return std.math.clamp(value, 0, axis_count - 1);
}

fn commandBounds(packet: direct_packets.DrawPacket) ?Rect2i {
    return switch (packet.payload) {
        .line => |line| .{
            .min_x = @min(line.start.x, line.end.x),
            .min_y = @min(line.start.y, line.end.y),
            .max_x = @max(line.start.x, line.end.x),
            .max_y = @max(line.start.y, line.end.y),
        },
        .triangle => |triangle| .{
            .min_x = @min(triangle.a.x, @min(triangle.b.x, triangle.c.x)),
            .min_y = @min(triangle.a.y, @min(triangle.b.y, triangle.c.y)),
            .max_x = @max(triangle.a.x, @max(triangle.b.x, triangle.c.x)),
            .max_y = @max(triangle.a.y, @max(triangle.b.y, triangle.c.y)),
        },
        .polygon => |polygon| polygonBounds(polygon.points),
        .circle => |circle| .{
            .min_x = circle.center.x - circle.radius,
            .min_y = circle.center.y - circle.radius,
            .max_x = circle.center.x + circle.radius,
            .max_y = circle.center.y + circle.radius,
        },
    };
}

fn polygonBounds(points: []const direct_primitives.Point2i) ?Rect2i {
    if (points.len == 0) return null;
    var bounds = Rect2i{
        .min_x = points[0].x,
        .min_y = points[0].y,
        .max_x = points[0].x,
        .max_y = points[0].y,
    };
    for (points[1..]) |point| {
        bounds.min_x = @min(bounds.min_x, point.x);
        bounds.min_y = @min(bounds.min_y, point.y);
        bounds.max_x = @max(bounds.max_x, point.x);
        bounds.max_y = @max(bounds.max_y, point.y);
    }
    return bounds;
}

fn deterministicSortTileRefs(
    refs: []usize,
    ranges: []const TileRange,
    commands: []const direct_packets.DrawPacket,
) void {
    for (ranges) |range| {
        if (range.len <= 1) continue;
        std.sort.insertion(usize, refs[range.start .. range.start + range.len], commands, lessThanCommandRef);
    }
}

fn lessThanCommandRef(commands: []const direct_packets.DrawPacket, lhs: usize, rhs: usize) bool {
    const lhs_key = commands[lhs].sort_key;
    const rhs_key = commands[rhs].sort_key;
    if (lhs_key == rhs_key) return lhs < rhs;
    return lhs_key < rhs_key;
}

test "screen binning stage emits deterministic tile refs" {
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try draw_list.appendTriangle(.{
        .a = .{ .x = 20, .y = 20 },
        .b = .{ .x = 90, .y = 24 },
        .c = .{ .x = 42, .y = 88 },
    }, .{ .fill_color = 0xFFFFFFFF, .depth = 0.2 });
    try draw_list.appendCircle(.{
        .center = .{ .x = 100, .y = 60 },
        .radius = 18,
    }, .{ .fill_color = 0xFF00FF00, .depth = 0.4 });

    var tile_counts: std.ArrayListUnmanaged(usize) = .{};
    defer tile_counts.deinit(std.testing.allocator);
    var tile_cursors: std.ArrayListUnmanaged(usize) = .{};
    defer tile_cursors.deinit(std.testing.allocator);
    var tile_ranges: std.ArrayListUnmanaged(TileRange) = .{};
    defer tile_ranges.deinit(std.testing.allocator);
    var tile_command_indices: std.ArrayListUnmanaged(usize) = .{};
    defer tile_command_indices.deinit(std.testing.allocator);

    const first = try execute(
        std.testing.allocator,
        &draw_list,
        160,
        90,
        &tile_counts,
        &tile_cursors,
        &tile_ranges,
        &tile_command_indices,
    );
    const first_refs = try std.testing.allocator.dupe(usize, tile_command_indices.items);
    defer std.testing.allocator.free(first_refs);
    const first_ranges = try std.testing.allocator.dupe(TileRange, tile_ranges.items);
    defer std.testing.allocator.free(first_ranges);

    const second = try execute(
        std.testing.allocator,
        &draw_list,
        160,
        90,
        &tile_counts,
        &tile_cursors,
        &tile_ranges,
        &tile_command_indices,
    );

    try std.testing.expect(first.touched_tiles > 0);
    try std.testing.expect(first.dirty_rect != null);
    try std.testing.expectEqual(first.tile_count, second.tile_count);
    try std.testing.expectEqualSlices(usize, first_refs, tile_command_indices.items);
    try std.testing.expectEqualSlices(TileRange, first_ranges, tile_ranges.items);
}
