//! Implements the Bloom Blur V kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

/// Runs this kernel over a `[start_row, end_row)` span.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn runRows(
    bloom: anytype,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(bloom), usize, usize) void,
) void {
    impl_fn(bloom, start_row, end_row);
}
