pub fn runRows(
    bloom: anytype,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(bloom), usize, usize) void,
) void {
    impl_fn(bloom, start_row, end_row);
}
