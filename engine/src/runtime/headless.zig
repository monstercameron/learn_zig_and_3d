//! Headless renderer driver.
//!
//! Provides a window-less run mode that drives the renderer against a
//! memory framebuffer instead of presenting to a real window. The
//! benchmark harness (see ROADMAP.md Phase D) needs this so the same
//! workload can be measured without window-system jitter, on cloud VMs
//! that have no display, and with deterministic per-frame output.
//!
//! Not implemented yet. The intended surface:
//!
//!   pub fn run(opts: HeadlessOptions) !HeadlessReport
//!
//! where HeadlessOptions selects the scene, frame budget, replay log,
//! and optional per-frame PPM dump, and HeadlessReport returns
//! aggregate timings + frame hashes.

const std = @import("std");

pub const HeadlessOptions = struct {
    scene_key: []const u8,
    frame_count: u64,
    width: i32 = 1280,
    height: i32 = 720,
    replay_path: ?[]const u8 = null,
    dump_frames_to: ?[]const u8 = null,
};

pub const HeadlessReport = struct {
    frames_rendered: u64,
    total_ns: i128,
    median_frame_ns: i128,
    p95_frame_ns: i128,
    p99_frame_ns: i128,
};

pub fn run(opts: HeadlessOptions) !HeadlessReport {
    _ = opts;
    return error.NotImplemented;
}
