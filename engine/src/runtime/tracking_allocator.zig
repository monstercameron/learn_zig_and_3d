//! Tracking allocator wrapper.
//!
//! Wraps any std.mem.Allocator and counts alloc / free / resize calls
//! plus bytes-in-use and peak. The counts feed the `mem` field of
//! introspect.FrameSnapshot so the agent can correlate allocation
//! pressure with frame timings.
//!
//! Concurrency: counters are std.atomic.Value(u64). Cheap to read from
//! the frame-end hook even when alloc happens on worker threads.
//!
//! Cost when introspection is disabled: zero — the wrapper is never
//! constructed unless ZIG_INTROSPECT_MEM=1 is set in main bootstrap.

const std = @import("std");
const builtin = @import("builtin");

pub const Stats = struct {
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    resize_count: u64 = 0,
    bytes_in_use: u64 = 0,
    peak_bytes: u64 = 0,
};

pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    free_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    resize_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_in_use: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(backing: std.mem.Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn snapshot(self: *const TrackingAllocator) Stats {
        return .{
            .alloc_count = self.alloc_count.load(.monotonic),
            .free_count = self.free_count.load(.monotonic),
            .resize_count = self.resize_count.load(.monotonic),
            .bytes_in_use = self.bytes_in_use.load(.monotonic),
            .peak_bytes = self.peak_bytes.load(.monotonic),
        };
    }

    fn updatePeak(self: *TrackingAllocator, current: u64) void {
        var peak = self.peak_bytes.load(.monotonic);
        while (current > peak) {
            const result = self.peak_bytes.cmpxchgWeak(peak, current, .monotonic, .monotonic);
            if (result == null) return;
            peak = result.?;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            _ = self.alloc_count.fetchAdd(1, .monotonic);
            const new_total = self.bytes_in_use.fetchAdd(len, .monotonic) + len;
            self.updatePeak(new_total);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            _ = self.resize_count.fetchAdd(1, .monotonic);
            if (new_len >= buf.len) {
                const new_total = self.bytes_in_use.fetchAdd(new_len - buf.len, .monotonic) + (new_len - buf.len);
                self.updatePeak(new_total);
            } else {
                _ = self.bytes_in_use.fetchSub(buf.len - new_len, .monotonic);
            }
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(buf, alignment, new_len, ret_addr);
        if (result != null) {
            _ = self.resize_count.fetchAdd(1, .monotonic);
            if (new_len >= buf.len) {
                const new_total = self.bytes_in_use.fetchAdd(new_len - buf.len, .monotonic) + (new_len - buf.len);
                self.updatePeak(new_total);
            } else {
                _ = self.bytes_in_use.fetchSub(buf.len - new_len, .monotonic);
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ret_addr);
        _ = self.free_count.fetchAdd(1, .monotonic);
        _ = self.bytes_in_use.fetchSub(buf.len, .monotonic);
    }
};
