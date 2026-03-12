//! Implements the SSAO Blur kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.
/// Runs horizontal rows.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn runHorizontalRows(
    ao_scratch: anytype,
    blur_depth_threshold: f32,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(ao_scratch), f32, usize, usize) void,
) void {
    impl_fn(ao_scratch, blur_depth_threshold, start_row, end_row);
}

/// Runs vertical rows.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn runVerticalRows(
    ao_scratch: anytype,
    blur_depth_threshold: f32,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(ao_scratch), f32, usize, usize) void,
) void {
    impl_fn(ao_scratch, blur_depth_threshold, start_row, end_row);
}
