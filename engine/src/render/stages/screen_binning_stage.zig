const std = @import("std");
const job_system = @import("job_system");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_draw_list = @import("../direct/draw_list.zig");
const direct_packets = @import("../direct/packets.zig");
const direct_primitives = @import("../direct/primitives.zig");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const TileRange = struct {
    start: usize = 0,
    len: usize = 0,
};

pub const TileSpan = struct {
    min_col: i32,
    max_col: i32,
    min_row: i32,
    max_row: i32,

    pub fn fromBounds(bounds: direct_primitives.Rect2i, tile_size: i32, cols: i32, rows: i32) TileSpan {
        return .{
            .min_col = clampTileCoord(divTile(bounds.min_x, tile_size), cols),
            .max_col = clampTileCoord(divTile(bounds.max_x, tile_size), cols),
            .min_row = clampTileCoord(divTile(bounds.min_y, tile_size), rows),
            .max_row = clampTileCoord(divTile(bounds.max_y, tile_size), rows),
        };
    }
};

pub const DirtyRect = struct {
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
    tile_spans: *std.ArrayListUnmanaged(?TileSpan),
    active_tile_indices: *std.ArrayListUnmanaged(usize),
    active_tile_command_counts: *std.ArrayListUnmanaged(usize),
) !Result {
    const tile_size = TileRenderer.TILE_SIZE;
    const cols = @max(@divTrunc(width + tile_size - 1, tile_size), 1);
    const rows = @max(@divTrunc(height + tile_size - 1, tile_size), 1);
    const tile_count: usize = @intCast(cols * rows);

    try tile_counts.resize(allocator, tile_count);
    try tile_cursors.resize(allocator, tile_count);
    try tile_ranges.resize(allocator, tile_count);
    try tile_spans.resize(allocator, draw_list.items().len);
    @memset(tile_counts.items, 0);

    for (draw_list.bounds(), tile_spans.items) |maybe_bounds, *maybe_span| {
        const bounds = maybe_bounds orelse {
            maybe_span.* = null;
            continue;
        };
        const span = TileSpan.fromBounds(bounds, tile_size, cols, rows);
        maybe_span.* = span;
        var row = span.min_row;
        while (row <= span.max_row) : (row += 1) {
            var col = span.min_col;
            while (col <= span.max_col) : (col += 1) {
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
    try active_tile_indices.resize(allocator, touchedTilesEstimate(tile_counts.items));
    try active_tile_command_counts.resize(allocator, active_tile_indices.items.len);
    var active_write_index: usize = 0;
    for (tile_counts.items, tile_ranges.items, 0..) |count, *range, tile_index| {
        range.* = .{ .start = total_refs, .len = count };
        total_refs += count;
        if (count != 0) {
            touched_tiles += 1;
            active_tile_indices.items[active_write_index] = tile_index;
            active_tile_command_counts.items[active_write_index] = count;
            active_write_index += 1;
            const row: i32 = @intCast(@divTrunc(@as(i32, @intCast(tile_index)), cols));
            const col: i32 = @intCast(@mod(@as(i32, @intCast(tile_index)), cols));
            min_touched_col = @min(min_touched_col, col);
            min_touched_row = @min(min_touched_row, row);
            max_touched_col = @max(max_touched_col, col);
            max_touched_row = @max(max_touched_row, row);
        }
    }
    active_tile_indices.items.len = touched_tiles;
    active_tile_command_counts.items.len = touched_tiles;
    try tile_command_indices.resize(allocator, total_refs);

    for (tile_counts.items, tile_ranges.items, tile_cursors.items) |*count, range, *cursor| {
        cursor.* = range.start;
        count.* = range.len;
    }

    for (tile_spans.items, 0..) |maybe_span, command_index| {
        const span = maybe_span orelse continue;
        var row = span.min_row;
        while (row <= span.max_row) : (row += 1) {
            var col = span.min_col;
            while (col <= span.max_col) : (col += 1) {
                const tile_index: usize = @intCast(row * cols + col);
                const write_index = tile_cursors.items[tile_index];
                tile_command_indices.items[write_index] = command_index;
                tile_cursors.items[tile_index] = write_index + 1;
            }
        }
    }

    if (!sortKeysAlreadyOrdered(draw_list.items())) {
        deterministicSortTileRefs(tile_command_indices.items, tile_ranges.items, draw_list.items());
    }

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

/// Parallel variant of `execute`. Splits the draw_list across worker
/// chunks via the two-pass histogram-scatter pattern:
///   1. Per-worker count pass: each chunk computes its own
///      tile_counts_local + tile_spans (no contention, no atomics).
///   2. Serial reduce + prefix sum: sum worker-local counts to global
///      counts, compute per-chunk per-tile offsets.
///   3. Per-worker scatter pass: each chunk writes its tile_command_
///      indices to its pre-computed offsets (no contention).
///   4. Optional parallel sort: one job per tile to sort its commands
///      by sort_key (each tile's slice is independent).
///
/// Memory scratch: chunk_count × tile_count × @sizeOf(usize). For 20
/// chunks × 252 tiles that's ~40 KB — allocated once via the caller's
/// allocator.
pub fn executeParallel(
    allocator: std.mem.Allocator,
    draw_list: *const direct_draw_list.DrawList,
    width: i32,
    height: i32,
    tile_counts: *std.ArrayListUnmanaged(usize),
    tile_cursors: *std.ArrayListUnmanaged(usize),
    tile_ranges: *std.ArrayListUnmanaged(TileRange),
    tile_command_indices: *std.ArrayListUnmanaged(usize),
    tile_spans: *std.ArrayListUnmanaged(?TileSpan),
    active_tile_indices: *std.ArrayListUnmanaged(usize),
    active_tile_command_counts: *std.ArrayListUnmanaged(usize),
    job_sys: ?*JobSystem,
) !Result {
    // Small inputs: skip parallel overhead.
    const PARALLEL_THRESHOLD: usize = 4096;
    const item_count = draw_list.items().len;
    if (job_sys == null or item_count < PARALLEL_THRESHOLD or job_sys.?.worker_count <= 1) {
        return execute(allocator, draw_list, width, height, tile_counts, tile_cursors, tile_ranges, tile_command_indices, tile_spans, active_tile_indices, active_tile_command_counts);
    }

    const tile_size = TileRenderer.TILE_SIZE;
    const cols = @max(@divTrunc(width + tile_size - 1, tile_size), 1);
    const rows = @max(@divTrunc(height + tile_size - 1, tile_size), 1);
    const tile_count: usize = @intCast(cols * rows);

    try tile_counts.resize(allocator, tile_count);
    try tile_cursors.resize(allocator, tile_count);
    try tile_ranges.resize(allocator, tile_count);
    try tile_spans.resize(allocator, item_count);
    @memset(tile_counts.items, 0);

    const js = job_sys.?;
    const worker_count = @as(usize, js.worker_count);
    const chunk_count = @min(@min(worker_count + 1, 32), item_count);

    // Per-worker tile_counts scratch (row-major: chunk_index × tile_count).
    const local_counts = try allocator.alloc(usize, chunk_count * tile_count);
    defer allocator.free(local_counts);
    @memset(local_counts, 0);

    // Per-worker per-tile starting offsets (computed from prefix sums).
    const local_offsets = try allocator.alloc(usize, chunk_count * tile_count);
    defer allocator.free(local_offsets);

    var contexts: [32]CountChunkCtx = undefined;
    var jobs: [32]Job = undefined;
    var parent_count = Job.init(noopBinningJob, @ptrFromInt(1), null);

    const base = item_count / chunk_count;
    const rem = item_count % chunk_count;
    var cursor: usize = 0;

    // === Pass 1: per-worker count + tile_span build ===
    for (0..chunk_count) |chunk_index| {
        const size = base + (if (chunk_index < rem) @as(usize, 1) else 0);
        const end = cursor + size;
        contexts[chunk_index] = .{
            .bounds = draw_list.bounds()[cursor..end],
            .spans_slice = tile_spans.items[cursor..end],
            .counts_local = local_counts[chunk_index * tile_count .. (chunk_index + 1) * tile_count],
            .tile_size = tile_size,
            .cols = cols,
            .rows = rows,
        };
        cursor = end;
    }
    var main_chunk: usize = 0;
    var dispatched: usize = 0;
    for (0..chunk_count) |chunk_index| {
        if (dispatched == 0) {
            main_chunk = chunk_index;
        } else {
            jobs[dispatched - 1] = Job.init(countChunkJob, @ptrCast(&contexts[chunk_index]), &parent_count);
            if (!js.submitJobWithClass(&jobs[dispatched - 1], .high)) {
                countChunkJob(@ptrCast(&contexts[chunk_index]));
            }
        }
        dispatched += 1;
    }
    countChunkJob(@ptrCast(&contexts[main_chunk]));
    parent_count.complete();
    js.waitFor(&parent_count);

    // === Reduce + prefix-sum: combine per-worker counts ===
    var total_refs: usize = 0;
    var touched_tiles: usize = 0;
    var min_touched_col: i32 = cols;
    var min_touched_row: i32 = rows;
    var max_touched_col: i32 = -1;
    var max_touched_row: i32 = -1;
    try active_tile_indices.resize(allocator, tile_count);
    try active_tile_command_counts.resize(allocator, tile_count);
    var active_write_index: usize = 0;
    for (0..tile_count) |tile_index| {
        var sum: usize = 0;
        // Per-chunk offset for this tile = running total within this
        // tile across the preceding chunks.
        var running: usize = 0;
        for (0..chunk_count) |chunk_index| {
            local_offsets[chunk_index * tile_count + tile_index] = total_refs + running;
            running += local_counts[chunk_index * tile_count + tile_index];
        }
        sum = running;
        tile_counts.items[tile_index] = sum;
        tile_ranges.items[tile_index] = .{ .start = total_refs, .len = sum };
        total_refs += sum;
        if (sum != 0) {
            touched_tiles += 1;
            active_tile_indices.items[active_write_index] = tile_index;
            active_tile_command_counts.items[active_write_index] = sum;
            active_write_index += 1;
            const row: i32 = @intCast(@divTrunc(@as(i32, @intCast(tile_index)), cols));
            const col: i32 = @intCast(@mod(@as(i32, @intCast(tile_index)), cols));
            min_touched_col = @min(min_touched_col, col);
            min_touched_row = @min(min_touched_row, row);
            max_touched_col = @max(max_touched_col, col);
            max_touched_row = @max(max_touched_row, row);
        }
    }
    active_tile_indices.items.len = touched_tiles;
    active_tile_command_counts.items.len = touched_tiles;
    try tile_command_indices.resize(allocator, total_refs);

    // === Pass 2: per-worker scatter writes ===
    var scatter_contexts: [32]ScatterChunkCtx = undefined;
    var scatter_jobs: [32]Job = undefined;
    var parent_scatter = Job.init(noopBinningJob, @ptrFromInt(1), null);
    cursor = 0;
    for (0..chunk_count) |chunk_index| {
        const size = base + (if (chunk_index < rem) @as(usize, 1) else 0);
        const end = cursor + size;
        scatter_contexts[chunk_index] = .{
            .spans_slice = tile_spans.items[cursor..end],
            .command_index_base = cursor,
            .offsets_local = local_offsets[chunk_index * tile_count .. (chunk_index + 1) * tile_count],
            .out_indices = tile_command_indices.items,
            .cols = cols,
        };
        cursor = end;
    }
    dispatched = 0;
    main_chunk = 0;
    for (0..chunk_count) |chunk_index| {
        if (dispatched == 0) {
            main_chunk = chunk_index;
        } else {
            scatter_jobs[dispatched - 1] = Job.init(scatterChunkJob, @ptrCast(&scatter_contexts[chunk_index]), &parent_scatter);
            if (!js.submitJobWithClass(&scatter_jobs[dispatched - 1], .high)) {
                scatterChunkJob(@ptrCast(&scatter_contexts[chunk_index]));
            }
        }
        dispatched += 1;
    }
    scatterChunkJob(@ptrCast(&scatter_contexts[main_chunk]));
    parent_scatter.complete();
    js.waitFor(&parent_scatter);

    // === Optional sort (per-tile, naturally parallel) ===
    if (!sortKeysAlreadyOrdered(draw_list.items())) {
        sortTileRefsParallel(tile_command_indices.items, tile_ranges.items, draw_list.items(), js);
    }

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

const CountChunkCtx = struct {
    bounds: []const ?direct_primitives.Rect2i align(64),
    spans_slice: []?TileSpan,
    counts_local: []usize,
    tile_size: i32,
    cols: i32,
    rows: i32,
};

fn countChunkJob(ctx_ptr: *anyopaque) void {
    const ctx: *CountChunkCtx = @ptrCast(@alignCast(ctx_ptr));
    for (ctx.bounds, ctx.spans_slice) |maybe_bounds, *maybe_span| {
        const bounds = maybe_bounds orelse {
            maybe_span.* = null;
            continue;
        };
        const span = TileSpan.fromBounds(bounds, ctx.tile_size, ctx.cols, ctx.rows);
        maybe_span.* = span;
        var row = span.min_row;
        while (row <= span.max_row) : (row += 1) {
            var col = span.min_col;
            while (col <= span.max_col) : (col += 1) {
                const tile_index: usize = @intCast(row * ctx.cols + col);
                ctx.counts_local[tile_index] += 1;
            }
        }
    }
}

const ScatterChunkCtx = struct {
    spans_slice: []const ?TileSpan align(64),
    command_index_base: usize,
    offsets_local: []usize,
    out_indices: []usize,
    cols: i32,
};

fn scatterChunkJob(ctx_ptr: *anyopaque) void {
    const ctx: *ScatterChunkCtx = @ptrCast(@alignCast(ctx_ptr));
    for (ctx.spans_slice, 0..) |maybe_span, local_idx| {
        const span = maybe_span orelse continue;
        const command_index = ctx.command_index_base + local_idx;
        var row = span.min_row;
        while (row <= span.max_row) : (row += 1) {
            var col = span.min_col;
            while (col <= span.max_col) : (col += 1) {
                const tile_index: usize = @intCast(row * ctx.cols + col);
                const write_index = ctx.offsets_local[tile_index];
                ctx.out_indices[write_index] = command_index;
                ctx.offsets_local[tile_index] = write_index + 1;
            }
        }
    }
}

fn noopBinningJob(_: *anyopaque) void {}

/// Parallel per-tile sort dispatch. Each tile's command-ref slice is
/// independent so we get one job per tile (capped at a sensible batch
/// size so we don't spam tiny jobs). For acura/wolf this is also
/// effectively skipped because sort_keys are pre-ordered.
fn sortTileRefsParallel(
    refs: []usize,
    ranges: []const TileRange,
    commands: []const direct_packets.DrawPacket,
    js: *JobSystem,
) void {
    const TILES_PER_JOB: usize = 8;
    const max_jobs: usize = 64;
    var contexts: [max_jobs]SortChunkCtx = undefined;
    var jobs: [max_jobs]Job = undefined;
    var parent = Job.init(noopBinningJob, @ptrFromInt(1), null);
    var main_chunk: ?usize = null;
    var job_idx: usize = 0;
    var tile_start: usize = 0;
    while (tile_start < ranges.len and job_idx < max_jobs) {
        const tile_end = @min(tile_start + TILES_PER_JOB, ranges.len);
        contexts[job_idx] = .{
            .refs = refs,
            .ranges = ranges[tile_start..tile_end],
            .commands = commands,
        };
        if (main_chunk == null) {
            main_chunk = job_idx;
        } else {
            jobs[job_idx - 1] = Job.init(sortChunkJob, @ptrCast(&contexts[job_idx]), &parent);
            if (!js.submitJobWithClass(&jobs[job_idx - 1], .high)) {
                sortChunkJob(@ptrCast(&contexts[job_idx]));
            }
        }
        job_idx += 1;
        tile_start = tile_end;
    }
    // Handle any remaining tiles past the job cap on the main thread.
    if (tile_start < ranges.len) {
        deterministicSortTileRefs(refs, ranges[tile_start..], commands);
    }
    if (main_chunk) |idx| sortChunkJob(@ptrCast(&contexts[idx]));
    parent.complete();
    js.waitFor(&parent);
}

const SortChunkCtx = struct {
    refs: []usize align(64),
    ranges: []const TileRange,
    commands: []const direct_packets.DrawPacket,
};

fn sortChunkJob(ctx_ptr: *anyopaque) void {
    const ctx: *SortChunkCtx = @ptrCast(@alignCast(ctx_ptr));
    deterministicSortTileRefs(ctx.refs, ctx.ranges, ctx.commands);
}

fn clampTileCoord(value: i32, axis_count: i32) i32 {
    return std.math.clamp(value, 0, axis_count - 1);
}

fn divTile(value: i32, tile_size: i32) i32 {
    const shift = comptime std.math.log2_int(u32, TileRenderer.TILE_SIZE);
    if (comptime std.math.isPowerOfTwo(TileRenderer.TILE_SIZE)) {
        return value >> shift;
    }
    return @divTrunc(value, tile_size);
}

fn deterministicSortTileRefs(
    refs: []usize,
    ranges: []const TileRange,
    commands: []const direct_packets.DrawPacket,
) void {
    const insertion_threshold = 16;
    for (ranges) |range| {
        if (range.len <= 1) continue;
        const slice = refs[range.start .. range.start + range.len];
        if (range.len <= insertion_threshold) {
            std.sort.insertion(usize, slice, commands, lessThanCommandRef);
        } else {
            std.sort.block(usize, slice, commands, lessThanCommandRef);
        }
    }
}

fn touchedTilesEstimate(counts: []const usize) usize {
    var total: usize = 0;
    for (counts) |count| {
        if (count != 0) total += 1;
    }
    return total;
}

fn sortKeysAlreadyOrdered(commands: []const direct_packets.DrawPacket) bool {
    if (commands.len <= 1) return true;
    var previous = commands[0].sort_key;
    for (commands[1..]) |command| {
        if (command.sort_key < previous) return false;
        previous = command.sort_key;
    }
    return true;
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
    var tile_spans: std.ArrayListUnmanaged(?TileSpan) = .{};
    defer tile_spans.deinit(std.testing.allocator);
    var active_tile_indices: std.ArrayListUnmanaged(usize) = .{};
    defer active_tile_indices.deinit(std.testing.allocator);
    var active_tile_command_counts: std.ArrayListUnmanaged(usize) = .{};
    defer active_tile_command_counts.deinit(std.testing.allocator);

    const first = try execute(
        std.testing.allocator,
        &draw_list,
        160,
        90,
        &tile_counts,
        &tile_cursors,
        &tile_ranges,
        &tile_command_indices,
        &tile_spans,
        &active_tile_indices,
        &active_tile_command_counts,
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
        &tile_spans,
        &active_tile_indices,
        &active_tile_command_counts,
    );

    try std.testing.expect(first.touched_tiles > 0);
    try std.testing.expect(first.dirty_rect != null);
    try std.testing.expectEqual(first.tile_count, second.tile_count);
    try std.testing.expectEqualSlices(usize, first_refs, tile_command_indices.items);
    try std.testing.expectEqualSlices(TileRange, first_ranges, tile_ranges.items);
    try std.testing.expectEqual(first.touched_tiles, active_tile_indices.items.len);
}
