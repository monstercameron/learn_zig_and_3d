//! Deterministic input record + replay.
//!
//! The benchmark workload (see ROADMAP.md Phase A) must run identical
//! frames across SIMD ISAs to give a fair perf comparison. That means
//! every input event (key, mouse delta, button, focus) and every
//! random seed needs to be recorded once and replayed exactly. This
//! module owns that recording format.
//!
//! Not implemented yet. The intended surface:
//!
//!   pub fn openRecorder(path) !Recorder
//!   pub fn openReplay(path) !Replay
//!   pub fn snapshotFrame(...) FrameHash    // regression check
//!
//! File format will be a versioned binary header + tightly-packed
//! per-frame event records so replays can fast-forward.

const std = @import("std");

pub const RecordHeader = extern struct {
    magic: [4]u8 = "ZRR\x00".*,
    version: u32 = 1,
    width: i32,
    height: i32,
    seed: u64,
};

pub const FrameEvent = union(enum) {
    none,
    key: struct { code: u32, down: bool },
    mouse_move: struct { x: i32, y: i32 },
    mouse_delta: struct { dx: i32, dy: i32 },
    mouse_button: struct { button: u8, down: bool },
    focus: bool,
};

pub const FrameHash = u64;

pub const Recorder = struct {
    file: std.fs.File,

    pub fn writeFrame(self: *Recorder, events: []const FrameEvent) !void {
        _ = self;
        _ = events;
        return error.NotImplemented;
    }

    pub fn close(self: *Recorder) void {
        self.file.close();
    }
};

pub const Replay = struct {
    file: std.fs.File,
    header: RecordHeader,

    pub fn nextFrame(self: *Replay, out_events: *std.ArrayList(FrameEvent)) !bool {
        _ = self;
        _ = out_events;
        return error.NotImplemented;
    }

    pub fn close(self: *Replay) void {
        self.file.close();
    }
};

pub fn openRecorder(path: []const u8, header: RecordHeader) !Recorder {
    _ = path;
    _ = header;
    return error.NotImplemented;
}

pub fn openReplay(path: []const u8) !Replay {
    _ = path;
    return error.NotImplemented;
}
