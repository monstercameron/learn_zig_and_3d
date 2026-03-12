//! Frame Context module.
//! Shared renderer core types/utilities used across passes, kernels, and frame setup.

pub const FrameContext = struct {
    pixels: []u32,
    depth: []const f32,
    width: usize,
    height: usize,
};
