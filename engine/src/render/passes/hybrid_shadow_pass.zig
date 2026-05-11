//! Orchestrates the hybrid shadow pipeline for meshlet-era CPU shadows.
//! Builds receiver bounds and candidate casters, then dispatches adaptive tile work/ray checks.
//! Outputs shadow coverage that is consumed by adaptive shadow resolve/composite stages.


const std = @import("std");
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const hybrid_shadow_cache_kernel = @import("../kernels/hybrid_shadow_cache_kernel.zig");
const hybrid_shadow_candidate_kernel = @import("../kernels/hybrid_shadow_candidate_kernel.zig");
const render_utils = @import("../core/utils.zig");

const ReceiverBounds = struct {
    valid_min_x: i32,
    valid_min_y: i32,
    valid_max_x: i32,
    valid_max_y: i32,
    min_u: f32,
    max_u: f32,
    min_v: f32,
    max_v: f32,
    min_depth: f32,
};

/// Runs this module step with the currently bound configuration.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn run(
    ctx: anytype,
    comptime run_fn: fn (@TypeOf(ctx)) void,
) void {
    run_fn(ctx);
}

/// Ensures e ns ur es cr at ch and grows backing storage/state when needed.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn ensureScratch(self: anytype, caster_capacity: usize, tile_candidate_capacity: usize, grid_candidate_capacity: usize) !void {
    if (caster_capacity > self.hybrid_shadow_caster_indices.len) {
        self.hybrid_shadow_caster_indices = if (self.hybrid_shadow_caster_indices.len == 0)
            try self.allocator.alloc(usize, caster_capacity)
        else
            try self.allocator.realloc(self.hybrid_shadow_caster_indices, caster_capacity);
    }

    if (caster_capacity > self.hybrid_shadow_caster_bounds.len) {
        self.hybrid_shadow_caster_bounds = if (self.hybrid_shadow_caster_bounds.len == 0)
            try self.allocator.alloc(@TypeOf(self.hybrid_shadow_caster_bounds[0]), caster_capacity)
        else
            try self.allocator.realloc(self.hybrid_shadow_caster_bounds, caster_capacity);
    }

    if (caster_capacity > self.hybrid_shadow_candidate_marks.len) {
        self.hybrid_shadow_candidate_marks = if (self.hybrid_shadow_candidate_marks.len == 0)
            try self.allocator.alloc(u32, caster_capacity)
        else
            try self.allocator.realloc(self.hybrid_shadow_candidate_marks, caster_capacity);
        @memset(self.hybrid_shadow_candidate_marks, 0);
        self.hybrid_shadow_candidate_mark_generation = 0;
    }

    if (tile_candidate_capacity > self.hybrid_shadow_tile_candidates.len) {
        self.hybrid_shadow_tile_candidates = if (self.hybrid_shadow_tile_candidates.len == 0)
            try self.allocator.alloc(usize, tile_candidate_capacity)
        else
            try self.allocator.realloc(self.hybrid_shadow_tile_candidates, tile_candidate_capacity);
    }

    if (grid_candidate_capacity > self.hybrid_shadow_grid_candidates.len) {
        self.hybrid_shadow_grid_candidates = if (self.hybrid_shadow_grid_candidates.len == 0)
            try self.allocator.alloc(usize, grid_candidate_capacity)
        else
            try self.allocator.realloc(self.hybrid_shadow_grid_candidates, grid_candidate_capacity);
    }
}

fn nextCandidateMark(self: anytype) u32 {
    self.hybrid_shadow_candidate_mark_generation = hybrid_shadow_candidate_kernel.nextMark(
        self.hybrid_shadow_candidate_mark_generation,
        self.hybrid_shadow_candidate_marks,
    );
    return self.hybrid_shadow_candidate_mark_generation;
}

fn collectTileCandidates(self: anytype, receiver_bounds: anytype, candidate_write: *usize) @TypeOf(self.hybrid_shadow_stats) {
    var stats: @TypeOf(self.hybrid_shadow_stats) = .{};
    if (!self.hybrid_shadow_grid.active or self.hybrid_shadow_caster_count == 0) return stats;

    const grid = self.hybrid_shadow_grid;
    const mark = nextCandidateMark(self);
    if (mark == 0) return stats;

    const hybrid_shadow_grid_dim: usize = 32;
    const min_cell_x = std.math.clamp(
        @as(i32, @intFromFloat(@floor((receiver_bounds.min_u - grid.min_u) * grid.inv_cell_u))),
        0,
        @as(i32, @intCast(hybrid_shadow_grid_dim - 1)),
    );
    const max_cell_x = std.math.clamp(
        @as(i32, @intFromFloat(@floor((receiver_bounds.max_u - grid.min_u) * grid.inv_cell_u))),
        0,
        @as(i32, @intCast(hybrid_shadow_grid_dim - 1)),
    );
    const min_cell_y = std.math.clamp(
        @as(i32, @intFromFloat(@floor((receiver_bounds.min_v - grid.min_v) * grid.inv_cell_v))),
        0,
        @as(i32, @intCast(hybrid_shadow_grid_dim - 1)),
    );
    const max_cell_y = std.math.clamp(
        @as(i32, @intFromFloat(@floor((receiver_bounds.max_v - grid.min_v) * grid.inv_cell_v))),
        0,
        @as(i32, @intCast(hybrid_shadow_grid_dim - 1)),
    );

    var cell_y = min_cell_y;
    while (cell_y <= max_cell_y) : (cell_y += 1) {
        var cell_x = min_cell_x;
        while (cell_x <= max_cell_x) : (cell_x += 1) {
            const cell_index = @as(usize, @intCast(cell_y)) * hybrid_shadow_grid_dim + @as(usize, @intCast(cell_x));
            const cell_range = self.hybrid_shadow_grid_ranges[cell_index];
            if (cell_range.count == 0) continue;

            const caster_indices = self.hybrid_shadow_grid_candidates[cell_range.offset .. cell_range.offset + cell_range.count];
            stats.grid_candidate_count += caster_indices.len;
            for (caster_indices) |caster_index| {
                if (caster_index >= self.hybrid_shadow_caster_count) continue;
                if (self.hybrid_shadow_candidate_marks[caster_index] == mark) continue;
                self.hybrid_shadow_candidate_marks[caster_index] = mark;
                stats.unique_candidate_count += 1;

                const caster = self.hybrid_shadow_caster_bounds[caster_index];
                if (caster.max_depth <= receiver_bounds.min_depth + config.POST_HYBRID_SHADOW_RAY_BIAS) continue;
                if (caster.max_u < receiver_bounds.min_u or caster.min_u > receiver_bounds.max_u) continue;
                if (caster.max_v < receiver_bounds.min_v or caster.min_v > receiver_bounds.max_v) continue;

                self.hybrid_shadow_tile_candidates[candidate_write.*] = caster_index;
                candidate_write.* += 1;
                stats.final_candidate_count += 1;
            }
        }
    }
    return stats;
}

/// buildReceiverBounds builds data structures used by Hybrid Shadow Pass.
fn buildReceiverBounds(self: anytype, tile: anytype, camera_to_light: anytype) ?ReceiverBounds {
    const tile_min_x = std.math.clamp(tile.x, 0, self.bitmap.width - 1);
    const tile_min_y = std.math.clamp(tile.y, 0, self.bitmap.height - 1);
    const tile_max_x = std.math.clamp(tile.x + tile.width - 1, 0, self.bitmap.width - 1);
    const tile_max_y = std.math.clamp(tile.y + tile.height - 1, 0, self.bitmap.height - 1);
    const sample_stride = @max(1, config.POST_HYBRID_SHADOW_EDGE_DOWNSAMPLE);
    var min_u = std.math.inf(f32);
    var max_u = -std.math.inf(f32);
    var min_v = std.math.inf(f32);
    var max_v = -std.math.inf(f32);
    var min_depth = std.math.inf(f32);
    var found_valid = false;

    var screen_y = tile_min_y;
    while (screen_y <= tile_max_y) {
        const row_base = @as(usize, @intCast(screen_y * self.bitmap.width));
        var screen_x = tile_min_x;
        while (screen_x <= tile_max_x) {
            const idx = row_base + @as(usize, @intCast(screen_x));
            const camera_pos = self.scene_camera[idx];
            if (std.math.isFinite(camera_pos.z) and camera_pos.z > 0.01) {
                const light_sample = camera_to_light.project(camera_pos);
                found_valid = true;
                if (light_sample.u < min_u) min_u = light_sample.u;
                if (light_sample.u > max_u) max_u = light_sample.u;
                if (light_sample.v < min_v) min_v = light_sample.v;
                if (light_sample.v > max_v) max_v = light_sample.v;
                if (light_sample.depth < min_depth) min_depth = light_sample.depth;
            }

            if (screen_x == tile_max_x) break;
            screen_x = @min(tile_max_x, screen_x + sample_stride);
        }
        if (screen_y == tile_max_y) break;
        screen_y = @min(tile_max_y, screen_y + sample_stride);
    }

    if (!found_valid) return null;
    return .{
        .valid_min_x = tile_min_x,
        .valid_min_y = tile_min_y,
        .valid_max_x = tile_max_x,
        .valid_max_y = tile_max_y,
        .min_u = min_u,
        .max_u = max_u,
        .min_v = min_v,
        .max_v = max_v,
        .min_depth = min_depth,
    };
}

/// buildGrid builds data structures used by Hybrid Shadow Pass.
fn buildGrid(self: anytype, caster_count: usize, light_basis_right: math.Vec3, light_basis_up: math.Vec3) void {
    if (caster_count == 0) {
        self.hybrid_shadow_grid.active = false;
        return;
    }

    const hybrid_shadow_grid_dim: usize = 32;
    const hybrid_shadow_grid_cells = hybrid_shadow_grid_dim * hybrid_shadow_grid_dim;

    var min_u = std.math.inf(f32);
    var max_u = -std.math.inf(f32);
    var min_v = std.math.inf(f32);
    var max_v = -std.math.inf(f32);
    for (self.hybrid_shadow_caster_bounds[0..caster_count]) |caster| {
        if (caster.min_u < min_u) min_u = caster.min_u;
        if (caster.max_u > max_u) max_u = caster.max_u;
        if (caster.min_v < min_v) min_v = caster.min_v;
        if (caster.max_v > max_v) max_v = caster.max_v;
    }

    const extent_u = @max(1e-3, max_u - min_u);
    const extent_v = @max(1e-3, max_v - min_v);
    self.hybrid_shadow_grid = .{
        .basis_right = light_basis_right,
        .basis_up = light_basis_up,
        .min_u = min_u,
        .max_u = max_u,
        .min_v = min_v,
        .max_v = max_v,
        .inv_cell_u = @as(f32, @floatFromInt(hybrid_shadow_grid_dim)) / extent_u,
        .inv_cell_v = @as(f32, @floatFromInt(hybrid_shadow_grid_dim)) / extent_v,
        .active = true,
    };

    const counts = self.allocator.alloc(usize, hybrid_shadow_grid_cells) catch return;
    defer self.allocator.free(counts);
    @memset(counts, 0);
    for (self.hybrid_shadow_caster_bounds[0..caster_count]) |caster| {
        const min_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));
        const max_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));
        const min_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));
        const max_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));

        var cell_y = min_cell_y;
        while (cell_y <= max_cell_y) : (cell_y += 1) {
            var cell_x = min_cell_x;
            while (cell_x <= max_cell_x) : (cell_x += 1) {
                const cell_index = @as(usize, @intCast(cell_y)) * hybrid_shadow_grid_dim + @as(usize, @intCast(cell_x));
                counts[cell_index] += 1;
            }
        }
    }

    var offset: usize = 0;
    for (&self.hybrid_shadow_grid_ranges, 0..) |*range, cell_index| {
        range.offset = offset;
        range.count = counts[cell_index];
        offset += counts[cell_index];
    }

    const write_offsets = self.allocator.alloc(usize, hybrid_shadow_grid_cells) catch return;
    defer self.allocator.free(write_offsets);
    @memset(write_offsets, 0);
    for (self.hybrid_shadow_caster_bounds[0..caster_count], 0..) |caster, caster_index| {
        const min_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));
        const max_cell_x = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_u - min_u) * self.hybrid_shadow_grid.inv_cell_u))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));
        const min_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.min_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));
        const max_cell_y = std.math.clamp(@as(i32, @intFromFloat(@floor((caster.max_v - min_v) * self.hybrid_shadow_grid.inv_cell_v))), 0, @as(i32, @intCast(hybrid_shadow_grid_dim - 1)));

        var cell_y = min_cell_y;
        while (cell_y <= max_cell_y) : (cell_y += 1) {
            var cell_x = min_cell_x;
            while (cell_x <= max_cell_x) : (cell_x += 1) {
                const cell_index = @as(usize, @intCast(cell_y)) * hybrid_shadow_grid_dim + @as(usize, @intCast(cell_x));
                const write_index = self.hybrid_shadow_grid_ranges[cell_index].offset + write_offsets[cell_index];
                self.hybrid_shadow_grid_candidates[write_index] = caster_index;
                write_offsets[cell_index] += 1;
            }
        }
    }
}

/// runPipeline executes the full Hybrid Shadow Pass pipeline for the current frame.
pub fn runPipeline(
    self: anytype,
    mesh: anytype,
    grid: anytype,
    active_flags: []const bool,
    active_indices: []usize,
    shadow_jobs: anytype,
    tile_ranges: anytype,
    jobs: anytype,
    camera_position: math.Vec3,
    basis_right: math.Vec3,
    basis_up: math.Vec3,
    basis_forward: math.Vec3,
    normalized_light_dir: math.Vec3,
    light_basis_right: math.Vec3,
    light_basis_up: math.Vec3,
    camera_to_light: anytype,
    darkness_scale: f32,
    pass_start: i128,
    rebuild_dot_threshold: f32,
    comptime noop_job_fn: fn (*anyopaque) void,
) void {
    var accel_elapsed_ns: i128 = 0;
    var active_tile_capacity: usize = 0;
    for (grid.tiles, 0..) |_, tile_index| {
        if (tile_index < active_flags.len and active_flags[tile_index]) active_tile_capacity += 1;
    }

    if (active_tile_capacity == 0 or mesh.meshlets.len == 0) return;
    ensureScratch(
        self,
        mesh.meshlets.len,
        active_tile_capacity * mesh.meshlets.len,
        mesh.meshlets.len * self.hybrid_shadow_grid_ranges.len,
    ) catch {
        return;
    };

    const accel_needs_rebuild = !self.hybrid_shadow_accel_valid or
        self.hybrid_shadow_cached_meshlet_count != mesh.meshlets.len or
        self.hybrid_shadow_cached_meshlet_vertex_count != mesh.meshlet_vertices.len or
        self.hybrid_shadow_cached_meshlet_primitive_count != mesh.meshlet_primitives.len or
        math.Vec3.dot(self.hybrid_shadow_cached_light_dir, normalized_light_dir) < rebuild_dot_threshold;

    if (accel_needs_rebuild) {
        const accel_start = std.time.nanoTimestamp();
        var caster_count: usize = 0;
        for (mesh.meshlets, 0..) |meshlet, meshlet_index| {
            if (meshlet.primitive_count == 0 or meshlet.bounds_radius <= 0.0) continue;
            const center_u = math.Vec3.dot(meshlet.bounds_center, light_basis_right);
            const center_v = math.Vec3.dot(meshlet.bounds_center, light_basis_up);
            const center_depth = math.Vec3.dot(meshlet.bounds_center, normalized_light_dir);

            self.hybrid_shadow_caster_indices[caster_count] = meshlet_index;
            self.hybrid_shadow_caster_bounds[caster_count] = .{
                .meshlet_index = meshlet_index,
                .min_u = center_u - meshlet.bounds_radius,
                .max_u = center_u + meshlet.bounds_radius,
                .min_v = center_v - meshlet.bounds_radius,
                .max_v = center_v + meshlet.bounds_radius,
                .max_depth = center_depth + meshlet.bounds_radius,
            };
            caster_count += 1;
        }
        self.hybrid_shadow_caster_count = caster_count;
        self.hybrid_shadow_cached_light_dir = normalized_light_dir;
        self.hybrid_shadow_cached_meshlet_count = mesh.meshlets.len;
        self.hybrid_shadow_cached_meshlet_vertex_count = mesh.meshlet_vertices.len;
        self.hybrid_shadow_cached_meshlet_primitive_count = mesh.meshlet_primitives.len;
        self.hybrid_shadow_accel_valid = caster_count != 0;
        if (caster_count == 0) return;
        buildGrid(self, caster_count, light_basis_right, light_basis_up);
        accel_elapsed_ns = std.time.nanoTimestamp() - accel_start;
    }

    const caster_count = self.hybrid_shadow_caster_count;
    if (caster_count == 0) return;

    const candidate_start = std.time.nanoTimestamp();
    var candidate_write: usize = 0;
    var shadow_job_count: usize = 0;
    for (grid.tiles, 0..) |*tile, tile_index| {
        tile_ranges[tile_index] = .{};
        if (tile_index >= active_flags.len or !active_flags[tile_index]) continue;
        self.hybrid_shadow_stats.active_tile_count += 1;

        const receiver_bounds = buildReceiverBounds(self, tile, camera_to_light) orelse continue;

        const candidate_offset = candidate_write;
        const candidate_stats = collectTileCandidates(self, receiver_bounds, &candidate_write);
        self.hybrid_shadow_stats.grid_candidate_count += candidate_stats.grid_candidate_count;
        self.hybrid_shadow_stats.unique_candidate_count += candidate_stats.unique_candidate_count;
        self.hybrid_shadow_stats.final_candidate_count += candidate_stats.final_candidate_count;

        const candidate_count = candidate_write - candidate_offset;
        if (candidate_count == 0) continue;

        tile_ranges[tile_index] = .{ .offset = candidate_offset, .count = candidate_count };
        shadow_jobs[tile_index] = .{
            .renderer = self,
            .mesh = mesh,
            .tile = tile,
            .camera_position = camera_position,
            .basis_right = basis_right,
            .basis_up = basis_up,
            .basis_forward = basis_forward,
            .light_dir_world = normalized_light_dir,
            .camera_to_light = camera_to_light,
            .darkness_scale = darkness_scale,
            .valid_min_x = receiver_bounds.valid_min_x,
            .valid_min_y = receiver_bounds.valid_min_y,
            .valid_max_x = receiver_bounds.valid_max_x,
            .valid_max_y = receiver_bounds.valid_max_y,
            .candidate_offset = candidate_offset,
            .candidate_count = candidate_count,
        };
        active_indices[shadow_job_count] = tile_index;
        shadow_job_count += 1;
    }

    self.hybrid_shadow_stats.accel_rebuild_ms = render_utils.nanosecondsToMs(accel_elapsed_ns);
    self.hybrid_shadow_stats.candidate_ms = render_utils.nanosecondsToMs(std.time.nanoTimestamp() - candidate_start);
    self.hybrid_shadow_stats.job_count = shadow_job_count;
    if (shadow_job_count == 0) return;

    const cache_clear_start = std.time.nanoTimestamp();
    hybrid_shadow_cache_kernel.clearUnknown(self.hybrid_shadow_coarse_cache);
    hybrid_shadow_cache_kernel.clearUnknown(self.hybrid_shadow_edge_cache);
    self.hybrid_shadow_stats.cache_clear_ms = render_utils.nanosecondsToMs(std.time.nanoTimestamp() - cache_clear_start);

    const ShadowCtxType = @TypeOf(shadow_jobs[0]);
    if (self.hybrid_shadow_debug.enabled) {
        const execute_start = std.time.nanoTimestamp();
        if (self.hybrid_shadow_debug.completed_jobs > shadow_job_count) {
            self.hybrid_shadow_debug.completed_jobs = shadow_job_count;
        }
        if (self.hybrid_shadow_debug.advance_requested) {
            self.hybrid_shadow_debug.completed_jobs = @min(shadow_job_count, self.hybrid_shadow_debug.completed_jobs + 1);
        }
        self.hybrid_shadow_debug.advance_requested = false;

        for (active_indices[0..self.hybrid_shadow_debug.completed_jobs]) |tile_index| {
            ShadowCtxType.run(@ptrCast(&shadow_jobs[tile_index]));
        }
        self.hybrid_shadow_stats.execute_ms = render_utils.nanosecondsToMs(std.time.nanoTimestamp() - execute_start);
        self.recordRenderPassTiming("hybrid_shadow_step", pass_start);
        return;
    }

    const execute_start = std.time.nanoTimestamp();
    if (self.job_system) |job_sys| {
        const JobType = @TypeOf(jobs[0]);
        var parent_job = JobType.init(noop_job_fn, @ptrCast(self), null);
        const main_tile_idx = active_indices[0];

        for (active_indices[1..shadow_job_count]) |tile_index| {
            jobs[tile_index] = JobType.init(
                ShadowCtxType.run,
                @ptrCast(&shadow_jobs[tile_index]),
                &parent_job,
            );
            if (!job_sys.submitJobWithClass(&jobs[tile_index], .high)) {
                ShadowCtxType.run(@ptrCast(&shadow_jobs[tile_index]));
            }
        }

        ShadowCtxType.run(@ptrCast(&shadow_jobs[main_tile_idx]));
        parent_job.complete();
        self.job_system.?.waitFor(&parent_job);
    } else {
        for (active_indices[0..shadow_job_count]) |tile_index| {
            ShadowCtxType.run(@ptrCast(&shadow_jobs[tile_index]));
        }
    }

    self.hybrid_shadow_stats.execute_ms = render_utils.nanosecondsToMs(std.time.nanoTimestamp() - execute_start);
    self.recordRenderPassTiming("hybrid_shadow", pass_start);
}
