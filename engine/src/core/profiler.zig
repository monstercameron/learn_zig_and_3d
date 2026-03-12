//! Profiler module.
//! Core runtime infrastructure shared engine-wide (config, logging, jobs, profiling, math).

const std = @import("std");

pub const ProfilerEvent = struct {
    name: []const u8,
    tid: std.Thread.Id,
    start_ns: i128,
    end_ns: i128 = 0,
};

pub const Profiler = struct {
    events: std.ArrayList(ProfilerEvent),
    mutex: std.Thread.Mutex,
    active: bool,
    allocator: std.mem.Allocator,

    pub var instance: ?Profiler = null;

    /// init initializes Profiler state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) void {
        instance = .{
            .events = std.ArrayList(ProfilerEvent){},
            .mutex = .{},
            .active = false,
            .allocator = allocator,
        };
    }

    /// deinit releases resources owned by Profiler.
    pub fn deinit() void {
        if (instance) |*p| {
            p.events.deinit(p.allocator);
            instance = null;
        }
    }

    /// Controls playback/state through start capture.
    /// Keeps start capture as the single implementation point so call-site behavior stays consistent.
    pub fn startCapture() void {
        if (instance) |*p| {
            p.mutex.lock();
            defer p.mutex.unlock();
            p.events.clearRetainingCapacity();
            p.active = true;
        }
    }

    /// Controls playback/state through stop capture and save.
    /// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
    pub fn stopCaptureAndSave(path: []const u8) !void {
        if (instance) |*p| {
            p.mutex.lock();
            defer p.mutex.unlock();
            p.active = false;

            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll("[\n");
            var first = true;
            
            var buf: [4096]u8 = undefined;
            for (p.events.items) |evt| {
                if (evt.end_ns == 0) continue; // Unfinished
                if (!first) {
                    try file.writeAll(",\n");
                }
                first = false;
                
                const start_us = @as(f64, @floatFromInt(evt.start_ns)) / 1000.0;
                const dur_us = @as(f64, @floatFromInt(evt.end_ns - evt.start_ns)) / 1000.0;
                const s = try std.fmt.bufPrint(&buf, "{{\"name\": \"{s}\", \"cat\": \"PERF\", \"ph\": \"X\", \"ts\": {d:.3}, \"dur\": {d:.3}, \"pid\": 1, \"tid\": {}, \"args\": {{}}}}",
                    .{ evt.name, start_us, dur_us, evt.tid });
                try file.writeAll(s);
            }
            try file.writeAll("\n]\n");
        }
    }

    pub const Zone = struct {
        index: usize,
        /// Finalizes the current operation and commits or clears temporary state.
        /// It finalizes an in-flight operation and commits/clears temporary state.
        pub fn end(self: *const Zone) void {
            if (instance) |*p| {
                if (!p.active) return;
                p.mutex.lock();
                defer p.mutex.unlock();
                const now = std.time.nanoTimestamp();
                if (self.index < p.events.items.len) {
                    p.events.items[self.index].end_ns = now;
                }
            }
        }
    };

    /// Begins an operation and captures temporary context used until completion.
    /// It marks the start of an operation and prepares transient state used until completion.
    pub fn begin(name: []const u8) ?Zone {
        if (instance) |*p| {
            if (!p.active) return null;
            p.mutex.lock();
            defer p.mutex.unlock();
            const start = std.time.nanoTimestamp();
            const tid = std.Thread.getCurrentId();
            const index = p.events.items.len;
            p.events.append(p.allocator, .{
                .name = name,
                .tid = tid,
                .start_ns = start,
            }) catch return null;
            return Zone{ .index = index };
        }
        return null;
    }
};

/// Performs zone.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
pub fn zone(name: []const u8) ?Profiler.Zone {
    return Profiler.begin(name);
}
