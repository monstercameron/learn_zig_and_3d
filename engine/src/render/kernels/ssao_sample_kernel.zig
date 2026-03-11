pub fn runRows(
    scene_camera: anytype,
    scene_width: usize,
    scene_height: usize,
    ao_scratch: anytype,
    ao_config: anytype,
    start_row: usize,
    end_row: usize,
    comptime impl_fn: fn (@TypeOf(scene_camera), usize, usize, @TypeOf(ao_scratch), @TypeOf(ao_config), usize, usize) void,
) void {
    impl_fn(scene_camera, scene_width, scene_height, ao_scratch, ao_config, start_row, end_row);
}
