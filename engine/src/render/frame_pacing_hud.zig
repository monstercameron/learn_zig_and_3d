const std = @import("std");

pub const history_len: usize = 240;

pub const Stats = struct {
    sample_count: usize = 0,
    mean_ms: f32 = 0.0,
    p95_ms: f32 = 0.0,
    p99_ms: f32 = 0.0,
    max_ms: f32 = 0.0,
    stutter_count: usize = 0,
    target_ms: f32 = 0.0,
};

pub const Tracker = struct {
    history_ms: [history_len]f32 = [_]f32{0.0} ** history_len,
    count: usize = 0,
    head: usize = 0,
    stats: Stats = .{},

    fn sampleOrdered(self: *const Tracker, ordered_index: usize) f32 {
        if (self.count == 0 or ordered_index >= self.count) return 0.0;
        const base = if (self.count == history_len) self.head else 0;
        const idx = (base + ordered_index) % history_len;
        return self.history_ms[idx];
    }

    fn lessThanF32(_: void, a: f32, b: f32) bool {
        return a < b;
    }

    pub fn recordSample(self: *Tracker, frame_ms: f32, target_frame_time_ns: i128) void {
        if (!std.math.isFinite(frame_ms) or frame_ms <= 0.0) return;

        self.history_ms[self.head] = frame_ms;
        self.head = (self.head + 1) % history_len;
        if (self.count < history_len) self.count += 1;
        if (self.count == 0) return;

        var sorted: [history_len]f32 = undefined;
        var sum_ms: f32 = 0.0;
        var max_ms: f32 = 0.0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const sample = self.sampleOrdered(i);
            sorted[i] = sample;
            sum_ms += sample;
            if (sample > max_ms) max_ms = sample;
        }
        std.sort.block(f32, sorted[0..self.count], {}, lessThanF32);

        const p95_index = @min(self.count - 1, @divTrunc((self.count - 1) * 95, 100));
        const p99_index = @min(self.count - 1, @divTrunc((self.count - 1) * 99, 100));
        const target_ms = if (target_frame_time_ns > 0)
            @as(f32, @floatFromInt(target_frame_time_ns)) / 1_000_000.0
        else
            0.0;

        var stutter_count: usize = 0;
        if (target_ms > 0.0) {
            const stutter_threshold = target_ms * 1.25;
            var s: usize = 0;
            while (s < self.count) : (s += 1) {
                if (self.sampleOrdered(s) > stutter_threshold) stutter_count += 1;
            }
        }

        self.stats = .{
            .sample_count = self.count,
            .mean_ms = sum_ms / @as(f32, @floatFromInt(self.count)),
            .p95_ms = sorted[p95_index],
            .p99_ms = sorted[p99_index],
            .max_ms = max_ms,
            .stutter_count = stutter_count,
            .target_ms = target_ms,
        };
    }
};

pub const PanelRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const DrawFns = struct {
    fillRectSolid: *const fn (ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, color: u32) void,
    drawLineColored: *const fn (ctx: *anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void,
    drawTextLine: *const fn (ctx: *anyopaque, x: i32, y: i32, text: []const u8) void,
};

pub const DrawParams = struct {
    bitmap_width: i32,
    bitmap_height: i32,
    vsync_enabled: bool,
    show_overlay: bool,
    draw_ctx: *anyopaque,
    fns: DrawFns,
};

pub fn panelRect(bitmap_width: i32, bitmap_height: i32) ?PanelRect {
    if (bitmap_width < 160 or bitmap_height < 120) return null;
    const margin: i32 = 14;
    var panel_w = @divTrunc(bitmap_width, 3);
    panel_w = std.math.clamp(panel_w, 220, 360);
    var panel_h = @divTrunc(bitmap_height, 4);
    panel_h = std.math.clamp(panel_h, 110, 180);
    if (panel_w >= bitmap_width - 8 or panel_h >= bitmap_height - 8) return null;
    return .{
        .x = bitmap_width - panel_w - margin,
        .y = bitmap_height - panel_h - margin,
        .w = panel_w,
        .h = panel_h,
    };
}

pub fn drawPanel(tracker: *const Tracker, params: DrawParams) void {
    if (!params.show_overlay) return;
    const panel = panelRect(params.bitmap_width, params.bitmap_height) orelse return;

    const fns = params.fns;
    const draw_ctx = params.draw_ctx;
    fns.fillRectSolid(draw_ctx, panel.x, panel.y, panel.w, panel.h, 0xFF11151D);
    fns.drawLineColored(draw_ctx, panel.x, panel.y, panel.x + panel.w - 1, panel.y, 0xFF2A3242);
    fns.drawLineColored(draw_ctx, panel.x, panel.y + panel.h - 1, panel.x + panel.w - 1, panel.y + panel.h - 1, 0xFF2A3242);
    fns.drawLineColored(draw_ctx, panel.x, panel.y, panel.x, panel.y + panel.h - 1, 0xFF2A3242);
    fns.drawLineColored(draw_ctx, panel.x + panel.w - 1, panel.y, panel.x + panel.w - 1, panel.y + panel.h - 1, 0xFF2A3242);

    const stats = tracker.stats;
    var line_buffer: [192]u8 = undefined;
    const line1 = if (stats.sample_count > 0)
        std.fmt.bufPrint(
            &line_buffer,
            "Frame ms mean {d:.2} p95 {d:.2} p99 {d:.2} max {d:.2}",
            .{ stats.mean_ms, stats.p95_ms, stats.p99_ms, stats.max_ms },
        ) catch ""
    else
        "Frame ms collecting...";
    if (line1.len != 0) fns.drawTextLine(draw_ctx, panel.x + 8, panel.y + 6, line1);

    const line2 = if (stats.target_ms > 0.0)
        std.fmt.bufPrint(
            &line_buffer,
            "target {d:.2} stutters {}/{} vsync {s}",
            .{
                stats.target_ms,
                stats.stutter_count,
                stats.sample_count,
                if (params.vsync_enabled) "on" else "off",
            },
        ) catch ""
    else
        std.fmt.bufPrint(
            &line_buffer,
            "target uncapped stutters {} vsync {s}",
            .{
                stats.stutter_count,
                if (params.vsync_enabled) "on" else "off",
            },
        ) catch "";
    if (line2.len != 0) fns.drawTextLine(draw_ctx, panel.x + 8, panel.y + 22, line2);

    const graph_x = panel.x + 8;
    const graph_y = panel.y + 40;
    const graph_w = panel.w - 16;
    const graph_h = panel.h - 48;
    if (graph_w < 8 or graph_h < 8) return;

    fns.fillRectSolid(draw_ctx, graph_x, graph_y, graph_w, graph_h, 0xFF0C1017);
    fns.drawLineColored(draw_ctx, graph_x, graph_y, graph_x + graph_w - 1, graph_y, 0xFF233042);
    fns.drawLineColored(draw_ctx, graph_x, graph_y + graph_h - 1, graph_x + graph_w - 1, graph_y + graph_h - 1, 0xFF233042);
    fns.drawLineColored(draw_ctx, graph_x, graph_y, graph_x, graph_y + graph_h - 1, 0xFF233042);
    fns.drawLineColored(draw_ctx, graph_x + graph_w - 1, graph_y, graph_x + graph_w - 1, graph_y + graph_h - 1, 0xFF233042);

    if (stats.sample_count < 2) return;

    var graph_max_ms = @max(16.0, stats.max_ms * 1.10);
    if (stats.target_ms > 0.0) graph_max_ms = @max(graph_max_ms, stats.target_ms * 1.50);

    if (stats.target_ms > 0.0) {
        const target_norm = std.math.clamp(stats.target_ms / graph_max_ms, 0.0, 1.0);
        const target_offset = @as(i32, @intFromFloat(target_norm * @as(f32, @floatFromInt(graph_h - 1))));
        const target_y = graph_y + (graph_h - 1 - target_offset);
        fns.drawLineColored(draw_ctx, graph_x + 1, target_y, graph_x + graph_w - 2, target_y, 0xFF3E5E3D);
    }

    const width_samples: usize = @intCast(graph_w);
    var prev_x: i32 = graph_x;
    var prev_y: i32 = graph_y + graph_h - 1;
    var has_prev = false;
    var sample_x: usize = 0;
    while (sample_x < width_samples) : (sample_x += 1) {
        const ordered_idx = if (width_samples <= 1)
            0
        else
            @divTrunc((stats.sample_count - 1) * sample_x, width_samples - 1);
        const sample_ms = tracker.sampleOrdered(ordered_idx);
        const norm = std.math.clamp(sample_ms / graph_max_ms, 0.0, 1.0);
        const y_offset = @as(i32, @intFromFloat(norm * @as(f32, @floatFromInt(graph_h - 1))));
        const point_x = graph_x + @as(i32, @intCast(sample_x));
        const point_y = graph_y + (graph_h - 1 - y_offset);
        const color: u32 = if (stats.target_ms > 0.0 and sample_ms > stats.target_ms * 1.25)
            0xFFFF5A5A
        else if (stats.target_ms > 0.0 and sample_ms > stats.target_ms)
            0xFFFFC857
        else
            0xFF63D7C2;

        if (has_prev) {
            fns.drawLineColored(draw_ctx, prev_x, prev_y, point_x, point_y, color);
        }
        prev_x = point_x;
        prev_y = point_y;
        has_prev = true;
    }
}
