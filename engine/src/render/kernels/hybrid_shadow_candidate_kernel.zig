//! Implements the Hybrid Shadow Candidate kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

/// Performs next mark.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
pub fn nextMark(current_generation: u32, marks: []u32) u32 {
    if (marks.len == 0) return 0;
    if (current_generation == std.math.maxInt(u32)) {
        @memset(marks, 0);
        return 1;
    }
    const next = current_generation +% 1;
    return if (next == 0) 1 else next;
}

const std = @import("std");
