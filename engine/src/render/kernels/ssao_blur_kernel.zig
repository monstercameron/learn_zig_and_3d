pub fn runHorizontalRows(
    ao_scratch: anytype,
    blur_depth_threshold: f32,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(ao_scratch), f32, usize, usize) void,
) void {
    impl_fn(ao_scratch, blur_depth_threshold, start_row, end_row);
}

pub fn runVerticalRows(
    ao_scratch: anytype,
    blur_depth_threshold: f32,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(ao_scratch), f32, usize, usize) void,
) void {
    impl_fn(ao_scratch, blur_depth_threshold, start_row, end_row);
}
