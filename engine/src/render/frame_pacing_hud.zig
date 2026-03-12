//! Frame Pacing Hud module.
//! Renderer subsystem module for camera/input integration, overlays, or scene interaction.

const std = @import("std");

pub const history_len: usize = 512;
const graph_window_ms: f32 = 4000.0;
const graph_bucket_ms: f32 = graph_window_ms / @as(f32, history_len);
const graph_min_scale_max_ms: f32 = 40.0;
const graph_hard_scale_max_ms: f32 = 250.0;
const guide_line_color: u32 = 0xFF35506E;
const guide_mid_line_color: u32 = 0xFF4F7399;

pub const Mode = enum {
    uncapped,
    software,
    compositor,

    /// Performs label.
    /// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .uncapped => "uncapped",
            .software => "software",
            .compositor => "compositor",
        };
    }
};

pub const Sample = struct {
    total_ms: f32,
    cpu_ms: f32,
    software_wait_ms: f32,
    present_wait_ms: f32,
};

pub const Stats = struct {
    sample_count: usize = 0,
    latest_ms: f32 = 0.0,
    mean_ms: f32 = 0.0,
    p95_ms: f32 = 0.0,
    p99_ms: f32 = 0.0,
    max_ms: f32 = 0.0,
    stutter_count: usize = 0,
    target_ms: f32 = 0.0,
    cpu_mean_ms: f32 = 0.0,
    software_wait_mean_ms: f32 = 0.0,
    present_wait_mean_ms: f32 = 0.0,
    cpu_latest_ms: f32 = 0.0,
    software_wait_latest_ms: f32 = 0.0,
    present_wait_latest_ms: f32 = 0.0,
};

pub const Tracker = struct {
    history_total_ms: [history_len]f32 = [_]f32{0.0} ** history_len,
    history_cpu_ms: [history_len]f32 = [_]f32{0.0} ** history_len,
    history_software_wait_ms: [history_len]f32 = [_]f32{0.0} ** history_len,
    history_present_wait_ms: [history_len]f32 = [_]f32{0.0} ** history_len,
    graph_history_ms: [history_len]f32 = [_]f32{0.0} ** history_len,
    graph_count: usize = 0,
    graph_head: usize = 0,
    graph_bucket_elapsed_ms: f32 = 0.0,
    graph_bucket_weight: f32 = 0.0,
    graph_bucket_total_ms: f32 = 0.0,
    count: usize = 0,
    head: usize = 0,
    stats: Stats = .{},

    /// sampleOrdered samples values used by Frame Pacing Hud.
    fn sampleOrdered(history: []const f32, count: usize, head: usize, ordered_index: usize) f32 {
        if (count == 0 or ordered_index >= count) return 0.0;
        const base = if (count == history_len) head else 0;
        const idx = (base + ordered_index) % history_len;
        return history[idx];
    }

    fn lessThanF32(_: void, a: f32, b: f32) bool {
        return a < b;
    }

    fn graphSampleOrdered(self: *const Tracker, ordered_index: usize) f32 {
        if (self.graph_count == 0 or ordered_index >= self.graph_count) return 0.0;
        const base = if (self.graph_count == history_len) self.graph_head else 0;
        const idx = (base + ordered_index) % history_len;
        return self.graph_history_ms[idx];
    }

    fn pushHistorySample(self: *Tracker, sample: Sample, target_frame_time_ns: i128) void {
        self.history_total_ms[self.head] = sample.total_ms;
        self.history_cpu_ms[self.head] = sample.cpu_ms;
        self.history_software_wait_ms[self.head] = sample.software_wait_ms;
        self.history_present_wait_ms[self.head] = sample.present_wait_ms;
        self.head = (self.head + 1) % history_len;
        if (self.count < history_len) self.count += 1;
        if (self.count == 0) return;

        var sorted: [history_len]f32 = undefined;
        var sum_ms: f32 = 0.0;
        var max_ms: f32 = 0.0;
        var cpu_sum_ms: f32 = 0.0;
        var software_wait_sum_ms: f32 = 0.0;
        var present_wait_sum_ms: f32 = 0.0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const total_ms = sampleOrdered(&self.history_total_ms, self.count, self.head, i);
            sorted[i] = total_ms;
            sum_ms += total_ms;
            cpu_sum_ms += sampleOrdered(&self.history_cpu_ms, self.count, self.head, i);
            software_wait_sum_ms += sampleOrdered(&self.history_software_wait_ms, self.count, self.head, i);
            present_wait_sum_ms += sampleOrdered(&self.history_present_wait_ms, self.count, self.head, i);
            if (total_ms > max_ms) max_ms = total_ms;
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
                if (sampleOrdered(&self.history_total_ms, self.count, self.head, s) > stutter_threshold) stutter_count += 1;
            }
        }

        const latest_idx = if (self.head == 0) history_len - 1 else self.head - 1;

        self.stats = .{
            .sample_count = self.count,
            .latest_ms = self.history_total_ms[latest_idx],
            .mean_ms = sum_ms / @as(f32, @floatFromInt(self.count)),
            .p95_ms = sorted[p95_index],
            .p99_ms = sorted[p99_index],
            .max_ms = max_ms,
            .stutter_count = stutter_count,
            .target_ms = target_ms,
            .cpu_mean_ms = cpu_sum_ms / @as(f32, @floatFromInt(self.count)),
            .software_wait_mean_ms = software_wait_sum_ms / @as(f32, @floatFromInt(self.count)),
            .present_wait_mean_ms = present_wait_sum_ms / @as(f32, @floatFromInt(self.count)),
            .cpu_latest_ms = self.history_cpu_ms[latest_idx],
            .software_wait_latest_ms = self.history_software_wait_ms[latest_idx],
            .present_wait_latest_ms = self.history_present_wait_ms[latest_idx],
        };
    }

    fn pushGraphBucket(self: *Tracker, sample_ms: f32) void {
        self.graph_history_ms[self.graph_head] = sample_ms;
        self.graph_head = (self.graph_head + 1) % history_len;
        if (self.graph_count < history_len) self.graph_count += 1;
    }

    fn recordGraphSample(self: *Tracker, sample_ms: f32) void {
        if (!std.math.isFinite(sample_ms) or sample_ms <= 0.0) return;

        var remaining_ms = sample_ms;
        while (remaining_ms > 0.0) {
            const bucket_capacity_ms = graph_bucket_ms - self.graph_bucket_elapsed_ms;
            const slice_ms = @min(remaining_ms, bucket_capacity_ms);
            const weight = slice_ms / sample_ms;

            self.graph_bucket_elapsed_ms += slice_ms;
            self.graph_bucket_weight += weight;
            self.graph_bucket_total_ms += sample_ms * weight;
            remaining_ms -= slice_ms;

            if (self.graph_bucket_elapsed_ms + 0.0001 >= graph_bucket_ms and self.graph_bucket_weight > 0.0) {
                self.pushGraphBucket(self.graph_bucket_total_ms / self.graph_bucket_weight);
                self.graph_bucket_elapsed_ms = 0.0;
                self.graph_bucket_weight = 0.0;
                self.graph_bucket_total_ms = 0.0;
            }
        }
    }

    /// Records telemetry/sample data and updates aggregate counters/statistics.
    /// It appends telemetry/sample data and updates aggregate counters/statistics.
    pub fn recordSample(self: *Tracker, sample: Sample, target_frame_time_ns: i128) void {
        if (!std.math.isFinite(sample.total_ms) or sample.total_ms <= 0.0) return;

        const normalized = Sample{
            .total_ms = sample.total_ms,
            .cpu_ms = if (std.math.isFinite(sample.cpu_ms) and sample.cpu_ms >= 0.0) sample.cpu_ms else 0.0,
            .software_wait_ms = if (std.math.isFinite(sample.software_wait_ms) and sample.software_wait_ms >= 0.0) sample.software_wait_ms else 0.0,
            .present_wait_ms = if (std.math.isFinite(sample.present_wait_ms) and sample.present_wait_ms >= 0.0) sample.present_wait_ms else 0.0,
        };

        self.pushHistorySample(normalized, target_frame_time_ns);
        self.recordGraphSample(normalized.total_ms);
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
    pacing_mode: Mode,
    show_overlay: bool,
    draw_ctx: *anyopaque,
    fns: DrawFns,
};

fn graphScaleMaxMs(stats: Stats) f32 {
    var scale_ms = graph_min_scale_max_ms;
    if (stats.sample_count > 0) {
        scale_ms = @max(scale_ms, stats.p95_ms * 1.35);
        scale_ms = @max(scale_ms, stats.p99_ms * 1.15);
    }
    if (stats.target_ms > 0.0) {
        scale_ms = @max(scale_ms, stats.target_ms * 2.0);
    }
    return std.math.clamp(scale_ms, graph_min_scale_max_ms, graph_hard_scale_max_ms);
}

fn frameTimeMsToYOffset(graph_h: i32, frame_ms: f32, graph_max_ms: f32) i32 {
    const clamped_ms = std.math.clamp(frame_ms, 0.0, graph_max_ms);
    const norm = if (graph_max_ms > 0.0) clamped_ms / graph_max_ms else 0.0;
    return @as(i32, @intFromFloat(norm * @as(f32, @floatFromInt(graph_h - 1))));
}

/// Performs panel rect.
/// Keeps panel rect as the single implementation point so call-site behavior stays consistent.
pub fn panelRect(bitmap_width: i32, bitmap_height: i32) ?PanelRect {
    if (bitmap_width < 160 or bitmap_height < 120) return null;
    const margin_x: i32 = 14;
    const margin_y: i32 = 26;
    var panel_w = @divTrunc(bitmap_width, 3);
    panel_w = std.math.clamp(panel_w, 220, 360);
    var panel_h = @divTrunc(bitmap_height, 4);
    panel_h = std.math.clamp(panel_h, 110, 180);
    if (panel_w >= bitmap_width - 8 or panel_h >= bitmap_height - 8) return null;
    return .{
        .x = bitmap_width - panel_w - margin_x,
        .y = bitmap_height - panel_h - margin_y,
        .w = panel_w,
        .h = panel_h,
    };
}

/// Produces visual output from current state and target buffers.
/// It emits frame output by transforming current state into rasterized/presentable results.
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
            "Frame ms latest {d:.2} mean {d:.2} p95 {d:.2} max {d:.2}",
            .{ stats.latest_ms, stats.mean_ms, stats.p95_ms, stats.max_ms },
        ) catch ""
    else
        "Frame ms collecting...";
    if (line1.len != 0) fns.drawTextLine(draw_ctx, panel.x + 8, panel.y + 6, line1);

    const line2 = if (stats.target_ms > 0.0)
        std.fmt.bufPrint(
            &line_buffer,
            "mode {s} target {d:.2} st {}/{} vsync {s}",
            .{
                params.pacing_mode.label(),
                stats.target_ms,
                stats.stutter_count,
                stats.sample_count,
                if (params.vsync_enabled) "on" else "off",
            },
        ) catch ""
    else
        std.fmt.bufPrint(
            &line_buffer,
            "mode {s} target uncapped st {} vsync {s}",
            .{
                params.pacing_mode.label(),
                stats.stutter_count,
                if (params.vsync_enabled) "on" else "off",
            },
        ) catch "";
    if (line2.len != 0) fns.drawTextLine(draw_ctx, panel.x + 8, panel.y + 22, line2);

    const line3 = if (stats.sample_count > 0)
        std.fmt.bufPrint(
            &line_buffer,
            "latest cpu {d:.2} wait {d:.2} present {d:.2} ms",
            .{ stats.cpu_latest_ms, stats.software_wait_latest_ms, stats.present_wait_latest_ms },
        ) catch ""
    else
        "";
    if (line3.len != 0) fns.drawTextLine(draw_ctx, panel.x + 8, panel.y + 38, line3);

    const graph_x = panel.x + 8;
    const graph_y = panel.y + 56;
    const graph_w = panel.w - 16;
    const graph_h = panel.h - 64;
    if (graph_w < 8 or graph_h < 8) return;
    const plot_padding: i32 = 2;
    const plot_x = graph_x + plot_padding;
    const plot_y = graph_y + plot_padding;
    const plot_w = graph_w - plot_padding * 2;
    const plot_h = graph_h - plot_padding * 2;
    if (plot_w < 8 or plot_h < 8) return;
    const graph_max_ms = graphScaleMaxMs(stats);

    fns.fillRectSolid(draw_ctx, graph_x, graph_y, graph_w, graph_h, 0xFF0C1017);
    fns.drawLineColored(draw_ctx, graph_x, graph_y, graph_x + graph_w - 1, graph_y, 0xFF233042);
    fns.drawLineColored(draw_ctx, graph_x, graph_y + graph_h - 1, graph_x + graph_w - 1, graph_y + graph_h - 1, 0xFF233042);
    fns.drawLineColored(draw_ctx, graph_x, graph_y, graph_x, graph_y + graph_h - 1, 0xFF233042);
    fns.drawLineColored(draw_ctx, graph_x + graph_w - 1, graph_y, graph_x + graph_w - 1, graph_y + graph_h - 1, 0xFF233042);

    const fps_guides = [_]struct {
        fps: f32,
        color: u32,
        label: []const u8,
        label_offset_y: i32,
    }{
        .{ .fps = 120.0, .color = guide_line_color, .label = "120 fps", .label_offset_y = 2 },
        .{ .fps = 60.0, .color = guide_mid_line_color, .label = "60 fps", .label_offset_y = -6 },
        .{ .fps = 30.0, .color = guide_line_color, .label = "30 fps", .label_offset_y = -12 },
    };
    var last_label_y: ?i32 = null;
    for (fps_guides) |guide| {
        const guide_ms = 1000.0 / guide.fps;
        if (guide_ms > graph_max_ms) continue;
        const guide_y = plot_y + frameTimeMsToYOffset(plot_h, guide_ms, graph_max_ms);
        fns.drawLineColored(draw_ctx, plot_x, guide_y, plot_x + plot_w - 1, guide_y, guide.color);
        const label_y = guide_y + guide.label_offset_y;
        if (last_label_y == null or @abs(label_y - last_label_y.?) >= 11) {
            fns.drawTextLine(draw_ctx, graph_x + 4, label_y, guide.label);
            last_label_y = label_y;
        }
    }

    var scale_label_buf: [32]u8 = undefined;
    const scale_label = std.fmt.bufPrint(&scale_label_buf, "{d:.0} ms", .{graph_max_ms}) catch "";
    if (scale_label.len != 0) fns.drawTextLine(draw_ctx, graph_x + 4, plot_y + plot_h - 12, scale_label);

    if (stats.sample_count < 2) return;

    if (stats.target_ms > 0.0) {
        const target_y = plot_y + frameTimeMsToYOffset(plot_h, stats.target_ms, graph_max_ms);
        fns.drawLineColored(draw_ctx, plot_x, target_y, plot_x + plot_w - 1, target_y, 0xFF3E5E3D);
    }

    var prev_x: i32 = plot_x;
    var prev_y: i32 = plot_y + plot_h - 1;
    var has_prev = false;
    const graph_w_usize: usize = @intCast(plot_w);
    if (graph_w_usize < 2) return;
    const window_samples: usize = @min(graph_w_usize, tracker.graph_count);
    if (window_samples < 2) return;

    const start_ordered_idx = tracker.graph_count - window_samples;
    var sample_x: usize = 0;
    while (sample_x < window_samples) : (sample_x += 1) {
        const sample_ms = tracker.graphSampleOrdered(start_ordered_idx + sample_x);
        const point_x = plot_x + @as(i32, @intCast(sample_x));
        const point_y = plot_y + frameTimeMsToYOffset(plot_h, sample_ms, graph_max_ms);
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
