pub const FrameContext = struct {
    pixels: []u32,
    depth: []const f32,
    width: usize,
    height: usize,
};
