const std = @import("std");
const windows = std.os.windows;
const math = @import("../../core/math.zig");
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const frame_pacing_hud = @import("../frame/pacing_hud.zig");
const scene_item_gizmo = @import("../scene/item_gizmo.zig");

const Renderer = renderer_module.Renderer;
const DwmFlush = renderer_module.DwmFlush;
const SetBkMode = renderer_module.SetBkMode;
const SetTextColor = renderer_module.SetTextColor;
const TextOutW = renderer_module.TextOutW;
const TRANSPARENT = renderer_module.TRANSPARENT;
const max_render_passes = renderer_module.max_render_passes;
const renderPassSortMetric = Renderer.renderPassSortMetric;
const lightGizmoAxisName = renderer_module.lightGizmoAxisName;

pub fn drawBitmap(renderer: *Renderer) void {
    _ = renderer.presentFrame(false) catch {
        // The renderer should remain operational even if a present fails transiently.
    };
    if (config.WINDOW_VSYNC and renderer.present_state.canPresent()) {
        _ = DwmFlush();
    }
}

const FramePacingDrawContext = struct {
    renderer: *Renderer,
    hdc_mem: windows.HDC,
};

fn fillRectSolid(renderer: *Renderer, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const min_x = std.math.clamp(x, 0, renderer.bitmap.width);
    const min_y = std.math.clamp(y, 0, renderer.bitmap.height);
    const max_x = std.math.clamp(x + w, 0, renderer.bitmap.width);
    const max_y = std.math.clamp(y + h, 0, renderer.bitmap.height);
    if (max_x <= min_x or max_y <= min_y) return;

    var py = min_y;
    while (py < max_y) : (py += 1) {
        const row_start = @as(usize, @intCast(py)) * @as(usize, @intCast(renderer.bitmap.width));
        var px = min_x;
        while (px < max_x) : (px += 1) {
            const idx = row_start + @as(usize, @intCast(px));
            if (idx < renderer.bitmap.pixels.len) renderer.bitmap.pixels[idx] = color;
        }
    }
}

fn framePacingFillRect(ctx_ptr: *anyopaque, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    const ctx: *FramePacingDrawContext = @ptrCast(@alignCast(ctx_ptr));
    fillRectSolid(ctx.renderer, x, y, w, h, color);
}

fn framePacingDrawLine(ctx_ptr: *anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    const ctx: *FramePacingDrawContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.renderer.drawLineColored(x0, y0, x1, y1, color);
}

fn framePacingDrawText(ctx_ptr: *anyopaque, x: i32, y: i32, text: []const u8) void {
    const ctx: *FramePacingDrawContext = @ptrCast(@alignCast(ctx_ptr));
    drawOverlayTextLine(ctx.renderer, ctx.hdc_mem, x, y, text);
}

pub fn drawFramePacingPanel(renderer: *Renderer, hdc_mem: windows.HDC) void {
    var draw_ctx = FramePacingDrawContext{
        .renderer = renderer,
        .hdc_mem = hdc_mem,
    };
    frame_pacing_hud.drawPanel(&renderer.frame_pacing, .{
        .bitmap_width = renderer.bitmap.width,
        .bitmap_height = renderer.bitmap.height,
        .vsync_enabled = config.WINDOW_VSYNC,
        .pacing_mode = renderer.currentPacingMode(),
        .show_overlay = renderer.show_frame_pacing_overlay,
        .draw_ctx = @ptrCast(&draw_ctx),
        .fns = .{
            .fillRectSolid = framePacingFillRect,
            .drawLineColored = framePacingDrawLine,
            .drawTextLine = framePacingDrawText,
        },
    });
}

pub fn drawRenderPassOverlay(renderer: *Renderer, hdc_mem: windows.HDC) void {
    if (renderer.render_pass_count == 0 and !renderer.hybrid_shadow_debug.enabled and renderer.hybrid_shadow_stats.job_count == 0 and !renderer.light_gizmo.enabled and !renderer.scene_item_gizmo.enabled and !renderer.show_render_overlay and !renderer.loading_overlay.enabled) return;

    _ = SetBkMode(hdc_mem, TRANSPARENT);

    var y: i32 = 12;
    if (renderer.render_pass_count != 0) {
        drawOverlayTextLine(renderer, hdc_mem, 12, y, "Render Passes (1s avg ms/frame)");
        y += 20;

        var line_buffer: [160]u8 = undefined;
        var pass_order: [max_render_passes]usize = undefined;
        for (0..renderer.render_pass_count) |idx| {
            pass_order[idx] = idx;
        }

        var sort_idx: usize = 1;
        while (sort_idx < renderer.render_pass_count) : (sort_idx += 1) {
            const current_idx = pass_order[sort_idx];
            const current_metric = renderPassSortMetric(renderer.render_pass_timings[current_idx]);
            var insert_idx = sort_idx;
            while (insert_idx > 0) {
                const prev_idx = pass_order[insert_idx - 1];
                if (renderPassSortMetric(renderer.render_pass_timings[prev_idx]) >= current_metric) break;
                pass_order[insert_idx] = prev_idx;
                insert_idx -= 1;
            }
            pass_order[insert_idx] = current_idx;
        }

        for (pass_order[0..renderer.render_pass_count]) |pass_idx| {
            const pass = renderer.render_pass_timings[pass_idx];
            const display_name = if (config.POST_TAA_ENABLED and std.mem.eql(u8, pass.name, "taa"))
                "meshlet_taa"
            else
                pass.name;
            const line = if (pass.has_sample)
                std.fmt.bufPrint(&line_buffer, "{s}: {d:.2} ms/frame", .{ display_name, pass.sampled_ms_per_frame }) catch continue
            else
                std.fmt.bufPrint(&line_buffer, "{s}: sampling...", .{display_name}) catch continue;
            drawOverlayTextLine(renderer, hdc_mem, 12, y, line);
            y += 16;
        }
    }

    if (renderer.hybrid_shadow_debug.enabled or renderer.hybrid_shadow_stats.job_count != 0) {
        var line_buffer: [160]u8 = undefined;
        if (renderer.render_pass_count != 0) y += 8;
        drawOverlayTextLine(renderer, hdc_mem, 12, y, "Hybrid Shadow");
        y += 20;

        const mode_line = if (renderer.hybrid_shadow_debug.enabled)
            std.fmt.bufPrint(
                &line_buffer,
                "step mode: H toggle, N advance ({}/{} jobs)",
                .{ renderer.hybrid_shadow_debug.completed_jobs, renderer.hybrid_shadow_stats.job_count },
            ) catch ""
        else
            std.fmt.bufPrint(&line_buffer, "jobs={} active_tiles={}", .{ renderer.hybrid_shadow_stats.job_count, renderer.hybrid_shadow_stats.active_tile_count }) catch "";
        if (mode_line.len != 0) {
            drawOverlayTextLine(renderer, hdc_mem, 12, y, mode_line);
            y += 16;
        }

        const stats_line = std.fmt.bufPrint(
            &line_buffer,
            "grid={} unique={} final={}",
            .{
                renderer.hybrid_shadow_stats.grid_candidate_count,
                renderer.hybrid_shadow_stats.unique_candidate_count,
                renderer.hybrid_shadow_stats.final_candidate_count,
            },
        ) catch "";
        if (stats_line.len != 0) {
            drawOverlayTextLine(renderer, hdc_mem, 12, y, stats_line);
            y += 16;
        }
    }

    if (renderer.light_gizmo.enabled) {
        var line_buffer: [192]u8 = undefined;
        if (renderer.render_pass_count != 0 or renderer.hybrid_shadow_debug.enabled or renderer.hybrid_shadow_stats.job_count != 0) y += 8;
        drawOverlayTextLine(renderer, hdc_mem, 12, y, "Light Gizmo");
        y += 20;
        drawOverlayTextLine(renderer, hdc_mem, 12, y, "G toggle, L cycle, X/Y/Z axis, J/K move");
        y += 16;

        if (renderer.lights.items.len > 0) {
            renderer.clampLightGizmoSelection();
            const status_line = std.fmt.bufPrint(
                &line_buffer,
                "light={}/{} axis={s} step={d:.2}",
                .{
                    renderer.light_gizmo.selected_light_index + 1,
                    renderer.lights.items.len,
                    lightGizmoAxisName(renderer.light_gizmo.active_axis),
                    renderer.light_gizmo.move_step,
                },
            ) catch "";
            if (status_line.len != 0) {
                drawOverlayTextLine(renderer, hdc_mem, 12, y, status_line);
                y += 16;
            }
        } else {
            drawOverlayTextLine(renderer, hdc_mem, 12, y, "no lights available");
            y += 16;
        }
    }

    if (renderer.scene_item_gizmo.enabled) {
        var line_buffer: [192]u8 = undefined;
        if (renderer.render_pass_count != 0 or renderer.hybrid_shadow_debug.enabled or renderer.hybrid_shadow_stats.job_count != 0 or renderer.light_gizmo.enabled) y += 8;
        drawOverlayTextLine(renderer, hdc_mem, 12, y, "Scene Gizmo");
        y += 20;
        drawOverlayTextLine(renderer, hdc_mem, 12, y, "click select, M toggle, X/Y/Z axis, J/K move");
        y += 16;

        if (renderer.scene_item_gizmo.selectedItemIndex()) |selected_item| {
            const status_line = std.fmt.bufPrint(
                &line_buffer,
                "item={}/{} axis={s} step={d:.2}",
                .{
                    selected_item + 1,
                    renderer.scene_item_gizmo.itemCount(),
                    scene_item_gizmo.axisName(renderer.scene_item_gizmo.active_axis),
                    renderer.scene_item_gizmo.move_step,
                },
            ) catch "";
            if (status_line.len != 0) {
                drawOverlayTextLine(renderer, hdc_mem, 12, y, status_line);
                y += 16;
            }
        } else {
            drawOverlayTextLine(renderer, hdc_mem, 12, y, "no selected item");
            y += 16;
        }
    }

    if (renderer.show_render_overlay or renderer.scene_item_gizmo.enabled) {
        var line_buffer: [160]u8 = undefined;
        if (renderer.render_pass_count != 0 or renderer.hybrid_shadow_debug.enabled or renderer.hybrid_shadow_stats.job_count != 0 or renderer.light_gizmo.enabled or renderer.scene_item_gizmo.enabled) y += 8;
        const mode_line = std.fmt.bufPrint(
            &line_buffer,
            "Camera Mode: {s} (V toggle)",
            .{if (renderer.camera_control_mode == .first_person) "first_person" else "editor"},
        ) catch "";
        if (mode_line.len != 0) {
            drawOverlayTextLine(renderer, hdc_mem, 12, y, mode_line);
            y += 16;
        }
        if (renderer.camera_control_mode == .first_person) {
            const mouse_line = std.fmt.bufPrint(
                &line_buffer,
                "Mouse sens={d:.4} dpi_scale={d:.2} smooth={d:.2}",
                .{
                    renderer.mouse_state.sensitivity,
                    config.CAMERA_MOUSE_DPI_SCALE,
                    config.CAMERA_MOUSE_SMOOTHING,
                },
            ) catch "";
            if (mouse_line.len != 0) drawOverlayTextLine(renderer, hdc_mem, 12, y, mouse_line);
        }
    }

    if (renderer.loading_overlay.enabled) {
        drawSceneLoadingOverlay(renderer, hdc_mem);
    }
}

fn drawSceneLoadingOverlay(renderer: *Renderer, hdc_mem: windows.HDC) void {
    if (!renderer.loading_overlay.enabled) return;

    const panel_w = std.math.clamp(@divTrunc(renderer.bitmap.width * 56, 100), 300, 620);
    const panel_h: i32 = 120;
    const panel_x = @divTrunc(renderer.bitmap.width - panel_w, 2);
    const panel_y = @divTrunc(renderer.bitmap.height - panel_h, 2);
    fillRectSolid(renderer, panel_x, panel_y, panel_w, panel_h, 0xDD0E141C);
    renderer.drawLineColored(panel_x, panel_y, panel_x + panel_w - 1, panel_y, 0xFF2F435A);
    renderer.drawLineColored(panel_x, panel_y + panel_h - 1, panel_x + panel_w - 1, panel_y + panel_h - 1, 0xFF2F435A);
    renderer.drawLineColored(panel_x, panel_y, panel_x, panel_y + panel_h - 1, 0xFF2F435A);
    renderer.drawLineColored(panel_x + panel_w - 1, panel_y, panel_x + panel_w - 1, panel_y + panel_h - 1, 0xFF2F435A);

    const spinner_center_x = panel_x + 28;
    const spinner_center_y = panel_y + 46;
    const spinner_segments: u32 = 12;
    const spinner_radius_inner: f32 = 7.0;
    const spinner_radius_outer: f32 = 12.0;
    const spinner_phase = renderer.loading_overlay.spinner_tick % spinner_segments;

    var seg: u32 = 0;
    while (seg < spinner_segments) : (seg += 1) {
        const angle = (@as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(spinner_segments))) * std.math.tau;
        const c = @cos(angle);
        const s = @sin(angle);
        const x0 = spinner_center_x + @as(i32, @intFromFloat(c * spinner_radius_inner));
        const y0 = spinner_center_y + @as(i32, @intFromFloat(s * spinner_radius_inner));
        const x1 = spinner_center_x + @as(i32, @intFromFloat(c * spinner_radius_outer));
        const y1 = spinner_center_y + @as(i32, @intFromFloat(s * spinner_radius_outer));
        const dist_a = if (seg >= spinner_phase) seg - spinner_phase else spinner_segments - (spinner_phase - seg);
        const shade: u32 = 64 + (spinner_segments - dist_a) * 12;
        const color: u32 = 0xFF000000 | (shade << 16) | (shade << 8) | shade;
        renderer.drawLineColored(x0, y0, x1, y1, color);
    }

    var line_buffer: [192]u8 = undefined;
    const title_line = std.fmt.bufPrint(
        &line_buffer,
        "Loading scene: {s}",
        .{renderer.loading_overlay.sceneText()},
    ) catch "Loading scene...";
    drawOverlayTextLine(renderer, hdc_mem, panel_x + 52, panel_y + 16, title_line);

    const status_line = std.fmt.bufPrint(
        &line_buffer,
        "Assets {}/{}",
        .{ renderer.loading_overlay.completed_steps, renderer.loading_overlay.total_steps },
    ) catch "";
    if (status_line.len != 0) drawOverlayTextLine(renderer, hdc_mem, panel_x + 52, panel_y + 34, status_line);

    const phase = renderer.loading_overlay.phaseText();
    if (phase.len != 0) drawOverlayTextLine(renderer, hdc_mem, panel_x + 52, panel_y + 52, phase);

    const bar_x = panel_x + 16;
    const bar_w = panel_w - 32;
    const bar_y = panel_y + panel_h - 28;
    const bar_h: i32 = 14;
    fillRectSolid(renderer, bar_x, bar_y, bar_w, bar_h, 0xFF0A0E14);
    renderer.drawLineColored(bar_x, bar_y, bar_x + bar_w - 1, bar_y, 0xFF304458);
    renderer.drawLineColored(bar_x, bar_y + bar_h - 1, bar_x + bar_w - 1, bar_y + bar_h - 1, 0xFF304458);
    renderer.drawLineColored(bar_x, bar_y, bar_x, bar_y + bar_h - 1, 0xFF304458);
    renderer.drawLineColored(bar_x + bar_w - 1, bar_y, bar_x + bar_w - 1, bar_y + bar_h - 1, 0xFF304458);

    const fill_max = @max(@as(i32, 0), bar_w - 2);
    const fill_w = std.math.clamp(
        @as(i32, @intFromFloat(renderer.loading_overlay.progress * @as(f32, @floatFromInt(fill_max)))),
        0,
        fill_max,
    );
    if (fill_w > 0) fillRectSolid(renderer, bar_x + 1, bar_y + 1, fill_w, bar_h - 2, 0xFF4ECFB5);
}

fn drawOverlayTextLine(renderer: *Renderer, hdc_mem: windows.HDC, x: i32, y: i32, text: []const u8) void {
    _ = renderer;
    var wide_buffer: [128:0]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide_buffer, text) catch return;
    wide_buffer[len] = 0;

    _ = SetTextColor(hdc_mem, 0x00000000);
    _ = TextOutW(hdc_mem, x + 1, y + 1, &wide_buffer, @intCast(len));
    _ = SetTextColor(hdc_mem, 0x00F0F0F0);
    _ = TextOutW(hdc_mem, x, y, &wide_buffer, @intCast(len));
}