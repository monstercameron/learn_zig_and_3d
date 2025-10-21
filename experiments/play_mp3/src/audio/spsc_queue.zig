const std = @import("std");

/// A lock-free, single-producer, single-consumer (SPSC) queue.
/// Used for passing commands from the main thread to the audio thread.
pub fn SpscQueue(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();
        buffer: [size]T = undefined,
        read_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        write_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn enqueue(self: *Self, item: T) bool {
            const write_index = self.write_idx.load(.monotonic);
            const next_write_index = (write_index + 1) % size;

            if (next_write_index == self.read_idx.load(.acquire)) {
                return false; // Queue is full
            }

            self.buffer[write_index] = item;
            self.write_idx.store(next_write_index, .release);
            return true;
        }

        pub fn dequeue(self: *Self) ?T {
            const read_index = self.read_idx.load(.monotonic);
            if (read_index == self.write_idx.load(.acquire)) {
                return null; // Queue is empty
            }

            const item = self.buffer[read_index];
            const next_read_index = (read_index + 1) % size;
            self.read_idx.store(next_read_index, .release);
            return item;
        }
    };
}
