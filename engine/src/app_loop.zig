const std = @import("std");

pub const LoopControl = struct {
    running: *bool,
    start_ns: i128,
    ttl_ns: ?i128 = null,
    ttl_frames: ?u64 = null,
};

pub fn run(control: *LoopControl, session: anytype, comptime Driver: type) !u32 {
    var frame_count: u32 = 0;

    while (control.running.*) {
        Driver.beginFrame(session);

        if (control.ttl_ns) |ttl_ns| {
            if (std.time.nanoTimestamp() - control.start_ns >= ttl_ns) {
                Driver.onTtlExpired(session, .time);
                control.running.* = false;
                break;
            }
        }
        if (control.ttl_frames) |ttl_frames| {
            if (frame_count >= ttl_frames) {
                Driver.onTtlExpired(session, .frames);
                control.running.* = false;
                break;
            }
        }

        if (!Driver.pump(session)) {
            Driver.onMessagePumpShutdown(session);
            control.running.* = false;
            break;
        }

        try Driver.update(session, frame_count);

        if (!Driver.shouldRender(session)) {
            Driver.waitUntilNextFrame(session);
            continue;
        }

        frame_count += 1;
        Driver.onFrameStart(session, frame_count);
        Driver.render(session) catch |err| {
            Driver.onRenderError(session, err);
            control.running.* = false;
            break;
        };
        Driver.onFrameComplete(session, frame_count);
    }

    return frame_count;
}

const TestSession = struct {
    begin_calls: u32 = 0,
    pump_calls: u32 = 0,
    update_calls: u32 = 0,
    wait_calls: u32 = 0,
    render_calls: u32 = 0,
    render_enabled: bool = true,
    next_pump_result: bool = true,
    stop_after_update: bool = false,
    ttl_events: u32 = 0,
    shutdown_events: u32 = 0,
    frame_start_calls: u32 = 0,
    frame_complete_calls: u32 = 0,
    render_error_events: u32 = 0,
};

const TestDriver = struct {
    pub fn beginFrame(session: *TestSession) void {
        session.begin_calls += 1;
    }

    pub fn pump(session: *TestSession) bool {
        session.pump_calls += 1;
        return session.next_pump_result;
    }

    pub fn update(session: *TestSession, _: u32) !void {
        session.update_calls += 1;
        if (session.stop_after_update) session.next_pump_result = false;
    }

    pub fn shouldRender(session: *TestSession) bool {
        return session.render_enabled;
    }

    pub fn waitUntilNextFrame(session: *TestSession) void {
        session.wait_calls += 1;
        session.next_pump_result = false;
    }

    pub fn render(session: *TestSession) !void {
        session.render_calls += 1;
    }

    pub fn onTtlExpired(session: *TestSession, _: enum { time, frames }) void {
        session.ttl_events += 1;
    }

    pub fn onMessagePumpShutdown(session: *TestSession) void {
        session.shutdown_events += 1;
    }

    pub fn onFrameStart(session: *TestSession, _: u32) void {
        session.frame_start_calls += 1;
    }

    pub fn onRenderError(session: *TestSession, _: anyerror) void {
        session.render_error_events += 1;
    }

    pub fn onFrameComplete(session: *TestSession, _: u32) void {
        session.frame_complete_calls += 1;
    }
};

test "app loop exits on frame TTL before update" {
    var running = true;
    var control = LoopControl{
        .running = &running,
        .start_ns = std.time.nanoTimestamp(),
        .ttl_frames = 0,
    };
    var session = TestSession{};
    const frames = try run(&control, &session, TestDriver);
    try std.testing.expectEqual(@as(u32, 0), frames);
    try std.testing.expectEqual(@as(u32, 1), session.begin_calls);
    try std.testing.expectEqual(@as(u32, 1), session.ttl_events);
    try std.testing.expectEqual(@as(u32, 0), session.pump_calls);
    try std.testing.expectEqual(false, running);
}

test "app loop exits on message pump shutdown" {
    var running = true;
    var control = LoopControl{
        .running = &running,
        .start_ns = std.time.nanoTimestamp(),
    };
    var session = TestSession{ .next_pump_result = false };
    const frames = try run(&control, &session, TestDriver);
    try std.testing.expectEqual(@as(u32, 0), frames);
    try std.testing.expectEqual(@as(u32, 1), session.begin_calls);
    try std.testing.expectEqual(@as(u32, 1), session.pump_calls);
    try std.testing.expectEqual(@as(u32, 1), session.shutdown_events);
    try std.testing.expectEqual(@as(u32, 0), session.update_calls);
    try std.testing.expectEqual(false, running);
}

test "app loop waits when render is skipped" {
    var running = true;
    var control = LoopControl{
        .running = &running,
        .start_ns = std.time.nanoTimestamp(),
    };
    var session = TestSession{ .render_enabled = false };
    const frames = try run(&control, &session, TestDriver);
    try std.testing.expectEqual(@as(u32, 0), frames);
    try std.testing.expectEqual(@as(u32, 1), session.update_calls);
    try std.testing.expectEqual(@as(u32, 1), session.wait_calls);
    try std.testing.expectEqual(@as(u32, 0), session.render_calls);
    try std.testing.expectEqual(false, running);
}
