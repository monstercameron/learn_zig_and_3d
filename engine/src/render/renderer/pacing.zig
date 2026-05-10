const std = @import("std");
const windows = std.os.windows;
const config = @import("../../core/app_config.zig");
const renderer_module = @import("../renderer.zig");
const frame_pacing_hud = @import("../frame/pacing_hud.zig");

const Renderer = renderer_module.Renderer;
const frame_pacing = @import("../frame/pacing.zig");
const SetWaitableTimerEx = renderer_module.SetWaitableTimerEx;
const Sleep = renderer_module.Sleep;
pub fn currentPacingMode(renderer: *const Renderer) frame_pacing_hud.Mode {
    return frame_pacing.resolveMode(config.WINDOW_VSYNC, renderer.target_frame_time_ns);
}

pub fn usesSoftwareFramePacing(renderer: *const Renderer) bool {
    return frame_pacing.usesSoftwarePacing(renderer.currentPacingMode());
}

pub fn effectiveFramePacingTargetNs(renderer: *const Renderer) i128 {
    return frame_pacing.effectiveTargetNs(renderer.currentPacingMode(), renderer.target_frame_time_ns);
}

fn waitWithFramePacingTimer(renderer: *Renderer, sleep_ns: i128) bool {
    const timer = renderer.frame_pacing_timer orelse return false;
    if (sleep_ns <= 0) return false;

    const relative_100ns = @max(@as(i128, 1), @divTrunc(sleep_ns, 100));
    const due_time: i64 = -@as(i64, @intCast(relative_100ns));
    if (SetWaitableTimerEx(timer, &due_time, 0, null, null, null, 0) == 0) return false;
    windows.WaitForSingleObject(timer, windows.INFINITE) catch return false;
    return true;
}

fn framePacingCoarseThresholdNs(renderer: *const Renderer) i128 {
    return frame_pacing.coarseThresholdNs(renderer.target_frame_time_ns);
}

fn framePacingRequestedSleepNs(renderer: *const Renderer, remaining_ns: i128) i128 {
    return frame_pacing.requestedSleepNs(renderer.target_frame_time_ns, renderer.frame_pacing_sleep_bias_ns, remaining_ns);
}

/// updateFramePacingSleepBias updates Renderer state for the current tick/frame.
fn updateFramePacingSleepBias(renderer: *Renderer, requested_sleep_ns: i128, actual_wait_ns: i128) void {
    renderer.frame_pacing_sleep_bias_ns = frame_pacing.updateSleepBias(
        renderer.frame_pacing_sleep_bias_ns,
        requested_sleep_ns,
        actual_wait_ns,
    );
}

/// Performs wait until next frame.
/// Keeps invariants on `renderer` centralized so callers do not duplicate state transitions.
pub fn waitUntilNextFrame(renderer: *Renderer) void {
    if (!usesSoftwareFramePacing(renderer)) return;

    const wait_start = std.time.nanoTimestamp();
    const coarse_threshold_ns = framePacingCoarseThresholdNs(renderer);

    while (true) {
        const now = std.time.nanoTimestamp();
        const remaining_ns = renderer.next_frame_time - now;
        if (remaining_ns <= 0) {
            renderer.pending_software_wait_ns += std.time.nanoTimestamp() - wait_start;
            return;
        }

        if (remaining_ns > coarse_threshold_ns) {
            const sleep_ns = framePacingRequestedSleepNs(renderer, remaining_ns);
            if (sleep_ns > 0) {
                const sleep_begin = std.time.nanoTimestamp();
                if (!waitWithFramePacingTimer(renderer, sleep_ns)) {
                    const sleep_ms = @max(@as(i128, 1), @divTrunc(sleep_ns, 1_000_000));
                    Sleep(@intCast(sleep_ms));
                }
                const sleep_end = std.time.nanoTimestamp();
                updateFramePacingSleepBias(renderer, sleep_ns, @max(sleep_end - sleep_begin, @as(i128, 0)));
                continue;
            } else {
                renderer.frame_pacing_sleep_bias_ns = frame_pacing.decaySleepBias(renderer.frame_pacing_sleep_bias_ns);
            }
        }

        std.atomic.spinLoopHint();
    }
}

pub fn advanceFrameDeadline(renderer: *Renderer, now_ns: i128) void {
    renderer.next_frame_time = frame_pacing.advanceDeadline(
        renderer.currentPacingMode(),
        renderer.next_frame_time,
        renderer.target_frame_time_ns,
        now_ns,
    );
}

pub fn notePresentedFrame(renderer: *Renderer, current_time: i128) void {
    renderer.frame_count += 1;
    renderer.total_frames_rendered += 1;
    renderer.last_completed_frame_time = current_time;
    renderer.active_software_wait_ns = 0;
    renderer.advanceFrameDeadline(current_time);
}
