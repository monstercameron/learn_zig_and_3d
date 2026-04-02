const std = @import("std");
const Bitmap = @import("../../assets/bitmap.zig").Bitmap;
const direct_primitives = @import("../direct_primitives.zig");
const present_d3d11 = @import("../present/present_d3d11.zig");
const present_state = @import("../present_state.zig");

pub const Result = struct {
    present_ns: i128 = 0,
    presented: bool = false,
};

pub fn execute(
    backend: *present_d3d11.Backend,
    state: *const present_state.State,
    bitmap: *const Bitmap,
    vsync: bool,
    dirty_rect: ?direct_primitives.Rect2i,
) !Result {
    if (!state.canPresent()) return .{};

    const start = std.time.nanoTimestamp();
    try backend.present(bitmap, vsync, if (dirty_rect) |rect| .{
        .min_x = rect.min_x,
        .min_y = rect.min_y,
        .max_x = rect.max_x,
        .max_y = rect.max_y,
    } else null);
    const end = std.time.nanoTimestamp();
    return .{
        .present_ns = @max(end - start, @as(i128, 0)),
        .presented = true,
    };
}
