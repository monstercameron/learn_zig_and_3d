const std = @import("std");
const windows = std.os.windows;
const math = @import("../core/math.zig");
const TileRenderer = @import("core/tile_renderer.zig");

pub const Axis = enum(u8) {
    x = 0,
    y = 1,
    z = 2,
};

pub fn axisName(axis: Axis) []const u8 {
    return switch (axis) {
        .x => "x",
        .y => "y",
        .z => "z",
    };
}

pub const CursorHint = enum(u8) {
    arrow,
    grab,
    grabbing,
};

pub const ItemBinding = struct {
    vertex_start: usize,
    vertex_count: usize,
    triangle_start: usize,
    triangle_count: usize,
    bounds_min: math.Vec3,
    bounds_max: math.Vec3,
    gizmo_origin: math.Vec3,
};

pub const TranslateRequest = struct {
    item_index: usize,
    delta: math.Vec3,
};

const invalid_item_index: u32 = std.math.maxInt(u32);
const axis_hover_threshold_px: f32 = 8.0;

const ItemState = struct {
    bounds_min: math.Vec3,
    bounds_max: math.Vec3,
    origin: math.Vec3,
    triangle_start: usize,
    triangle_count: usize,
};

pub const ProjectWorldFn = *const fn (ctx: *anyopaque, world_position: math.Vec3) ?[2]i32;
pub const DrawLineFn = *const fn (ctx: *anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void;

pub const State = struct {
    enabled: bool = false,
    selected_item_index: ?usize = null,
    active_axis: Axis = .x,
    move_step: f32 = 0.12,
    pending_pick: ?windows.POINT = null,
    pending_translate: ?TranslateRequest = null,

    hover_axis: ?Axis = null,
    drag_axis: ?Axis = null,
    drag_last_pointer: ?math.Vec2 = null,

    items: []ItemState = &[_]ItemState{},
    triangle_to_item: []u32 = &[_]u32{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.items.len != 0) allocator.free(self.items);
        if (self.triangle_to_item.len != 0) allocator.free(self.triangle_to_item);
        self.items = &[_]ItemState{};
        self.triangle_to_item = &[_]u32{};
        self.enabled = false;
        self.selected_item_index = null;
        self.pending_pick = null;
        self.pending_translate = null;
        self.hover_axis = null;
        self.drag_axis = null;
        self.drag_last_pointer = null;
    }

    pub fn setBindings(self: *State, allocator: std.mem.Allocator, bindings: []const ItemBinding, triangle_count: usize) !void {
        self.deinit(allocator);
        if (bindings.len == 0 or triangle_count == 0) return;

        const items = try allocator.alloc(ItemState, bindings.len);
        errdefer allocator.free(items);
        for (bindings, 0..) |binding, idx| {
            items[idx] = .{
                .bounds_min = binding.bounds_min,
                .bounds_max = binding.bounds_max,
                .origin = binding.gizmo_origin,
                .triangle_start = binding.triangle_start,
                .triangle_count = binding.triangle_count,
            };
        }

        const triangle_to_item = try allocator.alloc(u32, triangle_count);
        @memset(triangle_to_item, invalid_item_index);
        for (items, 0..) |item, item_index| {
            if (item.triangle_start >= triangle_count) continue;
            const available = triangle_count - item.triangle_start;
            const clamped_count = @min(item.triangle_count, available);
            if (clamped_count == 0) continue;
            const end = item.triangle_start + clamped_count;
            @memset(triangle_to_item[item.triangle_start..end], @as(u32, @intCast(item_index)));
        }

        self.items = items;
        self.triangle_to_item = triangle_to_item;
    }

    pub fn setPendingPick(self: *State, x: i32, y: i32) void {
        self.pending_pick = windows.POINT{ .x = x, .y = y };
    }

    pub fn toggleEnabled(self: *State) void {
        self.enabled = !self.enabled;
        self.clampSelection();
        if (!self.enabled) self.cancelInteraction();
    }

    pub fn setAxis(self: *State, axis: Axis) void {
        self.active_axis = axis;
    }

    pub fn isActive(self: *const State) bool {
        if (!self.enabled) return false;
        const selected = self.selected_item_index orelse return false;
        return selected < self.items.len;
    }

    pub fn selectedItemIndex(self: *const State) ?usize {
        const selected = self.selected_item_index orelse return null;
        if (selected >= self.items.len) return null;
        return selected;
    }

    pub fn itemCount(self: *const State) usize {
        return self.items.len;
    }

    pub fn queueSelectedTranslation(self: *State, delta_step: f32) void {
        if (!self.isActive()) return;
        const item_index = self.selected_item_index.?;
        var delta = math.Vec3.new(0.0, 0.0, 0.0);
        switch (self.active_axis) {
            .x => delta.x = delta_step,
            .y => delta.y = delta_step,
            .z => delta.z = delta_step,
        }
        self.queueTranslation(item_index, delta);
    }

    pub fn handlePointerMove(
        self: *State,
        window_x: i32,
        window_y: i32,
        bitmap_width: i32,
        bitmap_height: i32,
        window_width: i32,
        window_height: i32,
        ctx: *anyopaque,
        project_world: ProjectWorldFn,
    ) void {
        const mapped = mapWindowClickToBackbuffer(
            windows.POINT{ .x = window_x, .y = window_y },
            bitmap_width,
            bitmap_height,
            window_width,
            window_height,
        ) orelse {
            self.hover_axis = null;
            if (self.drag_axis == null) self.drag_last_pointer = null;
            return;
        };
        const pointer = math.Vec2.new(@as(f32, @floatFromInt(mapped.x)), @as(f32, @floatFromInt(mapped.y)));

        if (self.drag_axis) |drag_axis| {
            if (self.selected_item_index) |item_index| {
                if (self.drag_last_pointer) |prev| {
                    const drag_delta = computeAxisDragDelta(self, item_index, drag_axis, prev, pointer, ctx, project_world);
                    self.queueTranslation(item_index, drag_delta);
                }
                self.drag_last_pointer = pointer;
                self.hover_axis = drag_axis;
            } else {
                self.drag_axis = null;
                self.drag_last_pointer = null;
                self.hover_axis = null;
            }
            return;
        }

        if (!self.isActive()) {
            self.hover_axis = null;
            return;
        }
        self.hover_axis = hoverAxisAtPointer(self, pointer, ctx, project_world);
    }

    pub fn handlePointerDown(
        self: *State,
        window_x: i32,
        window_y: i32,
        bitmap_width: i32,
        bitmap_height: i32,
        window_width: i32,
        window_height: i32,
        ctx: *anyopaque,
        project_world: ProjectWorldFn,
    ) bool {
        const mapped = mapWindowClickToBackbuffer(
            windows.POINT{ .x = window_x, .y = window_y },
            bitmap_width,
            bitmap_height,
            window_width,
            window_height,
        ) orelse {
            self.setPendingPick(window_x, window_y);
            return false;
        };
        const pointer = math.Vec2.new(@as(f32, @floatFromInt(mapped.x)), @as(f32, @floatFromInt(mapped.y)));

        if (self.isActive()) {
            const hovered = hoverAxisAtPointer(self, pointer, ctx, project_world);
            if (hovered) |axis| {
                self.drag_axis = axis;
                self.drag_last_pointer = pointer;
                self.hover_axis = axis;
                return true;
            }
        }

        self.setPendingPick(window_x, window_y);
        return false;
    }

    pub fn handlePointerUp(self: *State) void {
        self.drag_axis = null;
        self.drag_last_pointer = null;
    }

    pub fn cancelInteraction(self: *State) void {
        self.hover_axis = null;
        self.drag_axis = null;
        self.drag_last_pointer = null;
    }

    pub fn cursorHint(self: *const State) CursorHint {
        if (self.drag_axis != null) return .grabbing;
        if (self.isActive() and self.hover_axis != null) return .grab;
        return .arrow;
    }

    pub fn isDragging(self: *const State) bool {
        return self.drag_axis != null;
    }

    pub fn consumeTranslateRequest(self: *State) ?TranslateRequest {
        const request = self.pending_translate;
        self.pending_translate = null;
        return request;
    }

    pub fn notifyItemTranslated(self: *State, item_index: usize, delta: math.Vec3) void {
        if (item_index >= self.items.len) return;
        self.items[item_index].origin = math.Vec3.add(self.items[item_index].origin, delta);
        self.items[item_index].bounds_min = math.Vec3.add(self.items[item_index].bounds_min, delta);
        self.items[item_index].bounds_max = math.Vec3.add(self.items[item_index].bounds_max, delta);
    }

    pub fn setItemOrigin(self: *State, item_index: usize, origin: math.Vec3) void {
        if (item_index >= self.items.len) return;
        const extents = math.Vec3.scale(math.Vec3.sub(self.items[item_index].bounds_max, self.items[item_index].bounds_min), 0.5);
        self.items[item_index].origin = origin;
        self.items[item_index].bounds_min = math.Vec3.sub(origin, extents);
        self.items[item_index].bounds_max = math.Vec3.add(origin, extents);
    }

    pub fn resolvePendingPick(
        self: *State,
        bitmap_width: i32,
        bitmap_height: i32,
        window_width: i32,
        window_height: i32,
        scene_surface: []const TileRenderer.SurfaceHandle,
    ) void {
        if (self.pending_pick == null) return;
        defer self.pending_pick = null;

        if (self.items.len == 0 or self.triangle_to_item.len == 0) {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        }

        const backbuffer_click = mapWindowClickToBackbuffer(
            self.pending_pick.?,
            bitmap_width,
            bitmap_height,
            window_width,
            window_height,
        ) orelse {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        };

        const pixel_index = @as(usize, @intCast(backbuffer_click.y)) * @as(usize, @intCast(bitmap_width)) + @as(usize, @intCast(backbuffer_click.x));
        if (pixel_index >= scene_surface.len) {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        }

        const surface = scene_surface[pixel_index];
        if (!surface.isValid()) {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        }
        const tri_id: usize = @intCast(surface.triangle_id);
        if (tri_id >= self.triangle_to_item.len) {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        }
        const selected_item_u32 = self.triangle_to_item[tri_id];
        if (selected_item_u32 == invalid_item_index) {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        }
        const selected_item: usize = @intCast(selected_item_u32);
        if (selected_item >= self.items.len) {
            self.selected_item_index = null;
            self.cancelInteraction();
            return;
        }

        self.selected_item_index = selected_item;
        self.enabled = true;
        self.cancelInteraction();
    }

    pub fn applyOutline(
        self: *const State,
        pixels: []u32,
        bitmap_width: i32,
        bitmap_height: i32,
        scene_surface: []const TileRenderer.SurfaceHandle,
    ) void {
        const selected = self.selectedItemIndex() orelse return;
        if (self.triangle_to_item.len == 0) return;
        if (bitmap_width <= 0 or bitmap_height <= 0) return;

        const width: usize = @intCast(bitmap_width);
        const height: usize = @intCast(bitmap_height);
        if (width < 3 or height < 3) return;

        const selected_u32: u32 = @intCast(selected);
        const outline_color: u32 = 0xFFFFC850;

        var y: usize = 1;
        while (y + 1 < height) : (y += 1) {
            const row_start = y * width;
            var x: usize = 1;
            while (x + 1 < width) : (x += 1) {
                const idx = row_start + x;
                if (idx >= pixels.len) continue;
                if (!pixelBelongsToItem(self, idx, selected_u32, scene_surface)) continue;

                const edge = !pixelBelongsToItem(self, idx - 1, selected_u32, scene_surface) or
                    !pixelBelongsToItem(self, idx + 1, selected_u32, scene_surface) or
                    !pixelBelongsToItem(self, idx - width, selected_u32, scene_surface) or
                    !pixelBelongsToItem(self, idx + width, selected_u32, scene_surface);
                if (edge) pixels[idx] = outline_color;
            }
        }
    }

    pub fn drawGizmo(self: *const State, ctx: *anyopaque, project_world: ProjectWorldFn, draw_line: DrawLineFn) void {
        const selected = self.selectedItemIndex() orelse return;
        if (selected >= self.items.len) return;
        const item = self.items[selected];
        const origin_world = item.origin;
        const origin_screen = project_world(ctx, origin_world) orelse return;

        const axis_extent = itemAxisExtent(item);
        const x_endpoint = math.Vec3.add(origin_world, math.Vec3.new(axis_extent, 0.0, 0.0));
        const y_endpoint = math.Vec3.add(origin_world, math.Vec3.new(0.0, axis_extent, 0.0));
        const z_endpoint = math.Vec3.add(origin_world, math.Vec3.new(0.0, 0.0, axis_extent));
        const hot_axis = self.drag_axis orelse self.hover_axis;

        if (project_world(ctx, x_endpoint)) |p| {
            const color = axisColor(.x, self.active_axis, hot_axis);
            draw_line(ctx, origin_screen[0], origin_screen[1], p[0], p[1], color);
            drawAxisHandle(ctx, draw_line, p[0], p[1], color);
        }
        if (project_world(ctx, y_endpoint)) |p| {
            const color = axisColor(.y, self.active_axis, hot_axis);
            draw_line(ctx, origin_screen[0], origin_screen[1], p[0], p[1], color);
            drawAxisHandle(ctx, draw_line, p[0], p[1], color);
        }
        if (project_world(ctx, z_endpoint)) |p| {
            const color = axisColor(.z, self.active_axis, hot_axis);
            draw_line(ctx, origin_screen[0], origin_screen[1], p[0], p[1], color);
            drawAxisHandle(ctx, draw_line, p[0], p[1], color);
        }

        draw_line(ctx, origin_screen[0] - 3, origin_screen[1], origin_screen[0] + 3, origin_screen[1], 0xFFFFFFFF);
        draw_line(ctx, origin_screen[0], origin_screen[1] - 3, origin_screen[0], origin_screen[1] + 3, 0xFFFFFFFF);
    }

    fn clampSelection(self: *State) void {
        if (self.items.len == 0) {
            self.selected_item_index = null;
            return;
        }
        if (self.selected_item_index == null) return;
        const selected = self.selected_item_index.?;
        if (selected >= self.items.len) {
            self.selected_item_index = self.items.len - 1;
        }
    }

    fn queueTranslation(self: *State, item_index: usize, delta: math.Vec3) void {
        if (@abs(delta.x) + @abs(delta.y) + @abs(delta.z) < 1e-6) return;
        if (self.pending_translate) |*pending| {
            if (pending.item_index == item_index) {
                pending.delta = math.Vec3.add(pending.delta, delta);
            } else {
                pending.* = .{ .item_index = item_index, .delta = delta };
            }
        } else {
            self.pending_translate = .{ .item_index = item_index, .delta = delta };
        }
    }
};

fn hoverAxisAtPointer(self: *const State, pointer: math.Vec2, ctx: *anyopaque, project_world: ProjectWorldFn) ?Axis {
    const selected = self.selectedItemIndex() orelse return null;
    if (selected >= self.items.len) return null;
    const item = self.items[selected];
    const origin = item.origin;
    const origin_screen = project_world(ctx, origin) orelse return null;
    const origin_v = math.Vec2.new(@floatFromInt(origin_screen[0]), @floatFromInt(origin_screen[1]));

    var best_axis: ?Axis = null;
    var best_dist: f32 = axis_hover_threshold_px;

    for ([_]Axis{ .x, .y, .z }) |axis| {
        const endpoint_world = axisEndpoint(item, axis);
        const endpoint_screen = project_world(ctx, endpoint_world) orelse continue;
        const endpoint_v = math.Vec2.new(@floatFromInt(endpoint_screen[0]), @floatFromInt(endpoint_screen[1]));
        const dist = distancePointToSegment(pointer, origin_v, endpoint_v);
        if (dist <= best_dist) {
            best_dist = dist;
            best_axis = axis;
        }
    }
    return best_axis;
}

fn computeAxisDragDelta(
    self: *const State,
    item_index: usize,
    axis: Axis,
    prev: math.Vec2,
    current: math.Vec2,
    ctx: *anyopaque,
    project_world: ProjectWorldFn,
) math.Vec3 {
    if (item_index >= self.items.len) return math.Vec3.new(0.0, 0.0, 0.0);
    const item = self.items[item_index];

    const origin_screen = project_world(ctx, item.origin) orelse return math.Vec3.new(0.0, 0.0, 0.0);
    const endpoint_screen = project_world(ctx, axisEndpoint(item, axis)) orelse return math.Vec3.new(0.0, 0.0, 0.0);

    const origin_v = math.Vec2.new(@floatFromInt(origin_screen[0]), @floatFromInt(origin_screen[1]));
    const endpoint_v = math.Vec2.new(@floatFromInt(endpoint_screen[0]), @floatFromInt(endpoint_screen[1]));
    const axis_screen = math.Vec2.sub(endpoint_v, origin_v);
    const axis_screen_len = @sqrt(axis_screen.x * axis_screen.x + axis_screen.y * axis_screen.y);
    if (axis_screen_len < 1.0) return math.Vec3.new(0.0, 0.0, 0.0);

    const axis_dir = math.Vec2.new(axis_screen.x / axis_screen_len, axis_screen.y / axis_screen_len);
    const mouse_delta = math.Vec2.sub(current, prev);
    const pixels_along_axis = mouse_delta.x * axis_dir.x + mouse_delta.y * axis_dir.y;
    const world_per_pixel = itemAxisExtent(item) / axis_screen_len;
    const amount = pixels_along_axis * world_per_pixel;
    if (@abs(amount) < 1e-6) return math.Vec3.new(0.0, 0.0, 0.0);
    return math.Vec3.scale(axisUnit(axis), amount);
}

fn axisColor(axis: Axis, active_axis: Axis, hot_axis: ?Axis) u32 {
    if (hot_axis != null and hot_axis.? == axis) return 0xFFFFFF66;
    if (axis == active_axis) {
        return switch (axis) {
            .x => 0xFFFFA0A0,
            .y => 0xFFA0FFA0,
            .z => 0xFFA0B8FF,
        };
    }
    return switch (axis) {
        .x => 0xFFDD4040,
        .y => 0xFF40DD40,
        .z => 0xFF4060DD,
    };
}

fn drawAxisHandle(ctx: *anyopaque, draw_line: DrawLineFn, x: i32, y: i32, color: u32) void {
    draw_line(ctx, x - 3, y, x + 3, y, color);
    draw_line(ctx, x, y - 3, x, y + 3, color);
}

fn axisUnit(axis: Axis) math.Vec3 {
    return switch (axis) {
        .x => math.Vec3.new(1.0, 0.0, 0.0),
        .y => math.Vec3.new(0.0, 1.0, 0.0),
        .z => math.Vec3.new(0.0, 0.0, 1.0),
    };
}

fn axisEndpoint(item: ItemState, axis: Axis) math.Vec3 {
    return math.Vec3.add(item.origin, math.Vec3.scale(axisUnit(axis), itemAxisExtent(item)));
}

fn itemAxisExtent(item: ItemState) f32 {
    const half_size = math.Vec3.scale(math.Vec3.sub(item.bounds_max, item.bounds_min), 0.5);
    const max_extent = @max(half_size.x, @max(half_size.y, half_size.z));
    return std.math.clamp(max_extent * 1.35, 0.25, 1.75);
}

fn distancePointToSegment(point: math.Vec2, seg_a: math.Vec2, seg_b: math.Vec2) f32 {
    const ab = math.Vec2.sub(seg_b, seg_a);
    const ap = math.Vec2.sub(point, seg_a);
    const ab_len_sq = ab.x * ab.x + ab.y * ab.y;
    if (ab_len_sq <= 1e-6) {
        const dx = point.x - seg_a.x;
        const dy = point.y - seg_a.y;
        return @sqrt(dx * dx + dy * dy);
    }
    const t = std.math.clamp((ap.x * ab.x + ap.y * ab.y) / ab_len_sq, 0.0, 1.0);
    const closest = math.Vec2.new(seg_a.x + ab.x * t, seg_a.y + ab.y * t);
    const dx = point.x - closest.x;
    const dy = point.y - closest.y;
    return @sqrt(dx * dx + dy * dy);
}

fn mapWindowClickToBackbuffer(
    click: windows.POINT,
    bitmap_width: i32,
    bitmap_height: i32,
    window_width: i32,
    window_height: i32,
) ?windows.POINT {
    if (click.x < 0 or click.y < 0) return null;
    if (window_width <= 0 or window_height <= 0) return null;
    if (bitmap_width <= 0 or bitmap_height <= 0) return null;
    if (click.x >= window_width or click.y >= window_height) return null;

    const x_scale = @as(f32, @floatFromInt(bitmap_width)) / @as(f32, @floatFromInt(window_width));
    const y_scale = @as(f32, @floatFromInt(bitmap_height)) / @as(f32, @floatFromInt(window_height));
    const mapped_x = std.math.clamp(
        @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(click.x)) * x_scale))),
        0,
        bitmap_width - 1,
    );
    const mapped_y = std.math.clamp(
        @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(click.y)) * y_scale))),
        0,
        bitmap_height - 1,
    );
    return windows.POINT{ .x = mapped_x, .y = mapped_y };
}

fn pixelBelongsToItem(self: *const State, pixel_index: usize, item_index: u32, scene_surface: []const TileRenderer.SurfaceHandle) bool {
    if (pixel_index >= scene_surface.len) return false;
    const surface = scene_surface[pixel_index];
    if (!surface.isValid()) return false;
    const tri_id: usize = @intCast(surface.triangle_id);
    if (tri_id >= self.triangle_to_item.len) return false;
    return self.triangle_to_item[tri_id] == item_index;
}
