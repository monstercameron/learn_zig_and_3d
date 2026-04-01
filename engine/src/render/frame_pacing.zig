const std = @import("std");
const frame_pacing_hud = @import("frame_pacing_hud.zig");

pub const Mode = frame_pacing_hud.Mode;

pub fn resolveMode(vsync_enabled: bool, target_frame_time_ns: i128) Mode {
    if (vsync_enabled) return .compositor;
    if (target_frame_time_ns > 0) return .software;
    return .uncapped;
}

pub fn usesSoftwarePacing(mode: Mode) bool {
    return mode == .software;
}

pub fn effectiveTargetNs(mode: Mode, target_frame_time_ns: i128) i128 {
    return if (usesSoftwarePacing(mode)) target_frame_time_ns else 0;
}

pub fn shouldRender(mode: Mode, next_frame_time_ns: i128, now_ns: i128) bool {
    if (!usesSoftwarePacing(mode)) return true;
    return now_ns >= next_frame_time_ns;
}

pub fn safetyMarginNs(target_frame_time_ns: i128) i128 {
    if (target_frame_time_ns <= 0) return 500_000;
    return std.math.clamp(@divTrunc(target_frame_time_ns, 30), @as(i128, 500_000), @as(i128, 2_000_000));
}

pub fn coarseThresholdNs(target_frame_time_ns: i128) i128 {
    if (target_frame_time_ns <= 0) return 2_000_000;
    return std.math.clamp(@divTrunc(target_frame_time_ns, 6), @as(i128, 2_000_000), @as(i128, 8_000_000));
}

pub fn requestedSleepNs(target_frame_time_ns: i128, sleep_bias_ns: i128, remaining_ns: i128) i128 {
    const safety_margin_ns = safetyMarginNs(target_frame_time_ns);
    const bias_ns = std.math.clamp(sleep_bias_ns, @as(i128, 0), safety_margin_ns);
    return remaining_ns - safety_margin_ns - bias_ns;
}

pub fn updateSleepBias(current_bias_ns: i128, requested_sleep_ns: i128, actual_wait_ns: i128) i128 {
    if (requested_sleep_ns <= 0 or actual_wait_ns <= 0) return current_bias_ns;
    const overshoot_ns = @max(actual_wait_ns - requested_sleep_ns, @as(i128, 0));
    if (overshoot_ns > current_bias_ns) return overshoot_ns;
    return @divTrunc(current_bias_ns * 3 + overshoot_ns, 4);
}

pub fn decaySleepBias(current_bias_ns: i128) i128 {
    return @divTrunc(current_bias_ns * 3, 4);
}

pub fn advanceDeadline(mode: Mode, current_next_frame_time_ns: i128, target_frame_time_ns: i128, now_ns: i128) i128 {
    if (!usesSoftwarePacing(mode)) return now_ns;
    if (current_next_frame_time_ns <= 0) return now_ns + target_frame_time_ns;

    var next_frame_time_ns = current_next_frame_time_ns + target_frame_time_ns;
    if (next_frame_time_ns <= now_ns) {
        const overdue = now_ns - next_frame_time_ns;
        const skip_frames = @divTrunc(overdue, target_frame_time_ns) + 1;
        next_frame_time_ns += skip_frames * target_frame_time_ns;
    }
    return next_frame_time_ns;
}

test "resolveMode prefers compositor pacing when vsync is enabled" {
    try std.testing.expectEqual(Mode.compositor, resolveMode(true, 16_666_667));
    try std.testing.expectEqual(Mode.software, resolveMode(false, 16_666_667));
    try std.testing.expectEqual(Mode.uncapped, resolveMode(false, 0));
}

test "advanceDeadline keeps cadence and catches up when overdue" {
    const mode = Mode.software;
    const target = 16_666_667;
    try std.testing.expectEqual(@as(i128, 116_666_667), advanceDeadline(mode, 100_000_000, target, 100_000_000));
    try std.testing.expectEqual(@as(i128, 150_000_003), advanceDeadline(mode, 100_000_000, target, 149_000_000));
}

test "requestedSleepNs accounts for safety margin and bias" {
    const target = 16_666_667;
    const requested = requestedSleepNs(target, 500_000, 8_000_000);
    try std.testing.expect(requested < 8_000_000);
    try std.testing.expect(requested > 0);
}

test "updateSleepBias reacts to overshoot and decays" {
    const increased = updateSleepBias(200_000, 2_000_000, 2_700_000);
    try std.testing.expectEqual(@as(i128, 700_000), increased);
    try std.testing.expectEqual(@as(i128, 525_000), decaySleepBias(700_000));
}

